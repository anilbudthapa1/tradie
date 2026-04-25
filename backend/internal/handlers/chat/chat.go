package chat

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// ── Hub ───────────────────────────────────────────────────────────────────────

// Hub maintains the set of active WebSocket clients keyed by business_id → user_id.
type Hub struct {
	mu      sync.RWMutex
	clients map[string]map[string]*Client // business_id -> user_id -> client
}

// Client is a single authenticated WebSocket connection.
type Client struct {
	conn       *websocket.Conn
	userID     string
	businessID string
	send       chan []byte
}

// WSMessage is the wire format for WebSocket frames in both directions.
type WSMessage struct {
	Type    string      `json:"type"`   // "message" | "ping" | "read"
	RoomID  string      `json:"room_id"`
	Content string      `json:"content"`
	Data    interface{} `json:"data,omitempty"`
}

// GlobalHub is the package-level singleton used by HTTP handlers and the WS pump.
var GlobalHub = NewHub()

func NewHub() *Hub {
	return &Hub{
		clients: make(map[string]map[string]*Client),
	}
}

func (h *Hub) register(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[c.businessID] == nil {
		h.clients[c.businessID] = make(map[string]*Client)
	}
	// Close any stale connection for the same user.
	if old, ok := h.clients[c.businessID][c.userID]; ok {
		close(old.send)
	}
	h.clients[c.businessID][c.userID] = c
}

func (h *Hub) unregister(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	biz := h.clients[c.businessID]
	if biz == nil {
		return
	}
	if existing, ok := biz[c.userID]; ok && existing == c {
		delete(biz, c.userID)
		if len(biz) == 0 {
			delete(h.clients, c.businessID)
		}
	}
}

// broadcastToUsers sends payload to each listed user_id within a business.
func (h *Hub) broadcastToUsers(businessID string, userIDs []string, payload []byte) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	biz := h.clients[businessID]
	if biz == nil {
		return
	}
	for _, uid := range userIDs {
		if c, ok := biz[uid]; ok {
			select {
			case c.send <- payload:
			default:
				// Slow consumer — drop rather than block.
			}
		}
	}
}

// ── Upgrader ──────────────────────────────────────────────────────────────────

var upgrader = websocket.Upgrader{
	CheckOrigin:     func(r *http.Request) bool { return true },
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
}

// ── Handler ───────────────────────────────────────────────────────────────────

type Handler struct {
	cfg *config.Config
	db  *pgxpool.Pool
	log *zap.Logger
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger) *Handler {
	return &Handler{cfg: cfg, db: db, log: log}
}

// ── Response helpers ──────────────────────────────────────────────────────────

func respondJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func respondError(w http.ResponseWriter, status int, code string) {
	respondJSON(w, status, map[string]string{"error": code})
}

// ── ListRooms — GET /chat/rooms ───────────────────────────────────────────────

func (h *Handler) ListRooms(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())

	rows, err := h.db.Query(r.Context(), `
		SELECT
			cr.id,
			cr.name,
			cr.type,
			cr.job_id,
			cr.created_by,
			cr.created_at,
			(
				SELECT row_to_json(sub)
				FROM (
					SELECT m.id, m.content, m.created_at, m.user_id
					FROM chat_messages m
					WHERE m.room_id = cr.id AND m.is_deleted = false
					ORDER BY m.created_at DESC
					LIMIT 1
				) sub
			) AS last_message,
			(
				SELECT COUNT(*)
				FROM chat_messages m
				WHERE m.room_id = cr.id
				  AND m.user_id != $2
				  AND m.is_deleted = false
				  AND m.created_at > COALESCE(
					(SELECT read_at FROM chat_read_receipts
					 WHERE room_id = cr.id AND user_id = $2),
					'1970-01-01'::timestamptz
				  )
			) AS unread_count
		FROM chat_rooms cr
		INNER JOIN chat_members cm ON cm.room_id = cr.id AND cm.user_id = $2
		WHERE cr.business_id = $1
		ORDER BY cr.created_at DESC
	`, bizID, claims.UserID)
	if err != nil {
		h.log.Error("list rooms", zap.Error(err))
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	defer rows.Close()

	type Room struct {
		ID          uuid.UUID              `json:"id"`
		Name        string                 `json:"name"`
		Type        string                 `json:"type"`
		JobID       *uuid.UUID             `json:"job_id,omitempty"`
		CreatedBy   uuid.UUID              `json:"created_by"`
		CreatedAt   time.Time              `json:"created_at"`
		LastMessage map[string]interface{} `json:"last_message,omitempty"`
		UnreadCount int                    `json:"unread_count"`
	}

	var rooms []Room
	for rows.Next() {
		var room Room
		var lastMsgJSON []byte
		if err := rows.Scan(
			&room.ID, &room.Name, &room.Type, &room.JobID,
			&room.CreatedBy, &room.CreatedAt,
			&lastMsgJSON, &room.UnreadCount,
		); err != nil {
			continue
		}
		if lastMsgJSON != nil {
			_ = json.Unmarshal(lastMsgJSON, &room.LastMessage)
		}
		rooms = append(rooms, room)
	}
	if rooms == nil {
		rooms = []Room{}
	}
	respondJSON(w, http.StatusOK, rooms)
}

