package customers

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
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

// ── List ───────────────────────────────────────────────────────────────────────

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	search := r.URL.Query().Get("search")
	var rows pgx.Rows
	var err error

	if search != "" {
		rows, err = h.db.Query(r.Context(),
			`SELECT id, business_id, first_name, last_name, company_name, email, phone, mobile, tags, is_active, source, created_at, updated_at
			 FROM customers
			 WHERE business_id=$1 AND deleted_at IS NULL
			   AND (first_name ILIKE $2 OR last_name ILIKE $2 OR company_name ILIKE $2 OR email ILIKE $2)
			 ORDER BY first_name ASC LIMIT 100`,
			bizID, "%"+search+"%")
	} else {
		rows, err = h.db.Query(r.Context(),
			`SELECT id, business_id, first_name, last_name, company_name, email, phone, mobile, tags, is_active, source, created_at, updated_at
			 FROM customers WHERE business_id=$1 AND deleted_at IS NULL ORDER BY first_name ASC LIMIT 100`, bizID)
	}
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()
	var list []models.Customer
	for rows.Next() {
		var c models.Customer
		_ = rows.Scan(&c.ID, &c.BusinessID, &c.FirstName, &c.LastName, &c.CompanyName,
			&c.Email, &c.Phone, &c.Mobile, &c.Tags, &c.IsActive, &c.Source, &c.CreatedAt, &c.UpdatedAt)
		list = append(list, c)
	}
	if list == nil {
		list = []models.Customer{}
	}
	respond(w, 200, list)
}

// ── Create ─────────────────────────────────────────────────────────────────────

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		FirstName   string   `json:"first_name"`
		LastName    string   `json:"last_name"`
		CompanyName string   `json:"company_name"`
		Email       string   `json:"email"`
		Phone       string   `json:"phone"`
		Mobile      string   `json:"mobile"`
		Tags        []string `json:"tags"`
		Source      string   `json:"source"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.FirstName == "" {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	var c models.Customer
	_ = h.db.QueryRow(r.Context(),
		`INSERT INTO customers (business_id, first_name, last_name, company_name, email, phone, mobile, tags, source)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		 RETURNING id, business_id, first_name, last_name, company_name, email, phone, mobile, tags, is_active, source, created_at, updated_at`,
		bizID, req.FirstName, nullStr(req.LastName), nullStr(req.CompanyName), nullStr(req.Email),
		nullStr(req.Phone), nullStr(req.Mobile), req.Tags, nullStr(req.Source),
	).Scan(&c.ID, &c.BusinessID, &c.FirstName, &c.LastName, &c.CompanyName,
		&c.Email, &c.Phone, &c.Mobile, &c.Tags, &c.IsActive, &c.Source, &c.CreatedAt, &c.UpdatedAt)
	respond(w, 201, c)
}

// ── Get ────────────────────────────────────────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var c models.Customer
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, first_name, last_name, company_name, email, phone, mobile, notes, tags, is_active, source, created_at, updated_at
		 FROM customers WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&c.ID, &c.BusinessID, &c.FirstName, &c.LastName, &c.CompanyName, &c.Email, &c.Phone,
		&c.Mobile, &c.Notes, &c.Tags, &c.IsActive, &c.Source, &c.CreatedAt, &c.UpdatedAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, c)
}

// ── Update ─────────────────────────────────────────────────────────────────────

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		FirstName   string   `json:"first_name"`
		LastName    string   `json:"last_name"`
		CompanyName string   `json:"company_name"`
		Email       string   `json:"email"`
		Phone       string   `json:"phone"`
		Mobile      string   `json:"mobile"`
		Notes       string   `json:"notes"`
		Tags        []string `json:"tags"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.FirstName == "" {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	var c models.Customer
	err := h.db.QueryRow(r.Context(),
		`UPDATE customers
		 SET first_name=$1, last_name=$2, company_name=$3, email=$4, phone=$5, mobile=$6, notes=$7, tags=$8, updated_at=NOW()
		 WHERE id=$9 AND business_id=$10 AND deleted_at IS NULL
		 RETURNING id, business_id, first_name, last_name, company_name, email, phone, mobile, notes, tags, is_active, source, created_at, updated_at`,
		req.FirstName, nullStr(req.LastName), nullStr(req.CompanyName), nullStr(req.Email),
		nullStr(req.Phone), nullStr(req.Mobile), nullStr(req.Notes), req.Tags,
		id, bizID,
	).Scan(&c.ID, &c.BusinessID, &c.FirstName, &c.LastName, &c.CompanyName, &c.Email, &c.Phone,
		&c.Mobile, &c.Notes, &c.Tags, &c.IsActive, &c.Source, &c.CreatedAt, &c.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respond(w, 404, map[string]string{"error": "not_found"})
			return
		}
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "update",
		EntityType: "customer",
		EntityID:   c.ID,
	})
	respond(w, 200, c)
}

