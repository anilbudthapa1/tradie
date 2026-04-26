// Package availability_roster implements Module 24 — Availability
// Roster Module.
//
// One service: RosterService. Three streams:
//
//   - Recurring weekly pattern (worker_availability) — reused from
//     the workers module via SetRecurring / GetRecurring; the legacy
//     /workers/{id}/availability route still works.
//
//   - Availability blocks (date-range exceptions) — the spec's
//     primary CRUD entity. Workers create their own leave requests
//     (status='pending'); managers approve or cancel.
//
//   - Roster assignments (per-date scheduled shifts, optionally
//     linked to a job). Managers create; workers see their own.
//
// Security:
//
//   - business_id only ever from BusinessIDFromCtx
//   - Workers can only create blocks/roster targeting themselves
//   - Approvals require roster.approve (manager+)
//   - Spec audit names AVAILABILITY_ROSTER_MODULE_*
package availability_roster

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
	AuditViewed       = "AVAILABILITY_ROSTER_MODULE_VIEWED"
	AuditCreated      = "AVAILABILITY_ROSTER_MODULE_CREATED"
	AuditUpdated      = "AVAILABILITY_ROSTER_MODULE_UPDATED"
	AuditDeleted      = "AVAILABILITY_ROSTER_MODULE_DELETED"
	AuditAccessDenied = "AVAILABILITY_ROSTER_MODULE_ACCESS_DENIED"
	AuditExported     = "AVAILABILITY_ROSTER_MODULE_EXPORTED"

	maxBodyBytes = 32 * 1024
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedBlockType = map[string]bool{
		"leave": true, "sick": true, "training": true,
		"public_holiday": true, "unavailable": true, "custom": true,
	}
	allowedBlockStatus = map[string]bool{
		"pending": true, "approved": true, "cancelled": true,
	}
	allowedBlockTransition = map[[2]string]bool{
		{"pending", "approved"}:   true,
		{"pending", "cancelled"}:  true,
		{"approved", "cancelled"}: true,
	}

	allowedRosterStatus = map[string]bool{
		"scheduled": true, "confirmed": true, "completed": true, "cancelled": true,
	}
	allowedRosterTransition = map[[2]string]bool{
		{"scheduled", "confirmed"}: true,
		{"scheduled", "cancelled"}: true,
		{"scheduled", "completed"}: true,
		{"confirmed", "completed"}: true,
		{"confirmed", "cancelled"}: true,
	}
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

// ── Row shapes ──────────────────────────────────────────────────

type blockRow struct {
	ID          uuid.UUID  `json:"id"`
	BusinessID  uuid.UUID  `json:"-"`
	UserID      uuid.UUID  `json:"user_id"`
	CreatedBy   *uuid.UUID `json:"created_by"`
	UpdatedBy   *uuid.UUID `json:"updated_by"`
	BlockType   string     `json:"block_type"`
	StartsAt    time.Time  `json:"starts_at"`
	EndsAt      time.Time  `json:"ends_at"`
	AllDay      bool       `json:"all_day"`
	Reason      string     `json:"reason"`
	Status      string     `json:"status"`
	ApprovedBy  *uuid.UUID `json:"approved_by"`
	ApprovedAt  *time.Time `json:"approved_at"`
	Metadata    []byte     `json:"-"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
}

func (a *blockRow) MarshalJSON() ([]byte, error) {
	type alias blockRow
	mm := json.RawMessage(a.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(a), mm})
}

type rosterRow struct {
	ID         uuid.UUID  `json:"id"`
	BusinessID uuid.UUID  `json:"-"`
	UserID     uuid.UUID  `json:"user_id"`
	JobID      *uuid.UUID `json:"job_id"`
	CreatedBy  *uuid.UUID `json:"created_by"`
	UpdatedBy  *uuid.UUID `json:"updated_by"`
	StartsAt   time.Time  `json:"starts_at"`
	EndsAt     time.Time  `json:"ends_at"`
	Notes      string     `json:"notes"`
	Status     string     `json:"status"`
	Metadata   []byte     `json:"-"`
	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"updated_at"`
}

func (a *rosterRow) MarshalJSON() ([]byte, error) {
	type alias rosterRow
	mm := json.RawMessage(a.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(a), mm})
}

// ── Block CRUD ──────────────────────────────────────────────────

