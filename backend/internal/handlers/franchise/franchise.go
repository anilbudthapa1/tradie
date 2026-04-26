// Package franchise implements M128 Franchise / Multi-Branch admin endpoints.
//
// Routes (mount at /api/v1/franchise):
//
//	GET  /branches              -> list children of the caller's business (owner only)
//	POST /branches              -> create a new child business under the caller (owner only)
//
// Handlers that want branch-aware queries should consume
// middleware.BranchIDsForCurrentTenant(ctx, db) and scope `business_id = ANY($1)`.
package franchise

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
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── GET /branches ───────────────────────────────────────────────────────

type branchRow struct {
	ID        uuid.UUID `json:"id"`
	Name      string    `json:"name"`
	Slug      string    `json:"slug"`
	City      *string   `json:"city"`
	State     *string   `json:"state"`
	IsActive  bool      `json:"is_active"`
	CreatedAt time.Time `json:"created_at"`
}

func (h *Handler) ListBranches(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	parentID := middleware.BusinessIDFromCtx(ctx)
	if !middleware.IsFranchiseParent(ctx, h.db) {
		respondErr(w, http.StatusForbidden, "not_a_franchise_parent")
		return
	}

	rows, err := h.db.Query(ctx,
		`SELECT id, name, slug, city, state, is_active, created_at
		 FROM businesses
		 WHERE parent_business_id=$1
		 ORDER BY created_at DESC`,
		parentID,
	)
	if err != nil {
		h.log.Error("franchise list", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []branchRow{}
	for rows.Next() {
		var b branchRow
		if err := rows.Scan(&b.ID, &b.Name, &b.Slug, &b.City, &b.State, &b.IsActive, &b.CreatedAt); err != nil {
			continue
		}
		out = append(out, b)
	}
	respond(w, http.StatusOK, map[string]interface{}{"branches": out, "total": len(out)})
}

// ── POST /branches ──────────────────────────────────────────────────────

type createBranchRequest struct {
	Name             string `json:"name"`
	Slug             string `json:"slug"`
	City             string `json:"city,omitempty"`
	State            string `json:"state,omitempty"`
	Phone            string `json:"phone,omitempty"`
	Email            string `json:"email,omitempty"`
	InheritBranding  bool   `json:"inherit_branding"`
	InheritTax       bool   `json:"inherit_tax"`
	InheritInvoice   bool   `json:"inherit_invoice"`
}

func (h *Handler) CreateBranch(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	parentID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	var req createBranchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_request")
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	req.Slug = strings.TrimSpace(strings.ToLower(req.Slug))
	if req.Name == "" || req.Slug == "" {
		respondErr(w, http.StatusBadRequest, "name and slug required")
		return
	}

	// Mark parent as franchise_parent if not already (idempotent).
	if _, err := h.db.Exec(ctx,
		`UPDATE businesses SET is_franchise_parent=TRUE, updated_at=NOW()
		 WHERE id=$1 AND COALESCE(is_franchise_parent,FALSE)=FALSE`,
		parentID,
	); err != nil {
		h.log.Warn("mark franchise parent failed", zap.Error(err))
	}

	// Inherit timezone/country from parent.
	var (
		country, timezone string
	)
	_ = h.db.QueryRow(ctx,
		`SELECT COALESCE(country,'AU'), COALESCE(timezone,'Australia/Sydney')
		 FROM businesses WHERE id=$1`,
		parentID,
	).Scan(&country, &timezone)

	childID := uuid.New()
	_, err := h.db.Exec(ctx,
		`INSERT INTO businesses
		   (id, name, slug, phone, email, city, state, country, timezone, parent_business_id)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
		childID, req.Name, req.Slug,
		nullable(req.Phone), nullable(req.Email),
		nullable(req.City), nullable(req.State),
		country, timezone, parentID,
	)
	if err != nil {
		h.log.Error("franchise create child", zap.Error(err))
		respondErr(w, http.StatusBadRequest, "create_failed")
		return
	}

	if req.InheritBranding {
		_, _ = h.db.Exec(ctx,
			`INSERT INTO business_branding_settings (business_id, primary_color, logo_url)
			 SELECT $1, primary_color, logo_url
			 FROM business_branding_settings WHERE business_id=$2
			 ON CONFLICT (business_id) DO NOTHING`,
			childID, parentID,
		)
	}
	if req.InheritTax {
		_, _ = h.db.Exec(ctx,
			`INSERT INTO business_tax_settings (business_id, gst_rate)
			 SELECT $1, gst_rate FROM business_tax_settings WHERE business_id=$2
			 ON CONFLICT (business_id) DO NOTHING`,
			childID, parentID,
		)
	}
	if req.InheritInvoice {
		_, _ = h.db.Exec(ctx,
			`INSERT INTO business_invoice_settings
			   (business_id, payment_terms, footer_text, bank_name, bank_bsb, bank_account)
			 SELECT $1, payment_terms, footer_text, bank_name, bank_bsb, bank_account
			 FROM business_invoice_settings WHERE business_id=$2
			 ON CONFLICT (business_id) DO NOTHING`,
			childID, parentID,
		)
	}

	h.audit.Log(ctx, middleware.AuditEntry{
		BusinessID: parentID,
		UserID:     claims.UserID,
		Action:     "FRANCHISE_BRANCH_CREATED",
		EntityType: "business",
		EntityID:   childID,
		NewData: map[string]interface{}{
			"name": req.Name,
			"slug": req.Slug,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusCreated, map[string]interface{}{
		"id":                 childID,
		"name":               req.Name,
		"slug":               req.Slug,
		"parent_business_id": parentID,
	})
}

// Routes mounts franchise endpoints. Caller is expected to wrap in
// RequireOwner() — only owners of the parent should manage branches.
func (h *Handler) Routes() func(r chi.Router) {
	return func(r chi.Router) {
		r.Get("/branches", h.ListBranches)
		r.Post("/branches", h.CreateBranch)
	}
}

// ── helpers ─────────────────────────────────────────────────────────────

func nullable(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
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
