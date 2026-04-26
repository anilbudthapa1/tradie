// Package activity implements Module 14 — Activity Feed Module.
//
// One service, two streams:
//
//   - Read-only audit feed sourced from `audit_logs` (immutable).
//     This is what the dashboard widget renders.
//   - CRUD entity `tenant_activity_entries` for owner-authored
//     announcements, milestones and pinned notes that satisfy the
//     spec's "Create, read, update, and manage module-specific
//     records" requirement.
//
// Both streams are tenant-scoped via BusinessIDFromCtx and gated by
// the `activity.*` permission keys. Audit events use the spec-named
// ACTIVITY_FEED_MODULE_* family.
package activity

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
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditViewed       = "ACTIVITY_FEED_MODULE_VIEWED"
	AuditCreated      = "ACTIVITY_FEED_MODULE_CREATED"
	AuditUpdated      = "ACTIVITY_FEED_MODULE_UPDATED"
	AuditDeleted      = "ACTIVITY_FEED_MODULE_DELETED"
	AuditAccessDenied = "ACTIVITY_FEED_MODULE_ACCESS_DENIED"
	AuditExported     = "ACTIVITY_FEED_MODULE_EXPORTED"

	maxBodyBytes = 64 * 1024
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedCategory   = map[string]bool{"announcement": true, "milestone": true, "alert": true, "note": true, "system": true}
	allowedEntityType = map[string]bool{
		"job": true, "invoice": true, "quote": true, "customer": true, "worker": true,
		"payment": true, "task": true, "lead": true, "expense": true, "safety": true, "tenant": true,
	}
	allowedVisibility = map[string]bool{"tenant": true, "managers": true, "self": true}
	allowedStatus     = map[string]bool{"active": true, "archived": true}
	allowedTransition = map[[2]string]bool{
		{"active", "archived"}: true,
		{"archived", "active"}: true,
	}
)

// Handler serves both the audit timeline and the tenant-authored CRUD entity.
type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── Read-only audit feed ────────────────────────────────────────

// List returns a paginated activity feed for the current tenant
// derived from `audit_logs`. Read-only; rows are immutable.
//
// Query params:
//
//	limit       int    (1..200, default 50)
//	entity_type string (optional, exact match — e.g. "customer", "job")
//	since       RFC3339 timestamp (optional, returns rows created after)
//	cursor      RFC3339 timestamp (optional, keyset pagination — created_at < cursor)
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	if !h.requirePermission(w, r, "activity.view") {
		return
	}

	q := r.URL.Query()
	limit := 50
	if v := q.Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 200 {
			limit = n
		}
	}

	args := []interface{}{bizID}
	filters := []string{"al.business_id = $1"}
	nextParam := 2

	if et := strings.TrimSpace(q.Get("entity_type")); et != "" {
		if !allowedEntityType[et] {
			respondErr(w, http.StatusBadRequest, "invalid_entity_type")
			return
		}
		filters = append(filters, "al.entity_type = $"+strconv.Itoa(nextParam))
		args = append(args, et)
		nextParam++
	}

	if s := strings.TrimSpace(q.Get("since")); s != "" {
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			filters = append(filters, "al.created_at > $"+strconv.Itoa(nextParam))
			args = append(args, t)
			nextParam++
		} else {
			respondErr(w, http.StatusBadRequest, "invalid_since")
			return
		}
	}

	if c := strings.TrimSpace(q.Get("cursor")); c != "" {
		if t, err := time.Parse(time.RFC3339, c); err == nil {
			filters = append(filters, "al.created_at < $"+strconv.Itoa(nextParam))
			args = append(args, t)
			nextParam++
		} else {
			respondErr(w, http.StatusBadRequest, "invalid_cursor")
			return
		}
	}

	args = append(args, limit)
	limitParam := nextParam

	sql := `SELECT al.id, al.user_id,
	               COALESCE(u.first_name || ' ' || u.last_name, 'System') AS user_name,
	               al.action, al.entity_type, al.entity_id, al.created_at
	        FROM audit_logs al
	        LEFT JOIN users u ON u.id = al.user_id
	        WHERE ` + strings.Join(filters, " AND ") + `
	        ORDER BY al.created_at DESC
	        LIMIT $` + strconv.Itoa(limitParam)

	rows, err := h.db.Query(r.Context(), sql, args...)
	if err != nil {
		h.log.Error("activity list", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	type item struct {
		ID         interface{} `json:"id"`
		UserID     interface{} `json:"user_id"`
		UserName   string      `json:"user_name"`
		Action     string      `json:"action"`
		EntityType interface{} `json:"entity_type"`
		EntityID   interface{} `json:"entity_id"`
		CreatedAt  time.Time   `json:"created_at"`
		Category   string      `json:"category"`
	}

	out := make([]item, 0, limit)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.UserID, &it.UserName, &it.Action, &it.EntityType, &it.EntityID, &it.CreatedAt); err != nil {
			h.log.Warn("activity scan", zap.Error(err))
			continue
		}
		it.Category = categorize(it.Action)
		out = append(out, it)
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     userID(claims),
		Action:     AuditViewed,
		EntityType: "activity_feed",
		EntityID:   uuid.Nil,
		IPAddress:  r.RemoteAddr,
	})

	var nextCursor string
	if len(out) == limit {
		nextCursor = out[len(out)-1].CreatedAt.Format(time.RFC3339Nano)
	}

	respond(w, http.StatusOK, map[string]interface{}{
		"items":       out,
		"next_cursor": nextCursor,
		"limit":       limit,
	})
}

