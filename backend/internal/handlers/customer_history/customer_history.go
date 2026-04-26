// Package customer_history implements Module 19 — Customer History Module.
//
// One service, two streams:
//
//   - Derived timeline — a UNION ALL across jobs, quotes, invoices,
//     invoice_payments and customer_notes, scoped to one customer.
//     Read-only; the underlying entities own their own writes.
//
//   - History annotations — owner / employee-authored entries on
//     customer_notes (extended in migration 000029 with status, kind,
//     metadata and the rest of the spec CRUD-pattern columns). Calls,
//     SMS, emails, site visits and free-text notes share this entity.
//
// Security:
//
//   - business_id only ever from BusinessIDFromCtx
//   - customers.history.view gates reads
//   - customers.history.create / .manage gate writes
//   - customers.history.export gates the CSV
//   - sensitive actions emit CUSTOMER_HISTORY_MODULE_* audit events
package customer_history

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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
	AuditViewed       = "CUSTOMER_HISTORY_MODULE_VIEWED"
	AuditCreated      = "CUSTOMER_HISTORY_MODULE_CREATED"
	AuditUpdated      = "CUSTOMER_HISTORY_MODULE_UPDATED"
	AuditDeleted      = "CUSTOMER_HISTORY_MODULE_DELETED"
	AuditAccessDenied = "CUSTOMER_HISTORY_MODULE_ACCESS_DENIED"
	AuditExported     = "CUSTOMER_HISTORY_MODULE_EXPORTED"

	maxBodyBytes = 32 * 1024
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedKind       = map[string]bool{"note": true, "call": true, "sms": true, "email": true, "site_visit": true, "other": true}
	allowedStatus     = map[string]bool{"active": true, "archived": true}
	allowedTransition = map[[2]string]bool{
		{"active", "archived"}: true,
		{"archived", "active"}: true,
	}
	// Kinds the timeline UNION can filter by — superset includes the
	// derived legs (job/quote/invoice/payment) too.
	allowedTimelineKind = map[string]bool{
		"job": true, "quote": true, "invoice": true, "payment": true, "note": true,
	}
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

// ── Derived timeline ────────────────────────────────────────────

