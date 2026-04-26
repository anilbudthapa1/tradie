package workers

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

func (h *Handler) RegisterPayrollRoutes(r chi.Router) {
	r.Route("/api/v1/payroll", func(r chi.Router) {
		// Self-service: any authenticated tenant user. Handlers enforce
		// caller-vs-target checks (e.g. employees see only their own payslips).
		r.Get("/payslips", h.ListPayslips)
		r.Get("/payslips/{id}/pdf", h.GeneratePayslipPDF)
		r.Post("/leave-requests", h.CreateLeaveRequest)
		r.Get("/leave-requests", h.ListLeaveRequests)
		r.Get("/leave-requests/export.csv", h.ExportLeaveRequests)  // M27
		r.Get("/leave-requests/{id}", h.GetLeaveRequest)            // M27
		r.Patch("/leave-requests/{id}", h.UpdateLeaveRequest)       // M27
		r.Post("/leave-requests/{id}/cancel", h.CancelLeaveRequest) // M27

		// Manager+ reads: pay run summaries and super tracking are sensitive
		// across the whole business and are restricted to manager and above.
		r.Group(func(r chi.Router) {
			r.Use(middleware.RequireAtLeast("manager"))
			r.Get("/runs", h.ListPayRuns)
			r.Get("/runs/{id}", h.GetPayRun)
			r.Get("/runs/export.csv", h.ExportPayRuns) // M28
			r.Get("/superannuation", h.ListSuper)
		})

		// Owner/Admin only: pay run mutations and leave approval/rejection.
		r.Group(func(r chi.Router) {
			r.Use(middleware.RequireOwnerOrAdmin())
			r.Post("/runs", h.CreatePayRun)
			r.Post("/runs/{id}/process", h.ProcessPayRun)
			r.Post("/runs/{id}/pay", h.MarkPayRunPaid)  // M28
			r.Post("/runs/{id}/cancel", h.CancelPayRun) // M28
			r.Post("/leave-requests/{id}/approve", h.ApproveLeave)
			r.Post("/leave-requests/{id}/reject", h.RejectLeave)
		})
	})
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "employees.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(),
		`SELECT u.id, u.email, u.first_name, u.last_name, u.role, u.phone,
		        u.is_active, u.worker_status, u.created_at
		 FROM users u WHERE u.business_id=$1 AND u.deleted_at IS NULL AND u.role != 'customer'
		 ORDER BY u.first_name ASC`, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()
	var workers []map[string]interface{}
	for rows.Next() {
		w2 := make(map[string]interface{})
		var id, email, first, last, role, workerStatus string
		var phone interface{}
		var active bool
		var createdAt interface{}
		if err := rows.Scan(&id, &email, &first, &last, &role, &phone, &active, &workerStatus, &createdAt); err != nil {
			continue
		}
		w2["id"] = id
		w2["email"] = email
		w2["first_name"] = first
		w2["last_name"] = last
		w2["role"] = role
		w2["phone"] = phone
		w2["is_active"] = active
		w2["worker_status"] = workerStatus
		w2["created_at"] = createdAt
		workers = append(workers, w2)
	}
	if workers == nil {
		workers = []map[string]interface{}{}
	}
	respond(w, 200, workers)
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "employees.create") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	var req struct {
		FirstName string  `json:"first_name"`
		LastName  string  `json:"last_name"`
		Email     string  `json:"email"`
		Phone     *string `json:"phone"`
		Role      string  `json:"role"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respond(w, 400, map[string]string{"error": err.Error()})
		return
	}
	if req.FirstName == "" || req.Email == "" {
		respond(w, 400, map[string]string{"error": "first_name_and_email_required"})
		return
	}
	// Role allow-list AND caller-must-outrank check. The hierarchy
	// gate prevents an admin from creating an owner peer.
	if !canAssignRole(claims.Role, req.Role) {
		respond(w, 403, map[string]string{"error": "forbidden:role_not_assignable"})
		return
	}

	newID := uuid.New()
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO users (id, business_id, created_by, email, first_name, last_name, phone, role,
		                    is_active, is_verified, worker_status, invited_at, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,true,false,'invited',NOW(),NOW(),NOW())
		 ON CONFLICT (email, business_id) DO NOTHING
		 RETURNING id`,
		newID, bizID, claims.UserID, req.Email, req.FirstName, req.LastName, req.Phone, req.Role,
	).Scan(&newID)
	if err != nil {
		respond(w, 409, map[string]string{"error": "email_already_exists"})
		return
	}

	result := map[string]interface{}{
		"id": newID, "email": req.Email, "first_name": req.FirstName,
		"last_name": req.LastName, "role": req.Role, "phone": req.Phone,
		"worker_status": "invited", "is_active": true, "invite_sent": true,
	}

	h.auditModuleAction(r, AuditCreated, newID, nil, map[string]interface{}{
		"email": req.Email, "role": req.Role, "first_name": req.FirstName,
	})
	respond(w, 201, result)
}

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "employees.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var worker struct {
		ID         string      `json:"id"`
		Email      string      `json:"email"`
		FirstName  string      `json:"first_name"`
		LastName   string      `json:"last_name"`
		Role       string      `json:"role"`
		Phone      interface{} `json:"phone"`
		IsActive   bool        `json:"is_active"`
		CreatedAt  time.Time   `json:"created_at"`
		ActiveJobs int         `json:"active_jobs"`
	}
	err := h.db.QueryRow(r.Context(),
		`SELECT u.id, u.email, u.first_name, u.last_name, u.role, u.phone, u.is_active, u.created_at,
		 (SELECT COUNT(*) FROM job_assignments ja JOIN jobs j ON j.id=ja.job_id
		  WHERE ja.worker_id=u.id AND j.status NOT IN ('completed','cancelled') AND j.business_id=$1) as active_jobs
		 FROM users u WHERE u.id=$2 AND u.business_id=$1 AND u.deleted_at IS NULL`,
		bizID, id,
	).Scan(&worker.ID, &worker.Email, &worker.FirstName, &worker.LastName, &worker.Role,
		&worker.Phone, &worker.IsActive, &worker.CreatedAt, &worker.ActiveJobs)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, worker)
}

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "employees.update") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	idStr := chi.URLParam(r, "id")
	id, err := uuid.Parse(idStr)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	var req struct {
		FirstName *string `json:"first_name"`
		LastName  *string `json:"last_name"`
		Phone     *string `json:"phone"`
		Role      *string `json:"role"`
		IsActive  *bool   `json:"is_active"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respond(w, 400, map[string]string{"error": err.Error()})
		return
	}

	// Snapshot for hierarchy check + audit.
	var oldRole, oldStatus string
	err = h.db.QueryRow(r.Context(),
		`SELECT role, worker_status FROM users
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND role <> 'customer'`,
		id, bizID,
	).Scan(&oldRole, &oldStatus)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	// Caller must outrank the current target. Blocks admin → editing owner.
	if !callerOutranks(claims.Role, oldRole) && id != claims.UserID {
		respond(w, 403, map[string]string{"error": "forbidden:target_outranks_caller"})
		return
	}
	// Role change: caller must also outrank the requested role.
	if req.Role != nil && *req.Role != oldRole {
		if !canAssignRole(claims.Role, *req.Role) {
			respond(w, 403, map[string]string{"error": "forbidden:role_not_assignable"})
			return
		}
	}

	_, err = h.db.Exec(r.Context(),
		`UPDATE users SET
		 first_name = COALESCE($3, first_name),
		 last_name = COALESCE($4, last_name),
		 phone = COALESCE($5, phone),
		 role = COALESCE($6, role),
		 is_active = COALESCE($7, is_active),
		 updated_by = $8,
		 updated_at = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.FirstName, req.LastName, req.Phone, req.Role, req.IsActive, claims.UserID,
	)
	if err != nil {
		h.log.Error("update worker", zap.Error(err))
		respond(w, 500, map[string]string{"error": "update_failed"})
		return
	}

	h.auditModuleAction(r, AuditUpdated, id,
		map[string]interface{}{"role": oldRole, "worker_status": oldStatus},
		map[string]interface{}{"role": req.Role, "is_active": req.IsActive})

	respond(w, 200, map[string]string{"status": "updated"})
}

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "employees.delete") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	idStr := chi.URLParam(r, "id")
	id, err := uuid.Parse(idStr)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	if id == claims.UserID {
		respond(w, 403, map[string]string{"error": "forbidden:cannot_delete_self"})
		return
	}

	// Caller must outrank the target.
	var targetRole string
	err = h.db.QueryRow(r.Context(),
		`SELECT role FROM users
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND role <> 'customer'`,
		id, bizID,
	).Scan(&targetRole)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if !callerOutranks(claims.Role, targetRole) {
		respond(w, 403, map[string]string{"error": "forbidden:target_outranks_caller"})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE users
		   SET deleted_at=NOW(), is_active=false, worker_status='archived',
		       updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "delete_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	h.auditModuleAction(r, AuditDeleted, id, nil, nil)
	respond(w, 204, nil)
}

