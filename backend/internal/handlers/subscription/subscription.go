package subscription

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"github.com/stripe/stripe-go/v79"
	"github.com/stripe/stripe-go/v79/checkout/session"
	stripecustomer "github.com/stripe/stripe-go/v79/customer"
	"github.com/stripe/stripe-go/v79/webhook"
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

// ── Get current subscription ──────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var sub struct {
		Status              string     `json:"status"`
		PlanName            string     `json:"plan_name"`
		PlanSlug            string     `json:"plan_slug"`
		PriceMonthly        float64    `json:"price_monthly"`
		MaxWorkers          int        `json:"max_workers"`
		MaxJobsMonth        int        `json:"max_jobs_month"`
		MaxStorageGB        float64    `json:"max_storage_gb"`
		TrialEndsAt         *time.Time `json:"trial_ends_at"`
		CurrentPeriodEnd    *time.Time `json:"current_period_end"`
		CancelAtPeriodEnd   bool       `json:"cancel_at_period_end"`
		StripeSubscriptionID *string   `json:"stripe_subscription_id,omitempty"`
	}

	err := h.db.QueryRow(r.Context(),
		`SELECT s.status, p.name, p.slug, COALESCE(p.price_monthly,0),
		        p.max_workers, p.max_jobs_month, p.max_storage_gb,
		        s.trial_ends_at, s.current_period_end, s.cancel_at_period_end, s.stripe_subscription_id
		 FROM subscriptions s JOIN plans p ON p.id=s.plan_id WHERE s.business_id=$1`, bizID,
	).Scan(&sub.Status, &sub.PlanName, &sub.PlanSlug, &sub.PriceMonthly,
		&sub.MaxWorkers, &sub.MaxJobsMonth, &sub.MaxStorageGB,
		&sub.TrialEndsAt, &sub.CurrentPeriodEnd, &sub.CancelAtPeriodEnd, &sub.StripeSubscriptionID)
	if err != nil {
		respond(w, 404, map[string]string{"error": "subscription_not_found"})
		return
	}

	// Current usage
	usage := h.getUsage(r, bizID.String())
	respond(w, 200, map[string]interface{}{
		"subscription": sub,
		"usage":        usage,
	})
}

// ── List plans ────────────────────────────────────────────────────

func (h *Handler) ListPlans(w http.ResponseWriter, r *http.Request) {
	rows, _ := h.db.Query(r.Context(),
		`SELECT id, name, slug, price_monthly, price_yearly, max_workers, max_jobs_month, max_storage_gb, features
		 FROM plans WHERE is_active=true ORDER BY price_monthly ASC`)
	defer rows.Close()

	var plans []map[string]interface{}
	for rows.Next() {
		p := make(map[string]interface{})
		var id, name, slug, features interface{}
		var priceM, priceY, storage float64
		var maxW, maxJ int
		_ = rows.Scan(&id, &name, &slug, &priceM, &priceY, &maxW, &maxJ, &storage, &features)
		p["id"] = id; p["name"] = name; p["slug"] = slug
		p["price_monthly"] = priceM; p["price_yearly"] = priceY
		p["max_workers"] = maxW; p["max_jobs_month"] = maxJ
		p["max_storage_gb"] = storage; p["features"] = features
		plans = append(plans, p)
	}
	if plans == nil {
		plans = []map[string]interface{}{}
	}
	respond(w, 200, plans)
}

// ── Upgrade (create Stripe Checkout session) ──────────────────────

