package middleware

import (
	"context"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TenantGuard validates the business is active and loads subscription into context.
func TenantGuard(db *pgxpool.Pool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims := ClaimsFromCtx(r.Context())
			if claims == nil {
				http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
				return
			}

			var isActive bool
			if err := db.QueryRow(r.Context(),
				`SELECT is_active FROM businesses WHERE id=$1 AND deleted_at IS NULL`,
				claims.BusinessID,
			).Scan(&isActive); err != nil || !isActive {
				http.Error(w, `{"error":"business_not_found"}`, http.StatusForbidden)
				return
			}

			// Load subscription into context (non-blocking — missing subscription is allowed)
			sub := loadSubscription(r.Context(), db, claims.BusinessID)

			ctx := context.WithValue(r.Context(), CtxBusinessID, claims.BusinessID)
			ctx = WithSubscription(ctx, sub)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func loadSubscription(ctx context.Context, db *pgxpool.Pool, bizID uuid.UUID) *SubscriptionCtx {
	var sub SubscriptionCtx
	var trialEnds *time.Time
	err := db.QueryRow(ctx,
		`SELECT s.status, p.slug, p.max_workers, p.max_jobs_month, p.max_storage_gb, s.trial_ends_at, s.cancel_at_period_end
		 FROM subscriptions s JOIN plans p ON p.id=s.plan_id WHERE s.business_id=$1`, bizID,
	).Scan(&sub.Status, &sub.PlanSlug, &sub.MaxWorkers, &sub.MaxJobsMonth, &sub.MaxStorageGB, &trialEnds, &sub.CancelAtPeriodEnd)
	if err != nil {
		return &SubscriptionCtx{Status: "trialing", PlanSlug: "starter", MaxWorkers: 5, MaxJobsMonth: 100, MaxStorageGB: 5}
	}
	sub.TrialEndsAt = trialEnds
	return &sub
}

// ScopeQuery returns the business_id for use in WHERE clauses.
func ScopeQuery(ctx context.Context) uuid.UUID {
	return BusinessIDFromCtx(ctx)
}
