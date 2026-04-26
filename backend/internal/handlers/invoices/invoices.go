package invoices

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stripe/stripe-go/v79"
	"github.com/stripe/stripe-go/v79/checkout/session"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
	"github.com/tradie/api/internal/models"
	"github.com/tradie/api/internal/services/email"
)

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

// ── List ───────────────────────────────────────────────────────
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	status := r.URL.Query().Get("status")
	customerID := r.URL.Query().Get("customer_id")

	const limit = 50
	const page = 1
	offset := (page - 1) * limit

	args := []interface{}{bizID}
	where := "WHERE i.business_id=$1 AND i.deleted_at IS NULL"
	idx := 2

	if status != "" {
		where += fmt.Sprintf(" AND i.status=$%d", idx)
		args = append(args, status)
		idx++
	}
	if customerID != "" {
		where += fmt.Sprintf(" AND i.customer_id=$%d", idx)
		args = append(args, customerID)
		idx++
	}

	args = append(args, limit, offset)
	limitIdx := idx
	offsetIdx := idx + 1

	query := fmt.Sprintf(`
		SELECT i.id, i.invoice_number, i.status, i.total_amount, i.amount_paid,
		       i.amount_due, i.due_date, i.sent_at, i.paid_at, i.created_at,
		       COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer_name
		FROM invoices i
		LEFT JOIN customers c ON c.id=i.customer_id
		%s
		ORDER BY i.created_at DESC LIMIT $%d OFFSET $%d`,
		where, limitIdx, offsetIdx)

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		h.log.Error("invoices.List query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	defer rows.Close()

	type InvoiceRow struct {
		ID            string     `json:"id"`
		InvoiceNumber string     `json:"invoice_number"`
		Status        string     `json:"status"`
		TotalAmount   float64    `json:"total_amount"`
		AmountPaid    float64    `json:"amount_paid"`
		AmountDue     float64    `json:"amount_due"`
		DueDate       *time.Time `json:"due_date,omitempty"`
		SentAt        *time.Time `json:"sent_at,omitempty"`
		PaidAt        *time.Time `json:"paid_at,omitempty"`
		CreatedAt     time.Time  `json:"created_at"`
		CustomerName  string     `json:"customer_name"`
	}

	list := []InvoiceRow{}
	for rows.Next() {
		var row InvoiceRow
		if err := rows.Scan(
			&row.ID, &row.InvoiceNumber, &row.Status,
			&row.TotalAmount, &row.AmountPaid, &row.AmountDue,
			&row.DueDate, &row.SentAt, &row.PaidAt,
			&row.CreatedAt, &row.CustomerName,
		); err != nil {
			h.log.Error("invoices.List scan", zap.Error(err))
			continue
		}
		list = append(list, row)
	}

	respond(w, 200, map[string]interface{}{
		"data": list,
		"meta": map[string]int{"page": page, "limit": limit},
	})
}

