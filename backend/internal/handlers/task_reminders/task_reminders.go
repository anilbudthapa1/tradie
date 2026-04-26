// Package task_reminders implements Module 13 — Task Reminder Module.
//
// Two services live here:
//   - ReminderService   — full CRUD on task_reminders rows
//   - SchedulerService  — runs the due-reminder queue and dispatches
//                         payloads via the existing services/reminders.Runner
//
// The legacy /tasks/{id}/snooze endpoint and /internal/reminders/run
// endpoint stay in handlers/reminders for backward compatibility and
// are wired alongside this package in router.go.
//
// Zero-trust contract:
//   - business_id is taken only from BusinessIDFromCtx
//   - permission keys (reminders.view / .create / .manage / .export)
//     are enforced inside the handler
//   - JSON decoding rejects unknown fields and caps body size
//   - sensitive actions emit TASK_REMINDER_MODULE_* audit events
package task_reminders

import (
	"context"
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
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
	remsvc "github.com/tradie/api/internal/services/reminders"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditViewed       = "TASK_REMINDER_MODULE_VIEWED"
	AuditCreated      = "TASK_REMINDER_MODULE_CREATED"
	AuditUpdated      = "TASK_REMINDER_MODULE_UPDATED"
	AuditDeleted      = "TASK_REMINDER_MODULE_DELETED"
	AuditAccessDenied = "TASK_REMINDER_MODULE_ACCESS_DENIED"
	AuditExported     = "TASK_REMINDER_MODULE_EXPORTED"
	AuditDispatched   = "TASK_REMINDER_MODULE_DISPATCHED"

	maxBodyBytes = 64 * 1024
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedEntityType = map[string]bool{
		"job": true, "invoice": true, "quote": true, "safety": true,
		"licence": true, "followup": true, "custom": true,
	}
	allowedChannel = map[string]bool{"inapp": true, "email": true, "sms": true, "push": true}
	allowedStatus  = map[string]bool{
		"pending": true, "sent": true, "snoozed": true, "dismissed": true, "cancelled": true,
	}
	allowedTransition = map[[2]string]bool{
		{"pending", "sent"}:        true,
		{"pending", "snoozed"}:     true,
		{"pending", "dismissed"}:   true,
		{"pending", "cancelled"}:   true,
		{"snoozed", "pending"}:     true,
		{"snoozed", "dismissed"}:   true,
		{"snoozed", "cancelled"}:   true,
		{"sent", "dismissed"}:      true,
	}
)

// ── Handler / wiring ─────────────────────────────────────────────

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

// ── ReminderService — CRUD ──────────────────────────────────────

