package leads

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
	bizID := middleware.BusinessIDFromCtx(r.Context())

	status := r.URL.Query().Get("status")
	assignedTo := r.URL.Query().Get("assigned_to")

	// Pagination
	page := 1
	pageSize := 50

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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.FirstName == "" {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	var assignedTo *uuid.UUID
	if req.AssignedTo != nil && *req.AssignedTo != "" {
		id, err := uuid.Parse(*req.AssignedTo)
		if err == nil {
			assignedTo = &id
		}
	}

	var l Lead
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO leads (business_id, first_name, last_name, email, phone, status, source, notes, assigned_to)
		 VALUES ($1,$2,$3,$4,$5,'new',$6,$7,$8)
		 RETURNING id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at`,
		bizID, req.FirstName, nullStr(req.LastName), nullStr(req.Email), nullStr(req.Phone),
		nullStr(req.Source), nullStr(req.Notes), assignedTo,
	).Scan(
		&l.ID, &l.BusinessID, &l.FirstName, &l.LastName, &l.Email, &l.Phone,
		&l.Status, &l.Source, &l.Notes, &l.AssignedTo, &l.CreatedAt, &l.UpdatedAt,
	)
	if err != nil {
		h.log.Error("leads create", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "create",
		EntityType: "lead",
		EntityID:   l.ID,
	})
	respond(w, http.StatusCreated, l)
}

// ── Get — GET /api/v1/leads/{id} ──────────────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
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
		 SET first_name=$1, last_name=$2, email=$3, phone=$4, status=$5, source=$6, notes=$7, assigned_to=$8, updated_at=NOW()
		 WHERE id=$9 AND business_id=$10 AND deleted_at IS NULL
		 RETURNING id, business_id, first_name, last_name, email, phone, status, source, notes, assigned_to, created_at, updated_at`,
		current.FirstName, nullStr(current.LastName), nullStr(current.Email), nullStr(current.Phone),
		current.Status, nullStr(current.Source), nullStr(current.Notes), current.AssignedTo,
		id, bizID,
	).Scan(
		&updated.ID, &updated.BusinessID, &updated.FirstName, &updated.LastName, &updated.Email, &updated.Phone,
		&updated.Status, &updated.Source, &updated.Notes, &updated.AssignedTo, &updated.CreatedAt, &updated.UpdatedAt,
	)
	if err != nil {
		h.log.Error("leads update", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "update",
		EntityType: "lead",
		EntityID:   updated.ID,
	})
	respond(w, http.StatusOK, updated)
}

// ── Delete — DELETE /api/v1/leads/{id} ───────────────────────────────────────

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	ct, err := h.db.Exec(r.Context(),
		`UPDATE leads SET deleted_at=NOW() WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	)
	if err != nil || ct.RowsAffected() == 0 {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}

	parsedID, _ := uuid.Parse(id)
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "delete",
		EntityType: "lead",
		EntityID:   parsedID,
	})
	respond(w, http.StatusNoContent, nil)
}

// ── ConvertToCustomer — POST /api/v1/leads/{id}/convert ──────────────────────

type convertResponse struct {
	CustomerID uuid.UUID `json:"customer_id"`
	Message    string    `json:"message"`
}

func (h *Handler) ConvertToCustomer(w http.ResponseWriter, r *http.Request) {
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

	var customerID uuid.UUID
	err = tx.QueryRow(r.Context(),
		`INSERT INTO customers (business_id, first_name, last_name, email, phone, source, notes)
		 VALUES ($1,$2,$3,$4,$5,$6,$7)
		 RETURNING id`,
		bizID, l.FirstName, nullStr(l.LastName), nullStr(l.Email), nullStr(l.Phone),
		nullStr(l.Source), nullStr(l.Notes),
	).Scan(&customerID)
	if err != nil {
		h.log.Error("leads convert: insert customer", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	_, err = tx.Exec(r.Context(),
		`UPDATE leads SET status='won', updated_at=NOW() WHERE id=$1 AND business_id=$2`,
		l.ID, bizID,
	)
	if err != nil {
		h.log.Error("leads convert: update lead status", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	if err := tx.Commit(r.Context()); err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "server_error"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "convert",
		EntityType: "lead",
		EntityID:   l.ID,
	})

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
		r.Get("/{id}", h.Get)
		r.Patch("/{id}", h.Update)
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
