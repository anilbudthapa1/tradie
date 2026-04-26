// Package reminders exposes HTTP endpoints for Module 13 — Task Reminder.
//
// Two endpoints are provided here:
//
//   - POST /api/v1/internal/reminders/run
//     Drains the due-reminder queue for the current tenant. Owner/admin only.
//     Until a real scheduler exists, ops must hit this on a cron.
//
//   - POST /api/v1/tasks/{id}/snooze
//     Mounted in routes for tasks. Updates `reminder_at` to "now + duration"
//     where duration is one of "1h" or "tomorrow". Author-self or manager+.
package reminders

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
	remsvc "github.com/tradie/api/internal/services/reminders"
)

type Handler struct {
	cfg    *config.Config
	db     *pgxpool.Pool
	log    *zap.Logger
	audit  *middleware.AuditService
	runner *remsvc.Runner
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService, dispatcher remsvc.ReminderDispatcher) *Handler {
	return &Handler{
		cfg:    cfg,
		db:     db,
		log:    log,
		audit:  audit,
		runner: remsvc.NewRunner(db, log, dispatcher),
	}
}

// Run scans this tenant's tasks for due reminders and dispatches them.
//
// Important: this endpoint is scoped to a single business; callers from
// `cmd/cron` (when one exists) should pass `?all=true` plus an internal
// API key — that path is not yet implemented.
func (h *Handler) Run(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	count, err := h.runner.Run(r.Context(), bizID)
	if err != nil {
		h.log.Error("reminders run", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}

	if claims != nil {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     "REMINDERS_RUN",
			EntityType: "task_reminder",
			EntityID:   uuid.Nil,
			NewData:    map[string]int{"dispatched": count},
			IPAddress:  r.RemoteAddr,
		})
	}

	respond(w, 200, map[string]interface{}{
		"dispatched": count,
		"backend":    "noop",
	})
}

// Snooze updates a task's reminder_at to NOW() + duration.
//
// Body: {"duration": "1h" | "tomorrow"} (default "1h").
// Authorization: caller must be the task assignee, the creator,
// or have manager+ role. Tenant scoping is enforced by business_id.
func (h *Handler) Snooze(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	if claims == nil {
		respond(w, 401, map[string]string{"error": "unauthorized"})
		return
	}

	var req struct {
		Duration string `json:"duration"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.Duration == "" {
		req.Duration = "1h"
	}

	now := time.Now()
	var newReminder time.Time
	switch req.Duration {
	case "1h":
		newReminder = now.Add(time.Hour)
	case "tomorrow":
		// 9am local time tomorrow.
		t := now.AddDate(0, 0, 1)
		newReminder = time.Date(t.Year(), t.Month(), t.Day(), 9, 0, 0, 0, t.Location())
	case "15m":
		newReminder = now.Add(15 * time.Minute)
	case "1d":
		newReminder = now.AddDate(0, 0, 1)
	default:
		respond(w, 400, map[string]string{"error": "invalid_duration"})
		return
	}

	// Verify ownership / role for this task before mutating.
	var assignedTo, createdBy *uuid.UUID
	err := h.db.QueryRow(r.Context(),
		`SELECT assigned_to, created_by FROM tasks WHERE id=$1 AND business_id=$2`,
		id, bizID,
	).Scan(&assignedTo, &createdBy)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respond(w, 404, map[string]string{"error": "not_found"})
			return
		}
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}

	isOwn := (assignedTo != nil && *assignedTo == claims.UserID) ||
		(createdBy != nil && *createdBy == claims.UserID)
	if !isOwn && !middleware.IsAtLeast(claims.Role, "manager") {
		respond(w, 403, map[string]string{"error": "forbidden"})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE tasks SET reminder_at=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2`,
		id, bizID, newReminder)
	if err != nil || tag.RowsAffected() == 0 {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}

	taskUUID, _ := uuid.Parse(id)
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "TASK_SNOOZED",
		EntityType: "task",
		EntityID:   taskUUID,
		NewData:    map[string]interface{}{"duration": req.Duration, "reminder_at": newReminder},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, 200, map[string]interface{}{
		"id":          id,
		"reminder_at": newReminder,
	})
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		_ = json.NewEncoder(w).Encode(data)
	}
}
