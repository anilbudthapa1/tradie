package integrations

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// ── Provider catalogue ────────────────────────────────────────────────────────
//
// Each accounting / calendar integration is a thin spec — auth + token URLs and
// the env vars that hold the OAuth client credentials. Endpoints + scopes come
// from each vendor's published OAuth2 docs (Xero, MYOB, Intuit, Google).
//
// All four are gated as needs-key. They will return 503 until the matching
// CLIENT_ID / CLIENT_SECRET pair is set in the environment.

type OAuthProvider struct {
	Name             string   // canonical slug used in URLs and the integration_tokens.provider column
	AuthURL          string   // authorize endpoint
	TokenURL         string   // token endpoint
	ClientIDEnv      string   // env var holding the OAuth client id
	ClientSecretEnv  string   // env var holding the OAuth client secret
	Scopes           []string // requested scopes
	UsesPKCE         bool     // whether the provider mandates PKCE (kept for future expansion)
	IncludeBasicAuth bool     // whether token exchange uses HTTP Basic auth (Xero, MYOB)
}

var oauthProviders = map[string]OAuthProvider{
	"xero": {
		Name:             "xero",
		AuthURL:          "https://login.xero.com/identity/connect/authorize",
		TokenURL:         "https://identity.xero.com/connect/token",
		ClientIDEnv:      "XERO_CLIENT_ID",
		ClientSecretEnv:  "XERO_CLIENT_SECRET",
		Scopes:           []string{"openid", "profile", "email", "offline_access", "accounting.transactions", "accounting.contacts", "accounting.reports.read"},
		IncludeBasicAuth: true,
	},
	"myob": {
		Name:             "myob",
		AuthURL:          "https://secure.myob.com/oauth2/account/authorize",
		TokenURL:         "https://secure.myob.com/oauth2/v1/authorize",
		ClientIDEnv:      "MYOB_CLIENT_ID",
		ClientSecretEnv:  "MYOB_CLIENT_SECRET",
		Scopes:           []string{"CompanyFile", "offline_access"},
		IncludeBasicAuth: true,
	},
	"quickbooks": {
		Name:            "quickbooks",
		AuthURL:         "https://appcenter.intuit.com/connect/oauth2",
		TokenURL:        "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer",
		ClientIDEnv:     "QUICKBOOKS_CLIENT_ID",
		ClientSecretEnv: "QUICKBOOKS_CLIENT_SECRET",
		Scopes:          []string{"com.intuit.quickbooks.accounting", "openid", "profile", "email"},
		UsesPKCE:        true,
	},
	"google_calendar": {
		Name:            "google_calendar",
		AuthURL:         "https://accounts.google.com/o/oauth2/v2/auth",
		TokenURL:        "https://oauth2.googleapis.com/token",
		ClientIDEnv:     "GOOGLE_CALENDAR_CLIENT_ID",
		ClientSecretEnv: "GOOGLE_CALENDAR_CLIENT_SECRET",
		Scopes:          []string{"https://www.googleapis.com/auth/calendar", "https://www.googleapis.com/auth/calendar.events"},
	},
}

// ── Handler ───────────────────────────────────────────────────────────────────

// OAuthHandler exposes connect / callback / disconnect routes for every OAuth
// integration. Routes are wired in router.go (admin+ guard) and audited.
type OAuthHandler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewOAuthHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *OAuthHandler {
	return &OAuthHandler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── GET /api/v1/integrations/{provider}/connect ──────────────────────────────
//
// Returns { "url": "<authorize URL>" } for the caller's browser to redirect to.
// A short-lived state token is stored server-side for CSRF / replay protection.

func (h *OAuthHandler) Connect(w http.ResponseWriter, r *http.Request) {
	providerSlug := chi.URLParam(r, "provider")
	provider, ok := oauthProviders[providerSlug]
	if !ok {
		oauthRespond(w, http.StatusNotFound, map[string]string{"error": "unknown_provider"})
		return
	}

	clientID := os.Getenv(provider.ClientIDEnv)
	clientSecret := os.Getenv(provider.ClientSecretEnv)
	if clientID == "" || clientSecret == "" {
		oauthRespond(w, http.StatusServiceUnavailable, map[string]string{
			"error":    "integration_not_configured",
			"provider": providerSlug,
			"hint":     fmt.Sprintf("set %s and %s in the backend environment", provider.ClientIDEnv, provider.ClientSecretEnv),
		})
		return
	}

	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		oauthRespond(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	state, err := randomState()
	if err != nil {
		h.log.Error("oauth state generation failed", zap.Error(err))
		oauthRespond(w, http.StatusInternalServerError, map[string]string{"error": "state_failed"})
		return
	}

	redirectURI := fmt.Sprintf("%s/api/v1/integrations/%s/callback", h.cfg.BaseURL, providerSlug)

	if _, err := h.db.Exec(r.Context(),
		`INSERT INTO oauth_state (state, business_id, user_id, provider, redirect_uri)
		 VALUES ($1, $2, $3, $4, $5)`,
		state, bizID, claims.UserID, providerSlug, redirectURI,
	); err != nil {
		h.log.Error("oauth state persist failed", zap.Error(err))
		oauthRespond(w, http.StatusInternalServerError, map[string]string{"error": "state_persist_failed"})
		return
	}

	q := url.Values{}
	q.Set("response_type", "code")
	q.Set("client_id", clientID)
	q.Set("redirect_uri", redirectURI)
	q.Set("scope", strings.Join(provider.Scopes, " "))
	q.Set("state", state)
	if providerSlug == "google_calendar" {
		q.Set("access_type", "offline")
		q.Set("prompt", "consent")
	}

	authorizeURL := provider.AuthURL + "?" + q.Encode()

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "integration.oauth_connect_started",
		EntityType: "integration",
		IPAddress:  r.RemoteAddr,
		NewData:    map[string]string{"provider": providerSlug},
	})

	oauthRespond(w, http.StatusOK, map[string]string{
		"url":      authorizeURL,
		"provider": providerSlug,
		"state":    state,
	})
}