// ListBlocks (GET /api/v1/availability_roster) — top-level list of
// availability blocks (the spec's CRUD entity). Workers see their own
// only; managers+ see the whole tenant.
func (h *Handler) ListBlocks(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roster.view") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedBlockStatus[statusFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	typeFilter := strings.TrimSpace(r.URL.Query().Get("block_type"))
	if typeFilter != "" && !allowedBlockType[typeFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_block_type")
		return
	}
	userIDFilter := strings.TrimSpace(r.URL.Query().Get("user_id"))
	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	args := []interface{}{bizID}
	filters := []string{"business_id=$1", "deleted_at IS NULL"}
	next := 2

	// Workers: pin to self regardless of any user_id query param.
	if !middleware.IsAtLeast(claims.Role, "manager") {
		filters = append(filters, "user_id=$"+strconv.Itoa(next))
		args = append(args, claims.UserID)
		next++
	} else if userIDFilter != "" {
		uid, err := uuid.Parse(userIDFilter)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_user_id")
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
	if typeFilter != "" {
		filters = append(filters, "block_type=$"+strconv.Itoa(next))
		args = append(args, typeFilter)
		next++
	}
	args = append(args, limit)
	limitParam := next

	q := `SELECT id, business_id, user_id, created_by, updated_by, block_type,
	             starts_at, ends_at, all_day, reason, status, approved_by, approved_at,
	             metadata, created_at, updated_at
	      FROM availability_blocks
	      WHERE ` + strings.Join(filters, " AND ") + `
	      ORDER BY starts_at DESC
	      LIMIT $` + strconv.Itoa(limitParam)

	rows, err := h.db.Query(r.Context(), q, args...)
	if err != nil {
		h.log.Error("list blocks", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*blockRow{}
	for rows.Next() {
		br := &blockRow{}
		if err := rows.Scan(&br.ID, &br.BusinessID, &br.UserID, &br.CreatedBy, &br.UpdatedBy,
			&br.BlockType, &br.StartsAt, &br.EndsAt, &br.AllDay, &br.Reason,
			&br.Status, &br.ApprovedBy, &br.ApprovedAt,
			&br.Metadata, &br.CreatedAt, &br.UpdatedAt); err == nil {
			out = append(out, br)
		}
	}
	respond(w, http.StatusOK, out)
}

// CreateBlock (POST /api/v1/availability_roster) — workers create
// for themselves, managers+ for anyone in the tenant.
func (h *Handler) CreateBlock(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roster.update") {
		return
	}

	var req struct {
		UserID    *string                `json:"user_id"`
		BlockType string                 `json:"block_type"`
		StartsAt  string                 `json:"starts_at"`
		EndsAt    string                 `json:"ends_at"`
		AllDay    *bool                  `json:"all_day"`
		Reason    string                 `json:"reason"`
		Metadata  map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	// Worker scope: target must be self.
	target := claims.UserID
	if req.UserID != nil && *req.UserID != "" {
		uid, err := uuid.Parse(*req.UserID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_user_id")
			return
		}
		if !middleware.IsAtLeast(claims.Role, "manager") && uid != claims.UserID {
			respondErr(w, http.StatusForbidden, "forbidden:non_manager_targeting_other")
			return
		}
		if !h.userInTenant(r, uid, bizID) {
			respondErr(w, http.StatusBadRequest, "user_not_in_tenant")
			return
		}
		target = uid
	}

	if req.BlockType == "" {
		req.BlockType = "leave"
	}
	if !allowedBlockType[req.BlockType] {
		respondErr(w, http.StatusBadRequest, "invalid_block_type")
		return
	}

	startsAt, err := time.Parse(time.RFC3339, strings.TrimSpace(req.StartsAt))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_starts_at")
		return
	}
	endsAt, err := time.Parse(time.RFC3339, strings.TrimSpace(req.EndsAt))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_ends_at")
		return
	}
	if !endsAt.After(startsAt) {
		respondErr(w, http.StatusBadRequest, "ends_at_must_be_after_starts_at")
		return
	}
	if startsAt.Before(time.Now().AddDate(-1, 0, 0)) || startsAt.After(time.Now().AddDate(2, 0, 0)) {
		// Sanity range — block requests for very far past/future.
		respondErr(w, http.StatusBadRequest, "starts_at_out_of_range")
		return
	}

	allDay := true
	if req.AllDay != nil {
		allDay = *req.AllDay
	}

	metaBytes := jsonOrEmpty(req.Metadata)

	// Conflict check: overlapping block of same type in the same window.
	var conflictID uuid.UUID
	err = h.db.QueryRow(r.Context(),
		`SELECT id FROM availability_blocks
		 WHERE business_id=$1 AND user_id=$2 AND deleted_at IS NULL
		   AND status IN ('pending','approved')
		   AND tstzrange(starts_at, ends_at, '[)') && tstzrange($3::timestamptz, $4::timestamptz, '[)')
		 LIMIT 1`,
		bizID, target, startsAt, endsAt,
	).Scan(&conflictID)
	if err == nil {
		respondErr(w, http.StatusConflict, "overlapping_block:"+conflictID.String())
		return
	}

	br := &blockRow{}
	err = h.db.QueryRow(r.Context(),
		`INSERT INTO availability_blocks
		   (business_id, user_id, created_by, block_type, starts_at, ends_at,
		    all_day, reason, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb)
		 RETURNING id, business_id, user_id, created_by, updated_by, block_type,
		           starts_at, ends_at, all_day, reason, status, approved_by, approved_at,
		           metadata, created_at, updated_at`,
		bizID, target, claims.UserID, req.BlockType, startsAt, endsAt,
		allDay, strings.TrimSpace(req.Reason), metaBytes,
	).Scan(&br.ID, &br.BusinessID, &br.UserID, &br.CreatedBy, &br.UpdatedBy,
		&br.BlockType, &br.StartsAt, &br.EndsAt, &br.AllDay, &br.Reason,
		&br.Status, &br.ApprovedBy, &br.ApprovedAt,
		&br.Metadata, &br.CreatedAt, &br.UpdatedAt)
	if err != nil {
		h.log.Error("create block", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "availability_block",
		EntityID:   br.ID,
		NewData: map[string]interface{}{
			"user_id": target, "block_type": req.BlockType,
			"starts_at": startsAt, "ends_at": endsAt,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusCreated, br)
}

// GetBlock (GET /api/v1/availability_roster/{id}).
func (h *Handler) GetBlock(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roster.view") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	br := &blockRow{}
	err = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, user_id, created_by, updated_by, block_type,
		        starts_at, ends_at, all_day, reason, status, approved_by, approved_at,
		        metadata, created_at, updated_at
		 FROM availability_blocks WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&br.ID, &br.BusinessID, &br.UserID, &br.CreatedBy, &br.UpdatedBy,
		&br.BlockType, &br.StartsAt, &br.EndsAt, &br.AllDay, &br.Reason,
		&br.Status, &br.ApprovedBy, &br.ApprovedAt,
		&br.Metadata, &br.CreatedAt, &br.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}

	// Workers can only see their own blocks.
	if !middleware.IsAtLeast(claims.Role, "manager") && br.UserID != claims.UserID {
		respondErr(w, http.StatusForbidden, "forbidden:not_owner")
		return
	}

	respond(w, http.StatusOK, br)
}

// UpdateBlock (PATCH /api/v1/availability_roster/{id}). Approvals
// (status='approved') require roster.approve in addition.
func (h *Handler) UpdateBlock(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roster.update") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		BlockType *string                `json:"block_type"`
		StartsAt  *string                `json:"starts_at"`
		EndsAt    *string                `json:"ends_at"`
		AllDay    *bool                  `json:"all_day"`
		Reason    *string                `json:"reason"`
		Status    *string                `json:"status"`
		Metadata  map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.BlockType != nil && !allowedBlockType[*req.BlockType] {
		respondErr(w, http.StatusBadRequest, "invalid_block_type")
		return
	}
	if req.Status != nil && !allowedBlockStatus[*req.Status] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}

	// Snapshot for transition validation, ownership check, and audit.
	var current blockRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, user_id, status, block_type
		 FROM availability_blocks WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current.ID, &current.UserID, &current.Status, &current.BlockType)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	// Workers can only edit their own pending blocks.
	if !middleware.IsAtLeast(claims.Role, "manager") {
		if current.UserID != claims.UserID {
			respondErr(w, http.StatusForbidden, "forbidden:not_owner")
			return
		}
		if current.Status != "pending" {
			respondErr(w, http.StatusForbidden, "forbidden:cannot_edit_after_approval")
			return
		}
		// Workers cannot self-approve.
		if req.Status != nil && *req.Status == "approved" {
			respondErr(w, http.StatusForbidden, "forbidden:approve_requires_manager")
			return
		}
	}

	// Approval requires the dedicated permission.
	if req.Status != nil && *req.Status == "approved" {
		if !h.requirePermission(w, r, "roster.approve") {
			return
		}
	}

	if req.Status != nil && *req.Status != current.Status {
		if !allowedBlockTransition[[2]string{current.Status, *req.Status}] {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
	}

	var startsAt, endsAt *time.Time
	if req.StartsAt != nil && strings.TrimSpace(*req.StartsAt) != "" {
		t, err := time.Parse(time.RFC3339, *req.StartsAt)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_starts_at")
			return
		}
		startsAt = &t
	}
	if req.EndsAt != nil && strings.TrimSpace(*req.EndsAt) != "" {
		t, err := time.Parse(time.RFC3339, *req.EndsAt)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_ends_at")
			return
		}
		endsAt = &t
	}

	var meta []byte
	if req.Metadata != nil {
		meta, _ = json.Marshal(req.Metadata)
	}

	// On approve, stamp approved_by / approved_at.
	approvedByArg, approvedAtArg := interface{}(nil), interface{}(nil)
	if req.Status != nil && *req.Status == "approved" {
		approvedByArg = claims.UserID
		now := time.Now()
		approvedAtArg = now
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE availability_blocks SET
		   block_type   = COALESCE($3, block_type),
		   starts_at    = COALESCE($4::timestamptz, starts_at),
		   ends_at      = COALESCE($5::timestamptz, ends_at),
		   all_day      = COALESCE($6, all_day),
		   reason       = COALESCE($7, reason),
		   status       = COALESCE($8, status),
		   metadata     = COALESCE($9::jsonb, metadata),
		   approved_by  = COALESCE($10::uuid, approved_by),
		   approved_at  = COALESCE($11::timestamptz, approved_at),
		   updated_by   = $12,
		   updated_at   = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.BlockType, startsAt, endsAt, req.AllDay, req.Reason,
		req.Status, meta, approvedByArg, approvedAtArg, claims.UserID,
	)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
		h.log.Error("update block", zap.Error(err))
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
		EntityType: "availability_block",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current.Status, "block_type": current.BlockType},
		NewData:    map[string]interface{}{"status": derefStr(req.Status), "block_type": derefStr(req.BlockType)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "updated"})
}

