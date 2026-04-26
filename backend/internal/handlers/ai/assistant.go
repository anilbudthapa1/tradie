package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// ── Handler ──────────────────────────────────────────────────────────────────

type Handler struct {
	cfg    *config.Config
	db     *pgxpool.Pool
	log    *zap.Logger
	rdb    *redis.Client
	audit  *middleware.AuditService
	client *http.Client
}

// NewHandler keeps a backwards-compatible signature with the existing router.
// Optional trailing args may include *redis.Client and *middleware.AuditService.
// Anything not supplied is initialized from cfg/db (Redis built from cfg.RedisURL).
func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, opts ...interface{}) *Handler {
	h := &Handler{
		cfg: cfg,
		db:  db,
		log: log,
		client: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
	for _, o := range opts {
		switch v := o.(type) {
		case *redis.Client:
			h.rdb = v
		case *middleware.AuditService:
			h.audit = v
		}
	}
	if h.rdb == nil && cfg.RedisURL != "" {
		if opt, err := redis.ParseURL(cfg.RedisURL); err == nil {
			h.rdb = redis.NewClient(opt)
		} else {
			log.Warn("ai: redis url parse failed, rate limiting will fail-open", zap.Error(err))
		}
	}
	if h.audit == nil {
		h.audit = middleware.NewAuditService(db, log)
	}
	return h
}

// ── Redis-backed rate limiter (per user, per minute) ────────────────────────

const (
	rateLimitPerMinute = 20
	rateLimitWindow    = time.Minute
)

// allow returns true if the user is under the per-minute prompt budget.
// Fails open when redis is unavailable so the AI assistant remains usable.
func (h *Handler) allow(ctx context.Context, userID uuid.UUID) bool {
	if h.rdb == nil {
		return true
	}
	minute := time.Now().UTC().Unix() / 60
	key := fmt.Sprintf("ai:rate:%s:%d", userID.String(), minute)
	count, err := h.rdb.Incr(ctx, key).Result()
	if err != nil {
		h.log.Warn("ai rate limiter incr failed (fail-open)", zap.Error(err))
		return true
	}
	if count == 1 {
		_ = h.rdb.Expire(ctx, key, rateLimitWindow+10*time.Second).Err()
	}
	return count <= int64(rateLimitPerMinute)
}

// ── Prompt sanitization (basic prompt-injection defense) ────────────────────

const (
	maxPromptLen = 8000
	// number of prior turns from same conversation_id that we re-send to the model
	contextHistoryLimit = 10
)

var promptInjectionPatterns = []string{
	"<<system>>",
	"ignore previous instructions",
	"ignore all previous instructions",
	"ignore the above",
	"disregard previous instructions",
}

type sanitizedPrompt struct {
	Text   string
	Reason string
}

func sanitizePrompt(raw string) (string, *sanitizedPrompt) {
	// strip null bytes
	cleaned := strings.ReplaceAll(raw, "\x00", "")
	cleaned = strings.TrimSpace(cleaned)

	if cleaned == "" {
		return "", &sanitizedPrompt{Reason: "empty"}
	}
	if len(cleaned) > maxPromptLen {
		return "", &sanitizedPrompt{Reason: "too_long"}
	}
	lower := strings.ToLower(cleaned)
	for _, p := range promptInjectionPatterns {
		if strings.Contains(lower, p) {
			return "", &sanitizedPrompt{Reason: "prompt_injection_attempt"}
		}
	}
	return cleaned, nil
}

// ── Anthropic API types ───────────────────────────────────────────────────────

const (
	anthropicAPIURL  = "https://api.anthropic.com/v1/messages"
	anthropicModel   = "claude-haiku-4-5-20251001"
	anthropicVersion = "2023-06-01"
	systemPrompt     = "You are a helpful assistant for Tradie Job Manager, an Australian tradie business management app. Help with job management, invoicing, scheduling, quoting, safety compliance, and business operations. Be concise and practical."
)

type anthropicRequest struct {
	Model     string             `json:"model"`
	MaxTokens int                `json:"max_tokens"`
	System    string             `json:"system"`
	Messages  []anthropicMessage `json:"messages"`
}

type anthropicMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type anthropicResponse struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	Usage *struct {
		InputTokens  int `json:"input_tokens"`
		OutputTokens int `json:"output_tokens"`
	} `json:"usage,omitempty"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

// callClaudeMessages sends an arbitrary message list (so we can include
// prior conversation turns as context).
func (h *Handler) callClaudeMessages(messages []anthropicMessage, sysPrompt string) (string, int, error) {
	if h.cfg.AnthropicAPIKey == "" {
		return "", 0, fmt.Errorf("ANTHROPIC_API_KEY not configured")
	}
	reqBody := anthropicRequest{
		Model:     anthropicModel,
		MaxTokens: 1024,
		System:    sysPrompt,
		Messages:  messages,
	}
	body, err := json.Marshal(reqBody)
	if err != nil {
		return "", 0, fmt.Errorf("marshal: %w", err)
	}

	req, err := http.NewRequest(http.MethodPost, anthropicAPIURL, bytes.NewReader(body))
	if err != nil {
		return "", 0, fmt.Errorf("new request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", h.cfg.AnthropicAPIKey)
	req.Header.Set("anthropic-version", anthropicVersion)

	resp, err := h.client.Do(req)
	if err != nil {
		return "", 0, fmt.Errorf("http do: %w", err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", 0, fmt.Errorf("read body: %w", err)
	}

	var ar anthropicResponse
	if err := json.Unmarshal(raw, &ar); err != nil {
		return "", 0, fmt.Errorf("unmarshal: %w", err)
	}
	if ar.Error != nil {
		return "", 0, fmt.Errorf("anthropic error: %s", ar.Error.Message)
	}
	tokens := 0
	if ar.Usage != nil {
		tokens = ar.Usage.InputTokens + ar.Usage.OutputTokens
	}
	for _, c := range ar.Content {
		if c.Type == "text" {
			return c.Text, tokens, nil
		}
	}
	return "", tokens, fmt.Errorf("no text content in response")
}

// ── Conversation persistence ────────────────────────────────────────────────

func (h *Handler) loadHistory(ctx context.Context, bizID, conversationID uuid.UUID) []anthropicMessage {
	rows, err := h.db.Query(ctx,
		`SELECT role, content FROM ai_conversation_logs
		 WHERE business_id=$1 AND conversation_id=$2
		 ORDER BY created_at DESC LIMIT $3`,
		bizID, conversationID, contextHistoryLimit,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var reversed []anthropicMessage
	for rows.Next() {
		var role, content string
		if err := rows.Scan(&role, &content); err != nil {
			continue
		}
		reversed = append(reversed, anthropicMessage{Role: role, Content: content})
	}
	// reverse to chronological
	out := make([]anthropicMessage, len(reversed))
	for i, m := range reversed {
		out[len(reversed)-1-i] = m
	}
	return out
}

func (h *Handler) persistTurn(ctx context.Context, bizID, userID, conversationID uuid.UUID, role, content, model string, tokens int) {
	_, err := h.db.Exec(ctx,
		`INSERT INTO ai_conversation_logs
		   (business_id, user_id, conversation_id, role, content, tokens_used, model)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		bizID, userID, conversationID, role, content, tokens, model,
	)
	if err != nil {
		h.log.Warn("ai conversation log insert failed", zap.Error(err))
	}
}

