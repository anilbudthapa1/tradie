# Tradie Job Manager — Gap Analysis (128 modules)

Date: 2026-04-25
Method: 13 read-only Explore agents mapped each module spec (`Docs/`) against the live code (`backend/`, `mobile/`, `migrations/`).
Symbol legend: ✅ done · 🟡 partial · ❌ missing

## 1. Headline numbers

| Status | Count | % |
|---|---|---|
| ✅ Done | 36 | 28% |
| 🟡 Partial | 64 | 50% |
| ❌ Missing | 28 | 22% |
| **Total** | **128** | 100% |

The codebase is roughly half-built. Most "partial" modules have CRUD wired and tenant isolation, but lack RBAC, audit logging, scheduler integration, or a real provider behind the integration stub.

## 2. Cross-cutting findings (these recur across most batches)

**A. RBAC is the single biggest gap.** Tenant isolation (`BusinessIDFromCtx`) is consistently applied — but module-level permission checks (`RequireOwner`, `RequireManager`, `RequireAtLeast`) are missing from most handlers. Any authenticated user in a tenant can hit most endpoints. **Highest-impact fix in the codebase.**

**B. Audit logging is partial.** `AuditService` exists and is called in customers, leads, jobs (some), invoices (some), workers. It is missing from: payments, exports, search, payroll runs, photo uploads, status changes, settings, and most read endpoints that the spec marks as sensitive.

**C. No background scheduler.** Several modules require cron/scheduler triggers (recurring invoices, overdue reminders, compliance expiry, customer ETA, follow-up campaigns, recurring jobs, push reminders). Currently exposed as HTTP POST handlers requiring manual trigger — security risk and won't run autonomously.

**D. Server-side financial enforcement is weak.** GST hardcoded at 10% (ignores `business_tax_settings.gst_rate`); discount has no cap; PDF generation is JSON-only stub; receipt scanner is mock; payslip endpoint lets employees enumerate other workers.

**E. Provider integrations are mostly stubs.** Stripe webhook + checkout are real. Everything else (Twilio SMS, FCM/APNs push, Sentry, Xero, MYOB, QuickBooks, Google Calendar, Google Maps API, OCR) is either missing or scaffolded but not wired.

**F. Mobile UI lags backend.** Backend handlers exist for many features whose mobile screens are placeholders or absent: payroll, payslips, super, recurring invoices, payment links, receipts, custom reports, audit log viewer, sessions, branding, branch picker.

## 3. Per-batch summary

| Batch | Range | Done | Partial | Missing | Top P0 |
|---|---|---|---|---|---|
| 01 Identity & Access | 1-10 | 4 | 5 | 1 | M10 Notification Prefs (entire backend missing); M06 subscription feature gating |
| 02 Dashboard & Customer | 11-20 | 7 | 3 | 2 | M14 Activity Feed (no endpoint); M19 Customer History (no unified view) |
| 03 Reviews/Workers/Payroll | 21-30 | 5 | 4 | 1 | **M28 Payroll routes unguarded** (any user can create pay runs); M29 employee can view all payslips; M30 super stub |
| 04 Jobs | 31-40 | 5 | 3 | 0+ | M33/M34/M35 no RBAC on create/assign/status; M38 private notes leak |
| 05 Scheduling | 41-50 | 6 | 3 | 1 | M45 conflict check is advisory not blocking; M48 no real map; drag-drop unaudited |
| 06 Location & Quotes | 51-60 | 1 | 6 | 3 | M52 worker locations visible to all roles; M53 geo check-in handler missing; M59 GST hardcoded |
| 07 Approval & Invoices | 61-70 | 1 | 8 | 1 | M63/M70 PDF generation missing; M66 recurring needs scheduler; M69 Stripe link not wired; M68 overdue reminder absent |
| 08 Tax/Bills/Safety | 71-80 | 2 | 7 | 1 | M74 receipt scanner stub; M73 no bills table; M72 expenses no RBAC; tax queries reference wrong column `expense_date` |
| 09 WorkSafe & Notifications | 81-90 | 0 | 8 | 2 | M83 incident report no RBAC + no old-value audit (legal risk); M84 near-miss has no separate workflow; M90 push notification absent |
| 10 Comms & Reports | 91-100 | 1 | 7 | 2 | M92 follow-up campaigns absent; M100 custom reports absent; revenue/unpaid reports lack RBAC |
| 11 Search/Export/Security | 101-110 | 1 | 5 | 4 | M103/M104 exports unaudited; M105/M106 bulk import/update absent; M110 permission management absent |
| 12 Admin/Backup/Integrations | 111-120 | 2 | 3 | 5 | M113 Sentry DSN configured but never initialized; M115-M118 Xero/MYOB/QBO/GCal OAuth absent; M111 backup absent |
| 13 Growth/Mobile/Advanced | 121-128 | 0 | 5 | 3 | **M125 AI prompt injection** + no audit; M128 franchise has no `parent_business_id` (architectural); M126 voice notes no backend |

## 4. Critical security findings (legally / financially significant)