// DeleteBlock (DELETE /api/v1/availability_roster/{id}) — soft delete.
func (h *Handler) DeleteBlock(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roster.update") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	// Ownership check for non-managers.
	if !middleware.IsAtLeast(claims.Role, "manager") {
		var ownerID uuid.UUID
		err = h.db.QueryRow(r.Context(),
			`SELECT user_id FROM availability_blocks
			 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
			id, bizID).Scan(&ownerID)
		if err != nil {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		if ownerID != claims.UserID {
			respondErr(w, http.StatusForbidden, "forbidden:not_owner")
			return
		}
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE availability_blocks
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

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditDeleted,
		EntityType: "availability_block",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// ── Roster assignments ──────────────────────────────────────────

// ListRoster (GET /api/v1/availability_roster/roster?from=&to=&user_id=)
func (h *Handler) ListRoster(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roster.view") {
		return
	}

	fromStr := strings.TrimSpace(r.URL.Query().Get("from"))
	toStr := strings.TrimSpace(r.URL.Query().Get("to"))
	if fromStr == "" || toStr == "" {
		respondErr(w, http.StatusBadRequest, "from_and_to_required")
		return
	}
	from, err := time.Parse(time.RFC3339, fromStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_from")
		return
	}
	to, err := time.Parse(time.RFC3339, toStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_to")
		return
	}
	if !to.After(from) {
		respondErr(w, http.StatusBadRequest, "to_must_be_after_from")
		return
	}
	if to.Sub(from) > 90*24*time.Hour {
		respondErr(w, http.StatusBadRequest, "range_too_wide:max_90_days")
		return
	}

	args := []interface{}{bizID, from, to}
	filter := "business_id=$1 AND deleted_at IS NULL AND tstzrange(starts_at, ends_at, '[)') && tstzrange($2::timestamptz, $3::timestamptz, '[)')"
	if !middleware.IsAtLeast(claims.Role, "manager") {
		args = append(args, claims.UserID)
		filter += " AND user_id=$4"
	} else if v := strings.TrimSpace(r.URL.Query().Get("user_id")); v != "" {
		uid, err := uuid.Parse(v)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_user_id")
			return
		}
		args = append(args, uid)
		filter += " AND user_id=$4"
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, user_id, job_id, created_by, updated_by,
		        starts_at, ends_at, notes, status, metadata, created_at, updated_at
		 FROM roster_assignments
		 WHERE `+filter+`
		 ORDER BY starts_at`,
		args...)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*rosterRow{}
	for rows.Next() {
		rr := &rosterRow{}
		if err := rows.Scan(&rr.ID, &rr.BusinessID, &rr.UserID, &rr.JobID, &rr.CreatedBy, &rr.UpdatedBy,
			&rr.StartsAt, &rr.EndsAt, &rr.Notes, &rr.Status,
			&rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt); err == nil {
			out = append(out, rr)
		}
	}
	respond(w, http.StatusOK, out)
}

// CreateRoster (POST /api/v1/availability_roster/roster) — manager+ only.
func (h *Handler) CreateRoster(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !middleware.IsAtLeast(claims.Role, "manager") {
		respondErr(w, http.StatusForbidden, "forbidden:manager_required")
		return
	}
	if !h.requirePermission(w, r, "roster.update") {
		return
	}

	var req struct {
		UserID   string                 `json:"user_id"`
		JobID    *string                `json:"job_id"`
		StartsAt string                 `json:"starts_at"`
		EndsAt   string                 `json:"ends_at"`
		Notes    string                 `json:"notes"`
		Metadata map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	userID, err := uuid.Parse(strings.TrimSpace(req.UserID))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_user_id")
		return
	}
	if !h.userInTenant(r, userID, bizID) {
		respondErr(w, http.StatusBadRequest, "user_not_in_tenant")
		return
	}

	var jobUUID *uuid.UUID
	if req.JobID != nil && *req.JobID != "" {
		jid, err := uuid.Parse(*req.JobID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_job_id")
			return
		}
		var ok bool
		_ = h.db.QueryRow(r.Context(),
			`SELECT EXISTS(SELECT 1 FROM jobs WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
			jid, bizID).Scan(&ok)
		if !ok {
			respondErr(w, http.StatusBadRequest, "job_not_in_tenant")
			return
		}
		jobUUID = &jid
	}

	startsAt, err := time.Parse(time.RFC3339, strings.TrimSpace(req.StartsAt))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_starts_at")
		return
	}
	endsAt, err := time.Parse(time.RFC3339, strings.TrimSpace(req.EndsAt))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_ends_at")
		return
	}
	if !endsAt.After(startsAt) {
		respondErr(w, http.StatusBadRequest, "ends_at_must_be_after_starts_at")
		return
	}

	// Conflict check: overlapping roster OR approved leave for this worker.
	var conflictID uuid.UUID
	err = h.db.QueryRow(r.Context(),
		`SELECT id FROM roster_assignments
		 WHERE business_id=$1 AND user_id=$2 AND deleted_at IS NULL
		   AND status IN ('scheduled','confirmed')
		   AND tstzrange(starts_at, ends_at, '[)') && tstzrange($3::timestamptz, $4::timestamptz, '[)')
		 LIMIT 1`,
		bizID, userID, startsAt, endsAt,
	).Scan(&conflictID)
	if err == nil {
		respondErr(w, http.StatusConflict, "overlapping_roster:"+conflictID.String())
		return
	}
	err = h.db.QueryRow(r.Context(),
		`SELECT id FROM availability_blocks
		 WHERE business_id=$1 AND user_id=$2 AND deleted_at IS NULL
		   AND status='approved'
		   AND tstzrange(starts_at, ends_at, '[)') && tstzrange($3::timestamptz, $4::timestamptz, '[)')
		 LIMIT 1`,
		bizID, userID, startsAt, endsAt,
	).Scan(&conflictID)
	if err == nil {
		respondErr(w, http.StatusConflict, "worker_on_approved_leave:"+conflictID.String())
		return
	}

	metaBytes := jsonOrEmpty(req.Metadata)

	rr := &rosterRow{}
	err = h.db.QueryRow(r.Context(),
		`INSERT INTO roster_assignments
		   (business_id, user_id, job_id, created_by, starts_at, ends_at, notes, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
		 RETURNING id, business_id, user_id, job_id, created_by, updated_by,
		           starts_at, ends_at, notes, status, metadata, created_at, updated_at`,
		bizID, userID, jobUUID, claims.UserID, startsAt, endsAt,
		strings.TrimSpace(req.Notes), metaBytes,
	).Scan(&rr.ID, &rr.BusinessID, &rr.UserID, &rr.JobID, &rr.CreatedBy, &rr.UpdatedBy,
		&rr.StartsAt, &rr.EndsAt, &rr.Notes, &rr.Status,
		&rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt)
	if err != nil {
		h.log.Error("create roster", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "roster_assignment",
		EntityID:   rr.ID,
		NewData: map[string]interface{}{
			"user_id": userID, "job_id": jobUUID,
			"starts_at": startsAt, "ends_at": endsAt,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusCreated, rr)
}

// UpdateRoster (PATCH /api/v1/availability_roster/roster/{id}).
func (h *Handler) UpdateRoster(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !middleware.IsAtLeast(claims.Role, "manager") {
		// Workers can only confirm their own roster shift.
	}
	if !h.requirePermission(w, r, "roster.update") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Status   *string                `json:"status"`
		Notes    *string                `json:"notes"`
		StartsAt *string                `json:"starts_at"`
		EndsAt   *string                `json:"ends_at"`
		Metadata map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Status != nil && !allowedRosterStatus[*req.Status] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}

	var current rosterRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, user_id, status FROM roster_assignments
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current.ID, &current.UserID, &current.Status)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	// Workers may only confirm their OWN scheduled shift; nothing else.
	if !middleware.IsAtLeast(claims.Role, "manager") {
		if current.UserID != claims.UserID {
			respondErr(w, http.StatusForbidden, "forbidden:not_owner")
			return
		}
		if req.Status == nil || *req.Status != "confirmed" || current.Status != "scheduled" {
			respondErr(w, http.StatusForbidden, "forbidden:non_manager_can_only_confirm_own_shift")
			return
		}
		if req.Notes != nil || req.StartsAt != nil || req.EndsAt != nil || req.Metadata != nil {
			respondErr(w, http.StatusForbidden, "forbidden:non_manager_extra_fields")
			return
		}
	}

	if req.Status != nil && *req.Status != current.Status {
		if !allowedRosterTransition[[2]string{current.Status, *req.Status}] {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
	}

	var startsAt, endsAt *time.Time
	if req.StartsAt != nil && strings.TrimSpace(*req.StartsAt) != "" {
		t, err := time.Parse(time.RFC3339, *req.StartsAt)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_starts_at")
			return
		}
		startsAt = &t
	}
	if req.EndsAt != nil && strings.TrimSpace(*req.EndsAt) != "" {
		t, err := time.Parse(time.RFC3339, *req.EndsAt)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_ends_at")
			return
		}
		endsAt = &t
	}

	var meta []byte
	if req.Metadata != nil {
		meta, _ = json.Marshal(req.Metadata)
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE roster_assignments SET
		   starts_at  = COALESCE($3::timestamptz, starts_at),
		   ends_at    = COALESCE($4::timestamptz, ends_at),
		   notes      = COALESCE($5, notes),
		   status     = COALESCE($6, status),
		   metadata   = COALESCE($7::jsonb, metadata),
		   updated_by = $8,
		   updated_at = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, startsAt, endsAt, req.Notes, req.Status, meta, claims.UserID)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
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
		EntityType: "roster_assignment",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current.Status},
		NewData:    map[string]interface{}{"status": derefStr(req.Status)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "updated"})
}

// DeleteRoster (DELETE /api/v1/availability_roster/roster/{id}) — soft delete.
func (h *Handler) DeleteRoster(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !middleware.IsAtLeast(claims.Role, "manager") {
		respondErr(w, http.StatusForbidden, "forbidden:manager_required")
		return
	}
	if !h.requirePermission(w, r, "roster.update") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE roster_assignments
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

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditDeleted,
		EntityType: "roster_assignment",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// ── Self-service ────────────────────────────────────────────────

// MeView (GET /api/v1/me/availability_roster_module) returns the
// caller's recurring weekly pattern, their open blocks, and their
// roster assignments for the next 30 days.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roster.view") {
		return
	}

	type weekSlot struct {
		ID          uuid.UUID `json:"id"`
		DayOfWeek   int       `json:"day_of_week"`
		StartTime   string    `json:"start_time"`
		EndTime     string    `json:"end_time"`
		IsAvailable bool      `json:"is_available"`
	}
	weekly := []weekSlot{}
	wRows, _ := h.db.Query(r.Context(),
		`SELECT id, day_of_week, to_char(start_time,'HH24:MI') AS start_time,
		        to_char(end_time,'HH24:MI') AS end_time, is_available
		 FROM worker_availability
		 WHERE business_id=$1 AND user_id=$2 AND deleted_at IS NULL
		 ORDER BY day_of_week`, bizID, claims.UserID)
	if wRows != nil {
		defer wRows.Close()
		for wRows.Next() {
			var s weekSlot
			if err := wRows.Scan(&s.ID, &s.DayOfWeek, &s.StartTime, &s.EndTime, &s.IsAvailable); err == nil {
				weekly = append(weekly, s)
			}
		}
	}

	// Open blocks (pending or approved, future or current).
	blocks := []*blockRow{}
	bRows, _ := h.db.Query(r.Context(),
		`SELECT id, business_id, user_id, created_by, updated_by, block_type,
		        starts_at, ends_at, all_day, reason, status, approved_by, approved_at,
		        metadata, created_at, updated_at
		 FROM availability_blocks
		 WHERE business_id=$1 AND user_id=$2 AND deleted_at IS NULL
		   AND status IN ('pending','approved') AND ends_at >= NOW() - INTERVAL '7 days'
		 ORDER BY starts_at`, bizID, claims.UserID)
	if bRows != nil {
		defer bRows.Close()
		for bRows.Next() {
			br := &blockRow{}
			if err := bRows.Scan(&br.ID, &br.BusinessID, &br.UserID, &br.CreatedBy, &br.UpdatedBy,
				&br.BlockType, &br.StartsAt, &br.EndsAt, &br.AllDay, &br.Reason,
				&br.Status, &br.ApprovedBy, &br.ApprovedAt,
				&br.Metadata, &br.CreatedAt, &br.UpdatedAt); err == nil {
				blocks = append(blocks, br)
			}
		}
	}

	// Roster assignments for the next 30 days.
	rosterOut := []*rosterRow{}
	rRows, _ := h.db.Query(r.Context(),
		`SELECT id, business_id, user_id, job_id, created_by, updated_by,
		        starts_at, ends_at, notes, status, metadata, created_at, updated_at
		 FROM roster_assignments
		 WHERE business_id=$1 AND user_id=$2 AND deleted_at IS NULL
		   AND status IN ('scheduled','confirmed')
		   AND starts_at < NOW() + INTERVAL '30 days'
		   AND ends_at >= NOW() - INTERVAL '1 day'
		 ORDER BY starts_at`, bizID, claims.UserID)
	if rRows != nil {
		defer rRows.Close()
		for rRows.Next() {
			rr := &rosterRow{}
			if err := rRows.Scan(&rr.ID, &rr.BusinessID, &rr.UserID, &rr.JobID, &rr.CreatedBy, &rr.UpdatedBy,
				&rr.StartsAt, &rr.EndsAt, &rr.Notes, &rr.Status,
				&rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt); err == nil {
				rosterOut = append(rosterOut, rr)
			}
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "availability_roster.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"weekly_pattern": weekly,
		"open_blocks":    blocks,
		"upcoming_roster": rosterOut,
	})
}

// ── Recurring weekly pattern (passthrough) ──────────────────────

// SetRecurring (PUT /api/v1/availability_roster/recurring/{user_id}) —
// upserts the week-pattern slots in one call. Mirrors the legacy
// /workers/{id}/availability behaviour but with proper validation.
func (h *Handler) SetRecurring(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roster.update") {
		return
	}

	target, err := uuid.Parse(chi.URLParam(r, "user_id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_user_id")
		return
	}
	// Workers may only set their own pattern.
	if !middleware.IsAtLeast(claims.Role, "manager") && target != claims.UserID {
		respondErr(w, http.StatusForbidden, "forbidden:not_owner")
		return
	}
	if !h.userInTenant(r, target, bizID) {
		respondErr(w, http.StatusBadRequest, "user_not_in_tenant")
		return
	}

	var req []struct {
		DayOfWeek   int    `json:"day_of_week"`
		StartTime   string `json:"start_time"` // "HH:MM"
		EndTime     string `json:"end_time"`
		IsAvailable bool   `json:"is_available"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(req) == 0 || len(req) > 7 {
		respondErr(w, http.StatusBadRequest, "invalid_slot_count")
		return
	}
	for _, s := range req {
		if s.DayOfWeek < 0 || s.DayOfWeek > 6 {
			respondErr(w, http.StatusBadRequest, "invalid_day_of_week")
			return
		}
		if !validHHMM(s.StartTime) || !validHHMM(s.EndTime) {
			respondErr(w, http.StatusBadRequest, "invalid_time_format")
			return
		}
		if s.StartTime >= s.EndTime {
			respondErr(w, http.StatusBadRequest, "start_after_end")
			return
		}
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "tx_failed")
		return
	}
	defer tx.Rollback(r.Context())

	for _, s := range req {
		newID := uuid.New()
		if _, err := tx.Exec(r.Context(),
			`INSERT INTO worker_availability
			   (id, business_id, user_id, created_by, day_of_week, start_time, end_time, is_available, created_at, updated_at)
			 VALUES ($1,$2,$3,$4,$5,$6::TIME,$7::TIME,$8,NOW(),NOW())
			 ON CONFLICT (business_id, user_id, day_of_week)
			 DO UPDATE SET start_time=EXCLUDED.start_time,
			               end_time=EXCLUDED.end_time,
			               is_available=EXCLUDED.is_available,
			               updated_by=EXCLUDED.created_by,
			               updated_at=NOW()`,
			newID, bizID, target, claims.UserID,
			s.DayOfWeek, s.StartTime, s.EndTime, s.IsAvailable,
		); err != nil {
			h.log.Error("upsert recurring slot", zap.Error(err))
			respondErr(w, http.StatusInternalServerError, "upsert_failed")
			return
		}
	}
	if err := tx.Commit(r.Context()); err != nil {
		respondErr(w, http.StatusInternalServerError, "commit_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "worker_availability.recurring",
		NewData:    map[string]interface{}{"target": target, "slots": len(req)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{"updated": len(req)})
}

// ── Export ──────────────────────────────────────────────────────

// Export (GET /api/v1/availability_roster/export.csv) — combined
// blocks + roster CSV for a date range.
func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "roster.export") {
		return
	}

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="availability-roster-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"source", "id", "user_id", "type_or_status", "starts_at", "ends_at", "details"})

	// Blocks first.
	bRows, _ := h.db.Query(r.Context(),
		`SELECT id, user_id, block_type, status, starts_at, ends_at, COALESCE(reason,'')
		 FROM availability_blocks
		 WHERE business_id=$1 AND deleted_at IS NULL
		 ORDER BY starts_at DESC LIMIT 10000`, bizID)
	if bRows != nil {
		defer bRows.Close()
		for bRows.Next() {
			var id, userID uuid.UUID
			var blockType, status, reason string
			var startsAt, endsAt time.Time
			if err := bRows.Scan(&id, &userID, &blockType, &status, &startsAt, &endsAt, &reason); err != nil {
				continue
			}
			_ = cw.Write([]string{
				"block", id.String(), userID.String(), blockType + ":" + status,
				startsAt.UTC().Format(time.RFC3339), endsAt.UTC().Format(time.RFC3339),
				reason,
			})
		}
	}

	// Roster.
	rRows, _ := h.db.Query(r.Context(),
		`SELECT id, user_id, status, starts_at, ends_at, COALESCE(notes,''), job_id
		 FROM roster_assignments
		 WHERE business_id=$1 AND deleted_at IS NULL
		 ORDER BY starts_at DESC LIMIT 10000`, bizID)
	if rRows != nil {
		defer rRows.Close()
		for rRows.Next() {
			var id, userID uuid.UUID
			var status, notes string
			var startsAt, endsAt time.Time
			var jobID *uuid.UUID
			if err := rRows.Scan(&id, &userID, &status, &startsAt, &endsAt, &notes, &jobID); err != nil {
				continue
			}
			jobStr := ""
			if jobID != nil {
				jobStr = jobID.String()
			}
			details := notes
			if jobStr != "" {
				details = "job=" + jobStr + " | " + notes
			}
			_ = cw.Write([]string{
				"roster", id.String(), userID.String(), status,
				startsAt.UTC().Format(time.RFC3339), endsAt.UTC().Format(time.RFC3339),
				details,
			})
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "availability_roster",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Internal helpers ────────────────────────────────────────────

func (h *Handler) userInTenant(r *http.Request, userID, bizID uuid.UUID) bool {
	var ok bool
	if err := h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		userID, bizID).Scan(&ok); err != nil {
		return false
	}
	return ok
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
			EntityType: "availability_roster",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respondErr(w, http.StatusForbidden, "forbidden:"+key)
		return false
	}
	return true
}

// validHHMM checks "HH:MM" format with hour 00-23 and minute 00-59.
func validHHMM(s string) bool {
	if len(s) != 5 || s[2] != ':' {
		return false
	}
	for i, r := range s {
		if i == 2 {
			continue
		}
		if r < '0' || r > '9' {
			return false
		}
	}
	hh, _ := strconv.Atoi(s[:2])
	mm, _ := strconv.Atoi(s[3:])
	return hh >= 0 && hh <= 23 && mm >= 0 && mm <= 59
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
