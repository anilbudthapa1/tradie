package quotes

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
	"github.com/tradie/api/internal/models"
)

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── List ──────────────────────────────────────────────────────
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, _ := h.db.Query(r.Context(),
		`SELECT id, business_id, quote_number, status, customer_id, title, subtotal, discount_amount, gst_amount, total, created_at, updated_at
		 FROM quotes WHERE business_id=$1 AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 100`, bizID)
	defer rows.Close()
	var list []models.Quote
	for rows.Next() {
		var q models.Quote
		_ = rows.Scan(&q.ID, &q.BusinessID, &q.QuoteNumber, &q.Status, &q.CustomerID, &q.Title,
			&q.Subtotal, &q.DiscountAmount, &q.GSTAmount, &q.Total, &q.CreatedAt, &q.UpdatedAt)
		list = append(list, q)
	}
	if list == nil {
		list = []models.Quote{}
	}
	respond(w, 200, list)
}

// ── Create ────────────────────────────────────────────────────
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	var req struct {
		CustomerID string `json:"customer_id"`
		Title      string `json:"title"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	var nextNum int
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(next_quote_number, 1001) FROM business_invoice_settings WHERE business_id=$1`, bizID).Scan(&nextNum)
	quoteNumber := "QT-" + fmt.Sprintf("%04d", nextNum)

	var q models.Quote
	_ = h.db.QueryRow(r.Context(),
		`INSERT INTO quotes (business_id, quote_number, customer_id, title, created_by)
		 VALUES ($1,$2,$3,$4,$5)
		 RETURNING id, business_id, quote_number, status, customer_id, title, subtotal, gst_amount, total, created_at, updated_at`,
		bizID, quoteNumber, req.CustomerID, req.Title, claims.UserID,
	).Scan(&q.ID, &q.BusinessID, &q.QuoteNumber, &q.Status, &q.CustomerID, &q.Title,
		&q.Subtotal, &q.GSTAmount, &q.Total, &q.CreatedAt, &q.UpdatedAt)
	// Increment quote number
	_, _ = h.db.Exec(r.Context(),
		`UPDATE business_invoice_settings SET next_quote_number=next_quote_number+1 WHERE business_id=$1`, bizID)
	respond(w, 201, q)
}

// ── Get ───────────────────────────────────────────────────────
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var q models.Quote
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, quote_number, status, customer_id, title, subtotal, discount_amount, gst_amount, total, valid_until, created_at, updated_at
		 FROM quotes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&q.ID, &q.BusinessID, &q.QuoteNumber, &q.Status, &q.CustomerID, &q.Title,
		&q.Subtotal, &q.DiscountAmount, &q.GSTAmount, &q.Total, &q.ValidUntil, &q.CreatedAt, &q.UpdatedAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, q)
}