// ── Delete ─────────────────────────────────────────────────────────────────────

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	_, _ = h.db.Exec(r.Context(), `UPDATE customers SET deleted_at=NOW() WHERE id=$1 AND business_id=$2`, id, bizID)
	respond(w, 204, nil)
}

// ── GetAddresses ───────────────────────────────────────────────────────────────

func (h *Handler) GetAddresses(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	rows, err := h.db.Query(r.Context(),
		`SELECT id, customer_id, label, address_line1, address_line2, city, state, postcode, country, is_primary, created_at
		 FROM customer_addresses
		 WHERE customer_id=$1 AND business_id=$2
		 ORDER BY is_primary DESC, created_at ASC`,
		id, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	var list []models.CustomerAddress
	for rows.Next() {
		var a models.CustomerAddress
		_ = rows.Scan(&a.ID, &a.CustomerID, &a.Label, &a.AddressLine1, &a.AddressLine2,
			&a.City, &a.State, &a.Postcode, &a.Country, &a.IsPrimary, &a.CreatedAt)
		list = append(list, a)
	}
	if list == nil {
		list = []models.CustomerAddress{}
	}
	respond(w, 200, list)
}

// ── AddAddress ─────────────────────────────────────────────────────────────────

func (h *Handler) AddAddress(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Label        string  `json:"label"`
		AddressLine1 string  `json:"address_line1"`
		AddressLine2 string  `json:"address_line2"`
		City         string  `json:"city"`
		State        string  `json:"state"`
		Postcode     string  `json:"postcode"`
		Country      string  `json:"country"`
		IsPrimary    bool    `json:"is_primary"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.AddressLine1 == "" {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// If marking as primary, demote all existing primary addresses
	if req.IsPrimary {
		_, _ = h.db.Exec(r.Context(),
			`UPDATE customer_addresses SET is_primary=false WHERE customer_id=$1 AND business_id=$2`,
			id, bizID)
	}

	var a models.CustomerAddress
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO customer_addresses (customer_id, business_id, label, address_line1, address_line2, city, state, postcode, country, is_primary)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
		 RETURNING id, customer_id, label, address_line1, address_line2, city, state, postcode, country, is_primary, created_at`,
		id, bizID, nullStr(req.Label), req.AddressLine1, nullStr(req.AddressLine2),
		req.City, nullStr(req.State), nullStr(req.Postcode), req.Country, req.IsPrimary,
	).Scan(&a.ID, &a.CustomerID, &a.Label, &a.AddressLine1, &a.AddressLine2,
		&a.City, &a.State, &a.Postcode, &a.Country, &a.IsPrimary, &a.CreatedAt)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 201, a)
}

// ── UpdateAddress ──────────────────────────────────────────────────────────────

