// Module 22 hardening — spec-compliance shim for the workers package.
//
// Adds what the legacy workers.go is missing per the Worker
// Management Module spec without rewriting it:
//
//   - requirePermission()  enforces employees.view / .create /
//                          .update / .delete / .export keys against
//                          the role_permissions catalog
//   - Spec audit names     WORKER_MANAGEMENT_MODULE_*
//   - MeView()             GET /api/v1/me/worker_management_module
//   - SetStatus()          POST /api/v1/workers/{id}/status
//   - Export()             GET /api/v1/workers/export.csv
//   - decodeStrict()       DisallowUnknownFields + 32 KiB body cap
//   - canAssignRole()      role-elevation guard so admin can't promote
//                          someone to owner
package workers

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
	"go.uber.org/zap"

	"github.com/tradie/api/internal/middleware"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditViewed       = "WORKER_MANAGEMENT_MODULE_VIEWED"
	AuditCreated      = "WORKER_MANAGEMENT_MODULE_CREATED"
	AuditUpdated      = "WORKER_MANAGEMENT_MODULE_UPDATED"
	AuditDeleted      = "WORKER_MANAGEMENT_MODULE_DELETED"
	AuditAccessDenied = "WORKER_MANAGEMENT_MODULE_ACCESS_DENIED"
	AuditExported     = "WORKER_MANAGEMENT_MODULE_EXPORTED"

	maxBodyBytes = 32 * 1024
)

// Allow-listed worker lifecycle (matches the DB CHECK constraint).
var allowedWorkerStatus = map[string]bool{
	"invited": true, "active": true, "suspended": true, "archived": true,
}

// Allow-listed roles a non-customer user can have. Customer is handled
// by the customers module and is not a "worker" in this context.
var allowedAssignableRole = map[string]bool{
	"owner": true, "admin": true, "manager": true, "worker": true, "accountant": true,
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
			EntityType: "worker",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:" + key})
		return false
	}
	return true
}

// auditModuleAction emits a spec-named audit event.
func (h *Handler) auditModuleAction(r *http.Request, action string, workerID uuid.UUID, oldData, newData interface{}) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     action,
		EntityType: "worker",
		EntityID:   workerID,
		OldData:    oldData,
		NewData:    newData,
		IPAddress:  r.RemoteAddr,
	})
}

// canAssignRole reports whether a caller with `callerRole` may assign
// `targetRole` to another worker. Rule: caller must be strictly above
// the target in the hierarchy (owner > admin > manager > worker =
// accountant > customer). This blocks an admin promoting someone to
// owner, or a manager promoting to admin.
func canAssignRole(callerRole, targetRole string) bool {
	if !allowedAssignableRole[targetRole] {
		return false
	}
	if !middleware.IsAtLeast(callerRole, "manager") {
		return false
	}
	// Caller must outrank the role they're granting.
	return middleware.IsAtLeast(callerRole, "admin") && targetRole != callerRole && callerOutranks(callerRole, targetRole)
}

// callerOutranks returns true when callerRole sits strictly above
// targetRole in the role ladder.
func callerOutranks(callerRole, targetRole string) bool {
	rank := func(role string) int {
		switch role {
		case "owner":
			return 5
		case "admin":
			return 4
		case "manager":
			return 3
		case "worker", "accountant":
			return 2
		case "customer":
			return 1
		default:
			return 0
		}
	}
	return rank(callerRole) > rank(targetRole)
}

// ── Self-service ────────────────────────────────────────────────

// MeView (GET /api/v1/me/worker_management_module) returns the
// calling user's own worker profile + a small operational snapshot
// (active jobs, pending timesheets). This is the safe surface for
// non-admin workers — they don't need access to /workers to see
// their own row.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "employees.view") {
		return
	}

	type meResp struct {
		ID            uuid.UUID `json:"id"`
		Email         string    `json:"email"`
		FirstName     string    `json:"first_name"`
		LastName      string    `json:"last_name"`
		Role          string    `json:"role"`
		Phone         *string   `json:"phone"`
		WorkerStatus  string    `json:"worker_status"`
		IsActive      bool      `json:"is_active"`
		IsVerified    bool      `json:"is_verified"`
		MFAEnabled    bool      `json:"mfa_enabled"`
		LastLoginAt   *time.Time `json:"last_login_at"`
		ActiveJobs    int        `json:"active_jobs"`
		CreatedAt     time.Time  `json:"created_at"`
	}
	var m meResp
	err := h.db.QueryRow(r.Context(),
		`SELECT u.id, u.email, u.first_name, u.last_name, u.role, u.phone,
		        u.worker_status, u.is_active, u.is_verified, u.mfa_enabled,
		        u.last_login_at, u.created_at,
		        (SELECT COUNT(*) FROM job_assignments ja
		           JOIN jobs j ON j.id=ja.job_id
		          WHERE ja.user_id=u.id
		            AND j.status NOT IN ('completed','cancelled')
		            AND j.business_id=$1) AS active_jobs
		 FROM users u
		 WHERE u.id=$2 AND u.business_id=$1 AND u.deleted_at IS NULL`,
		bizID, claims.UserID,
	).Scan(&m.ID, &m.Email, &m.FirstName, &m.LastName, &m.Role, &m.Phone,
		&m.WorkerStatus, &m.IsActive, &m.IsVerified, &m.MFAEnabled,
		&m.LastLoginAt, &m.CreatedAt, &m.ActiveJobs)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "worker.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, m)
}

