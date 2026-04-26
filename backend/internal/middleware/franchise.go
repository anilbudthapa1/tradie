package middleware

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// BranchIDsForCurrentTenant returns the set of business_ids that the current
// caller is permitted to query across (M128 multi-branch).
//
// Behaviour:
//   - Returns just the caller's own business_id when it is NOT a franchise
//     parent (the common case — franchise has zero perf cost).
//   - When the caller's business is flagged is_franchise_parent=TRUE, returns
//     the parent's id followed by every child's id (parent_business_id = caller).
//
// Handlers that want to be branch-aware should call this and use the returned
// slice with `WHERE business_id = ANY($1)` instead of `WHERE business_id = $1`.
//
// Pattern:
//
//	bizIDs := middleware.BranchIDsForCurrentTenant(r.Context(), h.db)
//	rows, err := h.db.Query(ctx, `SELECT ... WHERE business_id = ANY($1)`, bizIDs)
//
// Default handlers that are not yet branch-aware will simply scope to the
// caller's own business_id (BusinessIDFromCtx) — that remains correct and
// secure for non-franchise tenants.
func BranchIDsForCurrentTenant(ctx context.Context, db *pgxpool.Pool) []uuid.UUID {
	bizID := BusinessIDFromCtx(ctx)
	if bizID == uuid.Nil {
		return nil
	}
	out := []uuid.UUID{bizID}

	var isParent bool
	err := db.QueryRow(ctx,
		`SELECT COALESCE(is_franchise_parent, FALSE) FROM businesses WHERE id=$1`,
		bizID,
	).Scan(&isParent)
	if err != nil || !isParent {
		return out
	}

	rows, err := db.Query(ctx,
		`SELECT id FROM businesses WHERE parent_business_id=$1 AND is_active=TRUE`,
		bizID,
	)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var child uuid.UUID
		if err := rows.Scan(&child); err == nil {
			out = append(out, child)
		}
	}
	return out
}

// IsFranchiseParent reports whether the current caller's business is flagged
// as a franchise parent. Used by franchise endpoints to gate child-listing.
func IsFranchiseParent(ctx context.Context, db *pgxpool.Pool) bool {
	bizID := BusinessIDFromCtx(ctx)
	if bizID == uuid.Nil {
		return false
	}
	var v bool
	if err := db.QueryRow(ctx,
		`SELECT COALESCE(is_franchise_parent, FALSE) FROM businesses WHERE id=$1`,
		bizID,
	).Scan(&v); err != nil {
		return false
	}
	return v
}
