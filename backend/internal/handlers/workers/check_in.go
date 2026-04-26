// Module 26 (Check-In Check-Out) — spec-compliance shim layered
// over the existing CheckIn/CheckOut methods.
//
// The legacy methods on workers.go had a real bug: both read
// chi.URLParam(r, "id") on routes that had no :id param, so user_id
// was always "" and inserts failed silently or never matched. This
// shim adds:
//
//   - requireCheckInPermission()  enforces checkin.create / checkout.create /
//                                .view / .manage / .export
//   - Spec audit names CHECK_IN_CHECK_OUT_MODULE_*
//   - checkInAuditAction()       shared audit emitter
//   - MeCheckInView()            GET /api/v1/me/check_in_check_out_module
//   - ListCheckIns / GetCheckIn  manager+ surface
//   - CancelCheckIn              cancel the active row
//   - ExportCheckIns             CSV export
//   - decodeStrictCheckIn        DisallowUnknownFields + 8 KiB body cap
//
// The CheckIn / CheckOut methods themselves are rewritten in this
// file (overwriting the legacy versions in workers.go via a separate
// edit) so they use claims.UserID (the actual caller) instead of the
// always-empty URL param.
package workers

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
	"go.uber.org/zap"

	"github.com/tradie/api/internal/middleware"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditCheckInViewed       = "CHECK_IN_CHECK_OUT_MODULE_VIEWED"
	AuditCheckInCreated      = "CHECK_IN_CHECK_OUT_MODULE_CREATED"
	AuditCheckInUpdated      = "CHECK_IN_CHECK_OUT_MODULE_UPDATED"
	AuditCheckInDeleted      = "CHECK_IN_CHECK_OUT_MODULE_DELETED"
	AuditCheckInAccessDenied = "CHECK_IN_CHECK_OUT_MODULE_ACCESS_DENIED"
	AuditCheckInExported     = "CHECK_IN_CHECK_OUT_MODULE_EXPORTED"

	maxCheckInBodyBytes = 8 * 1024
)

var allowedCheckInStatus = map[string]bool{
	"active": true, "closed": true, "cancelled": true,
}

// ── Permission enforcement ──────────────────────────────────────

func (h *Handler) requireCheckInPermission(w http.ResponseWriter, r *http.Request, key string) bool {
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
		h.log.Error("checkin permission check", zap.String("key", key), zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "permission_check_failed"})
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditCheckInAccessDenied,
			EntityType: "worker_check_in",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:" + key})
		return false
	}
	return true
}

func (h *Handler) checkInAuditAction(r *http.Request, action string, id uuid.UUID, oldData, newData interface{}) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     action,
		EntityType: "worker_check_in",
		EntityID:   id,
		OldData:    oldData,
		NewData:    newData,
		IPAddress:  r.RemoteAddr,
	})
}

// ── List / Get ──────────────────────────────────────────────────

