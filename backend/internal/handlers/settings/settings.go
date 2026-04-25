package settings

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
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

// NewHandler accepts an optional AuditService via variadic to keep backward
// compatibility with callers that were written before audit was added.
func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit ...*middleware.AuditService) *Handler {
	h := &Handler{cfg: cfg, db: db, log: log}
	if len(audit) > 0 {
		h.audit = audit[0]
	}
	return h
}

// ── Aggregate settings ────────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		DateFormat                string `json:"date_format"`
		Currency                  string `json:"currency"`
		Language                  string `json:"language"`
		DefaultJobDurationMinutes int    `json:"default_job_duration_minutes"`
		AutoSendReminders         bool   `json:"auto_send_reminders"`
	}
	err := h.db.QueryRow(r.Context(),
		`SELECT date_format, currency, language, default_job_duration_minutes, auto_send_reminders
		 FROM business_settings WHERE business_id=$1`, bizID,
	).Scan(&s.DateFormat, &s.Currency, &s.Language, &s.DefaultJobDurationMinutes, &s.AutoSendReminders)
	if err != nil && err != pgx.ErrNoRows {
		h.log.Error("get settings", zap.Error(err))
	}
	respond(w, 200, s)
}

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		DateFormat                *string `json:"date_format"`
		Currency                  *string `json:"currency"`
		Language                  *string `json:"language"`
		DefaultJobDurationMinutes *int    `json:"default_job_duration_minutes"`
		AutoSendReminders         *bool   `json:"auto_send_reminders"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, err := h.db.Exec(r.Context(),
		`UPDATE business_settings SET
		  date_format=COALESCE($2,date_format),
		  currency=COALESCE($3,currency),
		  language=COALESCE($4,language),
		  default_job_duration_minutes=COALESCE($5,default_job_duration_minutes),
		  auto_send_reminders=COALESCE($6,auto_send_reminders),
		  updated_at=NOW()
		 WHERE business_id=$1`,
		bizID, req.DateFormat, req.Currency, req.Language,
		req.DefaultJobDurationMinutes, req.AutoSendReminders)
	if err != nil {
		h.log.Error("update settings", zap.Error(err))
	}
	if h.audit != nil {
		claims := middleware.ClaimsFromCtx(r.Context())
		if claims != nil {
			h.audit.Log(r.Context(), middleware.AuditEntry{
				BusinessID: bizID,
				UserID:     claims.UserID,
				Action:     "update",
				EntityType: "general_settings",
				IPAddress:  r.RemoteAddr,
			})
		}
	}
	h.Get(w, r)
}

// ── Security Settings ─────────────────────────────────────────

func (h *Handler) GetSecurity(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		Require2FA        bool     `json:"require_2fa"`
		SessionTimeoutMin int      `json:"session_timeout_min"`
		AllowedIPs        []string `json:"allowed_ips"`
	}
	err := h.db.QueryRow(r.Context(),
		`SELECT require_2fa, session_timeout_min, COALESCE(allowed_ips, '{}')
		 FROM security_settings WHERE business_id=$1`, bizID,
	).Scan(&s.Require2FA, &s.SessionTimeoutMin, &s.AllowedIPs)
	if err != nil && err != pgx.ErrNoRows {
		h.log.Error("get security settings", zap.Error(err))
	}
	if s.AllowedIPs == nil {
		s.AllowedIPs = []string{}
	}
	respond(w, 200, s)
}

func (h *Handler) UpdateSecurity(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		Require2FA        *bool    `json:"require_2fa"`
		SessionTimeoutMin *int     `json:"session_timeout_min"`
		AllowedIPs        []string `json:"allowed_ips"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, err := h.db.Exec(r.Context(),
		`UPDATE security_settings SET
		  require_2fa=COALESCE($2,require_2fa),
		  session_timeout_min=COALESCE($3,session_timeout_min),
		  updated_at=NOW()
		 WHERE business_id=$1`,
		bizID, req.Require2FA, req.SessionTimeoutMin)
	if err != nil {
		h.log.Error("update security settings", zap.Error(err))
	}
	if h.audit != nil {
		claims := middleware.ClaimsFromCtx(r.Context())
		if claims != nil {
			h.audit.Log(r.Context(), middleware.AuditEntry{
				BusinessID: bizID,
				UserID:     claims.UserID,
				Action:     "update",
				EntityType: "security_settings",
				IPAddress:  r.RemoteAddr,
			})
		}
	}
	h.GetSecurity(w, r)
}

// ── Scheduling Settings ───────────────────────────────────────