// ── Create ─────────────────────────────────────────────────────
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		CustomerID string `json:"customer_id"`
		JobID      string `json:"job_id"`
		Title      string `json:"title"`
		DueDate    string `json:"due_date"`
		Notes      string `json:"notes"`
		LineItems  []struct {
			Description string  `json:"description"`
			Quantity    float64 `json:"quantity"`
			UnitPrice   float64 `json:"unit_price"`
			TaxRate     float64 `json:"tax_rate"`
		} `json:"line_items"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_body"})
		return
	}
	if req.CustomerID == "" {
		respond(w, 400, map[string]string{"error": "customer_id required"})
		return
	}

	// Verify customer (and optional job) belong to caller's tenant before
	// any write — otherwise an attacker could pollute their own invoices
	// with cross-tenant references that leak via cascading reads.
	var customerOK bool
	_ = h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM customers
		                 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		req.CustomerID, bizID,
	).Scan(&customerOK)
	if !customerOK {
		respond(w, 404, map[string]string{"error": "customer_not_found"})
		return
	}
	if req.JobID != "" {
		var jobOK bool
		_ = h.db.QueryRow(r.Context(),
			`SELECT EXISTS(SELECT 1 FROM jobs
			                 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
			req.JobID, bizID,
		).Scan(&jobOK)
		if !jobOK {
			respond(w, 404, map[string]string{"error": "job_not_found"})
			return
		}
	}

	// Calculate totals
	var subtotal, gstAmount float64
	for _, li := range req.LineItems {
		lineSubtotal := li.Quantity * li.UnitPrice
		subtotal += lineSubtotal
		gstAmount += lineSubtotal * li.TaxRate
	}
	total := subtotal + gstAmount

	// Generate invoice number from count
	var count int
	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM invoices WHERE business_id=$1`, bizID,
	).Scan(&count)
	invNumber := fmt.Sprintf("INV-%04d", count+1001)

	// Parse optional due date
	var dueDate *time.Time
	if req.DueDate != "" {
		if parsed, err := time.Parse("2006-01-02", req.DueDate); err == nil {
			dueDate = &parsed
		}
	}

	// Insert invoice
	var inv models.Invoice
	err := h.db.QueryRow(r.Context(), `
		INSERT INTO invoices
		  (business_id, invoice_number, customer_id, job_id, title,
		   subtotal, tax_amount, total_amount, amount_due, due_date, notes, created_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
		RETURNING id, invoice_number, status, total_amount, amount_due, due_date, created_at`,
		bizID, invNumber, req.CustomerID, nullUUID(req.JobID), req.Title,
		subtotal, gstAmount, total, total, dueDate, nullStr(req.Notes), claims.UserID,
	).Scan(&inv.ID, &inv.InvoiceNumber, &inv.Status, &inv.Total, &inv.AmountDue, &inv.DueDate, &inv.CreatedAt)
	if err != nil {
		h.log.Error("invoices.Create insert", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}

	// Insert line items (skip zero-quantity/price entries)
	for _, li := range req.LineItems {
		if li.Quantity == 0 && li.UnitPrice == 0 {
			continue
		}
		lineTotal := li.Quantity * li.UnitPrice
		_, _ = h.db.Exec(r.Context(), `
			INSERT INTO invoice_line_items
			  (invoice_id, description, quantity, unit_price, tax_rate, line_total)
			VALUES ($1,$2,$3,$4,$5,$6)`,
			inv.ID, li.Description, li.Quantity, li.UnitPrice, li.TaxRate, lineTotal,
		)
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "create",
		EntityType: "invoice",
		EntityID:   inv.ID,
	})

	respond(w, 201, inv)
}

// ── Get ────────────────────────────────────────────────────────
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var inv models.Invoice
	err := h.db.QueryRow(r.Context(), `
		SELECT i.id, i.business_id, i.invoice_number, i.status,
		       i.customer_id, i.job_id, i.subtotal, i.tax_amount, i.total_amount,
		       i.amount_paid, i.amount_due, i.due_date, i.sent_at, i.paid_at,
		       i.notes, i.created_at, i.updated_at,
		       COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer_name
		FROM invoices i
		LEFT JOIN customers c ON c.id=i.customer_id
		WHERE i.id=$1 AND i.business_id=$2 AND i.deleted_at IS NULL`,
		id, bizID,
	).Scan(
		&inv.ID, &inv.BusinessID, &inv.InvoiceNumber, &inv.Status,
		&inv.CustomerID, &inv.JobID, &inv.Subtotal, &inv.GSTAmount, &inv.Total,
		&inv.AmountPaid, &inv.AmountDue, &inv.DueDate, &inv.SentAt, &inv.PaidAt,
		&inv.Notes, &inv.CreatedAt, &inv.UpdatedAt, &inv.CustomerName,
	)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	// Line items
	lineRows, _ := h.db.Query(r.Context(), `
		SELECT id, description, quantity, unit_price, tax_rate, line_total
		FROM invoice_line_items WHERE invoice_id=$1 ORDER BY id`, id)
	defer lineRows.Close()
	lineItems := []models.InvoiceLineItem{}
	for lineRows.Next() {
		var li models.InvoiceLineItem
		_ = lineRows.Scan(&li.ID, &li.Description, &li.Quantity, &li.UnitPrice, &li.TaxRate, &li.LineTotal)
		li.InvoiceID = inv.ID
		lineItems = append(lineItems, li)
	}

	// Payment history
	pmtRows, _ := h.db.Query(r.Context(), `
		SELECT id, amount, payment_method, reference, paid_at
		FROM invoice_payments WHERE invoice_id=$1 ORDER BY paid_at`, id)
	defer pmtRows.Close()
	payments := []models.InvoicePayment{}
	for pmtRows.Next() {
		var p models.InvoicePayment
		_ = pmtRows.Scan(&p.ID, &p.Amount, &p.PaymentMethod, &p.Reference, &p.PaidAt)
		p.InvoiceID = inv.ID
		p.BusinessID = bizID
		payments = append(payments, p)
	}

	respond(w, 200, map[string]interface{}{
		"invoice":    inv,
		"line_items": lineItems,
		"payments":   payments,
	})
}

// ── Update ─────────────────────────────────────────────────────
func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	invoiceID, err := uuid.Parse(id)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	var req struct {
		Title     string `json:"title"`
		DueDate   string `json:"due_date"`
		Notes     string `json:"notes"`
		LineItems []struct {
			Description string  `json:"description"`
			Quantity    float64 `json:"quantity"`
			UnitPrice   float64 `json:"unit_price"`
			TaxRate     float64 `json:"tax_rate"`
		} `json:"line_items"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_body"})
		return
	}

	var dueDate *time.Time
	if req.DueDate != "" {
		if parsed, err := time.Parse("2006-01-02", req.DueDate); err == nil {
			dueDate = &parsed
		}
	}

	// Recalculate totals
	var subtotal, gstAmount float64
	for _, li := range req.LineItems {
		lineSubtotal := li.Quantity * li.UnitPrice
		subtotal += lineSubtotal
		gstAmount += lineSubtotal * li.TaxRate
	}
	total := subtotal + gstAmount

	// Fetch current amount_paid to recompute amount_due
	var amountPaid float64
	_ = h.db.QueryRow(r.Context(),
		`SELECT amount_paid FROM invoices WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&amountPaid)
	amountDue := total - amountPaid

	res, err := h.db.Exec(r.Context(), `
		UPDATE invoices
		SET title=$3, due_date=$4, notes=$5,
		    subtotal=$6, tax_amount=$7, total_amount=$8, amount_due=$9,
		    updated_at=NOW()
		WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Title, dueDate, nullStr(req.Notes),
		subtotal, gstAmount, total, amountDue,
	)
	if err != nil || res.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	// Delete and re-insert line items
	_, _ = h.db.Exec(r.Context(), `DELETE FROM invoice_line_items WHERE invoice_id=$1`, id)
	for _, li := range req.LineItems {
		if li.Quantity == 0 && li.UnitPrice == 0 {
			continue
		}
		lineTotal := li.Quantity * li.UnitPrice
		_, _ = h.db.Exec(r.Context(), `
			INSERT INTO invoice_line_items
			  (invoice_id, description, quantity, unit_price, tax_rate, line_total)
			VALUES ($1,$2,$3,$4,$5,$6)`,
			id, li.Description, li.Quantity, li.UnitPrice, li.TaxRate, lineTotal,
		)
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "update",
		EntityType: "invoice",
		EntityID:   invoiceID,
	})

	respond(w, 200, map[string]string{"status": "updated"})
}