// ListCheckIns (GET /api/v1/workers/check-ins?status=&job_id=&user_id=&from=&to=)
// Workers see only their own; managers+ see the whole tenant.
func (h *Handler) ListCheckIns(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireCheckInPermission(w, r, "checkin.view") {
		return
	}

	q := r.URL.Query()
	statusFilter := strings.TrimSpace(q.Get("status"))
	if statusFilter != "" && !allowedCheckInStatus[statusFilter] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}
	args := []interface{}{bizID}
	filters := []string{"business_id=$1", "deleted_at IS NULL"}
	next := 2

	// Workers pinned to self.
	if !middleware.IsAtLeast(claims.Role, "manager") {
		filters = append(filters, "user_id=$"+strconv.Itoa(next))
		args = append(args, claims.UserID)
		next++
	} else if v := strings.TrimSpace(q.Get("user_id")); v != "" {
		uid, err := uuid.Parse(v)
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_user_id"})
			return
		}
		filters = append(filters, "user_id=$"+strconv.Itoa(next))
		args = append(args, uid)
		next++
	}
	if statusFilter != "" {
		filters = append(filters, "status=$"+strconv.Itoa(next))
		args = append(args, statusFilter)
		next++
	}
	if v := strings.TrimSpace(q.Get("job_id")); v != "" {
		jid, err := uuid.Parse(v)
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_job_id"})
			return
		}
		filters = append(filters, "job_id=$"+strconv.Itoa(next))
		args = append(args, jid)
		next++
	}
	if v := strings.TrimSpace(q.Get("from")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_from"})
			return
		}
		filters = append(filters, "checked_in_at >= $"+strconv.Itoa(next))
		args = append(args, t)
		next++
	}
	if v := strings.TrimSpace(q.Get("to")); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_to"})
			return
		}
		filters = append(filters, "checked_in_at <= $"+strconv.Itoa(next))
		args = append(args, t)
		next++
	}
	limit := 200
	if v := q.Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}
	args = append(args, limit)
	limitParam := next

	sql := `SELECT id, business_id, user_id, job_id, lat, lng, accuracy_m,
	               COALESCE(notes,''), status, checked_in_at, checked_out_at,
	               COALESCE(duration_minutes, 0), created_by, updated_by, created_at, updated_at
	        FROM worker_check_ins
	        WHERE ` + strings.Join(filters, " AND ") + `
	        ORDER BY checked_in_at DESC
	        LIMIT $` + strconv.Itoa(limitParam)

	rows, err := h.db.Query(r.Context(), sql, args...)
	if err != nil {
		h.log.Error("list check-ins", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	type row struct {
		ID              uuid.UUID  `json:"id"`
		BusinessID      uuid.UUID  `json:"-"`
		UserID          uuid.UUID  `json:"user_id"`
		JobID           *uuid.UUID `json:"job_id"`
		Lat             *float64   `json:"lat"`
		Lng             *float64   `json:"lng"`
		AccuracyM       *float64   `json:"accuracy_m"`
		Notes           string     `json:"notes"`
		Status          string     `json:"status"`
		CheckedInAt     time.Time  `json:"checked_in_at"`
		CheckedOutAt    *time.Time `json:"checked_out_at"`
		DurationMinutes int        `json:"duration_minutes"`
		CreatedBy       *uuid.UUID `json:"created_by"`
		UpdatedBy       *uuid.UUID `json:"updated_by"`
		CreatedAt       time.Time  `json:"created_at"`
		UpdatedAt       time.Time  `json:"updated_at"`
	}
	out := []row{}
	for rows.Next() {
		var x row
		if err := rows.Scan(&x.ID, &x.BusinessID, &x.UserID, &x.JobID,
			&x.Lat, &x.Lng, &x.AccuracyM, &x.Notes, &x.Status,
			&x.CheckedInAt, &x.CheckedOutAt, &x.DurationMinutes,
			&x.CreatedBy, &x.UpdatedBy, &x.CreatedAt, &x.UpdatedAt); err == nil {
			out = append(out, x)
		}
	}
	respond(w, http.StatusOK, out)
}

// GetCheckIn (GET /api/v1/workers/check-ins/{id}).
func (h *Handler) GetCheckIn(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireCheckInPermission(w, r, "checkin.view") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	type row struct {
		ID              uuid.UUID  `json:"id"`
		UserID          uuid.UUID  `json:"user_id"`
		JobID           *uuid.UUID `json:"job_id"`
		Lat             *float64   `json:"lat"`
		Lng             *float64   `json:"lng"`
		AccuracyM       *float64   `json:"accuracy_m"`
		Notes           string     `json:"notes"`
		Status          string     `json:"status"`
		CheckedInAt     time.Time  `json:"checked_in_at"`
		CheckedOutAt    *time.Time `json:"checked_out_at"`
		DurationMinutes int        `json:"duration_minutes"`
	}
	var x row
	err = h.db.QueryRow(r.Context(),
		`SELECT id, user_id, job_id, lat, lng, accuracy_m, COALESCE(notes,''),
		        status, checked_in_at, checked_out_at, COALESCE(duration_minutes,0)
		 FROM worker_check_ins
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&x.ID, &x.UserID, &x.JobID, &x.Lat, &x.Lng, &x.AccuracyM,
		&x.Notes, &x.Status, &x.CheckedInAt, &x.CheckedOutAt, &x.DurationMinutes)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if !middleware.IsAtLeast(claims.Role, "manager") && x.UserID != claims.UserID {
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:not_owner"})
		return
	}
	respond(w, http.StatusOK, x)
}

// CancelCheckIn (POST /api/v1/workers/check-ins/{id}/cancel) — workers
// can cancel their own active row (e.g. miscclick); managers can cancel any.
func (h *Handler) CancelCheckIn(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireCheckInPermission(w, r, "checkin.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	// Ownership check for non-managers.
	var ownerID uuid.UUID
	var status string
	err = h.db.QueryRow(r.Context(),
		`SELECT user_id, status FROM worker_check_ins
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&ownerID, &status)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if !middleware.IsAtLeast(claims.Role, "manager") && ownerID != claims.UserID {
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:not_owner"})
		return
	}
	if status != "active" {
		respond(w, http.StatusConflict, map[string]string{
			"error": "cannot_cancel", "status": status,
		})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE worker_check_ins
		   SET status='cancelled', updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND status='active'`,
		id, bizID, claims.UserID)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		respond(w, http.StatusInternalServerError, map[string]string{"error": "cancel_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusConflict, map[string]string{"error": "already_terminal"})
		return
	}

	h.checkInAuditAction(r, AuditCheckInDeleted, id, nil,
		map[string]interface{}{"status": "cancelled"})

	respond(w, http.StatusOK, map[string]string{"id": id.String(), "status": "cancelled"})
}

// ── Self-service ────────────────────────────────────────────────

// MeCheckInView (GET /api/v1/me/check_in_check_out_module) returns
// the caller's currently-active check-in (if any) and the last 30
// closed/cancelled rows.
func (h *Handler) MeCheckInView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireCheckInPermission(w, r, "checkin.view") {
		return
	}

	type row struct {
		ID              uuid.UUID  `json:"id"`
		JobID           *uuid.UUID `json:"job_id"`
		Lat             *float64   `json:"lat"`
		Lng             *float64   `json:"lng"`
		AccuracyM       *float64   `json:"accuracy_m"`
		Notes           string     `json:"notes"`
		Status          string     `json:"status"`
		CheckedInAt     time.Time  `json:"checked_in_at"`
		CheckedOutAt    *time.Time `json:"checked_out_at"`
		DurationMinutes int        `json:"duration_minutes"`
	}
	var active *row

	r1 := h.db.QueryRow(r.Context(),
		`SELECT id, job_id, lat, lng, accuracy_m, COALESCE(notes,''),
		        status, checked_in_at, checked_out_at, COALESCE(duration_minutes,0)
		 FROM worker_check_ins
		 WHERE business_id=$1 AND user_id=$2 AND status='active' AND deleted_at IS NULL
		 ORDER BY checked_in_at DESC LIMIT 1`,
		bizID, claims.UserID)
	var act row
	if err := r1.Scan(&act.ID, &act.JobID, &act.Lat, &act.Lng, &act.AccuracyM,
		&act.Notes, &act.Status, &act.CheckedInAt, &act.CheckedOutAt, &act.DurationMinutes); err == nil {
		active = &act
	}

	hist := []row{}
	rows, err := h.db.Query(r.Context(),
		`SELECT id, job_id, lat, lng, accuracy_m, COALESCE(notes,''),
		        status, checked_in_at, checked_out_at, COALESCE(duration_minutes,0)
		 FROM worker_check_ins
		 WHERE business_id=$1 AND user_id=$2 AND deleted_at IS NULL
		   AND status IN ('closed','cancelled')
		 ORDER BY checked_in_at DESC LIMIT 30`,
		bizID, claims.UserID)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var x row
			if err := rows.Scan(&x.ID, &x.JobID, &x.Lat, &x.Lng, &x.AccuracyM,
				&x.Notes, &x.Status, &x.CheckedInAt, &x.CheckedOutAt, &x.DurationMinutes); err == nil {
				hist = append(hist, x)
			}
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCheckInViewed,
		EntityType: "worker_check_in.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"active":  active,
		"history": hist,
	})
}

// ── Export ──────────────────────────────────────────────────────

func (h *Handler) ExportCheckIns(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireCheckInPermission(w, r, "checkin.export") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedCheckInStatus[statusFilter] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT ci.id, ci.user_id,
		        COALESCE(u.first_name||' '||COALESCE(u.last_name,''), '') AS worker,
		        ci.job_id, ci.lat, ci.lng, COALESCE(ci.notes,''),
		        ci.status, ci.checked_in_at, ci.checked_out_at, COALESCE(ci.duration_minutes,0)
		 FROM worker_check_ins ci
		 LEFT JOIN users u ON u.id=ci.user_id
		 WHERE ci.business_id=$1 AND ci.deleted_at IS NULL
		   AND ($2='' OR ci.status=$2)
		 ORDER BY ci.checked_in_at DESC LIMIT 10000`,
		bizID, statusFilter)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="check-ins-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "user_id", "worker", "job_id", "lat", "lng",
		"notes", "status", "checked_in_at", "checked_out_at", "duration_minutes"})

	for rows.Next() {
		var id, userID uuid.UUID
		var jobID *uuid.UUID
		var worker, notes, status string
		var lat, lng *float64
		var checkedIn time.Time
		var checkedOut *time.Time
		var duration int
		if err := rows.Scan(&id, &userID, &worker, &jobID, &lat, &lng, &notes,
			&status, &checkedIn, &checkedOut, &duration); err != nil {
			continue
		}
		jobStr := ""
		if jobID != nil {
			jobStr = jobID.String()
		}
		latStr, lngStr := "", ""
		if lat != nil {
			latStr = strconv.FormatFloat(*lat, 'f', 6, 64)
		}
		if lng != nil {
			lngStr = strconv.FormatFloat(*lng, 'f', 6, 64)
		}
		outStr := ""
		if checkedOut != nil {
			outStr = checkedOut.UTC().Format(time.RFC3339)
		}
		_ = cw.Write([]string{
			id.String(), userID.String(), worker, jobStr, latStr, lngStr, notes,
			status, checkedIn.UTC().Format(time.RFC3339), outStr,
			strconv.Itoa(duration),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCheckInExported,
		EntityType: "worker_check_in",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Strict decoding ─────────────────────────────────────────────

func decodeStrictCheckIn(r *http.Request, dst interface{}) error {
	r.Body = http.MaxBytesReader(nil, r.Body, maxCheckInBodyBytes)
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
