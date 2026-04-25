package payments

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

type Handler struct {
	cfg *config.Config
	db  *pgxpool.Pool
	log *zap.Logger
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, args ...interface{}) *Handler {
	return &Handler{cfg: cfg, db: db, log: log}
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}

// ── List ───────────────────────────────────────────────────────
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	type PaymentRow struct {
		ID            string    `json:"id"`
		InvoiceID     string    `json:"invoice_id"`
		InvoiceNumber string    `json:"invoice_number"`
		Customer      string    `json:"customer"`
		Amount        float64   `json:"amount"`
		PaymentMethod string    `json:"payment_method"`
		Reference     *string   `json:"reference,omitempty"`
		PaidAt        time.Time `json:"paid_at"`
	}

	rows, err := h.db.Query(r.Context(), `
		SELECT p.id, p.invoice_id, i.invoice_number,
		       COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer,
		       p.amount, p.payment_method, p.reference, p.paid_at
		FROM invoice_payments p
		JOIN invoices i ON i.id=p.invoice_id
		LEFT JOIN customers c ON c.id=i.customer_id
		WHERE p.business_id=$1
		ORDER BY p.paid_at DESC LIMIT 50`,
		bizID,
	)
	if err != nil {
		h.log.Error("payments.List query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	defer rows.Close()

	list := []PaymentRow{}
	for rows.Next() {
		var row PaymentRow
		if err := rows.Scan(
			&row.ID, &row.InvoiceID, &row.InvoiceNumber,
			&row.Customer, &row.Amount, &row.PaymentMethod,
			&row.Reference, &row.PaidAt,
		); err != nil {
			h.log.Error("payments.List scan", zap.Error(err))
			continue
		}
		list = append(list, row)
	}

	respond(w, 200, map[string]interface{}{"data": list})
}

// ── Get ────────────────────────────────────────────────────────
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	type PaymentDetail struct {
		ID            string    `json:"id"`
		InvoiceID     string    `json:"invoice_id"`
		InvoiceNumber string    `json:"invoice_number"`
		Customer      string    `json:"customer"`
		Amount        float64   `json:"amount"`
		PaymentMethod string    `json:"payment_method"`
		Reference     *string   `json:"reference,omitempty"`
		PaidAt        time.Time `json:"paid_at"`
	}

	var row PaymentDetail
	err := h.db.QueryRow(r.Context(), `
		SELECT p.id, p.invoice_id, i.invoice_number,
		       COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer,
		       p.amount, p.payment_method, p.reference, p.paid_at
		FROM invoice_payments p
		JOIN invoices i ON i.id=p.invoice_id
		LEFT JOIN customers c ON c.id=i.customer_id
		WHERE p.id=$1 AND p.business_id=$2`,
		id, bizID,
	).Scan(
		&row.ID, &row.InvoiceID, &row.InvoiceNumber,
		&row.Customer, &row.Amount, &row.PaymentMethod,
		&row.Reference, &row.PaidAt,
	)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	respond(w, 200, row)
}
