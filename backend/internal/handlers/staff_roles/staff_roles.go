// Package staff_roles implements Module 23 — Staff Roles Module.
//
// One service: StaffRoleService. The handler exposes:
//
//   - CRUD on tenant-defined role labels (e.g. "Lead Electrician"):
//       GET    /api/v1/staff_roles
//       POST   /api/v1/staff_roles
//       GET    /api/v1/staff_roles/{id}
//       PATCH  /api/v1/staff_roles/{id}
//       DELETE /api/v1/staff_roles/{id}
//       POST   /api/v1/staff_roles/{id}/status
//       GET    /api/v1/staff_roles/export.csv
//
//   - Assignment to workers:
//       POST   /api/v1/staff_roles/{id}/assign     {user_ids: [...]}
//       POST   /api/v1/staff_roles/{id}/unassign   {user_ids: [...]}
//
//   - Self-service:
//       GET    /api/v1/me/staff_roles_module
//
// Security: business_id only ever from BusinessIDFromCtx; the
// users.staff_role_id trigger enforces cross-tenant integrity at the
// DB level so a leaked role UUID cannot be assigned across tenants
// even if the handler check is bypassed.
//
// Audit names: STAFF_ROLES_MODULE_*.
package staff_roles

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
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
	AuditViewed       = "STAFF_ROLES_MODULE_VIEWED"
	AuditCreated      = "STAFF_ROLES_MODULE_CREATED"
	AuditUpdated      = "STAFF_ROLES_MODULE_UPDATED"
	AuditDeleted      = "STAFF_ROLES_MODULE_DELETED"
	AuditAccessDenied = "STAFF_ROLES_MODULE_ACCESS_DENIED"
	AuditExported     = "STAFF_ROLES_MODULE_EXPORTED"

	maxBodyBytes = 32 * 1024
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedBaseRole = map[string]bool{
		"admin": true, "manager": true, "worker": true, "accountant": true,
	}
	allowedColor = map[string]bool{"blue": true, "green": true, "red": true, "navy": true, "grey": true}
	allowedIcon  = map[string]bool{
		"people": true, "briefcase": true, "health": true, "warning_2": true,
		"security_safe": true, "chart_2": true, "wrench": true, "user": true,
	}
	allowedStatus     = map[string]bool{"active": true, "archived": true}
	allowedTransition = map[[2]string]bool{
		{"active", "archived"}: true,
		{"archived", "active"}: true,
	}

	// Slug must be ASCII letters / digits / hyphen / underscore, 2-48 chars.
	slugPattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9_-]{0,46}[a-z0-9])?$`)
)

// ── Handler / wiring ─────────────────────────────────────────────

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── Row shape ───────────────────────────────────────────────────

type roleRow struct {
	ID               uuid.UUID  `json:"id"`
	BusinessID       uuid.UUID  `json:"-"`
	CreatedBy        *uuid.UUID `json:"created_by"`
	UpdatedBy        *uuid.UUID `json:"updated_by"`
	Name             string     `json:"name"`
	Slug             string     `json:"slug"`
	Responsibilities string     `json:"responsibilities"`
	BaseRole         string     `json:"base_role"`
	ColorToken       string     `json:"color_token"`
	IconToken        string     `json:"icon_token"`
	DisplayOrder     int        `json:"display_order"`
	Status           string     `json:"status"`
	Metadata         []byte     `json:"-"`
	AssignedCount    int        `json:"assigned_count"`
	CreatedAt        time.Time  `json:"created_at"`
	UpdatedAt        time.Time  `json:"updated_at"`
}

func (a *roleRow) MarshalJSON() ([]byte, error) {
	type alias roleRow
	mm := json.RawMessage(a.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(a), mm})
}

// ── List (GET /api/v1/staff_roles) ──────────────────────────────

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "roles.view") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter == "" {
		statusFilter = "active"
	}
	if statusFilter != "all" && !allowedStatus[statusFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	args := []interface{}{bizID}
	filter := "sr.business_id=$1 AND sr.deleted_at IS NULL"
	if statusFilter != "all" {
		args = append(args, statusFilter)
		filter += " AND sr.status=$2"
	}
	args = append(args, limit)
	limitParam := len(args)

	q := `SELECT sr.id, sr.business_id, sr.created_by, sr.updated_by,
	             sr.name, sr.slug, sr.responsibilities, sr.base_role,
	             sr.color_token, sr.icon_token, sr.display_order,
	             sr.status, sr.metadata, sr.created_at, sr.updated_at,
	             (SELECT COUNT(*) FROM users u
	              WHERE u.staff_role_id=sr.id AND u.deleted_at IS NULL) AS assigned_count
	      FROM staff_roles sr
	      WHERE ` + filter + `
	      ORDER BY sr.display_order, sr.name
	      LIMIT $` + strconv.Itoa(limitParam)

	rows, err := h.db.Query(r.Context(), q, args...)
	if err != nil {
		h.log.Error("list staff_roles", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*roleRow{}
	for rows.Next() {
		rr := &roleRow{}
		if err := rows.Scan(&rr.ID, &rr.BusinessID, &rr.CreatedBy, &rr.UpdatedBy,
			&rr.Name, &rr.Slug, &rr.Responsibilities, &rr.BaseRole,
			&rr.ColorToken, &rr.IconToken, &rr.DisplayOrder,
			&rr.Status, &rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt,
			&rr.AssignedCount); err == nil {
			out = append(out, rr)
		}
	}
	respond(w, http.StatusOK, out)
}

// ── Create (POST /api/v1/staff_roles) ───────────────────────────

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roles.manage") {
		return
	}

	var req struct {
		Name             string                 `json:"name"`
		Slug             string                 `json:"slug"`
		Responsibilities string                 `json:"responsibilities"`
		BaseRole         string                 `json:"base_role"`
		ColorToken       string                 `json:"color_token"`
		IconToken        string                 `json:"icon_token"`
		DisplayOrder     *int                   `json:"display_order"`
		Metadata         map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(req.Name) == "" {
		respondErr(w, http.StatusBadRequest, "name_required")
		return
	}
	slug := strings.ToLower(strings.TrimSpace(req.Slug))
	if slug == "" {
		slug = slugifyName(req.Name)
	}
	if !slugPattern.MatchString(slug) {
		respondErr(w, http.StatusBadRequest, "invalid_slug")
		return
	}
	if req.BaseRole == "" {
		req.BaseRole = "worker"
	}
	if !allowedBaseRole[req.BaseRole] {
		respondErr(w, http.StatusBadRequest, "invalid_base_role")
		return
	}
	if req.ColorToken == "" {
		req.ColorToken = "blue"
	}
	if !allowedColor[req.ColorToken] {
		respondErr(w, http.StatusBadRequest, "invalid_color_token")
		return
	}
	if req.IconToken == "" {
		req.IconToken = "people"
	}
	if !allowedIcon[req.IconToken] {
		respondErr(w, http.StatusBadRequest, "invalid_icon_token")
		return
	}
	displayOrder := 0
	if req.DisplayOrder != nil {
		displayOrder = *req.DisplayOrder
	}

	metaBytes := jsonOrEmpty(req.Metadata)

	var newID uuid.UUID
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO staff_roles
		   (business_id, created_by, name, slug, responsibilities, base_role,
		    color_token, icon_token, display_order, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb)
		 RETURNING id`,
		bizID, claims.UserID, strings.TrimSpace(req.Name), slug,
		strings.TrimSpace(req.Responsibilities), req.BaseRole,
		req.ColorToken, req.IconToken, displayOrder, metaBytes,
	).Scan(&newID)
	if err != nil {
		if isDuplicateSlug(err) {
			respondErr(w, http.StatusConflict, "slug_already_exists")
			return
		}
		h.log.Error("create staff_role", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "staff_role",
		EntityID:   newID,
		NewData: map[string]interface{}{
			"name": req.Name, "slug": slug, "base_role": req.BaseRole,
		},
		IPAddress: r.RemoteAddr,
	})

	h.respondOne(w, r, newID, http.StatusCreated)
}

