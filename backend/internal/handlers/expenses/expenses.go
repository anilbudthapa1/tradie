package expenses

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
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
)

// ── Handler ────────────────────────────────────────────────────

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, args ...interface{}) *Handler {
	h := &Handler{cfg: cfg, db: db, log: log}
	for _, a := range args {
		if svc, ok := a.(*middleware.AuditService); ok {
			h.audit = svc
		}
	}
	return h
}

// ── helpers ────────────────────────────────────────────────────

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data) //nolint:errcheck
	}
}

// validCategories is the canonical set accepted by the API.
var validCategories = map[string]bool{
	"fuel": true, "materials": true, "tools": true, "insurance": true,
	"rent": true, "utilities": true, "subcontractor": true, "other": true,
}

var validPaymentMethods = map[string]bool{
	"cash": true, "card": true, "bank_transfer": true, "bpay": true,
}

// ── Expense row type ───────────────────────────────────────────

type Expense struct {
	ID             string     `json:"id"`
	BusinessID     string     `json:"business_id"`
	Category       string     `json:"category"`
	Description    string     `json:"description"`
	Amount         float64    `json:"amount"`
	GSTAmount      float64    `json:"gst_amount"`
	Date           string     `json:"date"`
	JobID          *string    `json:"job_id,omitempty"`
	JobReference   *string    `json:"job_reference,omitempty"`
	Supplier       *string    `json:"supplier,omitempty"`
	IsGSTInclusive bool       `json:"is_gst_inclusive"`
	PaymentMethod  string     `json:"payment_method"`
	ReceiptURL     *string    `json:"receipt_url,omitempty"`
	Status         string     `json:"status"`
	CreatedBy      string     `json:"created_by"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
	DeletedAt      *time.Time `json:"deleted_at,omitempty"`
}

// ── List ───────────────────────────────────────────────────────

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()

	category  := q.Get("category")
	dateFrom  := q.Get("date_from")
	dateTo    := q.Get("date_to")
	jobID     := q.Get("job_id")
	status    := q.Get("status")
	limitStr  := q.Get("limit")
	pageStr   := q.Get("page")

	limit := 50
	if v, err := strconv.Atoi(limitStr); err == nil && v > 0 && v <= 200 {
		limit = v
	}
	page := 1
	if v, err := strconv.Atoi(pageStr); err == nil && v > 1 {
		page = v
	}
	offset := (page - 1) * limit

	args := []interface{}{bizID}
	where := "WHERE e.business_id=$1 AND e.deleted_at IS NULL"
	idx := 2

	if category != "" && validCategories[category] {
		where += fmt.Sprintf(" AND e.category=$%d", idx)
		args = append(args, category)
		idx++
	}
	if dateFrom != "" {
		where += fmt.Sprintf(" AND e.date>=$%d", idx)
		args = append(args, dateFrom)
		idx++
	}
	if dateTo != "" {
		where += fmt.Sprintf(" AND e.date<=$%d", idx)
		args = append(args, dateTo)
		idx++
	}
	if jobID != "" {
		where += fmt.Sprintf(" AND e.job_id=$%d", idx)
		args = append(args, jobID)
		idx++
	}
	if status != "" {
		where += fmt.Sprintf(" AND e.status=$%d", idx)
		args = append(args, status)
		idx++
	}

	// Monthly total summary (current calendar month, same filters minus pagination)
	summaryQuery := fmt.Sprintf(`
		SELECT COALESCE(SUM(e.amount),0), COALESCE(SUM(e.gst_amount),0), COUNT(*)
		FROM expenses e
		%s
		AND date_trunc('month', e.date) = date_trunc('month', CURRENT_DATE)`,
		where)

	var monthTotal, monthGST float64
	var monthCount int64
	_ = h.db.QueryRow(r.Context(), summaryQuery, args...).Scan(&monthTotal, &monthGST, &monthCount)

	// Main list query
	args = append(args, limit, offset)
	listQuery := fmt.Sprintf(`
		SELECT e.id, e.business_id, e.category, e.description, e.amount, e.gst_amount,
		       e.date, e.job_id, j.reference AS job_reference,
		       e.supplier, e.is_gst_inclusive, e.payment_method,
		       e.receipt_url, e.status, e.created_by, e.created_at, e.updated_at
		FROM expenses e
		LEFT JOIN jobs j ON j.id = e.job_id
		%s
		ORDER BY e.date DESC, e.created_at DESC
		LIMIT $%d OFFSET $%d`,
		where, idx, idx+1)

	rows, err := h.db.Query(r.Context(), listQuery, args...)
	if err != nil {
		h.log.Error("expenses.List query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	defer rows.Close()

	list := []Expense{}
	for rows.Next() {
		var e Expense
		if err := rows.Scan(
			&e.ID, &e.BusinessID, &e.Category, &e.Description,
			&e.Amount, &e.GSTAmount, &e.Date, &e.JobID, &e.JobReference,
			&e.Supplier, &e.IsGSTInclusive, &e.PaymentMethod,
			&e.ReceiptURL, &e.Status, &e.CreatedBy, &e.CreatedAt, &e.UpdatedAt,
		); err != nil {
			h.log.Error("expenses.List scan", zap.Error(err))
			continue
		}
		list = append(list, e)
	}

	respond(w, 200, map[string]interface{}{
		"data": list,
		"meta": map[string]interface{}{
			"page":        page,
			"limit":       limit,
			"total_count": len(list),
		},
		"summary": map[string]interface{}{
			"total_this_month":     monthTotal,
			"total_gst_this_month": monthGST,
			"count_this_month":     monthCount,
		},
	})
}

// ── Create ─────────────────────────────────────────────────────

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID  := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		Category       string  `json:"category"`
		Description    string  `json:"description"`
		Amount         float64 `json:"amount"`
		Date           string  `json:"date"`
		JobID          string  `json:"job_id"`
		Supplier       string  `json:"supplier"`
		IsGSTInclusive bool    `json:"is_gst_inclusive"`
		PaymentMethod  string  `json:"payment_method"`
		ReceiptURL     string  `json:"receipt_url"`
		Status         string  `json:"status"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_body"})
		return
	}

	// Validation
	if req.Category == "" || !validCategories[req.Category] {
		respond(w, 400, map[string]string{"error": "invalid category; must be one of: fuel,materials,tools,insurance,rent,utilities,subcontractor,other"})
		return
	}
	if req.Description == "" {
		respond(w, 400, map[string]string{"error": "description required"})
		return
	}
	if req.Amount <= 0 {
		respond(w, 400, map[string]string{"error": "amount must be positive"})
		return
	}
	if req.Date == "" {
		req.Date = time.Now().Format("2006-01-02")
	}
	if req.PaymentMethod == "" {
		req.PaymentMethod = "card"
	}
	if !validPaymentMethods[req.PaymentMethod] {
		respond(w, 400, map[string]string{"error": "invalid payment_method; must be one of: cash,card,bank_transfer,bpay"})
		return
	}
	if req.Status == "" {
		req.Status = "approved"
	}

	// GST: 1/11 of the gross if is_gst_inclusive
	var gstAmount float64
	if req.IsGSTInclusive {
		gstAmount = req.Amount / 11.0
	}

	id     := uuid.New()
	userID := claims.UserID // uuid.UUID

	var jobIDPtr interface{} = nil
	if req.JobID != "" {
		jobIDPtr = req.JobID
	}
	var supplierPtr interface{} = nil
	if req.Supplier != "" {
		supplierPtr = req.Supplier
	}
	var receiptURLPtr interface{} = nil
	if req.ReceiptURL != "" {
		receiptURLPtr = req.ReceiptURL
	}

	const insertSQL = `
		INSERT INTO expenses
			(id, business_id, category, description, amount, gst_amount, date,
			 job_id, supplier, is_gst_inclusive, payment_method, receipt_url,
			 status, created_by, created_at, updated_at)
		VALUES
			($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,NOW(),NOW())
		RETURNING id, business_id, category, description, amount, gst_amount,
		          date, job_id, supplier, is_gst_inclusive, payment_method,
		          receipt_url, status, created_by, created_at, updated_at`

	var e Expense
	err := h.db.QueryRow(r.Context(), insertSQL,
		id, bizID, req.Category, req.Description, req.Amount, gstAmount, req.Date,
		jobIDPtr, supplierPtr, req.IsGSTInclusive, req.PaymentMethod, receiptURLPtr,
		req.Status, userID,
	).Scan(
		&e.ID, &e.BusinessID, &e.Category, &e.Description, &e.Amount, &e.GSTAmount,
		&e.Date, &e.JobID, &e.Supplier, &e.IsGSTInclusive, &e.PaymentMethod,
		&e.ReceiptURL, &e.Status, &e.CreatedBy, &e.CreatedAt, &e.UpdatedAt,
	)
	if err != nil {
		h.log.Error("expenses.Create insert", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}

	respond(w, 201, e)
}

