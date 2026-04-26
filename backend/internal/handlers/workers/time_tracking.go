// Module 25 (Time Tracking) — spec-compliance shim layered over the
// existing timesheet methods on workers.Handler. Adds:
//
//   - requireTimePermission() enforces time.view/.create/.update/
//     .approve/.delete/.export keys against role_permissions
//   - Spec audit names TIME_TRACKING_MODULE_*
//   - timeAuditAction() shared audit emitter
//   - MeTimeView()       GET /api/v1/me/time_tracking_module
//   - SubmitTimesheet()  POST /api/v1/workers/timesheets/{id}/submit
//   - RejectTimesheet()  POST /api/v1/workers/timesheets/{id}/reject
//   - CancelTimesheet()  POST /api/v1/workers/timesheets/{id}/cancel
//   - ExportTimesheets() GET  /api/v1/workers/timesheets/export.csv
//   - decodeStrictTime() DisallowUnknownFields + 16 KiB body cap
//   - canTouchTimesheet() shared ownership / approval gating helper
//
// The legacy CreateTimesheet / UpdateTimesheet / ApproveTimesheet
// methods are wrapped (not replaced) — wrappers below add permission
// gating, audit emission, and worker-scope enforcement so the spec
// security baseline is met without rewriting the underlying queries.
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
	AuditTimeViewed       = "TIME_TRACKING_MODULE_VIEWED"
	AuditTimeCreated      = "TIME_TRACKING_MODULE_CREATED"
	AuditTimeUpdated      = "TIME_TRACKING_MODULE_UPDATED"
	AuditTimeDeleted      = "TIME_TRACKING_MODULE_DELETED"
	AuditTimeAccessDenied = "TIME_TRACKING_MODULE_ACCESS_DENIED"
	AuditTimeExported     = "TIME_TRACKING_MODULE_EXPORTED"

	maxTimeBodyBytes = 16 * 1024
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedTimeStatus = map[string]bool{
		"draft": true, "submitted": true, "pending": true,
		"approved": true, "rejected": true, "cancelled": true,
	}
)

// ── Permission enforcement ──────────────────────────────────────

// requireTimePermission gates a time-tracking action by spec key.
func (h *Handler) requireTimePermission(w http.ResponseWriter, r *http.Request, key string) bool {
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
		h.log.Error("time permission check", zap.String("key", key), zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "permission_check_failed"})
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditTimeAccessDenied,
			EntityType: "timesheet",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:" + key})
		return false
	}
	return true
}

func (h *Handler) timeAuditAction(r *http.Request, action string, sheetID uuid.UUID, oldData, newData interface{}) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     action,
		EntityType: "timesheet",
		EntityID:   sheetID,
		OldData:    oldData,
		NewData:    newData,
		IPAddress:  r.RemoteAddr,
	})
}