// ── Get (GET /api/v1/staff_roles/{id}) ──────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "roles.view") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}
	h.respondOne(w, r, id, http.StatusOK)
}

func (h *Handler) respondOne(w http.ResponseWriter, r *http.Request, id uuid.UUID, code int) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rr := &roleRow{}
	err := h.db.QueryRow(r.Context(),
		`SELECT sr.id, sr.business_id, sr.created_by, sr.updated_by,
		        sr.name, sr.slug, sr.responsibilities, sr.base_role,
		        sr.color_token, sr.icon_token, sr.display_order,
		        sr.status, sr.metadata, sr.created_at, sr.updated_at,
		        (SELECT COUNT(*) FROM users u
		         WHERE u.staff_role_id=sr.id AND u.deleted_at IS NULL) AS assigned_count
		 FROM staff_roles sr
		 WHERE sr.id=$1 AND sr.business_id=$2 AND sr.deleted_at IS NULL`,
		id, bizID,
	).Scan(&rr.ID, &rr.BusinessID, &rr.CreatedBy, &rr.UpdatedBy,
		&rr.Name, &rr.Slug, &rr.Responsibilities, &rr.BaseRole,
		&rr.ColorToken, &rr.IconToken, &rr.DisplayOrder,
		&rr.Status, &rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt,
		&rr.AssignedCount)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	respond(w, code, rr)
}

