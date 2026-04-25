package tasks

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

type Handler struct {
	cfg *config.Config
	db  *pgxpool.Pool
	log *zap.Logger
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger) *Handler {
	return &Handler{cfg: cfg, db: db, log: log}
}

// ── List tasks ────────────────────────────────────────────────────

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	status := r.URL.Query().Get("status")
	if status == "" {
		status = "pending"
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT t.id, t.title, t.description, t.priority, t.status,
		        t.due_date, t.reminder_at, t.completed_at,
		        t.created_by, t.assigned_to,
		        u.first_name||' '||u.last_name AS assigned_name,
		        t.job_id, t.created_at
		 FROM tasks t
		 LEFT JOIN users u ON u.id=t.assigned_to
		 WHERE t.business_id=$1
		   AND ($2='all' OR t.status=$2::task_status)
		   AND (t.assigned_to=$3 OR t.created_by=$3 OR $4='owner' OR $4='admin' OR $4='manager')
		 ORDER BY
		   CASE t.priority WHEN 'urgent' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 ELSE 4 END,
		   t.due_date NULLS LAST, t.created_at DESC
		 LIMIT 100`,
		bizID, status, claims.UserID, claims.Role)
	if err != nil {
		h.log.Error("list tasks", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	var list []map[string]interface{}
	for rows.Next() {
		t := make(map[string]interface{})
		var id, title, desc, priority, taskStatus, createdBy, assignedTo, assignedName, jobID, createdAt interface{}
		var dueDate, reminderAt, completedAt *time.Time
		_ = rows.Scan(&id, &title, &desc, &priority, &taskStatus,
			&dueDate, &reminderAt, &completedAt,
			&createdBy, &assignedTo, &assignedName, &jobID, &createdAt)
		t["id"] = id; t["title"] = title; t["description"] = desc
		t["priority"] = priority; t["status"] = taskStatus
		t["due_date"] = dueDate; t["reminder_at"] = reminderAt; t["completed_at"] = completedAt
		t["created_by"] = createdBy; t["assigned_to"] = assignedTo
		t["assigned_name"] = assignedName; t["job_id"] = jobID; t["created_at"] = createdAt
		if dueDate != nil {
			t["overdue"] = dueDate.Before(time.Now()) && taskStatus == "pending"
		}
		list = append(list, t)
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

// ── Create task ───────────────────────────────────────────────────

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		Title       string  `json:"title"`
		Description string  `json:"description"`
		Priority    string  `json:"priority"`
		AssignedTo  *string `json:"assigned_to"`
		JobID       *string `json:"job_id"`
		DueDate     *string `json:"due_date"`
		ReminderAt  *string `json:"reminder_at"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Title == "" {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if req.Priority == "" {
		req.Priority = "medium"
	}

	var id string
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO tasks (business_id, created_by, assigned_to, job_id, title, description, priority, due_date, reminder_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8::timestamptz,$9::timestamptz)
		 RETURNING id`,
		bizID, claims.UserID, req.AssignedTo, req.JobID,
		req.Title, req.Description, req.Priority,
		req.DueDate, req.ReminderAt,
	).Scan(&id)
	if err != nil {
		h.log.Error("create task", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 201, map[string]string{"id": id})
}

// ── Get task ──────────────────────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	t := make(map[string]interface{})
	var idVal, title, desc, priority, status, createdBy, assignedTo, jobID, createdAt interface{}
	var dueDate, reminderAt, completedAt *time.Time

	err := h.db.QueryRow(r.Context(),
		`SELECT id, title, description, priority, status,
		        due_date, reminder_at, completed_at,
		        created_by, assigned_to, job_id, created_at
		 FROM tasks WHERE id=$1 AND business_id=$2`, id, bizID,
	).Scan(&idVal, &title, &desc, &priority, &status,
		&dueDate, &reminderAt, &completedAt,
		&createdBy, &assignedTo, &jobID, &createdAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	t["id"] = idVal
	t["title"] = title; t["description"] = desc
	t["priority"] = priority; t["status"] = status
	t["due_date"] = dueDate; t["reminder_at"] = reminderAt; t["completed_at"] = completedAt
	t["created_by"] = createdBy; t["assigned_to"] = assignedTo
	t["job_id"] = jobID; t["created_at"] = createdAt
	respond(w, 200, t)
}

// ── Update task ───────────────────────────────────────────────────

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Title       *string `json:"title"`
		Description *string `json:"description"`
		Priority    *string `json:"priority"`
		AssignedTo  *string `json:"assigned_to"`
		DueDate     *string `json:"due_date"`
		ReminderAt  *string `json:"reminder_at"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	tag, err := h.db.Exec(r.Context(),
		`UPDATE tasks SET
		  title=COALESCE($3,title),
		  description=COALESCE($4,description),
		  priority=COALESCE($5::task_priority,priority),
		  assigned_to=COALESCE($6::uuid,assigned_to),
		  due_date=COALESCE($7::timestamptz,due_date),
		  reminder_at=COALESCE($8::timestamptz,reminder_at),
		  updated_at=NOW()
		 WHERE id=$1 AND business_id=$2`,
		id, bizID, req.Title, req.Description, req.Priority,
		req.AssignedTo, req.DueDate, req.ReminderAt)
	if err != nil || tag.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, map[string]string{"message": "updated"})
}

// ── Complete task ─────────────────────────────────────────────────

func (h *Handler) Complete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	tag, _ := h.db.Exec(r.Context(),
		`UPDATE tasks SET status='completed', completed_at=NOW(), completed_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND status='pending'`,
		id, bizID, claims.UserID)
	if tag.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, map[string]string{"message": "completed"})
}

// ── Delete task ───────────────────────────────────────────────────

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	tag, _ := h.db.Exec(r.Context(), `DELETE FROM tasks WHERE id=$1 AND business_id=$2`, id, bizID)
	if tag.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 204, nil)
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
