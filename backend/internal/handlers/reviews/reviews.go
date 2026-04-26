// Package reviews implements Module 21 — Review Request Module.
//
// One service: ReviewRequestService. Two surfaces:
//
//   - Authenticated CRUD for owners / managers:
//       GET    /api/v1/reviews
//       POST   /api/v1/reviews
//       GET    /api/v1/reviews/{id}
//       PATCH  /api/v1/reviews/{id}
//       DELETE /api/v1/reviews/{id}
//       POST   /api/v1/reviews/{id}/remind
//       GET    /api/v1/reviews/export.csv
//       GET    /api/v1/me/review_request_module
//
//   - Public, token-gated, for the customer-facing review form:
//       GET    /api/v1/public/reviews/{token}
//       POST   /api/v1/public/reviews/{token}
//
// Security:
//
//   - business_id only ever from BusinessIDFromCtx (auth side)
//   - Public endpoints look up by token only — never by business_id
//     from the URL — so a leaked token gives no cross-tenant lift
//   - Tokens expire (default 60 days) and are checked on every read
//   - Status transitions enforced server-side and at the DB
//   - Audit events use spec-named REVIEW_REQUEST_MODULE_*
package reviews

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
	"github.com/tradie/api/internal/services/email"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditViewed       = "REVIEW_REQUEST_MODULE_VIEWED"
	AuditCreated      = "REVIEW_REQUEST_MODULE_CREATED"
	AuditUpdated      = "REVIEW_REQUEST_MODULE_UPDATED"
	AuditDeleted      = "REVIEW_REQUEST_MODULE_DELETED"
	AuditAccessDenied = "REVIEW_REQUEST_MODULE_ACCESS_DENIED"
	AuditExported     = "REVIEW_REQUEST_MODULE_EXPORTED"

	maxBodyBytes = 16 * 1024
	defaultTTL   = 60 * 24 * time.Hour // 60 days
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedStatus = map[string]bool{
		"sent": true, "opened": true, "responded": true, "declined": true, "expired": true,
	}
	allowedChannel    = map[string]bool{"email": true, "sms": true, "push": true, "manual": true}
	allowedTransition = map[[2]string]bool{
		{"sent", "opened"}:      true,
		{"sent", "declined"}:    true,
		{"sent", "expired"}:     true,
		{"opened", "responded"}: true,
		{"opened", "declined"}:  true,
		{"opened", "expired"}:   true,
	}
)

// ── Handler / wiring ─────────────────────────────────────────────

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
	email *email.Service
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService, emailSvc *email.Service) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit, email: emailSvc}
}

// ── Row shape ───────────────────────────────────────────────────