// ── Update ────────────────────────────────────────────────────
// PATCH /quotes/{id}
// Allowed fields: title, description, valid_until, discount_amount.
// Recalculates gst_amount and total from line_items after update.
// Only allowed in draft/sent status.
func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	// Check existence and status
	var currentStatus string
	err := h.db.QueryRow(r.Context(),
		`SELECT status FROM quotes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&currentStatus)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if currentStatus != "draft" && currentStatus != "sent" {
		respond(w, 422, map[string]string{"error": "can_only_update_draft_or_sent_quotes"})
		return
	}

	var req struct {
		Title          *string    `json:"title"`
		Description    *string    `json:"description"`
		ValidUntil     *time.Time `json:"valid_until"`
		DiscountAmount *float64   `json:"discount_amount"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// Apply field updates
	if req.Title != nil {
		_, _ = h.db.Exec(r.Context(),
			`UPDATE quotes SET title=$1, updated_at=NOW() WHERE id=$2 AND business_id=$3`,
			*req.Title, id, bizID)
	}
	if req.Description != nil {
		_, _ = h.db.Exec(r.Context(),
			`UPDATE quotes SET description=$1, updated_at=NOW() WHERE id=$2 AND business_id=$3`,
			*req.Description, id, bizID)
	}
	if req.ValidUntil != nil {
		_, _ = h.db.Exec(r.Context(),
			`UPDATE quotes SET valid_until=$1, updated_at=NOW() WHERE id=$2 AND business_id=$3`,
			*req.ValidUntil, id, bizID)
	}
	if req.DiscountAmount != nil {
		claims := middleware.ClaimsFromCtx(r.Context())
		var subtotal float64
		_ = h.db.QueryRow(r.Context(),
			`SELECT COALESCE(subtotal, 0) FROM quotes WHERE id=$1 AND business_id=$2`,
			id, bizID,
		).Scan(&subtotal)
		capped := clampDiscount(claims.Role, subtotal, *req.DiscountAmount)
		_, _ = h.db.Exec(r.Context(),
			`UPDATE quotes SET discount_amount=$1, updated_at=NOW() WHERE id=$2 AND business_id=$3`,
			capped, id, bizID)
	}

	// Recalculate totals from line_items
	if err := h.recalcTotals(r, id, bizID.String()); err != nil {
		h.log.Warn("recalcTotals failed on update", zap.String("quote_id", id), zap.Error(err))
	}

	// Return updated quote
	var q models.Quote
	_ = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, quote_number, status, customer_id, title, subtotal, discount_amount, gst_amount, total, valid_until, created_at, updated_at
		 FROM quotes WHERE id=$1 AND business_id=$2`, id, bizID,
	).Scan(&q.ID, &q.BusinessID, &q.QuoteNumber, &q.Status, &q.CustomerID, &q.Title,
		&q.Subtotal, &q.DiscountAmount, &q.GSTAmount, &q.Total, &q.ValidUntil, &q.CreatedAt, &q.UpdatedAt)
	respond(w, 200, q)
}

// ── Delete ────────────────────────────────────────────────────
// DELETE /quotes/{id}
// Soft delete — sets deleted_at. Only allowed when status=draft.
func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var quoteID uuid.UUID
	var status string
	err := h.db.QueryRow(r.Context(),
		`SELECT id, status FROM quotes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&quoteID, &status)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if status != "draft" {
		respond(w, 422, map[string]string{"error": "only_draft_quotes_can_be_deleted"})
		return
	}

	_, err = h.db.Exec(r.Context(),
		`UPDATE quotes SET deleted_at=NOW(), updated_at=NOW() WHERE id=$1 AND business_id=$2`,
		quoteID, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "delete_failed"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "quote.deleted",
		EntityType: "quote",
		EntityID:   quoteID,
		IPAddress:  r.RemoteAddr,
	})

	respond(w, 204, nil)
}

