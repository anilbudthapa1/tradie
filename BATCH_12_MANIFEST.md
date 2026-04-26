# Batch 12 Manifest — Admin, Backup & Integrations (M111, M113, M115-M118, M120)

Status: ready for Phase B merge.
Base commit: `eb75849` (initial codebase).
Phase A is **not** present in this worktree — Stripe handler line 61 bug, RBAC `IsAtLeast`, and Files Delete admin guard are owned by Phase A.

---

## Files added

| Path | Purpose |
|---|---|
| `backend/internal/middleware/sentry.go` | `RecoverWithSentry()` middleware. No-op `sentryCapture()` swap-point; merges with sentry-go later. |
| `backend/internal/handlers/integrations/oauth.go` | Generic `OAuthHandler` + `OAuthProvider` registry (Xero, MYOB, QuickBooks, Google Calendar). Connect / Callback / Disconnect / Status. |
| `backend/internal/handlers/integrations/backup.go` | `BackupHandler.Request` — owner-only audit-only stub for M111. |
| `backend/migrations/000021_oauth_integrations.up.sql` | Ensures `integration_tokens` exists in goose-style migrations + adds `oauth_state` (CSRF). |
| `backend/migrations/000021_oauth_integrations.down.sql` | Drops `oauth_state`; preserves `integration_tokens`. |
| `docs/admin/backup_runbook.md` | DBA runbook referenced by `BACKUP_REQUESTED` response. |

## Files modified

| Path | Change |
|---|---|
| `backend/internal/handlers/files/files.go` | M120: mime-type allowlist on `Upload` (rejects unknown types with 415); `FILE_UPLOADED` audit (size + mime + entity_type); audit service pulled from variadic args or lazily constructed. |
| `mobile/lib/core/providers/settings_provider.dart` | Added `getIntegrationsStatus`, `startOAuthConnect`, `disconnectIntegration`, `getStripeStatus`, `createBillingPortal`. |
| `mobile/lib/features/settings/screens/integrations_screen.dart` | Replaced Coming-Soon Xero/MYOB/QBO/GCal tiles with live `_OAuthTile`s; added `integrationsStatusProvider`; added QuickBooks tile. |

---

## Migrations

- `000021_oauth_integrations.up.sql` — only new migration this batch.
- Idempotent (`CREATE TABLE IF NOT EXISTS`) so it runs cleanly on both fresh DBs and DBs already carrying the legacy `integration_tokens` from `internal/db/migrations/003_payroll_safety.sql`.

---

## Routes to wire (router.go diff for parent merge)

Insert after the existing `r.Route("/api/v1/files", …)` block, inside the authenticated group:

```go
// Integrations (OAuth — admin+ for connect/disconnect, status visible to all)
oauthH := integrations.NewOAuthHandler(cfg, db, log, audit)
r.Route("/api/v1/integrations", func(r chi.Router) {
    r.Get("/status", oauthH.Status)
    // OAuth callback is GET (browser redirect) but still inside the auth
    // group because the user must be logged in for the state cookie/session
    // to map to a business. If the redirect strips the JWT, move this to
    // a public route and rely on the state→business_id lookup in oauth_state.
    r.Get("/{provider}/callback", oauthH.Callback)

    r.Group(func(r chi.Router) {
        r.Use(middleware.RequireOwnerOrAdmin())
        r.Get("/{provider}/connect", oauthH.Connect)
        r.Delete("/{provider}", oauthH.Disconnect)
    })
})

// Admin — backup request stub (owner only)
backupH := integrations.NewBackupHandler(cfg, db, log, audit)
r.Route("/api/v1/admin", func(r chi.Router) {
    r.Use(middleware.RequireOwner())
    r.Post("/backup", backupH.Request)
})
```

Files handler — pass audit explicitly so the FILE_UPLOADED entry runs through the canonical service (optional; currently auto-built):

```go
fileH := files.NewHandler(cfg, db, log, audit)
```

---

## Mobile routes to wire (router.dart diff for parent merge)

Add to the GoRouter routes list (alongside `/settings/audit-log`):

```dart
GoRoute(
  path: '/settings/integrations',
  builder: (_, __) => const IntegrationsScreen(),
),
```

The OAuth completion redirects to `${FRONTEND_URL}/settings/integrations?integration=xero&status=connected` so this route should also handle those query params (no parsing required for MVP — page just refetches status).

---

## Pubspec — no new deps required

The integrations screen already uses `url_launcher`, `shared_preferences`, `flutter_riverpod`, `iconsax_flutter`, all present.

If a webview-style in-app OAuth flow is added later: depend on `webview_flutter` (already in pubspec) instead of `url_launcher`.

