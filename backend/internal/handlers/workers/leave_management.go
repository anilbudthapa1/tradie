// Module 27 (Leave Management) — spec-compliance shim layered over
// the existing CreateLeaveRequest / ListLeaveRequests / ApproveLeave /
// RejectLeave methods on workers.Handler.
//
// Adds:
//   - requireLeavePermission() enforces leave.request / .approve /
//     .view / .manage / .export keys
//   - Spec audit names LEAVE_MANAGEMENT_MODULE_*
//   - leaveAuditAction() shared audit emitter
//   - MeLeaveView()           GET /api/v1/me/leave_management_module
//   - GetLeaveRequest()       GET /api/v1/payroll/leave-requests/{id}
//   - UpdateLeaveRequest()    PATCH /api/v1/payroll/leave-requests/{id}
//   - CancelLeaveRequest()    POST /api/v1/payroll/leave-requests/{id}/cancel
//   - ExportLeaveRequests()   GET /api/v1/payroll/leave-requests/export.csv
//   - decodeStrictLeave()     DisallowUnknownFields + 16 KiB body cap
//
// The Create / Approve / Reject methods on workers.go are also patched
// in-place to gate by permission, emit spec audit names, and validate
// inputs with the allow-list.
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
	AuditLeaveViewed       = "LEAVE_MANAGEMENT_MODULE_VIEWED"
	AuditLeaveCreated      = "LEAVE_MANAGEMENT_MODULE_CREATED"
	AuditLeaveUpdated      = "LEAVE_MANAGEMENT_MODULE_UPDATED"
	AuditLeaveDeleted      = "LEAVE_MANAGEMENT_MODULE_DELETED"
	AuditLeaveAccessDenied = "LEAVE_MANAGEMENT_MODULE_ACCESS_DENIED"
	AuditLeaveExported     = "LEAVE_MANAGEMENT_MODULE_EXPORTED"

	maxLeaveBodyBytes = 16 * 1024
)

var (
	allowedLeaveType = map[string]bool{
		"annual": true, "sick": true, "personal": true, "unpaid": true, "other": true,
	}
	allowedLeaveStatus = map[string]bool{
		"pending": true, "approved": true, "rejected": true, "cancelled": true,
	}
)

// ── Permission enforcement ──────────────────────────────────────

func (h *Handler) requireLeavePermission(w http.ResponseWriter, r *http.Request, key string) bool {
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
		h.log.Error("leave permission check", zap.String("key", key), zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "permission_check_failed"})
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditLeaveAccessDenied,
			EntityType: "leave_request",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:" + key})
		return false
	}
	return true
}

func (h *Handler) leaveAuditAction(r *http.Request, action string, id uuid.UUID, oldData, newData interface{}) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     action,
		EntityType: "leave_request",
		EntityID:   id,
		OldData:    oldData,
		NewData:    newData,
		IPAddress:  r.RemoteAddr,
	})
}

// canTouchLeaveRequest enforces ownership: non-managers can only act
// on their own row. Returns (worker_id, status, ok). On miss/forbidden
// it has already written the response.
func (h *Handler) canTouchLeaveRequest(w http.ResponseWriter, r *http.Request, id uuid.UUID) (uuid.UUID, string, bool) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var workerID uuid.UUID
	var status string
	err := h.db.QueryRow(r.Context(),
		`SELECT worker_id, status FROM leave_requests
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
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

// MeLeaveView (GET /api/v1/me/leave_management_module) returns the
// caller's leave requests in the last 12 months, plus aggregate days
// taken / days pending.
func (h *Handler) MeLeaveView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireLeavePermission(w, r, "leave.view") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, leave_type, start_date, end_date, days_count,
		        COALESCE(reason,''), status, COALESCE(rejection_reason,''),
		        approved_by, approved_at, created_at, updated_at
		 FROM leave_requests
		 WHERE business_id=$1 AND worker_id=$2 AND deleted_at IS NULL
		   AND start_date >= NOW() - INTERVAL '12 months'
		 ORDER BY start_date DESC LIMIT 200`,
		bizID, claims.UserID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	type req struct {
		ID              uuid.UUID  `json:"id"`
		LeaveType       string     `json:"leave_type"`
		StartDate       time.Time  `json:"start_date"`
		EndDate         time.Time  `json:"end_date"`
		DaysCount       int        `json:"days_count"`
		Reason          string     `json:"reason"`
		Status          string     `json:"status"`
		RejectionReason string     `json:"rejection_reason,omitempty"`
		ApprovedBy      *uuid.UUID `json:"approved_by"`
		ApprovedAt      *time.Time `json:"approved_at"`
		CreatedAt       time.Time  `json:"created_at"`
		UpdatedAt       time.Time  `json:"updated_at"`
	}
	out := []req{}
	var daysApproved, daysPending int
	for rows.Next() {
		var x req
		if err := rows.Scan(&x.ID, &x.LeaveType, &x.StartDate, &x.EndDate, &x.DaysCount,
			&x.Reason, &x.Status, &x.RejectionReason,
			&x.ApprovedBy, &x.ApprovedAt, &x.CreatedAt, &x.UpdatedAt); err != nil {
			continue
		}
		switch x.Status {
		case "approved":
			daysApproved += x.DaysCount
		case "pending":
			daysPending += x.DaysCount
		}
		out = append(out, x)
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditLeaveViewed,
		EntityType: "leave_request.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"requests":      out,
		"days_approved": daysApproved,
		"days_pending":  daysPending,
		"window_months": 12,
	})
}

