package leads

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// ── Handler ───────────────────────────────────────────────────────────────────

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── Model ─────────────────────────────────────────────────────────────────────

type Lead struct {
	ID         uuid.UUID  `json:"id"`
	BusinessID uuid.UUID  `json:"business_id"`
	FirstName  string     `json:"first_name"`
	LastName   string     `json:"last_name"`
	Email      string     `json:"email"`
	Phone      string     `json:"phone"`
	Status     string     `json:"status"`
	Source     string     `json:"source"`
	Notes      string     `json:"notes"`
	AssignedTo *uuid.UUID `json:"assigned_to,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"updated_at"`
}

// ── List — GET /api/v1/leads ──────────────────────────────────────────────────

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "leads.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())

	status := r.URL.Query().Get("status")
	assignedTo := r.URL.Query().Get("assigned_to")

	// Pagination — page param was previously hardcoded to 1.
	page := 1
	if v := r.URL.Query().Get("page"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 1000 {
			page = n
		}
	}
	pageSize := 50
	if v := r.URL.Query().Get("page_size"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 200 {
			pageSize = n
		}
	}
	if status != "" && !validStatuses[status] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	var (
		rows pgx.Rows
		err  error
	)

	switch {
	case status != "" && assignedTo != "":
		rows, err = h.db.Query(r.Context(),
			`SELECT id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at
			 FROM leads
			 WHERE business_id=$1 AND deleted_at IS NULL AND status=$2 AND assigned_to=$3
			 ORDER BY created_at DESC LIMIT $4 OFFSET $5`,
			bizID, status, assignedTo, pageSize, (page-1)*pageSize)
	case status != "":
		rows, err = h.db.Query(r.Context(),
			`SELECT id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at
			 FROM leads
			 WHERE business_id=$1 AND deleted_at IS NULL AND status=$2
			 ORDER BY created_at DESC LIMIT $3 OFFSET $4`,
			bizID, status, pageSize, (page-1)*pageSize)
	case assignedTo != "":
		rows, err = h.db.Query(r.Context(),
			`SELECT id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at
			 FROM leads
			 WHERE business_id=$1 AND deleted_at IS NULL AND assigned_to=$2
			 ORDER BY created_at DESC LIMIT $3 OFFSET $4`,
			bizID, assignedTo, pageSize, (page-1)*pageSize)
	default:
		rows, err = h.db.Query(r.Context(),
			`SELECT id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at
			 FROM leads
			 WHERE business_id=$1 AND deleted_at IS NULL
			 ORDER BY created_at DESC LIMIT $2 OFFSET $3`,
			bizID, pageSize, (page-1)*pageSize)
	}

	if err != nil {
		h.log.Error("leads list query", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	list := []Lead{}
	for rows.Next() {
		var l Lead
		if err := rows.Scan(
			&l.ID, &l.BusinessID, &l.FirstName, &l.LastName, &l.Email, &l.Phone,
			&l.Status, &l.Source, &l.Notes, &l.AssignedTo, &l.CreatedAt, &l.UpdatedAt,
		); err != nil {
			continue
		}
		list = append(list, l)
	}
	respond(w, http.StatusOK, list)
}

// ── Create — POST /api/v1/leads ───────────────────────────────────────────────

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "leads.create") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		FirstName  string  `json:"first_name"`
		LastName   string  `json:"last_name"`
		Email      string  `json:"email"`
		Phone      string  `json:"phone"`
		Source     string  `json:"source"`
		Notes      string  `json:"notes"`
		AssignedTo *string `json:"assigned_to,omitempty"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if req.FirstName == "" {
		respond(w, http.StatusBadRequest, map[string]string{"error": "first_name_required"})
		return
	}

	// Workers may only assign leads to themselves; managers+ can assign to anyone.
	var assignedTo *uuid.UUID
	if req.AssignedTo != nil && *req.AssignedTo != "" {
		id, err := uuid.Parse(*req.AssignedTo)
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_assigned_to"})
			return
		}
		if !middleware.IsAtLeast(claims.Role, "manager") && id != claims.UserID {
			respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:assign_to_other"})
			return
		}
		assignedTo = &id
	}

	var l Lead
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO leads (business_id, created_by, first_name, last_name, email, phone, status, source, notes, assigned_to)
		 VALUES ($1,$2,$3,$4,$5,$6,'new',$7,$8,$9)
		 RETURNING id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at`,
		bizID, claims.UserID, req.FirstName, nullStr(req.LastName), nullStr(req.Email), nullStr(req.Phone),
		nullStr(req.Source), nullStr(req.Notes), assignedTo,
	).Scan(
		&l.ID, &l.BusinessID, &l.FirstName, &l.LastName, &l.Email, &l.Phone,
		&l.Status, &l.Source, &l.Notes, &l.AssignedTo, &l.CreatedAt, &l.UpdatedAt,
	)
	if err != nil {
		h.log.Error("leads create", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "create_failed"})
		return
	}

	h.auditModuleAction(r, AuditCreated, l.ID, nil, map[string]interface{}{
		"first_name": req.FirstName, "source": req.Source,
		"email": maskedEmail(req.Email), "assigned_to": assignedTo,
	})
	respond(w, http.StatusCreated, l)
}