func (h *Handler) UpdateAddress(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	customerID := chi.URLParam(r, "id")
	aid := chi.URLParam(r, "aid")

	var req struct {
		Label        string `json:"label"`
		AddressLine1 string `json:"address_line1"`
		AddressLine2 string `json:"address_line2"`
		City         string `json:"city"`
		State        string `json:"state"`
		Postcode     string `json:"postcode"`
		Country      string `json:"country"`
		IsPrimary    bool   `json:"is_primary"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// If marking as primary, demote existing primary addresses
	if req.IsPrimary {
		_, _ = h.db.Exec(r.Context(),
			`UPDATE customer_addresses SET is_primary=false WHERE customer_id=$1 AND business_id=$2 AND id<>$3`,
			customerID, bizID, aid)
	}

	var a models.CustomerAddress
	err := h.db.QueryRow(r.Context(),
		`UPDATE customer_addresses
		 SET label=$1, address_line1=$2, address_line2=$3, city=$4, state=$5, postcode=$6, country=$7, is_primary=$8
		 WHERE id=$9 AND business_id=$10
		 RETURNING id, customer_id, label, address_line1, address_line2, city, state, postcode, country, is_primary, created_at`,
		nullStr(req.Label), req.AddressLine1, nullStr(req.AddressLine2),
		req.City, nullStr(req.State), nullStr(req.Postcode), req.Country, req.IsPrimary,
		aid, bizID,
	).Scan(&a.ID, &a.CustomerID, &a.Label, &a.AddressLine1, &a.AddressLine2,
		&a.City, &a.State, &a.Postcode, &a.Country, &a.IsPrimary, &a.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respond(w, 404, map[string]string{"error": "not_found"})
			return
		}
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 200, a)
}

// ── DeleteAddress ──────────────────────────────────────────────────────────────

func (h *Handler) DeleteAddress(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	aid := chi.URLParam(r, "aid")
	_, _ = h.db.Exec(r.Context(),
		`DELETE FROM customer_addresses WHERE id=$1 AND business_id=$2`, aid, bizID)
	respond(w, 204, nil)
}

// ── GetContacts ────────────────────────────────────────────────────────────────

func (h *Handler) GetContacts(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	rows, err := h.db.Query(r.Context(),
		`SELECT id, customer_id, name, role, email, phone, is_primary, created_at
		 FROM customer_contacts
		 WHERE customer_id=$1 AND business_id=$2
		 ORDER BY is_primary DESC`,
		id, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	var list []models.CustomerContact
	for rows.Next() {
		var c models.CustomerContact
		_ = rows.Scan(&c.ID, &c.CustomerID, &c.Name, &c.Role, &c.Email, &c.Phone, &c.IsPrimary, &c.CreatedAt)
		list = append(list, c)
	}
	if list == nil {
		list = []models.CustomerContact{}
	}
	respond(w, 200, list)
}

// ── AddContact ─────────────────────────────────────────────────────────────────

func (h *Handler) AddContact(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Name      string `json:"name"`
		Role      string `json:"role"`
		Email     string `json:"email"`
		Phone     string `json:"phone"`
		IsPrimary bool   `json:"is_primary"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// If marking as primary, demote existing
	if req.IsPrimary {
		_, _ = h.db.Exec(r.Context(),
			`UPDATE customer_contacts SET is_primary=false WHERE customer_id=$1 AND business_id=$2`,
			id, bizID)
	}

	var c models.CustomerContact
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO customer_contacts (customer_id, business_id, name, role, email, phone, is_primary)
		 VALUES ($1,$2,$3,$4,$5,$6,$7)
		 RETURNING id, customer_id, name, role, email, phone, is_primary, created_at`,
		id, bizID, req.Name, nullStr(req.Role), nullStr(req.Email), nullStr(req.Phone), req.IsPrimary,
	).Scan(&c.ID, &c.CustomerID, &c.Name, &c.Role, &c.Email, &c.Phone, &c.IsPrimary, &c.CreatedAt)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 201, c)
}

// ── GetNotes ───────────────────────────────────────────────────────────────────

func (h *Handler) GetNotes(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	rows, err := h.db.Query(r.Context(),
		`SELECT n.id, n.customer_id, n.content, n.created_by,
		        u.first_name||' '||u.last_name AS author, n.created_at
		 FROM customer_notes n
		 LEFT JOIN users u ON u.id=n.created_by
		 WHERE n.customer_id=$1 AND n.business_id=$2
		 ORDER BY n.created_at DESC`,
		id, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	var list []models.CustomerNote
	for rows.Next() {
		var n models.CustomerNote
		_ = rows.Scan(&n.ID, &n.CustomerID, &n.Content, &n.CreatedBy, &n.Author, &n.CreatedAt)
		list = append(list, n)
	}
	if list == nil {
		list = []models.CustomerNote{}
	}
	respond(w, 200, list)
}

// ── AddNote ────────────────────────────────────────────────────────────────────

func (h *Handler) AddNote(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Content string `json:"content"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Content == "" {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	var n models.CustomerNote
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO customer_notes (customer_id, business_id, content, created_by)
		 VALUES ($1,$2,$3,$4)
		 RETURNING id, customer_id, content, created_by,
		           (SELECT first_name||' '||last_name FROM users WHERE id=$4),
		           created_at`,
		id, bizID, req.Content, claims.UserID,
	).Scan(&n.ID, &n.CustomerID, &n.Content, &n.CreatedBy, &n.Author, &n.CreatedAt)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 201, n)
}

// ── GetJobs ────────────────────────────────────────────────────────────────────

func (h *Handler) GetJobs(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	rows, err := h.db.Query(r.Context(),
		`SELECT id, job_number, title, status, priority, scheduled_start, created_at
		 FROM jobs
		 WHERE customer_id=$1 AND business_id=$2 AND deleted_at IS NULL
		 ORDER BY created_at DESC LIMIT 20`,
		id, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type jobSummary struct {
		ID             interface{} `json:"id"`
		JobNumber      string      `json:"job_number"`
		Title          string      `json:"title"`
		Status         string      `json:"status"`
		Priority       string      `json:"priority"`
		ScheduledStart interface{} `json:"scheduled_start"`
		CreatedAt      interface{} `json:"created_at"`
	}
	var list []jobSummary
	for rows.Next() {
		var j jobSummary
		_ = rows.Scan(&j.ID, &j.JobNumber, &j.Title, &j.Status, &j.Priority, &j.ScheduledStart, &j.CreatedAt)
		list = append(list, j)
	}
	if list == nil {
		list = []jobSummary{}
	}
	respond(w, 200, list)
}

// ── GetQuotes ──────────────────────────────────────────────────────────────────

func (h *Handler) GetQuotes(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	rows, err := h.db.Query(r.Context(),
		`SELECT id, quote_number, title, status, total, created_at
		 FROM quotes
		 WHERE customer_id=$1 AND business_id=$2 AND deleted_at IS NULL
		 ORDER BY created_at DESC LIMIT 20`,
		id, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type quoteSummary struct {
		ID          interface{} `json:"id"`
		QuoteNumber string      `json:"quote_number"`
		Title       string      `json:"title"`
		Status      string      `json:"status"`
		Total       float64     `json:"total"`
		CreatedAt   interface{} `json:"created_at"`
	}
	var list []quoteSummary
	for rows.Next() {
		var q quoteSummary
		_ = rows.Scan(&q.ID, &q.QuoteNumber, &q.Title, &q.Status, &q.Total, &q.CreatedAt)
		list = append(list, q)
	}
	if list == nil {
		list = []quoteSummary{}
	}
	respond(w, 200, list)
}

// ── GetInvoices ────────────────────────────────────────────────────────────────

func (h *Handler) GetInvoices(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	rows, err := h.db.Query(r.Context(),
		`SELECT id, invoice_number, status, total, amount_paid, due_date, created_at
		 FROM invoices
		 WHERE customer_id=$1 AND business_id=$2 AND deleted_at IS NULL
		 ORDER BY created_at DESC LIMIT 20`,
		id, bizID)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type invoiceSummary struct {
		ID            interface{} `json:"id"`
		InvoiceNumber string      `json:"invoice_number"`
		Status        string      `json:"status"`
		Total         float64     `json:"total"`
		AmountPaid    float64     `json:"amount_paid"`
		DueDate       interface{} `json:"due_date"`
		CreatedAt     interface{} `json:"created_at"`
	}
	var list []invoiceSummary
	for rows.Next() {
		var inv invoiceSummary
		_ = rows.Scan(&inv.ID, &inv.InvoiceNumber, &inv.Status, &inv.Total, &inv.AmountPaid, &inv.DueDate, &inv.CreatedAt)
		list = append(list, inv)
	}
	if list == nil {
		list = []invoiceSummary{}
	}
	respond(w, 200, list)
}

// ── Helpers ────────────────────────────────────────────────────────────────────

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}

func nullStr(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}