// ── CreateRoom — POST /chat/rooms ─────────────────────────────────────────────

func (h *Handler) CreateRoom(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req struct {
		Name      string      `json:"name"`
		Type      string      `json:"type"`       // "direct" | "group" | "job"
		MemberIDs []uuid.UUID `json:"member_ids"` // other members, not including self
		JobID     *uuid.UUID  `json:"job_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if req.Type == "" {
		req.Type = "group"
	}

	ctx := r.Context()

	// For direct rooms, find or reuse an existing one-to-one room.
	if req.Type == "direct" && len(req.MemberIDs) == 1 {
		otherID := req.MemberIDs[0]
		var existingID uuid.UUID
		err := h.db.QueryRow(ctx, `
			SELECT cr.id
			FROM chat_rooms cr
			INNER JOIN chat_members cm1 ON cm1.room_id = cr.id AND cm1.user_id = $1
			INNER JOIN chat_members cm2 ON cm2.room_id = cr.id AND cm2.user_id = $2
			WHERE cr.business_id = $3 AND cr.type = 'direct'
			LIMIT 1
		`, claims.UserID, otherID, bizID).Scan(&existingID)
		if err == nil {
			h.getRoom(w, r, existingID)
			return
		}
	}

	tx, err := h.db.Begin(ctx)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	defer tx.Rollback(ctx)

	var roomID uuid.UUID
	err = tx.QueryRow(ctx, `
		INSERT INTO chat_rooms (business_id, name, type, job_id, created_by)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id
	`, bizID, req.Name, req.Type, req.JobID, claims.UserID).Scan(&roomID)
	if err != nil {
		h.log.Error("create room", zap.Error(err))
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	// Add creator + all requested members.
	allMembers := append([]uuid.UUID{claims.UserID}, req.MemberIDs...)
	for _, uid := range allMembers {
		if _, err := tx.Exec(ctx, `
			INSERT INTO chat_members (room_id, user_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING
		`, roomID, uid); err != nil {
			h.log.Error("add chat member", zap.Error(err))
			respondError(w, http.StatusInternalServerError, "server_error")
			return
		}
	}

	if err := tx.Commit(ctx); err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	h.getRoom(w, r, roomID)
}

// ── GetRoom — GET /chat/rooms/{id} ───────────────────────────────────────────

func (h *Handler) GetRoom(w http.ResponseWriter, r *http.Request) {
	roomID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondError(w, http.StatusBadRequest, "invalid_id")
		return
	}
	h.getRoom(w, r, roomID)
}

func (h *Handler) getRoom(w http.ResponseWriter, r *http.Request, roomID uuid.UUID) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var isMember bool
	_ = h.db.QueryRow(r.Context(), `
		SELECT EXISTS(SELECT 1 FROM chat_members WHERE room_id=$1 AND user_id=$2)
	`, roomID, claims.UserID).Scan(&isMember)
	if !isMember {
		respondError(w, http.StatusForbidden, "forbidden")
		return
	}

	var room struct {
		ID        uuid.UUID  `json:"id"`
		Name      string     `json:"name"`
		Type      string     `json:"type"`
		JobID     *uuid.UUID `json:"job_id,omitempty"`
		CreatedBy uuid.UUID  `json:"created_by"`
		CreatedAt time.Time  `json:"created_at"`
	}
	err := h.db.QueryRow(r.Context(), `
		SELECT id, name, type, job_id, created_by, created_at
		FROM chat_rooms WHERE id=$1 AND business_id=$2
	`, roomID, bizID).Scan(
		&room.ID, &room.Name, &room.Type, &room.JobID,
		&room.CreatedBy, &room.CreatedAt,
	)
	if err == pgx.ErrNoRows {
		respondError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	memberRows, _ := h.db.Query(r.Context(), `
		SELECT cm.user_id, u.first_name, u.last_name, u.avatar_url, cm.joined_at
		FROM chat_members cm
		INNER JOIN users u ON u.id = cm.user_id
		WHERE cm.room_id = $1
	`, roomID)
	defer memberRows.Close()

	type Member struct {
		UserID    uuid.UUID `json:"user_id"`
		FirstName string    `json:"first_name"`
		LastName  string    `json:"last_name"`
		AvatarURL *string   `json:"avatar_url,omitempty"`
		JoinedAt  time.Time `json:"joined_at"`
	}
	var members []Member
	for memberRows.Next() {
		var m Member
		if err := memberRows.Scan(&m.UserID, &m.FirstName, &m.LastName, &m.AvatarURL, &m.JoinedAt); err == nil {
			members = append(members, m)
		}
	}
	if members == nil {
		members = []Member{}
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"room":    room,
		"members": members,
	})
}

// ── GetMessages — GET /chat/rooms/{id}/messages ───────────────────────────────

func (h *Handler) GetMessages(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())

	roomID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondError(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var isMember bool
	_ = h.db.QueryRow(r.Context(), `
		SELECT EXISTS(SELECT 1 FROM chat_members WHERE room_id=$1 AND user_id=$2)
	`, roomID, claims.UserID).Scan(&isMember)
	if !isMember {
		respondError(w, http.StatusForbidden, "forbidden")
		return
	}

	const limit = 50
	beforeID := r.URL.Query().Get("before")

	type Message struct {
		ID        uuid.UUID `json:"id"`
		RoomID    uuid.UUID `json:"room_id"`
		UserID    uuid.UUID `json:"user_id"`
		Content   string    `json:"content"`
		FileURL   *string   `json:"file_url,omitempty"`
		IsDeleted bool      `json:"is_deleted"`
		CreatedAt time.Time `json:"created_at"`
		FirstName string    `json:"first_name"`
		LastName  string    `json:"last_name"`
		AvatarURL *string   `json:"avatar_url,omitempty"`
	}

	var rows pgx.Rows
	if pid, parseErr := uuid.Parse(beforeID); parseErr == nil {
		rows, err = h.db.Query(r.Context(), `
			SELECT
				m.id, m.room_id, m.user_id, m.content, m.file_url,
				m.is_deleted, m.created_at,
				u.first_name, u.last_name, u.avatar_url
			FROM chat_messages m
			INNER JOIN users u ON u.id = m.user_id
			WHERE m.room_id = $1
			  AND m.business_id = $2
			  AND m.is_deleted = false
			  AND m.created_at < (SELECT created_at FROM chat_messages WHERE id = $3)
			ORDER BY m.created_at DESC
			LIMIT $4
		`, roomID, bizID, pid, limit)
	} else {
		rows, err = h.db.Query(r.Context(), `
			SELECT
				m.id, m.room_id, m.user_id, m.content, m.file_url,
				m.is_deleted, m.created_at,
				u.first_name, u.last_name, u.avatar_url
			FROM chat_messages m
			INNER JOIN users u ON u.id = m.user_id
			WHERE m.room_id = $1 AND m.business_id = $2 AND m.is_deleted = false
			ORDER BY m.created_at DESC
			LIMIT $3
		`, roomID, bizID, limit)
	}
	if err != nil {
		h.log.Error("get messages", zap.Error(err))
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}
	defer rows.Close()

	var messages []Message
	for rows.Next() {
		var msg Message
		if err := rows.Scan(
			&msg.ID, &msg.RoomID, &msg.UserID, &msg.Content, &msg.FileURL,
			&msg.IsDeleted, &msg.CreatedAt,
			&msg.FirstName, &msg.LastName, &msg.AvatarURL,
		); err == nil {
			messages = append(messages, msg)
		}
	}
	if messages == nil {
		messages = []Message{}
	}
	respondJSON(w, http.StatusOK, messages)
}

// ── SendMessage — POST /chat/rooms/{id}/messages ──────────────────────────────

func (h *Handler) SendMessage(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())

	roomID, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondError(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var isMember bool
	_ = h.db.QueryRow(r.Context(), `
		SELECT EXISTS(SELECT 1 FROM chat_members WHERE room_id=$1 AND user_id=$2)
	`, roomID, claims.UserID).Scan(&isMember)
	if !isMember {
		respondError(w, http.StatusForbidden, "forbidden")
		return
	}

	var req struct {
		Content string  `json:"content"`
		FileURL *string `json:"file_url"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Content == "" {
		respondError(w, http.StatusBadRequest, "invalid_request")
		return
	}

	var msgID uuid.UUID
	var createdAt time.Time
	err = h.db.QueryRow(r.Context(), `
		INSERT INTO chat_messages (room_id, business_id, user_id, content, file_url)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, created_at
	`, roomID, bizID, claims.UserID, req.Content, req.FileURL).Scan(&msgID, &createdAt)
	if err != nil {
		h.log.Error("send message", zap.Error(err))
		respondError(w, http.StatusInternalServerError, "server_error")
		return
	}

	h.broadcastMessage(context.Background(), roomID, bizID, claims.UserID.String(), msgID, req.Content, req.FileURL, createdAt)

	respondJSON(w, http.StatusCreated, map[string]interface{}{
		"id":         msgID,
		"room_id":    roomID,
		"user_id":    claims.UserID,
		"content":    req.Content,
		"file_url":   req.FileURL,
		"created_at": createdAt,
	})
}

// broadcastMessage fetches room members and fans out to connected clients.
func (h *Handler) broadcastMessage(ctx context.Context, roomID, bizID uuid.UUID, userIDStr string, msgID uuid.UUID, content string, fileURL *string, createdAt time.Time) {
	rows, err := h.db.Query(ctx, `SELECT user_id FROM chat_members WHERE room_id = $1`, roomID)
	if err != nil {
		return
	}
	var memberIDs []string
	for rows.Next() {
		var uid uuid.UUID
		if err := rows.Scan(&uid); err == nil {
			memberIDs = append(memberIDs, uid.String())
		}
	}
	rows.Close()

	payload, _ := json.Marshal(WSMessage{
		Type:    "message",
		RoomID:  roomID.String(),
		Content: content,
		Data: map[string]interface{}{
			"id":         msgID,
			"user_id":    userIDStr,
			"created_at": createdAt,
			"file_url":   fileURL,
		},
	})
	GlobalHub.broadcastToUsers(bizID.String(), memberIDs, payload)
}

// ── WebSocket — GET /chat/ws?token=<jwt> ─────────────────────────────────────

func (h *Handler) WebSocket(w http.ResponseWriter, r *http.Request) {
	tokenStr := r.URL.Query().Get("token")
	if tokenStr == "" {
		http.Error(w, `{"error":"missing_token"}`, http.StatusUnauthorized)
		return
	}

	claims := &middleware.Claims{}
	_, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrSignatureInvalid
		}
		return []byte(h.cfg.JWTSecret), nil
	})
	if err != nil {
		http.Error(w, `{"error":"invalid_token"}`, http.StatusUnauthorized)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		h.log.Error("ws upgrade", zap.Error(err))
		return
	}

	client := &Client{
		conn:       conn,
		userID:     claims.UserID.String(),
		businessID: claims.BusinessID.String(),
		send:       make(chan []byte, 256),
	}

	GlobalHub.register(client)
	go h.writePump(client)
	h.readPump(client) // blocks until disconnect
}