func (h *Handler) Upgrade(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		PlanSlug string `json:"plan_slug"`
		Yearly   bool   `json:"yearly"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.PlanSlug == "" {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	if h.cfg.StripeSecretKey == "" {
		respond(w, 503, map[string]string{"error": "billing_not_configured"})
		return
	}

	// Get plan price ID
	var stripePriceID string
	switch req.PlanSlug {
	case "pro":
		stripePriceID = h.cfg.StripePricePro
	case "enterprise":
		stripePriceID = h.cfg.StripePriceEnterprise
	default:
		respond(w, 400, map[string]string{"error": "invalid_plan"})
		return
	}

	stripe.Key = h.cfg.StripeSecretKey

	// Get or create Stripe customer
	var stripeCustomerID string
	_ = h.db.QueryRow(r.Context(),
		`SELECT stripe_customer_id FROM businesses WHERE id=$1`, bizID,
	).Scan(&stripeCustomerID)

	if stripeCustomerID == "" {
		var email string
		_ = h.db.QueryRow(r.Context(), `SELECT email FROM users WHERE id=$1`, claims.UserID).Scan(&email)
		cust, err := stripecustomer.New(&stripe.CustomerParams{
			Email: stripe.String(email),
			Metadata: map[string]string{"business_id": bizID.String()},
		})
		if err == nil {
			stripeCustomerID = cust.ID
			_, _ = h.db.Exec(r.Context(),
				`UPDATE businesses SET stripe_customer_id=$2 WHERE id=$1`, bizID, stripeCustomerID)
		}
	}

	successURL := fmt.Sprintf("%s/settings/subscription?success=1", h.cfg.FrontendURL)
	cancelURL := fmt.Sprintf("%s/settings/subscription?canceled=1", h.cfg.FrontendURL)

	params := &stripe.CheckoutSessionParams{
		Customer:   stripe.String(stripeCustomerID),
		Mode:       stripe.String(string(stripe.CheckoutSessionModeSubscription)),
		SuccessURL: stripe.String(successURL),
		CancelURL:  stripe.String(cancelURL),
		LineItems: []*stripe.CheckoutSessionLineItemParams{
			{Price: stripe.String(stripePriceID), Quantity: stripe.Int64(1)},
		},
		SubscriptionData: &stripe.CheckoutSessionSubscriptionDataParams{
			Metadata: map[string]string{"business_id": bizID.String()},
		},
	}

	sess, err := session.New(params)
	if err != nil {
		h.log.Error("stripe checkout failed", zap.Error(err))
		respond(w, 500, map[string]string{"error": "billing_error"})
		return
	}

	respond(w, 200, map[string]string{"url": sess.URL})
}

// ── Cancel subscription ───────────────────────────────────────────

func (h *Handler) Cancel(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var stripeSubID string
	_ = h.db.QueryRow(r.Context(),
		`SELECT stripe_subscription_id FROM subscriptions WHERE business_id=$1`, bizID,
	).Scan(&stripeSubID)

	if stripeSubID != "" && h.cfg.StripeSecretKey != "" {
		stripe.Key = h.cfg.StripeSecretKey
		params := &stripe.SubscriptionParams{CancelAtPeriodEnd: stripe.Bool(true)}
		err := stripe.GetBackend(stripe.APIBackend).Call(
			"POST", "/v1/subscriptions/"+stripeSubID, h.cfg.StripeSecretKey, params, nil)
		if err != nil {
			h.log.Warn("stripe cancel failed", zap.Error(err))
		}
	}

	_, _ = h.db.Exec(r.Context(),
		`UPDATE subscriptions SET cancel_at_period_end=true, updated_at=NOW() WHERE business_id=$1`, bizID)

	respond(w, 200, map[string]string{"message": "subscription_canceled_at_period_end"})
}

// ── Usage ─────────────────────────────────────────────────────────

func (h *Handler) Usage(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	usage := h.getUsage(r, bizID.String())
	respond(w, 200, usage)
}

// ── Stripe Webhook ────────────────────────────────────────────────

func (h *Handler) StripeWebhook(w http.ResponseWriter, r *http.Request) {
	if h.cfg.StripeWebhookSecret == "" {
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

	switch event.Type {
	case "checkout.session.completed":
		var sess stripe.CheckoutSession
		if err := json.Unmarshal(event.Data.Raw, &sess); err == nil {
			h.handleCheckoutComplete(r, &sess)
		}
	case "customer.subscription.updated":
		var sub stripe.Subscription
		if err := json.Unmarshal(event.Data.Raw, &sub); err == nil {
			h.handleSubscriptionUpdated(r, &sub)
		}
	case "customer.subscription.deleted":
		var sub stripe.Subscription
		if err := json.Unmarshal(event.Data.Raw, &sub); err == nil {
			h.handleSubscriptionDeleted(r, &sub)
		}
	case "invoice.payment_failed":
		var inv stripe.Invoice
		if err := json.Unmarshal(event.Data.Raw, &inv); err == nil {
			h.handlePaymentFailed(r, &inv)
		}
	}

	w.WriteHeader(200)
}

// ── Internal ──────────────────────────────────────────────────────

func (h *Handler) handleCheckoutComplete(r *http.Request, sess *stripe.CheckoutSession) {
	bizID := sess.Metadata["business_id"]
	if bizID == "" || sess.Subscription == nil {
		return
	}
	subID := sess.Subscription.ID
	planSlug := h.getPlanSlugFromPriceID(r, sess.Subscription.Items.Data[0].Price.ID)
	var planID string
	_ = h.db.QueryRow(r.Context(), `SELECT id FROM plans WHERE slug=$1`, planSlug).Scan(&planID)
	if planID == "" {
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE subscriptions SET status='active', plan_id=$2, stripe_subscription_id=$3,
		  current_period_start=$4, current_period_end=$5, updated_at=NOW()
		 WHERE business_id=$1`,
		bizID, planID, subID,
		time.Unix(sess.Subscription.CurrentPeriodStart, 0),
		time.Unix(sess.Subscription.CurrentPeriodEnd, 0))
}

