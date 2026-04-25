package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
	"github.com/tradie/api/internal/models"
	"github.com/tradie/api/internal/validator"
)

type Handler struct {
	cfg      *config.Config
	db       *pgxpool.Pool
	rdb      *redis.Client
	log      *zap.Logger
	audit    *middleware.AuditService
	webauthn *webauthn.WebAuthn
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, rdb *redis.Client, log *zap.Logger, audit *middleware.AuditService) *Handler {
	wa, _ := webauthn.New(&webauthn.Config{
		RPDisplayName: cfg.WebAuthnRPName,
		RPID:          cfg.WebAuthnRPID,
		RPOrigins:     cfg.WebAuthnRPOrigins,
	})
	return &Handler{cfg: cfg, db: db, rdb: rdb, log: log, audit: audit, webauthn: wa}
}

// ── Register ──────────────────────────────────────────────────────

type RegisterRequest struct {
	FirstName    string `json:"first_name" validate:"required,min=2"`
	LastName     string `json:"last_name" validate:"required"`
	Email        string `json:"email" validate:"required,email"`
	Password     string `json:"password" validate:"required,min=8"`
	BusinessName string `json:"business_name" validate:"required,min=2"`
	Phone        string `json:"phone"`
	Timezone     string `json:"timezone"`
}

