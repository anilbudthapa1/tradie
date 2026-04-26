// Package customer_addresses implements Module 17 — Customer Address Module.
//
// One service: CustomerAddressService. The handler exposes:
//
//   - Top-level CRUD per spec:
//       GET    /api/v1/customer_addresses
//       POST   /api/v1/customer_addresses
//       GET    /api/v1/customer_addresses/{id}
//       PATCH  /api/v1/customer_addresses/{id}
//       DELETE /api/v1/customer_addresses/{id}
//       POST   /api/v1/customer_addresses/{id}/status
//       GET    /api/v1/customer_addresses/export.csv
//
//   - Legacy nested endpoints (mobile compat):
//       GET    /api/v1/customers/{id}/addresses
//       POST   /api/v1/customers/{id}/addresses
//       PATCH  /api/v1/customers/{id}/addresses/{aid}
//       PUT    /api/v1/customers/{id}/addresses/{aid}
//       DELETE /api/v1/customers/{id}/addresses/{aid}
//
//   - Self-service:
//       GET    /api/v1/me/customer_address_module
//
// Security: business_id only ever comes from BusinessIDFromCtx;
// customers.addresses.manage gates writes; customers.view gates
// reads; customers.addresses.export gates the CSV; sensitive
// actions emit CUSTOMER_ADDRESS_MODULE_* audit events.
package customer_addresses

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditViewed       = "CUSTOMER_ADDRESS_MODULE_VIEWED"
	AuditCreated      = "CUSTOMER_ADDRESS_MODULE_CREATED"
	AuditUpdated      = "CUSTOMER_ADDRESS_MODULE_UPDATED"
	AuditDeleted      = "CUSTOMER_ADDRESS_MODULE_DELETED"
	AuditAccessDenied = "CUSTOMER_ADDRESS_MODULE_ACCESS_DENIED"
	AuditExported     = "CUSTOMER_ADDRESS_MODULE_EXPORTED"

	maxBodyBytes = 32 * 1024
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedAddressType = map[string]bool{"service": true, "billing": true, "postal": true, "other": true}
	allowedStatus      = map[string]bool{"active": true, "archived": true}
	allowedTransition  = map[[2]string]bool{
		{"active", "archived"}: true,
		{"archived", "active"}: true,
	}

	// auPostcode matches Australian 4-digit postcodes.
	auPostcode = regexp.MustCompile(`^[0-9]{4}$`)
)

// ── Handler / wiring ─────────────────────────────────────────────

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── Row shape ───────────────────────────────────────────────────

type addressRow struct {
	ID           uuid.UUID  `json:"id"`
	CustomerID   uuid.UUID  `json:"customer_id"`
	BusinessID   uuid.UUID  `json:"-"`
	CreatedBy    *uuid.UUID `json:"created_by"`
	UpdatedBy    *uuid.UUID `json:"updated_by"`
	Label        *string    `json:"label"`
	AddressType  string     `json:"address_type"`
	AddressLine1 string     `json:"address_line1"`
	AddressLine2 *string    `json:"address_line2"`
	City         string     `json:"city"`
	State        *string    `json:"state"`
	Postcode     *string    `json:"postcode"`
	Country      string     `json:"country"`
	IsPrimary    bool       `json:"is_primary"`
	Status       string     `json:"status"`
	Metadata     []byte     `json:"-"`
	CreatedAt    time.Time  `json:"created_at"`
	UpdatedAt    time.Time  `json:"updated_at"`
}

func (a *addressRow) MarshalJSON() ([]byte, error) {
	type alias addressRow
	mm := json.RawMessage(a.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(a), mm})
}

// ── List ────────────────────────────────────────────────────────

