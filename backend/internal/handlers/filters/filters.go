package filters

import (
	"encoding/json"
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
	cfg *config.Config
	db  *pgxpool.Pool
	log *zap.Logger
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger) *Handler {
	return &Handler{cfg: cfg, db: db, log: log}
}

var allowedEntityTypes = map[string]bool{
	"jobs": true, "customers": true, "leads": true,
	"invoices": true, "quotes": true, "expenses": true,
	"workers": true, "tasks": true,
}

// Create — POST /api/v1/filters
// Body: { entity_type, name, filter_spec, is_shared }
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		EntityType string                 `json:"entity_type"`
		Name       string                 `json:"name"`
		FilterSpec map[string]interface{} `json:"filter_spec"`
		IsShared   bool                   `json:"is_shared"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_body")
		return
	}
	req.EntityType = strings.ToLower(strings.TrimSpace(req.EntityType))
	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		respondErr(w, http.StatusBadRequest, "name_required")
		return
	}
	if !allowedEntityTypes[req.EntityType] {
		respondErr(w, http.StatusBadRequest, "invalid_entity_type")
		return
	}
	if req.FilterSpec == nil {
		req.FilterSpec = map[string]interface{}{}
	}
	specJSON, _ := json.Marshal(req.FilterSpec)

	id := uuid.New()
	_, err := h.db.Exec(r.Context(),
		`INSERT INTO saved_filters (id, user_id, business_id, entity_type, name, filter_spec, is_shared)
		 VALUES ($1,$2,$3,$4,$5,$6,$7)`,
		id, claims.UserID, bizID, req.EntityType, req.Name, specJSON, req.IsShared,
	)
	if err != nil {
		h.log.Error("filters.create", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	respondJSON(w, http.StatusCreated, map[string]interface{}{
		"id":          id,
		"entity_type": req.EntityType,
		"name":        req.Name,
		"filter_spec": req.FilterSpec,
		"is_shared":   req.IsShared,
	})
}

// List — GET /api/v1/filters?entity_type=jobs
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	entityType := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("entity_type")))

	query := `SELECT id, user_id, entity_type, name, filter_spec, is_shared, created_at
	          FROM saved_filters
	          WHERE business_id=$1
	            AND (user_id=$2 OR is_shared=true)`
	args := []interface{}{bizID, claims.UserID}

	if entityType != "" {
		if !allowedEntityTypes[entityType] {
			respondErr(w, http.StatusBadRequest, "invalid_entity_type")
			return
		}
		query += ` AND entity_type=$3`
		args = append(args, entityType)
	}
	query += ` ORDER BY created_at DESC LIMIT 200`

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	type item struct {
		ID         uuid.UUID              `json:"id"`
		UserID     uuid.UUID              `json:"user_id"`
		EntityType string                 `json:"entity_type"`
		Name       string                 `json:"name"`
		FilterSpec map[string]interface{} `json:"filter_spec"`
		IsShared   bool                   `json:"is_shared"`
		IsOwner    bool                   `json:"is_owner"`
		CreatedAt  time.Time              `json:"created_at"`
	}
	out := []item{}
	for rows.Next() {
		var it item
		var raw []byte
		if err := rows.Scan(&it.ID, &it.UserID, &it.EntityType, &it.Name, &raw, &it.IsShared, &it.CreatedAt); err != nil {
			continue
		}
		_ = json.Unmarshal(raw, &it.FilterSpec)
		it.IsOwner = it.UserID == claims.UserID
		out = append(out, it)
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{"filters": out, "total": len(out)})
}

// Delete — DELETE /api/v1/filters/{id}
func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	idStr := chi.URLParam(r, "id")
	id, err := uuid.Parse(idStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	ct, err := h.db.Exec(r.Context(),
		`DELETE FROM saved_filters WHERE id=$1 AND business_id=$2 AND user_id=$3`,
		id, bizID, claims.UserID,
	)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "delete_failed")
		return
	}
	if ct.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ── helpers ───────────────────────────────────────────────────────

func respondJSON(w http.ResponseWriter, code int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if body != nil {
		_ = json.NewEncoder(w).Encode(body)
	}
}

func respondErr(w http.ResponseWriter, code int, msg string) {
	respondJSON(w, code, map[string]string{"error": msg})
}
