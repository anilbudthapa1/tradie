# Batch 02 Implementation Manifest

## Summary
- Modules covered: 11-20
- Status: Done 2 (M14, M19) · Partial improved 5 (M13, M15, M16, M17, M18) · Untouched 3 (M11, M12, M20)
- Skipped: M11 Dashboard, M12 KPI Widgets, M20 Lead Management — already wired sufficiently per gap analysis. No P0/P1 deltas for this batch.
- Build: `go build ./...` passes for every package this batch touched. The repo as a whole still has one **pre-existing** error in `backend/internal/handlers/integrations/stripe.go:61` (`claims.UserID` typed as `uuid.UUID` passed where `string` expected) that is unrelated to Batch 02. Verified by stashing and re-building; the error reproduces without any of my changes.

## Backend integration (for router.go merge)

Add the import:
```go
activityH "github.com/tradie/api/internal/handlers/activity"
remindersH "github.com/tradie/api/internal/handlers/reminders"
remsvc "github.com/tradie/api/internal/services/reminders"
```

In the authenticated group (after `audit := middleware.NewAuditService(db, log)`):

```go
// ── Activity Feed (M14) ─────────────────────────────────────────
actH := activityH.NewHandler(cfg, db, log, audit)
r.Route("/api/v1/activity", func(r chi.Router) {
    r.Use(middleware.RequireAtLeast("manager"))
    r.Get("/", actH.List)
})

// ── Reminders (M13) — stub-able dispatcher ──────────────────────
remDispatcher := remsvc.NewNoopDispatcher(log) // swap for real provider when push infra lands
remH := remindersH.NewHandler(cfg, db, log, audit, remDispatcher)
r.Route("/api/v1/internal/reminders", func(r chi.Router) {
    r.Use(middleware.RequireOwnerOrAdmin())
    r.Post("/run", remH.Run)
})
```

In the existing `/api/v1/tasks` route group, add ONE line:

```go
r.Post("/{id}/snooze", remH.Snooze)
```

In the existing `/api/v1/customers` route group, add ONE line for M19:

```go
r.Get("/{id}/history", custH.History)
```

## Mobile integration (for router.dart merge)

Routes to add (path + widget class):
- `/customers/:id/history` → `CustomerHistoryScreen(customerId: id)`
  Import: `package:tradie/features/customers/screens/customer_history_screen.dart`

Note: the customer detail screen (`_HistoryTab`) also opens `CustomerHistoryScreen` directly via `Navigator.push`, so the named route is optional but recommended for deep-linking.

## Mobile deps (for pubspec.yaml merge)
- (no new packages required — uses existing `flutter_riverpod`, `iconsax_flutter`, `dio`)

## Migrations added
- `backend/migrations/000011_activity_history.up.sql` + `.down.sql` — Adds composite indexes backing the new Activity Feed (`audit_logs (business_id, created_at DESC)`, `audit_logs (business_id, entity_type, created_at DESC)`) and Customer History UNION legs (`jobs/quotes/invoices/customer_notes` on `(customer_id, business_id, created_at DESC)` and `invoice_payments (invoice_id, business_id, paid_at DESC)`). All `IF NOT EXISTS`, idempotent.

## Needs-key items
- **M13 Task Reminder needs a scheduler.** Reminders only fire when an admin calls `POST /api/v1/internal/reminders/run`. The dispatcher interface is in `backend/internal/services/reminders/`. To go live, ops needs to:
  1. Either run a cron job that hits this endpoint, or build `cmd/cron` that calls `remsvc.NewRunner(db, log, dispatcher).Run(ctx, uuid.Nil)` on a tick.
  2. Replace `remsvc.NewNoopDispatcher(log)` with a real implementation (Twilio for SMS, FCM/APNs for push) once Batch 09 (M88-M90) lands.
- No new env vars required by Batch 02 itself.

## Per-module status table
| ID  | Module              | Before        | After         | Notes |
|-----|---------------------|---------------|---------------|-------|
| M11 | Dashboard           | partial    | partial    | unchanged this batch |
| M12 | KPI Widgets         | partial    | partial    | unchanged this batch |
| M13 | Task Reminder       | partial    | partial    | dispatcher stubbed; snooze API + UI shipped; needs scheduler |
| M14 | Activity Feed       | missing    | done       | new endpoint, manager+ RBAC, audit, mobile widget rewired |
| M15 | Customer Management | done       | done       | unchanged (already done) |
| M16 | Customer Contact    | partial    | partial    | added email validation, audit on AddContact |
| M17 | Customer Address    | partial    | partial    | postcode validation, country default AU, audit on add/update/delete |
| M18 | Customer Notes      | partial    | partial    | audit on AddNote |
| M19 | Customer History    | missing    | done       | unified UNION endpoint, mobile timeline screen, audit |
| M20 | Lead Management     | partial    | partial    | unchanged this batch |

## Files touched

### Backend (new)
- `backend/internal/handlers/activity/activity.go` — Activity Feed list endpoint, derives category, audits read.
- `backend/internal/handlers/reminders/reminders.go` — `Run` (drains due reminders) + `Snooze` (per-task) HTTP handlers.
- `backend/internal/services/reminders/reminders.go` — `ReminderDispatcher` interface, `NoopDispatcher`, `Runner` that claims+dispatches in one UPDATE.
- `backend/migrations/000011_activity_history.up.sql` — composite indexes for activity feed + customer history.
- `backend/migrations/000011_activity_history.down.sql` — drops the same indexes.

### Backend (edited)
- `backend/internal/middleware/rbac.go` — added `IsAtLeast(role, minRole)` helper for in-handler role checks.
- `backend/internal/handlers/customers/customers.go` —
  - new imports: `net/mail`, `regexp`, `strings`, `time`, `github.com/google/uuid`
  - new `auPostcode` regex
  - `AddContact`: rejects malformed emails, audits `CUSTOMER_CONTACT_ADDED`
  - `AddAddress`: defaults country to `AU`, validates AU postcode, audits `CUSTOMER_ADDRESS_ADDED`
  - `UpdateAddress`: defaults country, validates AU postcode, audits `CUSTOMER_ADDRESS_UPDATED`
  - `DeleteAddress`: audits `CUSTOMER_ADDRESS_DELETED`
  - `AddNote`: audits `CUSTOMER_NOTE_ADDED`
  - new `History` handler returning unified jobs/quotes/invoices/payments/notes timeline; tenant-scoped + audited

### Mobile (new)
- `mobile/lib/features/dashboard/providers/activity_provider.dart` — `ActivityItem` model, `ActivityFilter`, `activityFeedProvider` family.
- `mobile/lib/features/customers/providers/customer_history_provider.dart` — `CustomerHistoryItem` model + family provider.
- `mobile/lib/features/customers/screens/customer_history_screen.dart` — full timeline screen (loading/error/empty/data), kind badges + iconsax icons.

### Mobile (edited)
- `mobile/lib/features/dashboard/widgets/activity_feed_widget.dart` — switched data source from `dashboardStatsProvider` to `activityFeedProvider`; now supports `entityType` filter; added retry on error; expanded category icon/color set.
- `mobile/lib/features/dashboard/providers/dashboard_provider.dart` — added `snooze(id, duration)` to `TaskNotifier`.
- `mobile/lib/features/tasks/screens/tasks_screen.dart` — `_ActionMenu` gains "Snooze 1 hour" and "Snooze to tomorrow" entries with snackbar feedback.
- `mobile/lib/features/customers/screens/customer_detail_screen.dart` — `_HistoryTab` gains a "Unified Timeline" navigation card that opens `CustomerHistoryScreen`.
