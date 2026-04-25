// Package referrals implements M123: Referral Program.
//
// Routes (mount at /api/v1/referrals):
//
//	POST /                  -> create + send referral invite (any auth)
//	GET  /                  -> list own referrals (any auth)
//	GET  /all               -> list all (admin+)
//	POST /{id}/payout       -> mark reward paid (owner only)
package referrals

import (
	"crypto/rand"
	"encoding/base32"
	"encoding/json"
	"errors"
	"net/http"
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

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── Models ──────────────────────────────────────────────────────────────

type referralRow struct {
	ID             uuid.UUID  `json:"id"`
	ReferrerUserID uuid.UUID  `json:"referrer_user_id"`
	RefereeEmail   string     `json:"referee_email"`
	ReferralCode   string     `json:"referral_code"`
	Status         string     `json:"status"`
	RewardAmount   float64    `json:"reward_amount"`
	RewardPaidAt   *time.Time `json:"reward_paid_at"`
	ConvertedAt    *time.Time `json:"converted_at"`
	CreatedAt      time.Time  `json:"created_at"`
}

// ── POST / ──────────────────────────────────────────────────────────────

type createRequest struct {
	RefereeEmail string  `json:"referee_email"`
	RewardAmount float64 `json:"reward_amount,omitempty"`
	Notes        string  `json:"notes,omitempty"`
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	var req createRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_request")
		return
	}
	req.RefereeEmail = strings.TrimSpace(strings.ToLower(req.RefereeEmail))
	if !isEmail(req.RefereeEmail) {
		respondErr(w, http.StatusBadRequest, "valid email required")
		return
	}
	if req.RewardAmount < 0 {
		respondErr(w, http.StatusBadRequest, "reward_amount cannot be negative")
		return
	}

	code, err := newReferralCode()
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "code_generation_failed")
		return
	}

	id := uuid.New()
	_, err = h.db.Exec(ctx,
		`INSERT INTO referrals
		   (id, business_id, referrer_user_id, referee_email, referral_code,
		    status, reward_amount, notes)
		 VALUES ($1,$2,$3,$4,$5,'sent',$6,$7)`,
		id, bizID, claims.UserID, req.RefereeEmail, code, req.RewardAmount,
		nullable(req.Notes),
	)
	if err != nil {
		h.log.Error("referral insert", zap.Error(err))
		respondErr(w, http.StatusBadRequest, "create_failed")
		return
	}

	// TODO: enqueue an actual email send via SendGrid (M88 notifications). For now
	// we just record the referral and let the notification scheduler pick it up.
	h.audit.Log(ctx, middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "REFERRAL_CREATED",
		EntityType: "referral",
		EntityID:   id,
		NewData: map[string]interface{}{
			"referee_email": req.RefereeEmail,
			"code":          code,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusCreated, map[string]interface{}{
		"id":            id,
		"referral_code": code,
		"status":        "sent",
		"created_at":    time.Now().UTC(),
	})
}

// ── GET / (own) ─────────────────────────────────────────────────────────

func (h *Handler) ListOwn(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	rows, err := h.db.Query(ctx,
		`SELECT id, referrer_user_id, referee_email, referral_code, status,
		        reward_amount, reward_paid_at, converted_at, created_at
		 FROM referrals
		 WHERE business_id=$1 AND referrer_user_id=$2
		 ORDER BY created_at DESC LIMIT 200`,
		bizID, claims.UserID,
	)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()
	respond(w, http.StatusOK, scanReferrals(rows))
}

// ── GET /all (admin+) ───────────────────────────────────────────────────

func (h *Handler) ListAll(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	rows, err := h.db.Query(ctx,
		`SELECT id, referrer_user_id, referee_email, referral_code, status,
		        reward_amount, reward_paid_at, converted_at, created_at
		 FROM referrals
		 WHERE business_id=$1
		 ORDER BY created_at DESC LIMIT 500`,
		bizID,
	)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()
	respond(w, http.StatusOK, scanReferrals(rows))
}

// ── POST /{id}/payout (owner) ───────────────────────────────────────────

func (h *Handler) Payout(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	idStr := chi.URLParam(r, "id")
	id, err := uuid.Parse(idStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var amount float64
	err = h.db.QueryRow(ctx,
		`UPDATE referrals
		 SET reward_paid_at=NOW(), updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND reward_paid_at IS NULL
		 RETURNING reward_amount`,
		id, bizID,
	).Scan(&amount)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found_or_already_paid")
			return
		}
		respondErr(w, http.StatusInternalServerError, "update_failed")
		return
	}

	h.audit.Log(ctx, middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "REFERRAL_PAYOUT",
		EntityType: "referral",
		EntityID:   id,
		NewData: map[string]interface{}{
			"reward_amount": amount,
			"paid_at":       time.Now().UTC(),
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"id":            id,
		"reward_amount": amount,
		"reward_paid_at": time.Now().UTC(),
	})
}

// ── Routes ──────────────────────────────────────────────────────────────
//
// The parent router should wrap /all in RequireOwnerOrAdmin() and
// /{id}/payout in RequireOwner().
func (h *Handler) Routes() func(r chi.Router) {
	return func(r chi.Router) {
		r.Post("/", h.Create)
		r.Get("/", h.ListOwn)
		r.Get("/all", h.ListAll)
		r.Post("/{id}/payout", h.Payout)
	}
}

// ── helpers ─────────────────────────────────────────────────────────────

func scanReferrals(rows pgx.Rows) map[string]interface{} {
	out := []referralRow{}
	for rows.Next() {
		var x referralRow
		if err := rows.Scan(&x.ID, &x.ReferrerUserID, &x.RefereeEmail, &x.ReferralCode,
			&x.Status, &x.RewardAmount, &x.RewardPaidAt, &x.ConvertedAt, &x.CreatedAt); err != nil {
			continue
		}
		out = append(out, x)
	}
	return map[string]interface{}{"referrals": out, "total": len(out)}
}

func newReferralCode() (string, error) {
	buf := make([]byte, 6)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	enc := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(buf)
	// 6 random bytes -> 10 chars in base32; collisions vanishingly rare.
	return strings.ToUpper(enc), nil
}

func isEmail(s string) bool {
	if len(s) < 3 || len(s) > 254 {
		return false
	}
	at := strings.IndexByte(s, '@')
	if at <= 0 || at == len(s)-1 {
		return false
	}
	if !strings.Contains(s[at+1:], ".") {
		return false
	}
	return true
}

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