// ── Get — GET /api/v1/leads/{id} ──────────────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "leads.view") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var l Lead
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at
		 FROM leads WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(
		&l.ID, &l.BusinessID, &l.FirstName, &l.LastName, &l.Email, &l.Phone,
		&l.Status, &l.Source, &l.Notes, &l.AssignedTo, &l.CreatedAt, &l.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}
	respond(w, http.StatusOK, l)
}

// ── Update — PATCH /api/v1/leads/{id} ────────────────────────────────────────

var validStatuses = map[string]bool{
	"new": true, "contacted": true, "qualified": true,
	"proposal": true, "won": true, "lost": true,
}

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "leads.update") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		FirstName  *string `json:"first_name,omitempty"`
		LastName   *string `json:"last_name,omitempty"`
		Email      *string `json:"email,omitempty"`
		Phone      *string `json:"phone,omitempty"`
		Status     *string `json:"status,omitempty"`
		Source     *string `json:"source,omitempty"`
		Notes      *string `json:"notes,omitempty"`
		AssignedTo *string `json:"assigned_to,omitempty"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	if req.Status != nil && !validStatuses[*req.Status] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}

	// Fetch current
	var current Lead
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at
		 FROM leads WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(
		&current.ID, &current.BusinessID, &current.FirstName, &current.LastName, &current.Email, &current.Phone,
		&current.Status, &current.Source, &current.Notes, &current.AssignedTo, &current.CreatedAt, &current.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	// Validate status transition before mutating (matches the DB trigger).
	if req.Status != nil && *req.Status != current.Status {
		if !allowedStatusTransition[[2]string{current.Status, *req.Status}] {
			respond(w, http.StatusConflict, map[string]string{
				"error": "invalid_status_transition",
				"from":  current.Status,
				"to":    *req.Status,
			})
			return
		}
	}

	// Capture old data for the audit payload before merge.
	oldStatus := current.Status
	oldAssigned := current.AssignedTo

	// Merge patch fields
	if req.FirstName != nil {
		current.FirstName = *req.FirstName
	}
	if req.LastName != nil {
		current.LastName = *req.LastName
	}
	if req.Email != nil {
		current.Email = *req.Email
	}
	if req.Phone != nil {
		current.Phone = *req.Phone
	}
	if req.Status != nil {
		current.Status = *req.Status
	}
	if req.Source != nil {
		current.Source = *req.Source
	}
	if req.Notes != nil {
		current.Notes = *req.Notes
	}
	if req.AssignedTo != nil {
		if *req.AssignedTo == "" {
			current.AssignedTo = nil
		} else {
			parsed, err := uuid.Parse(*req.AssignedTo)
			if err == nil {
				current.AssignedTo = &parsed
			}
		}
	}

	var updated Lead
	err = h.db.QueryRow(r.Context(),
		`UPDATE leads
		 SET first_name=$1, last_name=$2, email=$3, phone=$4, status=$5, source=$6, notes=$7, assigned_to=$8,
		     updated_by=$11, updated_at=NOW()
		 WHERE id=$9 AND business_id=$10 AND deleted_at IS NULL
		 RETURNING id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at`,
		current.FirstName, nullStr(current.LastName), nullStr(current.Email), nullStr(current.Phone),
		current.Status, nullStr(current.Source), nullStr(current.Notes), current.AssignedTo,
		id, bizID, claims.UserID,
	).Scan(
		&updated.ID, &updated.BusinessID, &updated.FirstName, &updated.LastName, &updated.Email, &updated.Phone,
		&updated.Status, &updated.Source, &updated.Notes, &updated.AssignedTo, &updated.CreatedAt, &updated.UpdatedAt,
	)
	if err != nil {
		// Trigger raises check_violation for invalid transitions.
		if isStatusTransitionError(err) {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		h.log.Error("leads update", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "update_failed"})
		return
	}

	h.auditModuleAction(r, AuditUpdated, updated.ID,
		map[string]interface{}{"status": oldStatus, "assigned_to": oldAssigned},
		map[string]interface{}{"status": updated.Status, "assigned_to": updated.AssignedTo})
	respond(w, http.StatusOK, updated)
}

// ── Delete — DELETE /api/v1/leads/{id} ───────────────────────────────────────

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "leads.delete") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	idStr := chi.URLParam(r, "id")
	id, err := uuid.Parse(idStr)
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	ct, err := h.db.Exec(r.Context(),
		`UPDATE leads SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID,
	)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "delete_failed"})
		return
	}
	if ct.RowsAffected() == 0 {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}

	h.auditModuleAction(r, AuditDeleted, id, nil, nil)
	respond(w, http.StatusNoContent, nil)
}