func (h *Handler) Register(w http.ResponseWriter, r *http.Request) {
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if errs := validator.Validate(req); errs != nil {
		respondValidation(w, errs)
		return
	}

	var exists bool
	_ = h.db.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM users WHERE email=$1 AND deleted_at IS NULL)`, req.Email).Scan(&exists)
	if exists {
		respondError(w, http.StatusConflict, "email_taken")
		return
	}

	hash, err := hashPassword(req.Password)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	tz := req.Timezone
	if tz == "" {
		tz = "Australia/Sydney"
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	defer tx.Rollback(r.Context())

	var bizID uuid.UUID
	slug := generateSlug(req.BusinessName)
	err = tx.QueryRow(r.Context(),
		`INSERT INTO businesses (name, slug, timezone, trial_ends_at) VALUES ($1,$2,$3,NOW()+INTERVAL '14 days') RETURNING id`,
		req.BusinessName, slug, tz,
	).Scan(&bizID)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	for _, q := range []string{
		`INSERT INTO business_settings (business_id) VALUES ($1)`,
		`INSERT INTO business_tax_settings (business_id) VALUES ($1)`,
		`INSERT INTO business_invoice_settings (business_id) VALUES ($1)`,
		`INSERT INTO business_payroll_settings (business_id) VALUES ($1)`,
		`INSERT INTO job_settings (business_id) VALUES ($1)`,
		`INSERT INTO scheduling_settings (business_id) VALUES ($1)`,
		`INSERT INTO notification_preferences (business_id) VALUES ($1)`,
		`INSERT INTO security_settings (business_id) VALUES ($1)`,
	} {
		_, _ = tx.Exec(r.Context(), q, bizID)
	}

	var starterPlanID uuid.UUID
	if err := tx.QueryRow(r.Context(), `SELECT id FROM plans WHERE slug='starter'`).Scan(&starterPlanID); err == nil {
		_, _ = tx.Exec(r.Context(),
			`INSERT INTO subscriptions (business_id, plan_id, status, trial_ends_at) VALUES ($1,$2,'trialing',NOW()+INTERVAL '14 days')`,
			bizID, starterPlanID)
	}

	var userID uuid.UUID
	err = tx.QueryRow(r.Context(),
		`INSERT INTO users (business_id, email, phone, first_name, last_name, role, password_hash, is_verified)
		 VALUES ($1,$2,$3,$4,$5,'owner',$6,false) RETURNING id`,
		bizID, req.Email, nullStr(req.Phone), req.FirstName, req.LastName, hash,
	).Scan(&userID)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	_, _ = tx.Exec(r.Context(), `INSERT INTO user_preferences (user_id) VALUES ($1)`, userID)
	_, _ = tx.Exec(r.Context(), `INSERT INTO user_notification_preferences (user_id) VALUES ($1)`, userID)

	if err = tx.Commit(r.Context()); err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	go h.sendVerificationEmail(req.Email)

	user := &models.User{ID: userID, BusinessID: bizID, Email: req.Email, FirstName: req.FirstName, LastName: req.LastName, Role: "owner"}
	access, refresh, err := h.issueTokens(r.Context(), user, r.UserAgent(), r.RemoteAddr)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	respondJSON(w, http.StatusCreated, map[string]interface{}{
		"access_token":  access,
		"refresh_token": refresh,
		"user":          user,
		"business_id":   bizID,
	})
}

// ── Login ─────────────────────────────────────────────────────────

type LoginRequest struct {
	Email    string `json:"email" validate:"required,email"`
	Password string `json:"password" validate:"required"`
}

func (h *Handler) Login(w http.ResponseWriter, r *http.Request) {
	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}

	var failCount int
	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM login_attempts WHERE email=$1 AND success=false AND created_at>NOW()-INTERVAL '15 minutes'`,
		req.Email).Scan(&failCount)
	if failCount >= 5 {
		respondError(w, http.StatusTooManyRequests, "too_many_attempts")
		return
	}

	var user models.User
	var passwordHash string
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, email, first_name, last_name, role, password_hash, is_active, is_verified
		 FROM users WHERE email=$1 AND deleted_at IS NULL`, req.Email,
	).Scan(&user.ID, &user.BusinessID, &user.Email, &user.FirstName, &user.LastName,
		&user.Role, &passwordHash, &user.IsActive, &user.IsVerified)

	riskScore := h.calcRiskScore(r.Context(), req.Email, r.RemoteAddr, r.UserAgent())

	record := func(ok bool) {
		_, _ = h.db.Exec(r.Context(),
			`INSERT INTO login_attempts (email, ip_address, success, risk_score) VALUES ($1,$2,$3,$4)`,
			req.Email, r.RemoteAddr, ok, riskScore)
	}

	if err == pgx.ErrNoRows || !verifyPassword(passwordHash, req.Password) {
		record(false)
		respondError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	if !user.IsActive {
		respondError(w, http.StatusForbidden, "account_disabled")
		return
	}
	record(true)
	_, _ = h.db.Exec(r.Context(), `UPDATE users SET last_login_at=NOW() WHERE id=$1`, user.ID)

	var mfaEnabled bool
	_ = h.db.QueryRow(r.Context(), `SELECT enabled FROM mfa_secrets WHERE user_id=$1`, user.ID).Scan(&mfaEnabled)
	if mfaEnabled {
		mfaToken, err := h.storeMFAPending(r.Context(), user.ID)
		if err != nil {
			respondError(w, http.StatusInternalServerError, "server_error")
			return
		}
		respondJSON(w, http.StatusOK, map[string]interface{}{"mfa_required": true, "mfa_token": mfaToken})
		return
	}

	access, refresh, err := h.issueTokens(r.Context(), &user, r.UserAgent(), r.RemoteAddr)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{"access_token": access, "refresh_token": refresh, "user": user})
}

// ── MFA Login (public — verify TOTP after password login) ─────────

func (h *Handler) MFALogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		MFAToken string `json:"mfa_token"`
		Code     string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.MFAToken == "" || req.Code == "" {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}

	userIDStr, err := h.rdb.Get(r.Context(), "mfa_pending:"+hashToken(req.MFAToken)).Result()
	if err != nil {
		respondError(w, http.StatusUnauthorized, "invalid_or_expired_token")
		return
	}
	userID, err := uuid.Parse(userIDStr)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	var secret string
	if err := h.db.QueryRow(r.Context(),
		`SELECT secret FROM mfa_secrets WHERE user_id=$1 AND enabled=true`, userID,
	).Scan(&secret); err != nil {
		respondError(w, http.StatusUnauthorized, "mfa_not_configured")
		return
	}

	if !validateTOTP(secret, req.Code) {
		// Check backup codes
		if !h.useBackupCode(r.Context(), userID, req.Code) {
			respondError(w, http.StatusUnauthorized, "invalid_code")
			return
		}
	}

	h.rdb.Del(r.Context(), "mfa_pending:"+hashToken(req.MFAToken))

	var user models.User
	_ = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, email, first_name, last_name, role FROM users WHERE id=$1`, userID,
	).Scan(&user.ID, &user.BusinessID, &user.Email, &user.FirstName, &user.LastName, &user.Role)

	access, refresh, err := h.issueTokens(r.Context(), &user, r.UserAgent(), r.RemoteAddr)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{"access_token": access, "refresh_token": refresh, "user": user})
}