// Timeline (GET /api/v1/customers/{id}/history) returns a unified
// timeline across jobs / quotes / invoices / payments / notes for
// a single customer. Each row carries a `kind` discriminator so the
// UI can render type-specific badges.
func (h *Handler) Timeline(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.history.view") {
		return
	}

	custUUID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	// Verify the customer exists in this tenant before exposing aggregated data.
	var exists bool
	if err := h.db.QueryRow(r.Context(),
		`SELECT EXISTS (SELECT 1 FROM customers WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		custUUID, bizID,
	).Scan(&exists); err != nil || !exists {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	kindFilter := strings.TrimSpace(r.URL.Query().Get("kind"))
	if kindFilter != "" && !allowedTimelineKind[kindFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_kind")
		return
	}
	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 1000 {
			limit = n
		}
	}
	var sinceTime *time.Time
	if v := strings.TrimSpace(r.URL.Query().Get("since")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_since")
			return
		}
		sinceTime = &t
	}

	// One UNION ALL → one round-trip. Each leg carries a `kind` and a
	// canonical `(title, status, amount)` shape so the client sees a
	// uniform record. Amounts are nullable for non-financial events.
	const sql = `
SELECT kind, id, title, status, amount, occurred_at, ref, sub_kind FROM (
    SELECT 'job' AS kind, id::text AS id,
           COALESCE(title, '')          AS title,
           COALESCE(status::text, '')   AS status,
           NULL::float8                 AS amount,
           created_at                   AS occurred_at,
           job_number                   AS ref,
           ''                           AS sub_kind
      FROM jobs
     WHERE customer_id = $1 AND business_id = $2 AND deleted_at IS NULL

    UNION ALL

    SELECT 'quote', id::text,
           COALESCE(title, ''), COALESCE(status::text, ''),
           total::float8, created_at, quote_number, ''
      FROM quotes
     WHERE customer_id = $1 AND business_id = $2 AND deleted_at IS NULL

    UNION ALL

    SELECT 'invoice', id::text,
           COALESCE(invoice_number, ''), COALESCE(status::text, ''),
           total::float8, created_at, invoice_number, ''
      FROM invoices
     WHERE customer_id = $1 AND business_id = $2 AND deleted_at IS NULL

    UNION ALL

    SELECT 'payment', ip.id::text,
           COALESCE('Invoice ' || i.invoice_number, 'Payment'),
           COALESCE(ip.payment_method, ''),
           ip.amount::float8, ip.paid_at,
           COALESCE(ip.reference, ''), ''
      FROM invoice_payments ip
      JOIN invoices i
        ON i.id = ip.invoice_id
       AND i.business_id = ip.business_id
     WHERE i.customer_id = $1 AND ip.business_id = $2

    UNION ALL

    SELECT 'note', id::text,
           LEFT(content, 120), status,
           NULL::float8, created_at, '',
           kind
      FROM customer_notes
     WHERE customer_id = $1 AND business_id = $2 AND deleted_at IS NULL
) t
WHERE ($3 = '' OR kind = $3)
  AND ($4::timestamptz IS NULL OR occurred_at >= $4::timestamptz)
ORDER BY occurred_at DESC
LIMIT $5`

	rows, err := h.db.Query(r.Context(), sql, custUUID, bizID, kindFilter, sinceTime, limit)
	if err != nil {
		h.log.Error("customer history", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	type entry struct {
		Kind       string    `json:"kind"`
		ID         string    `json:"id"`
		Title      string    `json:"title"`
		Status     string    `json:"status,omitempty"`
		Amount     *float64  `json:"amount,omitempty"`
		OccurredAt time.Time `json:"occurred_at"`
		Ref        string    `json:"ref,omitempty"`
		SubKind    string    `json:"sub_kind,omitempty"`
	}

	out := make([]entry, 0, 64)
	for rows.Next() {
		var e entry
		var amount *float64
		if err := rows.Scan(&e.Kind, &e.ID, &e.Title, &e.Status, &amount, &e.OccurredAt, &e.Ref, &e.SubKind); err != nil {
			h.log.Warn("history scan", zap.Error(err))
			continue
		}
		e.Amount = amount
		out = append(out, e)
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "customer_history",
		EntityID:   custUUID,
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"customer_id": custUUID,
		"items":       out,
	})
}

// ── Annotation CRUD on customer_notes ───────────────────────────

type annotationRow struct {
	ID         uuid.UUID  `json:"id"`
	CustomerID uuid.UUID  `json:"customer_id"`
	BusinessID uuid.UUID  `json:"-"`
	CreatedBy  *uuid.UUID `json:"created_by"`
	UpdatedBy  *uuid.UUID `json:"updated_by"`
	Author     *string    `json:"author"`
	Content    string     `json:"content"`
	Kind       string     `json:"kind"`
	Status     string     `json:"status"`
	Metadata   []byte     `json:"-"`
	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"updated_at"`
}

func (a *annotationRow) MarshalJSON() ([]byte, error) {
	type alias annotationRow
	mm := json.RawMessage(a.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(a), mm})
}