These should be considered blockers regardless of which build batches you pick:

1. **Payroll routes are not RBAC-guarded.** Any authenticated user with a session can call payroll create/process endpoints. Wrap registration with `RequireOwnerOrAdmin()`.
2. **Payslips are enumerable across workers.** `ListPayslips` accepts `worker_id` query param without verifying caller is owner or that worker. Add `claims.UserID == workerID || isOwner`.
3. **AI assistant has prompt-injection surface and zero audit.** System-prompt concatenation at the user message; rate limiter is in-memory (resets on restart); prompts/responses not logged. Production AI should log + sanitize + Redis rate-limit.
4. **Worker live location is visible to all roles.** No RBAC on `/workers/locations`. Should be owner/admin only.
5. **GST is hardcoded 10%.** Ignores `business_tax_settings.gst_rate`. Tax-compliance risk for businesses outside the default rate or for GST-exempt items.
6. **Discount has no server-side cap.** `discount_amount` accepted from frontend with no max enforcement. Owner could be social-engineered into a 100% discount link.
7. **Reports with no RBAC.** Revenue, unpaid invoices, worker performance — sensitive financial / HR data — readable by employees.
8. **Exports are not audited.** CSV / PDF exports are the most common exfiltration vector. Add audit entries with row count + scope.
9. **Tax/BAS report queries reference a non-existent column.** `expense_date` in three report queries — schema column is `date`. These reports will throw at runtime.
10. **Email reset / role change does not revoke sessions.** `ResetPassword` doesn't kill existing refresh tokens.

## 5. Recommended P0 build queue

Sequenced so each step is independently shippable. Each is a single Implementation Agent run with a CEO review pass.

| # | Item | Why now | Risk if skipped |
|---|---|---|---|
| 1 | RBAC sweep across all handlers | Single change set; touches every batch; unblocks safe rollout of anything else | Tenant-internal data leakage |
| 2 | Payroll + payslip access fix (M28/M29) | Privilege escalation + PII leak | Legal/HR exposure |
| 3 | Audit logging coverage (exports, payments, status, settings, search, photo upload) | Compliance baseline | Cannot prove who did what |
| 4 | GST + discount server-side enforcement (M59/M60) | Reads `business_tax_settings`, caps discount per role | Tax incorrectness, financial loss |
| 5 | Fix `expense_date` → `date` in reports (M75/M76/M77/M78) | One-line fix per query, but reports currently broken | Reports unusable in prod |
| 6 | Notification infrastructure (M10 + M88-M90) | Enables overdue reminders, ETA, compliance expiry, push | Half a dozen modules silently broken |
| 7 | Background scheduler (cron/worker) | Required by M13/M36/M66/M68/M86/M92 | Recurring + reminder modules don't actually run |
| 8 | PDF + S3 signed-URL pipeline (M63/M70/M104) | Quote, invoice, receipt, accountant export | Customers cannot receive PDFs |
| 9 | Geo check-in (M53) + map visualization (M48) | Job lifecycle gap | Field workers can't check in |
| 10 | AI assistant hardening (M125): prompt sanitization + audit + Redis rate limit | Public-facing LLM endpoint | Prompt injection, abuse, runaway cost |

## 6. Items deliberately deferred to later phases

These appear in the spec but are clearly Phase-3/4 in the spec itself. Acknowledge but don't build now:

- M84 Near Miss as a fully separate module (currently merged into incident with `incident_type='near_miss'` — acceptable for MVP if RBAC + audit on incidents is fixed)
- M115-M118 Accounting OAuth (Xero/MYOB/QBO) and M118 Google Calendar — large surface, low MVP value
- M128 Franchise multi-branch — schema-level addition (`businesses.parent_business_id`); affects every tenant query; do post-MVP
- M127 Multi-language i18n
- M125 AI assistant feature expansion (history persistence, streaming) — the P0 above is just hardening
- M111 Backup/restore as in-app feature (handle via DB-level snapshots + Stripe-grade ops for now)

## 7. What this report does NOT cover

- **No tests run.** Status is from spec-vs-code reading, not live behavior.
- **No frontend acceptance.** "Mobile UI exists" means a screen file is present, not that it works end-to-end.
- **Inferred edges from Graphify (`81% extracted, 18% inferred`) were not re-verified** — minor module relationships may be approximate.
- **Modified files in `git status` (16 files) were read in current state.** Your in-flight work was treated as part of the codebase.

## 8. Next decision

Three options, pick one:

- **(i) Fix the top 5 critical security items first** (RBAC sweep + payroll fix + audit logging + GST/discount + expense_date typo). Single sequential build pass, ~1 implementation agent at a time, CEO review between each. Recommended.
- **(ii) Build a single feature batch end-to-end** (e.g. complete the notification infrastructure + scheduler so half a dozen partial modules light up). Higher visible progress, but the security gaps stay open.
- **(iii) Fan out one Implementation Agent per batch** (the original 13-agent shape). Faster wall-clock, but carries the collision and overwrite risks I flagged earlier — not recommended given the half-built state.