// List handles both:
//
//	GET /api/v1/customer_addresses?customer_id=&address_type=&status=&limit=
//	GET /api/v1/customers/{id}/addresses                                   (legacy)
//
// Tenant isolation is enforced via business_id; customer_id is
// optional but when supplied must belong to the same tenant.
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.view") {
		return
	}

	customerID := strings.TrimSpace(r.URL.Query().Get("customer_id"))
	if id := chi.URLParam(r, "id"); id != "" {
		customerID = id // legacy nested route — :id is the customer
	}
	addressType := strings.TrimSpace(r.URL.Query().Get("address_type"))
	if addressType != "" && !allowedAddressType[addressType] {
		respondErr(w, http.StatusBadRequest, "invalid_address_type")
		return
	}
	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter == "" {
		statusFilter = "active" // default to active rows
	}
	if statusFilter != "all" && !allowedStatus[statusFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	args := []interface{}{bizID}
	filters := []string{"business_id=$1", "deleted_at IS NULL"}
	next := 2
	if customerID != "" {
		uid, err := uuid.Parse(customerID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_customer_id")
			return
		}
		filters = append(filters, "customer_id=$"+strconv.Itoa(next))
		args = append(args, uid)
		next++
	}
	if addressType != "" {
		filters = append(filters, "address_type=$"+strconv.Itoa(next))
		args = append(args, addressType)
		next++
	}
	if statusFilter != "all" {
		filters = append(filters, "status=$"+strconv.Itoa(next))
		args = append(args, statusFilter)
		next++
	}
	args = append(args, limit)
	limitParam := next

	q := `SELECT id, customer_id, business_id, created_by, updated_by, label,
	             address_type, address_line1, address_line2, city, state, postcode,
	             country, is_primary, status, metadata, created_at, updated_at
	      FROM customer_addresses
	      WHERE ` + strings.Join(filters, " AND ") + `
	      ORDER BY is_primary DESC, created_at ASC
	      LIMIT $` + strconv.Itoa(limitParam)

	rows, err := h.db.Query(r.Context(), q, args...)
	if err != nil {
		h.log.Error("list addresses", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*addressRow{}
	for rows.Next() {
		ar := &addressRow{}
		if err := rows.Scan(&ar.ID, &ar.CustomerID, &ar.BusinessID, &ar.CreatedBy, &ar.UpdatedBy, &ar.Label,
			&ar.AddressType, &ar.AddressLine1, &ar.AddressLine2, &ar.City, &ar.State, &ar.Postcode,
			&ar.Country, &ar.IsPrimary, &ar.Status, &ar.Metadata, &ar.CreatedAt, &ar.UpdatedAt); err == nil {
			out = append(out, ar)
		}
	}
	respond(w, http.StatusOK, out)
}

// ── Create ──────────────────────────────────────────────────────

// Create handles both:
//
//	POST /api/v1/customer_addresses                  (body: {customer_id, ...})
//	POST /api/v1/customers/{id}/addresses            (legacy: customer_id from URL)
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.addresses.manage") {
		return
	}

	var req struct {
		CustomerID   string                 `json:"customer_id"`
		Label        string                 `json:"label"`
		AddressType  string                 `json:"address_type"`
		AddressLine1 string                 `json:"address_line1"`
		AddressLine2 string                 `json:"address_line2"`
		City         string                 `json:"city"`
		State        string                 `json:"state"`
		Postcode     string                 `json:"postcode"`
		Country      string                 `json:"country"`
		IsPrimary    bool                   `json:"is_primary"`
		Metadata     map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	// Customer ID can come from URL (legacy) or body (top-level).
	customerIDStr := strings.TrimSpace(req.CustomerID)
	if id := chi.URLParam(r, "id"); id != "" {
		customerIDStr = id
	}
	customerID, err := uuid.Parse(customerIDStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_customer_id")
		return
	}
	if !h.customerInTenant(r, customerID, bizID) {
		respondErr(w, http.StatusBadRequest, "customer_not_in_tenant")
		return
	}

	if strings.TrimSpace(req.AddressLine1) == "" {
		respondErr(w, http.StatusBadRequest, "address_line1_required")
		return
	}
	if strings.TrimSpace(req.City) == "" {
		respondErr(w, http.StatusBadRequest, "city_required")
		return
	}
	if req.AddressType == "" {
		req.AddressType = "service"
	}
	if !allowedAddressType[req.AddressType] {
		respondErr(w, http.StatusBadRequest, "invalid_address_type")
		return
	}
	if strings.TrimSpace(req.Country) == "" {
		req.Country = "AU"
	}
	if req.Postcode != "" && strings.EqualFold(req.Country, "AU") && !auPostcode.MatchString(req.Postcode) {
		respondErr(w, http.StatusBadRequest, "invalid_postcode")
		return
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "tx_failed")
		return
	}
	defer tx.Rollback(r.Context())

	// Demote existing primary if the new one claims it.
	if req.IsPrimary {
		if _, err := tx.Exec(r.Context(),
			`UPDATE customer_addresses
			   SET is_primary=false, updated_at=NOW()
			 WHERE customer_id=$1 AND business_id=$2 AND deleted_at IS NULL AND is_primary=true`,
			customerID, bizID); err != nil {
			respondErr(w, http.StatusInternalServerError, "demote_failed")
			return
		}
	}

	metaBytes := jsonOrEmpty(req.Metadata)
	var newID uuid.UUID
	err = tx.QueryRow(r.Context(),
		`INSERT INTO customer_addresses
		   (customer_id, business_id, created_by, label, address_type,
		    address_line1, address_line2, city, state, postcode, country,
		    is_primary, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13::jsonb)
		 RETURNING id`,
		customerID, bizID, claims.UserID, nullStr(req.Label), req.AddressType,
		strings.TrimSpace(req.AddressLine1), nullStr(req.AddressLine2),
		strings.TrimSpace(req.City), nullStr(req.State), nullStr(req.Postcode), req.Country,
		req.IsPrimary, metaBytes,
	).Scan(&newID)
	if err != nil {
		h.log.Error("create address", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		respondErr(w, http.StatusInternalServerError, "commit_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "customer_address",
		EntityID:   newID,
		NewData: map[string]interface{}{
			"customer_id":  customerID,
			"address_type": req.AddressType,
			"city":         req.City,
			"state":        req.State,
			"is_primary":   req.IsPrimary,
		},
		IPAddress: r.RemoteAddr,
	})

	// Return the newly-created row so callers don't need a follow-up GET.
	h.respondOne(w, r, newID, http.StatusCreated)
}

// ── Get ─────────────────────────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "customers.view") {
		return
	}

	idStr := chi.URLParam(r, "id")
	if v := chi.URLParam(r, "aid"); v != "" {
		idStr = v // legacy nested route uses {aid}
	}
	id, err := uuid.Parse(idStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}
	h.respondOne(w, r, id, http.StatusOK)
}