// ── Send ──────────────────────────────────────────────────────
// POST /quotes/{id}/send
// Sets status=sent, sent_at=NOW(). Records audit event.
func (h *Handler) Send(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var quoteID uuid.UUID
	var status string
	err := h.db.QueryRow(r.Context(),
		`SELECT id, status FROM quotes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&quoteID, &status)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if status != "draft" {
		respond(w, 422, map[string]string{"error": "only_draft_quotes_can_be_sent"})
		return
	}

	var q models.Quote
	err = h.db.QueryRow(r.Context(),
		`UPDATE quotes SET status='sent', sent_at=NOW(), updated_at=NOW()
		 WHERE id=$1 AND business_id=$2
		 RETURNING id, business_id, quote_number, status, customer_id, title, subtotal, discount_amount, gst_amount, total, valid_until, created_at, updated_at`,
		quoteID, bizID,
	).Scan(&q.ID, &q.BusinessID, &q.QuoteNumber, &q.Status, &q.CustomerID, &q.Title,
		&q.Subtotal, &q.DiscountAmount, &q.GSTAmount, &q.Total, &q.ValidUntil, &q.CreatedAt, &q.UpdatedAt)
	if err != nil {
		respond(w, 500, map[string]string{"error": "send_failed"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "quote.sent",
		EntityType: "quote",
		EntityID:   quoteID,
		IPAddress:  r.RemoteAddr,
	})

	respond(w, 200, q)
}

// ── ConvertToJob ──────────────────────────────────────────────
// POST /quotes/{id}/convert-to-job
// Creates a job from the quote, sets quote status=converted, returns new job id.
func (h *Handler) ConvertToJob(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var quoteID uuid.UUID
	var status, title string
	var customerID uuid.UUID
	var description *string
	err := h.db.QueryRow(r.Context(),
		`SELECT id, status, title, customer_id, description
		 FROM quotes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&quoteID, &status, &title, &customerID, &description)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if status != "approved" && status != "sent" {
		respond(w, 422, map[string]string{"error": "quote_must_be_approved_or_sent_to_convert"})
		return
	}

	// Generate job number
	var nextJobNum int
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(MAX(CAST(SUBSTRING(job_number FROM 4) AS INTEGER)), 1000) + 1
		 FROM jobs WHERE business_id=$1`, bizID).Scan(&nextJobNum)
	jobNumber := fmt.Sprintf("JB-%04d", nextJobNum)

	// Insert job
	var jobID uuid.UUID
	err = h.db.QueryRow(r.Context(),
		`INSERT INTO jobs (business_id, job_number, title, description, customer_id, created_by)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 RETURNING id`,
		bizID, jobNumber, title, description, customerID, claims.UserID,
	).Scan(&jobID)
	if err != nil {
		h.log.Error("convert_to_job: insert job failed", zap.Error(err))
		respond(w, 500, map[string]string{"error": "job_creation_failed"})
		return
	}

	// Update quote status
	_, err = h.db.Exec(r.Context(),
		`UPDATE quotes SET status='converted', converted_job_id=$1, updated_at=NOW()
		 WHERE id=$2 AND business_id=$3`,
		jobID, quoteID, bizID)
	if err != nil {
		h.log.Error("convert_to_job: update quote failed", zap.Error(err))
		respond(w, 500, map[string]string{"error": "quote_update_failed"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "quote.converted_to_job",
		EntityType: "quote",
		EntityID:   quoteID,
		NewData:    map[string]string{"job_id": jobID.String()},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, 200, map[string]string{"job_id": jobID.String(), "job_number": jobNumber})
}

// ── GeneratePDF ───────────────────────────────────────────────
// GET /quotes/{id}/pdf
// Returns structured JSON for client-side PDF rendering.
func (h *Handler) GeneratePDF(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	// Fetch quote
	var q models.Quote
	var description *string
	var sentAt, approvedAt, validUntil *time.Time
	var publicToken *string
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, quote_number, status, customer_id, title, subtotal,
		        discount_amount, gst_amount, total, valid_until, sent_at, approved_at,
		        description, public_token, created_at, updated_at
		 FROM quotes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&q.ID, &q.BusinessID, &q.QuoteNumber, &q.Status, &q.CustomerID, &q.Title,
		&q.Subtotal, &q.DiscountAmount, &q.GSTAmount, &q.Total,
		&validUntil, &sentAt, &approvedAt, &description, &publicToken,
		&q.CreatedAt, &q.UpdatedAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	// Fetch line items
	liRows, _ := h.db.Query(r.Context(),
		`SELECT id, description, quantity, unit_price, tax_rate, line_total
		 FROM quote_line_items WHERE quote_id=$1 AND business_id=$2 ORDER BY created_at`, id, bizID)
	defer liRows.Close()
	type lineItemDTO struct {
		ID          uuid.UUID `json:"id"`
		Description string    `json:"description"`
		Quantity    float64   `json:"quantity"`
		UnitPrice   float64   `json:"unit_price"`
		TaxRate     float64   `json:"tax_rate"`
		LineTotal   float64   `json:"line_total"`
	}
	var lineItems []lineItemDTO
	for liRows.Next() {
		var li lineItemDTO
		_ = liRows.Scan(&li.ID, &li.Description, &li.Quantity, &li.UnitPrice, &li.TaxRate, &li.LineTotal)
		lineItems = append(lineItems, li)
	}
	if lineItems == nil {
		lineItems = []lineItemDTO{}
	}

	// Fetch business info
	type businessDTO struct {
		Name     string  `json:"name"`
		ABN      *string `json:"abn,omitempty"`
		Phone    *string `json:"phone,omitempty"`
		Email    *string `json:"email,omitempty"`
		Address  *string `json:"address,omitempty"`
		City     *string `json:"city,omitempty"`
		State    *string `json:"state,omitempty"`
		Postcode *string `json:"postcode,omitempty"`
		LogoURL  *string `json:"logo_url,omitempty"`
	}
	var biz businessDTO
	_ = h.db.QueryRow(r.Context(),
		`SELECT name, abn, phone, email, address_line1, city, state, postcode, logo_url
		 FROM businesses WHERE id=$1`, bizID,
	).Scan(&biz.Name, &biz.ABN, &biz.Phone, &biz.Email, &biz.Address, &biz.City, &biz.State, &biz.Postcode, &biz.LogoURL)

	// Fetch customer info
	type customerDTO struct {
		FirstName   string  `json:"first_name"`
		LastName    *string `json:"last_name,omitempty"`
		CompanyName *string `json:"company_name,omitempty"`
		Email       *string `json:"email,omitempty"`
		Phone       *string `json:"phone,omitempty"`
	}
	var cust customerDTO
	_ = h.db.QueryRow(r.Context(),
		`SELECT first_name, last_name, company_name, email, phone
		 FROM customers WHERE id=$1 AND business_id=$2`, q.CustomerID, bizID,
	).Scan(&cust.FirstName, &cust.LastName, &cust.CompanyName, &cust.Email, &cust.Phone)

	respond(w, 200, map[string]interface{}{
		"quote": map[string]interface{}{
			"id":              q.ID,
			"quote_number":    q.QuoteNumber,
			"status":          q.Status,
			"title":           q.Title,
			"description":     description,
			"subtotal":        q.Subtotal,
			"discount_amount": q.DiscountAmount,
			"gst_amount":      q.GSTAmount,
			"total":           q.Total,
			"valid_until":     validUntil,
			"sent_at":         sentAt,
			"approved_at":     approvedAt,
			"public_token":    publicToken,
			"created_at":      q.CreatedAt,
		},
		"line_items": lineItems,
		"business":   biz,
		"customer":   cust,
	})
}

// ── ListTemplates ─────────────────────────────────────────────
// GET /quotes/templates
func (h *Handler) ListTemplates(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, name, description, items, created_by, created_at, updated_at
		 FROM quote_templates WHERE business_id=$1 ORDER BY name`, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	type templateDTO struct {
		ID          uuid.UUID       `json:"id"`
		BusinessID  uuid.UUID       `json:"business_id"`
		Name        string          `json:"name"`
		Description *string         `json:"description,omitempty"`
		Items       json.RawMessage `json:"items"`
		CreatedBy   uuid.UUID       `json:"created_by"`
		CreatedAt   time.Time       `json:"created_at"`
		UpdatedAt   time.Time       `json:"updated_at"`
	}
	var list []templateDTO
	for rows.Next() {
		var t templateDTO
		_ = rows.Scan(&t.ID, &t.BusinessID, &t.Name, &t.Description, &t.Items, &t.CreatedBy, &t.CreatedAt, &t.UpdatedAt)
		list = append(list, t)
	}
	if list == nil {
		list = []templateDTO{}
	}
	respond(w, 200, list)
}