// ── Accept Invite ─────────────────────────────────────────────────

func (h *Handler) AcceptInvite(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token     string `json:"token"`
		FirstName string `json:"first_name"`
		LastName  string `json:"last_name"`
		Password  string `json:"password"`
		Phone     string `json:"phone"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Password) < 8 {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}

	hashed := hashToken(req.Token)
	var inviteEmail string
	var inviteBizID uuid.UUID
	var inviteRole string
	var expiresAt time.Time
	err := h.db.QueryRow(r.Context(),
		`SELECT email, business_id, role, expires_at FROM team_invites WHERE token_hash=$1 AND accepted_at IS NULL`,
		hashed,
	).Scan(&inviteEmail, &inviteBizID, &inviteRole, &expiresAt)
	if err != nil || time.Now().After(expiresAt) {
		respondError(w, http.StatusBadRequest, "invalid_or_expired_invite")
		return
	}

	passHash, err := hashPassword(req.Password)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	defer tx.Rollback(r.Context())

	// Create or update the user for this invite
	var userID uuid.UUID
	err = tx.QueryRow(r.Context(),
		`INSERT INTO users (business_id, email, first_name, last_name, phone, role, password_hash, is_verified)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,true)
		 ON CONFLICT (business_id, email) DO UPDATE SET first_name=$3, last_name=$4, phone=$5, password_hash=$7, is_verified=true
		 RETURNING id`,
		inviteBizID, inviteEmail, req.FirstName, req.LastName, nullStr(req.Phone), inviteRole, passHash,
	).Scan(&userID)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	_, _ = tx.Exec(r.Context(), `UPDATE team_invites SET accepted_at=NOW() WHERE token_hash=$1`, hashed)

	if err = tx.Commit(r.Context()); err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	var user models.User
	_ = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, email, first_name, last_name, role FROM users WHERE id=$1`, userID,
	).Scan(&user.ID, &user.BusinessID, &user.Email, &user.FirstName, &user.LastName, &user.Role)

	access, refresh, err := h.issueTokens(r.Context(), &user, r.UserAgent(), r.RemoteAddr)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{"access_token": access, "refresh_token": refresh, "user": user})
}

// ── Token Management ──────────────────────────────────────────────

func (h *Handler) RefreshToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	hashed := hashToken(req.RefreshToken)
	var userID, bizID uuid.UUID
	var expiresAt time.Time
	err := h.db.QueryRow(r.Context(),
		`SELECT u.id, u.business_id, rt.expires_at FROM refresh_tokens rt JOIN users u ON u.id=rt.user_id
		 WHERE rt.token_hash=$1 AND rt.revoked_at IS NULL`, hashed,
	).Scan(&userID, &bizID, &expiresAt)
	if err != nil || time.Now().After(expiresAt) {
		respondError(w, http.StatusUnauthorized, "invalid_token")
		return
	}
	_, _ = h.db.Exec(r.Context(), `UPDATE refresh_tokens SET revoked_at=NOW() WHERE token_hash=$1`, hashed)
	var user models.User
	_ = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, email, first_name, last_name, role FROM users WHERE id=$1`, userID,
	).Scan(&user.ID, &user.BusinessID, &user.Email, &user.FirstName, &user.LastName, &user.Role)
	access, refresh, err := h.issueTokens(r.Context(), &user, r.UserAgent(), r.RemoteAddr)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{"access_token": access, "refresh_token": refresh})
}

func (h *Handler) Logout(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.RefreshToken != "" {
		_, _ = h.db.Exec(r.Context(), `UPDATE refresh_tokens SET revoked_at=NOW() WHERE token_hash=$1`, hashToken(req.RefreshToken))
	}
	respondJSON(w, http.StatusOK, map[string]string{"message": "logged_out"})
}

// ── Me ────────────────────────────────────────────────────────────

func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	var user models.User
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, email, phone, first_name, last_name, role, avatar_url, is_active, is_verified, last_login_at, created_at, updated_at
		 FROM users WHERE id=$1`, claims.UserID,
	).Scan(&user.ID, &user.BusinessID, &user.Email, &user.Phone, &user.FirstName, &user.LastName,
		&user.Role, &user.AvatarURL, &user.IsActive, &user.IsVerified, &user.LastLoginAt, &user.CreatedAt, &user.UpdatedAt)
	if err != nil {
		respondError(w, http.StatusNotFound, "not_found")
		return
	}
	respondJSON(w, http.StatusOK, user)
}