// respondOne writes a single address row (or 404). Shared between Get and
// the post-Create response.
func (h *Handler) respondOne(w http.ResponseWriter, r *http.Request, id uuid.UUID, code int) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	ar := &addressRow{}
	err := h.db.QueryRow(r.Context(),
		`SELECT id, customer_id, business_id, created_by, updated_by, label,
		        address_type, address_line1, address_line2, city, state, postcode,
		        country, is_primary, status, metadata, created_at, updated_at
		 FROM customer_addresses WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&ar.ID, &ar.CustomerID, &ar.BusinessID, &ar.CreatedBy, &ar.UpdatedBy, &ar.Label,
		&ar.AddressType, &ar.AddressLine1, &ar.AddressLine2, &ar.City, &ar.State, &ar.Postcode,
		&ar.Country, &ar.IsPrimary, &ar.Status, &ar.Metadata, &ar.CreatedAt, &ar.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	respond(w, code, ar)
}

// ── Update ──────────────────────────────────────────────────────

// Update handles both:
//
//	PATCH /api/v1/customer_addresses/{id}
//	PUT|PATCH /api/v1/customers/{id}/addresses/{aid}   (legacy)
func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.addresses.manage") {
		return
	}

	idStr := chi.URLParam(r, "id")
	if v := chi.URLParam(r, "aid"); v != "" {
		idStr = v
	}
	id, err := uuid.Parse(idStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Label        *string                `json:"label"`
		AddressType  *string                `json:"address_type"`
		AddressLine1 *string                `json:"address_line1"`
		AddressLine2 *string                `json:"address_line2"`
		City         *string                `json:"city"`
		State        *string                `json:"state"`
		Postcode     *string                `json:"postcode"`
		Country      *string                `json:"country"`
		IsPrimary    *bool                  `json:"is_primary"`
		Status       *string                `json:"status"`
		Metadata     map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	if req.AddressType != nil && !allowedAddressType[*req.AddressType] {
		respondErr(w, http.StatusBadRequest, "invalid_address_type")
		return
	}
	if req.Status != nil && !allowedStatus[*req.Status] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}

	// Postcode-format check when supplied (Australia only).
	country := "AU"
	if req.Country != nil && strings.TrimSpace(*req.Country) != "" {
		country = *req.Country
	}
	if req.Postcode != nil && *req.Postcode != "" && strings.EqualFold(country, "AU") && !auPostcode.MatchString(*req.Postcode) {
		respondErr(w, http.StatusBadRequest, "invalid_postcode")
		return
	}

	// Snapshot for transition validation + old-data audit.
	var current addressRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, customer_id, status, address_type, is_primary, city
		 FROM customer_addresses WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current.ID, &current.CustomerID, &current.Status, &current.AddressType, &current.IsPrimary, &current.City)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	if req.Status != nil && *req.Status != current.Status {
		if !allowedTransition[[2]string{current.Status, *req.Status}] {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "tx_failed")
		return
	}
	defer tx.Rollback(r.Context())

	// Demote any other primary if this row is becoming primary.
	if req.IsPrimary != nil && *req.IsPrimary && !current.IsPrimary {
		if _, err := tx.Exec(r.Context(),
			`UPDATE customer_addresses
			   SET is_primary=false, updated_at=NOW()
			 WHERE customer_id=$1 AND business_id=$2 AND id<>$3 AND deleted_at IS NULL AND is_primary=true`,
			current.CustomerID, bizID, id); err != nil {
			respondErr(w, http.StatusInternalServerError, "demote_failed")
			return
		}
	}

	var meta []byte
	if req.Metadata != nil {
		meta, _ = json.Marshal(req.Metadata)
	}

	tag, err := tx.Exec(r.Context(),
		`UPDATE customer_addresses SET
		   label         = COALESCE($3, label),
		   address_type  = COALESCE($4, address_type),
		   address_line1 = COALESCE($5, address_line1),
		   address_line2 = COALESCE($6, address_line2),
		   city          = COALESCE($7, city),
		   state         = COALESCE($8, state),
		   postcode      = COALESCE($9, postcode),
		   country       = COALESCE($10, country),
		   is_primary    = COALESCE($11, is_primary),
		   status        = COALESCE($12, status),
		   metadata      = COALESCE($13::jsonb, metadata),
		   updated_by    = $14,
		   updated_at    = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Label, req.AddressType, req.AddressLine1, req.AddressLine2,
		req.City, req.State, req.Postcode, req.Country, req.IsPrimary, req.Status,
		meta, claims.UserID,
	)
	if err != nil {
		// Trigger raises check_violation for invalid transitions.
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
		h.log.Error("update address", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "update_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		respondErr(w, http.StatusInternalServerError, "commit_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "customer_address",
		EntityID:   id,
		OldData: map[string]interface{}{
			"status": current.Status, "address_type": current.AddressType,
			"is_primary": current.IsPrimary, "city": current.City,
		},
		NewData: map[string]interface{}{
			"status":       derefStr(req.Status),
			"address_type": derefStr(req.AddressType),
			"is_primary":   derefBool(req.IsPrimary),
			"city":         derefStr(req.City),
		},
		IPAddress: r.RemoteAddr,
	})

	h.respondOne(w, r, id, http.StatusOK)
}