// ── POST /api/v1/ai/chat ──────────────────────────────────────────────────────

type chatRequest struct {
	Message        string `json:"message"`
	ConversationID string `json:"conversation_id,omitempty"`
	Context        struct {
		Page     string `json:"page"`
		EntityID string `json:"entity_id,omitempty"`
	} `json:"context"`
}

type chatResponse struct {
	Reply          string   `json:"reply"`
	ConversationID string   `json:"conversation_id"`
	Suggestions    []string `json:"suggestions,omitempty"`
}

func (h *Handler) Chat(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respond(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	if !h.allow(ctx, claims.UserID) {
		respond(w, http.StatusTooManyRequests, map[string]string{"error": "rate_limit_exceeded"})
		return
	}

	var req chatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	// Conversation ID: from body or query (?conversation_id=...). New if none.
	convStr := req.ConversationID
	if convStr == "" {
		convStr = r.URL.Query().Get("conversation_id")
	}
	var convID uuid.UUID
	if convStr != "" {
		parsed, err := uuid.Parse(convStr)
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_conversation_id"})
			return
		}
		convID = parsed
	} else {
		convID = uuid.New()
	}

	cleaned, bad := sanitizePrompt(req.Message)
	if bad != nil {
		respond(w, http.StatusBadRequest, map[string]string{
			"error":  "invalid_prompt",
			"reason": bad.Reason,
		})
		return
	}

	// Build context-aware system prompt
	sys := systemPrompt
	if req.Context.Page != "" {
		// page tag is allow-listed to alphanum/underscore to avoid prompt smuggling
		page := safePageTag(req.Context.Page)
		if page != "" {
			sys += fmt.Sprintf(" The user is currently on the '%s' page.", page)
		}
	}

	// Persist the user turn first so it's logged even if the API call fails.
	h.persistTurn(ctx, bizID, claims.UserID, convID, "user", cleaned, anthropicModel, 0)

	// Load prior turns (now includes the just-inserted one at the end).
	history := h.loadHistory(ctx, bizID, convID)
	if len(history) == 0 {
		history = []anthropicMessage{{Role: "user", Content: cleaned}}
	}

	reply, tokens, err := h.callClaudeMessages(history, sys)
	if err != nil {
		h.log.Error("claude chat error", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "ai_unavailable"})
		return
	}

	// Persist assistant reply.
	h.persistTurn(ctx, bizID, claims.UserID, convID, "assistant", reply, anthropicModel, tokens)

	// Audit (no full content — that lives in conversation_logs).
	h.audit.Log(ctx, middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "AI_PROMPT",
		EntityType: "ai_conversation",
		EntityID:   convID,
		NewData: map[string]interface{}{
			"prompt_length": len(cleaned),
			"model":         anthropicModel,
			"tokens_used":   tokens,
		},
		IPAddress: r.RemoteAddr,
	})

	suggestions := quickSuggestions(req.Context.Page)
	respond(w, http.StatusOK, chatResponse{
		Reply:          reply,
		ConversationID: convID.String(),
		Suggestions:    suggestions,
	})
}