// ── Update (PATCH /api/v1/staff_roles/{id}) ─────────────────────

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roles.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Name             *string                `json:"name"`
		Slug             *string                `json:"slug"`
		Responsibilities *string                `json:"responsibilities"`
		BaseRole         *string                `json:"base_role"`
		ColorToken       *string                `json:"color_token"`
		IconToken        *string                `json:"icon_token"`
		DisplayOrder     *int                   `json:"display_order"`
		Status           *string                `json:"status"`
		Metadata         map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.BaseRole != nil && !allowedBaseRole[*req.BaseRole] {
		respondErr(w, http.StatusBadRequest, "invalid_base_role")
		return
	}
	if req.ColorToken != nil && !allowedColor[*req.ColorToken] {
		respondErr(w, http.StatusBadRequest, "invalid_color_token")
		return
	}
	if req.IconToken != nil && !allowedIcon[*req.IconToken] {
		respondErr(w, http.StatusBadRequest, "invalid_icon_token")
		return
	}
	if req.Status != nil && !allowedStatus[*req.Status] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	if req.Slug != nil {
		s := strings.ToLower(strings.TrimSpace(*req.Slug))
		if !slugPattern.MatchString(s) {
			respondErr(w, http.StatusBadRequest, "invalid_slug")
			return
		}
		req.Slug = &s
	}

	var current roleRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, status, name, slug, base_role
		 FROM staff_roles WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current.ID, &current.Status, &current.Name, &current.Slug, &current.BaseRole)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	if req.Status != nil && *req.Status != current.Status {
		if !allowedTransition[[2]string{current.Status, *req.Status}] {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
	}

	// Block changing base_role on a row that has people assigned —
	// would silently re-bucket them. Force unassign first.
	if req.BaseRole != nil && *req.BaseRole != current.BaseRole {
		var assigned int
		_ = h.db.QueryRow(r.Context(),
			`SELECT COUNT(*) FROM users
			 WHERE staff_role_id=$1 AND deleted_at IS NULL`, id).Scan(&assigned)
		if assigned > 0 {
			respondErr(w, http.StatusConflict, "base_role_change_blocked:has_assignees")
			return
		}
	}

	var meta []byte
	if req.Metadata != nil {
		meta, _ = json.Marshal(req.Metadata)
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE staff_roles SET
		   name             = COALESCE($3, name),
		   slug             = COALESCE($4, slug),
		   responsibilities = COALESCE($5, responsibilities),
		   base_role        = COALESCE($6, base_role),
		   color_token      = COALESCE($7, color_token),
		   icon_token       = COALESCE($8, icon_token),
		   display_order    = COALESCE($9, display_order),
		   status           = COALESCE($10, status),
		   metadata         = COALESCE($11::jsonb, metadata),
		   updated_by       = $12,
		   updated_at       = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Name, req.Slug, req.Responsibilities, req.BaseRole,
		req.ColorToken, req.IconToken, req.DisplayOrder, req.Status,
		meta, claims.UserID,
	)
	if err != nil {
		if isDuplicateSlug(err) {
			respondErr(w, http.StatusConflict, "slug_already_exists")
			return
		}
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
		h.log.Error("update staff_role", zap.Error(err))
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
		EntityType: "staff_role",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current.Status, "name": current.Name, "slug": current.Slug, "base_role": current.BaseRole},
		NewData:    map[string]interface{}{"status": derefStr(req.Status), "name": derefStr(req.Name), "slug": derefStr(req.Slug), "base_role": derefStr(req.BaseRole)},
		IPAddress:  r.RemoteAddr,
	})

	h.respondOne(w, r, id, http.StatusOK)
}