// ── ConvertToCustomer — POST /api/v1/leads/{id}/convert ──────────────────────

type convertResponse struct {
	CustomerID uuid.UUID `json:"customer_id"`
	Message    string    `json:"message"`
}

func (h *Handler) ConvertToCustomer(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "leads.convert") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	// Fetch lead
	var l Lead
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at
		 FROM leads WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(
		&l.ID, &l.BusinessID, &l.FirstName, &l.LastName, &l.Email, &l.Phone,
		&l.Status, &l.Source, &l.Notes, &l.AssignedTo, &l.CreatedAt, &l.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respond(w, http.StatusNotFound, map[string]string{"error": "lead_not_found"})
			return
		}
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	if l.Status == "won" {
		respond(w, http.StatusConflict, map[string]string{"error": "lead_already_converted"})
		return
	}

	// Use a transaction: create customer + mark lead as won atomically
	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}
	defer tx.Rollback(r.Context()) //nolint:errcheck

	// Lead must be in 'proposal' to transition to 'won' under the
	// new transition guard. Direct conversion from earlier statuses
	// must walk the pipeline first or use a manager override.
	if l.Status != "proposal" {
		respond(w, http.StatusConflict, map[string]string{
			"error":  "lead_not_in_proposal",
			"status": l.Status,
		})
		return
	}

	var customerID uuid.UUID
	err = tx.QueryRow(r.Context(),
		`INSERT INTO customers (business_id, created_by, first_name, last_name, email, phone, source, notes)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		 RETURNING id`,
		bizID, claims.UserID, l.FirstName, nullStr(l.LastName), nullStr(l.Email), nullStr(l.Phone),
		nullStr(l.Source), nullStr(l.Notes),
	).Scan(&customerID)
	if err != nil {
		h.log.Error("leads convert: insert customer", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "convert_failed"})
		return
	}

	_, err = tx.Exec(r.Context(),
		`UPDATE leads SET status='won', updated_by=$3, updated_at=NOW() WHERE id=$1 AND business_id=$2`,
		l.ID, bizID, claims.UserID,
	)
	if err != nil {
		if isStatusTransitionError(err) {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		h.log.Error("leads convert: update lead status", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "convert_failed"})
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "commit_failed"})
		return
	}

	h.auditModuleAction(r, AuditUpdated, l.ID,
		map[string]interface{}{"status": l.Status},
		map[string]interface{}{"status": "won", "converted_to_customer": customerID})

	respond(w, http.StatusOK, convertResponse{
		CustomerID: customerID,
		Message:    "Lead successfully converted to customer",
	})
}

// ── Routes ────────────────────────────────────────────────────────────────────

func (h *Handler) Routes() func(r chi.Router) {
	return func(r chi.Router) {
		r.Get("/", h.List)
		r.Post("/", h.Create)
		r.Get("/export.csv", h.Export)
		r.Get("/{id}", h.Get)
		r.Patch("/{id}", h.Update)
		r.Put("/{id}", h.Update)
		r.Delete("/{id}", h.Delete)
		r.Post("/{id}/convert", h.ConvertToCustomer)
	}
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		_ = json.NewEncoder(w).Encode(data)
	}
}

func nullStr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