func (h *Handler) handleSubscriptionUpdated(r *http.Request, sub *stripe.Subscription) {
	bizID := sub.Metadata["business_id"]
	if bizID == "" {
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE subscriptions SET status=$2, cancel_at_period_end=$3,
		  current_period_start=$4, current_period_end=$5, updated_at=NOW()
		 WHERE stripe_subscription_id=$1`,
		sub.ID, string(sub.Status), sub.CancelAtPeriodEnd,
		time.Unix(sub.CurrentPeriodStart, 0),
		time.Unix(sub.CurrentPeriodEnd, 0))
}

func (h *Handler) handleSubscriptionDeleted(r *http.Request, sub *stripe.Subscription) {
	_, _ = h.db.Exec(r.Context(),
		`UPDATE subscriptions SET status='canceled', canceled_at=NOW(), updated_at=NOW()
		 WHERE stripe_subscription_id=$1`, sub.ID)
}

func (h *Handler) handlePaymentFailed(r *http.Request, inv *stripe.Invoice) {
	if inv.Subscription == nil {
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE subscriptions SET status='past_due', updated_at=NOW()
		 WHERE stripe_subscription_id=$1`, inv.Subscription.ID)
}

func (h *Handler) getPlanSlugFromPriceID(r *http.Request, priceID string) string {
	switch priceID {
	case h.cfg.StripePricePro:
		return "pro"
	case h.cfg.StripePriceEnterprise:
		return "enterprise"
	default:
		return "starter"
	}
}

func (h *Handler) getUsage(r *http.Request, bizID string) map[string]interface{} {
	var workerCount, jobsThisMonth int
	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM users WHERE business_id=$1 AND role!='customer' AND deleted_at IS NULL`, bizID,
	).Scan(&workerCount)
	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM jobs WHERE business_id=$1 AND created_at >= DATE_TRUNC('month',NOW())`, bizID,
	).Scan(&jobsThisMonth)
	return map[string]interface{}{
		"workers":       workerCount,
		"jobs_this_month": jobsThisMonth,
	}
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