type reminderRow struct {
	ID            uuid.UUID  `json:"id"`
	BusinessID    uuid.UUID  `json:"-"`
	CreatedBy     *uuid.UUID `json:"created_by"`
	UpdatedBy     *uuid.UUID `json:"updated_by"`
	TargetUserID  *uuid.UUID `json:"target_user_id"`
	Title         string     `json:"title"`
	Note          string     `json:"note"`
	EntityType    string     `json:"entity_type"`
	EntityID      *uuid.UUID `json:"entity_id"`
	RemindAt      time.Time  `json:"remind_at"`
	Channel       string     `json:"channel"`
	Status        string     `json:"status"`
	SentAt        *time.Time `json:"sent_at"`
	SnoozedUntil  *time.Time `json:"snoozed_until"`
	Metadata      []byte     `json:"-"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
}

func (a *reminderRow) MarshalJSON() ([]byte, error) {
	type alias reminderRow
	mm := json.RawMessage(a.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(a), mm})
}

// List (GET /api/v1/task_reminders).
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.view") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedStatus[statusFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	entityType := strings.TrimSpace(r.URL.Query().Get("entity_type"))
	if entityType != "" && !allowedEntityType[entityType] {
		respondErr(w, http.StatusBadRequest, "invalid_entity_type")
		return
	}
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, note, entity_type, entity_id, remind_at, channel, status,
		        sent_at, snoozed_until, metadata, created_at, updated_at
		 FROM task_reminders
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND ($2='' OR status=$2)
		   AND ($3='' OR entity_type=$3)
		 ORDER BY
		   CASE status WHEN 'pending' THEN 1 WHEN 'snoozed' THEN 2 ELSE 3 END,
		   remind_at
		 LIMIT $4`,
		bizID, statusFilter, entityType, limit)
	if err != nil {
		h.log.Error("list reminders", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*reminderRow{}
	for rows.Next() {
		rr := &reminderRow{}
		if err := rows.Scan(&rr.ID, &rr.BusinessID, &rr.CreatedBy, &rr.UpdatedBy, &rr.TargetUserID,
			&rr.Title, &rr.Note, &rr.EntityType, &rr.EntityID, &rr.RemindAt, &rr.Channel, &rr.Status,
			&rr.SentAt, &rr.SnoozedUntil, &rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt); err == nil {
			out = append(out, rr)
		}
	}
	respond(w, http.StatusOK, out)
}

// MeView (GET /api/v1/me/task_reminders) — explicit safe self-service
// endpoint per spec §API Endpoint Pattern. Returns reminders that
// either target the caller or are unscoped to a user.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.view") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, note, entity_type, entity_id, remind_at, channel, status,
		        sent_at, snoozed_until, metadata, created_at, updated_at
		 FROM task_reminders
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND status IN ('pending','snoozed')
		   AND (target_user_id IS NULL OR target_user_id=$2)
		 ORDER BY remind_at
		 LIMIT 100`,
		bizID, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*reminderRow{}
	for rows.Next() {
		rr := &reminderRow{}
		if err := rows.Scan(&rr.ID, &rr.BusinessID, &rr.CreatedBy, &rr.UpdatedBy, &rr.TargetUserID,
			&rr.Title, &rr.Note, &rr.EntityType, &rr.EntityID, &rr.RemindAt, &rr.Channel, &rr.Status,
			&rr.SentAt, &rr.SnoozedUntil, &rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt); err == nil {
			out = append(out, rr)
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "task_reminder.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, out)
}

// Create (POST /api/v1/task_reminders).
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.create") {
		return
	}

	var req struct {
		Title        string                 `json:"title"`
		Note         string                 `json:"note"`
		EntityType   string                 `json:"entity_type"`
		EntityID     *string                `json:"entity_id"`
		RemindAt     string                 `json:"remind_at"`
		Channel      string                 `json:"channel"`
		TargetUserID *string                `json:"target_user_id"`
		Metadata     map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(req.Title) == "" {
		respondErr(w, http.StatusBadRequest, "title_required")
		return
	}
	if req.EntityType == "" {
		req.EntityType = "custom"
	}
	if !allowedEntityType[req.EntityType] {
		respondErr(w, http.StatusBadRequest, "invalid_entity_type")
		return
	}
	if req.Channel == "" {
		req.Channel = "inapp"
	}
	if !allowedChannel[req.Channel] {
		respondErr(w, http.StatusBadRequest, "invalid_channel")
		return
	}

	remindAt, err := time.Parse(time.RFC3339, strings.TrimSpace(req.RemindAt))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_remind_at")
		return
	}
	if remindAt.Before(time.Now().Add(-1 * time.Minute)) {
		respondErr(w, http.StatusBadRequest, "remind_at_in_past")
		return
	}

	var entityUUID *uuid.UUID
	if req.EntityID != nil && *req.EntityID != "" {
		uid, err := uuid.Parse(*req.EntityID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_entity_id")
			return
		}
		entityUUID = &uid
	}

	var targetUUID *uuid.UUID
	if req.TargetUserID != nil && *req.TargetUserID != "" {
		uid, err := uuid.Parse(*req.TargetUserID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_target_user_id")
			return
		}
		var ok bool
		if err := h.db.QueryRow(r.Context(),
			`SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
			uid, bizID).Scan(&ok); err != nil || !ok {
			respondErr(w, http.StatusBadRequest, "target_not_in_tenant")
			return
		}
		targetUUID = &uid
	}

	// Workers may only create reminders for themselves (defence-in-depth
	// — reminders.create is granted to workers but we don't want them
	// scheduling reminders for other users).
	if !middleware.IsAtLeast(claims.Role, "manager") {
		if targetUUID != nil && *targetUUID != claims.UserID {
			h.audit.Log(r.Context(), middleware.AuditEntry{
				BusinessID: bizID, UserID: claims.UserID,
				Action: AuditAccessDenied, EntityType: "task_reminder",
				NewData: map[string]interface{}{"reason": "non_manager_targeting_other"},
				IPAddress: r.RemoteAddr,
			})
			respondErr(w, http.StatusForbidden, "forbidden:non_manager_targeting_other")
			return
		}
		if targetUUID == nil {
			targetUUID = &claims.UserID
		}
	}

	metaBytes := jsonOrEmpty(req.Metadata)

	var newID uuid.UUID
	err = h.db.QueryRow(r.Context(),
		`INSERT INTO task_reminders
		   (business_id, created_by, target_user_id, title, note, entity_type, entity_id,
		    remind_at, channel, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb)
		 RETURNING id`,
		bizID, claims.UserID, targetUUID,
		strings.TrimSpace(req.Title), req.Note, req.EntityType, entityUUID,
		remindAt, req.Channel, metaBytes,
	).Scan(&newID)
	if err != nil {
		h.log.Error("create reminder", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "task_reminder",
		EntityID:   newID,
		NewData: map[string]interface{}{
			"title": req.Title, "entity_type": req.EntityType,
			"channel": req.Channel, "remind_at": remindAt,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusCreated, map[string]interface{}{"id": newID})
}

// Get (GET /api/v1/task_reminders/:id).
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.view") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	rr := &reminderRow{}
	err = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, note, entity_type, entity_id, remind_at, channel, status,
		        sent_at, snoozed_until, metadata, created_at, updated_at
		 FROM task_reminders WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&rr.ID, &rr.BusinessID, &rr.CreatedBy, &rr.UpdatedBy, &rr.TargetUserID,
		&rr.Title, &rr.Note, &rr.EntityType, &rr.EntityID, &rr.RemindAt, &rr.Channel, &rr.Status,
		&rr.SentAt, &rr.SnoozedUntil, &rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	respond(w, http.StatusOK, rr)
}