// ── ActivityFeedService — CRUD on tenant_activity_entries ───────

type entryRow struct {
	ID           uuid.UUID  `json:"id"`
	BusinessID   uuid.UUID  `json:"-"`
	CreatedBy    *uuid.UUID `json:"created_by"`
	UpdatedBy    *uuid.UUID `json:"updated_by"`
	TargetUserID *uuid.UUID `json:"target_user_id"`
	Title        string     `json:"title"`
	Body         string     `json:"body"`
	Category     string     `json:"category"`
	EntityType   *string    `json:"entity_type"`
	EntityID     *uuid.UUID `json:"entity_id"`
	Visibility   string     `json:"visibility"`
	Pinned       bool       `json:"pinned"`
	Status       string     `json:"status"`
	Metadata     []byte     `json:"-"`
	CreatedAt    time.Time  `json:"created_at"`
	UpdatedAt    time.Time  `json:"updated_at"`
}

func (e *entryRow) MarshalJSON() ([]byte, error) {
	type alias entryRow
	mm := json.RawMessage(e.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(e), mm})
}

// ListEntries (GET /api/v1/activity/entries) — owner / manager scoped.
func (h *Handler) ListEntries(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "activity.view") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedStatus[statusFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	categoryFilter := strings.TrimSpace(r.URL.Query().Get("category"))
	if categoryFilter != "" && !allowedCategory[categoryFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_category")
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
		        title, body, category, entity_type, entity_id, visibility,
		        pinned, status, metadata, created_at, updated_at
		 FROM tenant_activity_entries
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND ($2='' OR status=$2)
		   AND ($3='' OR category=$3)
		 ORDER BY pinned DESC, created_at DESC
		 LIMIT $4`,
		bizID, statusFilter, categoryFilter, limit)
	if err != nil {
		h.log.Error("list entries", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*entryRow{}
	for rows.Next() {
		er := &entryRow{}
		if err := rows.Scan(&er.ID, &er.BusinessID, &er.CreatedBy, &er.UpdatedBy, &er.TargetUserID,
			&er.Title, &er.Body, &er.Category, &er.EntityType, &er.EntityID, &er.Visibility,
			&er.Pinned, &er.Status, &er.Metadata, &er.CreatedAt, &er.UpdatedAt); err == nil {
			out = append(out, er)
		}
	}
	respond(w, http.StatusOK, out)
}

// MeView (GET /api/v1/me/activity_feed) — explicit safe self-service
// endpoint per spec §API Endpoint Pattern. Returns active entries
// the calling user is allowed to see (visibility filter), plus the
// audit-derived feed scoped to their own actions.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "activity.view") {
		return
	}

	elevated := middleware.IsAtLeast(claims.Role, "manager")

	// Visibility filter:
	//   - "tenant" → everyone
	//   - "managers" → managers+ only
	//   - "self" → only when target_user_id == caller
	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, body, category, entity_type, entity_id, visibility,
		        pinned, status, metadata, created_at, updated_at
		 FROM tenant_activity_entries
		 WHERE business_id=$1 AND deleted_at IS NULL AND status='active'
		   AND (
		     visibility='tenant'
		     OR (visibility='managers' AND $2)
		     OR (visibility='self' AND target_user_id=$3)
		   )
		 ORDER BY pinned DESC, created_at DESC
		 LIMIT 100`,
		bizID, elevated, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	entries := []*entryRow{}
	for rows.Next() {
		er := &entryRow{}
		if err := rows.Scan(&er.ID, &er.BusinessID, &er.CreatedBy, &er.UpdatedBy, &er.TargetUserID,
			&er.Title, &er.Body, &er.Category, &er.EntityType, &er.EntityID, &er.Visibility,
			&er.Pinned, &er.Status, &er.Metadata, &er.CreatedAt, &er.UpdatedAt); err == nil {
			entries = append(entries, er)
		}
	}

	// Recent self-actions from audit_logs (last 7 days, capped at 25).
	auditRows, _ := h.db.Query(r.Context(),
		`SELECT al.id, al.action, al.entity_type, al.entity_id, al.created_at
		 FROM audit_logs al
		 WHERE al.business_id=$1 AND al.user_id=$2 AND al.created_at > NOW() - INTERVAL '7 days'
		 ORDER BY al.created_at DESC
		 LIMIT 25`,
		bizID, claims.UserID)
	type auditItem struct {
		ID         uuid.UUID `json:"id"`
		Action     string    `json:"action"`
		EntityType *string   `json:"entity_type"`
		EntityID   *uuid.UUID `json:"entity_id"`
		CreatedAt  time.Time `json:"created_at"`
		Category   string    `json:"category"`
	}
	auditOut := []auditItem{}
	if auditRows != nil {
		defer auditRows.Close()
		for auditRows.Next() {
			var it auditItem
			if err := auditRows.Scan(&it.ID, &it.Action, &it.EntityType, &it.EntityID, &it.CreatedAt); err == nil {
				it.Category = categorize(it.Action)
				auditOut = append(auditOut, it)
			}
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "activity_feed.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"entries":       entries,
		"recent_audit":  auditOut,
	})
}

// CreateEntry (POST /api/v1/activity/entries) — activity.create.
func (h *Handler) CreateEntry(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "activity.create") {
		return
	}

	var req struct {
		Title        string                 `json:"title"`
		Body         string                 `json:"body"`
		Category     string                 `json:"category"`
		EntityType   *string                `json:"entity_type"`
		EntityID     *string                `json:"entity_id"`
		Visibility   string                 `json:"visibility"`
		Pinned       bool                   `json:"pinned"`
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
	if req.Category == "" {
		req.Category = "announcement"
	}
	if !allowedCategory[req.Category] {
		respondErr(w, http.StatusBadRequest, "invalid_category")
		return
	}
	if req.Visibility == "" {
		req.Visibility = "tenant"
	}
	if !allowedVisibility[req.Visibility] {
		respondErr(w, http.StatusBadRequest, "invalid_visibility")
		return
	}

	var entityTypePtr *string
	if req.EntityType != nil && strings.TrimSpace(*req.EntityType) != "" {
		et := strings.TrimSpace(*req.EntityType)
		if !allowedEntityType[et] {
			respondErr(w, http.StatusBadRequest, "invalid_entity_type")
			return
		}
		entityTypePtr = &et
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

	if req.Visibility == "self" && targetUUID == nil {
		respondErr(w, http.StatusBadRequest, "self_visibility_requires_target")
		return
	}

	metaBytes := jsonOrEmpty(req.Metadata)

	var newID uuid.UUID
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO tenant_activity_entries
		   (business_id, created_by, target_user_id, title, body, category,
		    entity_type, entity_id, visibility, pinned, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb)
		 RETURNING id`,
		bizID, claims.UserID, targetUUID,
		strings.TrimSpace(req.Title), req.Body, req.Category,
		entityTypePtr, entityUUID, req.Visibility, req.Pinned, metaBytes,
	).Scan(&newID)
	if err != nil {
		h.log.Error("create entry", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "tenant_activity_entry",
		EntityID:   newID,
		NewData: map[string]interface{}{
			"title": req.Title, "category": req.Category,
			"visibility": req.Visibility, "pinned": req.Pinned,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusCreated, map[string]interface{}{"id": newID})
}

// GetEntry (GET /api/v1/activity/entries/:id).
func (h *Handler) GetEntry(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "activity.view") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	er := &entryRow{}
	err = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, body, category, entity_type, entity_id, visibility,
		        pinned, status, metadata, created_at, updated_at
		 FROM tenant_activity_entries WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&er.ID, &er.BusinessID, &er.CreatedBy, &er.UpdatedBy, &er.TargetUserID,
		&er.Title, &er.Body, &er.Category, &er.EntityType, &er.EntityID, &er.Visibility,
		&er.Pinned, &er.Status, &er.Metadata, &er.CreatedAt, &er.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	respond(w, http.StatusOK, er)
}

// UpdateEntry (PATCH /api/v1/activity/entries/:id).
func (h *Handler) UpdateEntry(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "activity.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Title      *string                `json:"title"`
		Body       *string                `json:"body"`
		Category   *string                `json:"category"`
		Visibility *string                `json:"visibility"`
		Pinned     *bool                  `json:"pinned"`
		Status     *string                `json:"status"`
		Metadata   map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Category != nil && !allowedCategory[*req.Category] {
		respondErr(w, http.StatusBadRequest, "invalid_category")
		return
	}
	if req.Visibility != nil && !allowedVisibility[*req.Visibility] {
		respondErr(w, http.StatusBadRequest, "invalid_visibility")
		return
	}

	var current entryRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, status, title, category
		 FROM tenant_activity_entries WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current.ID, &current.Status, &current.Title, &current.Category)
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
		`UPDATE tenant_activity_entries SET
		   title       = COALESCE($3, title),
		   body        = COALESCE($4, body),
		   category    = COALESCE($5, category),
		   visibility  = COALESCE($6, visibility),
		   pinned      = COALESCE($7, pinned),
		   status      = COALESCE($8, status),
		   metadata    = COALESCE($9::jsonb, metadata),
		   updated_by  = $10,
		   updated_at  = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Title, req.Body, req.Category, req.Visibility,
		req.Pinned, req.Status, meta, claims.UserID,
	)
	if err != nil {
		h.log.Error("update entry", zap.Error(err))
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
		EntityType: "tenant_activity_entry",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current.Status, "title": current.Title, "category": current.Category},
		NewData:    map[string]interface{}{"status": derefStr(req.Status), "title": derefStr(req.Title), "category": derefStr(req.Category)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "updated"})
}