// ── GET /api/v1/integrations/{provider}/callback ─────────────────────────────
//
// The provider redirects the browser back here with `code` and `state`. We
// verify state, exchange the code for a token, and persist into integration_tokens.

func (h *OAuthHandler) Callback(w http.ResponseWriter, r *http.Request) {
	providerSlug := chi.URLParam(r, "provider")
	provider, ok := oauthProviders[providerSlug]
	if !ok {
		oauthRespond(w, http.StatusNotFound, map[string]string{"error": "unknown_provider"})
		return
	}

	if errParam := r.URL.Query().Get("error"); errParam != "" {
		oauthRespond(w, http.StatusBadRequest, map[string]string{"error": errParam, "provider": providerSlug})
		return
	}

	code := r.URL.Query().Get("code")
	state := r.URL.Query().Get("state")
	if code == "" || state == "" {
		oauthRespond(w, http.StatusBadRequest, map[string]string{"error": "missing_code_or_state"})
		return
	}

	// Verify state and pull out the originating business / user / redirect.
	var (
		bizID       string
		userID      string
		savedProv   string
		redirectURI string
		expiresAt   time.Time
	)
	row := h.db.QueryRow(r.Context(),
		`DELETE FROM oauth_state
		 WHERE state = $1
		 RETURNING business_id::text, user_id::text, provider, redirect_uri, expires_at`,
		state,
	)
	if err := row.Scan(&bizID, &userID, &savedProv, &redirectURI, &expiresAt); err != nil {
		oauthRespond(w, http.StatusBadRequest, map[string]string{"error": "invalid_state"})
		return
	}
	if savedProv != providerSlug {
		oauthRespond(w, http.StatusBadRequest, map[string]string{"error": "state_provider_mismatch"})
		return
	}
	if time.Now().After(expiresAt) {
		oauthRespond(w, http.StatusBadRequest, map[string]string{"error": "state_expired"})
		return
	}

	clientID := os.Getenv(provider.ClientIDEnv)
	clientSecret := os.Getenv(provider.ClientSecretEnv)
	if clientID == "" || clientSecret == "" {
		oauthRespond(w, http.StatusServiceUnavailable, map[string]string{"error": "integration_not_configured"})
		return
	}

	tok, err := h.exchangeCode(r.Context(), provider, clientID, clientSecret, code, redirectURI)
	if err != nil {
		h.log.Error("oauth token exchange failed",
			zap.String("provider", providerSlug), zap.Error(err))
		oauthRespond(w, http.StatusBadGateway, map[string]string{"error": "token_exchange_failed"})
		return
	}

	var expiry *time.Time
	if tok.ExpiresIn > 0 {
		t := time.Now().Add(time.Duration(tok.ExpiresIn) * time.Second)
		expiry = &t
	}

	if _, err := h.db.Exec(r.Context(),
		`INSERT INTO integration_tokens (business_id, provider, access_token, refresh_token, token_expiry, metadata)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 ON CONFLICT (business_id, provider) DO UPDATE
		   SET access_token  = EXCLUDED.access_token,
		       refresh_token = COALESCE(NULLIF(EXCLUDED.refresh_token, ''), integration_tokens.refresh_token),
		       token_expiry  = EXCLUDED.token_expiry,
		       metadata      = EXCLUDED.metadata,
		       updated_at    = NOW()`,
		bizID, providerSlug, tok.AccessToken, tok.RefreshToken, expiry,
		map[string]interface{}{"token_type": tok.TokenType, "scope": tok.Scope},
	); err != nil {
		h.log.Error("integration_tokens upsert failed", zap.Error(err))
		oauthRespond(w, http.StatusInternalServerError, map[string]string{"error": "token_persist_failed"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: parseUUIDOrNil(bizID),
		UserID:     parseUUIDOrNil(userID),
		Action:     "integration.connected",
		EntityType: "integration",
		IPAddress:  r.RemoteAddr,
		NewData:    map[string]string{"provider": providerSlug},
	})

	// Friendly redirect target — frontend can read ?integration=xero&status=connected.
	dest := fmt.Sprintf("%s/settings/integrations?integration=%s&status=connected", h.cfg.FrontendURL, providerSlug)
	http.Redirect(w, r, dest, http.StatusFound)
}

// ── DELETE /api/v1/integrations/{provider} ───────────────────────────────────

func (h *OAuthHandler) Disconnect(w http.ResponseWriter, r *http.Request) {
	providerSlug := chi.URLParam(r, "provider")
	if _, ok := oauthProviders[providerSlug]; !ok {
		oauthRespond(w, http.StatusNotFound, map[string]string{"error": "unknown_provider"})
		return
	}

	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	tag, err := h.db.Exec(r.Context(),
		`DELETE FROM integration_tokens WHERE business_id = $1 AND provider = $2`,
		bizID, providerSlug,
	)
	if err != nil {
		oauthRespond(w, http.StatusInternalServerError, map[string]string{"error": "delete_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		oauthRespond(w, http.StatusNotFound, map[string]string{"error": "not_connected"})
		return
	}

	if claims != nil {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     "integration.disconnected",
			EntityType: "integration",
			IPAddress:  r.RemoteAddr,
			OldData:    map[string]string{"provider": providerSlug},
		})
	}

	oauthRespond(w, http.StatusOK, map[string]string{"status": "disconnected", "provider": providerSlug})
}

// ── GET /api/v1/integrations/status ──────────────────────────────────────────
//
// Returns connection state for every supported OAuth provider for the caller's
// business. Used by the mobile integrations screen.

func (h *OAuthHandler) Status(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	rows, err := h.db.Query(r.Context(),
		`SELECT provider, token_expiry, updated_at
		 FROM integration_tokens
		 WHERE business_id = $1`,
		bizID,
	)
	if err != nil {
		oauthRespond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	connected := map[string]map[string]interface{}{}
	for rows.Next() {
		var (
			prov      string
			expiry    *time.Time
			updatedAt time.Time
		)
		if err := rows.Scan(&prov, &expiry, &updatedAt); err != nil {
			continue
		}
		connected[prov] = map[string]interface{}{
			"connected":    true,
			"token_expiry": expiry,
			"updated_at":   updatedAt,
		}
	}

	out := map[string]interface{}{}
	for slug, p := range oauthProviders {
		entry, ok := connected[slug]
		configured := os.Getenv(p.ClientIDEnv) != "" && os.Getenv(p.ClientSecretEnv) != ""
		if !ok {
			out[slug] = map[string]interface{}{"connected": false, "configured": configured}
			continue
		}
		entry["configured"] = configured
		out[slug] = entry
	}

	oauthRespond(w, http.StatusOK, map[string]interface{}{"providers": out})
}

// ── helpers ───────────────────────────────────────────────────────────────────

type oauthTokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	Scope        string `json:"scope"`
}

func (h *OAuthHandler) exchangeCode(ctx context.Context, p OAuthProvider, clientID, clientSecret, code, redirectURI string) (*oauthTokenResponse, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("redirect_uri", redirectURI)

	if !p.IncludeBasicAuth {
		form.Set("client_id", clientID)
		form.Set("client_secret", clientSecret)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	if p.IncludeBasicAuth {
		req.SetBasicAuth(clientID, clientSecret)
	}

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("token endpoint %d: %s", resp.StatusCode, string(body))
	}

	var tok oauthTokenResponse
	if err := json.Unmarshal(body, &tok); err != nil {
		return nil, fmt.Errorf("decode token: %w", err)
	}
	if tok.AccessToken == "" {
		return nil, fmt.Errorf("empty access_token in response")
	}
	return &tok, nil
}

func randomState() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func parseUUIDOrNil(s string) uuid.UUID {
	id, err := uuid.Parse(s)
	if err != nil {
		return uuid.Nil
	}
	return id
}

func oauthRespond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		_ = json.NewEncoder(w).Encode(data)
	}
}