// ListAnnotations handles both:
//
//	GET /api/v1/customer_history?customer_id=&kind=&status=&limit=
//	GET /api/v1/customers/{id}/notes                           (legacy)
func (h *Handler) ListAnnotations(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.history.view") {
		return
	}

	customerID := strings.TrimSpace(r.URL.Query().Get("customer_id"))
	if id := chi.URLParam(r, "id"); id != "" {
		customerID = id
	}
	kindFilter := strings.TrimSpace(r.URL.Query().Get("kind"))
	if kindFilter != "" && !allowedKind[kindFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_kind")
		return
	}
	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter == "" {
		statusFilter = "active"
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
	filters := []string{"n.business_id=$1", "n.deleted_at IS NULL"}
	next := 2
	if customerID != "" {
		uid, err := uuid.Parse(customerID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_customer_id")
			return
		}
		filters = append(filters, "n.customer_id=$"+strconv.Itoa(next))
		args = append(args, uid)
		next++
	}
	if kindFilter != "" {
		filters = append(filters, "n.kind=$"+strconv.Itoa(next))
		args = append(args, kindFilter)
		next++
	}
	if statusFilter != "all" {
		filters = append(filters, "n.status=$"+strconv.Itoa(next))
		args = append(args, statusFilter)
		next++
	}
	args = append(args, limit)
	limitParam := next

	q := `SELECT n.id, n.customer_id, n.business_id, n.created_by, n.updated_by,
	             u.first_name||' '||COALESCE(u.last_name,'') AS author,
	             n.content, n.kind, n.status, n.metadata,
	             n.created_at, n.updated_at
	      FROM customer_notes n
	      LEFT JOIN users u ON u.id = n.created_by
	      WHERE ` + strings.Join(filters, " AND ") + `
	      ORDER BY n.created_at DESC
	      LIMIT $` + strconv.Itoa(limitParam)

	rows, err := h.db.Query(r.Context(), q, args...)
	if err != nil {
		h.log.Error("list annotations", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*annotationRow{}
	for rows.Next() {
		ar := &annotationRow{}
		if err := rows.Scan(&ar.ID, &ar.CustomerID, &ar.BusinessID, &ar.CreatedBy, &ar.UpdatedBy,
			&ar.Author, &ar.Content, &ar.Kind, &ar.Status, &ar.Metadata,
			&ar.CreatedAt, &ar.UpdatedAt); err == nil {
			out = append(out, ar)
		}
	}
	respond(w, http.StatusOK, out)
}

// CreateAnnotation handles both:
//
//	POST /api/v1/customer_history       (body: {customer_id, content, kind, ...})
//	POST /api/v1/customers/{id}/notes   (legacy; customer_id from URL)
func (h *Handler) CreateAnnotation(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.history.create") {
		return
	}

	var req struct {
		CustomerID string                 `json:"customer_id"`
		Content    string                 `json:"content"`
		Kind       string                 `json:"kind"`
		Metadata   map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

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

	if strings.TrimSpace(req.Content) == "" {
		respondErr(w, http.StatusBadRequest, "content_required")
		return
	}
	if req.Kind == "" {
		req.Kind = "note"
	}
	if !allowedKind[req.Kind] {
		respondErr(w, http.StatusBadRequest, "invalid_kind")
		return
	}

	metaBytes := jsonOrEmpty(req.Metadata)

	ar := &annotationRow{}
	err = h.db.QueryRow(r.Context(),
		`INSERT INTO customer_notes
		   (customer_id, business_id, created_by, content, kind, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6::jsonb)
		 RETURNING id, customer_id, business_id, created_by, updated_by,
		           (SELECT first_name||' '||COALESCE(last_name,'') FROM users WHERE id=$3),
		           content, kind, status, metadata, created_at, updated_at`,
		customerID, bizID, claims.UserID,
		strings.TrimSpace(req.Content), req.Kind, metaBytes,
	).Scan(&ar.ID, &ar.CustomerID, &ar.BusinessID, &ar.CreatedBy, &ar.UpdatedBy,
		&ar.Author, &ar.Content, &ar.Kind, &ar.Status, &ar.Metadata,
		&ar.CreatedAt, &ar.UpdatedAt)
	if err != nil {
		h.log.Error("create annotation", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "customer_history",
		EntityID:   ar.ID,
		NewData: map[string]interface{}{
			"customer_id": customerID, "kind": req.Kind,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusCreated, ar)
}

// GetAnnotation (GET /api/v1/customer_history/{id}).
func (h *Handler) GetAnnotation(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.history.view") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	ar := &annotationRow{}
	err = h.db.QueryRow(r.Context(),
		`SELECT n.id, n.customer_id, n.business_id, n.created_by, n.updated_by,
		        u.first_name||' '||COALESCE(u.last_name,'') AS author,
		        n.content, n.kind, n.status, n.metadata, n.created_at, n.updated_at
		 FROM customer_notes n
		 LEFT JOIN users u ON u.id=n.created_by
		 WHERE n.id=$1 AND n.business_id=$2 AND n.deleted_at IS NULL`,
		id, bizID,
	).Scan(&ar.ID, &ar.CustomerID, &ar.BusinessID, &ar.CreatedBy, &ar.UpdatedBy,
		&ar.Author, &ar.Content, &ar.Kind, &ar.Status, &ar.Metadata,
		&ar.CreatedAt, &ar.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	respond(w, http.StatusOK, ar)
}

// UpdateAnnotation (PATCH /api/v1/customer_history/{id}).
func (h *Handler) UpdateAnnotation(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.history.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Content  *string                `json:"content"`
		Kind     *string                `json:"kind"`
		Status   *string                `json:"status"`
		Metadata map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Kind != nil && !allowedKind[*req.Kind] {
		respondErr(w, http.StatusBadRequest, "invalid_kind")
		return
	}
	if req.Status != nil && !allowedStatus[*req.Status] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}

	var current annotationRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, status, kind, content
		 FROM customer_notes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current.ID, &current.Status, &current.Kind, &current.Content)
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

	var meta []byte
	if req.Metadata != nil {
		meta, _ = json.Marshal(req.Metadata)
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE customer_notes SET
		   content    = COALESCE($3, content),
		   kind       = COALESCE($4, kind),
		   status     = COALESCE($5, status),
		   metadata   = COALESCE($6::jsonb, metadata),
		   updated_by = $7,
		   updated_at = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Content, req.Kind, req.Status, meta, claims.UserID)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
		h.log.Error("update annotation", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "update_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "customer_history",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current.Status, "kind": current.Kind},
		NewData:    map[string]interface{}{"status": derefStr(req.Status), "kind": derefStr(req.Kind)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "updated"})
}

// DeleteAnnotation (DELETE /api/v1/customer_history/{id}) — soft delete.
func (h *Handler) DeleteAnnotation(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.history.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE customer_notes
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
		EntityType: "customer_history",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// ── Self-service ────────────────────────────────────────────────

// MeView (GET /api/v1/me/customer_history_module) returns history
// annotations for customers the calling employee has open jobs for.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.history.view") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT DISTINCT n.id, n.customer_id, n.business_id, n.created_by, n.updated_by,
		                u.first_name||' '||COALESCE(u.last_name,'') AS author,
		                n.content, n.kind, n.status, n.metadata,
		                n.created_at, n.updated_at
		 FROM customer_notes n
		 LEFT JOIN users u ON u.id=n.created_by
		 JOIN jobs j ON j.customer_id=n.customer_id
		 JOIN job_assignments ja ON ja.job_id=j.id
		 WHERE n.business_id=$1 AND n.deleted_at IS NULL AND n.status='active'
		   AND ja.user_id=$2
		 ORDER BY n.created_at DESC
		 LIMIT 200`,
		bizID, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*annotationRow{}
	for rows.Next() {
		ar := &annotationRow{}
		if err := rows.Scan(&ar.ID, &ar.CustomerID, &ar.BusinessID, &ar.CreatedBy, &ar.UpdatedBy,
			&ar.Author, &ar.Content, &ar.Kind, &ar.Status, &ar.Metadata,
			&ar.CreatedAt, &ar.UpdatedAt); err == nil {
			out = append(out, ar)
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "customer_history.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, out)
}

// ── Export ──────────────────────────────────────────────────────

// Export (GET /api/v1/customer_history/export.csv) — annotations only.
// The derived timeline streams come from each module's own export.
func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.history.export") {
		return
	}

	customerID := strings.TrimSpace(r.URL.Query().Get("customer_id"))
	args := []interface{}{bizID}
	filter := "n.business_id=$1 AND n.deleted_at IS NULL"
	if customerID != "" {
		uid, err := uuid.Parse(customerID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_customer_id")
			return
		}
		filter += " AND n.customer_id=$2"
		args = append(args, uid)
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT n.id, n.customer_id,
		        COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer,
		        COALESCE(u.first_name||' '||COALESCE(u.last_name,''), '') AS author,
		        n.kind, n.status, n.content, n.created_at
		 FROM customer_notes n
		 LEFT JOIN customers c ON c.id=n.customer_id
		 LEFT JOIN users u ON u.id=n.created_by
		 WHERE `+filter+`
		 ORDER BY n.created_at DESC
		 LIMIT 10000`,
		args...)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="customer-history-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "customer_id", "customer", "author", "kind", "status", "content", "created_at"})

	for rows.Next() {
		var id, custID uuid.UUID
		var customer, author, kind, status, content string
		var createdAt time.Time
		if err := rows.Scan(&id, &custID, &customer, &author, &kind, &status, &content, &createdAt); err != nil {
			continue
		}
		_ = cw.Write([]string{
			id.String(), custID.String(), customer, author, kind, status,
			content, createdAt.UTC().Format(time.RFC3339),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "customer_history",
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
			EntityType: "customer_history",
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