// ── Update Me ─────────────────────────────────────────────────────

func (h *Handler) UpdateMe(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	var req struct {
		FirstName *string `json:"first_name"`
		LastName  *string `json:"last_name"`
		Phone     *string `json:"phone"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	_, err := h.db.Exec(r.Context(),
		`UPDATE users SET
		  first_name=COALESCE($2,first_name),
		  last_name=COALESCE($3,last_name),
		  phone=COALESCE($4,phone),
		  updated_at=NOW()
		 WHERE id=$1`,
		claims.UserID, req.FirstName, req.LastName, req.Phone)
	if err != nil {
		h.log.Error("update me failed", zap.Error(err))
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	h.Me(w, r)
}

// ── Password Reset ────────────────────────────────────────────────

func (h *Handler) ForgotPassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	go h.sendPasswordReset(req.Email)
	respondJSON(w, http.StatusOK, map[string]string{"message": "if_exists_email_sent"})
}

func (h *Handler) ResetPassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token    string `json:"token"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Password) < 8 {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	hashed := hashToken(req.Token)
	var userID uuid.UUID
	var expiresAt time.Time
	err := h.db.QueryRow(r.Context(),
		`SELECT user_id, expires_at FROM password_reset_tokens WHERE token_hash=$1 AND used_at IS NULL`, hashed,
	).Scan(&userID, &expiresAt)
	if err != nil || time.Now().After(expiresAt) {
		respondError(w, http.StatusBadRequest, "invalid_or_expired_token")
		return
	}
	newHash, err := hashPassword(req.Password)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	_, _ = h.db.Exec(r.Context(), `UPDATE users SET password_hash=$1 WHERE id=$2`, newHash, userID)
	_, _ = h.db.Exec(r.Context(), `UPDATE password_reset_tokens SET used_at=NOW() WHERE token_hash=$1`, hashed)
	_, _ = h.db.Exec(r.Context(), `UPDATE refresh_tokens SET revoked_at=NOW() WHERE user_id=$1 AND revoked_at IS NULL`, userID)
	respondJSON(w, http.StatusOK, map[string]string{"message": "password_reset"})
}

// ── Email Verification ────────────────────────────────────────────

func (h *Handler) VerifyEmail(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token string `json:"token"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	hashed := hashToken(req.Token)
	var email string
	var expiresAt time.Time
	err := h.db.QueryRow(r.Context(),
		`SELECT email, expires_at FROM registration_tokens WHERE token_hash=$1 AND used_at IS NULL`, hashed,
	).Scan(&email, &expiresAt)
	if err != nil || time.Now().After(expiresAt) {
		respondError(w, http.StatusBadRequest, "invalid_token")
		return
	}
	_, _ = h.db.Exec(r.Context(), `UPDATE users SET is_verified=true WHERE email=$1`, email)
	_, _ = h.db.Exec(r.Context(), `UPDATE registration_tokens SET used_at=NOW() WHERE token_hash=$1`, hashed)
	respondJSON(w, http.StatusOK, map[string]string{"message": "email_verified"})
}

// ── Sessions ──────────────────────────────────────────────────────

func (h *Handler) ListSessions(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	rows, _ := h.db.Query(r.Context(),
		`SELECT id, device_info, ip_address, user_agent, location, is_current, last_seen, created_at
		 FROM login_sessions WHERE user_id=$1 ORDER BY last_seen DESC LIMIT 20`,
		claims.UserID)
	defer rows.Close()
	var sessions []map[string]interface{}
	for rows.Next() {
		s := make(map[string]interface{})
		var id, deviceInfo, ipAddr, userAgent, location, lastSeen, createdAt interface{}
		var isCurrent bool
		_ = rows.Scan(&id, &deviceInfo, &ipAddr, &userAgent, &location, &isCurrent, &lastSeen, &createdAt)
		s["id"] = id
		s["device_info"] = deviceInfo
		s["ip_address"] = ipAddr
		s["user_agent"] = userAgent
		s["location"] = location
		s["is_current"] = isCurrent
		s["last_seen"] = lastSeen
		s["created_at"] = createdAt
		sessions = append(sessions, s)
	}
	if sessions == nil {
		sessions = []map[string]interface{}{}
	}
	respondJSON(w, http.StatusOK, sessions)
}

func (h *Handler) RevokeSession(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	sessionID := chi.URLParam(r, "id")
	tag, err := h.db.Exec(r.Context(),
		`DELETE FROM login_sessions WHERE id=$1 AND user_id=$2`, sessionID, claims.UserID)
	if err != nil || tag.RowsAffected() == 0 {
		respondError(w, http.StatusNotFound, "session_not_found")
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{UserID: claims.UserID, BusinessID: claims.BusinessID, Action: "session.revoked"})
	respondJSON(w, http.StatusOK, map[string]string{"message": "session_revoked"})
}

// ── Internal helpers ──────────────────────────────────────────────

func (h *Handler) issueTokens(ctx context.Context, user *models.User, userAgent, remoteAddr string) (access, refresh string, err error) {
	now := time.Now()
	claims := &middleware.Claims{
		UserID:     user.ID,
		BusinessID: user.BusinessID,
		Role:       user.Role,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(h.cfg.JWTAccessTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
		},
	}
	access, err = jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(h.cfg.JWTSecret))
	if err != nil {
		return
	}

	refreshToken := generateSecureToken()
	hashed := hashToken(refreshToken)
	_, err = h.db.Exec(ctx,
		`INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1,$2,$3)`,
		user.ID, hashed, now.Add(h.cfg.JWTRefreshTTL))
	if err != nil {
		return
	}

	_, _ = h.db.Exec(ctx,
		`INSERT INTO login_sessions (user_id, ip_address, user_agent, is_current)
		 VALUES ($1,$2,$3,true)
		 ON CONFLICT DO NOTHING`,
		user.ID, remoteAddr, userAgent)

	refresh = refreshToken
	return
}

func (h *Handler) storeMFAPending(ctx context.Context, userID uuid.UUID) (string, error) {
	token := generateSecureToken()
	key := "mfa_pending:" + hashToken(token)
	err := h.rdb.Set(ctx, key, userID.String(), 5*time.Minute).Err()
	if err != nil {
		return "", err
	}
	return token, nil
}

func (h *Handler) calcRiskScore(ctx context.Context, email, ip, ua string) int {
	score := 0
	var recentFails int
	_ = h.db.QueryRow(ctx,
		`SELECT COUNT(*) FROM login_attempts WHERE email=$1 AND success=false AND created_at>NOW()-INTERVAL '15 minutes'`,
		email).Scan(&recentFails)
	score += recentFails * 10

	// New IP for this user
	var knownIP bool
	_ = h.db.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM login_sessions ls JOIN users u ON u.id=ls.user_id WHERE u.email=$1 AND ls.ip_address=$2)`,
		email, ip).Scan(&knownIP)
	if !knownIP {
		score += 20
	}
	return score
}
