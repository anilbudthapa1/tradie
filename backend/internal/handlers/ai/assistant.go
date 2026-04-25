package ai

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// ── Handler ──────────────────────────────────────────────────────────────────

type Handler struct {
	cfg    *config.Config
	db     *pgxpool.Pool
	log    *zap.Logger
	client *http.Client
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger) *Handler {
	return &Handler{
		cfg: cfg,
		db:  db,
		log: log,
		client: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// ── Rate limiter (simple in-memory, per business) ─────────────────────────────

type rateLimiter struct {
	mu      sync.Mutex
	buckets map[uuid.UUID]*rateBucket
}

type rateBucket struct {
	count    int
	resetAt  time.Time
}

var limiter = &rateLimiter{
	buckets: make(map[uuid.UUID]*rateBucket),
}

func (rl *rateLimiter) allow(bizID uuid.UUID) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	b, ok := rl.buckets[bizID]
	if !ok || now.After(b.resetAt) {
		rl.buckets[bizID] = &rateBucket{count: 1, resetAt: now.Add(time.Minute)}
		return true
	}
	if b.count >= 10 {
		return false
	}
	b.count++
	return true
}

// ── Anthropic API types ───────────────────────────────────────────────────────

const (
	anthropicAPIURL = "https://api.anthropic.com/v1/messages"
	anthropicModel  = "claude-haiku-4-5-20251001"
	anthropicVersion = "2023-06-01"
	systemPrompt    = "You are a helpful assistant for Tradie Job Manager, an Australian tradie business management app. Help with job management, invoicing, scheduling, quoting, safety compliance, and business operations. Be concise and practical."
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
	Error *struct {
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

// ── callClaude makes an HTTP call to the Anthropic API ───────────────────────

func (h *Handler) callClaude(userMessage, sysPrompt string) (string, error) {
	reqBody := anthropicRequest{
		Model:     anthropicModel,
		MaxTokens: 1024,
		System:    sysPrompt,
		Messages:  []anthropicMessage{{Role: "user", Content: userMessage}},
	}
	body, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("marshal: %w", err)
	}

	req, err := http.NewRequest(http.MethodPost, anthropicAPIURL, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("new request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", h.cfg.AnthropicAPIKey)
	req.Header.Set("anthropic-version", anthropicVersion)

	resp, err := h.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("http do: %w", err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read body: %w", err)
	}

	var ar anthropicResponse
	if err := json.Unmarshal(raw, &ar); err != nil {
		return "", fmt.Errorf("unmarshal: %w", err)
	}
	if ar.Error != nil {
		return "", fmt.Errorf("anthropic error: %s", ar.Error.Message)
	}
	for _, c := range ar.Content {
		if c.Type == "text" {
			return c.Text, nil
		}
	}
	return "", fmt.Errorf("no text content in response")
}

// ── POST /api/v1/ai/chat ──────────────────────────────────────────────────────

type chatRequest struct {
	Message string `json:"message"`
	Context struct {
		Page     string `json:"page"`
		EntityID string `json:"entity_id,omitempty"`
	} `json:"context"`
}

type chatResponse struct {
	Reply       string   `json:"reply"`
	Suggestions []string `json:"suggestions,omitempty"`
}

func (h *Handler) Chat(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	if !limiter.allow(bizID) {
		respond(w, http.StatusTooManyRequests, map[string]string{"error": "rate_limit_exceeded"})
		return
	}

	var req chatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Message == "" {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}

	// Build context-aware system prompt
	sys := systemPrompt
	if req.Context.Page != "" {
		sys += fmt.Sprintf(" The user is currently on the '%s' page.", req.Context.Page)
	}

	reply, err := h.callClaude(req.Message, sys)
	if err != nil {
		h.log.Error("claude chat error", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "ai_unavailable"})
		return
	}

	suggestions := quickSuggestions(req.Context.Page)
	respond(w, http.StatusOK, chatResponse{Reply: reply, Suggestions: suggestions})
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
	bizID := middleware.BusinessIDFromCtx(r.Context())

	if !limiter.allow(bizID) {
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

	summary, err := h.callClaude(prompt, systemPrompt)
	if err != nil {
		h.log.Error("claude summarize error", zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "ai_unavailable"})
		return
	}

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

// ── Routes ────────────────────────────────────────────────────────────────────

func (h *Handler) Routes() func(r chi.Router) {
	return func(r chi.Router) {
		r.Post("/chat", h.Chat)
		r.Post("/summarize", h.Summarize)
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
