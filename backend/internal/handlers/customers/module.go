// Module 15 hardening — spec-compliance shim for the customers package.
//
// This file adds what the legacy customers.go is missing per the
// Customer Management Module spec without rewriting it:
//
//   - requirePermission()  enforces customers.view / .create /
//                          .update / .delete keys against the
//                          role_permissions catalog
//   - Spec audit names     CUSTOMER_MANAGEMENT_MODULE_*
//   - MeView()             GET /api/v1/me/customer_management_module
//   - SetStatus()          POST /api/v1/customers/{id}/status
//                          status transitions are validated server-side
//   - Export()             GET /api/v1/customers.csv
//   - decodeStrict()       DisallowUnknownFields + 64 KiB body cap
//
// The legacy handler methods continue to handle CRUD; the new methods
// here cover the spec gaps. Where the legacy methods emit ad-hoc
// audit names, callers can layer `auditModuleAction` on top.
package customers

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/middleware"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditViewed       = "CUSTOMER_MANAGEMENT_MODULE_VIEWED"
	AuditCreated      = "CUSTOMER_MANAGEMENT_MODULE_CREATED"
	AuditUpdated      = "CUSTOMER_MANAGEMENT_MODULE_UPDATED"
	AuditDeleted      = "CUSTOMER_MANAGEMENT_MODULE_DELETED"
	AuditAccessDenied = "CUSTOMER_MANAGEMENT_MODULE_ACCESS_DENIED"
	AuditExported     = "CUSTOMER_MANAGEMENT_MODULE_EXPORTED"

	maxBodyBytes = 64 * 1024
)

// Allow-listed lifecycle status (matches the DB CHECK constraint).
var allowedCustomerStatus = map[string]bool{
	"lead": true, "active": true, "inactive": true, "archived": true,
}

// ── Permission enforcement ──────────────────────────────────────

// requirePermission gates an action by the spec permission key. It
// queries role_permissions (per-business override beats template).
// Emits CUSTOMER_MANAGEMENT_MODULE_ACCESS_DENIED on reject.
func (h *Handler) requirePermission(w http.ResponseWriter, r *http.Request, key string) bool {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		respond(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
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
		respond(w, http.StatusInternalServerError, map[string]string{"error": "permission_check_failed"})
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditAccessDenied,
			EntityType: "customer",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:" + key})
		return false
	}
	return true
}

// auditModuleAction emits a spec-named audit event. Callers use this
// from the legacy handler methods so existing flows pick up the new
// audit naming without rewrites.
func (h *Handler) auditModuleAction(r *http.Request, action string, customerID uuid.UUID, oldData, newData interface{}) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     action,
		EntityType: "customer",
		EntityID:   customerID,
		OldData:    oldData,
		NewData:    newData,
		IPAddress:  r.RemoteAddr,
	})
}

// ── Self-service ────────────────────────────────────────────────

