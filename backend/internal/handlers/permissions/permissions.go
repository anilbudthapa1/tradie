package permissions

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
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

var validRoles = map[string]bool{
	"owner": true, "admin": true, "manager": true,
	"worker": true, "accountant": true, "customer": true,
}

// ── GET /api/v1/permissions — caller's effective permissions ──────
func (h *Handler) Effective(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	// Per-business override takes precedence over template (NULL business_id).
	rows, err := h.db.Query(r.Context(),
		`SELECT DISTINCT p.key
		 FROM permissions p
		 JOIN role_permissions rp ON rp.permission_id = p.id
		 WHERE rp.role = $1
		   AND (rp.business_id = $2 OR
		        (rp.business_id IS NULL AND NOT EXISTS (
		            SELECT 1 FROM role_permissions rp2 WHERE rp2.role=$1 AND rp2.business_id=$2
		        )))
		 ORDER BY p.key`,
		claims.Role, bizID,
	)
	if err != nil {
		h.log.Error("permissions.effective", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	keys := []string{}
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err == nil {
			keys = append(keys, k)
		}
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"role":        claims.Role,
		"permissions": keys,
	})
}

// ── GET /api/v1/permissions/all — list catalog ────────────────────
func (h *Handler) ListAll(w http.ResponseWriter, r *http.Request) {
	rows, err := h.db.Query(r.Context(),
		`SELECT id, key, COALESCE(description,''), COALESCE(category,'')
		 FROM permissions ORDER BY category, key`)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	type perm struct {
		ID          string `json:"id"`
		Key         string `json:"key"`
		Description string `json:"description"`
		Category    string `json:"category"`
	}
	out := []perm{}
	for rows.Next() {
		var p perm
		if err := rows.Scan(&p.ID, &p.Key, &p.Description, &p.Category); err == nil {
			out = append(out, p)
		}
	}

	// Also return current role->permission map for the business
	bizID := middleware.BusinessIDFromCtx(r.Context())
	mapRows, err := h.db.Query(r.Context(),
		`SELECT role, p.key
		 FROM role_permissions rp
		 JOIN permissions p ON p.id = rp.permission_id
		 WHERE rp.business_id = $1 OR rp.business_id IS NULL
		 ORDER BY role, p.key`,
		bizID,
	)
	roleMap := map[string][]string{}
	if err == nil {
		defer mapRows.Close()
		for mapRows.Next() {
			var role, key string
			if err := mapRows.Scan(&role, &key); err == nil {
				// avoid dupes if both business + template grants exist
				exists := false
				for _, k := range roleMap[role] {
					if k == key {
						exists = true
						break
					}
				}
				if !exists {
					roleMap[role] = append(roleMap[role], key)
				}
			}
		}
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"permissions": out,
		"role_map":    roleMap,
	})
}

// ── PUT /api/v1/permissions/role/{role} — owner only ──────────────
// Body: { permission_keys: ["jobs.create", ...] }
func (h *Handler) UpdateRole(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	role := strings.ToLower(strings.TrimSpace(chi.URLParam(r, "role")))
	if !validRoles[role] {
		respondErr(w, http.StatusBadRequest, "invalid_role")
		return
	}
	if role == "owner" {
		respondErr(w, http.StatusForbidden, "cannot_modify_owner")
		return
	}

	var req struct {
		PermissionKeys []string `json:"permission_keys"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_body")
		return
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "tx_failed")
		return
	}
	defer tx.Rollback(r.Context())

	// Replace existing per-business overrides for this role
	if _, err := tx.Exec(r.Context(),
		`DELETE FROM role_permissions WHERE role=$1 AND business_id=$2`,
		role, bizID,
	); err != nil {
		respondErr(w, http.StatusInternalServerError, "delete_failed")
		return
	}

	added := 0
	for _, key := range req.PermissionKeys {
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		ct, err := tx.Exec(r.Context(),
			`INSERT INTO role_permissions (role, permission_id, business_id)
			 SELECT $1, id, $2 FROM permissions WHERE key=$3
			 ON CONFLICT DO NOTHING`,
			role, bizID, key,
		)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_key:"+key)
			return
		}
		if ct.RowsAffected() > 0 {
			added++
		}
	}

	if err := tx.Commit(r.Context()); err != nil {
		respondErr(w, http.StatusInternalServerError, "commit_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "PERMISSIONS_ROLE_UPDATED",
		EntityType: "role_permissions",
		NewData:    map[string]interface{}{"role": role, "keys": req.PermissionKeys},
		IPAddress:  r.RemoteAddr,
	})

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"role":          role,
		"granted_count": added,
	})
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