// ── Get ─────────────────────────────────────────────────────────

// GetLeaveRequest (GET /api/v1/payroll/leave-requests/{id}).
func (h *Handler) GetLeaveRequest(w http.ResponseWriter, r *http.Request) {
	if !h.requireLeavePermission(w, r, "leave.view") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	_, _, ok := h.canTouchLeaveRequest(w, r, id)
	if !ok {
		return
	}

	bizID := middleware.BusinessIDFromCtx(r.Context())
	type req struct {
		ID              uuid.UUID  `json:"id"`
		WorkerID        uuid.UUID  `json:"worker_id"`
		LeaveType       string     `json:"leave_type"`
		StartDate       time.Time  `json:"start_date"`
		EndDate         time.Time  `json:"end_date"`
		DaysCount       int        `json:"days_count"`
		Reason          string     `json:"reason"`
		Status          string     `json:"status"`
		RejectionReason string     `json:"rejection_reason,omitempty"`
		ApprovedBy      *uuid.UUID `json:"approved_by"`
		ApprovedAt      *time.Time `json:"approved_at"`
		CreatedAt       time.Time  `json:"created_at"`
		UpdatedAt       time.Time  `json:"updated_at"`
	}
	var x req
	err = h.db.QueryRow(r.Context(),
		`SELECT id, worker_id, leave_type, start_date, end_date, days_count,
		        COALESCE(reason,''), status, COALESCE(rejection_reason,''),
		        approved_by, approved_at, created_at, updated_at
		 FROM leave_requests
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&x.ID, &x.WorkerID, &x.LeaveType, &x.StartDate, &x.EndDate, &x.DaysCount,
		&x.Reason, &x.Status, &x.RejectionReason,
		&x.ApprovedBy, &x.ApprovedAt, &x.CreatedAt, &x.UpdatedAt)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	respond(w, http.StatusOK, x)
}

// ── Update ──────────────────────────────────────────────────────

// UpdateLeaveRequest (PATCH /api/v1/payroll/leave-requests/{id}) —
// owner can only edit their own pending request; managers can edit
// pending or approved (e.g. to fix dates after approval).
func (h *Handler) UpdateLeaveRequest(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireLeavePermission(w, r, "leave.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	_, status, ok := h.canTouchLeaveRequest(w, r, id)
	if !ok {
		return
	}

	// Workers can only edit their own pending request.
	if !middleware.IsAtLeast(claims.Role, "manager") && status != "pending" {
		respond(w, http.StatusConflict, map[string]string{
			"error":  "cannot_edit",
			"status": status,
		})
		return
	}
	// Managers: cannot edit cancelled / rejected (terminal-ish).
	if status == "cancelled" || status == "rejected" {
		respond(w, http.StatusConflict, map[string]string{
			"error":  "cannot_edit",
			"status": status,
		})
		return
	}

	var req struct {
		LeaveType *string `json:"leave_type"`
		StartDate *string `json:"start_date"`
		EndDate   *string `json:"end_date"`
		Reason    *string `json:"reason"`
	}
	if err := decodeStrictLeave(r, &req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if req.LeaveType != nil && !allowedLeaveType[*req.LeaveType] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_leave_type"})
		return
	}
	// Validate the date pair if either is supplied. Must end >= start.
	var startD, endD *time.Time
	if req.StartDate != nil {
		t, err := time.Parse("2006-01-02", strings.TrimSpace(*req.StartDate))
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_start_date"})
			return
		}
		startD = &t
	}
	if req.EndDate != nil {
		t, err := time.Parse("2006-01-02", strings.TrimSpace(*req.EndDate))
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_end_date"})
			return
		}
		endD = &t
	}
	if startD != nil && endD != nil && endD.Before(*startD) {
		respond(w, http.StatusBadRequest, map[string]string{"error": "end_before_start"})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE leave_requests SET
		   leave_type = COALESCE($3, leave_type),
		   start_date = COALESCE($4::DATE, start_date),
		   end_date   = COALESCE($5::DATE, end_date),
		   days_count = (COALESCE($5::DATE, end_date) - COALESCE($4::DATE, start_date) + 1)::INT,
		   reason     = COALESCE($6, reason),
		   updated_by = $7,
		   updated_at = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.LeaveType,
		toStrPtr(startD), toStrPtr(endD),
		req.Reason, claims.UserID,
	)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "update_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}

	h.leaveAuditAction(r, AuditLeaveUpdated, id,
		map[string]interface{}{"status": status},
		map[string]interface{}{
			"leave_type": derefStrLeave(req.LeaveType),
			"start_date": derefStrLeave(req.StartDate),
			"end_date":   derefStrLeave(req.EndDate),
		})

	respond(w, http.StatusOK, map[string]string{"status": "updated"})
}

// ── Cancel ──────────────────────────────────────────────────────

// CancelLeaveRequest (POST /api/v1/payroll/leave-requests/{id}/cancel) —
// workers can withdraw their own pending request; managers can cancel
// any non-cancelled row.
func (h *Handler) CancelLeaveRequest(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireLeavePermission(w, r, "leave.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	_, status, ok := h.canTouchLeaveRequest(w, r, id)
	if !ok {
		return
	}
	if !middleware.IsAtLeast(claims.Role, "manager") && status != "pending" {
		respond(w, http.StatusConflict, map[string]string{
			"error":  "cannot_cancel",
			"status": status,
		})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE leave_requests
		   SET status='cancelled', updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status IN ('pending','approved','rejected')`,
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

	h.leaveAuditAction(r, AuditLeaveDeleted, id, nil,
		map[string]interface{}{"status": "cancelled"})

	respond(w, http.StatusOK, map[string]string{"id": id.String(), "status": "cancelled"})
}

// DeleteLeaveRequest (DELETE /api/v1/leave_management_module/{id}) soft
// deletes a leave row. Workers may delete only their own pending row;
// managers+ may soft-delete tenant rows for correction/admin cleanup.
func (h *Handler) DeleteLeaveRequest(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireLeavePermission(w, r, "leave.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	_, status, ok := h.canTouchLeaveRequest(w, r, id)
	if !ok {
		return
	}
	if !middleware.IsAtLeast(claims.Role, "manager") && status != "pending" {
		respond(w, http.StatusConflict, map[string]string{
			"error":  "cannot_delete",
			"status": status,
		})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE leave_requests
		   SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "delete_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}

	h.leaveAuditAction(r, AuditLeaveDeleted, id,
		map[string]interface{}{"status": status},
		map[string]interface{}{"deleted_at": "now"})

	w.WriteHeader(http.StatusNoContent)
}

// ── Export ──────────────────────────────────────────────────────

func (h *Handler) ExportLeaveRequests(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requireLeavePermission(w, r, "leave.export") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedLeaveStatus[statusFilter] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT lr.id, lr.worker_id,
		        COALESCE(u.first_name||' '||COALESCE(u.last_name,''), '') AS worker,
		        lr.leave_type, lr.start_date, lr.end_date, lr.days_count,
		        COALESCE(lr.reason,''), lr.status, COALESCE(lr.rejection_reason,''),
		        lr.created_at, lr.approved_at
		 FROM leave_requests lr
		 LEFT JOIN users u ON u.id=lr.worker_id
		 WHERE lr.business_id=$1 AND lr.deleted_at IS NULL
		   AND ($2='' OR lr.status=$2)
		 ORDER BY lr.start_date DESC LIMIT 10000`,
		bizID, statusFilter)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="leave-requests-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "worker_id", "worker", "leave_type",
		"start_date", "end_date", "days_count", "reason", "status",
		"rejection_reason", "created_at", "approved_at"})

	for rows.Next() {
		var id, workerID uuid.UUID
		var worker, leaveType, reason, status, rejection string
		var startD, endD time.Time
		var days int
		var createdAt time.Time
		var approvedAt *time.Time
		if err := rows.Scan(&id, &workerID, &worker, &leaveType, &startD, &endD,
			&days, &reason, &status, &rejection, &createdAt, &approvedAt); err != nil {
			continue
		}
		approvedStr := ""
		if approvedAt != nil {
			approvedStr = approvedAt.UTC().Format(time.RFC3339)
		}
		_ = cw.Write([]string{
			id.String(), workerID.String(), worker, leaveType,
			startD.Format("2006-01-02"), endD.Format("2006-01-02"),
			strconv.Itoa(days), reason, status, rejection,
			createdAt.UTC().Format(time.RFC3339), approvedStr,
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditLeaveExported,
		EntityType: "leave_request",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Strict decoding ─────────────────────────────────────────────

func decodeStrictLeave(r *http.Request, dst interface{}) error {
	r.Body = http.MaxBytesReader(nil, r.Body, maxLeaveBodyBytes)
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

func toStrPtr(t *time.Time) interface{} {
	if t == nil {
		return nil
	}
	return t.Format("2006-01-02")
}

func derefStrLeave(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