func (h *Handler) GetScheduling(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		WorkDays      []int  `json:"work_days"`
		WorkStart     string `json:"work_start"`
		WorkEnd       string `json:"work_end"`
		SlotMinutes   int    `json:"slot_minutes"`
		BufferMinutes int    `json:"buffer_minutes"`
	}
	err := h.db.QueryRow(r.Context(),
		`SELECT work_days, work_start::text, work_end::text, slot_minutes, buffer_minutes
		 FROM scheduling_settings WHERE business_id=$1`, bizID,
	).Scan(&s.WorkDays, &s.WorkStart, &s.WorkEnd, &s.SlotMinutes, &s.BufferMinutes)
	if err != nil && err != pgx.ErrNoRows {
		h.log.Error("get scheduling", zap.Error(err))
	}
	if s.WorkDays == nil {
		s.WorkDays = []int{1, 2, 3, 4, 5}
	}
	respond(w, 200, s)
}

func (h *Handler) UpdateScheduling(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		WorkDays      []int   `json:"work_days"`
		WorkStart     *string `json:"work_start"`
		WorkEnd       *string `json:"work_end"`
		SlotMinutes   *int    `json:"slot_minutes"`
		BufferMinutes *int    `json:"buffer_minutes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if len(req.WorkDays) > 0 {
		_, _ = h.db.Exec(r.Context(),
			`UPDATE scheduling_settings SET work_days=$2 WHERE business_id=$1`, bizID, req.WorkDays)
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE scheduling_settings SET
		  work_start=COALESCE($2::time,work_start),
		  work_end=COALESCE($3::time,work_end),
		  slot_minutes=COALESCE($4,slot_minutes),
		  buffer_minutes=COALESCE($5,buffer_minutes),
		  updated_at=NOW()
		 WHERE business_id=$1`,
		bizID, req.WorkStart, req.WorkEnd, req.SlotMinutes, req.BufferMinutes)
	h.GetScheduling(w, r)
}

// ── Job Settings ──────────────────────────────────────────────

func (h *Handler) GetJobSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		DefaultDurationMinutes int  `json:"default_duration_minutes"`
		RequireSignOff         bool `json:"require_sign_off"`
		RequirePhotos          bool `json:"require_photos"`
		AllowWorkerNotes       bool `json:"allow_worker_notes"`
	}
	err := h.db.QueryRow(r.Context(),
		`SELECT default_duration_minutes, require_sign_off, require_photos, allow_worker_notes
		 FROM job_settings WHERE business_id=$1`, bizID,
	).Scan(&s.DefaultDurationMinutes, &s.RequireSignOff, &s.RequirePhotos, &s.AllowWorkerNotes)
	if err != nil && err != pgx.ErrNoRows {
		h.log.Error("get job settings", zap.Error(err))
	}
	respond(w, 200, s)
}

func (h *Handler) UpdateJobSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		DefaultDurationMinutes *int  `json:"default_duration_minutes"`
		RequireSignOff         *bool `json:"require_sign_off"`
		RequirePhotos          *bool `json:"require_photos"`
		AllowWorkerNotes       *bool `json:"allow_worker_notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE job_settings SET
		  default_duration_minutes=COALESCE($2,default_duration_minutes),
		  require_sign_off=COALESCE($3,require_sign_off),
		  require_photos=COALESCE($4,require_photos),
		  allow_worker_notes=COALESCE($5,allow_worker_notes),
		  updated_at=NOW()
		 WHERE business_id=$1`,
		bizID, req.DefaultDurationMinutes, req.RequireSignOff, req.RequirePhotos, req.AllowWorkerNotes)
	h.GetJobSettings(w, r)
}

// ── API Keys ──────────────────────────────────────────────────