// ── CreateTemplate ────────────────────────────────────────────
// POST /quotes/templates
func (h *Handler) CreateTemplate(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		Name        string          `json:"name"`
		Description *string         `json:"description"`
		Items       json.RawMessage `json:"items"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if req.Name == "" {
		respond(w, 400, map[string]string{"error": "name_required"})
		return
	}
	if req.Items == nil {
		req.Items = json.RawMessage("[]")
	}

	type templateDTO struct {
		ID          uuid.UUID       `json:"id"`
		BusinessID  uuid.UUID       `json:"business_id"`
		Name        string          `json:"name"`
		Description *string         `json:"description,omitempty"`
		Items       json.RawMessage `json:"items"`
		CreatedBy   uuid.UUID       `json:"created_by"`
		CreatedAt   time.Time       `json:"created_at"`
		UpdatedAt   time.Time       `json:"updated_at"`
	}
	var t templateDTO
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO quote_templates (business_id, name, description, items, created_by)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING id, business_id, name, description, items, created_by, created_at, updated_at`,
		bizID, req.Name, req.Description, req.Items, claims.UserID,
	).Scan(&t.ID, &t.BusinessID, &t.Name, &t.Description, &t.Items, &t.CreatedBy, &t.CreatedAt, &t.UpdatedAt)
	if err != nil {
		h.log.Error("create_template failed", zap.Error(err))
		respond(w, 500, map[string]string{"error": "create_failed"})
		return
	}
	respond(w, 201, t)
}