func (h *Handler) Invite(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var email string
	err := h.db.QueryRow(r.Context(),
		`SELECT email FROM users WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&email)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, map[string]string{"status": "invite_sent", "email": email})
}

func (h *Handler) GetTimesheets(w http.ResponseWriter, r *http.Request) {
	if !h.requireTimePermission(w, r, "time.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	rows, err := h.db.Query(r.Context(),
		`SELECT id, worker_id, job_id, date, start_time, end_time, break_minutes, total_hours, notes, status, created_at
		 FROM timesheets WHERE business_id=$1 AND worker_id=$2 ORDER BY date DESC LIMIT 100`,
		bizID, id,
	)
	if err != nil {
		respond(w, 200, []interface{}{})
		return
	}
	defer rows.Close()
	var list []map[string]interface{}
	for rows.Next() {
		m := make(map[string]interface{})
		var tsID, workerID string
		var jobID interface{}
		var date, startTime, endTime interface{}
		var breakMins int
		var totalHours float64
		var notes interface{}
		var status string
		var createdAt time.Time
		_ = rows.Scan(&tsID, &workerID, &jobID, &date, &startTime, &endTime, &breakMins, &totalHours, &notes, &status, &createdAt)
		m["id"] = tsID
		m["worker_id"] = workerID
		m["job_id"] = jobID
		m["date"] = date
		m["start_time"] = startTime
		m["end_time"] = endTime
		m["break_minutes"] = breakMins
		m["total_hours"] = totalHours
		m["notes"] = notes
		m["status"] = status
		m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) GetPayslips(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	rows, err := h.db.Query(r.Context(),
		`SELECT id, pay_run_id, gross_pay, tax_withheld, net_pay, super_amount, period_start, period_end, created_at
		 FROM payslips WHERE business_id=$1 AND worker_id=$2 ORDER BY period_start DESC`,
		bizID, id,
	)
	if err != nil {
		respond(w, 200, []interface{}{})
		return
	}
	defer rows.Close()
	var list []map[string]interface{}
	for rows.Next() {
		m := make(map[string]interface{})
		var psID, payRunID string
		var gross, tax, net, super float64
		var periodStart, periodEnd interface{}
		var createdAt time.Time
		_ = rows.Scan(&psID, &payRunID, &gross, &tax, &net, &super, &periodStart, &periodEnd, &createdAt)
		m["id"] = psID
		m["pay_run_id"] = payRunID
		m["gross_pay"] = gross
		m["tax_withheld"] = tax
		m["net_pay"] = net
		m["super_amount"] = super
		m["period_start"] = periodStart
		m["period_end"] = periodEnd
		m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) GetAvailability(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	rows, err := h.db.Query(r.Context(),
		`SELECT id, day_of_week, start_time, end_time, is_available
		 FROM worker_availability WHERE business_id=$1 AND user_id=$2 ORDER BY day_of_week ASC`,
		bizID, id,
	)
	if err != nil {
		respond(w, 200, []interface{}{})
		return
	}
	defer rows.Close()
	var slots []map[string]interface{}
	for rows.Next() {
		m := make(map[string]interface{})
		var slotID string
		var day int
		var startTime, endTime interface{}
		var isAvail bool
		_ = rows.Scan(&slotID, &day, &startTime, &endTime, &isAvail)
		m["id"] = slotID
		m["day_of_week"] = day
		m["start_time"] = startTime
		m["end_time"] = endTime
		m["is_available"] = isAvail
		slots = append(slots, m)
	}
	if slots == nil {
		slots = []map[string]interface{}{}
	}
	respond(w, 200, slots)
}

func (h *Handler) UpdateAvailability(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var req []struct {
		DayOfWeek   int    `json:"day_of_week"`
		StartTime   string `json:"start_time"`
		EndTime     string `json:"end_time"`
		IsAvailable bool   `json:"is_available"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	for _, slot := range req {
		newID := uuid.New()
		_, _ = h.db.Exec(r.Context(),
			`INSERT INTO worker_availability (id, business_id, user_id, day_of_week, start_time, end_time, is_available, created_at, updated_at)
			 VALUES ($1,$2,$3,$4,$5::TIME,$6::TIME,$7,NOW(),NOW())
			 ON CONFLICT (business_id, user_id, day_of_week)
			 DO UPDATE SET start_time=EXCLUDED.start_time, end_time=EXCLUDED.end_time, is_available=EXCLUDED.is_available, updated_at=NOW()`,
			newID, bizID, id, slot.DayOfWeek, slot.StartTime, slot.EndTime, slot.IsAvailable,
		)
	}
	respond(w, 200, map[string]string{"status": "updated"})
}

func (h *Handler) GetPerformance(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var totalJobs, completedJobs int
	var avgHours float64
	_ = h.db.QueryRow(r.Context(),
		`SELECT
		 COUNT(*) as total,
		 COUNT(*) FILTER (WHERE j.status='completed') as completed,
		 COALESCE(AVG(EXTRACT(EPOCH FROM (j.actual_end - j.actual_start))/3600) FILTER (WHERE j.actual_end IS NOT NULL AND j.actual_start IS NOT NULL), 0) as avg_hours
		 FROM job_assignments ja
		 JOIN jobs j ON j.id = ja.job_id
		 WHERE ja.worker_id=$1 AND j.business_id=$2`,
		id, bizID,
	).Scan(&totalJobs, &completedJobs, &avgHours)

	completionRate := 0.0
	if totalJobs > 0 {
		completionRate = math.Round(float64(completedJobs)/float64(totalJobs)*100*10) / 10
	}

	var onTimeCount int
	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM job_assignments ja JOIN jobs j ON j.id=ja.job_id
		 WHERE ja.worker_id=$1 AND j.business_id=$2 AND j.status='completed'
		 AND j.actual_end <= j.scheduled_end`,
		id, bizID,
	).Scan(&onTimeCount)

	onTimeRate := 0.0
	if completedJobs > 0 {
		onTimeRate = math.Round(float64(onTimeCount)/float64(completedJobs)*100*10) / 10
	}

	respond(w, 200, map[string]interface{}{
		"total_jobs":      totalJobs,
		"completed_jobs":  completedJobs,
		"completion_rate": completionRate,
		"avg_hours":       math.Round(avgHours*100) / 100,
		"on_time_rate":    onTimeRate,
	})
}

func (h *Handler) GetLocation(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var lat, lng float64
	var accuracy interface{}
	var recordedAt time.Time
	err := h.db.QueryRow(r.Context(),
		`SELECT lat, lng, accuracy, recorded_at FROM worker_locations
		 WHERE business_id=$1 AND user_id=$2 ORDER BY recorded_at DESC LIMIT 1`,
		bizID, id,
	).Scan(&lat, &lng, &accuracy, &recordedAt)
	if err != nil {
		respond(w, 200, map[string]interface{}{"lat": nil, "lng": nil})
		return
	}
	respond(w, 200, map[string]interface{}{
		"lat": lat, "lng": lng, "accuracy": accuracy, "recorded_at": recordedAt,
	})
}

func (h *Handler) UpdateLocation(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var req struct {
		Lat      float64  `json:"lat"`
		Lng      float64  `json:"lng"`
		Accuracy *float64 `json:"accuracy"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	newID := uuid.New()
	_, _ = h.db.Exec(r.Context(),
		`INSERT INTO worker_locations (id, business_id, user_id, lat, lng, accuracy, recorded_at)
		 VALUES ($1,$2,$3,$4,$5,$6,NOW())`,
		newID, bizID, id, req.Lat, req.Lng, req.Accuracy,
	)
	respond(w, 200, map[string]string{"status": "ok"})
}

// CheckIn (POST /api/v1/workers/check-in) — starts a shift for the
// CALLING user. The legacy version read chi.URLParam(r,"id") which
// was always empty (the route has no :id). Now uses claims.UserID
// and validates tenant + assignment (when job_id is supplied).
func (h *Handler) CheckIn(w http.ResponseWriter, r *http.Request) {
	if !h.requireCheckInPermission(w, r, "checkin.create") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		UserID    *string  `json:"user_id"` // managers can check someone else in
		JobID     *string  `json:"job_id"`
		Lat       *float64 `json:"lat"`
		Lng       *float64 `json:"lng"`
		AccuracyM *float64 `json:"accuracy_m"`
		Notes     *string  `json:"notes"`
	}
	if err := decodeStrictCheckIn(r, &req); err != nil {
		respond(w, 400, map[string]string{"error": err.Error()})
		return
	}

	// Worker scope: non-managers can only check themselves in.
	target := claims.UserID
	if req.UserID != nil && *req.UserID != "" {
		uid, err := uuid.Parse(*req.UserID)
		if err != nil {
			respond(w, 400, map[string]string{"error": "invalid_user_id"})
			return
		}
		if !middleware.IsAtLeast(claims.Role, "manager") && uid != claims.UserID {
			respond(w, 403, map[string]string{"error": "forbidden:non_manager_targeting_other"})
			return
		}
		target = uid
	}

	// Validate lat/lng range when supplied.
	if req.Lat != nil && (*req.Lat < -90 || *req.Lat > 90) {
		respond(w, 400, map[string]string{"error": "invalid_lat"})
		return
	}
	if req.Lng != nil && (*req.Lng < -180 || *req.Lng > 180) {
		respond(w, 400, map[string]string{"error": "invalid_lng"})
		return
	}

	// Validate the job belongs to this tenant AND the caller is
	// assigned to it (or is manager+).
	var jobUUID *uuid.UUID
	if req.JobID != nil && *req.JobID != "" {
		jid, err := uuid.Parse(*req.JobID)
		if err != nil {
			respond(w, 400, map[string]string{"error": "invalid_job_id"})
			return
		}
		var exists bool
		if err := h.db.QueryRow(r.Context(),
			`SELECT EXISTS(SELECT 1 FROM jobs WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
			jid, bizID).Scan(&exists); err != nil || !exists {
			respond(w, 400, map[string]string{"error": "job_not_in_tenant"})
			return
		}
		if !middleware.IsAtLeast(claims.Role, "manager") {
			var assigned bool
			_ = h.db.QueryRow(r.Context(),
				`SELECT EXISTS(SELECT 1 FROM job_assignments
				               WHERE job_id=$1 AND user_id=$2)`,
				jid, target).Scan(&assigned)
			if !assigned {
				respond(w, 403, map[string]string{"error": "forbidden:not_assigned_to_job"})
				return
			}
		}
		jobUUID = &jid
	}

	now := time.Now()
	newID := uuid.New()
	_, err := h.db.Exec(r.Context(),
		`INSERT INTO worker_check_ins
		   (id, business_id, created_by, user_id, job_id, lat, lng, accuracy_m,
		    notes, status, checked_in_at, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'active',$10,NOW(),NOW())`,
		newID, bizID, claims.UserID, target, jobUUID,
		req.Lat, req.Lng, req.AccuracyM, req.Notes, now,
	)
	if err != nil {
		// Partial unique index prevents two active rows per user.
		if strings.Contains(err.Error(), "uq_worker_check_ins_one_active") {
			respond(w, http.StatusConflict, map[string]string{"error": "already_checked_in"})
			return
		}
		h.log.Error("check in", zap.Error(err))
		respond(w, 500, map[string]string{"error": "check_in_failed"})
		return
	}

	h.checkInAuditAction(r, AuditCheckInCreated, newID, nil, map[string]interface{}{
		"user_id": target, "job_id": jobUUID, "lat": req.Lat, "lng": req.Lng,
	})

	respond(w, 201, map[string]interface{}{
		"id": newID, "checked_in_at": now, "job_id": jobUUID, "status": "active",
	})
}

// CheckOut (POST /api/v1/workers/check-out) — closes the calling
// user's active check-in. Same fix as CheckIn: uses claims.UserID,
// not the always-empty chi URL param.
func (h *Handler) CheckOut(w http.ResponseWriter, r *http.Request) {
	if !h.requireCheckInPermission(w, r, "checkout.create") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	// Optional body to capture exit lat/lng/notes; allowed to be empty.
	var req struct {
		UserID    *string  `json:"user_id"`
		Lat       *float64 `json:"lat"`
		Lng       *float64 `json:"lng"`
		AccuracyM *float64 `json:"accuracy_m"`
		Notes     *string  `json:"notes"`
	}
	if err := decodeStrictCheckIn(r, &req); err != nil {
		// Empty body is fine for check-out.
		req = struct {
			UserID    *string  `json:"user_id"`
			Lat       *float64 `json:"lat"`
			Lng       *float64 `json:"lng"`
			AccuracyM *float64 `json:"accuracy_m"`
			Notes     *string  `json:"notes"`
		}{}
	}
	if req.Lat != nil && (*req.Lat < -90 || *req.Lat > 90) {
		respond(w, 400, map[string]string{"error": "invalid_lat"})
		return
	}
	if req.Lng != nil && (*req.Lng < -180 || *req.Lng > 180) {
		respond(w, 400, map[string]string{"error": "invalid_lng"})
		return
	}

	target := claims.UserID
	if req.UserID != nil && *req.UserID != "" {
		uid, err := uuid.Parse(*req.UserID)
		if err != nil {
			respond(w, 400, map[string]string{"error": "invalid_user_id"})
			return
		}
		if !middleware.IsAtLeast(claims.Role, "manager") && uid != claims.UserID {
			respond(w, 403, map[string]string{"error": "forbidden:non_manager_targeting_other"})
			return
		}
		target = uid
	}

	var checkInID uuid.UUID
	var checkedInAt time.Time
	err := h.db.QueryRow(r.Context(),
		`SELECT id, checked_in_at FROM worker_check_ins
		 WHERE business_id=$1 AND user_id=$2 AND status='active' AND deleted_at IS NULL
		 ORDER BY checked_in_at DESC LIMIT 1`,
		bizID, target,
	).Scan(&checkInID, &checkedInAt)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "no_active_check_in"})
		return
	}

	now := time.Now()
	durationMins := int(now.Sub(checkedInAt).Minutes())
	if durationMins < 0 {
		durationMins = 0 // clock skew safety
	}

	// Append exit notes to the existing notes column when supplied
	// (preserves whatever the worker entered on check-in).
	var exitNotes *string
	if req.Notes != nil && strings.TrimSpace(*req.Notes) != "" {
		s := strings.TrimSpace(*req.Notes)
		exitNotes = &s
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE worker_check_ins
		   SET status='closed',
		       checked_out_at=$1,
		       duration_minutes=$2,
		       notes=CASE WHEN $5::text IS NULL THEN notes
		                  WHEN COALESCE(notes,'')='' THEN $5
		                  ELSE notes || E'\n--- check-out ---\n' || $5 END,
		       updated_by=$4, updated_at=NOW()
		 WHERE id=$3 AND business_id=$6 AND status='active' AND deleted_at IS NULL`,
		now, durationMins, checkInID, claims.UserID, exitNotes, bizID,
	)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		h.log.Error("check out", zap.Error(err))
		respond(w, 500, map[string]string{"error": "check_out_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusConflict, map[string]string{"error": "no_active_check_in"})
		return
	}

	h.checkInAuditAction(r, AuditCheckInUpdated, checkInID,
		map[string]interface{}{"status": "active"},
		map[string]interface{}{"status": "closed", "duration_minutes": durationMins})

	respond(w, http.StatusOK, map[string]interface{}{
		"check_in_id":      checkInID,
		"checked_out_at":   now,
		"duration_minutes": durationMins,
		"status":           "closed",
	})
}

func (h *Handler) ListTimesheets(w http.ResponseWriter, r *http.Request) {
	if !h.requireTimePermission(w, r, "time.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	q := r.URL.Query()
	workerID := q.Get("worker_id")
	status := q.Get("status")
	dateFrom := q.Get("date_from")
	dateTo := q.Get("date_to")

	// Workers may only see their own timesheets, regardless of any
	// `worker_id` query param. Pin to self on the server side.
	if !middleware.IsAtLeast(claims.Role, "manager") {
		workerID = claims.UserID.String()
	}
	if status != "" && !allowedTimeStatus[status] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	query := `SELECT t.id, t.worker_id, u.first_name||' '||u.last_name as worker_name,
		 t.job_id, t.date, t.start_time, t.end_time, t.break_minutes, t.total_hours, t.status, t.created_at
		 FROM timesheets t JOIN users u ON u.id=t.worker_id
		 WHERE t.business_id=$1`
	args := []interface{}{bizID}
	argN := 2

	if workerID != "" {
		query += fmt.Sprintf(" AND t.worker_id=$%d", argN)
		args = append(args, workerID)
		argN++
	}
	if status != "" {
		query += fmt.Sprintf(" AND t.status=$%d", argN)
		args = append(args, status)
		argN++
	}
	if dateFrom != "" {
		query += fmt.Sprintf(" AND t.date>=$%d", argN)
		args = append(args, dateFrom)
		argN++
	}
	if dateTo != "" {
		query += fmt.Sprintf(" AND t.date<=$%d", argN)
		args = append(args, dateTo)
		argN++
	}
	query += " ORDER BY t.date DESC LIMIT 200"

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		respond(w, 200, []interface{}{})
		return
	}
	defer rows.Close()
	var list []map[string]interface{}
	for rows.Next() {
		m := make(map[string]interface{})
		var id, workerIDVal, workerName, status2 string
		var jobID interface{}
		var date, startTime, endTime interface{}
		var breakMins int
		var totalHours float64
		var createdAt time.Time
		_ = rows.Scan(&id, &workerIDVal, &workerName, &jobID, &date, &startTime, &endTime, &breakMins, &totalHours, &status2, &createdAt)
		m["id"] = id
		m["worker_id"] = workerIDVal
		m["worker_name"] = workerName
		m["job_id"] = jobID
		m["date"] = date
		m["start_time"] = startTime
		m["end_time"] = endTime
		m["break_minutes"] = breakMins
		m["total_hours"] = totalHours
		m["status"] = status2
		m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) CreateTimesheet(w http.ResponseWriter, r *http.Request) {
	if !h.requireTimePermission(w, r, "time.create") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		WorkerID     string  `json:"worker_id"`
		JobID        *string `json:"job_id"`
		Date         string  `json:"date"`
		StartTime    string  `json:"start_time"`
		EndTime      string  `json:"end_time"`
		BreakMinutes int     `json:"break_minutes"`
		Notes        *string `json:"notes"`
		Status       string  `json:"status"`
	}
	if err := decodeStrictTime(r, &req); err != nil {
		respond(w, 400, map[string]string{"error": err.Error()})
		return
	}

	// Worker scope: non-managers can only submit for themselves.
	target := claims.UserID
	if req.WorkerID != "" {
		uid, err := uuid.Parse(req.WorkerID)
		if err != nil {
			respond(w, 400, map[string]string{"error": "invalid_worker_id"})
			return
		}
		if !middleware.IsAtLeast(claims.Role, "manager") && uid != claims.UserID {
			respond(w, 403, map[string]string{"error": "forbidden:non_manager_targeting_other"})
			return
		}
		target = uid
	}

	// Validate basic fields. Time format is HH:MM (Postgres TIME also
	// accepts seconds; we reject bad shapes here for cleaner errors).
	if req.Date == "" || req.StartTime == "" || req.EndTime == "" {
		respond(w, 400, map[string]string{"error": "date_start_end_required"})
		return
	}
	if req.BreakMinutes < 0 || req.BreakMinutes > 720 {
		respond(w, 400, map[string]string{"error": "invalid_break_minutes"})
		return
	}
	// Status is normally 'pending'; allow 'draft' if explicitly requested.
	status := "pending"
	if req.Status == "draft" {
		status = "draft"
	} else if req.Status != "" && req.Status != "pending" {
		respond(w, 400, map[string]string{"error": "invalid_initial_status"})
		return
	}

	// Tenant guard for job_id when supplied.
	if req.JobID != nil && *req.JobID != "" {
		jid, err := uuid.Parse(*req.JobID)
		if err != nil {
			respond(w, 400, map[string]string{"error": "invalid_job_id"})
			return
		}
		var ok bool
		_ = h.db.QueryRow(r.Context(),
			`SELECT EXISTS(SELECT 1 FROM jobs WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
			jid, bizID).Scan(&ok)
		if !ok {
			respond(w, 400, map[string]string{"error": "job_not_in_tenant"})
			return
		}
	}

	// Overlap detection: reject duplicate timesheets for same date with
	// overlapping time window for the same worker. Night-shift (end<start)
	// is treated as same-day for the overlap check; matches legacy behaviour.
	var overlapID uuid.UUID
	err := h.db.QueryRow(r.Context(),
		`SELECT id FROM timesheets
		 WHERE business_id=$1 AND worker_id=$2 AND deleted_at IS NULL
		   AND status NOT IN ('cancelled','rejected')
		   AND date=$3::DATE
		   AND tsrange(date::timestamp + start_time, date::timestamp + end_time, '[)')
		    && tsrange($3::DATE::timestamp + $4::TIME, $3::DATE::timestamp + $5::TIME, '[)')
		 LIMIT 1`,
		bizID, target, req.Date, req.StartTime, req.EndTime,
	).Scan(&overlapID)
	if err == nil {
		respond(w, http.StatusConflict, map[string]string{
			"error":          "overlapping_timesheet",
			"conflicts_with": overlapID.String(),
		})
		return
	}

	// total_hours: night shifts (end < start) wrap to next day. Use
	// modular arithmetic so the value is always positive.
	newID := uuid.New()
	_, err = h.db.Exec(r.Context(),
		`INSERT INTO timesheets (id, business_id, created_by, worker_id, job_id, date, start_time, end_time,
		   break_minutes, total_hours, notes, status, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6::DATE,$7::TIME,$8::TIME,$9,
		   GREATEST(0,
		     (EXTRACT(EPOCH FROM ($8::TIME - $7::TIME))::float8
		      + CASE WHEN $8::TIME < $7::TIME THEN 86400.0 ELSE 0.0 END
		     ) / 3600.0 - ($9::float8 / 60.0)
		   ),
		   $10,$11,NOW(),NOW())`,
		newID, bizID, claims.UserID, target, req.JobID, req.Date, req.StartTime, req.EndTime,
		req.BreakMinutes, req.Notes, status,
	)
	if err != nil {
		h.log.Error("create timesheet", zap.Error(err))
		respond(w, 500, map[string]string{"error": "create_failed"})
		return
	}

	h.timeAuditAction(r, AuditTimeCreated, newID, nil, map[string]interface{}{
		"worker_id": target, "date": req.Date, "status": status,
	})

	respond(w, 201, map[string]interface{}{"id": newID, "status": status})
}

func (h *Handler) UpdateTimesheet(w http.ResponseWriter, r *http.Request) {
	if !h.requireTimePermission(w, r, "time.update") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	idStr := chi.URLParam(r, "id")
	id, err := uuid.Parse(idStr)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	// Ownership + state guard.
	_, currentStatus, ok := h.canTouchTimesheet(w, r, id)
	if !ok {
		return
	}
	// Editing only allowed in non-terminal, non-approved states.
	if currentStatus == "approved" || currentStatus == "cancelled" {
		respond(w, http.StatusConflict, map[string]string{
			"error":  "cannot_edit",
			"status": currentStatus,
		})
		return
	}

	var req struct {
		StartTime    *string `json:"start_time"`
		EndTime      *string `json:"end_time"`
		BreakMinutes *int    `json:"break_minutes"`
		Notes        *string `json:"notes"`
	}
	if err := decodeStrictTime(r, &req); err != nil {
		respond(w, 400, map[string]string{"error": err.Error()})
		return
	}
	if req.BreakMinutes != nil && (*req.BreakMinutes < 0 || *req.BreakMinutes > 720) {
		respond(w, 400, map[string]string{"error": "invalid_break_minutes"})
		return
	}

	_, err = h.db.Exec(r.Context(),
		`UPDATE timesheets SET
		   start_time    = COALESCE($3::TIME, start_time),
		   end_time      = COALESCE($4::TIME, end_time),
		   break_minutes = COALESCE($5, break_minutes),
		   notes         = COALESCE($6, notes),
		   total_hours = GREATEST(0,
		     (EXTRACT(EPOCH FROM (
		         COALESCE($4::TIME, end_time) - COALESCE($3::TIME, start_time)
		     ))::float8
		      + CASE WHEN COALESCE($4::TIME, end_time) < COALESCE($3::TIME, start_time)
		             THEN 86400.0 ELSE 0.0 END
		     ) / 3600.0 - (COALESCE($5, break_minutes)::float8 / 60.0)
		   ),
		   updated_by = $7, updated_at = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status NOT IN ('approved','cancelled')`,
		id, bizID, req.StartTime, req.EndTime, req.BreakMinutes, req.Notes, claims.UserID,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "update_failed"})
		return
	}

	h.timeAuditAction(r, AuditTimeUpdated, id, nil, map[string]interface{}{
		"start_time": req.StartTime, "end_time": req.EndTime,
		"break_minutes": req.BreakMinutes,
	})
	respond(w, 200, map[string]string{"status": "updated"})
}

func (h *Handler) ApproveTimesheet(w http.ResponseWriter, r *http.Request) {
	if !h.requireTimePermission(w, r, "time.approve") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	idStr := chi.URLParam(r, "id")
	id, err := uuid.Parse(idStr)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}
	tag, err := h.db.Exec(r.Context(),
		`UPDATE timesheets
		   SET status='approved', approved_by=$3, approved_at=NOW(),
		       updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status IN ('pending','submitted')`,
		id, bizID, claims.UserID,
	)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		respond(w, 500, map[string]string{"error": "approve_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusConflict, map[string]string{"error": "not_found_or_invalid_state"})
		return
	}

	h.timeAuditAction(r, AuditTimeUpdated, id, nil,
		map[string]interface{}{"status": "approved"})

	respond(w, 200, map[string]string{"id": id.String(), "status": "approved"})
}

// ── Payroll ────────────────────────────────────────────────────

func (h *Handler) ListPayRuns(w http.ResponseWriter, r *http.Request) {
	if !h.requirePayrollPermission(w, r, "payroll.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(),
		`SELECT id, period_start, period_end, pay_date, status, total_gross, total_tax, total_net, created_at
		 FROM pay_runs WHERE business_id=$1 AND deleted_at IS NULL ORDER BY period_start DESC`, bizID)
	if err != nil {
		respond(w, 200, []interface{}{})
		return
	}
	defer rows.Close()
	var list []map[string]interface{}
	for rows.Next() {
		m := make(map[string]interface{})
		var id, status string
		var periodStart, periodEnd, payDate interface{}
		var gross, tax, net float64
		var createdAt time.Time
		_ = rows.Scan(&id, &periodStart, &periodEnd, &payDate, &status, &gross, &tax, &net, &createdAt)
		m["id"] = id
		m["period_start"] = periodStart
		m["period_end"] = periodEnd
		m["pay_date"] = payDate
		m["status"] = status
		m["total_gross"] = gross
		m["total_tax"] = tax
		m["total_net"] = net
		m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) CreatePayRun(w http.ResponseWriter, r *http.Request) {
	if !h.requirePayrollPermission(w, r, "payroll.process") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		PeriodStart string `json:"period_start"`
		PeriodEnd   string `json:"period_end"`
		PayDate     string `json:"pay_date"`
	}
	if err := decodeStrictPayroll(r, &req); err != nil {
		respond(w, 400, map[string]string{"error": err.Error()})
		return
	}

	startD, err := time.Parse("2006-01-02", strings.TrimSpace(req.PeriodStart))
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_period_start"})
		return
	}
	endD, err := time.Parse("2006-01-02", strings.TrimSpace(req.PeriodEnd))
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_period_end"})
		return
	}
	payD, err := time.Parse("2006-01-02", strings.TrimSpace(req.PayDate))
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_pay_date"})
		return
	}
	if endD.Before(startD) {
		respond(w, 400, map[string]string{"error": "end_before_start"})
		return
	}
	if payD.Before(startD) {
		respond(w, 400, map[string]string{"error": "pay_date_before_period_start"})
		return
	}

	// Overlap detection: reject if a non-cancelled run already covers
	// any day in this period for the tenant.
	var conflictID uuid.UUID
	err = h.db.QueryRow(r.Context(),
		`SELECT id FROM pay_runs
		 WHERE business_id=$1 AND deleted_at IS NULL AND status <> 'cancelled'
		   AND daterange(period_start, period_end, '[]') && daterange($2::DATE, $3::DATE, '[]')
		 LIMIT 1`,
		bizID, startD.Format("2006-01-02"), endD.Format("2006-01-02"),
	).Scan(&conflictID)
	if err == nil {
		respond(w, http.StatusConflict, map[string]string{
			"error":          "overlapping_pay_run",
			"conflicts_with": conflictID.String(),
		})
		return
	}

	newID := uuid.New()
	_, err = h.db.Exec(r.Context(),
		`INSERT INTO pay_runs (id, business_id, period_start, period_end, pay_date,
		   status, total_gross, total_tax, total_net,
		   created_by, created_at, updated_at)
		 VALUES ($1,$2,$3::DATE,$4::DATE,$5::DATE,'draft',0,0,0,$6,NOW(),NOW())`,
		newID, bizID, req.PeriodStart, req.PeriodEnd, req.PayDate, claims.UserID,
	)
	if err != nil {
		h.log.Error("create pay run", zap.Error(err))
		respond(w, 500, map[string]string{"error": "create_failed"})
		return
	}

	h.payrollAuditAction(r, AuditPayrollCreated, newID, nil, map[string]interface{}{
		"period_start": req.PeriodStart,
		"period_end":   req.PeriodEnd,
		"pay_date":     req.PayDate,
	})

	respond(w, 201, map[string]interface{}{"id": newID, "status": "draft"})
}

func (h *Handler) GetPayRun(w http.ResponseWriter, r *http.Request) {
	if !h.requirePayrollPermission(w, r, "payroll.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var run map[string]interface{}
	var runID, status string
	var periodStart, periodEnd, payDate interface{}
	var gross, tax, net float64
	var createdAt time.Time
	err := h.db.QueryRow(r.Context(),
		`SELECT id, period_start, period_end, pay_date, status, total_gross, total_tax, total_net, created_at
		 FROM pay_runs WHERE id=$1 AND business_id=$2`, id, bizID,
	).Scan(&runID, &periodStart, &periodEnd, &payDate, &status, &gross, &tax, &net, &createdAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	run = map[string]interface{}{
		"id": runID, "period_start": periodStart, "period_end": periodEnd,
		"pay_date": payDate, "status": status, "total_gross": gross,
		"total_tax": tax, "total_net": net, "created_at": createdAt,
	}
	// attach payslips
	rows, _ := h.db.Query(r.Context(),
		`SELECT ps.id, ps.worker_id, u.first_name||' '||u.last_name, ps.gross_pay, ps.tax_withheld, ps.net_pay, ps.super_amount
		 FROM payslips ps JOIN users u ON u.id=ps.worker_id WHERE ps.pay_run_id=$1 AND ps.business_id=$2`,
		id, bizID,
	)
	var payslips []map[string]interface{}
	if rows != nil {
		defer rows.Close()
		for rows.Next() {
			p := make(map[string]interface{})
			var psID, workerID, workerName string
			var gpay, tax2, net2, super float64
			_ = rows.Scan(&psID, &workerID, &workerName, &gpay, &tax2, &net2, &super)
			p["id"] = psID
			p["worker_id"] = workerID
			p["worker_name"] = workerName
			p["gross_pay"] = gpay
			p["tax_withheld"] = tax2
			p["net_pay"] = net2
			p["super_amount"] = super
			payslips = append(payslips, p)
		}
	}
	if payslips == nil {
		payslips = []map[string]interface{}{}
	}
	run["payslips"] = payslips
	respond(w, 200, run)
}

func (h *Handler) ProcessPayRun(w http.ResponseWriter, r *http.Request) {
	if !h.requirePayrollPermission(w, r, "payroll.process") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	runID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respond(w, 500, map[string]string{"error": "tx_failed"})
		return
	}
	defer tx.Rollback(r.Context())

	// Lock the pay run row for the duration of processing — prevents
	// two concurrent processes from double-counting.
	var periodStart, periodEnd string
	err = tx.QueryRow(r.Context(),
		`SELECT period_start::TEXT, period_end::TEXT
		 FROM pay_runs
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND status='draft'
		 FOR UPDATE`,
		runID, bizID,
	).Scan(&periodStart, &periodEnd)
	if err != nil {
		respond(w, 404, map[string]string{"error": "pay_run_not_found_or_already_processed"})
		return
	}

	// Resolve tenant tax + super rates once.
	rates := h.loadPayrollRates(r.Context(), bizID)
	taxFraction := rates.taxRatePct / 100.0
	superFraction := rates.superRatePct / 100.0

	// Aggregate approved timesheets in the period per worker.
	rows, err := tx.Query(r.Context(),
		`SELECT worker_id, SUM(total_hours)::float8
		 FROM timesheets
		 WHERE business_id=$1 AND date BETWEEN $2::DATE AND $3::DATE
		   AND status='approved' AND deleted_at IS NULL
		 GROUP BY worker_id`,
		bizID, periodStart, periodEnd,
	)
	if err != nil {
		h.log.Error("process pay run: aggregate", zap.Error(err))
		respond(w, 500, map[string]string{"error": "aggregate_failed"})
		return
	}

	type workerHours struct {
		workerID uuid.UUID
		hours    float64
	}
	workers := []workerHours{}
	for rows.Next() {
		var x workerHours
		if err := rows.Scan(&x.workerID, &x.hours); err != nil {
			rows.Close()
			respond(w, 500, map[string]string{"error": "scan_failed"})
			return
		}
		workers = append(workers, x)
	}
	rows.Close()

	var totalGross, totalTax, totalNet float64
	for _, wk := range workers {
		hourlyRate := h.hourlyRateFor(r.Context(), wk.workerID, bizID)
		grossPay := wk.hours * hourlyRate
		taxWithheld := grossPay * taxFraction
		netPay := grossPay - taxWithheld
		superAmt := grossPay * superFraction
		totalGross += grossPay
		totalTax += taxWithheld
		totalNet += netPay

		newID := uuid.New()
		if _, err := tx.Exec(r.Context(),
			`INSERT INTO payslips (id, business_id, pay_run_id, worker_id, created_by,
			   gross_pay, tax_withheld, net_pay, super_amount, hours_worked, hourly_rate,
			   period_start, period_end, status, created_at, updated_at)
			 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12::DATE,$13::DATE,'locked',NOW(),NOW())
			 ON CONFLICT (pay_run_id, worker_id) DO UPDATE SET
			   gross_pay=EXCLUDED.gross_pay,
			   tax_withheld=EXCLUDED.tax_withheld,
			   net_pay=EXCLUDED.net_pay,
			   super_amount=EXCLUDED.super_amount,
			   hours_worked=EXCLUDED.hours_worked,
			   hourly_rate=EXCLUDED.hourly_rate,
			   status='locked',
			   updated_by=EXCLUDED.created_by,
			   updated_at=NOW()`,
			newID, bizID, runID, wk.workerID, claims.UserID,
			grossPay, taxWithheld, netPay, superAmt, wk.hours, hourlyRate,
			periodStart, periodEnd,
		); err != nil {
			h.log.Error("process pay run: insert payslip", zap.Error(err))
			respond(w, 500, map[string]string{"error": "payslip_insert_failed"})
			return
		}

		// Superannuation accrual row (one per worker per pay run).
		quarter := fmt.Sprintf("%dQ%d",
			parseDateYear(periodStart),
			parseDateQuarter(periodStart))
		if _, err := tx.Exec(r.Context(),
			`INSERT INTO superannuation (business_id, worker_id, pay_run_id,
			   created_by, amount, quarter, status, due_date, created_at, updated_at)
			 VALUES ($1,$2,$3,$4,$5,$6,'pending',
			   (date_trunc('quarter', $7::DATE) + INTERVAL '4 months 28 days')::DATE,
			   NOW(), NOW())`,
			bizID, wk.workerID, runID, claims.UserID, superAmt, quarter, periodStart,
		); err != nil {
			h.log.Error("process pay run: insert super", zap.Error(err))
			respond(w, 500, map[string]string{"error": "super_insert_failed"})
			return
		}
	}

	if _, err := tx.Exec(r.Context(),
		`UPDATE pay_runs
		   SET status='processed', total_gross=$3, total_tax=$4, total_net=$5,
		       processed_at=NOW(), updated_by=$6, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND status='draft'`,
		runID, bizID, totalGross, totalTax, totalNet, claims.UserID,
	); err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		h.log.Error("process pay run: finalise", zap.Error(err))
		respond(w, 500, map[string]string{"error": "finalise_failed"})
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		respond(w, 500, map[string]string{"error": "commit_failed"})
		return
	}

	h.payrollAuditAction(r, AuditPayrollUpdated, runID,
		map[string]interface{}{"status": "draft"},
		map[string]interface{}{
			"status":         "processed",
			"total_gross":    totalGross,
			"total_tax":      totalTax,
			"total_net":      totalNet,
			"payslip_count":  len(workers),
			"tax_rate_pct":   rates.taxRatePct,
			"super_rate_pct": rates.superRatePct,
		})

	respond(w, 200, map[string]interface{}{
		"status":        "processed",
		"total_gross":   totalGross,
		"total_tax":     totalTax,
		"total_net":     totalNet,
		"payslip_count": len(workers),
	})
}

// parseDateYear / parseDateQuarter pull a calendar quarter label from
// a YYYY-MM-DD string. They never panic — bad input returns 0.
func parseDateYear(d string) int {
	t, err := time.Parse("2006-01-02", d)
	if err != nil {
		return 0
	}
	return t.Year()
}
func parseDateQuarter(d string) int {
	t, err := time.Parse("2006-01-02", d)
	if err != nil {
		return 0
	}
	return (int(t.Month())-1)/3 + 1
}

func (h *Handler) ListPayslips(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	workerID := r.URL.Query().Get("worker_id")

	// Non-elevated callers (worker, accountant) can only see their
	// own payslips. Manager+ may query for any worker — gated by
	// payroll.view so revoking the catalogue grant takes effect here.
	elevated := middleware.IsAtLeast(claims.Role, "manager")
	if elevated {
		if !h.requirePayrollPermission(w, r, "payroll.view") {
			return
		}
		// elevated callers can scope to any worker, including blank.
	} else {
		if workerID != "" && workerID != claims.UserID.String() {
			respond(w, 403, map[string]string{"error": "forbidden"})
			return
		}
		workerID = claims.UserID.String()
	}
	query := `SELECT ps.id, ps.worker_id, u.first_name||' '||u.last_name, ps.pay_run_id, ps.gross_pay, ps.tax_withheld, ps.net_pay, ps.super_amount, ps.period_start, ps.period_end, ps.created_at
		 FROM payslips ps JOIN users u ON u.id=ps.worker_id WHERE ps.business_id=$1`
	args := []interface{}{bizID}
	if workerID != "" {
		query += " AND ps.worker_id=$2"
		args = append(args, workerID)
	}
	query += " ORDER BY ps.period_start DESC LIMIT 200"
	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		respond(w, 200, []interface{}{})
		return
	}
	defer rows.Close()
	var list []map[string]interface{}
	for rows.Next() {
		m := make(map[string]interface{})
		var id, wID, wName, payRunID string
		var gross, tax, net, super float64
		var periodStart, periodEnd interface{}
		var createdAt time.Time
		_ = rows.Scan(&id, &wID, &wName, &payRunID, &gross, &tax, &net, &super, &periodStart, &periodEnd, &createdAt)
		m["id"] = id
		m["worker_id"] = wID
		m["worker_name"] = wName
		m["pay_run_id"] = payRunID
		m["gross_pay"] = gross
		m["tax_withheld"] = tax
		m["net_pay"] = net
		m["super_amount"] = super
		m["period_start"] = periodStart
		m["period_end"] = periodEnd
		m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) GeneratePayslipPDF(w http.ResponseWriter, r *http.Request) {
	h.DownloadPayslipPDF(w, r)
}

func (h *Handler) ListSuper(w http.ResponseWriter, r *http.Request) {
	if !h.requirePayrollPermission(w, r, "payroll.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(),
		`SELECT s.id, s.worker_id, u.first_name||' '||u.last_name, s.amount, s.quarter, s.status, s.due_date
		 FROM superannuation s JOIN users u ON u.id=s.worker_id
		 WHERE s.business_id=$1 AND s.deleted_at IS NULL ORDER BY s.quarter DESC`, bizID)
	if err != nil {
		respond(w, 200, []interface{}{})
		return
	}
	defer rows.Close()
	var list []map[string]interface{}
	for rows.Next() {
		m := make(map[string]interface{})
		var id, wID, wName, quarter, status string
		var amount float64
		var dueDate interface{}
		_ = rows.Scan(&id, &wID, &wName, &amount, &quarter, &status, &dueDate)
		m["id"] = id
		m["worker_id"] = wID
		m["worker_name"] = wName
		m["amount"] = amount
		m["quarter"] = quarter
		m["status"] = status
		m["due_date"] = dueDate
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) CreateLeaveRequest(w http.ResponseWriter, r *http.Request) {
	if !h.requireLeavePermission(w, r, "leave.request") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		WorkerID  string  `json:"worker_id"`
		LeaveType string  `json:"leave_type"` // annual|sick|personal|unpaid|other
		StartDate string  `json:"start_date"`
		EndDate   string  `json:"end_date"`
		Reason    *string `json:"reason"`
	}
	if err := decodeStrictLeave(r, &req); err != nil {
		respond(w, 400, map[string]string{"error": err.Error()})
		return
	}

	// Worker scope: non-managers can only request for themselves.
	target := claims.UserID
	if req.WorkerID != "" {
		uid, err := uuid.Parse(req.WorkerID)
		if err != nil {
			respond(w, 400, map[string]string{"error": "invalid_worker_id"})
			return
		}
		if !middleware.IsAtLeast(claims.Role, "manager") && uid != claims.UserID {
			respond(w, 403, map[string]string{"error": "forbidden:non_manager_targeting_other"})
			return
		}
		target = uid
	}

	if !allowedLeaveType[req.LeaveType] {
		respond(w, 400, map[string]string{"error": "invalid_leave_type"})
		return
	}

	startD, err := time.Parse("2006-01-02", strings.TrimSpace(req.StartDate))
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_start_date"})
		return
	}
	endD, err := time.Parse("2006-01-02", strings.TrimSpace(req.EndDate))
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_end_date"})
		return
	}
	if endD.Before(startD) {
		respond(w, 400, map[string]string{"error": "end_before_start"})
		return
	}

	// Tenant guard for the worker_id (manager case targeting someone).
	var ok bool
	_ = h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		target, bizID).Scan(&ok)
	if !ok {
		respond(w, 400, map[string]string{"error": "worker_not_in_tenant"})
		return
	}

	// Overlap detection: reject if pending/approved leave already covers any day in this range.
	var overlapID uuid.UUID
	err = h.db.QueryRow(r.Context(),
		`SELECT id FROM leave_requests
		 WHERE business_id=$1 AND worker_id=$2 AND deleted_at IS NULL
		   AND status IN ('pending','approved')
		   AND daterange(start_date, end_date, '[]') && daterange($3::DATE, $4::DATE, '[]')
		 LIMIT 1`,
		bizID, target, startD.Format("2006-01-02"), endD.Format("2006-01-02"),
	).Scan(&overlapID)
	if err == nil {
		respond(w, http.StatusConflict, map[string]string{
			"error":          "overlapping_leave",
			"conflicts_with": overlapID.String(),
		})
		return
	}

	newID := uuid.New()
	_, err = h.db.Exec(r.Context(),
		`INSERT INTO leave_requests (id, business_id, created_by, worker_id, leave_type,
		   start_date, end_date, days_count, reason, status, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6::DATE,$7::DATE,
		   ($7::DATE - $6::DATE + 1)::INT,
		   $8,'pending',NOW(),NOW())`,
		newID, bizID, claims.UserID, target, req.LeaveType,
		startD.Format("2006-01-02"), endD.Format("2006-01-02"), req.Reason,
	)
	if err != nil {
		h.log.Error("create leave request", zap.Error(err))
		respond(w, 500, map[string]string{"error": "create_failed"})
		return
	}

	h.leaveAuditAction(r, AuditLeaveCreated, newID, nil, map[string]interface{}{
		"worker_id":  target,
		"leave_type": req.LeaveType,
		"start_date": req.StartDate,
		"end_date":   req.EndDate,
	})

	respond(w, 201, map[string]interface{}{"id": newID, "status": "pending"})
}

func (h *Handler) ListLeaveRequests(w http.ResponseWriter, r *http.Request) {
	if !h.requireLeavePermission(w, r, "leave.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	q := r.URL.Query()
	status := q.Get("status")
	workerID := q.Get("worker_id")

	// Non-elevated callers can only see their own; ignore any
	// worker_id query param that doesn't match themselves.
	if !middleware.IsAtLeast(claims.Role, "manager") {
		workerID = claims.UserID.String()
	}
	if status != "" && !allowedLeaveStatus[status] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	query := `SELECT lr.id, lr.worker_id, u.first_name||' '||u.last_name, lr.leave_type,
		         lr.start_date, lr.end_date, lr.days_count, lr.status, lr.created_at
		 FROM leave_requests lr JOIN users u ON u.id=lr.worker_id
		 WHERE lr.business_id=$1 AND lr.deleted_at IS NULL`
	args := []interface{}{bizID}
	argN := 2
	if status != "" {
		query += fmt.Sprintf(" AND lr.status=$%d", argN)
		args = append(args, status)
		argN++
	}
	if workerID != "" {
		query += fmt.Sprintf(" AND lr.worker_id=$%d", argN)
		args = append(args, workerID)
		argN++
	}
	query += " ORDER BY lr.created_at DESC LIMIT 100"
	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		respond(w, 200, []interface{}{})
		return
	}
	defer rows.Close()
	var list []map[string]interface{}
	for rows.Next() {
		m := make(map[string]interface{})
		var id, wID, wName, leaveType, leaveStatus string
		var startDate, endDate interface{}
		var daysCount int
		var createdAt time.Time
		_ = rows.Scan(&id, &wID, &wName, &leaveType, &startDate, &endDate, &daysCount, &leaveStatus, &createdAt)
		m["id"] = id
		m["worker_id"] = wID
		m["worker_name"] = wName
		m["leave_type"] = leaveType
		m["start_date"] = startDate
		m["end_date"] = endDate
		m["days_count"] = daysCount
		m["status"] = leaveStatus
		m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) ApproveLeave(w http.ResponseWriter, r *http.Request) {
	if !h.requireLeavePermission(w, r, "leave.approve") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	leaveID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}
	tag, err := h.db.Exec(r.Context(),
		`UPDATE leave_requests
		   SET status='approved', approved_by=$3, approved_at=NOW(),
		       updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND status='pending'`,
		leaveID, bizID, claims.UserID,
	)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		respond(w, 500, map[string]string{"error": "approve_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusConflict, map[string]string{"error": "not_found_or_invalid_state"})
		return
	}

	h.leaveAuditAction(r, AuditLeaveUpdated, leaveID, nil,
		map[string]interface{}{"status": "approved"})

	respond(w, 200, map[string]string{"id": leaveID.String(), "status": "approved"})
}

func (h *Handler) RejectLeave(w http.ResponseWriter, r *http.Request) {
	if !h.requireLeavePermission(w, r, "leave.approve") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	leaveID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}
	var req struct {
		Reason *string `json:"rejection_reason"`
	}
	if err := decodeStrictLeave(r, &req); err != nil {
		// Empty body acceptable: reason defaults to NULL.
		req.Reason = nil
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE leave_requests
		   SET status='rejected', rejection_reason=$3,
		       updated_by=$4, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND status='pending'`,
		leaveID, bizID, req.Reason, claims.UserID,
	)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		respond(w, 500, map[string]string{"error": "reject_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusConflict, map[string]string{"error": "not_found_or_invalid_state"})
		return
	}

	h.leaveAuditAction(r, AuditLeaveUpdated, leaveID, nil,
		map[string]interface{}{"status": "rejected", "rejection_reason": req.Reason})

	respond(w, 200, map[string]string{"id": leaveID.String(), "status": "rejected"})
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