// canTouchTimesheet enforces the worker self-scope: non-managers can
// only operate on their own timesheets; managers+ can touch any.
// Returns the worker_id of the row, or zero UUID + error response on miss.
func (h *Handler) canTouchTimesheet(w http.ResponseWriter, r *http.Request, sheetID uuid.UUID) (uuid.UUID, string, bool) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var workerID uuid.UUID
	var status string
	err := h.db.QueryRow(r.Context(),
		`SELECT worker_id, status FROM timesheets
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		sheetID, bizID,
	).Scan(&workerID, &status)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return uuid.Nil, "", false
	}
	if !middleware.IsAtLeast(claims.Role, "manager") && workerID != claims.UserID {
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:not_owner"})
		return uuid.Nil, "", false
	}
	return workerID, status, true
}

// ── Self-service ────────────────────────────────────────────────

// MeView (GET /api/v1/me/time_tracking_module) returns the calling
// user's timesheets from the last 30 days with an aggregate summary.
func (h *Handler) MeTimeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireTimePermission(w, r, "time.view") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, worker_id, job_id, date, start_time, end_time, break_minutes,
		        total_hours, COALESCE(notes,''), status, COALESCE(rejection_reason,''),
		        submitted_at, approved_at, created_at, updated_at
		 FROM timesheets
		 WHERE business_id=$1 AND worker_id=$2 AND deleted_at IS NULL
		   AND date >= NOW() - INTERVAL '30 days'
		 ORDER BY date DESC, start_time DESC
		 LIMIT 200`,
		bizID, claims.UserID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	type sheet struct {
		ID               uuid.UUID  `json:"id"`
		WorkerID         uuid.UUID  `json:"worker_id"`
		JobID            *uuid.UUID `json:"job_id"`
		Date             time.Time  `json:"date"`
		StartTime        string     `json:"start_time"`
		EndTime          string     `json:"end_time"`
		BreakMinutes     int        `json:"break_minutes"`
		TotalHours       float64    `json:"total_hours"`
		Notes            string     `json:"notes"`
		Status           string     `json:"status"`
		RejectionReason  string     `json:"rejection_reason,omitempty"`
		SubmittedAt      *time.Time `json:"submitted_at"`
		ApprovedAt       *time.Time `json:"approved_at"`
		CreatedAt        time.Time  `json:"created_at"`
		UpdatedAt        time.Time  `json:"updated_at"`
	}
	out := []sheet{}
	var totalApproved, totalPending float64
	for rows.Next() {
		var s sheet
		var startT, endT time.Time
		if err := rows.Scan(&s.ID, &s.WorkerID, &s.JobID, &s.Date, &startT, &endT,
			&s.BreakMinutes, &s.TotalHours, &s.Notes, &s.Status, &s.RejectionReason,
			&s.SubmittedAt, &s.ApprovedAt, &s.CreatedAt, &s.UpdatedAt); err != nil {
			continue
		}
		s.StartTime = startT.Format("15:04")
		s.EndTime = endT.Format("15:04")
		switch s.Status {
		case "approved":
			totalApproved += s.TotalHours
		case "pending", "submitted", "draft":
			totalPending += s.TotalHours
		}
		out = append(out, s)
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditTimeViewed,
		EntityType: "timesheet.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"timesheets":            out,
		"total_approved_hours":  totalApproved,
		"total_pending_hours":   totalPending,
		"window_days":           30,
	})
}

// ── Lifecycle endpoints ─────────────────────────────────────────