// ── PublicGet ─────────────────────────────────────────────────
// GET /public/quotes/{token}
// No auth — fetch quote by public_token.
func (h *Handler) PublicGet(w http.ResponseWriter, r *http.Request) {
	token := chi.URLParam(r, "token")

	var q models.Quote
	var description *string
	var validUntil, sentAt, approvedAt *time.Time
	var customerSignature *json.RawMessage
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, quote_number, status, customer_id, title,
		        subtotal, discount_amount, gst_amount, total,
		        valid_until, sent_at, approved_at, description, customer_signature, created_at
		 FROM quotes WHERE public_token=$1 AND deleted_at IS NULL`, token,
	).Scan(&q.ID, &q.BusinessID, &q.QuoteNumber, &q.Status, &q.CustomerID, &q.Title,
		&q.Subtotal, &q.DiscountAmount, &q.GSTAmount, &q.Total,
		&validUntil, &sentAt, &approvedAt, &description, &customerSignature, &q.CreatedAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	// Fetch line items
	liRows, _ := h.db.Query(r.Context(),
		`SELECT id, description, quantity, unit_price, tax_rate, line_total
		 FROM quote_line_items WHERE quote_id=$1 ORDER BY created_at`, q.ID)
	defer liRows.Close()
	type lineItemDTO struct {
		ID          uuid.UUID `json:"id"`
		Description string    `json:"description"`
		Quantity    float64   `json:"quantity"`
		UnitPrice   float64   `json:"unit_price"`
		TaxRate     float64   `json:"tax_rate"`
		LineTotal   float64   `json:"line_total"`
	}
	var lineItems []lineItemDTO
	for liRows.Next() {
		var li lineItemDTO
		_ = liRows.Scan(&li.ID, &li.Description, &li.Quantity, &li.UnitPrice, &li.TaxRate, &li.LineTotal)
		lineItems = append(lineItems, li)
	}
	if lineItems == nil {
		lineItems = []lineItemDTO{}
	}

	// Fetch business info (public fields only)
	type businessDTO struct {
		Name     string  `json:"name"`
		ABN      *string `json:"abn,omitempty"`
		Phone    *string `json:"phone,omitempty"`
		Email    *string `json:"email,omitempty"`
		LogoURL  *string `json:"logo_url,omitempty"`
	}
	var biz businessDTO
	_ = h.db.QueryRow(r.Context(),
		`SELECT name, abn, phone, email, logo_url FROM businesses WHERE id=$1`, q.BusinessID,
	).Scan(&biz.Name, &biz.ABN, &biz.Phone, &biz.Email, &biz.LogoURL)

	respond(w, 200, map[string]interface{}{
		"quote": map[string]interface{}{
			"id":                 q.ID,
			"quote_number":       q.QuoteNumber,
			"status":             q.Status,
			"title":              q.Title,
			"description":        description,
			"subtotal":           q.Subtotal,
			"discount_amount":    q.DiscountAmount,
			"gst_amount":         q.GSTAmount,
			"total":              q.Total,
			"valid_until":        validUntil,
			"approved_at":        approvedAt,
			"customer_signature": customerSignature,
			"created_at":         q.CreatedAt,
		},
		"line_items": lineItems,
		"business":   biz,
	})
}

// ── PublicApprove ─────────────────────────────────────────────
// POST /public/quotes/{token}/approve
// Customer approves quote — sets status=approved, approved_at, customer_signature JSONB.
func (h *Handler) PublicApprove(w http.ResponseWriter, r *http.Request) {
	token := chi.URLParam(r, "token")

	var req struct {
		CustomerSignature json.RawMessage `json:"customer_signature"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	var quoteID uuid.UUID
	var bizID uuid.UUID
	var status string
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, status FROM quotes WHERE public_token=$1 AND deleted_at IS NULL`, token,
	).Scan(&quoteID, &bizID, &status)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if status != "sent" {
		respond(w, 422, map[string]string{"error": "quote_not_in_sent_status"})
		return
	}

	var sig interface{}
	if len(req.CustomerSignature) > 0 {
		sig = req.CustomerSignature
	}

	_, err = h.db.Exec(r.Context(),
		`UPDATE quotes SET status='approved', approved_at=NOW(), customer_signature=$1, updated_at=NOW()
		 WHERE id=$2`, sig, quoteID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "approve_failed"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		Action:     "quote.approved_by_customer",
		EntityType: "quote",
		EntityID:   quoteID,
		IPAddress:  r.RemoteAddr,
	})

	respond(w, 200, map[string]string{"status": "approved"})
}

// ── PublicReject ──────────────────────────────────────────────
// POST /public/quotes/{token}/reject
// Customer rejects quote — sets status=rejected, rejection_reason.
func (h *Handler) PublicReject(w http.ResponseWriter, r *http.Request) {
	token := chi.URLParam(r, "token")

	var req struct {
		RejectionReason string `json:"rejection_reason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	var quoteID uuid.UUID
	var bizID uuid.UUID
	var status string
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, status FROM quotes WHERE public_token=$1 AND deleted_at IS NULL`, token,
	).Scan(&quoteID, &bizID, &status)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if status != "sent" {
		respond(w, 422, map[string]string{"error": "quote_not_in_sent_status"})
		return
	}

	var reason interface{}
	if req.RejectionReason != "" {
		reason = req.RejectionReason
	}

	_, err = h.db.Exec(r.Context(),
		`UPDATE quotes SET status='rejected', rejection_reason=$1, updated_at=NOW()
		 WHERE id=$2`, reason, quoteID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "reject_failed"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		Action:     "quote.rejected_by_customer",
		EntityType: "quote",
		EntityID:   quoteID,
		NewData:    map[string]string{"reason": req.RejectionReason},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, 200, map[string]string{"status": "rejected"})
}

// ── AddLineItem ───────────────────────────────────────────────
// POST /quotes/{id}/line-items
// Adds a line item to quote_line_items and recalculates totals.
func (h *Handler) AddLineItem(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Description string  `json:"description"`
		Quantity    float64 `json:"quantity"`
		UnitPrice   float64 `json:"unit_price"`
		TaxRate     float64 `json:"tax_rate"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if req.Description == "" {
		respond(w, 400, map[string]string{"error": "description_required"})
		return
	}
	if req.Quantity <= 0 {
		req.Quantity = 1
	}
	if req.TaxRate == 0 {
		req.TaxRate = h.businessGSTRate(r, bizID)
	}

	// Verify quote belongs to business and is editable
	var status string
	err := h.db.QueryRow(r.Context(),
		`SELECT status FROM quotes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&status)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if status != "draft" && status != "sent" {
		respond(w, 422, map[string]string{"error": "cannot_modify_line_items_on_this_quote"})
		return
	}

	lineTotal := math.Round(req.Quantity*req.UnitPrice*100) / 100

	type lineItemDTO struct {
		ID          uuid.UUID `json:"id"`
		QuoteID     uuid.UUID `json:"quote_id"`
		BusinessID  uuid.UUID `json:"business_id"`
		Description string    `json:"description"`
		Quantity    float64   `json:"quantity"`
		UnitPrice   float64   `json:"unit_price"`
		TaxRate     float64   `json:"tax_rate"`
		LineTotal   float64   `json:"line_total"`
		CreatedAt   time.Time `json:"created_at"`
	}
	var li lineItemDTO
	err = h.db.QueryRow(r.Context(),
		`INSERT INTO quote_line_items (quote_id, business_id, description, quantity, unit_price, tax_rate, line_total)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)
		 RETURNING id, quote_id, business_id, description, quantity, unit_price, tax_rate, line_total, created_at`,
		id, bizID, req.Description, req.Quantity, req.UnitPrice, req.TaxRate, lineTotal,
	).Scan(&li.ID, &li.QuoteID, &li.BusinessID, &li.Description, &li.Quantity, &li.UnitPrice, &li.TaxRate, &li.LineTotal, &li.CreatedAt)
	if err != nil {
		h.log.Error("add_line_item: insert failed", zap.Error(err))
		respond(w, 500, map[string]string{"error": "insert_failed"})
		return
	}

	if err := h.recalcTotals(r, id, bizID.String()); err != nil {
		h.log.Warn("recalcTotals failed on add_line_item", zap.String("quote_id", id), zap.Error(err))
	}

	respond(w, 201, li)
}

// ── RemoveLineItem ────────────────────────────────────────────
// DELETE /quotes/{id}/line-items/{item_id}
// Removes a line item and recalculates totals.
func (h *Handler) RemoveLineItem(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	itemID := chi.URLParam(r, "item_id")

	// Verify quote belongs to business and is editable
	var status string
	err := h.db.QueryRow(r.Context(),
		`SELECT status FROM quotes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&status)
	if err != nil {
		respond(w, 404, map[string]string{"error": "quote_not_found"})
		return
	}
	if status != "draft" && status != "sent" {
		respond(w, 422, map[string]string{"error": "cannot_modify_line_items_on_this_quote"})
		return
	}

	ct, err := h.db.Exec(r.Context(),
		`DELETE FROM quote_line_items WHERE id=$1 AND quote_id=$2 AND business_id=$3`,
		itemID, id, bizID)
	if err != nil || ct.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "line_item_not_found"})
		return
	}

	if err := h.recalcTotals(r, id, bizID.String()); err != nil {
		h.log.Warn("recalcTotals failed on remove_line_item", zap.String("quote_id", id), zap.Error(err))
	}

	respond(w, 204, nil)
}