// writePump drains client.send to the WebSocket, with a 30 s ping heartbeat.
func (h *Handler) writePump(c *Client) {
	ticker := time.NewTicker(30 * time.Second)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case msg, ok := <-c.send:
			if !ok {
				_ = c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		case <-ticker.C:
			ping, _ := json.Marshal(WSMessage{Type: "ping"})
			if err := c.conn.WriteMessage(websocket.TextMessage, ping); err != nil {
				return
			}
		}
	}
}

// readPump reads incoming frames, persists messages and broadcasts to room members.
func (h *Handler) readPump(c *Client) {
	defer func() {
		GlobalHub.unregister(c)
		c.conn.Close()
	}()

	c.conn.SetReadLimit(4096)
	_ = c.conn.SetReadDeadline(time.Now().Add(70 * time.Second))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(70 * time.Second))
	})

	userID, _ := uuid.Parse(c.userID)
	bizID, _ := uuid.Parse(c.businessID)
	ctx := context.Background()

	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			break
		}
		_ = c.conn.SetReadDeadline(time.Now().Add(70 * time.Second))

		var msg WSMessage
		if err := json.Unmarshal(raw, &msg); err != nil {
			continue
		}

		switch msg.Type {
		case "message":
			if msg.RoomID == "" || msg.Content == "" {
				continue
			}
			roomID, err := uuid.Parse(msg.RoomID)
			if err != nil {
				continue
			}

			// Gate: user must be a member of the target room.
			var isMember bool
			_ = h.db.QueryRow(ctx, `
				SELECT EXISTS(SELECT 1 FROM chat_members WHERE room_id=$1 AND user_id=$2)
			`, roomID, userID).Scan(&isMember)
			if !isMember {
				continue
			}

			var msgID uuid.UUID
			var createdAt time.Time
			err = h.db.QueryRow(ctx, `
				INSERT INTO chat_messages (room_id, business_id, user_id, content)
				VALUES ($1, $2, $3, $4)
				RETURNING id, created_at
			`, roomID, bizID, userID, msg.Content).Scan(&msgID, &createdAt)
			if err != nil {
				h.log.Error("ws persist message", zap.Error(err))
				continue
			}

			h.broadcastMessage(ctx, roomID, bizID, c.userID, msgID, msg.Content, nil, createdAt)

		case "ping":
			pong, _ := json.Marshal(WSMessage{Type: "ping"})
			select {
			case c.send <- pong:
			default:
			}
		}
	}
}
