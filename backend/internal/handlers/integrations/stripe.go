package integrations

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stripe/stripe-go/v79"
	"github.com/stripe/stripe-go/v79/billingportal/session"
	checkoutsession "github.com/stripe/stripe-go/v79/checkout/session"
	stripecustomer "github.com/stripe/stripe-go/v79/customer"
	"github.com/stripe/stripe-go/v79/invoice"
	"github.com/stripe/stripe-go/v79/webhook"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// StripeHandler handles all Stripe-related integration endpoints.
type StripeHandler struct {
	cfg *config.Config
	db  *pgxpool.Pool
	log *zap.Logger
}

func NewStripeHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger) *StripeHandler {
	return &StripeHandler{cfg: cfg, db: db, log: log}
}

// ── CreateCheckoutSession ─────────────────────────────────────────────────────
// POST /integrations/stripe/checkout
// Body: { "price_id": "price_xxx", "success_url": "...", "cancel_url": "..." }
// Returns: { "url": "https://checkout.stripe.com/..." }

func (h *StripeHandler) CreateCheckoutSession(w http.ResponseWriter, r *http.Request) {
	if h.cfg.StripeSecretKey == "" {
		stripeRespond(w, 503, map[string]string{"error": "billing_not_configured"})
		return
	}

	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		PriceID    string `json:"price_id"`
		SuccessURL string `json:"success_url"`
		CancelURL  string `json:"cancel_url"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.PriceID == "" {
		stripeRespond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	stripe.Key = h.cfg.StripeSecretKey

	// Get or create Stripe customer for this business.
	stripeCustomerID := h.getOrCreateStripeCustomer(r, bizID.String(), claims.UserID)

	successURL := req.SuccessURL
	if successURL == "" {
		successURL = fmt.Sprintf("%s/settings/subscription?success=1", h.cfg.FrontendURL)
	}
	cancelURL := req.CancelURL
	if cancelURL == "" {
		cancelURL = fmt.Sprintf("%s/settings/subscription?canceled=1", h.cfg.FrontendURL)
	}

	params := &stripe.CheckoutSessionParams{
		Customer:   stripe.String(stripeCustomerID),
		Mode:       stripe.String(string(stripe.CheckoutSessionModeSubscription)),
		SuccessURL: stripe.String(successURL),
		CancelURL:  stripe.String(cancelURL),
		LineItems: []*stripe.CheckoutSessionLineItemParams{
			{Price: stripe.String(req.PriceID), Quantity: stripe.Int64(1)},
		},
		SubscriptionData: &stripe.CheckoutSessionSubscriptionDataParams{
			Metadata: map[string]string{
				"business_id": bizID.String(),
			},
		},
	}

	sess, err := checkoutsession.New(params)
	if err != nil {
		h.log.Error("stripe checkout session create failed", zap.Error(err))
		stripeRespond(w, 500, map[string]string{"error": "billing_error"})
		return
	}

	stripeRespond(w, 200, map[string]string{"url": sess.URL})
}

// ── CreateBillingPortal ───────────────────────────────────────────────────────
// POST /integrations/stripe/portal
// Returns: { "url": "https://billing.stripe.com/..." }

func (h *StripeHandler) CreateBillingPortal(w http.ResponseWriter, r *http.Request) {
	if h.cfg.StripeSecretKey == "" {
		stripeRespond(w, 503, map[string]string{"error": "billing_not_configured"})
		return
	}

	bizID := middleware.BusinessIDFromCtx(r.Context())

	var stripeCustomerID string
	_ = h.db.QueryRow(r.Context(),
		`SELECT stripe_customer_id FROM businesses WHERE id=$1`, bizID,
	).Scan(&stripeCustomerID)

	if stripeCustomerID == "" {
		stripeRespond(w, 400, map[string]string{"error": "no_stripe_customer"})
		return
	}

	stripe.Key = h.cfg.StripeSecretKey

	returnURL := fmt.Sprintf("%s/settings/subscription", h.cfg.FrontendURL)

	params := &stripe.BillingPortalSessionParams{
		Customer:  stripe.String(stripeCustomerID),
		ReturnURL: stripe.String(returnURL),
	}

	portal, err := session.New(params)
	if err != nil {
		h.log.Error("stripe billing portal create failed", zap.Error(err))
		stripeRespond(w, 500, map[string]string{"error": "billing_error"})
		return
	}

	stripeRespond(w, 200, map[string]string{"url": portal.URL})
}

// ── Webhook ───────────────────────────────────────────────────────────────────
// POST /integrations/stripe/webhook
// Verifies signature, handles subscription lifecycle and invoice events.

func (h *StripeHandler) Webhook(w http.ResponseWriter, r *http.Request) {
	if h.cfg.StripeWebhookSecret == "" {
		// Accept without verification in dev if secret not set.
		w.WriteHeader(200)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		w.WriteHeader(400)
		return
	}

	event, err := webhook.ConstructEvent(body, r.Header.Get("Stripe-Signature"), h.cfg.StripeWebhookSecret)
	if err != nil {
		h.log.Warn("stripe webhook signature invalid", zap.Error(err))
		w.WriteHeader(400)
		return
	}

	// Idempotency: check if we've already processed this event.
	if h.stripeEventAlreadyProcessed(r, event.ID) {
		w.WriteHeader(200)
		return
	}

	// Store the event before processing to prevent duplicate work.
	h.recordStripeEvent(r, event.ID, string(event.Type), event.Data.Raw)

	switch event.Type {
	case "customer.subscription.created", "customer.subscription.updated":
		var sub stripe.Subscription
		if err := json.Unmarshal(event.Data.Raw, &sub); err == nil {
			h.handleSubscriptionUpsert(r, &sub)
		}

	case "customer.subscription.deleted":
		var sub stripe.Subscription
		if err := json.Unmarshal(event.Data.Raw, &sub); err == nil {
			h.handleSubscriptionDeleted(r, &sub)
		}

	case "invoice.payment_succeeded":
		var inv stripe.Invoice
		if err := json.Unmarshal(event.Data.Raw, &inv); err == nil {
			h.handleInvoicePaymentSucceeded(r, &inv)
		}

	case "invoice.payment_failed":
		var inv stripe.Invoice
		if err := json.Unmarshal(event.Data.Raw, &inv); err == nil {
			h.handleInvoicePaymentFailed(r, &inv)
		}
	}

	w.WriteHeader(200)
}

// ── GetInvoices ───────────────────────────────────────────────────────────────
// GET /integrations/stripe/invoices
// Returns the last 20 Stripe invoices for the business's Stripe customer.

func (h *StripeHandler) GetInvoices(w http.ResponseWriter, r *http.Request) {
	if h.cfg.StripeSecretKey == "" {
		stripeRespond(w, 503, map[string]string{"error": "billing_not_configured"})
		return
	}

	bizID := middleware.BusinessIDFromCtx(r.Context())

	var stripeCustomerID string
	_ = h.db.QueryRow(r.Context(),
		`SELECT stripe_customer_id FROM businesses WHERE id=$1`, bizID,
	).Scan(&stripeCustomerID)

	if stripeCustomerID == "" {
		stripeRespond(w, 200, map[string]interface{}{"data": []interface{}{}})
		return
	}

	stripe.Key = h.cfg.StripeSecretKey

	params := &stripe.InvoiceListParams{
		Customer: stripe.String(stripeCustomerID),
	}
	params.Filters.AddFilter("limit", "", "20")

	iter := invoice.List(params)

	type InvoiceRow struct {
		ID             string  `json:"id"`
		Number         string  `json:"number"`
		Status         string  `json:"status"`
		AmountDue      int64   `json:"amount_due"`
		AmountPaid     int64   `json:"amount_paid"`
		Currency       string  `json:"currency"`
		InvoicePDF     string  `json:"invoice_pdf"`
		HostedInvoiceURL string `json:"hosted_invoice_url"`
		PeriodStart    int64   `json:"period_start"`
		PeriodEnd      int64   `json:"period_end"`
		Created        int64   `json:"created"`
	}

	var invoices []InvoiceRow
	for iter.Next() {
		inv := iter.Invoice()
		row := InvoiceRow{
			ID:           inv.ID,
			Number:       inv.Number,
			Status:       string(inv.Status),
			AmountDue:    inv.AmountDue,
			AmountPaid:   inv.AmountPaid,
			Currency:     string(inv.Currency),
			InvoicePDF:   inv.InvoicePDF,
			HostedInvoiceURL: inv.HostedInvoiceURL,
			Created:      inv.Created,
		}
		if inv.Lines != nil && len(inv.Lines.Data) > 0 {
			row.PeriodStart = inv.Lines.Data[0].Period.Start
			row.PeriodEnd = inv.Lines.Data[0].Period.End
		}
		invoices = append(invoices, row)
	}
	if err := iter.Err(); err != nil {
		h.log.Error("stripe invoice list failed", zap.Error(err))
		stripeRespond(w, 500, map[string]string{"error": "billing_error"})
		return
	}
	if invoices == nil {
		invoices = []InvoiceRow{}
	}

	stripeRespond(w, 200, map[string]interface{}{"data": invoices})
}

// ── Internal helpers ──────────────────────────────────────────────────────────

func (h *StripeHandler) getOrCreateStripeCustomer(r *http.Request, bizID, userID string) string {
	var stripeCustomerID string
	_ = h.db.QueryRow(r.Context(),
		`SELECT stripe_customer_id FROM businesses WHERE id=$1`, bizID,
	).Scan(&stripeCustomerID)

	if stripeCustomerID != "" {
		return stripeCustomerID
	}

	var email string
	_ = h.db.QueryRow(r.Context(),
		`SELECT email FROM users WHERE id=$1`, userID,
	).Scan(&email)

	cust, err := stripecustomer.New(&stripe.CustomerParams{
		Email: stripe.String(email),
		Metadata: map[string]string{
			"business_id": bizID,
		},
	})
	if err != nil {
		h.log.Error("stripe customer create failed", zap.Error(err))
		return ""
	}

	_, _ = h.db.Exec(r.Context(),
		`UPDATE businesses SET stripe_customer_id=$2 WHERE id=$1`, bizID, cust.ID)

	return cust.ID
}

func (h *StripeHandler) stripeEventAlreadyProcessed(r *http.Request, eventID string) bool {
	var exists bool
	_ = h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM stripe_events WHERE stripe_event_id=$1)`, eventID,
	).Scan(&exists)
	return exists
}