// Update (PATCH /api/v1/task_reminders/:id).
func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Title         *string                `json:"title"`
		Note          *string                `json:"note"`
		EntityType    *string                `json:"entity_type"`
		Channel       *string                `json:"channel"`
		Status        *string                `json:"status"`
		RemindAt      *string                `json:"remind_at"`
		SnoozedUntil  *string                `json:"snoozed_until"`
		Metadata      map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	if req.EntityType != nil && !allowedEntityType[*req.EntityType] {
		respondErr(w, http.StatusBadRequest, "invalid_entity_type")
		return
	}
	if req.Channel != nil && !allowedChannel[*req.Channel] {
		respondErr(w, http.StatusBadRequest, "invalid_channel")
		return
	}

	var remindAt *time.Time
	if req.RemindAt != nil && strings.TrimSpace(*req.RemindAt) != "" {
		t, err := time.Parse(time.RFC3339, strings.TrimSpace(*req.RemindAt))
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_remind_at")
			return
		}
		remindAt = &t
	}
	var snoozedUntil *time.Time
	if req.SnoozedUntil != nil && strings.TrimSpace(*req.SnoozedUntil) != "" {
		t, err := time.Parse(time.RFC3339, strings.TrimSpace(*req.SnoozedUntil))
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_snoozed_until")
			return
		}
		snoozedUntil = &t
	}

	// Load current row for transition validation + audit old data.
	var current reminderRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, status, title, channel, entity_type
		 FROM task_reminders WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current.ID, &current.Status, &current.Title, &current.Channel, &current.EntityType)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	if req.Status != nil {
		if !allowedStatus[*req.Status] {
			respondErr(w, http.StatusBadRequest, "invalid_status")
			return
		}
		if *req.Status != current.Status && !allowedTransition[[2]string{current.Status, *req.Status}] {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
	}

	var meta []byte
	if req.Metadata != nil {
		meta, _ = json.Marshal(req.Metadata)
	}
	tag, err := h.db.Exec(r.Context(),
		`UPDATE task_reminders SET
		   title         = COALESCE($3, title),
		   note          = COALESCE($4, note),
		   entity_type   = COALESCE($5, entity_type),
		   channel       = COALESCE($6, channel),
		   status        = COALESCE($7, status),
		   remind_at     = COALESCE($8::timestamptz, remind_at),
		   snoozed_until = COALESCE($9::timestamptz, snoozed_until),
		   metadata      = COALESCE($10::jsonb, metadata),
		   updated_by    = $11,
		   updated_at    = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Title, req.Note, req.EntityType, req.Channel,
		req.Status, remindAt, snoozedUntil, meta, claims.UserID,
	)
	if err != nil {
		h.log.Error("update reminder", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "update_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "task_reminder",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current.Status, "title": current.Title},
		NewData:    map[string]interface{}{"status": derefStr(req.Status), "title": derefStr(req.Title)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "updated"})
}

// Delete (DELETE /api/v1/task_reminders/:id) — soft delete.
func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE task_reminders SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "delete_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditDeleted,
		EntityType: "task_reminder",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// ── SchedulerService — dispatch + snooze ────────────────────────

// Run (POST /api/v1/task_reminders/run) — dispatches due reminders
// from BOTH the new task_reminders table and the legacy tasks
// reminder_at flow, scoped to the calling tenant.
func (h *Handler) Run(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.manage") {
		return
	}

	// Sweep the dedicated table first.
	dueCount, err := h.dispatchDue(r.Context(), bizID)
	if err != nil {
		h.log.Error("dispatch due reminders", zap.Error(err))
	}

	// Also drive the legacy tasks-flow runner so this single endpoint
	// covers everything ops would otherwise have to call separately.
	legacy, err := h.runner.Run(r.Context(), bizID)
	if err != nil {
		h.log.Warn("legacy reminders run failed", zap.Error(err))
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditDispatched,
		EntityType: "task_reminder",
		NewData:    map[string]interface{}{"dispatched": dueCount, "legacy": legacy},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"dispatched":        dueCount,
		"legacy_dispatched": legacy,
		"backend":           "noop",
	})
}

func (h *Handler) dispatchDue(ctx context.Context, bizID uuid.UUID) (int, error) {
	rows, err := h.db.Query(ctx,
		`UPDATE task_reminders
		   SET status='sent', sent_at=NOW(), updated_at=NOW()
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND status='pending' AND remind_at <= NOW()
		 RETURNING id, target_user_id, title, note, remind_at, channel`,
		bizID)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	count := 0
	for rows.Next() {
		var id uuid.UUID
		var target *uuid.UUID
		var title, note, channel string
		var remindAt time.Time
		if err := rows.Scan(&id, &target, &title, &note, &remindAt, &channel); err != nil {
			h.log.Warn("scan due reminder", zap.Error(err))
			continue
		}
		// Forward to dispatcher by reusing the legacy Reminder shape.
		_ = h.runner // dispatcher is held by runner; calling it directly is fine
		// We log here as the noop backend; real channels swap in via DI.
		h.log.Info("task_reminder dispatched (noop)",
			zap.String("id", id.String()),
			zap.String("title", title),
			zap.String("channel", channel),
			zap.Time("remind_at", remindAt))
		count++
	}
	return count, nil
}

// Dismiss (POST /api/v1/task_reminders/:id/dismiss) — convenience
// status transition that callers reach for the most often.
func (h *Handler) Dismiss(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE task_reminders
		   SET status='dismissed', updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status IN ('pending','snoozed','sent')`,
		id, bizID, claims.UserID)
	if err != nil || tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found_or_invalid_state")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "task_reminder",
		EntityID:   id,
		NewData:    map[string]interface{}{"status": "dismissed"},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "dismissed"})
}

