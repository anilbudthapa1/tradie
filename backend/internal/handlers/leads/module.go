// Module 20 hardening — spec-compliance shim for the leads package.
//
// Adds what the legacy leads.go is missing per the Lead Management
// Module spec without rewriting it:
//
//   - requirePermission()  enforces leads.view / .create / .update /
//                          .convert / .delete / .export keys against
//                          the role_permissions catalog
//   - Spec audit names     LEAD_MANAGEMENT_MODULE_*
//   - MeView()             GET /api/v1/me/lead_management_module
//   - Export()             GET /api/v1/leads/export.csv
//   - decodeStrict()       DisallowUnknownFields + 32 KiB body cap
//   - Status transitions   server-side enforcement (DB trigger is
//                          the source of truth; this returns nicer
//                          409 errors for invalid moves)
package leads

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/middleware"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditViewed       = "LEAD_MANAGEMENT_MODULE_VIEWED"
	AuditCreated      = "LEAD_MANAGEMENT_MODULE_CREATED"
	AuditUpdated      = "LEAD_MANAGEMENT_MODULE_UPDATED"
	AuditDeleted      = "LEAD_MANAGEMENT_MODULE_DELETED"
	AuditAccessDenied = "LEAD_MANAGEMENT_MODULE_ACCESS_DENIED"
	AuditExported     = "LEAD_MANAGEMENT_MODULE_EXPORTED"
	AuditConverted    = "LEAD_MANAGEMENT_MODULE_UPDATED" // convert is an update + new customer

	maxBodyBytes = 32 * 1024
)

// Status pipeline transitions (mirrors the DB trigger). The handler
// short-circuits invalid moves so callers get a clean 409 rather than
// a cryptic check_violation surfacing through the driver.
var allowedStatusTransition = map[[2]string]bool{
	{"new", "contacted"}:        true,
	{"new", "qualified"}:        true,
	{"new", "lost"}:             true,
	{"contacted", "qualified"}:  true,
	{"contacted", "proposal"}:   true,
	{"contacted", "lost"}:       true,
	{"qualified", "proposal"}:   true,
	{"qualified", "lost"}:       true,
	{"proposal", "won"}:         true,
	{"proposal", "lost"}:        true,
}

// ── Permission enforcement ──────────────────────────────────────

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
			EntityType: "lead",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:" + key})
		return false
	}
	return true
}

// auditModuleAction emits a spec-named audit event with optional masked PII.
func (h *Handler) auditModuleAction(r *http.Request, action string, leadID uuid.UUID, oldData, newData interface{}) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     action,
		EntityType: "lead",
		EntityID:   leadID,
		OldData:    oldData,
		NewData:    newData,
		IPAddress:  r.RemoteAddr,
	})
}

// ── Self-service ────────────────────────────────────────────────

// MeView (GET /api/v1/me/lead_management_module) returns the leads
// either assigned to the calling user or in 'new' status (so workers
// can pick up unassigned leads from the field).
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "leads.view") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, first_name, COALESCE(last_name,''), COALESCE(email,''),
		        COALESCE(phone,''), status, COALESCE(source,''), COALESCE(notes,''),
		        assigned_to, created_at, updated_at
		 FROM leads
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND (assigned_to=$2 OR (assigned_to IS NULL AND status='new'))
		 ORDER BY
		   CASE status WHEN 'new' THEN 1 WHEN 'contacted' THEN 2 WHEN 'qualified' THEN 3
		               WHEN 'proposal' THEN 4 WHEN 'won' THEN 5 ELSE 6 END,
		   created_at DESC
		 LIMIT 200`,
		bizID, claims.UserID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	out := []Lead{}
	for rows.Next() {
		var l Lead
		if err := rows.Scan(&l.ID, &l.BusinessID, &l.FirstName, &l.LastName, &l.Email, &l.Phone,
			&l.Status, &l.Source, &l.Notes, &l.AssignedTo, &l.CreatedAt, &l.UpdatedAt); err == nil {
			out = append(out, l)
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "lead.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, out)
}

// ── Export ──────────────────────────────────────────────────────

// Export (GET /api/v1/leads/export.csv) — full active-lead CSV with
// optional status filter. PII (email, phone) included; gated by
// leads.export.
func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "leads.export") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !validStatuses[statusFilter] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, first_name, COALESCE(last_name,''), COALESCE(email,''),
		        COALESCE(phone,''), status, COALESCE(source,''), assigned_to, created_at
		 FROM leads
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND ($2='' OR status=$2)
		 ORDER BY created_at DESC`,
		bizID, statusFilter)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="leads-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "first_name", "last_name", "email", "phone",
		"status", "source", "assigned_to", "created_at"})

	for rows.Next() {
		var id uuid.UUID
		var first, last, email, phone, status, source string
		var assignedTo *uuid.UUID
		var createdAt time.Time
		if err := rows.Scan(&id, &first, &last, &email, &phone, &status, &source, &assignedTo, &createdAt); err != nil {
			continue
		}
		assignedStr := ""
		if assignedTo != nil {
			assignedStr = assignedTo.String()
		}
		_ = cw.Write([]string{
			id.String(), first, last, email, phone, status, source,
			assignedStr, createdAt.UTC().Format(time.RFC3339),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "lead",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Strict decoding ─────────────────────────────────────────────

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

// isStatusTransitionError reports whether the error came from the
// lead_status_guard trigger so callers can render a clean 409.
func isStatusTransitionError(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "invalid_status_transition") ||
		strings.Contains(err.Error(), "cannot_change_status_on_deleted_lead")
}

// maskedEmail masks the local part of an email for audit payloads.
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