func (h *StripeHandler) recordStripeEvent(r *http.Request, eventID, eventType string, raw json.RawMessage) {
	_, _ = h.db.Exec(r.Context(),
		`INSERT INTO stripe_events (stripe_event_id, event_type, payload, processed_at)
		 VALUES ($1, $2, $3, NOW())
		 ON CONFLICT (stripe_event_id) DO NOTHING`,
		eventID, eventType, raw,
	)
}

func (h *StripeHandler) handleSubscriptionUpsert(r *http.Request, sub *stripe.Subscription) {
	bizID := sub.Metadata["business_id"]
	if bizID == "" && sub.Customer != nil {
		// Fall back: look up by stripe customer ID.
		_ = h.db.QueryRow(r.Context(),
			`SELECT id FROM businesses WHERE stripe_customer_id=$1`, sub.Customer.ID,
		).Scan(&bizID)
	}
	if bizID == "" {
		h.log.Warn("stripe subscription upsert: no business_id", zap.String("sub_id", sub.ID))
		return
	}

	// Determine plan details from the subscription's first price.
	planSlug := ""
	maxWorkers := 5
	maxJobsMonth := 100
	if len(sub.Items.Data) > 0 {
		priceID := sub.Items.Data[0].Price.ID
		planSlug = h.planSlugFromPriceID(priceID)
		maxWorkers, maxJobsMonth = h.planLimitsFromSlug(planSlug)
	}

	var planID string
	if planSlug != "" {
		_ = h.db.QueryRow(r.Context(),
			`SELECT id FROM plans WHERE slug=$1`, planSlug,
		).Scan(&planID)
	}

	currentPeriodEnd := time.Unix(sub.CurrentPeriodEnd, 0)

	if planID != "" {
		_, _ = h.db.Exec(r.Context(),
			`UPDATE subscriptions
			 SET status=$2, plan_id=$3, stripe_subscription_id=$4,
			     current_period_start=$5, current_period_end=$6,
			     cancel_at_period_end=$7, max_workers=$8, max_jobs_month=$9,
			     updated_at=NOW()
			 WHERE business_id=$1`,
			bizID,
			string(sub.Status),
			planID,
			sub.ID,
			time.Unix(sub.CurrentPeriodStart, 0),
			currentPeriodEnd,
			sub.CancelAtPeriodEnd,
			maxWorkers,
			maxJobsMonth,
		)
	} else {
		// Update without changing plan_id if we couldn't resolve it.
		_, _ = h.db.Exec(r.Context(),
			`UPDATE subscriptions
			 SET status=$2, stripe_subscription_id=$3,
			     current_period_start=$4, current_period_end=$5,
			     cancel_at_period_end=$6, updated_at=NOW()
			 WHERE business_id=$1`,
			bizID,
			string(sub.Status),
			sub.ID,
			time.Unix(sub.CurrentPeriodStart, 0),
			currentPeriodEnd,
			sub.CancelAtPeriodEnd,
		)
	}
}