---

## Sentry — needs-key wiring (cmd/main.go snippet)

`SENTRY_DSN` is already in `config.Config` (line 49 / 101). The middleware exists. To complete M113, the Phase B merge needs three things:

1. Add to `backend/go.mod`:
   ```
   require github.com/getsentry/sentry-go v0.28.0
   ```
   then `go mod tidy`.

2. Add to `backend/cmd/main.go` near the top of `main()`, before `router.New(...)`:

   ```go
   import sentryHTTP "github.com/getsentry/sentry-go/http"
   import "github.com/getsentry/sentry-go"

   if cfg.SentryDSN != "" {
       if err := sentry.Init(sentry.ClientOptions{
           Dsn:              cfg.SentryDSN,
           Environment:      cfg.Env,
           Release:          os.Getenv("APP_VERSION"),
           AttachStacktrace: true,
           TracesSampleRate: 0.1,
       }); err != nil {
           log.Warn("sentry init failed", zap.Error(err))
       } else {
           defer sentry.Flush(2 * time.Second)
       }
   }
   ```

3. Add to `backend/internal/router/router.go` — global middleware section, after `RequestLogger`:

   ```go
   if cfg.SentryDSN != "" {
       r.Use(sentryHTTP.New(sentryHTTP.Options{Repanic: true}).Handle)
   }
   r.Use(middleware.RecoverWithSentry(log)) // replaces chimid.Recoverer
   ```

   Then replace the `sentryCapture()` body in `internal/middleware/sentry.go` with:

   ```go
   hub := sentry.GetHubFromContext(r.Context())
   if hub == nil {
       hub = sentry.CurrentHub().Clone()
   }
   hub.RecoverWithContext(r.Context(), rec)
   hub.Flush(2 * time.Second)
   ```

The middleware already logs panics via zap, so even without the swap-in it is safe to wire today (it will behave like `chimid.Recoverer`).

---

## needs-key items

| Env var | Used by | Effect when missing |
|---|---|---|
| `SENTRY_DSN` | M113 init in `main.go` | Sentry init skipped; `RecoverWithSentry` still recovers + zap-logs. |
| `XERO_CLIENT_ID` + `XERO_CLIENT_SECRET` | `oauth.go` Xero provider | `/integrations/xero/connect` returns 503 `integration_not_configured`. |
| `MYOB_CLIENT_ID` + `MYOB_CLIENT_SECRET` | MYOB provider | 503. |
| `QUICKBOOKS_CLIENT_ID` + `QUICKBOOKS_CLIENT_SECRET` | QuickBooks provider | 503. |
| `GOOGLE_CALENDAR_CLIENT_ID` + `GOOGLE_CALENDAR_CLIENT_SECRET` | Google Calendar provider | 503. |

All four OAuth providers also need their redirect URI registered with the vendor: `${BASE_URL}/api/v1/integrations/{provider}/callback`.

---

## Audit events introduced

| Action | Where | Notes |
|---|---|---|
| `integration.oauth_connect_started` | `oauth.go` Connect | Records before redirect. |
| `integration.connected` | `oauth.go` Callback | Records after successful token exchange. |
| `integration.disconnected` | `oauth.go` Disconnect | Records on revoke. |
| `BACKUP_REQUESTED` | `backup.go` Request | Owner-only. |
| `FILE_UPLOADED` | `files.go` Upload | Includes size, mime, entity_type. |

---

## Build verification

```sh
go build ./internal/middleware/      # PASS
go build ./internal/handlers/files/  # PASS
go vet   ./internal/handlers/integrations/oauth.go ./internal/handlers/integrations/backup.go  # PASS
gofmt -l ./internal/handlers/integrations/oauth.go ./internal/handlers/integrations/backup.go ./internal/handlers/files/files.go ./internal/middleware/sentry.go  # clean
```

`go build ./internal/handlers/integrations/...` fails on `stripe.go:61` (the pre-existing Phase A bug — out of scope per spec). Verified my code compiles by temporarily patching `claims.UserID` → `claims.UserID.String()`; full package then builds cleanly.

---

## What this batch does NOT do

- Sentry init in `main.go` — manifest snippet only (file is off-limits to me).
- Real Xero/MYOB/QBO/GCal data sync — only OAuth connect/disconnect + token persistence. The actual sync workers (`sync_invoices`, `push_calendar_event`) are follow-up modules.
- Performing a database backup — runbook only, by design (M111 spec § "out of scope for in-app").
- File mime sniffing — we trust `Content-Type` header. Magic-byte sniffing is a hardening follow-up.
