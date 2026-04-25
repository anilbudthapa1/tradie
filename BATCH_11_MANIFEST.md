# Batch 11 — Search, Export & Security (modules 101-110)

Worktree: `agent-adf75675ab752848a` (base `eb75849`).
Scope: P0 M105 Bulk Import, P0 M106 Bulk Update, P0 M110 Permission Management,
P1 M102 Saved Filters, P1 M109 mobile 2FA setup screen.

## 1. Module status

| # | Module | Before | After |
|---|--------|--------|-------|
| 101 | Global Search | partial (existing handler) | partial — untouched (out of scope this batch) |
| 102 | Advanced Filters / saved filter sets | missing | **partial** — saved_filters table + CRUD endpoints (UI deferred) |
| 103 | Reports CSV export | partial | unchanged (Phase A added export audit) |
| 104 | Reports PDF export | partial | unchanged (Phase A added export audit) |
| 105 | Bulk Import (CSV) | missing | **partial→done** — table, CSV upload, async goroutine processor, per-row audit, progress endpoint |
| 106 | Bulk Update | missing | **done** — allow-list-validated bulk PATCH endpoint with per-row audit |
| 107 | Sessions / device list | done (Phase A audited) | unchanged |
| 108 | Audit log viewer | partial | unchanged |
| 109 | 2FA backend | done | **done + mobile** — new `MfaSetupScreen` (QR + secret + backup codes + verify) |
| 110 | Permission Management | missing | **done** — permissions catalog seeded, role_permissions table, three endpoints, mobile admin screen |

## 2. Migration

`backend/migrations/000020_batch11_security.up.sql` (+ `.down.sql`):

- `bulk_import_jobs` (id, business_id, entity_type enum [customers/jobs/expenses], file_id, file_name, status enum [pending/processing/completed/failed_partial/failed], total_rows, processed_rows, success_rows, error_log JSONB, created_by, created_at, completed_at)
- `permissions` (id, key UNIQUE, description, category) — seeded with 33 canonical keys
- `role_permissions` (role, permission_id, business_id NULLable) — `business_id IS NULL` rows = built-in template, per-business rows override the template
- `saved_filters` (id, user_id, business_id, entity_type, name, filter_spec JSONB, is_shared)

All `CREATE TABLE` and `INSERT` use `IF NOT EXISTS` / `ON CONFLICT DO NOTHING` for idempotency.

## 3. Backend — files added

- `backend/internal/handlers/bulk_import/bulk_import.go`
- `backend/internal/handlers/bulk_update/bulk_update.go`
- `backend/internal/handlers/permissions/permissions.go`
- `backend/internal/handlers/filters/filters.go`

All four packages build clean (`go build ./internal/handlers/{bulk_import,bulk_update,permissions,filters}/...`).

### 3a. Router merge — imports

Add to `backend/internal/router/router.go` import block:

```go
"github.com/tradie/api/internal/handlers/bulk_import"
"github.com/tradie/api/internal/handlers/bulk_update"
"github.com/tradie/api/internal/handlers/filters"
"github.com/tradie/api/internal/handlers/permissions"
```

### 3b. Router merge — route registration

Inside the authenticated `r.Group(func(r chi.Router) { ... })` block (after existing handlers):

```go
// Bulk import — admin+
biH := bulk_import.NewHandler(cfg, db, log, audit)
r.Route("/api/v1/bulk-import", func(r chi.Router) {
    r.Use(middleware.RequireAtLeast("admin"))
    r.Get("/", biH.List)
    r.Post("/", biH.Create)
    r.Get("/{id}", biH.Get)
})

// Bulk update — admin+
buH := bulk_update.NewHandler(cfg, db, log, audit)
r.Route("/api/v1/bulk-update", func(r chi.Router) {
    r.Use(middleware.RequireAtLeast("admin"))
    r.Post("/{entity_type}", buH.Apply)
})

// Permission management
permH := permissions.NewHandler(cfg, db, log, audit)
r.Route("/api/v1/permissions", func(r chi.Router) {
    r.Get("/", permH.Effective) // any authenticated user
    r.Group(func(r chi.Router) {
        r.Use(middleware.RequireAtLeast("admin"))
        r.Get("/all", permH.ListAll)
    })
    r.Group(func(r chi.Router) {
        r.Use(middleware.RequireOwner())
        r.Put("/role/{role}", permH.UpdateRole)
    })
})

// Saved filters — any authenticated user
filtH := filters.NewHandler(cfg, db, log)
r.Route("/api/v1/filters", func(r chi.Router) {
    r.Get("/", filtH.List)
    r.Post("/", filtH.Create)
    r.Delete("/{id}", filtH.Delete)
})
```