// ── Get ────────────────────────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id    := chi.URLParam(r, "id")

	const query = `
		SELECT e.id, e.business_id, e.category, e.description, e.amount, e.gst_amount,
		       e.date, e.job_id, j.reference AS job_reference,
		       e.supplier, e.is_gst_inclusive, e.payment_method,
		       e.receipt_url, e.status, e.created_by, e.created_at, e.updated_at
		FROM expenses e
		LEFT JOIN jobs j ON j.id = e.job_id
		WHERE e.id=$1 AND e.business_id=$2 AND e.deleted_at IS NULL`

	var e Expense
	err := h.db.QueryRow(r.Context(), query, id, bizID).Scan(
		&e.ID, &e.BusinessID, &e.Category, &e.Description, &e.Amount, &e.GSTAmount,
		&e.Date, &e.JobID, &e.JobReference, &e.Supplier, &e.IsGSTInclusive,
		&e.PaymentMethod, &e.ReceiptURL, &e.Status, &e.CreatedBy, &e.CreatedAt, &e.UpdatedAt,
	)
	if err != nil {
		if isNoRows(err) {
			respond(w, 404, map[string]string{"error": "not_found"})
			return
		}
		h.log.Error("expenses.Get query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}

	respond(w, 200, e)
}

// ── Update ─────────────────────────────────────────────────────

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id    := chi.URLParam(r, "id")

	// Decode into map so we can patch only provided fields
	var patch map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_body"})
		return
	}

	// Allowed editable fields
	allowed := map[string]bool{
		"category": true, "description": true, "amount": true,
		"date": true, "job_id": true, "supplier": true,
		"payment_method": true, "receipt_url": true,
	}

	setClauses := []string{}
	args := []interface{}{}
	idx := 1

	for key, val := range patch {
		if !allowed[key] {
			continue
		}
		// Validate category if provided
		if key == "category" {
			cat, ok := val.(string)
			if !ok || !validCategories[cat] {
				respond(w, 400, map[string]string{"error": "invalid category"})
				return
			}
		}
		// Validate payment_method if provided
		if key == "payment_method" {
			pm, ok := val.(string)
			if !ok || !validPaymentMethods[pm] {
				respond(w, 400, map[string]string{"error": "invalid payment_method"})
				return
			}
		}
		// Recompute gst_amount if amount changes
		if key == "amount" {
			if amt, ok := toFloat64(val); ok && amt > 0 {
				setClauses = append(setClauses, fmt.Sprintf("amount=$%d", idx))
				args = append(args, amt)
				idx++
				// Recalculate GST based on existing is_gst_inclusive flag
				setClauses = append(setClauses, fmt.Sprintf(
					"gst_amount=CASE WHEN is_gst_inclusive THEN $%d / 11.0 ELSE 0 END", idx))
				args = append(args, amt)
				idx++
				continue
			} else {
				respond(w, 400, map[string]string{"error": "amount must be a positive number"})
				return
			}
		}
		setClauses = append(setClauses, fmt.Sprintf("%s=$%d", pgColName(key), idx))
		args = append(args, val)
		idx++
	}

	if len(setClauses) == 0 {
		respond(w, 400, map[string]string{"error": "no valid fields to update"})
		return
	}

	setClauses = append(setClauses, fmt.Sprintf("updated_at=$%d", idx))
	args = append(args, time.Now())
	idx++

	args = append(args, id, bizID)

	updateSQL := fmt.Sprintf(`
		UPDATE expenses SET %s
		WHERE id=$%d AND business_id=$%d AND deleted_at IS NULL`,
		strings.Join(setClauses, ", "), idx, idx+1)

	ct, err := h.db.Exec(r.Context(), updateSQL, args...)
	if err != nil {
		h.log.Error("expenses.Update exec", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	if ct.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	// Return updated record
	h.Get(w, r)
}

// ── Delete ─────────────────────────────────────────────────────

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id    := chi.URLParam(r, "id")

	ct, err := h.db.Exec(r.Context(),
		`UPDATE expenses SET deleted_at=NOW(), updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	)
	if err != nil {
		h.log.Error("expenses.Delete exec", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	if ct.RowsAffected() == 0 {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	respond(w, 200, map[string]string{"status": "deleted"})
}

// ── ScanReceipt ────────────────────────────────────────────────

func (h *Handler) ScanReceipt(w http.ResponseWriter, r *http.Request) {
	_ = middleware.BusinessIDFromCtx(r.Context())

	const maxSize = 10 << 20 // 10 MB
	if err := r.ParseMultipartForm(maxSize); err != nil {
		respond(w, 400, map[string]string{"error": "multipart parse error"})
		return
	}

	file, header, err := r.FormFile("receipt")
	if err != nil {
		respond(w, 400, map[string]string{"error": "receipt file required"})
		return
	}
	defer file.Close()

	uploadID := uuid.New().String()

	// Save the file to a temp location for future OCR processing.
	uploadDir := filepath.Join(os.TempDir(), "tradie_receipts")
	_ = os.MkdirAll(uploadDir, 0o755)
	destPath := filepath.Join(uploadDir, uploadID+filepath.Ext(header.Filename))

	dest, err := os.Create(destPath)
	if err == nil {
		_, _ = io.Copy(dest, file)
		dest.Close()
	}
	// Non-fatal: even if disk write fails we return the placeholder.

	respond(w, 200, map[string]interface{}{
		"status":    "pending",
		"message":   "receipt_uploaded",
		"upload_id": uploadID,
		"extracted": map[string]interface{}{
			"amount":   nil,
			"date":     nil,
			"supplier": nil,
		},
	})
}

// ── ExportAccountant ───────────────────────────────────────────

func (h *Handler) ExportAccountant(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()

	dateFrom := q.Get("date_from")
	dateTo   := q.Get("date_to")

	args := []interface{}{bizID}
	where := "WHERE e.business_id=$1 AND e.deleted_at IS NULL"
	idx := 2

	if dateFrom != "" {
		where += fmt.Sprintf(" AND e.date>=$%d", idx)
		args = append(args, dateFrom)
		idx++
	}
	if dateTo != "" {
		where += fmt.Sprintf(" AND e.date<=$%d", idx)
		args = append(args, dateTo)
		idx++
	}

	query := fmt.Sprintf(`
		SELECT e.category, e.description, e.amount, e.gst_amount,
		       e.date, COALESCE(j.reference,'') AS job_reference,
		       e.payment_method, COALESCE(e.receipt_url,'') AS receipt_url
		FROM expenses e
		LEFT JOIN jobs j ON j.id = e.job_id
		%s
		ORDER BY e.date DESC`, where)

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		h.log.Error("expenses.ExportAccountant query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	defer rows.Close()

	type ExportRow struct {
		Category      string  `json:"category"`
		Description   string  `json:"description"`
		Amount        float64 `json:"amount"`
		GSTAmount     float64 `json:"gst_amount"`
		Date          string  `json:"date"`
		JobReference  string  `json:"job_reference"`
		PaymentMethod string  `json:"payment_method"`
		ReceiptURL    string  `json:"receipt_url"`
	}

	list := []ExportRow{}
	for rows.Next() {
		var row ExportRow
		if err := rows.Scan(
			&row.Category, &row.Description, &row.Amount, &row.GSTAmount,
			&row.Date, &row.JobReference, &row.PaymentMethod, &row.ReceiptURL,
		); err != nil {
			h.log.Error("expenses.ExportAccountant scan", zap.Error(err))
			continue
		}
		list = append(list, row)
	}

	respond(w, 200, map[string]interface{}{
		"data":       list,
		"exported_at": time.Now().UTC().Format(time.RFC3339),
		"total_rows":  len(list),
	})
}

// ── GetSummary ─────────────────────────────────────────────────

func (h *Handler) GetSummary(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	ctx   := r.Context()

	// 1. This-month totals
	const thisMonthSQL = `
		SELECT COALESCE(SUM(amount),0), COALESCE(SUM(gst_amount),0)
		FROM expenses
		WHERE business_id=$1
		  AND deleted_at IS NULL
		  AND date_trunc('month', date) = date_trunc('month', CURRENT_DATE)`

	var totalThisMonth, totalGSTThisMonth float64
	_ = h.db.QueryRow(ctx, thisMonthSQL, bizID).Scan(&totalThisMonth, &totalGSTThisMonth)

	// 2. By category (all time, not deleted)
	const catSQL = `
		SELECT category, COALESCE(SUM(amount),0) AS total, COUNT(*) AS cnt
		FROM expenses
		WHERE business_id=$1 AND deleted_at IS NULL
		GROUP BY category
		ORDER BY total DESC`

	catRows, err := h.db.Query(ctx, catSQL, bizID)
	if err != nil {
		h.log.Error("expenses.GetSummary category query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	defer catRows.Close()

	type CatRow struct {
		Category string  `json:"category"`
		Total    float64 `json:"total"`
		Count    int64   `json:"count"`
	}
	byCategory := []CatRow{}
	for catRows.Next() {
		var c CatRow
		if err := catRows.Scan(&c.Category, &c.Total, &c.Count); err != nil {
			continue
		}
		byCategory = append(byCategory, c)
	}
	catRows.Close()

	// 3. Monthly trend — last 12 months
	const trendSQL = `
		SELECT to_char(date_trunc('month', date), 'YYYY-MM') AS month,
		       COALESCE(SUM(amount),0) AS total
		FROM expenses
		WHERE business_id=$1
		  AND deleted_at IS NULL
		  AND date >= date_trunc('month', CURRENT_DATE) - INTERVAL '11 months'
		GROUP BY date_trunc('month', date)
		ORDER BY date_trunc('month', date) ASC`

	trendRows, err := h.db.Query(ctx, trendSQL, bizID)
	if err != nil {
		h.log.Error("expenses.GetSummary trend query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	defer trendRows.Close()

	type TrendRow struct {
		Month string  `json:"month"`
		Total float64 `json:"total"`
	}
	monthlyTrend := []TrendRow{}
	for trendRows.Next() {
		var t TrendRow
		if err := trendRows.Scan(&t.Month, &t.Total); err != nil {
			continue
		}
		monthlyTrend = append(monthlyTrend, t)
	}

	respond(w, 200, map[string]interface{}{
		"total_this_month":     totalThisMonth,
		"total_gst_this_month": totalGSTThisMonth,
		"by_category":          byCategory,
		"monthly_trend":        monthlyTrend,
	})
}

// ── small helpers ──────────────────────────────────────────────

func isNoRows(err error) bool {
	return errors.Is(err, pgx.ErrNoRows)
}

// pgColName maps JSON field names to DB column names (they match 1:1 here
// except we guard against SQL injection by only allowing known keys via
// the `allowed` map in Update before this is ever called).
func pgColName(key string) string { return key }

func toFloat64(v interface{}) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	}
	return 0, false
}