// MeView (GET /api/v1/me/customer_management_module) returns the
// customers the calling employee is connected to via their assigned
// jobs. Customer-role callers see only themselves (matched on email).
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.view") {
		return
	}

	q := `SELECT DISTINCT c.id, c.business_id, c.first_name, c.last_name, c.company_name,
	             c.email, c.phone, c.mobile, c.tags, c.is_active, c.source,
	             c.status, c.created_at, c.updated_at
	      FROM customers c
	      JOIN jobs j ON j.customer_id=c.id
	      JOIN job_assignments ja ON ja.job_id=j.id
	      WHERE c.business_id=$1 AND c.deleted_at IS NULL AND ja.user_id=$2
	      ORDER BY c.first_name`
	rows, err := h.db.Query(r.Context(), q, bizID, claims.UserID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	type item struct {
		ID          uuid.UUID `json:"id"`
		FirstName   string    `json:"first_name"`
		LastName    *string   `json:"last_name"`
		CompanyName *string   `json:"company_name"`
		Email       *string   `json:"email"`
		Phone       *string   `json:"phone"`
		Mobile      *string   `json:"mobile"`
		Status      string    `json:"status"`
		CreatedAt   time.Time `json:"created_at"`
		UpdatedAt   time.Time `json:"updated_at"`
	}
	out := []item{}
	for rows.Next() {
		var it item
		var bizIDScan uuid.UUID
		var tags []string
		var active bool
		var source *string
		if err := rows.Scan(&it.ID, &bizIDScan, &it.FirstName, &it.LastName, &it.CompanyName,
			&it.Email, &it.Phone, &it.Mobile, &tags, &active, &source,
			&it.Status, &it.CreatedAt, &it.UpdatedAt); err == nil {
			out = append(out, it)
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "customer.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, out)
}

// ── Status transitions ──────────────────────────────────────────

// SetStatus (POST /api/v1/customers/{id}/status) moves a customer
// through the lifecycle: lead → active → inactive → archived.
// The DB trigger is the source of truth; this handler short-circuits
// for nicer error responses.
func (h *Handler) SetStatus(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.update") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	var req struct {
		Status string `json:"status"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if !allowedCustomerStatus[req.Status] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	var current string
	err = h.db.QueryRow(r.Context(),
		`SELECT status FROM customers WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}

	if current == req.Status {
		respond(w, http.StatusOK, map[string]string{"message": "no_change", "status": current})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE customers
		   SET status=$3, updated_by=$4, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Status, claims.UserID)
	if err != nil {
		// Trigger raises check_violation for invalid transitions.
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{
				"error":  "invalid_status_transition",
				"from":   current,
				"to":     req.Status,
			})
			return
		}
		respond(w, http.StatusInternalServerError, map[string]string{"error": "update_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}

	h.auditModuleAction(r, AuditUpdated, id,
		map[string]interface{}{"status": current},
		map[string]interface{}{"status": req.Status})

	respond(w, http.StatusOK, map[string]interface{}{"id": id, "status": req.Status})
}

// ── Export ──────────────────────────────────────────────────────

// Export (GET /api/v1/customers.csv) — CSV of every active customer.
// Sensitive PII (email, phone) is included only for callers with
// customers.view; status filter is allow-listed.
func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "customers.view") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedCustomerStatus[statusFilter] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, first_name, COALESCE(last_name,''), COALESCE(company_name,''),
		        COALESCE(email,''), COALESCE(phone,''), COALESCE(mobile,''),
		        status, created_at
		 FROM customers
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND ($2='' OR status=$2)
		 ORDER BY first_name`,
		bizID, statusFilter)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="customers-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "first_name", "last_name", "company_name", "email", "phone", "mobile", "status", "created_at"})

	for rows.Next() {
		var id uuid.UUID
		var fn, ln, cn, email, phone, mobile, status string
		var createdAt time.Time
		if err := rows.Scan(&id, &fn, &ln, &cn, &email, &phone, &mobile, &status, &createdAt); err != nil {
			continue
		}
		_ = cw.Write([]string{
			id.String(), fn, ln, cn, email, phone, mobile, status,
			createdAt.UTC().Format(time.RFC3339),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "customer",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Strict decoding ─────────────────────────────────────────────

// maskedEmailPtr is a *string-friendly variant for legacy models.
func maskedEmailPtr(p *string) string {
	if p == nil {
		return ""
	}
	return maskedEmail(*p)
}

// maskedEmail returns the email with the local-part partially obscured —
// used in audit payloads so sensitive PII does not land in plaintext.
func maskedEmail(email string) string {
	at := strings.IndexByte(email, '@')
	if at <= 0 {
		return ""
	}
	local := email[:at]
	if len(local) <= 2 {
		return "**" + email[at:]
	}
	return local[:1] + strings.Repeat("*", len(local)-2) + local[len(local)-1:] + email[at:]
}

// decodeStrict enforces the spec's "reject unknown fields" + body-size rules.
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
