package bulk_update

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

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

// fieldSpec defines an updatable field for an entity, including SQL fragment + a value validator.
type fieldSpec struct {
	column   string
	validate func(v interface{}) (interface{}, bool)
}

// allowList maps entity_type -> field name -> spec.
// Anything not in this list is rejected.
var allowList = map[string]map[string]fieldSpec{
	"jobs": {
		"status": {column: "status", validate: enumValidator("pending", "scheduled", "in_progress", "completed", "cancelled", "on_hold")},
	},
	"leads": {
		"assigned_to": {column: "assigned_to", validate: nullableUUIDValidator},
	},
	"customers": {
		"is_active": {column: "is_active", validate: boolValidator},
	},
	"invoices": {
		"due_date": {column: "due_date", validate: dateValidator},
	},
}

const maxIDs = 500

// Apply — POST /api/v1/bulk-update/{entity_type}
// Body: { ids: [uuid...], updates: { field: value } }
func (h *Handler) Apply(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	entityType := strings.ToLower(strings.TrimSpace(chi.URLParam(r, "entity_type")))
	fields, ok := allowList[entityType]
	if !ok {
		respondErr(w, http.StatusBadRequest, "invalid_entity_type")
		return
	}

	var req struct {
		IDs     []string               `json:"ids"`
		Updates map[string]interface{} `json:"updates"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_body")
		return
	}
	if len(req.IDs) == 0 {
		respondErr(w, http.StatusBadRequest, "ids_required")
		return
	}
	if len(req.IDs) > maxIDs {
		respondErr(w, http.StatusBadRequest, "too_many_ids")
		return
	}
	if len(req.Updates) == 0 {
		respondErr(w, http.StatusBadRequest, "updates_required")
		return
	}

	// Validate every requested field is in allow-list and value is acceptable
	setFragments := []string{}
	args := []interface{}{}
	argIdx := 1
	for k, v := range req.Updates {
		spec, exists := fields[k]
		if !exists {
			respondErr(w, http.StatusBadRequest, "field_not_allowed:"+k)
			return
		}
		validated, ok := spec.validate(v)
		if !ok {
			respondErr(w, http.StatusBadRequest, "invalid_value:"+k)
			return
		}
		setFragments = append(setFragments, fmt.Sprintf("%s = $%d", spec.column, argIdx))
		args = append(args, validated)
		argIdx++
	}

	// Parse IDs
	ids := make([]uuid.UUID, 0, len(req.IDs))
	for _, s := range req.IDs {
		id, err := uuid.Parse(s)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_uuid:"+s)
			return
		}
		ids = append(ids, id)
	}

	// Build query: UPDATE <table> SET ... WHERE business_id=$N AND id = ANY($M)
	args = append(args, bizID)
	bizParam := argIdx
	argIdx++
	args = append(args, ids)
	idsParam := argIdx

	query := fmt.Sprintf(
		"UPDATE %s SET %s, updated_at=NOW() WHERE business_id=$%d AND id = ANY($%d) RETURNING id",
		entityType,
		strings.Join(setFragments, ", "),
		bizParam, idsParam,
	)

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		h.log.Error("bulk_update", zap.Error(err), zap.String("entity", entityType))
		respondErr(w, http.StatusInternalServerError, "update_failed")
		return
	}
	defer rows.Close()

	updatedIDs := []uuid.UUID{}
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err == nil {
			updatedIDs = append(updatedIDs, id)
		}
	}

	// Audit each affected row
	for _, id := range updatedIDs {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     "BULK_UPDATE_ROW",
			EntityType: entityType,
			EntityID:   id,
			NewData:    req.Updates,
			IPAddress:  r.RemoteAddr,
		})
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"requested_count": len(ids),
		"updated_count":   len(updatedIDs),
		"updated_ids":     updatedIDs,
	})
}

// ── Validators ────────────────────────────────────────────────────

func enumValidator(allowed ...string) func(interface{}) (interface{}, bool) {
	set := make(map[string]bool, len(allowed))
	for _, v := range allowed {
		set[v] = true
	}
	return func(v interface{}) (interface{}, bool) {
		s, ok := v.(string)
		if !ok || !set[s] {
			return nil, false
		}
		return s, true
	}
}

func boolValidator(v interface{}) (interface{}, bool) {
	b, ok := v.(bool)
	return b, ok
}

func nullableUUIDValidator(v interface{}) (interface{}, bool) {
	if v == nil {
		return nil, true
	}
	s, ok := v.(string)
	if !ok {
		return nil, false
	}
	if s == "" {
		return nil, true
	}
	id, err := uuid.Parse(s)
	if err != nil {
		return nil, false
	}
	return id, true
}

func dateValidator(v interface{}) (interface{}, bool) {
	s, ok := v.(string)
	if !ok {
		return nil, false
	}
	// Postgres will validate the actual date; we just require non-empty string
	if len(s) < 8 {
		return nil, false
	}
	return s, true
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