// ── Delete (DELETE /api/v1/staff_roles/{id}) — soft. ────────────

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roles.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "tx_failed")
		return
	}
	defer tx.Rollback(r.Context())

	// Detach any users currently assigned so we don't orphan a FK.
	if _, err := tx.Exec(r.Context(),
		`UPDATE users SET staff_role_id=NULL, updated_at=NOW()
		 WHERE staff_role_id=$1 AND business_id=$2`,
		id, bizID); err != nil {
		respondErr(w, http.StatusInternalServerError, "detach_failed")
		return
	}

	tag, err := tx.Exec(r.Context(),
		`UPDATE staff_roles
		   SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
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
	if err := tx.Commit(r.Context()); err != nil {
		respondErr(w, http.StatusInternalServerError, "commit_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditDeleted,
		EntityType: "staff_role",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// ── SetStatus (POST /api/v1/staff_roles/{id}/status) ────────────

func (h *Handler) SetStatus(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roles.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Status string `json:"status"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if !allowedStatus[req.Status] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}

	var current string
	err = h.db.QueryRow(r.Context(),
		`SELECT status FROM staff_roles WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}
	if current == req.Status {
		respond(w, http.StatusOK, map[string]string{"message": "no_change", "status": current})
		return
	}

	if _, err := h.db.Exec(r.Context(),
		`UPDATE staff_roles SET status=$3, updated_by=$4, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Status, claims.UserID); err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
		respondErr(w, http.StatusInternalServerError, "update_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "staff_role",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current},
		NewData:    map[string]interface{}{"status": req.Status},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{"id": id, "status": req.Status})
}

// ── Assign / unassign (POST /api/v1/staff_roles/{id}/assign) ────

func (h *Handler) Assign(w http.ResponseWriter, r *http.Request) {
	h.assignOrUnassign(w, r, true)
}

func (h *Handler) Unassign(w http.ResponseWriter, r *http.Request) {
	h.assignOrUnassign(w, r, false)
}