// ── ApplyDiscount ─────────────────────────────────────────────
// POST /quotes/{id}/discount
// Applies a discount by amount or percentage to a quote and recalculates totals.
func (h *Handler) ApplyDiscount(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		DiscountAmount     *float64 `json:"discount_amount"`
		DiscountPercentage *float64 `json:"discount_percentage"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if req.DiscountAmount == nil && req.DiscountPercentage == nil {
		respond(w, 400, map[string]string{"error": "discount_amount_or_percentage_required"})
		return
	}

	// Verify quote exists and is editable
	var status string
	var currentSubtotal float64
	err := h.db.QueryRow(r.Context(),
		`SELECT status, subtotal FROM quotes WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&status, &currentSubtotal)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	if status != "draft" && status != "sent" {
		respond(w, 422, map[string]string{"error": "cannot_apply_discount_on_this_quote"})
		return
	}

	var discountAmount float64
	if req.DiscountAmount != nil {
		discountAmount = *req.DiscountAmount
	} else if req.DiscountPercentage != nil {
		pct := *req.DiscountPercentage
		if pct < 0 || pct > 100 {
			respond(w, 400, map[string]string{"error": "discount_percentage_must_be_0_to_100"})
			return
		}
		discountAmount = math.Round(currentSubtotal*pct/100*100) / 100
	}
	claims := middleware.ClaimsFromCtx(r.Context())
	discountAmount = clampDiscount(claims.Role, currentSubtotal, discountAmount)

	_, err = h.db.Exec(r.Context(),
		`UPDATE quotes SET discount_amount=$1, updated_at=NOW() WHERE id=$2 AND business_id=$3`,
		discountAmount, id, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "update_failed"})
		return
	}

	if err := h.recalcTotals(r, id, bizID.String()); err != nil {
		h.log.Warn("recalcTotals failed on apply_discount", zap.String("quote_id", id), zap.Error(err))
	}

	var q models.Quote
	_ = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, quote_number, status, customer_id, title, subtotal, discount_amount, gst_amount, total, valid_until, created_at, updated_at
		 FROM quotes WHERE id=$1 AND business_id=$2`, id, bizID,
	).Scan(&q.ID, &q.BusinessID, &q.QuoteNumber, &q.Status, &q.CustomerID, &q.Title,
		&q.Subtotal, &q.DiscountAmount, &q.GSTAmount, &q.Total, &q.ValidUntil, &q.CreatedAt, &q.UpdatedAt)
	respond(w, 200, q)
}

// businessGSTRate returns the tenant's GST rate as a decimal (0.10 for 10%).
// Falls back to 0.10 if no business_tax_settings row exists for the tenant.
func (h *Handler) businessGSTRate(r *http.Request, bizID interface{}) float64 {
	var pct float64
	err := h.db.QueryRow(r.Context(),
		`SELECT COALESCE(gst_rate, 10.00) FROM business_tax_settings WHERE business_id=$1`,
		bizID,
	).Scan(&pct)
	if err != nil {
		return 0.10
	}
	return pct / 100.0
}

// clampDiscount caps a requested discount amount to a fraction of subtotal
// based on caller role: owner up to 100%, admin up to 50%, manager up to 25%,
// any other role 0%. Negative requested amounts are coerced to zero.
// Server-side enforcement so frontend cannot apply a 100% discount.
func clampDiscount(role string, subtotal, requested float64) float64 {
	if requested < 0 {
		return 0
	}
	var maxFrac float64
	switch role {
	case "owner":
		maxFrac = 1.0
	case "admin":
		maxFrac = 0.5
	case "manager":
		maxFrac = 0.25
	default:
		maxFrac = 0
	}
	maxAllowed := subtotal * maxFrac
	if requested > maxAllowed {
		return maxAllowed
	}
	return requested
}

// ── recalcTotals ──────────────────────────────────────────────
// Internal helper: recalculates subtotal, gst_amount, and total
// from quote_line_items and current discount_amount, then persists.
func (h *Handler) recalcTotals(r *http.Request, quoteID, bizID string) error {
	// Sum line item totals
	var subtotal float64
	err := h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(line_total), 0) FROM quote_line_items WHERE quote_id=$1 AND business_id=$2`,
		quoteID, bizID,
	).Scan(&subtotal)
	if err != nil {
		return err
	}

	// Fetch current discount
	var discountAmount float64
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(discount_amount, 0) FROM quotes WHERE id=$1`, quoteID,
	).Scan(&discountAmount)

	taxableAmount := subtotal - discountAmount
	if taxableAmount < 0 {
		taxableAmount = 0
	}

	// Weighted average tax rate across all line items for accurate GST
	var weightedGST float64
	err = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(line_total * tax_rate), 0) FROM quote_line_items WHERE quote_id=$1 AND business_id=$2`,
		quoteID, bizID,
	).Scan(&weightedGST)
	if err != nil {
		return err
	}

	// GST is proportionally discounted
	var gstAmount float64
	if subtotal > 0 {
		gstAmount = math.Round(weightedGST*(taxableAmount/subtotal)*100) / 100
	}
	total := math.Round((taxableAmount+gstAmount)*100) / 100
	subtotal = math.Round(subtotal*100) / 100

	_, err = h.db.Exec(r.Context(),
		`UPDATE quotes SET subtotal=$1, gst_amount=$2, total=$3, updated_at=NOW()
		 WHERE id=$4`,
		subtotal, gstAmount, total, quoteID)
	return err
}

// ── respond ───────────────────────────────────────────────────
func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