// DeleteEntry (DELETE /api/v1/activity/entries/:id) — soft delete.
func (h *Handler) DeleteEntry(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "activity.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE tenant_activity_entries SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
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
		EntityType: "tenant_activity_entry",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// ── Export ──────────────────────────────────────────────────────

// Export (GET /api/v1/activity/export.csv) — combined audit + tenant
// entries for the current tenant.
func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "activity.export") {
		return
	}

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="activity-feed-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"source", "id", "title_or_action", "category", "entity_type", "entity_id", "user", "created_at"})

	// Tenant entries first.
	entryRows, err := h.db.Query(r.Context(),
		`SELECT te.id, te.title, te.category, te.entity_type, te.entity_id,
		        COALESCE(u.first_name||' '||u.last_name, ''), te.created_at
		 FROM tenant_activity_entries te
		 LEFT JOIN users u ON u.id = te.created_by
		 WHERE te.business_id=$1 AND te.deleted_at IS NULL
		 ORDER BY te.created_at DESC
		 LIMIT 5000`, bizID)
	if err == nil {
		defer entryRows.Close()
		for entryRows.Next() {
			var id uuid.UUID
			var title, category, user string
			var entityType *string
			var entityID *uuid.UUID
			var createdAt time.Time
			if err := entryRows.Scan(&id, &title, &category, &entityType, &entityID, &user, &createdAt); err != nil {
				continue
			}
			_ = cw.Write([]string{
				"entry", id.String(), title, category,
				strPtr(entityType), uuidPtrStr(entityID),
				user, createdAt.UTC().Format(time.RFC3339),
			})
		}
	}

	// Audit log rows.
	auditRows, err := h.db.Query(r.Context(),
		`SELECT al.id, al.action, al.entity_type, al.entity_id,
		        COALESCE(u.first_name||' '||u.last_name, 'System'), al.created_at
		 FROM audit_logs al
		 LEFT JOIN users u ON u.id = al.user_id
		 WHERE al.business_id=$1
		 ORDER BY al.created_at DESC
		 LIMIT 10000`, bizID)
	if err == nil {
		defer auditRows.Close()
		for auditRows.Next() {
			var id uuid.UUID
			var action, user string
			var entityType *string
			var entityID *uuid.UUID
			var createdAt time.Time
			if err := auditRows.Scan(&id, &action, &entityType, &entityID, &user, &createdAt); err != nil {
				continue
			}
			_ = cw.Write([]string{
				"audit", id.String(), action, categorize(action),
				strPtr(entityType), uuidPtrStr(entityID),
				user, createdAt.UTC().Format(time.RFC3339),
			})
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "activity_feed",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Internal helpers ────────────────────────────────────────────

// categorize derives a high-level grouping from an audit action name.
// Mirrors the activity_feed view's CASE expression so the mobile UI
// can colour/icon by category without re-parsing.
func categorize(action string) string {
	a := strings.ToLower(action)
	switch {
	case strings.HasPrefix(a, "job"):
		return "job"
	case strings.HasPrefix(a, "invoice"):
		return "invoice"
	case strings.HasPrefix(a, "quote"):
		return "quote"
	case strings.HasPrefix(a, "customer"):
		return "customer"
	case strings.HasPrefix(a, "worker"):
		return "worker"
	case strings.HasPrefix(a, "payment"):
		return "payment"
	case strings.HasPrefix(a, "session"), strings.HasPrefix(a, "auth"), strings.HasPrefix(a, "login"):
		return "auth"
	case strings.HasPrefix(a, "task"):
		return "task"
	case strings.HasPrefix(a, "lead"):
		return "lead"
	case strings.HasPrefix(a, "expense"):
		return "expense"
	case strings.HasPrefix(a, "safety"), strings.HasPrefix(a, "incident"):
		return "safety"
	case strings.HasPrefix(a, "activity_feed_module"), strings.HasPrefix(a, "tenant_activity"):
		return "system"
	default:
		return "system"
	}
}

func userID(c *middleware.Claims) uuid.UUID {
	if c == nil {
		return uuid.Nil
	}
	return c.UserID
}

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
			EntityType: "activity_feed",
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

func strPtr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func uuidPtrStr(p *uuid.UUID) string {
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