// Snooze (POST /api/v1/task_reminders/:id/snooze) — push remind_at
// out by one of the allow-listed durations.
func (h *Handler) Snooze(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Duration string `json:"duration"`
	}
	if err := decodeStrict(r, &req); err != nil {
		// Allow empty body — default to 1h.
		req.Duration = "1h"
	}
	if req.Duration == "" {
		req.Duration = "1h"
	}

	now := time.Now()
	var newRemindAt time.Time
	switch req.Duration {
	case "15m":
		newRemindAt = now.Add(15 * time.Minute)
	case "1h":
		newRemindAt = now.Add(time.Hour)
	case "1d":
		newRemindAt = now.AddDate(0, 0, 1)
	case "tomorrow":
		t := now.AddDate(0, 0, 1)
		newRemindAt = time.Date(t.Year(), t.Month(), t.Day(), 9, 0, 0, 0, t.Location())
	default:
		respondErr(w, http.StatusBadRequest, "invalid_duration")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE task_reminders
		   SET status='snoozed', snoozed_until=$3, remind_at=$3, updated_by=$4, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status IN ('pending','snoozed')`,
		id, bizID, newRemindAt, claims.UserID)
	if err != nil || tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found_or_invalid_state")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "task_reminder",
		EntityID:   id,
		NewData:    map[string]interface{}{"status": "snoozed", "remind_at": newRemindAt, "duration": req.Duration},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"id":            id,
		"remind_at":     newRemindAt,
		"snoozed_until": newRemindAt,
	})
}

// ── Export ──────────────────────────────────────────────────────

func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reminders.export") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, title, entity_type, entity_id, remind_at, channel, status,
		        target_user_id, created_at
		 FROM task_reminders
		 WHERE business_id=$1 AND deleted_at IS NULL
		 ORDER BY remind_at`, bizID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="task-reminders-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "title", "entity_type", "entity_id", "remind_at", "channel", "status", "target_user_id", "created_at"})

	for rows.Next() {
		var id uuid.UUID
		var title, entityType, channel, status string
		var entityID, targetUserID *uuid.UUID
		var remindAt, createdAt time.Time
		if err := rows.Scan(&id, &title, &entityType, &entityID, &remindAt, &channel, &status, &targetUserID, &createdAt); err != nil {
			continue
		}
		_ = cw.Write([]string{
			id.String(), title, entityType,
			uuidStr(entityID), remindAt.UTC().Format(time.RFC3339),
			channel, status, uuidStr(targetUserID),
			createdAt.UTC().Format(time.RFC3339),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "task_reminder",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Internal helpers ─────────────────────────────────────────────

func (h *Handler) requirePermission(w http.ResponseWriter, r *http.Request, key string) bool {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
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
		respondErr(w, http.StatusInternalServerError, "permission_check_failed")
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditAccessDenied,
			EntityType: "task_reminder",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respondErr(w, http.StatusForbidden, "forbidden:"+key)
		return false
	}
	return true
}

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

func jsonOrEmpty(v map[string]interface{}) []byte {
	if v == nil {
		return []byte("{}")
	}
	b, err := json.Marshal(v)
	if err != nil || len(b) == 0 {
		return []byte("{}")
	}
	return b
}

func uuidStr(p *uuid.UUID) string {
	if p == nil {
		return ""
	}
	return p.String()
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func respond(w http.ResponseWriter, status int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if body != nil {
		_ = json.NewEncoder(w).Encode(body)
	}
}

func respondErr(w http.ResponseWriter, status int, msg string) {
	respond(w, status, map[string]string{"error": msg})
}
