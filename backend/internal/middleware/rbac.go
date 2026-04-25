package middleware

import (
	"context"
	"net/http"
	"time"
)

// ── Role hierarchy ─────────────────────────────────────────────────
// owner > admin > manager > worker = accountant > customer

var roleLevel = map[string]int{
	"owner":      5,
	"admin":      4,
	"manager":    3,
	"worker":     2,
	"accountant": 2,
	"customer":   1,
}

// RequireAtLeast passes if the caller's role level >= minRole.
func RequireAtLeast(minRole string) func(http.Handler) http.Handler {
	minLevel := roleLevel[minRole]
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims := ClaimsFromCtx(r.Context())
			if claims == nil || roleLevel[claims.Role] < minLevel {
				http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func RequireOwner() func(http.Handler) http.Handler        { return RequireAtLeast("owner") }
func RequireOwnerOrAdmin() func(http.Handler) http.Handler { return RequireAtLeast("admin") }
func RequireManager() func(http.Handler) http.Handler      { return RequireAtLeast("manager") }

// ── Subscription context ───────────────────────────────────────────

type contextSubKey struct{}

// SubscriptionCtx holds the current plan state for the business.
type SubscriptionCtx struct {
	Status            string
	PlanSlug          string
	MaxWorkers        int
	MaxJobsMonth      int
	MaxStorageGB      float64
	TrialEndsAt       *time.Time
	CancelAtPeriodEnd bool
}

func (s *SubscriptionCtx) IsActive() bool {
	return s.Status == "active" || s.Status == "trialing" || s.Status == "past_due"
}

func (s *SubscriptionCtx) IsTrialing() bool { return s.Status == "trialing" }

// SubscriptionFromCtx retrieves the subscription context (loaded by TenantGuard).
func SubscriptionFromCtx(ctx context.Context) *SubscriptionCtx {
	v, _ := ctx.Value(contextSubKey{}).(*SubscriptionCtx)
	return v
}

// WithSubscription stores subscription context (called by TenantGuard).
func WithSubscription(ctx context.Context, sub *SubscriptionCtx) context.Context {
	return context.WithValue(ctx, contextSubKey{}, sub)
}

// RequirePlan blocks access if the business plan is below minPlan.
func RequirePlan(minPlan string) func(http.Handler) http.Handler {
	order := map[string]int{"starter": 1, "pro": 2, "enterprise": 3}
	minLevel := order[minPlan]
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			sub := SubscriptionFromCtx(r.Context())
			if sub == nil || order[sub.PlanSlug] < minLevel {
				http.Error(w, `{"error":"plan_upgrade_required","required_plan":"`+minPlan+`"}`, http.StatusPaymentRequired)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// RequireActiveSubscription blocks inactive/canceled accounts.
func RequireActiveSubscription() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			sub := SubscriptionFromCtx(r.Context())
			if sub == nil || !sub.IsActive() {
				http.Error(w, `{"error":"subscription_required"}`, http.StatusPaymentRequired)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
