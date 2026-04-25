// Package i18n implements M127: Multi-Language string lookup.
//
// Routes (mount at /api/v1/i18n):
//
//	GET /{language}      -> flat key->value map for the requested language
//	                        Falls back to 'en' for any key missing in the
//	                        requested language. Open to all authenticated users.
package i18n

import (
	"encoding/json"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
)

// Whitelisted languages (mirrors the migration CHECK constraint).
var supportedLanguages = map[string]bool{
	"en":    true,
	"en-AU": true,
	"zh":    true,
	"vi":    true,
	"ar":    true,
}

type Handler struct {
	cfg *config.Config
	db  *pgxpool.Pool
	log *zap.Logger
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger) *Handler {
	return &Handler{cfg: cfg, db: db, log: log}
}

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	lang := chi.URLParam(r, "language")
	if !supportedLanguages[lang] {
		respondErr(w, http.StatusBadRequest, "unsupported_language")
		return
	}

	// Use a single query that prefers the requested language but falls back to 'en'.
	rows, err := h.db.Query(r.Context(), `
		SELECT namespace || '.' || key AS k,
		       COALESCE(
		         (SELECT value FROM translation_strings t
		          WHERE t.namespace=ts.namespace AND t.key=ts.key AND t.language=$1
		          LIMIT 1),
		         ts.value
		       ) AS v
		FROM translation_strings ts
		WHERE ts.language='en'
		ORDER BY k`, lang)
	if err != nil {
		h.log.Error("i18n query", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := map[string]string{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			continue
		}
		out[k] = v
	}

	w.Header().Set("Cache-Control", "public, max-age=300")
	respond(w, http.StatusOK, map[string]interface{}{
		"language": lang,
		"strings":  out,
	})
}

// Routes mounts the i18n endpoints. Caller wraps in Auth middleware as needed.
func (h *Handler) Routes() func(r chi.Router) {
	return func(r chi.Router) {
		r.Get("/{language}", h.Get)
	}
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		_ = json.NewEncoder(w).Encode(data)
	}
}

func respondErr(w http.ResponseWriter, status int, msg string) {
	respond(w, status, map[string]string{"error": msg})
}