func (h *Handler) assignOrUnassign(w http.ResponseWriter, r *http.Request, assign bool) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roles.assign") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		UserIDs []string `json:"user_ids"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(req.UserIDs) == 0 || len(req.UserIDs) > 200 {
		respondErr(w, http.StatusBadRequest, "invalid_user_count")
		return
	}

	// Confirm role exists in tenant + is active.
	var status string
	err = h.db.QueryRow(r.Context(),
		`SELECT status FROM staff_roles WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&status)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}
	if assign && status != "active" {
		respondErr(w, http.StatusConflict, "cannot_assign_archived_role")
		return
	}

	uids := make([]uuid.UUID, 0, len(req.UserIDs))
	for _, raw := range req.UserIDs {
		uid, err := uuid.Parse(raw)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_user_id:"+raw)
			return
		}
		uids = append(uids, uid)
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "tx_failed")
		return
	}
	defer tx.Rollback(r.Context())

	var roleArg interface{}
	action := "assigned"
	if assign {
		roleArg = id
	} else {
		roleArg = nil
		action = "unassigned"
	}

	// Single statement: only flip rows that belong to the tenant.
	tag, err := tx.Exec(r.Context(),
		`UPDATE users SET staff_role_id=$3, updated_by=$4, updated_at=NOW()
		 WHERE id = ANY($1::uuid[]) AND business_id=$2 AND deleted_at IS NULL
		   AND role <> 'customer'`,
		uids, bizID, roleArg, claims.UserID)
	if err != nil {
		// Trigger raises check_violation if cross-tenant slips through.
		if strings.Contains(err.Error(), "staff_role_cross_tenant") {
			respondErr(w, http.StatusBadRequest, "cross_tenant")
			return
		}
		h.log.Error("assign staff_role", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "assign_failed")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		respondErr(w, http.StatusInternalServerError, "commit_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "staff_role." + action,
		EntityID:   id,
		NewData:    map[string]interface{}{"user_count": tag.RowsAffected(), "user_ids": req.UserIDs},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"action":  action,
		"updated": tag.RowsAffected(),
	})
}

// ── MeView (GET /api/v1/me/staff_roles_module) ──────────────────

// MeView returns the calling user's own staff role (if any) plus the
// list of active roles in the tenant — workers can see the catalogue
// to know what other titles exist without being able to edit.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roles.view") {
		return
	}

	type me struct {
		StaffRoleID *uuid.UUID `json:"staff_role_id"`
		Name        *string    `json:"name"`
		Slug        *string    `json:"slug"`
		BaseRole    *string    `json:"base_role"`
		ColorToken  *string    `json:"color_token"`
		IconToken   *string    `json:"icon_token"`
	}
	var m me
	_ = h.db.QueryRow(r.Context(),
		`SELECT u.staff_role_id, sr.name, sr.slug, sr.base_role, sr.color_token, sr.icon_token
		 FROM users u
		 LEFT JOIN staff_roles sr ON sr.id=u.staff_role_id AND sr.deleted_at IS NULL
		 WHERE u.id=$1 AND u.business_id=$2 AND u.deleted_at IS NULL`,
		claims.UserID, bizID,
	).Scan(&m.StaffRoleID, &m.Name, &m.Slug, &m.BaseRole, &m.ColorToken, &m.IconToken)

	// Catalogue (active only).
	rows, err := h.db.Query(r.Context(),
		`SELECT id, name, slug, base_role, color_token, icon_token, display_order
		 FROM staff_roles
		 WHERE business_id=$1 AND deleted_at IS NULL AND status='active'
		 ORDER BY display_order, name`, bizID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	type tile struct {
		ID           uuid.UUID `json:"id"`
		Name         string    `json:"name"`
		Slug         string    `json:"slug"`
		BaseRole     string    `json:"base_role"`
		ColorToken   string    `json:"color_token"`
		IconToken    string    `json:"icon_token"`
		DisplayOrder int       `json:"display_order"`
	}
	catalogue := []tile{}
	for rows.Next() {
		var t tile
		if err := rows.Scan(&t.ID, &t.Name, &t.Slug, &t.BaseRole, &t.ColorToken, &t.IconToken, &t.DisplayOrder); err == nil {
			catalogue = append(catalogue, t)
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "staff_role.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"me":         m,
		"catalogue":  catalogue,
	})
}

// ── Export ──────────────────────────────────────────────────────

func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roles.export") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT sr.id, sr.name, sr.slug, sr.responsibilities, sr.base_role,
		        sr.status, sr.display_order,
		        (SELECT COUNT(*) FROM users u
		         WHERE u.staff_role_id=sr.id AND u.deleted_at IS NULL) AS assigned_count,
		        sr.created_at
		 FROM staff_roles sr
		 WHERE sr.business_id=$1 AND sr.deleted_at IS NULL
		 ORDER BY sr.display_order, sr.name`, bizID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="staff-roles-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "name", "slug", "responsibilities", "base_role",
		"status", "display_order", "assigned_count", "created_at"})

	for rows.Next() {
		var id uuid.UUID
		var name, slug, resp, baseRole, status string
		var displayOrder, assignedCount int
		var createdAt time.Time
		if err := rows.Scan(&id, &name, &slug, &resp, &baseRole, &status,
			&displayOrder, &assignedCount, &createdAt); err != nil {
			continue
		}
		_ = cw.Write([]string{
			id.String(), name, slug, resp, baseRole, status,
			strconv.Itoa(displayOrder), strconv.Itoa(assignedCount),
			createdAt.UTC().Format(time.RFC3339),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "staff_role",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Internal helpers ────────────────────────────────────────────

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
			EntityType: "staff_role",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respondErr(w, http.StatusForbidden, "forbidden:"+key)
		return false
	}
	return true
}

// slugifyName produces a valid slug from a free-text name.
// Lowercases, replaces non-alphanumerics with hyphens, trims hyphens
// at the edges, and caps to 48 chars.
func slugifyName(name string) string {
	var b strings.Builder
	prevHyphen := false
	for _, r := range strings.ToLower(strings.TrimSpace(name)) {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'):
			b.WriteRune(r)
			prevHyphen = false
		case r == '_' || r == '-' || r == ' ':
			if !prevHyphen && b.Len() > 0 {
				b.WriteRune('-')
				prevHyphen = true
			}
		}
	}
	out := strings.Trim(b.String(), "-")
	if len(out) > 48 {
		out = out[:48]
		out = strings.TrimRight(out, "-")
	}
	if len(out) < 2 {
		// Fallback so we never produce an invalid slug; the handler
		// validates separately so this only matters when name is empty
		// (which is rejected upstream).
		return "role"
	}
	return out
}

func isDuplicateSlug(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "uq_staff_roles_business_slug") ||
		strings.Contains(s, "duplicate key value")
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

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func respond(w http.ResponseWriter, code int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if body != nil {
		_ = json.NewEncoder(w).Encode(body)
	}
}

func respondErr(w http.ResponseWriter, code int, msg string) {
	respond(w, code, map[string]string{"error": msg})
}