func safePageTag(page string) string {
	var b strings.Builder
	for i, r := range page {
		if i >= 32 {
			break
		}
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '_' || r == '-':
			b.WriteRune(r)
		}
	}
	return b.String()
}

func quickSuggestions(page string) []string {
	switch page {
	case "jobs":
		return []string{"Summarize today's jobs", "Check overdue jobs", "Safety checklist tips"}
	case "invoices":
		return []string{"Draft invoice reminder", "Check overdue invoices", "Payment terms advice"}
	case "quotes":
		return []string{"Quote follow-up tips", "Pricing advice", "Convert quote to invoice"}
	default:
		return []string{"Summarize today's jobs", "Draft invoice reminder", "Check overdue invoices", "Safety checklist tips"}
	}
}

// ── POST /api/v1/ai/summarize ─────────────────────────────────────────────────

type summarizeRequest struct {
	EntityType string `json:"entity_type"` // "job" | "invoice"
	EntityID   string `json:"entity_id"`
}

type summarizeResponse struct {
	Summary string `json:"summary"`
}

func (h *Handler) Summarize(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respond(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	if !h.allow(ctx, claims.UserID) {
		respond(w, http.StatusTooManyRequests, map[string]string{"error": "rate_limit_exceeded"})
		return
	}

	var req summarizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if req.EntityType != "job" && req.EntityType != "invoice" {
		respond(w, http.StatusBadRequest, map[string]string{"error": "entity_type must be job or invoice"})
		return
	}
	if req.EntityID == "" {
		respond(w, http.StatusBadRequest, map[string]string{"error": "entity_id required"})
		return
	}

	entityJSON, err := h.fetchEntityJSON(r, bizID, req.EntityType, req.EntityID)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "entity_not_found"})
		return
	}

	prompt := fmt.Sprintf(
		"Summarize the following %s in 2-3 sentences. Be practical and highlight any important details for an Australian tradie business.\n\n%s",
		req.EntityType, entityJSON,
	)
	cleaned, bad := sanitizePrompt(prompt)
	if bad != nil {
		// summarizer prompt is internal — only "too_long" is realistically possible.
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_prompt", "reason": bad.Reason})
		return
	}

	summary, tokens, err := h.callClaudeMessages(
		[]anthropicMessage{{Role: "user", Content: cleaned}},
		systemPrompt,
	)
	if err != nil {
		h.log.Error("claude summarize error", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "ai_unavailable"})
		return
	}

	h.audit.Log(ctx, middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "AI_SUMMARIZE",
		EntityType: req.EntityType,
		NewData: map[string]interface{}{
			"prompt_length": len(cleaned),
			"model":         anthropicModel,
			"tokens_used":   tokens,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusOK, summarizeResponse{Summary: summary})
}

