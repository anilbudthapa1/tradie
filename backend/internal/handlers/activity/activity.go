package activity

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// Handler serves the cross-tenant Activity Feed (Module 14).
//
// It reads from the existing `audit_logs` table and joins users so the
// feed can be rendered with author names directly. Access is gated by
// RequireAtLeast("manager") at the route level — the feed exposes
// cross-user actions and is therefore considered a sensitive read.
type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// List returns a paginated activity feed for the current tenant.
//
// Query params:
//
//	limit       int    (1..200, default 50)
//	entity_type string (optional, exact match — e.g. "customer", "job")
//	since       RFC3339 timestamp (optional, returns rows created after)
//	cursor      RFC3339 timestamp (optional, keyset pagination — created_at < cursor)
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	q := r.URL.Query()
	limit := 50
	if v := q.Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 200 {
			limit = n
		}
	}

	var (
		args      = []interface{}{bizID}
		filters   = []string{"al.business_id = $1"}
		nextParam = 2
	)

	if et := strings.TrimSpace(q.Get("entity_type")); et != "" {
		filters = append(filters, "al.entity_type = $"+strconv.Itoa(nextParam))
		args = append(args, et)
		nextParam++
	}

	if s := strings.TrimSpace(q.Get("since")); s != "" {
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			filters = append(filters, "al.created_at > $"+strconv.Itoa(nextParam))
			args = append(args, t)
			nextParam++
		}
	}

	if c := strings.TrimSpace(q.Get("cursor")); c != "" {
		if t, err := time.Parse(time.RFC3339, c); err == nil {
			filters = append(filters, "al.created_at < $"+strconv.Itoa(nextParam))
			args = append(args, t)
			nextParam++
		}
	}

	args = append(args, limit)
	limitParam := nextParam

	sql := `SELECT al.id, al.user_id,
	               COALESCE(u.first_name || ' ' || u.last_name, 'System') AS user_name,
	               al.action, al.entity_type, al.entity_id, al.created_at
	        FROM audit_logs al
	        LEFT JOIN users u ON u.id = al.user_id
	        WHERE ` + strings.Join(filters, " AND ") + `
	        ORDER BY al.created_at DESC
	        LIMIT $` + strconv.Itoa(limitParam)

	rows, err := h.db.Query(r.Context(), sql, args...)
	if err != nil {
		h.log.Error("activity list", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type item struct {
		ID         interface{} `json:"id"`
		UserID     interface{} `json:"user_id"`
		UserName   string      `json:"user_name"`
		Action     string      `json:"action"`
		EntityType interface{} `json:"entity_type"`
		EntityID   interface{} `json:"entity_id"`
		CreatedAt  time.Time   `json:"created_at"`
		Category   string      `json:"category"`
	}

	out := make([]item, 0, limit)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.UserID, &it.UserName, &it.Action, &it.EntityType, &it.EntityID, &it.CreatedAt); err != nil {
			h.log.Warn("activity scan", zap.Error(err))
			continue
		}
		it.Category = categorize(it.Action)
		out = append(out, it)
	}

	// Audit the read — feed exposes cross-user actions.
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     userID(claims),
		Action:     "ACTIVITY_FEED_VIEWED",
		EntityType: "activity_feed",
		EntityID:   uuid.Nil,
		IPAddress:  r.RemoteAddr,
	})

	var nextCursor string
	if len(out) == limit {
		nextCursor = out[len(out)-1].CreatedAt.Format(time.RFC3339Nano)
	}

	respond(w, 200, map[string]interface{}{
		"items":       out,
		"next_cursor": nextCursor,
		"limit":       limit,
	})
}

// categorize derives a high-level grouping from an audit action name.
// Mirrors the activity_feed view's CASE expression so the mobile UI
// can colour/icon by category without re-parsing.
func categorize(action string) string {
	a := strings.ToLower(action)
	switch {
	case strings.HasPrefix(a, "job"):
		return "job"
	case strings.HasPrefix(a, "invoice"):
		return "invoice"
	case strings.HasPrefix(a, "quote"):
		return "quote"
	case strings.HasPrefix(a, "customer"):
		return "customer"
	case strings.HasPrefix(a, "worker"):
		return "worker"
	case strings.HasPrefix(a, "payment"):
		return "payment"
	case strings.HasPrefix(a, "session"), strings.HasPrefix(a, "auth"), strings.HasPrefix(a, "login"):
		return "auth"
	case strings.HasPrefix(a, "task"):
		return "task"
	case strings.HasPrefix(a, "lead"):
		return "lead"
	case strings.HasPrefix(a, "expense"):
		return "expense"
	case strings.HasPrefix(a, "safety"), strings.HasPrefix(a, "incident"):
		return "safety"
	default:
		return "system"
	}
}

func userID(c *middleware.Claims) uuid.UUID {
	if c == nil {
		return uuid.Nil
	}
	return c.UserID
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		_ = json.NewEncoder(w).Encode(data)
	}
}
