package notifications

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

type Handler struct {
	cfg *config.Config
	db  *pgxpool.Pool
	rdb *redis.Client
	log *zap.Logger
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, rdb *redis.Client, log *zap.Logger) *Handler {
	return &Handler{cfg: cfg, db: db, rdb: rdb, log: log}
}

// ── Notifications list ────────────────────────────────────────────

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())

	rows, _ := h.db.Query(r.Context(),
		`SELECT id, type, title, body, data, read_at, created_at
		 FROM notifications WHERE business_id=$1 AND (user_id=$2 OR user_id IS NULL)
		 ORDER BY created_at DESC LIMIT 50`, bizID, claims.UserID)
	defer rows.Close()

	var notifs []map[string]interface{}
	for rows.Next() {
		n := make(map[string]interface{})
		var id, notifType, title, body, data, readAt, createdAt interface{}
		_ = rows.Scan(&id, &notifType, &title, &body, &data, &readAt, &createdAt)
		n["id"] = id; n["type"] = notifType; n["title"] = title
		n["body"] = body; n["data"] = data
		n["read"] = readAt != nil; n["read_at"] = readAt; n["created_at"] = createdAt
		notifs = append(notifs, n)
	}
	if notifs == nil {
		notifs = []map[string]interface{}{}
	}

	// Unread count
	var unread int
	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM notifications WHERE business_id=$1 AND (user_id=$2 OR user_id IS NULL) AND read_at IS NULL`,
		bizID, claims.UserID).Scan(&unread)

	respond(w, 200, map[string]interface{}{
		"notifications": notifs,
		"unread_count":  unread,
	})
}

func (h *Handler) MarkRead(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())
	notifID := chi.URLParam(r, "id")

	tag, _ := h.db.Exec(r.Context(),
		`UPDATE notifications SET read_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND (user_id=$3 OR user_id IS NULL) AND read_at IS NULL`,
		notifID, bizID, claims.UserID)
	if tag.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, map[string]string{"message": "marked_read"})
}

func (h *Handler) MarkAllRead(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())
	_, _ = h.db.Exec(r.Context(),
		`UPDATE notifications SET read_at=NOW()
		 WHERE business_id=$1 AND (user_id=$2 OR user_id IS NULL) AND read_at IS NULL`,
		bizID, claims.UserID)
	respond(w, 200, map[string]string{"message": "all_marked_read"})
}

// ── Notification Preferences ──────────────────────────────────────

func (h *Handler) GetPreferences(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())

	// Business-level preferences
	var bizPrefs []byte
	_ = h.db.QueryRow(r.Context(),
		`SELECT settings FROM notification_preferences WHERE business_id=$1`, bizID,
	).Scan(&bizPrefs)

	// User-level preferences
	var userPrefs struct {
		Email       bool            `json:"email"`
		SMS         bool            `json:"sms"`
		Push        bool            `json:"push"`
		InApp       bool            `json:"in_app"`
		Preferences json.RawMessage `json:"preferences"`
	}
	userPrefs.Email = true; userPrefs.SMS = true; userPrefs.Push = true; userPrefs.InApp = true
	_ = h.db.QueryRow(r.Context(),
		`SELECT email, sms, push, in_app, preferences
		 FROM user_notification_preferences WHERE user_id=$1`, claims.UserID,
	).Scan(&userPrefs.Email, &userPrefs.SMS, &userPrefs.Push, &userPrefs.InApp, &userPrefs.Preferences)

	respond(w, 200, map[string]interface{}{
		"user":     userPrefs,
		"business": json.RawMessage(bizPrefs),
	})
}

func (h *Handler) UpdatePreferences(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req struct {
		User struct {
			Email *bool            `json:"email"`
			SMS   *bool            `json:"sms"`
			Push  *bool            `json:"push"`
			InApp *bool            `json:"in_app"`
			Prefs json.RawMessage  `json:"preferences"`
		} `json:"user"`
		Business json.RawMessage `json:"business"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// Update user preferences
	_, _ = h.db.Exec(r.Context(),
		`UPDATE user_notification_preferences SET
		  email=COALESCE($2,email),
		  sms=COALESCE($3,sms),
		  push=COALESCE($4,push),
		  in_app=COALESCE($5,in_app),
		  updated_at=NOW()
		 WHERE user_id=$1`,
		claims.UserID, req.User.Email, req.User.SMS, req.User.Push, req.User.InApp)

	// Update business preferences (owner/admin only)
	if req.Business != nil {
		role := claims.Role
		if role == "owner" || role == "admin" {
			_, _ = h.db.Exec(r.Context(),
				`UPDATE notification_preferences SET settings=$2, updated_at=NOW() WHERE business_id=$1`,
				bizID, req.Business)
		}
	}

	h.GetPreferences(w, r)
}

// ── Notification Templates ────────────────────────────────────────

func (h *Handler) ListTemplates(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, _ := h.db.Query(r.Context(),
		`SELECT id, type, channel, subject, body, variables, is_default, updated_at
		 FROM notification_templates
		 WHERE business_id=$1 OR (business_id IS NULL AND is_default=true)
		 ORDER BY type, channel`, bizID)
	defer rows.Close()

	var templates []map[string]interface{}
	for rows.Next() {
		t := make(map[string]interface{})
		var id, tmplType, channel, subject, body, updatedAt interface{}
		var variables []string
		var isDefault bool
		_ = rows.Scan(&id, &tmplType, &channel, &subject, &body, &variables, &isDefault, &updatedAt)
		t["id"] = id; t["type"] = tmplType; t["channel"] = channel
		t["subject"] = subject; t["body"] = body; t["variables"] = variables
		t["is_default"] = isDefault; t["updated_at"] = updatedAt
		templates = append(templates, t)
	}
	if templates == nil {
		templates = []map[string]interface{}{}
	}
	respond(w, 200, templates)
}

func (h *Handler) UpdateTemplate(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	templateID := chi.URLParam(r, "id")

	var req struct {
		Subject *string `json:"subject"`
		Body    *string `json:"body"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// Upsert business-specific override
	_, err := h.db.Exec(r.Context(),
		`UPDATE notification_templates SET
		  subject=COALESCE($3,subject),
		  body=COALESCE($4,body),
		  updated_at=NOW()
		 WHERE id=$1 AND business_id=$2`,
		templateID, bizID, req.Subject, req.Body)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 200, map[string]string{"message": "updated"})
}

// ── Delivery Logs ─────────────────────────────────────────────────

func (h *Handler) DeliveryLogs(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, _ := h.db.Query(r.Context(),
		`SELECT id, notification_id, channel, recipient, status, provider_id, error, sent_at, created_at
		 FROM notification_delivery_logs WHERE business_id=$1
		 ORDER BY created_at DESC LIMIT 100`, bizID)
	defer rows.Close()

	var logs []map[string]interface{}
	for rows.Next() {
		l := make(map[string]interface{})
		var id, notifID, channel, recipient, status, providerID, errMsg, sentAt interface{}
		var createdAt time.Time
		_ = rows.Scan(&id, &notifID, &channel, &recipient, &status, &providerID, &errMsg, &sentAt, &createdAt)
		l["id"] = id; l["notification_id"] = notifID; l["channel"] = channel
		l["recipient"] = recipient; l["status"] = status; l["provider_id"] = providerID
		l["error"] = errMsg; l["sent_at"] = sentAt; l["created_at"] = createdAt
		logs = append(logs, l)
	}
	if logs == nil {
		logs = []map[string]interface{}{}
	}
	respond(w, 200, logs)
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