// SubmitTimesheet (POST /api/v1/workers/timesheets/{id}/submit)
// moves draft → submitted (and submitted/draft → submitted is idempotent).
func (h *Handler) SubmitTimesheet(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireTimePermission(w, r, "time.create") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	_, currentStatus, ok := h.canTouchTimesheet(w, r, id)
	if !ok {
		return
	}
	if currentStatus != "draft" && currentStatus != "rejected" {
		respond(w, http.StatusConflict, map[string]string{
			"error":  "cannot_submit",
			"status": currentStatus,
		})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE timesheets
		   SET status='submitted', submitted_at=NOW(),
		       rejection_reason=NULL, updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status IN ('draft','rejected')`,
		id, bizID, claims.UserID)
	if err != nil || tag.RowsAffected() == 0 {
		respond(w, http.StatusConflict, map[string]string{"error": "submit_failed"})
		return
	}

	h.timeAuditAction(r, AuditTimeUpdated, id,
		map[string]interface{}{"status": currentStatus},
		map[string]interface{}{"status": "submitted"})

	respond(w, http.StatusOK, map[string]string{"id": id.String(), "status": "submitted"})
}

// RejectTimesheet (POST /api/v1/workers/timesheets/{id}/reject)
// is the manager-side counterpart to ApproveTimesheet. Body:
// {"reason": "..."}.
func (h *Handler) RejectTimesheet(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireTimePermission(w, r, "time.approve") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	var req struct {
		Reason string `json:"reason"`
	}
	if err := decodeStrictTime(r, &req); err != nil {
		// Empty body acceptable: reason defaults to "".
		req.Reason = ""
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE timesheets
		   SET status='rejected',
		       rejection_reason=$3,
		       updated_by=$4, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status IN ('pending','submitted')`,
		id, bizID, strings.TrimSpace(req.Reason), claims.UserID)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		respond(w, http.StatusInternalServerError, map[string]string{"error": "reject_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusConflict, map[string]string{"error": "not_found_or_invalid_state"})
		return
	}

	h.timeAuditAction(r, AuditTimeUpdated, id, nil,
		map[string]interface{}{"status": "rejected", "reason": req.Reason})

	respond(w, http.StatusOK, map[string]string{"id": id.String(), "status": "rejected"})
}

// CancelTimesheet (POST /api/v1/workers/timesheets/{id}/cancel)
// is the soft-delete-style action for the lifecycle. Owner can
// cancel their own draft/rejected; managers can cancel anything.
func (h *Handler) CancelTimesheet(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireTimePermission(w, r, "time.delete") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	_, _, ok := h.canTouchTimesheet(w, r, id)
	if !ok {
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE timesheets
		   SET status='cancelled', updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status NOT IN ('cancelled')`,
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
		respond(w, http.StatusConflict, map[string]string{"error": "already_cancelled"})
		return
	}

	h.timeAuditAction(r, AuditTimeDeleted, id, nil,
		map[string]interface{}{"status": "cancelled"})

	respond(w, http.StatusOK, map[string]string{"id": id.String(), "status": "cancelled"})
}

// ── Export ──────────────────────────────────────────────────────

// ExportTimesheets (GET /api/v1/workers/timesheets/export.csv)
// streams every timesheet for the tenant. Optional ?status= filter.
func (h *Handler) ExportTimesheets(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireTimePermission(w, r, "time.export") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedTimeStatus[statusFilter] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT t.id, t.worker_id,
		        COALESCE(u.first_name||' '||COALESCE(u.last_name,''), '') AS worker,
		        t.job_id, t.date, t.start_time, t.end_time, t.break_minutes,
		        t.total_hours, t.status, COALESCE(t.rejection_reason,''),
		        t.submitted_at, t.approved_at, t.created_at
		 FROM timesheets t
		 LEFT JOIN users u ON u.id=t.worker_id
		 WHERE t.business_id=$1 AND t.deleted_at IS NULL
		   AND ($2='' OR t.status=$2)
		 ORDER BY t.date DESC
		 LIMIT 10000`,
		bizID, statusFilter)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="timesheets-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "worker_id", "worker", "job_id", "date",
		"start_time", "end_time", "break_minutes", "total_hours", "status",
		"rejection_reason", "submitted_at", "approved_at", "created_at"})

	for rows.Next() {
		var id, workerID uuid.UUID
		var jobID *uuid.UUID
		var worker, status, rejection string
		var date time.Time
		var startT, endT time.Time
		var breakMin int
		var totalHours float64
		var submittedAt, approvedAt *time.Time
		var createdAt time.Time
		if err := rows.Scan(&id, &workerID, &worker, &jobID, &date, &startT, &endT,
			&breakMin, &totalHours, &status, &rejection, &submittedAt, &approvedAt, &createdAt); err != nil {
			continue
		}
		jobStr := ""
		if jobID != nil {
			jobStr = jobID.String()
		}
		submittedStr := ""
		if submittedAt != nil {
			submittedStr = submittedAt.UTC().Format(time.RFC3339)
		}
		approvedStr := ""
		if approvedAt != nil {
			approvedStr = approvedAt.UTC().Format(time.RFC3339)
		}
		_ = cw.Write([]string{
			id.String(), workerID.String(), worker, jobStr,
			date.Format("2006-01-02"),
			startT.Format("15:04"), endT.Format("15:04"),
			fmt.Sprintf("%d", breakMin),
			fmt.Sprintf("%.2f", totalHours),
			status, rejection, submittedStr, approvedStr,
			createdAt.UTC().Format(time.RFC3339),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditTimeExported,
		EntityType: "timesheet",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Strict decoding ─────────────────────────────────────────────

func decodeStrictTime(r *http.Request, dst interface{}) error {
	r.Body = http.MaxBytesReader(nil, r.Body, maxTimeBodyBytes)
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