type reviewRow struct {
	ID             uuid.UUID  `json:"id"`
	BusinessID     uuid.UUID  `json:"-"`
	CreatedBy      *uuid.UUID `json:"created_by"`
	UpdatedBy      *uuid.UUID `json:"updated_by"`
	JobID          *uuid.UUID `json:"job_id"`
	CustomerID     *uuid.UUID `json:"customer_id"`
	Status         string     `json:"status"`
	Channel        string     `json:"channel"`
	Rating         *int       `json:"rating"`
	Feedback       *string    `json:"feedback"`
	Token          *string    `json:"token,omitempty"`
	ExpiresAt      *time.Time `json:"expires_at"`
	SentAt         time.Time  `json:"sent_at"`
	OpenedAt       *time.Time `json:"opened_at"`
	RespondedAt    *time.Time `json:"responded_at"`
	LastReminderAt *time.Time `json:"last_reminder_at"`
	ReminderCount  int        `json:"reminder_count"`
	Metadata       []byte     `json:"-"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

func (a *reviewRow) MarshalJSON() ([]byte, error) {
	type alias reviewRow
	mm := json.RawMessage(a.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(a), mm})
}

// reviewRow without the Token (used for owner-side responses where
// the token is sensitive — owners get the public URL via a separate
// helper, not the raw token in every list).
func (a *reviewRow) public() *reviewRow {
	clone := *a
	clone.Token = nil
	return &clone
}

// ── List (GET /api/v1/reviews) ──────────────────────────────────

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "reviews.view") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedStatus[statusFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	customerID := strings.TrimSpace(r.URL.Query().Get("customer_id"))
	jobID := strings.TrimSpace(r.URL.Query().Get("job_id"))
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	args := []interface{}{bizID}
	filters := []string{"business_id=$1", "deleted_at IS NULL"}
	next := 2
	if statusFilter != "" {
		filters = append(filters, "status=$"+strconv.Itoa(next))
		args = append(args, statusFilter)
		next++
	}
	if customerID != "" {
		uid, err := uuid.Parse(customerID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_customer_id")
			return
		}
		filters = append(filters, "customer_id=$"+strconv.Itoa(next))
		args = append(args, uid)
		next++
	}
	if jobID != "" {
		uid, err := uuid.Parse(jobID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_job_id")
			return
		}
		filters = append(filters, "job_id=$"+strconv.Itoa(next))
		args = append(args, uid)
		next++
	}
	args = append(args, limit)
	limitParam := next

	q := `SELECT id, business_id, created_by, updated_by, job_id, customer_id,
	             status, channel, rating, feedback, token, expires_at,
	             sent_at, opened_at, responded_at, last_reminder_at, reminder_count,
	             metadata, created_at, updated_at
	      FROM review_requests
	      WHERE ` + strings.Join(filters, " AND ") + `
	      ORDER BY sent_at DESC
	      LIMIT $` + strconv.Itoa(limitParam)

	rows, err := h.db.Query(r.Context(), q, args...)
	if err != nil {
		h.log.Error("list reviews", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*reviewRow{}
	for rows.Next() {
		rr := &reviewRow{}
		if err := scanReview(rows, rr); err == nil {
			out = append(out, rr.public())
		}
	}
	respond(w, http.StatusOK, out)
}

// ── Create (POST /api/v1/reviews) ───────────────────────────────

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reviews.request") {
		return
	}

	var req struct {
		CustomerID string                 `json:"customer_id"`
		JobID      *string                `json:"job_id"`
		Channel    string                 `json:"channel"`
		ExpiresIn  *int                   `json:"expires_in_days"`
		Metadata   map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	customerID, err := uuid.Parse(strings.TrimSpace(req.CustomerID))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_customer_id")
		return
	}
	if !h.customerInTenant(r, customerID, bizID) {
		respondErr(w, http.StatusBadRequest, "customer_not_in_tenant")
		return
	}

	var jobUUID *uuid.UUID
	if req.JobID != nil && *req.JobID != "" {
		jid, err := uuid.Parse(*req.JobID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_job_id")
			return
		}
		// Job must belong to this tenant AND match the customer.
		var ok bool
		if err := h.db.QueryRow(r.Context(),
			`SELECT EXISTS(SELECT 1 FROM jobs WHERE id=$1 AND business_id=$2 AND customer_id=$3 AND deleted_at IS NULL)`,
			jid, bizID, customerID).Scan(&ok); err != nil || !ok {
			respondErr(w, http.StatusBadRequest, "job_not_in_tenant_or_customer_mismatch")
			return
		}
		jobUUID = &jid
	}

	if req.Channel == "" {
		req.Channel = "email"
	}
	if !allowedChannel[req.Channel] {
		respondErr(w, http.StatusBadRequest, "invalid_channel")
		return
	}

	ttl := defaultTTL
	if req.ExpiresIn != nil {
		if *req.ExpiresIn <= 0 || *req.ExpiresIn > 365 {
			respondErr(w, http.StatusBadRequest, "invalid_expires_in_days")
			return
		}
		ttl = time.Duration(*req.ExpiresIn) * 24 * time.Hour
	}
	expiresAt := time.Now().Add(ttl)

	token, err := newToken()
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "token_failed")
		return
	}

	metaBytes := jsonOrEmpty(req.Metadata)

	rr := &reviewRow{}
	err = h.db.QueryRow(r.Context(),
		`INSERT INTO review_requests
		   (business_id, created_by, job_id, customer_id, channel, token, expires_at, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
		 RETURNING id, business_id, created_by, updated_by, job_id, customer_id,
		           status, channel, rating, feedback, token, expires_at,
		           sent_at, opened_at, responded_at, last_reminder_at, reminder_count,
		           metadata, created_at, updated_at`,
		bizID, claims.UserID, jobUUID, customerID, req.Channel, token, expiresAt, metaBytes,
	).Scan(&rr.ID, &rr.BusinessID, &rr.CreatedBy, &rr.UpdatedBy, &rr.JobID, &rr.CustomerID,
		&rr.Status, &rr.Channel, &rr.Rating, &rr.Feedback, &rr.Token, &rr.ExpiresAt,
		&rr.SentAt, &rr.OpenedAt, &rr.RespondedAt, &rr.LastReminderAt, &rr.ReminderCount,
		&rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt)
	if err != nil {
		h.log.Error("create review", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "review_request",
		EntityID:   rr.ID,
		NewData: map[string]interface{}{
			"customer_id": customerID, "job_id": jobUUID, "channel": req.Channel,
		},
		IPAddress: r.RemoteAddr,
	})

	// Dispatch the public link to the customer. SMS path is logged
	// only — Twilio wiring lives in services/notifications and we
	// route through email here as the safe default; SMS will be added
	// when the dispatcher gains channel routing.
	if strings.EqualFold(req.Channel, "email") {
		var (
			toEmail string
			toName  string
		)
		err := h.db.QueryRow(r.Context(),
			`SELECT email,
			        NULLIF(TRIM(COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')), '')
			   FROM customers
			  WHERE id = $1 AND business_id = $2`,
			customerID, bizID,
		).Scan(&toEmail, &toName)
		if err == nil && toEmail != "" && rr.Token != nil {
			if toName == "" {
				toName = toEmail
			}
			link := fmt.Sprintf("%s/reviews/%s", h.cfg.FrontendURL, *rr.Token)
			body := fmt.Sprintf(
				`<p>Hi %s,</p>
				 <p>Thanks for the recent work — we'd love your feedback.</p>
				 <p><a href="%s">Leave a review</a></p>
				 <p>This link expires on %s.</p>`,
				html.EscapeString(toName),
				link,
				rr.ExpiresAt.Format("2 Jan 2006"),
			)
			if sendErr := h.email.Send(r.Context(), toEmail, toName, "How did we do?", body); sendErr != nil {
				h.log.Warn("review request email failed",
					zap.String("review_id", rr.ID.String()),
					zap.Error(sendErr))
			}
		}
	}

	// On create, return the row WITH the token so the caller can build
	// the public link (e.g. for manual delivery). It's the only place
	// the token leaves the server side.
	respond(w, http.StatusCreated, rr)
}

// ── Get (GET /api/v1/reviews/{id}) ──────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "reviews.view") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	rr := &reviewRow{}
	row := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, created_by, updated_by, job_id, customer_id,
		        status, channel, rating, feedback, token, expires_at,
		        sent_at, opened_at, responded_at, last_reminder_at, reminder_count,
		        metadata, created_at, updated_at
		 FROM review_requests WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID)
	if err := scanReview(row, rr); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	respond(w, http.StatusOK, rr.public())
}

// ── Update (PATCH /api/v1/reviews/{id}) ─────────────────────────

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reviews.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Status   *string                `json:"status"`
		Channel  *string                `json:"channel"`
		Metadata map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Status != nil && !allowedStatus[*req.Status] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	if req.Channel != nil && !allowedChannel[*req.Channel] {
		respondErr(w, http.StatusBadRequest, "invalid_channel")
		return
	}

	var current reviewRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, status, channel
		 FROM review_requests WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current.ID, &current.Status, &current.Channel)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	if req.Status != nil && *req.Status != current.Status {
		if !allowedTransition[[2]string{current.Status, *req.Status}] {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
	}

	var meta []byte
	if req.Metadata != nil {
		meta, _ = json.Marshal(req.Metadata)
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE review_requests SET
		   status     = COALESCE($3, status),
		   channel    = COALESCE($4, channel),
		   metadata   = COALESCE($5::jsonb, metadata),
		   updated_by = $6,
		   updated_at = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Status, req.Channel, meta, claims.UserID)
	if err != nil {
		if isStatusTransitionError(err) {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
		h.log.Error("update review", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "update_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "review_request",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current.Status, "channel": current.Channel},
		NewData:    map[string]interface{}{"status": derefStr(req.Status), "channel": derefStr(req.Channel)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "updated"})
}

// ── Delete (DELETE /api/v1/reviews/{id}) — soft delete. ─────────

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reviews.manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE review_requests
		   SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "delete_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditDeleted,
		EntityType: "review_request",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// ── Reminder (POST /api/v1/reviews/{id}/remind) ─────────────────

// Remind bumps the reminder counter and timestamp. The actual
// dispatch is left to the configured NotificationHookService — the
// audit captures intent so this works even without a real backend.
func (h *Handler) Remind(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reviews.request") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE review_requests
		   SET last_reminder_at=NOW(),
		       reminder_count=reminder_count+1,
		       updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status IN ('sent','opened')
		   AND (expires_at IS NULL OR expires_at > NOW())`,
		id, bizID, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "remind_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusConflict, "cannot_remind:terminal_or_expired")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "review_request",
		EntityID:   id,
		NewData:    map[string]interface{}{"reminder_sent": true},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "reminder_recorded"})
}

// ── Self-service ────────────────────────────────────────────────

// MeView returns review requests for jobs the calling worker was
// assigned to — so they can see how their work was rated without
// reading every customer's history.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reviews.view") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT DISTINCT rr.id, rr.business_id, rr.created_by, rr.updated_by,
		                rr.job_id, rr.customer_id, rr.status, rr.channel,
		                rr.rating, rr.feedback, rr.token, rr.expires_at,
		                rr.sent_at, rr.opened_at, rr.responded_at,
		                rr.last_reminder_at, rr.reminder_count,
		                rr.metadata, rr.created_at, rr.updated_at
		 FROM review_requests rr
		 JOIN jobs j ON j.id=rr.job_id
		 JOIN job_assignments ja ON ja.job_id=j.id
		 WHERE rr.business_id=$1 AND rr.deleted_at IS NULL
		   AND ja.user_id=$2
		 ORDER BY rr.sent_at DESC
		 LIMIT 200`,
		bizID, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*reviewRow{}
	for rows.Next() {
		rr := &reviewRow{}
		if err := scanReview(rows, rr); err == nil {
			out = append(out, rr.public())
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "review_request.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, out)
}

// ── Export ──────────────────────────────────────────────────────

func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "reviews.export") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT rr.id, rr.customer_id,
		        COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer,
		        rr.job_id, rr.status, rr.channel, rr.rating,
		        COALESCE(rr.feedback,''), rr.sent_at, rr.responded_at, rr.reminder_count
		 FROM review_requests rr
		 LEFT JOIN customers c ON c.id=rr.customer_id
		 WHERE rr.business_id=$1 AND rr.deleted_at IS NULL
		 ORDER BY rr.sent_at DESC
		 LIMIT 10000`,
		bizID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="review-requests-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "customer_id", "customer", "job_id", "status",
		"channel", "rating", "feedback", "sent_at", "responded_at", "reminder_count"})

	for rows.Next() {
		var id, custID uuid.UUID
		var jobID *uuid.UUID
		var customer, status, channel, feedback string
		var rating *int
		var reminderCount int
		var sentAt time.Time
		var respondedAt *time.Time
		if err := rows.Scan(&id, &custID, &customer, &jobID, &status, &channel,
			&rating, &feedback, &sentAt, &respondedAt, &reminderCount); err != nil {
			continue
		}
		ratingStr := ""
		if rating != nil {
			ratingStr = strconv.Itoa(*rating)
		}
		jobStr := ""
		if jobID != nil {
			jobStr = jobID.String()
		}
		respondedStr := ""
		if respondedAt != nil {
			respondedStr = respondedAt.UTC().Format(time.RFC3339)
		}
		_ = cw.Write([]string{
			id.String(), custID.String(), customer, jobStr, status, channel,
			ratingStr, feedback, sentAt.UTC().Format(time.RFC3339), respondedStr,
			strconv.Itoa(reminderCount),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "review_request",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Public surface ──────────────────────────────────────────────

// PublicGet returns a thin payload for the customer-facing review
// form. Looks up by token only — no business_id from the URL — so a
// leaked token is the only credential needed but cannot be pivoted
// to other tenants. Marks the row as 'opened' on first read.
//
// Auth: none. Tokens are unguessable random.
func (h *Handler) PublicGet(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimSpace(chi.URLParam(r, "token"))
	if len(token) < 16 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	type payload struct {
		ID           uuid.UUID `json:"id"`
		Status       string    `json:"status"`
		Rating       *int      `json:"rating"`
		Feedback     *string   `json:"feedback"`
		BusinessName string    `json:"business_name"`
		CustomerName string    `json:"customer_name"`
		JobTitle     string    `json:"job_title,omitempty"`
		ExpiresAt    time.Time `json:"expires_at"`
	}
	var p payload
	var expiresAt *time.Time
	var status string
	err := h.db.QueryRow(r.Context(),
		`SELECT rr.id, rr.status, rr.rating, rr.feedback, rr.expires_at,
		        COALESCE(b.name, ''),
		        COALESCE(c.first_name||' '||COALESCE(c.last_name,''), ''),
		        COALESCE(j.title, '')
		 FROM review_requests rr
		 LEFT JOIN businesses b ON b.id=rr.business_id
		 LEFT JOIN customers  c ON c.id=rr.customer_id
		 LEFT JOIN jobs       j ON j.id=rr.job_id
		 WHERE rr.token=$1 AND rr.deleted_at IS NULL`,
		token,
	).Scan(&p.ID, &status, &p.Rating, &p.Feedback, &expiresAt,
		&p.BusinessName, &p.CustomerName, &p.JobTitle)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	if expiresAt != nil && time.Now().After(*expiresAt) {
		// Mark expired so the row reflects reality and ops dashboards line up.
		_, _ = h.db.Exec(r.Context(),
			`UPDATE review_requests SET status='expired', updated_at=NOW()
			 WHERE id=$1 AND status IN ('sent','opened')`, p.ID)
		respondErr(w, http.StatusGone, "expired")
		return
	}

	// Bump status sent → opened on first read. Idempotent: opened stays opened.
	if status == "sent" {
		_, _ = h.db.Exec(r.Context(),
			`UPDATE review_requests SET status='opened', opened_at=NOW(), updated_at=NOW()
			 WHERE id=$1 AND status='sent'`, p.ID)
		status = "opened"
	}
	p.Status = status
	if expiresAt != nil {
		p.ExpiresAt = *expiresAt
	}

	respond(w, http.StatusOK, p)
}

// PublicSubmit accepts the customer's rating + feedback. Cannot be
// re-submitted once responded.
//
// Auth: none. Token-gated.
func (h *Handler) PublicSubmit(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimSpace(chi.URLParam(r, "token"))
	if len(token) < 16 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	var req struct {
		Rating   int    `json:"rating"`
		Feedback string `json:"feedback"`
		Decline  bool   `json:"decline"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	// Resolve to confirm row exists and isn't terminal/expired.
	var id uuid.UUID
	var status string
	var bizID uuid.UUID
	var expiresAt *time.Time
	err := h.db.QueryRow(r.Context(),
		`SELECT id, status, business_id, expires_at
		 FROM review_requests
		 WHERE token=$1 AND deleted_at IS NULL`,
		token,
	).Scan(&id, &status, &bizID, &expiresAt)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}
	if expiresAt != nil && time.Now().After(*expiresAt) {
		respondErr(w, http.StatusGone, "expired")
		return
	}
	if status == "responded" || status == "declined" || status == "expired" {
		respondErr(w, http.StatusConflict, "already_terminal:"+status)
		return
	}

	if req.Decline {
		if _, err := h.db.Exec(r.Context(),
			`UPDATE review_requests
			   SET status='declined', responded_at=NOW(), updated_at=NOW()
			 WHERE id=$1 AND status IN ('sent','opened')`, id); err != nil {
			respondErr(w, http.StatusInternalServerError, "decline_failed")
			return
		}
		// Tenant-scoped audit so the owner sees the decline in their feed.
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID, UserID: uuid.Nil, // public submission, no user
			Action: AuditUpdated, EntityType: "review_request", EntityID: id,
			NewData:   map[string]interface{}{"status": "declined", "via": "public"},
			IPAddress: r.RemoteAddr,
		})
		respond(w, http.StatusOK, map[string]string{"message": "declined"})
		return
	}

	if req.Rating < 1 || req.Rating > 5 {
		respondErr(w, http.StatusBadRequest, "rating_out_of_range")
		return
	}
	if len(req.Feedback) > 4000 {
		respondErr(w, http.StatusBadRequest, "feedback_too_long")
		return
	}

	// Move to opened first if still sent (mirrors the directed flow).
	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "tx_failed")
		return
	}
	defer tx.Rollback(r.Context())

	if status == "sent" {
		if _, err := tx.Exec(r.Context(),
			`UPDATE review_requests SET status='opened', opened_at=NOW(), updated_at=NOW()
			 WHERE id=$1 AND status='sent'`, id); err != nil {
			respondErr(w, http.StatusInternalServerError, "transition_failed")
			return
		}
	}

	if _, err := tx.Exec(r.Context(),
		`UPDATE review_requests
		   SET status='responded', rating=$2, feedback=$3, responded_at=NOW(), updated_at=NOW()
		 WHERE id=$1 AND status='opened'`,
		id, req.Rating, nullStr(req.Feedback)); err != nil {
		if isStatusTransitionError(err) {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
		respondErr(w, http.StatusInternalServerError, "submit_failed")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		respondErr(w, http.StatusInternalServerError, "commit_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     uuid.Nil,
		Action:     AuditUpdated,
		EntityType: "review_request",
		EntityID:   id,
		NewData:    map[string]interface{}{"status": "responded", "rating": req.Rating, "via": "public"},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{"message": "thanks", "rating": req.Rating})
}

// ── Internal helpers ────────────────────────────────────────────

// scanReview centralises the column order so List/Get/MeView stay aligned.
type rowScanner interface {
	Scan(dest ...interface{}) error
}

func scanReview(s rowScanner, rr *reviewRow) error {
	return s.Scan(
		&rr.ID, &rr.BusinessID, &rr.CreatedBy, &rr.UpdatedBy, &rr.JobID, &rr.CustomerID,
		&rr.Status, &rr.Channel, &rr.Rating, &rr.Feedback, &rr.Token, &rr.ExpiresAt,
		&rr.SentAt, &rr.OpenedAt, &rr.RespondedAt, &rr.LastReminderAt, &rr.ReminderCount,
		&rr.Metadata, &rr.CreatedAt, &rr.UpdatedAt,
	)
}

func (h *Handler) customerInTenant(r *http.Request, customerID, bizID uuid.UUID) bool {
	var ok bool
	if err := h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM customers WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		customerID, bizID).Scan(&ok); err != nil {
		return false
	}
	return ok
}

func (h *Handler) requirePermission(w http.ResponseWriter, r *http.Request, key string) bool {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return false
	}

	var allowed bool
	err := h.db.QueryRow(r.Context(),
		`SELECT EXISTS(
		   SELECT 1
		   FROM role_permissions rp
		   JOIN permissions p ON p.id = rp.permission_id
		   WHERE rp.role=$1 AND p.key=$2
		     AND (rp.business_id=$3 OR
		          (rp.business_id IS NULL AND NOT EXISTS (
		             SELECT 1 FROM role_permissions rp2 WHERE rp2.role=$1 AND rp2.business_id=$3
		          )))
		 )`,
		claims.Role, key, bizID).Scan(&allowed)
	if err != nil {
		h.log.Error("permission check", zap.String("key", key), zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "permission_check_failed")
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditAccessDenied,
			EntityType: "review_request",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respondErr(w, http.StatusForbidden, "forbidden:"+key)
		return false
	}
	return true
}

// newToken returns a 32-byte random URL-safe string.
func newToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func isStatusTransitionError(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "invalid_status_transition")
}

func decodeStrict(r *http.Request, dst interface{}) error {
	r.Body = http.MaxBytesReader(nil, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			return errors.New("body_too_large")
		}
		if errors.Is(err, io.EOF) {
			return errors.New("empty_body")
		}
		return errors.New("invalid_request")
	}
	if dec.More() {
		return errors.New("trailing_data")
	}
	return nil
}

func jsonOrEmpty(v map[string]interface{}) []byte {
	if v == nil {
		return []byte("{}")
	}
	b, err := json.Marshal(v)
	if err != nil || len(b) == 0 {
		return []byte("{}")
	}
	return b
}

func nullStr(s string) interface{} {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	return s
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func respond(w http.ResponseWriter, code int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if body != nil {
		_ = json.NewEncoder(w).Encode(body)
	}
}

func respondErr(w http.ResponseWriter, code int, msg string) {
	respond(w, code, map[string]string{"error": msg})
}
