package middleware

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/db"
)

// WithTenantRLSHooks returns a db.ConfigOption that wires per-acquire
// pool hooks so every query runs with `app.current_business_id` set
// to the caller's business_id. Combined with migration
// 000043_rls_tenant_isolation, this turns Postgres RLS into a hard
// backstop: any handler that ever forgets a `WHERE business_id=...`
// filter will silently see zero rows from other tenants instead of
// leaking them.
//
// Mechanics:
//   - BeforeAcquire reads the request ctx for CtxBusinessID. If
//     present, runs `SELECT set_tenant($1::uuid)` on the connection
//     before handing it to the caller.
//   - AfterRelease runs `SELECT clear_tenant()` to reset the GUC so
//     the next caller (potentially a different request) starts clean.
//
// Connections used outside an authenticated request — health checks,
// background workers, the Stripe webhook (public group), migrations —
// have no bizID in ctx; the hook leaves them alone and the policy's
// "permissive when unset" branch lets queries through.
func WithTenantRLSHooks(log *zap.Logger) db.ConfigOption {
	return func(cfg *pgxpool.Config) {
		cfg.BeforeAcquire = func(ctx context.Context, conn *pgx.Conn) bool {
			bizID, ok := ctx.Value(CtxBusinessID).(uuid.UUID)
			if !ok || bizID == uuid.Nil {
				// No tenant set — let the connection pass; the policy's
				// permissive-when-unset branch handles cross-tenant
				// admin / cron / webhook access.
				return true
			}
			if _, err := conn.Exec(ctx, "SELECT set_tenant($1::uuid)", bizID); err != nil {
				log.Warn("rls set_tenant failed",
					zap.String("business_id", bizID.String()),
					zap.Error(err))
				return false
			}
			return true
		}
		cfg.AfterRelease = func(conn *pgx.Conn) bool {
			// Use a fresh background ctx — the request ctx may already
			// be cancelled when Release fires.
			if _, err := conn.Exec(context.Background(), "SELECT clear_tenant()"); err != nil {
				log.Warn("rls clear_tenant failed", zap.Error(err))
				// Returning false discards the connection so the next
				// caller doesn't inherit our tenant.
				return false
			}
			return true
		}
	}
}