func (h *StripeHandler) handleSubscriptionDeleted(r *http.Request, sub *stripe.Subscription) {
	_, _ = h.db.Exec(r.Context(),
		`UPDATE subscriptions
		 SET status='canceled', canceled_at=NOW(), updated_at=NOW()
		 WHERE stripe_subscription_id=$1`,
		sub.ID,
	)
}

func (h *StripeHandler) handleInvoicePaymentSucceeded(r *http.Request, inv *stripe.Invoice) {
	if inv.Subscription == nil {
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE subscriptions
		 SET status='active', updated_at=NOW()
		 WHERE stripe_subscription_id=$1`,
		inv.Subscription.ID,
	)
}

func (h *StripeHandler) handleInvoicePaymentFailed(r *http.Request, inv *stripe.Invoice) {
	if inv.Subscription == nil {
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE subscriptions
		 SET status='past_due', updated_at=NOW()
		 WHERE stripe_subscription_id=$1`,
		inv.Subscription.ID,
	)
}

func (h *StripeHandler) planSlugFromPriceID(priceID string) string {
	switch priceID {
	case h.cfg.StripePriceStarter:
		return "starter"
	case h.cfg.StripePricePro:
		return "pro"
	case h.cfg.StripePriceEnterprise:
		return "enterprise"
	default:
		return ""
	}
}

func (h *StripeHandler) planLimitsFromSlug(slug string) (maxWorkers, maxJobsMonth int) {
	switch slug {
	case "starter":
		return 3, 50
	case "pro":
		return 15, 500
	case "enterprise":
		return 9999, 9999
	default:
		return 5, 100
	}
}

func stripeRespond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