## 4. Mobile

### Files added

- `mobile/lib/features/auth/screens/mfa_setup_screen.dart` — class `MfaSetupScreen`
- `mobile/lib/features/settings/screens/permissions_screen.dart` — class `PermissionsScreen`

### Router merge — `mobile/lib/core/router/router.dart`

Add imports:

```dart
import '../../features/auth/screens/mfa_setup_screen.dart';
import '../../features/settings/screens/permissions_screen.dart';
```

Add routes inside the main shell route list:

```dart
GoRoute(path: '/auth/mfa-setup', builder: (_, __) => const MfaSetupScreen()),
GoRoute(path: '/settings/permissions', builder: (_, __) => const PermissionsScreen()),
```

(The MFA setup screen is reachable from the existing settings/security area; the parent should add a "Two-factor auth" tile that pushes `/auth/mfa-setup`. The permissions screen should be exposed only when `claims.role == 'owner' || 'admin'`.)

### Pubspec deps — needs-dep

Parent must add to `mobile/pubspec.yaml` `dependencies:`

```yaml
qr_flutter: ^4.1.0
```

(Used only by `mfa_setup_screen.dart`. No other new packages required — `dio`, `flutter_riverpod`, `iconsax_flutter`, `flutter_secure_storage` were already present.)

## 5. needs-key / needs-dep / needs-scheduler

| Item | Type | Where | Notes |
|------|------|-------|-------|
| `qr_flutter` | needs-dep | mobile/pubspec.yaml | required for `MfaSetupScreen` QR rendering |
| Bulk-import async runner | needs-scheduler | bulk_import.process | Currently runs in an in-process goroutine; for production, replace with a queue worker (e.g. NATS / Redis stream / cron + DB poll) so jobs survive restarts |
| Per-business permission cache | future | permissions handler | Effective-permissions query is uncached; acceptable for now (read on login), revisit if hit rate becomes a hotspot |
| Permission enforcement on routes | follow-up | router | This batch ships *observability* of role->permission map. Phase A's `RequireAtLeast` is still the primary RBAC gate. A future change should wire `RequirePermission("jobs.create")` middleware that consults `role_permissions` |

## 6. Files touched (one line each)

- `backend/migrations/000020_batch11_security.up.sql` — new tables: bulk_import_jobs, permissions, role_permissions, saved_filters; seed permission catalog + default role grants
- `backend/migrations/000020_batch11_security.down.sql` — drops the four tables
- `backend/internal/handlers/bulk_import/bulk_import.go` — multipart CSV upload, header allow-list validation, async goroutine processor, per-row audit, progress GET
- `backend/internal/handlers/bulk_update/bulk_update.go` — allow-list-validated bulk PATCH (`jobs.status`, `leads.assigned_to`, `customers.is_active`, `invoices.due_date`), per-row audit
- `backend/internal/handlers/permissions/permissions.go` — three endpoints (effective / list-all / update-role), business-override semantics
- `backend/internal/handlers/filters/filters.go` — saved filter CRUD scoped to user + shared sets
- `mobile/lib/features/auth/screens/mfa_setup_screen.dart` — three-step setup wizard (intro → QR + backup codes + verify → success)
- `mobile/lib/features/settings/screens/permissions_screen.dart` — role selector + grouped permission toggles + save (admin/owner only)
- `BATCH_11_MANIFEST.md` — this file

## 7. Build verification

```
cd backend && go build ./internal/handlers/bulk_import/... \
                       ./internal/handlers/bulk_update/... \
                       ./internal/handlers/permissions/... \
                       ./internal/handlers/filters/...
# clean
```

Full-tree build intentionally not run (pre-existing stripe.go bug — fixed by Phase A, out of scope here).