// ── Delete ──────────────────────────────────────────────────────

// Delete handles both:
//
//	DELETE /api/v1/customer_addresses/{id}
//	DELETE /api/v1/customers/{id}/addresses/{aid}   (legacy)
//
// Soft delete; the row stays for audit/legal reasons.
func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.addresses.manage") {
		return
	}

	idStr := chi.URLParam(r, "id")
	if v := chi.URLParam(r, "aid"); v != "" {
		idStr = v
	}
	id, err := uuid.Parse(idStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE customer_addresses
		   SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "delete_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditDeleted,
		EntityType: "customer_address",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// ── Status transition ───────────────────────────────────────────

// SetStatus moves an address between active/archived. The DB trigger
// is the source of truth; the handler short-circuits for nicer error
// responses.
func (h *Handler) SetStatus(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.addresses.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Status string `json:"status"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if !allowedStatus[req.Status] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}

	var current string
	err = h.db.QueryRow(r.Context(),
		`SELECT status FROM customer_addresses WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}
	if current == req.Status {
		respond(w, http.StatusOK, map[string]string{"message": "no_change", "status": current})
		return
	}

	if _, err := h.db.Exec(r.Context(),
		`UPDATE customer_addresses
		   SET status=$3, updated_by=$4, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Status, claims.UserID); err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
		respondErr(w, http.StatusInternalServerError, "update_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "customer_address",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current},
		NewData:    map[string]interface{}{"status": req.Status},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{"id": id, "status": req.Status})
}

// ── Self-service ────────────────────────────────────────────────

// MeView returns the addresses belonging to customers the calling
// employee has open jobs for. This is the safe surface for workers
// who otherwise should not browse the full address book.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.view") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT DISTINCT a.id, a.customer_id, a.business_id, a.created_by, a.updated_by, a.label,
		                a.address_type, a.address_line1, a.address_line2, a.city, a.state, a.postcode,
		                a.country, a.is_primary, a.status, a.metadata, a.created_at, a.updated_at
		 FROM customer_addresses a
		 JOIN jobs j ON j.customer_id=a.customer_id
		 JOIN job_assignments ja ON ja.job_id=j.id
		 WHERE a.business_id=$1 AND a.deleted_at IS NULL AND a.status='active'
		   AND ja.user_id=$2
		 ORDER BY a.is_primary DESC, a.city`,
		bizID, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*addressRow{}
	for rows.Next() {
		ar := &addressRow{}
		if err := rows.Scan(&ar.ID, &ar.CustomerID, &ar.BusinessID, &ar.CreatedBy, &ar.UpdatedBy, &ar.Label,
			&ar.AddressType, &ar.AddressLine1, &ar.AddressLine2, &ar.City, &ar.State, &ar.Postcode,
			&ar.Country, &ar.IsPrimary, &ar.Status, &ar.Metadata, &ar.CreatedAt, &ar.UpdatedAt); err == nil {
			out = append(out, ar)
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "customer_address.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, out)
}

// ── Export ──────────────────────────────────────────────────────

// Export streams every active address as CSV. PII (full street line)
// is included; access is gated by customers.addresses.export.
func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.addresses.export") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedStatus[statusFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT a.id, a.customer_id,
		        COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer_name,
		        COALESCE(a.label,''), a.address_type, a.address_line1,
		        COALESCE(a.address_line2,''), a.city, COALESCE(a.state,''),
		        COALESCE(a.postcode,''), a.country, a.is_primary, a.status, a.created_at
		 FROM customer_addresses a
		 LEFT JOIN customers c ON c.id=a.customer_id
		 WHERE a.business_id=$1 AND a.deleted_at IS NULL
		   AND ($2='' OR a.status=$2)
		 ORDER BY c.first_name, a.is_primary DESC, a.city`,
		bizID, statusFilter)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="customer-addresses-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "customer_id", "customer", "label", "address_type",
		"address_line1", "address_line2", "city", "state", "postcode", "country",
		"is_primary", "status", "created_at"})

	for rows.Next() {
		var id, customerID uuid.UUID
		var customer, label, addressType, line1, line2, city, state, postcode, country, status string
		var isPrimary bool
		var createdAt time.Time
		if err := rows.Scan(&id, &customerID, &customer, &label, &addressType, &line1, &line2,
			&city, &state, &postcode, &country, &isPrimary, &status, &createdAt); err != nil {
			continue
		}
		_ = cw.Write([]string{
			id.String(), customerID.String(), customer, label, addressType,
			line1, line2, city, state, postcode, country,
			strconv.FormatBool(isPrimary), status,
			createdAt.UTC().Format(time.RFC3339),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "customer_address",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Internal helpers ────────────────────────────────────────────

func (h *Handler) customerInTenant(r *http.Request, customerID, bizID uuid.UUID) bool {
	var ok bool
	if err := h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM customers WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		customerID, bizID).Scan(&ok); err != nil {
		return false
	}
	return ok
}

func (h *Handler) requirePermission(w http.ResponseWriter, r *http.Request, key string) bool {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return false
	}

	var allowed bool
	err := h.db.QueryRow(r.Context(),
		`SELECT EXISTS(
		   SELECT 1
		   FROM role_permissions rp
		   JOIN permissions p ON p.id = rp.permission_id
		   WHERE rp.role=$1 AND p.key=$2
		     AND (rp.business_id=$3 OR
		          (rp.business_id IS NULL AND NOT EXISTS (
		             SELECT 1 FROM role_permissions rp2 WHERE rp2.role=$1 AND rp2.business_id=$3
		          )))
		 )`,
		claims.Role, key, bizID).Scan(&allowed)
	if err != nil {
		h.log.Error("permission check", zap.String("key", key), zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "permission_check_failed")
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditAccessDenied,
			EntityType: "customer_address",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respondErr(w, http.StatusForbidden, "forbidden:"+key)
		return false
	}
	return true
}

func decodeStrict(r *http.Request, dst interface{}) error {
	r.Body = http.MaxBytesReader(nil, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			return errors.New("body_too_large")
		}
		if errors.Is(err, io.EOF) {
			return errors.New("empty_body")
		}
		return errors.New("invalid_request")
	}
	if dec.More() {
		return errors.New("trailing_data")
	}
	return nil
}

func nullStr(s string) interface{} {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	return s
}

func jsonOrEmpty(v map[string]interface{}) []byte {
	if v == nil {
		return []byte("{}")
	}
	b, err := json.Marshal(v)
	if err != nil || len(b) == 0 {
		return []byte("{}")
	}
	return b
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func derefBool(p *bool) bool {
	if p == nil {
		return false
	}
	return *p
}

func respond(w http.ResponseWriter, code int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if body != nil {
		_ = json.NewEncoder(w).Encode(body)
	}
}

func respondErr(w http.ResponseWriter, code int, msg string) {
	respond(w, code, map[string]string{"error": msg})
}