// ── Status transitions ──────────────────────────────────────────

// SetStatus (POST /api/v1/workers/{id}/status) drives the worker
// lifecycle: invited → active ↔ suspended → archived. The DB trigger
// validates transitions; this returns clean 409s.
func (h *Handler) SetStatus(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "employees.update") {
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
	if !allowedWorkerStatus[req.Status] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	// Caller must outrank the target user — admin can't suspend the
	// owner. We also block self-suspension to avoid lockouts.
	if id == claims.UserID && req.Status != "active" {
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:cannot_modify_self"})
		return
	}
	var targetRole string
	var current string
	err = h.db.QueryRow(r.Context(),
		`SELECT role, worker_status FROM users
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND role <> 'customer'`,
		id, bizID,
	).Scan(&targetRole, &current)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if !callerOutranks(claims.Role, targetRole) {
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:target_outranks_caller"})
		return
	}

	if current == req.Status {
		respond(w, http.StatusOK, map[string]string{"message": "no_change", "status": current})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE users SET worker_status=$3, updated_by=$4, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Status, claims.UserID)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_worker_status_transition") {
			respond(w, http.StatusConflict, map[string]string{
				"error": "invalid_status_transition",
				"from":  current,
				"to":    req.Status,
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

	// Mirror to is_active so legacy queries stay coherent.
	switch req.Status {
	case "suspended", "archived":
		_, _ = h.db.Exec(r.Context(),
			`UPDATE users SET is_active=false WHERE id=$1 AND business_id=$2`, id, bizID)
	case "active":
		_, _ = h.db.Exec(r.Context(),
			`UPDATE users SET is_active=true WHERE id=$1 AND business_id=$2`, id, bizID)
	}

	h.auditModuleAction(r, AuditUpdated, id,
		map[string]interface{}{"worker_status": current},
		map[string]interface{}{"worker_status": req.Status})

	respond(w, http.StatusOK, map[string]interface{}{"id": id, "status": req.Status})
}

// ── Export ──────────────────────────────────────────────────────

// Export (GET /api/v1/workers/export.csv) — CSV of the worker roster,
// optionally filtered by status.
func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "employees.export") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedWorkerStatus[statusFilter] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, email, first_name, COALESCE(last_name,''), role, COALESCE(phone,''),
		        worker_status, is_active, is_verified, mfa_enabled, last_login_at, created_at
		 FROM users
		 WHERE business_id=$1 AND deleted_at IS NULL AND role <> 'customer'
		   AND ($2='' OR worker_status=$2)
		 ORDER BY first_name`,
		bizID, statusFilter)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="workers-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "email", "first_name", "last_name", "role", "phone",
		"worker_status", "is_active", "is_verified", "mfa_enabled", "last_login_at", "created_at"})

	for rows.Next() {
		var id uuid.UUID
		var email, first, last, role, phone, status string
		var active, verified, mfa bool
		var lastLogin *time.Time
		var createdAt time.Time
		if err := rows.Scan(&id, &email, &first, &last, &role, &phone,
			&status, &active, &verified, &mfa, &lastLogin, &createdAt); err != nil {
			continue
		}
		lastStr := ""
		if lastLogin != nil {
			lastStr = lastLogin.UTC().Format(time.RFC3339)
		}
		_ = cw.Write([]string{
			id.String(), email, first, last, role, phone,
			status,
			boolStr(active), boolStr(verified), boolStr(mfa),
			lastStr, createdAt.UTC().Format(time.RFC3339),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "worker",
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

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
