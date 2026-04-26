package workers

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
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

		// Manager+ reads: pay run summaries and super tracking are sensitive
		// across the whole business and are restricted to manager and above.
		r.Group(func(r chi.Router) {
			r.Use(middleware.RequireAtLeast("manager"))
			r.Get("/runs", h.ListPayRuns)
			r.Get("/runs/{id}", h.GetPayRun)
			r.Get("/superannuation", h.ListSuper)
		})

		// Owner/Admin only: pay run mutations and leave approval/rejection.
		r.Group(func(r chi.Router) {
			r.Use(middleware.RequireOwnerOrAdmin())
			r.Post("/runs", h.CreatePayRun)
			r.Post("/runs/{id}/process", h.ProcessPayRun)
			r.Post("/leave-requests/{id}/approve", h.ApproveLeave)
			r.Post("/leave-requests/{id}/reject", h.RejectLeave)
		})
	})
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, _ := h.db.Query(r.Context(),
		`SELECT u.id, u.email, u.first_name, u.last_name, u.role, u.phone, u.is_active, u.created_at
		 FROM users u WHERE u.business_id=$1 AND u.deleted_at IS NULL AND u.role != 'customer'
		 ORDER BY u.first_name ASC`, bizID)
	defer rows.Close()
	var workers []map[string]interface{}
	for rows.Next() {
		w2 := make(map[string]interface{})
		var id, email, first, last, role string
		var phone interface{}
		var active bool
		var createdAt interface{}
		_ = rows.Scan(&id, &email, &first, &last, &role, &phone, &active, &createdAt)
		w2["id"] = id; w2["email"] = email; w2["first_name"] = first; w2["last_name"] = last
		w2["role"] = role; w2["phone"] = phone; w2["is_active"] = active; w2["created_at"] = createdAt
		workers = append(workers, w2)
	}
	if workers == nil {
		workers = []map[string]interface{}{}
	}
	respond(w, 200, workers)
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	var req struct {
		FirstName string  `json:"first_name"`
		LastName  string  `json:"last_name"`
		Email     string  `json:"email"`
		Phone     *string `json:"phone"`
		Role      string  `json:"role"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if req.FirstName == "" || req.Email == "" {
		respond(w, 400, map[string]string{"error": "first_name and email required"})
		return
	}
	allowed := map[string]bool{"worker": true, "manager": true, "accountant": true}
	if !allowed[req.Role] {
		respond(w, 400, map[string]string{"error": "role must be worker, manager, or accountant"})
		return
	}
	newID := uuid.New()
	var result map[string]interface{}
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO users (id, business_id, email, first_name, last_name, phone, role, is_active, is_verified, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,true,false,NOW(),NOW())
		 ON CONFLICT (email, business_id) DO NOTHING
		 RETURNING id, email, first_name, last_name, role, phone, is_active, created_at`,
		newID, bizID, req.Email, req.FirstName, req.LastName, req.Phone, req.Role,
	).Scan(
		&newID, new(string), new(string), new(string), new(string), new(interface{}), new(bool), new(time.Time),
	)
	if err != nil {
		respond(w, 409, map[string]string{"error": "email_already_exists"})
		return
	}
	result = map[string]interface{}{
		"id": newID, "email": req.Email, "first_name": req.FirstName,
		"last_name": req.LastName, "role": req.Role, "phone": req.Phone,
		"is_active": true, "invite_sent": true,
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "WORKER_CREATED",
		EntityType: "user",
		EntityID:   newID,
	})
	respond(w, 201, result)
}

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var worker struct {
		ID        string      `json:"id"`
		Email     string      `json:"email"`
		FirstName string      `json:"first_name"`
		LastName  string      `json:"last_name"`
		Role      string      `json:"role"`
		Phone     interface{} `json:"phone"`
		IsActive  bool        `json:"is_active"`
		CreatedAt time.Time   `json:"created_at"`
		ActiveJobs int        `json:"active_jobs"`
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
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var req struct {
		FirstName *string `json:"first_name"`
		LastName  *string `json:"last_name"`
		Phone     *string `json:"phone"`
		Role      *string `json:"role"`
		IsActive  *bool   `json:"is_active"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, err := h.db.Exec(r.Context(),
		`UPDATE users SET
		 first_name = COALESCE($3, first_name),
		 last_name = COALESCE($4, last_name),
		 phone = COALESCE($5, phone),
		 role = COALESCE($6, role),
		 is_active = COALESCE($7, is_active),
		 updated_at = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.FirstName, req.LastName, req.Phone, req.Role, req.IsActive,
	)
	if err != nil {
		h.log.Error("update worker", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	entityID, _ := uuid.Parse(id)
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "WORKER_UPDATED",
		EntityType: "user",
		EntityID:   entityID,
	})
	respond(w, 200, map[string]string{"status": "updated"})
}

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	_, err := h.db.Exec(r.Context(),
		`UPDATE users SET deleted_at=NOW(), is_active=false WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	entityID, _ := uuid.Parse(id)
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "WORKER_DELETED",
		EntityType: "user",
		EntityID:   entityID,
	})
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
		m["id"] = tsID; m["worker_id"] = workerID; m["job_id"] = jobID
		m["date"] = date; m["start_time"] = startTime; m["end_time"] = endTime
		m["break_minutes"] = breakMins; m["total_hours"] = totalHours
		m["notes"] = notes; m["status"] = status; m["created_at"] = createdAt
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
		m["id"] = psID; m["pay_run_id"] = payRunID; m["gross_pay"] = gross
		m["tax_withheld"] = tax; m["net_pay"] = net; m["super_amount"] = super
		m["period_start"] = periodStart; m["period_end"] = periodEnd; m["created_at"] = createdAt
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
		m["id"] = slotID; m["day_of_week"] = day; m["start_time"] = startTime
		m["end_time"] = endTime; m["is_available"] = isAvail
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

func (h *Handler) CheckIn(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var req struct {
		JobID *string  `json:"job_id"`
		Lat   *float64 `json:"lat"`
		Lng   *float64 `json:"lng"`
		Notes *string  `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	newID := uuid.New()
	now := time.Now()
	_, err := h.db.Exec(r.Context(),
		`INSERT INTO worker_check_ins (id, business_id, user_id, job_id, lat, lng, notes, checked_in_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
		newID, bizID, id, req.JobID, req.Lat, req.Lng, req.Notes, now,
	)
	if err != nil {
		h.log.Error("check in", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	respond(w, 200, map[string]interface{}{
		"id": newID, "checked_in_at": now, "job_id": req.JobID,
	})
}

func (h *Handler) CheckOut(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	now := time.Now()
	var checkInID string
	var checkedInAt time.Time
	err := h.db.QueryRow(r.Context(),
		`SELECT id, checked_in_at FROM worker_check_ins
		 WHERE business_id=$1 AND user_id=$2 AND checked_out_at IS NULL
		 ORDER BY checked_in_at DESC LIMIT 1`,
		bizID, id,
	).Scan(&checkInID, &checkedInAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "no_active_check_in"})
		return
	}
	durationMins := int(now.Sub(checkedInAt).Minutes())
	_, _ = h.db.Exec(r.Context(),
		`UPDATE worker_check_ins SET checked_out_at=$1, duration_minutes=$2 WHERE id=$3`,
		now, durationMins, checkInID,
	)
	respond(w, 200, map[string]interface{}{
		"check_in_id": checkInID, "checked_out_at": now, "duration_minutes": durationMins,
	})
}

func (h *Handler) ListTimesheets(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()
	workerID := q.Get("worker_id")
	status := q.Get("status")
	dateFrom := q.Get("date_from")
	dateTo := q.Get("date_to")

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
		m["id"] = id; m["worker_id"] = workerIDVal; m["worker_name"] = workerName
		m["job_id"] = jobID; m["date"] = date; m["start_time"] = startTime
		m["end_time"] = endTime; m["break_minutes"] = breakMins; m["total_hours"] = totalHours
		m["status"] = status2; m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) CreateTimesheet(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		WorkerID     string  `json:"worker_id"`
		JobID        *string `json:"job_id"`
		Date         string  `json:"date"`
		StartTime    string  `json:"start_time"`
		EndTime      string  `json:"end_time"`
		BreakMinutes int     `json:"break_minutes"`
		Notes        *string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	newID := uuid.New()
	// total_hours computed from start/end minus break
	_, err := h.db.Exec(r.Context(),
		`INSERT INTO timesheets (id, business_id, worker_id, job_id, date, start_time, end_time, break_minutes,
		 total_hours, notes, status, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5::DATE,$6::TIME,$7::TIME,$8,
		 EXTRACT(EPOCH FROM ($7::TIME - $6::TIME))/3600 - $8/60.0,
		 $9,'pending',NOW(),NOW())`,
		newID, bizID, req.WorkerID, req.JobID, req.Date, req.StartTime, req.EndTime,
		req.BreakMinutes, req.Notes,
	)
	if err != nil {
		h.log.Error("create timesheet", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	respond(w, 201, map[string]interface{}{"id": newID, "status": "pending"})
}

func (h *Handler) UpdateTimesheet(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var req struct {
		StartTime    *string `json:"start_time"`
		EndTime      *string `json:"end_time"`
		BreakMinutes *int    `json:"break_minutes"`
		Notes        *string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, err := h.db.Exec(r.Context(),
		`UPDATE timesheets SET
		 start_time = COALESCE($3::TIME, start_time),
		 end_time = COALESCE($4::TIME, end_time),
		 break_minutes = COALESCE($5, break_minutes),
		 notes = COALESCE($6, notes),
		 updated_at = NOW()
		 WHERE id=$1 AND business_id=$2 AND status='pending'`,
		id, bizID, req.StartTime, req.EndTime, req.BreakMinutes, req.Notes,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	respond(w, 200, map[string]string{"status": "updated"})
}

func (h *Handler) ApproveTimesheet(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	_, err := h.db.Exec(r.Context(),
		`UPDATE timesheets SET status='approved', approved_by=$3, approved_at=NOW(), updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND status='pending'`,
		id, bizID, claims.UserID,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	respond(w, 200, map[string]string{"status": "approved"})
}

// ── Payroll ────────────────────────────────────────────────────

func (h *Handler) ListPayRuns(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(),
		`SELECT id, period_start, period_end, pay_date, status, total_gross, total_tax, total_net, created_at
		 FROM pay_runs WHERE business_id=$1 ORDER BY period_start DESC`, bizID)
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
		m["id"] = id; m["period_start"] = periodStart; m["period_end"] = periodEnd
		m["pay_date"] = payDate; m["status"] = status; m["total_gross"] = gross
		m["total_tax"] = tax; m["total_net"] = net; m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) CreatePayRun(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	var req struct {
		PeriodStart string `json:"period_start"`
		PeriodEnd   string `json:"period_end"`
		PayDate     string `json:"pay_date"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	newID := uuid.New()
	_, err := h.db.Exec(r.Context(),
		`INSERT INTO pay_runs (id, business_id, period_start, period_end, pay_date, status, total_gross, total_tax, total_net, created_by, created_at, updated_at)
		 VALUES ($1,$2,$3::DATE,$4::DATE,$5::DATE,'draft',0,0,0,$6,NOW(),NOW())`,
		newID, bizID, req.PeriodStart, req.PeriodEnd, req.PayDate, claims.UserID,
	)
	if err != nil {
		h.log.Error("create pay run", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "PAYROLL_RUN_CREATED",
		EntityType: "pay_run",
		EntityID:   newID,
		NewData: map[string]interface{}{
			"period_start": req.PeriodStart,
			"period_end":   req.PeriodEnd,
			"pay_date":     req.PayDate,
		},
	})
	respond(w, 201, map[string]interface{}{"id": newID, "status": "draft"})
}

func (h *Handler) GetPayRun(w http.ResponseWriter, r *http.Request) {
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
			p["id"] = psID; p["worker_id"] = workerID; p["worker_name"] = workerName
			p["gross_pay"] = gpay; p["tax_withheld"] = tax2; p["net_pay"] = net2; p["super_amount"] = super
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
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	runID, _ := uuid.Parse(id)
	var periodStart, periodEnd string
	err := h.db.QueryRow(r.Context(),
		`SELECT period_start::TEXT, period_end::TEXT FROM pay_runs WHERE id=$1 AND business_id=$2 AND status='draft'`,
		id, bizID,
	).Scan(&periodStart, &periodEnd)
	if err != nil {
		respond(w, 404, map[string]string{"error": "pay_run_not_found_or_already_processed"})
		return
	}
	// Aggregate timesheets in period to compute totals
	rows, _ := h.db.Query(r.Context(),
		`SELECT worker_id, SUM(total_hours) FROM timesheets
		 WHERE business_id=$1 AND date BETWEEN $2::DATE AND $3::DATE AND status='approved'
		 GROUP BY worker_id`,
		bizID, periodStart, periodEnd,
	)
	var totalGross float64
	if rows != nil {
		defer rows.Close()
		for rows.Next() {
			var workerID string
			var hours float64
			_ = rows.Scan(&workerID, &hours)
			grossPay := hours * 35.0 // placeholder hourly rate
			taxWithheld := grossPay * 0.19
			netPay := grossPay - taxWithheld
			superAmt := grossPay * 0.11
			totalGross += grossPay
			newID := uuid.New()
			_, _ = h.db.Exec(r.Context(),
				`INSERT INTO payslips (id, business_id, pay_run_id, worker_id, gross_pay, tax_withheld, net_pay, super_amount, period_start, period_end, created_at)
				 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::DATE,$10::DATE,NOW())
				 ON CONFLICT DO NOTHING`,
				newID, bizID, id, workerID, grossPay, taxWithheld, netPay, superAmt, periodStart, periodEnd,
			)
		}
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE pay_runs SET status='processed', total_gross=$3, total_tax=$4, total_net=$5, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2`,
		id, bizID, totalGross, totalGross*0.19, totalGross*0.81,
	)
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "PAYROLL_RUN_PROCESSED",
		EntityType: "pay_run",
		EntityID:   runID,
		NewData: map[string]interface{}{
			"total_gross": totalGross,
			"total_tax":   totalGross * 0.19,
			"total_net":   totalGross * 0.81,
		},
	})
	respond(w, 200, map[string]string{"status": "processed"})
}

func (h *Handler) ListPayslips(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	workerID := r.URL.Query().Get("worker_id")
	// Non-elevated callers (worker, accountant, customer) can only see their own payslips.
	// Manager+ may query for any worker in the tenant.
	elevated := middleware.IsAtLeast(claims.Role, "manager")
	if !elevated {
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
		m["id"] = id; m["worker_id"] = wID; m["worker_name"] = wName; m["pay_run_id"] = payRunID
		m["gross_pay"] = gross; m["tax_withheld"] = tax; m["net_pay"] = net; m["super_amount"] = super
		m["period_start"] = periodStart; m["period_end"] = periodEnd; m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) GeneratePayslipPDF(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var psID, workerID, workerName string
	var gross, tax, net, super float64
	var periodStart, periodEnd interface{}
	err := h.db.QueryRow(r.Context(),
		`SELECT ps.id, ps.worker_id, u.first_name||' '||u.last_name, ps.gross_pay, ps.tax_withheld, ps.net_pay, ps.super_amount, ps.period_start, ps.period_end
		 FROM payslips ps JOIN users u ON u.id=ps.worker_id WHERE ps.id=$1 AND ps.business_id=$2`,
		id, bizID,
	).Scan(&psID, &workerID, &workerName, &gross, &tax, &net, &super, &periodStart, &periodEnd)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if !middleware.IsAtLeast(claims.Role, "manager") && workerID != claims.UserID.String() {
		respond(w, 403, map[string]string{"error": "forbidden"})
		return
	}
	respond(w, 200, map[string]interface{}{
		"payslip_id":  psID,
		"worker_name": workerName,
		"period":      fmt.Sprintf("%v to %v", periodStart, periodEnd),
		"gross_pay":   gross,
		"tax_withheld": tax,
		"net_pay":     net,
		"super_amount": super,
	})
}

func (h *Handler) ListSuper(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(),
		`SELECT s.id, s.worker_id, u.first_name||' '||u.last_name, s.amount, s.quarter, s.status, s.due_date
		 FROM superannuation s JOIN users u ON u.id=s.worker_id
		 WHERE s.business_id=$1 ORDER BY s.quarter DESC`, bizID)
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
		m["id"] = id; m["worker_id"] = wID; m["worker_name"] = wName
		m["amount"] = amount; m["quarter"] = quarter; m["status"] = status; m["due_date"] = dueDate
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) CreateLeaveRequest(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	var req struct {
		WorkerID  string  `json:"worker_id"`
		LeaveType string  `json:"leave_type"` // annual|sick|personal|unpaid
		StartDate string  `json:"start_date"`
		EndDate   string  `json:"end_date"`
		Reason    *string `json:"reason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	workerID := req.WorkerID
	if workerID == "" {
		workerID = claims.UserID.String()
	}
	if workerID != claims.UserID.String() && !middleware.IsAtLeast(claims.Role, "admin") {
		respond(w, 403, map[string]string{"error": "forbidden"})
		return
	}
	newID := uuid.New()
	_, err := h.db.Exec(r.Context(),
		`INSERT INTO leave_requests (id, business_id, worker_id, leave_type, start_date, end_date,
		 days_count, reason, status, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5::DATE,$6::DATE,
		 ($6::DATE - $5::DATE + 1)::INT,
		 $7,'pending',NOW(),NOW())`,
		newID, bizID, workerID, req.LeaveType, req.StartDate, req.EndDate, req.Reason,
	)
	if err != nil {
		h.log.Error("create leave request", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	respond(w, 201, map[string]interface{}{"id": newID, "status": "pending"})
}

func (h *Handler) ListLeaveRequests(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	q := r.URL.Query()
	status := q.Get("status")
	workerID := q.Get("worker_id")
	// Non-elevated callers can only see their own leave requests; ignore any
	// worker_id query param that doesn't match themselves.
	if !middleware.IsAtLeast(claims.Role, "manager") {
		workerID = claims.UserID.String()
	}
	query := `SELECT lr.id, lr.worker_id, u.first_name||' '||u.last_name, lr.leave_type, lr.start_date, lr.end_date, lr.days_count, lr.status, lr.created_at
		 FROM leave_requests lr JOIN users u ON u.id=lr.worker_id WHERE lr.business_id=$1`
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
		m["id"] = id; m["worker_id"] = wID; m["worker_name"] = wName
		m["leave_type"] = leaveType; m["start_date"] = startDate; m["end_date"] = endDate
		m["days_count"] = daysCount; m["status"] = leaveStatus; m["created_at"] = createdAt
		list = append(list, m)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

func (h *Handler) ApproveLeave(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	leaveID, _ := uuid.Parse(id)
	_, err := h.db.Exec(r.Context(),
		`UPDATE leave_requests SET status='approved', approved_by=$3, approved_at=NOW(), updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND status='pending'`,
		id, bizID, claims.UserID,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "LEAVE_REQUEST_APPROVED",
		EntityType: "leave_request",
		EntityID:   leaveID,
	})
	respond(w, 200, map[string]string{"status": "approved"})
}

func (h *Handler) RejectLeave(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	leaveID, _ := uuid.Parse(id)
	var req struct {
		Reason *string `json:"rejection_reason"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	_, err := h.db.Exec(r.Context(),
		`UPDATE leave_requests SET status='rejected', rejection_reason=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND status='pending'`,
		id, bizID, req.Reason,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "LEAVE_REQUEST_REJECTED",
		EntityType: "leave_request",
		EntityID:   leaveID,
		NewData:    map[string]interface{}{"rejection_reason": req.Reason},
	})
	respond(w, 200, map[string]string{"status": "rejected"})
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
