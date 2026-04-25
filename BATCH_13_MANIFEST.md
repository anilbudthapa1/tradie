# Batch 13 — Growth, Mobile & Advanced

Worktree: `agent-aa95fa73a05cb32b1` (base `eb75849`).
Migration owned: **000022** only.

## Files added

```
backend/migrations/000022_batch13_growth_advanced.up.sql
backend/migrations/000022_batch13_growth_advanced.down.sql
backend/internal/middleware/franchise.go
backend/internal/services/transcription/transcription.go
backend/internal/handlers/voice_notes/voice_notes.go
backend/internal/handlers/franchise/franchise.go
backend/internal/handlers/referrals/referrals.go
backend/internal/handlers/i18n/i18n.go
```

## Files modified

```
backend/internal/handlers/ai/assistant.go    -- M125 hardening
```

## Migration 000022 changes

- `ai_conversation_logs` table (M125 audit + context)
- `voice_notes` table + indexes (M126)
- `businesses.parent_business_id` + `is_franchise_parent` (M128)
- `business_branding_settings` extensions: `custom_domain` UNIQUE, `footer_text`,
  `email_from_name`, `hide_powered_by` (M122)
- `referrals` table (M123)
- `translation_strings` table (M127) seeded with ~13 baseline `en` keys

All `ALTER` / `CREATE` are idempotent (`IF NOT EXISTS`). Down migration removes
only what 000022 added.

## P0 deliverables

### M125 — AI Assistant hardening (`backend/internal/handlers/ai/assistant.go`)

- Input sanitization (`sanitizePrompt`):
  - rejects empty / >8000 chars
  - strips `\x00` null bytes
  - rejects substrings (case-insensitive): `<<system>>`, `ignore previous instructions`,
    `ignore all previous instructions`, `ignore the above`, `disregard previous instructions`
  - `safePageTag` allow-lists context page name to `[A-Za-z0-9_-]{0,32}`
- **Redis-backed rate limiter** keyed by `ai:rate:<user_id>:<minute>` (per-user,
  20 prompts/min, fail-open on Redis error). The previous in-memory limiter is
  removed.
- **Persistence**: every user message and assistant reply written to
  `ai_conversation_logs` with `tokens_used` from Anthropic usage.
- **Conversation context**: `conversation_id` accepted via JSON body or
  `?conversation_id=` query. Last 10 turns from the same conversation are
  loaded as message history.
- **Audit**: `AI_PROMPT` / `AI_SUMMARIZE` actions logged with
  `{prompt_length, model, tokens_used}` only — full content lives in
  `ai_conversation_logs`.
- New endpoint `GET /ai/conversations/{id}` returns the caller's own turns for
  a conversation (auto-registered via `Routes()`).
- `NewHandler` accepts variadic opts so an existing call site
  `ai.NewHandler(cfg, db, log)` still compiles; Redis is built from
  `cfg.RedisURL` if not supplied.

### M126 — Voice Notes (`backend/internal/handlers/voice_notes/`)

- `Transcriber` interface in `internal/services/transcription/`. Default
  `StubTranscriber` returns `"Transcription not configured"` — **needs-key:**
  `ANTHROPIC_API_KEY` (Claude audio) or `ASSEMBLYAI_API_KEY`.
- `Routes()`:
  - `POST /presign` — presigned PUT URL valid 15 min, scoped to `<bizID>/voice-notes/<uuid>.<ext>`
  - `POST /` — finalize: tx-inserts `files` + `voice_notes`, validates job ownership
  - `GET /?job_id=...` — manager+ sees all in tenant; workers see only own
  - `POST /{id}/transcribe` — owner of note OR manager+; flips status
    `pending`→`processing`, runs transcriber in goroutine, persists
    `transcript`/`completed` or `error_message`/`error`
- 25 MB upload cap; storage-key prefix verified to prevent cross-tenant uploads.

### M128 — Franchise / Multi-branch

- `middleware/franchise.go`:
  - `BranchIDsForCurrentTenant(ctx, db) []uuid.UUID` — returns caller's
    business_id, plus all child ids when `is_franchise_parent=TRUE`.
  - `IsFranchiseParent(ctx, db) bool`.
- `handlers/franchise/franchise.go` `Routes()`:
  - `GET /branches` — lists children (parent only)
  - `POST /branches` — creates child business under caller, optionally
    inheriting branding / tax / invoice settings; auto-marks parent as
    `is_franchise_parent=TRUE`.
