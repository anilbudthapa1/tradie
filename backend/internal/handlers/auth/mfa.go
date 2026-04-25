package auth

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/pquerna/otp/totp"

	"github.com/tradie/api/internal/middleware"
)

// ── Enable MFA (generates secret + QR code) ───────────────────────

func (h *Handler) EnableMFA(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())

	var enabled bool
	_ = h.db.QueryRow(r.Context(), `SELECT enabled FROM mfa_secrets WHERE user_id=$1`, claims.UserID).Scan(&enabled)
	if enabled {
		respondError(w, http.StatusConflict, "mfa_already_enabled")
		return
	}

	var email string
	_ = h.db.QueryRow(r.Context(), `SELECT email FROM users WHERE id=$1`, claims.UserID).Scan(&email)

	key, err := totp.Generate(totp.GenerateOpts{
		Issuer:      "Tradie Job Manager",
		AccountName: email,
	})
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	backupCodes := generateBackupCodes(8)
	backupHashes := make([]string, len(backupCodes))
	for i, c := range backupCodes {
		backupHashes[i] = hashToken(c)
	}

	_, _ = h.db.Exec(r.Context(),
		`INSERT INTO mfa_secrets (user_id, secret, backup_codes, enabled)
		 VALUES ($1,$2,$3,false)
		 ON CONFLICT (user_id) DO UPDATE SET secret=$2, backup_codes=$3, enabled=false`,
		claims.UserID, key.Secret(), backupHashes)

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"secret":       key.Secret(),
		"qr_url":       key.URL(),
		"backup_codes": backupCodes,
	})
}

// ── Verify MFA (confirms setup — sets enabled=true) ───────────────

func (h *Handler) VerifyMFA(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Code == "" {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}

	var secret string
	var enabled bool
	err := h.db.QueryRow(r.Context(),
		`SELECT secret, enabled FROM mfa_secrets WHERE user_id=$1`, claims.UserID,
	).Scan(&secret, &enabled)
	if err != nil {
		respondError(w, http.StatusBadRequest, "mfa_not_initiated")
		return
	}
	if enabled {
		respondError(w, http.StatusConflict, "mfa_already_enabled")
		return
	}
	if !validateTOTP(secret, req.Code) {
		respondError(w, http.StatusUnauthorized, "invalid_code")
		return
	}

	_, _ = h.db.Exec(r.Context(), `UPDATE mfa_secrets SET enabled=true WHERE user_id=$1`, claims.UserID)
	h.audit.Log(r.Context(), middleware.AuditEntry{UserID: claims.UserID, BusinessID: claims.BusinessID, Action: "mfa.enabled"})
	respondJSON(w, http.StatusOK, map[string]string{"message": "mfa_enabled"})
}

// ── Disable MFA ───────────────────────────────────────────────────

func (h *Handler) DisableMFA(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Code == "" {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}

	var secret string
	err := h.db.QueryRow(r.Context(),
		`SELECT secret FROM mfa_secrets WHERE user_id=$1 AND enabled=true`, claims.UserID,
	).Scan(&secret)
	if err != nil {
		respondError(w, http.StatusBadRequest, "mfa_not_enabled")
		return
	}

	if !validateTOTP(secret, req.Code) && !h.useBackupCode(r.Context(), claims.UserID, req.Code) {
		respondError(w, http.StatusUnauthorized, "invalid_code")
		return
	}

	_, _ = h.db.Exec(r.Context(), `DELETE FROM mfa_secrets WHERE user_id=$1`, claims.UserID)
	h.audit.Log(r.Context(), middleware.AuditEntry{UserID: claims.UserID, BusinessID: claims.BusinessID, Action: "mfa.disabled"})
	respondJSON(w, http.StatusOK, map[string]string{"message": "mfa_disabled"})
}

// ── Helpers ───────────────────────────────────────────────────────

func validateTOTP(secret, code string) bool {
	return totp.Validate(code, secret)
}

func generateBackupCodes(n int) []string {
	codes := make([]string, n)
	for i := range codes {
		b := make([]byte, 5)
		rand.Read(b)
		codes[i] = strings.ToUpper(hex.EncodeToString(b))
	}
	return codes
}

func (h *Handler) useBackupCode(ctx context.Context, userID uuid.UUID, code string) bool {
	hashed := hashToken(strings.ToUpper(strings.TrimSpace(code)))
	var codes []string
	if err := h.db.QueryRow(ctx, `SELECT backup_codes FROM mfa_secrets WHERE user_id=$1`, userID).Scan(&codes); err != nil {
		return false
	}
	for i, c := range codes {
		if c == hashed {
			newCodes := append(codes[:i], codes[i+1:]...)
			_, _ = h.db.Exec(ctx, `UPDATE mfa_secrets SET backup_codes=$1 WHERE user_id=$2`, newCodes, userID)
			return true
		}
	}
	return false
}