// ── Delete ─────────────────────────────────────────────────────
func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	invoiceID, err := uuid.Parse(id)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	res, err := h.db.Exec(r.Context(), `
		UPDATE invoices SET deleted_at=NOW()
		WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID)
	if err != nil || res.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "delete",
		EntityType: "invoice",
		EntityID:   invoiceID,
	})

	respond(w, 204, nil)
}

// ── Send ───────────────────────────────────────────────────────
func (h *Handler) Send(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	invoiceID, err := uuid.Parse(id)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	type SentResult struct {
		ID            uuid.UUID  `json:"id"`
		InvoiceNumber string     `json:"invoice_number"`
		Status        string     `json:"status"`
		SentAt        *time.Time `json:"sent_at"`
	}
	var (
		result        SentResult
		customerEmail *string
		customerName  *string
		amountDue     float64
		dueDate       *time.Time
	)
	err = h.db.QueryRow(r.Context(), `
		UPDATE invoices i
		SET status='sent', sent_at=NOW(), updated_at=NOW()
		FROM customers c
		WHERE i.id=$1 AND i.business_id=$2 AND i.status='draft' AND i.deleted_at IS NULL
		  AND c.id = i.customer_id
		RETURNING i.id, i.invoice_number, i.status, i.sent_at,
		          c.email,
		          NULLIF(TRIM(COALESCE(c.first_name,'') || ' ' || COALESCE(c.last_name,'')), ''),
		          (i.total - COALESCE(i.amount_paid, 0))::float8,
		          i.due_date`,
		id, bizID,
	).Scan(&result.ID, &result.InvoiceNumber, &result.Status, &result.SentAt,
		&customerEmail, &customerName, &amountDue, &dueDate)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invoice_not_draft_or_not_found"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "send",
		EntityType: "invoice",
		EntityID:   invoiceID,
	})

	if customerEmail != nil && *customerEmail != "" {
		name := result.InvoiceNumber
		if customerName != nil {
			name = *customerName
		}
		link := fmt.Sprintf("%s/invoices/%s", h.cfg.FrontendURL, result.ID)
		due := ""
		if dueDate != nil {
			due = fmt.Sprintf("<p>Due: %s</p>", dueDate.Format("2 Jan 2006"))
		}
		body := fmt.Sprintf(
			`<p>Hi %s,</p>
			 <p>Invoice <strong>%s</strong> for $%.2f is ready.</p>
			 %s
			 <p><a href="%s">View invoice</a></p>
			 <p>Thanks,<br>Tradie Job Manager</p>`,
			name, result.InvoiceNumber, amountDue, due, link,
		)
		subject := fmt.Sprintf("Invoice %s — $%.2f", result.InvoiceNumber, amountDue)
		if sendErr := h.email.Send(r.Context(), *customerEmail, name, subject, body); sendErr != nil {
			h.log.Warn("invoice email send failed",
				zap.String("invoice_id", result.ID.String()),
				zap.Error(sendErr))
		}
	}

	respond(w, 200, result)
}

// ── GeneratePDF ────────────────────────────────────────────────
func (h *Handler) GeneratePDF(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var inv models.Invoice
	err := h.db.QueryRow(r.Context(), `
		SELECT i.id, i.business_id, i.invoice_number, i.status,
		       i.customer_id, i.job_id, i.subtotal, i.tax_amount, i.total_amount,
		       i.amount_paid, i.amount_due, i.due_date, i.sent_at, i.paid_at,
		       i.notes, i.created_at, i.updated_at
		FROM invoices i
		WHERE i.id=$1 AND i.business_id=$2 AND i.deleted_at IS NULL`,
		id, bizID,
	).Scan(
		&inv.ID, &inv.BusinessID, &inv.InvoiceNumber, &inv.Status,
		&inv.CustomerID, &inv.JobID, &inv.Subtotal, &inv.GSTAmount, &inv.Total,
		&inv.AmountPaid, &inv.AmountDue, &inv.DueDate, &inv.SentAt, &inv.PaidAt,
		&inv.Notes, &inv.CreatedAt, &inv.UpdatedAt,
	)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	var biz models.Business
	_ = h.db.QueryRow(r.Context(), `
		SELECT id, name, abn, phone, email, address_line1, city, state, postcode, logo_url
		FROM businesses WHERE id=$1`, bizID,
	).Scan(&biz.ID, &biz.Name, &biz.ABN, &biz.Phone, &biz.Email,
		&biz.Address, &biz.City, &biz.State, &biz.Postcode, &biz.LogoURL)

	lineRows, _ := h.db.Query(r.Context(), `
		SELECT id, description, quantity, unit_price, tax_rate, line_total
		FROM invoice_line_items WHERE invoice_id=$1 ORDER BY id`, id)
	defer lineRows.Close()
	lineItems := []models.InvoiceLineItem{}
	for lineRows.Next() {
		var li models.InvoiceLineItem
		_ = lineRows.Scan(&li.ID, &li.Description, &li.Quantity, &li.UnitPrice, &li.TaxRate, &li.LineTotal)
		li.InvoiceID = inv.ID
		lineItems = append(lineItems, li)
	}

	pmtRows, _ := h.db.Query(r.Context(), `
		SELECT id, amount, payment_method, reference, paid_at
		FROM invoice_payments WHERE invoice_id=$1 ORDER BY paid_at`, id)
	defer pmtRows.Close()
	payments := []models.InvoicePayment{}
	for pmtRows.Next() {
		var p models.InvoicePayment
		_ = pmtRows.Scan(&p.ID, &p.Amount, &p.PaymentMethod, &p.Reference, &p.PaidAt)
		p.InvoiceID = inv.ID
		p.BusinessID = bizID
		payments = append(payments, p)
	}

	respond(w, 200, map[string]interface{}{
		"invoice":    inv,
		"line_items": lineItems,
		"business":   biz,
		"payments":   payments,
		"pdf_url":    nil,
	})
}

// ── RecordPayment ──────────────────────────────────────────────
func (h *Handler) RecordPayment(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	invoiceID, err := uuid.Parse(id)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	var req struct {
		Amount        float64 `json:"amount"`
		PaymentMethod string  `json:"payment_method"`
		Reference     string  `json:"reference"`
		PaidAt        string  `json:"paid_at"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_body"})
		return
	}
	if req.Amount <= 0 {
		respond(w, 400, map[string]string{"error": "amount must be positive"})
		return
	}
	if req.PaymentMethod == "" {
		respond(w, 400, map[string]string{"error": "payment_method required"})
		return
	}

	// Verify invoice exists and belongs to business
	var exists bool
	_ = h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM invoices WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		id, bizID,
	).Scan(&exists)
	if !exists {
		respond(w, 404, map[string]string{"error": "invoice_not_found"})
		return
	}

	var paidAt *time.Time
	if req.PaidAt != "" {
		if parsed, err := time.Parse(time.RFC3339, req.PaidAt); err == nil {
			paidAt = &parsed
		}
	}

	type PaymentResult struct {
		ID     uuid.UUID `json:"id"`
		Amount float64   `json:"amount"`
		PaidAt time.Time `json:"paid_at"`
	}
	var result PaymentResult
	err = h.db.QueryRow(r.Context(), `
		INSERT INTO invoice_payments
		  (invoice_id, business_id, amount, payment_method, reference, paid_at)
		VALUES ($1,$2,$3,$4,$5,COALESCE($6, NOW()))
		RETURNING id, amount, paid_at`,
		id, bizID, req.Amount, req.PaymentMethod, nullStr(req.Reference), paidAt,
	).Scan(&result.ID, &result.Amount, &result.PaidAt)
	if err != nil {
		h.log.Error("invoices.RecordPayment insert", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}

	// Update invoice totals and status atomically
	_, _ = h.db.Exec(r.Context(), `
		UPDATE invoices
		SET amount_paid = (SELECT COALESCE(SUM(amount),0) FROM invoice_payments WHERE invoice_id=$1),
		    amount_due  = total_amount - (SELECT COALESCE(SUM(amount),0) FROM invoice_payments WHERE invoice_id=$1),
		    status = CASE
		        WHEN (SELECT COALESCE(SUM(amount),0) FROM invoice_payments WHERE invoice_id=$1) >= total_amount THEN 'paid'
		        WHEN (SELECT COALESCE(SUM(amount),0) FROM invoice_payments WHERE invoice_id=$1) > 0 THEN 'partial'
		        ELSE status END,
		    paid_at = CASE
		        WHEN (SELECT COALESCE(SUM(amount),0) FROM invoice_payments WHERE invoice_id=$1) >= total_amount THEN NOW()
		        ELSE NULL END,
		    updated_at = NOW()
		WHERE id=$1 AND business_id=$2`,
		id, bizID,
	)

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "payment",
		EntityType: "invoice",
		EntityID:   invoiceID,
	})

	respond(w, 201, result)
}