- **Adoption pattern (documented for follow-up)**: existing handlers should
  switch tenant-scoped queries from
  `WHERE business_id=$1` to
  `WHERE business_id = ANY($1)` and pass
  `middleware.BranchIDsForCurrentTenant(ctx, h.db)`. Not refactored in this
  batch — non-franchise tenants are unaffected by the helper's default return.

## P1 deliverables

### M122 — White Label

Schema-only here (handler exists per Phase A). 000022 adds the four columns
plus partial unique index on `custom_domain` (NULLs allowed; uniqueness on
real values).

### M123 — Referrals (`backend/internal/handlers/referrals/`)

- `Routes()`:
  - `POST /` — any auth user; generates 10-char base32 code, validates email
  - `GET /` — own list
  - `GET /all` — admin+ (caller wraps in `RequireAtLeast("admin")`)
  - `POST /{id}/payout` — owner; sets `reward_paid_at`, audited
- Audited actions: `REFERRAL_CREATED`, `REFERRAL_PAYOUT`.
- TODO comment: outbound email send wires through M88 notification scheduler
  once that exists; today the row is recorded with `status='sent'`.

### M127 — Multi-language (`backend/internal/handlers/i18n/`)

- `GET /{language}` returns
  `{"language":"<lang>","strings":{"common.app.name":"...", ...}}`.
- Single SQL with `COALESCE` so any key missing in the requested language
  falls back to the seeded `en` value.
- `Cache-Control: public, max-age=300` for CDN/edge caching.
- Mobile not refactored — endpoint only, per spec.

## Routes NOT wired into router.go

Per constraints, `backend/internal/router/router.go` is untouched. Phase B
merge needs to mount these route trees:

```go
// inside the authenticated group:
voiceH := voicenotes.NewHandler(cfg, db, log, audit)
r.Route("/api/v1/voice-notes", voiceH.Routes())

franH := franchise.NewHandler(cfg, db, log, audit)
r.Route("/api/v1/franchise", func(r chi.Router) {
    r.Use(middleware.RequireOwner())
    franH.Routes()(r)
})

refH := referrals.NewHandler(cfg, db, log, audit)
r.Route("/api/v1/referrals", func(r chi.Router) {
    r.Post("/", refH.Create)
    r.Get("/", refH.ListOwn)
    r.Group(func(r chi.Router) {
        r.Use(middleware.RequireAtLeast("admin"))
        r.Get("/all", refH.ListAll)
    })
    r.Group(func(r chi.Router) {
        r.Use(middleware.RequireOwner())
        r.Post("/{id}/payout", refH.Payout)
    })
})

i18nH := i18n.NewHandler(cfg, db, log)
r.Route("/api/v1/i18n", i18nH.Routes())
```

The AI handler keeps the existing `aihandler.NewHandler(cfg, db, log)` /
`r.Route("/api/v1/ai", aiH.Routes())` lines — no router change needed for M125.
The new `GET /ai/conversations/{id}` route is exposed automatically via the
existing `Routes()` mount.

## Build verify

```
go build ./internal/handlers/ai/...
        ./internal/handlers/voice_notes/...
        ./internal/handlers/franchise/...
        ./internal/handlers/referrals/...
        ./internal/handlers/i18n/...
        ./internal/middleware/...
        ./internal/services/transcription/...
go vet  (same set)
```

Both pass clean.

## Caveats / known follow-ups

- `business_tax_settings` and `business_branding_settings` are assumed to
  exist by Phase A migration 000008. The franchise inheritance copy uses
  `_, _ =` so a missing source table fails silently rather than blocking
  branch creation.
- `audit_logs` schema in 000001 declares `old_values`/`new_values` while
  `middleware.audit.go` writes `old_data`/`new_data` — a pre-existing
  mismatch outside this batch's scope. The new audit calls follow the same
  pattern as every other handler so behaviour is consistent.
- Real transcription provider is intentionally not wired (needs-key).
  `transcription.NewFromConfig` is the seam for swapping in a real backend.
- AI rate limiter fails OPEN if Redis is unavailable; the previous in-memory
  limiter failed CLOSED for the same key. Acceptable trade-off because the
  Anthropic API has its own per-key rate limit and we'd rather degrade
  gracefully than 429 every user during a Redis blip.
