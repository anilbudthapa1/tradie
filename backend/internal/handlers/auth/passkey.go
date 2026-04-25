package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/middleware"
	"github.com/tradie/api/internal/models"
)

// webAuthnUser implements webauthn.User.
type webAuthnUser struct {
	id          uuid.UUID
	name        string
	displayName string
	credentials []webauthn.Credential
}

func (u *webAuthnUser) WebAuthnID() []byte                         { return u.id[:] }
func (u *webAuthnUser) WebAuthnName() string                       { return u.name }
func (u *webAuthnUser) WebAuthnDisplayName() string                { return u.displayName }
func (u *webAuthnUser) WebAuthnIcon() string                       { return "" }
func (u *webAuthnUser) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

// ── Begin Passkey Registration (authenticated) ────────────────────

func (h *Handler) BeginPasskeyRegister(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())

	waUser, err := h.buildWebAuthnUser(r.Context(), claims.UserID)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	options, session, err := h.webauthn.BeginRegistration(waUser,
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
			ResidentKey:      protocol.ResidentKeyRequirementPreferred,
			UserVerification: protocol.VerificationPreferred,
		}),
	)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "webauthn_error")
		return
	}

	sessionJSON, _ := json.Marshal(session)
	h.rdb.Set(r.Context(), "webauthn_reg:"+claims.UserID.String(), sessionJSON, 5*time.Minute)
	respondJSON(w, http.StatusOK, options)
}

// ── Finish Passkey Registration (authenticated) ───────────────────

func (h *Handler) FinishPasskeyRegister(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())

	sessionJSON, err := h.rdb.Get(r.Context(), "webauthn_reg:"+claims.UserID.String()).Bytes()
	if err != nil {
		respondError(w, http.StatusBadRequest, "session_expired")
		return
	}
	var session webauthn.SessionData
	json.Unmarshal(sessionJSON, &session)

	waUser, err := h.buildWebAuthnUser(r.Context(), claims.UserID)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	credential, err := h.webauthn.FinishRegistration(waUser, session, r)
	if err != nil {
		h.log.Warn("passkey registration failed", zap.Error(err))
		respondError(w, http.StatusBadRequest, "registration_failed")
		return
	}

	h.rdb.Del(r.Context(), "webauthn_reg:"+claims.UserID.String())

	credJSON, _ := json.Marshal(credential)
	_, err = h.db.Exec(r.Context(),
		`INSERT INTO passkeys (user_id, credential_id, public_key, aaguid, sign_count, name)
		 VALUES ($1,$2,$3,$4,$5,'My Passkey')`,
		claims.UserID, credential.ID, credJSON,
		credential.Authenticator.AAGUID, credential.Authenticator.SignCount)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{UserID: claims.UserID, BusinessID: claims.BusinessID, Action: "passkey.registered"})
	respondJSON(w, http.StatusOK, map[string]string{"message": "passkey_registered"})
}

// ── Begin Passkey Authentication (public) ─────────────────────────

func (h *Handler) BeginPasskeyAuth(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)

	var user models.User
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, email, first_name, last_name, role FROM users
		 WHERE email=$1 AND deleted_at IS NULL AND is_active=true`, req.Email,
	).Scan(&user.ID, &user.BusinessID, &user.Email, &user.FirstName, &user.LastName, &user.Role)
	if err != nil {
		// Use discoverable login to not reveal user existence
		options, session, err2 := h.webauthn.BeginDiscoverableLogin()
		if err2 != nil {
			respondError(w, http.StatusInternalServerError, "server_error")
			return
		}
		sessionJSON, _ := json.Marshal(session)
		h.rdb.Set(r.Context(), "webauthn_disc:anon", sessionJSON, 5*time.Minute)
		respondJSON(w, http.StatusOK, options)
		return
	}

	waUser, err := h.buildWebAuthnUserFull(r.Context(), user.ID, user.Email, user.FullName())
	if err != nil || len(waUser.credentials) == 0 {
		respondError(w, http.StatusBadRequest, "no_passkeys_registered")
		return
	}

	options, session, err := h.webauthn.BeginLogin(waUser)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "webauthn_error")
		return
	}

	sessionJSON, _ := json.Marshal(session)
	h.rdb.Set(r.Context(), "webauthn_auth:"+user.ID.String(), sessionJSON, 5*time.Minute)

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"options": options,
		"user_id": user.ID,
	})
}

// ── Finish Passkey Authentication (public) ────────────────────────

func (h *Handler) FinishPasskeyAuth(w http.ResponseWriter, r *http.Request) {
	userIDStr := r.URL.Query().Get("user_id")
	if userIDStr == "" {
		respondError(w, http.StatusBadRequest, "user_id_required")
		return
	}
	userID, err := uuid.Parse(userIDStr)
	if err != nil {
		respondError(w, http.StatusBadRequest, "invalid_user_id")
		return
	}

	sessionJSON, err := h.rdb.Get(r.Context(), "webauthn_auth:"+userID.String()).Bytes()
	if err != nil {
		respondError(w, http.StatusBadRequest, "session_expired")
		return
	}
	var session webauthn.SessionData
	json.Unmarshal(sessionJSON, &session)

	var user models.User
	_ = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, email, first_name, last_name, role FROM users WHERE id=$1`, userID,
	).Scan(&user.ID, &user.BusinessID, &user.Email, &user.FirstName, &user.LastName, &user.Role)

	waUser, err := h.buildWebAuthnUserFull(r.Context(), userID, user.Email, user.FullName())
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	credential, err := h.webauthn.FinishLogin(waUser, session, r)
	if err != nil {
		h.log.Warn("passkey auth failed", zap.Error(err))
		respondError(w, http.StatusUnauthorized, "authentication_failed")
		return
	}

	h.rdb.Del(r.Context(), "webauthn_auth:"+userID.String())
	_, _ = h.db.Exec(r.Context(),
		`UPDATE passkeys SET sign_count=$1, last_used_at=NOW() WHERE credential_id=$2`,
		credential.Authenticator.SignCount, credential.ID)

	access, refresh, err := h.issueTokens(r.Context(), &user, r.UserAgent(), r.RemoteAddr)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"access_token":  access,
		"refresh_token": refresh,
		"user":          user,
	})
}

// ── Internal ──────────────────────────────────────────────────────

func (h *Handler) buildWebAuthnUser(ctx context.Context, userID uuid.UUID) (*webAuthnUser, error) {
	var email, firstName, lastName string
	if err := h.db.QueryRow(ctx,
		`SELECT email, first_name, last_name FROM users WHERE id=$1`, userID,
	).Scan(&email, &firstName, &lastName); err != nil {
		return nil, err
	}
	return h.buildWebAuthnUserFull(ctx, userID, email, firstName+" "+lastName)
}

func (h *Handler) buildWebAuthnUserFull(ctx context.Context, userID uuid.UUID, email, displayName string) (*webAuthnUser, error) {
	rows, err := h.db.Query(ctx, `SELECT public_key FROM passkeys WHERE user_id=$1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var credentials []webauthn.Credential
	for rows.Next() {
		var credJSON []byte
		if err := rows.Scan(&credJSON); err != nil {
			continue
		}
		var cred webauthn.Credential
		if json.Unmarshal(credJSON, &cred) == nil {
			credentials = append(credentials, cred)
		}
	}

	return &webAuthnUser{
		id:          userID,
		name:        email,
		displayName: displayName,
		credentials: credentials,
	}, nil
}