func (h *Handler) ListAPIKeys(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(),
		`SELECT id, name, key_prefix, COALESCE(scopes, '{}'), last_used_at, created_at
		 FROM api_keys
		 WHERE business_id=$1 AND revoked_at IS NULL
		 ORDER BY created_at DESC`, bizID)
	if err != nil {
		h.log.Error("list api keys", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	keys := make([]map[string]interface{}, 0)
	for rows.Next() {
		k := make(map[string]interface{})
		var (
			id, name, prefix interface{}
			scopes           []string
			lastUsed         *time.Time
			createdAt        time.Time
		)
		if err := rows.Scan(&id, &name, &prefix, &scopes, &lastUsed, &createdAt); err != nil {
			h.log.Error("scan api key", zap.Error(err))
			continue
		}
		k["id"] = id
		k["name"] = name
		k["key_prefix"] = prefix
		k["scopes"] = scopes
		k["last_used_at"] = lastUsed
		k["created_at"] = createdAt
		keys = append(keys, k)
	}
	respond(w, 200, keys)
}

func (h *Handler) CreateAPIKey(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		Name   string   `json:"name"`
		Scopes []string `json:"scopes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		respond(w, 400, map[string]string{"error": "name_required"})
		return
	}
	if len(req.Scopes) == 0 {
		req.Scopes = []string{"read"}
	}

	rawKey := generateAPIKey()
	hashed := hashAPIKey(rawKey)
	prefix := rawKey[:8] + "..."

	var keyID string
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO api_keys (business_id, created_by, name, key_hash, key_prefix, scopes)
		 VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
		bizID, claims.UserID, req.Name, hashed, prefix, req.Scopes,
	).Scan(&keyID)
	if err != nil {
		h.log.Error("create api key", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}

	if h.audit != nil {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     "create",
			EntityType: "api_key",
			IPAddress:  r.RemoteAddr,
		})
	}

	// Return the full key ONCE — cannot be retrieved again.
	respond(w, 201, map[string]interface{}{
		"id":     keyID,
		"name":   req.Name,
		"key":    rawKey,
		"scopes": req.Scopes,
	})
}

func (h *Handler) RevokeAPIKey(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	keyID := chi.URLParam(r, "id")

	tag, err := h.db.Exec(r.Context(),
		`UPDATE api_keys SET revoked_at=NOW() WHERE id=$1 AND business_id=$2 AND revoked_at IS NULL`,
		keyID, bizID)
	if err != nil {
		h.log.Error("revoke api key", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	if h.audit != nil && claims != nil {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     "revoke",
			EntityType: "api_key",
			IPAddress:  r.RemoteAddr,
		})
	}

	respond(w, 200, map[string]string{"message": "revoked"})
}

// ── Audit Log ─────────────────────────────────────────────────
//
// GET /settings/audit-log
//   ?page=1  (default 1)
//   ?limit=50 (default 50, max 200)
//   ?action=create
//   ?entity_type=api_key

func (h *Handler) AuditLog(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()

	page, _ := strconv.Atoi(q.Get("page"))
	if page < 1 {
		page = 1
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit < 1 || limit > 200 {
		limit = 50
	}
	offset := (page - 1) * limit

	actionFilter := q.Get("action")
	entityFilter := q.Get("entity_type")

	// Build parameterised WHERE clauses.
	args := []interface{}{bizID}
	where := "al.business_id=$1"
	nextArg := 2

	if actionFilter != "" {
		where += fmt.Sprintf(" AND al.action=$%d", nextArg)
		args = append(args, actionFilter)
		nextArg++
	}
	if entityFilter != "" {
		where += fmt.Sprintf(" AND al.entity_type=$%d", nextArg)
		args = append(args, entityFilter)
		nextArg++
	}

	// Count total for pagination meta.
	var total int
	countSQL := fmt.Sprintf(`SELECT COUNT(*) FROM audit_logs al WHERE %s`, where)
	_ = h.db.QueryRow(r.Context(), countSQL, args...).Scan(&total)

	// Fetch page.
	args = append(args, limit, offset)
	dataSQL := fmt.Sprintf(`
		SELECT al.id, al.user_id, u.first_name, u.last_name,
		       al.action, al.entity_type, al.entity_id, al.ip_address, al.created_at
		FROM audit_logs al
		LEFT JOIN users u ON u.id = al.user_id
		WHERE %s
		ORDER BY al.created_at DESC
		LIMIT $%d OFFSET $%d`,
		where, nextArg, nextArg+1)

	rows, err := h.db.Query(r.Context(), dataSQL, args...)
	if err != nil {
		h.log.Error("audit log query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	logs := make([]map[string]interface{}, 0)
	for rows.Next() {
		entry := make(map[string]interface{})
		var (
			id, userID, first, last interface{}
			action, entityType      string
			entityID, ip            interface{}
			createdAt               time.Time
		)
		if err := rows.Scan(&id, &userID, &first, &last, &action, &entityType, &entityID, &ip, &createdAt); err != nil {
			h.log.Error("scan audit log", zap.Error(err))
			continue
		}
		firstName, _ := first.(string)
		lastName, _ := last.(string)
		userName := ""
		if firstName != "" || lastName != "" {
			userName = firstName + " " + lastName
		}
		entry["id"] = id
		entry["user_id"] = userID
		entry["user_name"] = userName
		entry["action"] = action
		entry["entity_type"] = entityType
		entry["entity_id"] = entityID
		entry["ip_address"] = ip
		entry["created_at"] = createdAt
		logs = append(logs, entry)
	}

	pages := int(math.Ceil(float64(total) / float64(limit)))
	respond(w, 200, map[string]interface{}{
		"data": logs,
		"meta": map[string]int{
			"total": total,
			"page":  page,
			"limit": limit,
			"pages": pages,
		},
	})
}

// ── Helpers ───────────────────────────────────────────────────

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		_ = json.NewEncoder(w).Encode(data)
	}
}

func generateAPIKey() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return "tjm_" + hex.EncodeToString(b)
}

func hashAPIKey(key string) string {
	h := sha256.New()
	h.Write([]byte(key))
	return fmt.Sprintf("%x", h.Sum(nil))
}