func (h *Handler) fetchEntityJSON(r *http.Request, bizID uuid.UUID, entityType, entityID string) (string, error) {
	var raw map[string]interface{}
	var err error

	switch entityType {
	case "job":
		err = h.db.QueryRow(r.Context(),
			`SELECT row_to_json(j) FROM (
				SELECT id, job_number, title, description, status, priority,
				       scheduled_start, scheduled_end, address, notes, created_at
				FROM jobs WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
			) j`,
			entityID, bizID,
		).Scan(&raw)
	case "invoice":
		err = h.db.QueryRow(r.Context(),
			`SELECT row_to_json(i) FROM (
				SELECT id, invoice_number, status, subtotal, tax_amount, total,
				       due_date, notes, created_at
				FROM invoices WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
			) i`,
			entityID, bizID,
		).Scan(&raw)
	}
	if err != nil {
		return "", err
	}
	b, _ := json.Marshal(raw)
	return string(b), nil
}

// ── GET /api/v1/ai/conversations/{id} — recent turns for a conversation ────

func (h *Handler) GetConversation(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respond(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}
	convStr := chi.URLParam(r, "id")
	convID, err := uuid.Parse(convStr)
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_conversation_id"})
		return
	}

	rows, err := h.db.Query(ctx,
		`SELECT role, content, tokens_used, model, created_at
		 FROM ai_conversation_logs
		 WHERE business_id=$1 AND conversation_id=$2 AND user_id=$3
		 ORDER BY created_at ASC LIMIT 200`,
		bizID, convID, claims.UserID,
	)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	type turn struct {
		Role       string    `json:"role"`
		Content    string    `json:"content"`
		TokensUsed int       `json:"tokens_used"`
		Model      string    `json:"model"`
		CreatedAt  time.Time `json:"created_at"`
	}
	turns := []turn{}
	for rows.Next() {
		var t turn
		var model *string
		if err := rows.Scan(&t.Role, &t.Content, &t.TokensUsed, &model, &t.CreatedAt); err != nil {
			continue
		}
		if model != nil {
			t.Model = *model
		}
		turns = append(turns, t)
	}
	respond(w, http.StatusOK, map[string]interface{}{
		"conversation_id": convID,
		"turns":           turns,
	})
}

// ── Routes ────────────────────────────────────────────────────────────────────

func (h *Handler) Routes() func(r chi.Router) {
	return func(r chi.Router) {
		r.Post("/chat", h.Chat)
		r.Post("/summarize", h.Summarize)
		r.Get("/conversations/{id}", h.GetConversation)
	}
}

// ── respond helper ────────────────────────────────────────────────────────────

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		_ = json.NewEncoder(w).Encode(data)
	}
}