// ── IssueCreditNote ────────────────────────────────────────────
func (h *Handler) IssueCreditNote(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	invoiceID, err := uuid.Parse(id)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	var req struct {
		Amount float64 `json:"amount"`
		Reason string  `json:"reason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_body"})
		return
	}
	if req.Amount <= 0 {
		respond(w, 400, map[string]string{"error": "amount must be positive"})
		return
	}

	// Verify invoice exists
	var exists bool
	_ = h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM invoices WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		id, bizID,
	).Scan(&exists)
	if !exists {
		respond(w, 404, map[string]string{"error": "invoice_not_found"})
		return
	}

	var cn models.CreditNote
	err = h.db.QueryRow(r.Context(), `
		INSERT INTO credit_notes (invoice_id, business_id, amount, reason, issued_by, issued_at)
		VALUES ($1,$2,$3,$4,$5,NOW())
		RETURNING id, amount, reason, issued_at`,
		id, bizID, req.Amount, nullStr(req.Reason), claims.UserID,
	).Scan(&cn.ID, &cn.Amount, &cn.Reason, &cn.IssuedAt)
	if err != nil {
		h.log.Error("invoices.IssueCreditNote insert", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}

	// Reduce amount_due, floor at zero
	_, _ = h.db.Exec(r.Context(), `
		UPDATE invoices
		SET amount_due=GREATEST(0, amount_due-$3), updated_at=NOW()
		WHERE id=$1 AND business_id=$2`,
		id, bizID, req.Amount,
	)

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "credit_note",
		EntityType: "invoice",
		EntityID:   invoiceID,
	})

	respond(w, 201, cn)
}

// ── GetReceipt ─────────────────────────────────────────────────
func (h *Handler) GetReceipt(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var inv models.Invoice
	err := h.db.QueryRow(r.Context(), `
		SELECT i.id, i.business_id, i.invoice_number, i.status,
		       i.customer_id, i.job_id, i.subtotal, i.tax_amount, i.total_amount,
		       i.amount_paid, i.amount_due, i.due_date, i.sent_at, i.paid_at,
		       i.notes, i.created_at, i.updated_at
		FROM invoices i
		WHERE i.id=$1 AND i.business_id=$2 AND i.status='paid' AND i.deleted_at IS NULL`,
		id, bizID,
	).Scan(
		&inv.ID, &inv.BusinessID, &inv.InvoiceNumber, &inv.Status,
		&inv.CustomerID, &inv.JobID, &inv.Subtotal, &inv.GSTAmount, &inv.Total,
		&inv.AmountPaid, &inv.AmountDue, &inv.DueDate, &inv.SentAt, &inv.PaidAt,
		&inv.Notes, &inv.CreatedAt, &inv.UpdatedAt,
	)
	if err != nil {
		respond(w, 404, map[string]string{"error": "receipt_not_available"})
		return
	}

	var biz models.Business
	_ = h.db.QueryRow(r.Context(), `
		SELECT id, name, abn, phone, email, address_line1, city, state, postcode, logo_url
		FROM businesses WHERE id=$1`, bizID,
	).Scan(&biz.ID, &biz.Name, &biz.ABN, &biz.Phone, &biz.Email,
		&biz.Address, &biz.City, &biz.State, &biz.Postcode, &biz.LogoURL)

	lineRows, _ := h.db.Query(r.Context(), `
		SELECT id, description, quantity, unit_price, tax_rate, line_total
		FROM invoice_line_items WHERE invoice_id=$1 ORDER BY id`, id)
	defer lineRows.Close()
	lineItems := []models.InvoiceLineItem{}
	for lineRows.Next() {
		var li models.InvoiceLineItem
		_ = lineRows.Scan(&li.ID, &li.Description, &li.Quantity, &li.UnitPrice, &li.TaxRate, &li.LineTotal)
		li.InvoiceID = inv.ID
		lineItems = append(lineItems, li)
	}

	pmtRows, _ := h.db.Query(r.Context(), `
		SELECT id, amount, payment_method, reference, paid_at
		FROM invoice_payments WHERE invoice_id=$1 ORDER BY paid_at`, id)
	defer pmtRows.Close()
	payments := []models.InvoicePayment{}
	for pmtRows.Next() {
		var p models.InvoicePayment
		_ = pmtRows.Scan(&p.ID, &p.Amount, &p.PaymentMethod, &p.Reference, &p.PaidAt)
		p.InvoiceID = inv.ID
		p.BusinessID = bizID
		payments = append(payments, p)
	}

	respond(w, 200, map[string]interface{}{
		"invoice":    inv,
		"line_items": lineItems,
		"business":   biz,
		"payments":   payments,
		"pdf_url":    nil,
	})
}

// ── CreatePaymentLink ──────────────────────────────────────────
//
// Returns a Stripe Checkout URL when STRIPE_SECRET_KEY is configured;
// the customer pays on Stripe's hosted page and the resulting
// checkout.session.completed webhook (handled in subscription/) marks
// the invoice paid via metadata.invoice_id.
//
// Falls back to a token-based link when Stripe is not configured so
// dev environments stay working without billing credentials.
func (h *Handler) CreatePaymentLink(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var (
		invoiceNumber string
		total         float64
		amountPaid    float64
		customerEmail *string
	)
	err := h.db.QueryRow(r.Context(), `
		SELECT i.invoice_number, i.total, COALESCE(i.amount_paid, 0), c.email
		  FROM invoices i
		  LEFT JOIN customers c ON c.id = i.customer_id
		 WHERE i.id=$1 AND i.business_id=$2 AND i.deleted_at IS NULL`,
		id, bizID,
	).Scan(&invoiceNumber, &total, &amountPaid, &customerEmail)
	if err != nil {
		respond(w, 404, map[string]string{"error": "invoice_not_found"})
		return
	}

	amountDue := total - amountPaid
	if amountDue <= 0 {
		respond(w, 400, map[string]string{"error": "invoice_already_paid"})
		return
	}

	// Stripe Checkout path — preferred when configured.
	if h.cfg.StripeSecretKey != "" {
		stripe.Key = h.cfg.StripeSecretKey
		successURL := fmt.Sprintf("%s/invoices/%s?paid=1", h.cfg.FrontendURL, id)
		cancelURL := fmt.Sprintf("%s/invoices/%s?canceled=1", h.cfg.FrontendURL, id)
		params := &stripe.CheckoutSessionParams{
			Mode:       stripe.String(string(stripe.CheckoutSessionModePayment)),
			SuccessURL: stripe.String(successURL),
			CancelURL:  stripe.String(cancelURL),
			LineItems: []*stripe.CheckoutSessionLineItemParams{{
				Quantity: stripe.Int64(1),
				PriceData: &stripe.CheckoutSessionLineItemPriceDataParams{
					Currency:   stripe.String(string(stripe.CurrencyAUD)),
					UnitAmount: stripe.Int64(int64(amountDue * 100)),
					ProductData: &stripe.CheckoutSessionLineItemPriceDataProductDataParams{
						Name: stripe.String("Invoice " + invoiceNumber),
					},
				},
			}},
			Metadata: map[string]string{
				"invoice_id":  id,
				"business_id": bizID.String(),
			},
		}
		if customerEmail != nil && *customerEmail != "" {
			params.CustomerEmail = stripe.String(*customerEmail)
		}
		sess, sessErr := session.New(params)
		if sessErr != nil {
			h.log.Error("stripe checkout session", zap.Error(sessErr))
			respond(w, 502, map[string]string{"error": "billing_provider_error"})
			return
		}

		_, _ = h.db.Exec(r.Context(), `
			INSERT INTO payment_links (invoice_id, business_id, token, expires_at, created_by, stripe_session_id)
			VALUES ($1,$2,$3,$4,$5,$6)
			ON CONFLICT (invoice_id) DO UPDATE
			SET token=$3, expires_at=$4, created_by=$5, stripe_session_id=$6`,
			id, bizID, sess.ID, time.Now().Add(24*time.Hour), claims.UserID, sess.ID,
		)

		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     "create_payment_link",
			EntityType: "invoice",
			EntityID:   uuid.MustParse(id),
			NewData:    map[string]interface{}{"provider": "stripe", "session_id": sess.ID},
		})

		respond(w, 200, map[string]string{
			"payment_url": sess.URL,
			"provider":    "stripe",
			"session_id":  sess.ID,
		})
		return
	}

	// Fallback — token-based link for dev / unconfigured environments.
	token, err := generateToken()
	if err != nil {
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	expiresAt := time.Now().Add(7 * 24 * time.Hour)
	_, dbErr := h.db.Exec(r.Context(), `
		INSERT INTO payment_links (invoice_id, business_id, token, expires_at, created_by)
		VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT (invoice_id) DO UPDATE
		SET token=$3, expires_at=$4, created_by=$5`,
		id, bizID, token, expiresAt, claims.UserID,
	)
	if dbErr != nil {
		h.log.Error("invoices.CreatePaymentLink insert", zap.Error(dbErr))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}

	frontendURL := h.cfg.FrontendURL
	if frontendURL == "" {
		frontendURL = "https://defecexinso.com"
	}
	respond(w, 200, map[string]string{
		"payment_url": fmt.Sprintf("%s/pay/%s", frontendURL, token),
		"token":       token,
		"provider":    "token",
	})
}

// ── CreateRecurringRule ────────────────────────────────────────
// POST /invoices/recurring
// Creates a recurring_invoice_rules record for a business.
func (h *Handler) CreateRecurringRule(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		CustomerID   string          `json:"customer_id"`
		Frequency    string          `json:"frequency"` // weekly|fortnightly|monthly|quarterly|yearly
		TemplateData json.RawMessage `json:"template_data"`
		NextRunAt    string          `json:"next_run_at"` // YYYY-MM-DD
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_body"})
		return
	}
	if req.CustomerID == "" {
		respond(w, 400, map[string]string{"error": "customer_id required"})
		return
	}
	validFrequencies := map[string]bool{
		"weekly": true, "fortnightly": true, "monthly": true, "quarterly": true, "yearly": true,
	}
	if !validFrequencies[req.Frequency] {
		respond(w, 400, map[string]string{"error": "frequency must be one of: weekly, fortnightly, monthly, quarterly, yearly"})
		return
	}

	var nextRunAt time.Time
	if req.NextRunAt != "" {
		var err error
		nextRunAt, err = time.Parse("2006-01-02", req.NextRunAt)
		if err != nil {
			respond(w, 400, map[string]string{"error": "next_run_at must be YYYY-MM-DD"})
			return
		}
	} else {
		nextRunAt = time.Now().UTC().Truncate(24 * time.Hour)
	}

	templateData := req.TemplateData
	if len(templateData) == 0 {
		templateData = json.RawMessage(`{}`)
	}

	type RuleResult struct {
		ID         string    `json:"id"`
		CustomerID string    `json:"customer_id"`
		Frequency  string    `json:"frequency"`
		NextRunAt  time.Time `json:"next_run_at"`
		IsActive   bool      `json:"is_active"`
		CreatedAt  time.Time `json:"created_at"`
	}
	var result RuleResult
	err := h.db.QueryRow(r.Context(), `
		INSERT INTO recurring_invoice_rules
		  (business_id, customer_id, template_data, frequency, next_run_at, is_active, created_by)
		VALUES ($1,$2,$3,$4,$5,true,$6)
		RETURNING id, customer_id, frequency, next_run_at, is_active, created_at`,
		bizID, req.CustomerID, templateData, req.Frequency, nextRunAt, claims.UserID,
	).Scan(&result.ID, &result.CustomerID, &result.Frequency, &result.NextRunAt, &result.IsActive, &result.CreatedAt)
	if err != nil {
		h.log.Error("invoices.CreateRecurringRule insert", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "create",
		EntityType: "recurring_invoice_rule",
		EntityID:   uuid.MustParse(result.ID),
	})

	respond(w, 201, result)
}

// ── ListRecurringRules ─────────────────────────────────────────
// GET /invoices/recurring
// Lists all active recurring rules for the current business.
func (h *Handler) ListRecurringRules(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	rows, err := h.db.Query(r.Context(), `
		SELECT r.id, r.customer_id, r.frequency, r.template_data,
		       r.next_run_at, r.last_run_at, r.is_active, r.created_at,
		       COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer_name
		FROM recurring_invoice_rules r
		LEFT JOIN customers c ON c.id=r.customer_id
		WHERE r.business_id=$1
		ORDER BY r.created_at DESC`,
		bizID,
	)
	if err != nil {
		h.log.Error("invoices.ListRecurringRules query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	defer rows.Close()

	type RuleRow struct {
		ID           string          `json:"id"`
		CustomerID   string          `json:"customer_id"`
		CustomerName string          `json:"customer_name"`
		Frequency    string          `json:"frequency"`
		TemplateData json.RawMessage `json:"template_data"`
		NextRunAt    time.Time       `json:"next_run_at"`
		LastRunAt    *time.Time      `json:"last_run_at,omitempty"`
		IsActive     bool            `json:"is_active"`
		CreatedAt    time.Time       `json:"created_at"`
	}

	list := []RuleRow{}
	for rows.Next() {
		var row RuleRow
		if err := rows.Scan(
			&row.ID, &row.CustomerID, &row.Frequency, &row.TemplateData,
			&row.NextRunAt, &row.LastRunAt, &row.IsActive, &row.CreatedAt,
			&row.CustomerName,
		); err != nil {
			h.log.Error("invoices.ListRecurringRules scan", zap.Error(err))
			continue
		}
		list = append(list, row)
	}

	respond(w, 200, map[string]interface{}{"data": list})
}

// ── DeleteRecurringRule ────────────────────────────────────────
// DELETE /invoices/recurring/{id}
// Soft-deletes (sets is_active=false) a recurring rule.
func (h *Handler) DeleteRecurringRule(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	ruleID, err := uuid.Parse(id)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_id"})
		return
	}

	res, err := h.db.Exec(r.Context(), `
		UPDATE recurring_invoice_rules
		SET is_active=false, updated_at=NOW()
		WHERE id=$1 AND business_id=$2 AND is_active=true`,
		id, bizID,
	)
	if err != nil || res.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "rule_not_found_or_already_inactive"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "delete",
		EntityType: "recurring_invoice_rule",
		EntityID:   ruleID,
	})

	respond(w, 204, nil)
}

// ── ProcessDueRecurring ────────────────────────────────────────
// POST /invoices/recurring/process  (internal/admin only)
// Finds all rules where next_run_at <= NOW() AND is_active=true,
// generates an invoice for each, then advances next_run_at.
func (h *Handler) ProcessDueRecurring(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Load all due active rules
	rows, err := h.db.Query(ctx, `
		SELECT id, business_id, customer_id, template_data, frequency, created_by
		FROM recurring_invoice_rules
		WHERE is_active=true AND next_run_at <= NOW()
		ORDER BY next_run_at ASC`,
	)
	if err != nil {
		h.log.Error("invoices.ProcessDueRecurring query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	defer rows.Close()

	type dueRule struct {
		ID           string
		BusinessID   uuid.UUID
		CustomerID   string
		TemplateData json.RawMessage
		Frequency    string
		CreatedBy    string
	}

	var rules []dueRule
	for rows.Next() {
		var rule dueRule
		if err := rows.Scan(
			&rule.ID, &rule.BusinessID, &rule.CustomerID,
			&rule.TemplateData, &rule.Frequency, &rule.CreatedBy,
		); err != nil {
			h.log.Error("invoices.ProcessDueRecurring scan", zap.Error(err))
			continue
		}
		rules = append(rules, rule)
	}
	rows.Close()

	type ProcessedItem struct {
		RuleID    string `json:"rule_id"`
		InvoiceID string `json:"invoice_id,omitempty"`
		Error     string `json:"error,omitempty"`
	}
	processed := []ProcessedItem{}

	for _, rule := range rules {
		item := ProcessedItem{RuleID: rule.ID}

		// Parse template_data to extract line_items, notes, due_days
		var tmpl struct {
			LineItems []struct {
				Description string  `json:"description"`
				Quantity    float64 `json:"quantity"`
				UnitPrice   float64 `json:"unit_price"`
				TaxRate     float64 `json:"tax_rate"`
			} `json:"line_items"`
			Notes   string `json:"notes"`
			DueDays int    `json:"due_days"`
		}
		if err := json.Unmarshal(rule.TemplateData, &tmpl); err != nil {
			h.log.Error("invoices.ProcessDueRecurring unmarshal template", zap.Error(err), zap.String("rule_id", rule.ID))
			item.Error = "invalid_template_data"
			processed = append(processed, item)
			continue
		}

		// Calculate totals from template line items
		var subtotal, gstAmount float64
		for _, li := range tmpl.LineItems {
			lineSubtotal := li.Quantity * li.UnitPrice
			subtotal += lineSubtotal
			gstAmount += lineSubtotal * li.TaxRate
		}
		total := subtotal + gstAmount

		// Generate invoice number
		var count int
		_ = h.db.QueryRow(ctx,
			`SELECT COUNT(*) FROM invoices WHERE business_id=$1`, rule.BusinessID,
		).Scan(&count)
		invNumber := fmt.Sprintf("INV-%04d", count+1001)

		// Compute due date
		var dueDate *time.Time
		if tmpl.DueDays > 0 {
			d := time.Now().UTC().AddDate(0, 0, tmpl.DueDays)
			dueDate = &d
		}

		// Insert invoice
		var invID string
		err := h.db.QueryRow(ctx, `
			INSERT INTO invoices
			  (business_id, invoice_number, customer_id, title,
			   subtotal, tax_amount, total_amount, amount_due, due_date, notes, created_by)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
			RETURNING id`,
			rule.BusinessID, invNumber, rule.CustomerID,
			fmt.Sprintf("Recurring Invoice %s", invNumber),
			subtotal, gstAmount, total, total, dueDate,
			nullStr(tmpl.Notes), rule.CreatedBy,
		).Scan(&invID)
		if err != nil {
			h.log.Error("invoices.ProcessDueRecurring create invoice", zap.Error(err), zap.String("rule_id", rule.ID))
			item.Error = "invoice_create_failed"
			processed = append(processed, item)
			continue
		}

		// Insert line items
		for _, li := range tmpl.LineItems {
			if li.Quantity == 0 && li.UnitPrice == 0 {
				continue
			}
			lineTotal := li.Quantity * li.UnitPrice
			_, _ = h.db.Exec(ctx, `
				INSERT INTO invoice_line_items
				  (invoice_id, description, quantity, unit_price, tax_rate, line_total)
				VALUES ($1,$2,$3,$4,$5,$6)`,
				invID, li.Description, li.Quantity, li.UnitPrice, li.TaxRate, lineTotal,
			)
		}

		// Advance next_run_at based on frequency
		nextRun := advanceByFrequency(time.Now().UTC(), rule.Frequency)
		_, _ = h.db.Exec(ctx, `
			UPDATE recurring_invoice_rules
			SET next_run_at=$2, last_run_at=NOW(), updated_at=NOW()
			WHERE id=$1`,
			rule.ID, nextRun,
		)

		item.InvoiceID = invID
		processed = append(processed, item)
		h.log.Info("recurring invoice generated",
			zap.String("rule_id", rule.ID),
			zap.String("invoice_id", invID),
			zap.String("frequency", rule.Frequency),
			zap.Time("next_run_at", nextRun),
		)
	}

	respond(w, 200, map[string]interface{}{
		"processed": len(processed),
		"results":   processed,
	})
}

// advanceByFrequency returns the next run timestamp based on the rule's frequency.
func advanceByFrequency(from time.Time, frequency string) time.Time {
	switch frequency {
	case "weekly":
		return from.AddDate(0, 0, 7)
	case "fortnightly":
		return from.AddDate(0, 0, 14)
	case "monthly":
		return from.AddDate(0, 1, 0)
	case "quarterly":
		return from.AddDate(0, 3, 0)
	case "yearly":
		return from.AddDate(1, 0, 0)
	default:
		return from.AddDate(0, 1, 0) // fallback: monthly
	}
}

// ── helpers ────────────────────────────────────────────────────
func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}

func nullUUID(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

func nullStr(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

func generateToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
