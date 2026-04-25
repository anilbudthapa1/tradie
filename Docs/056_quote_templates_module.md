# 56. Quote Templates Module — Full Module Specification

## Main Purpose
The **Quote Templates Module** is responsible for reusable quote templates for common jobs in **Tradie Job Manager**.

This module must be production-focused, tenant-safe, auditable, and secure by design.

## Main Users
- **Owner:** full business-level access based on plan.
- **Employee:** limited access to assigned work or own records.
- **Customer:** limited portal access only where applicable.
- **Platform Admin:** internal support only, heavily audited, no casual access to tenant data.

## Core Features
- Create, read, update, and manage module-specific records.
- Connect records to the correct `business_id`.
- Support role-aware UI and backend enforcement.
- Support audit logging for sensitive changes.
- Support export/reporting where relevant.
- Support notification hooks where relevant.

## What We Will Implement
1. Tenant-scoped data model for this module.
2. Owner-facing management screens.
3. Employee/customer limited screens where applicable.
4. Backend service layer in Go.
5. Strict validation and permission checks.
6. Audit events for sensitive operations.
7. Secure API endpoints.
8. Default empty/loading/error/success states.

## Core Permissions
```txt
quote_templates.manage
```

## Suggested Go Services
```txt
QuoteTemplateService
TenantGuard
AuditService
ValidationService
NotificationHookService
```

## API Endpoint Pattern
Use REST endpoints like:

```txt
GET    /api/quote_templates_module
POST   /api/quote_templates_module
GET    /api/quote_templates_module/:id
PATCH  /api/quote_templates_module/:id
DELETE /api/quote_templates_module/:id
```

For employee/self-service views, use explicit safe endpoints:

```txt
GET /api/me/quote_templates_module
```

## Database Pattern
Minimum table pattern:

```sql
id UUID PRIMARY KEY,
business_id UUID NOT NULL REFERENCES businesses(id),
created_by UUID REFERENCES users(id),
updated_by UUID REFERENCES users(id),
status TEXT,
metadata JSONB,
created_at TIMESTAMP NOT NULL,
updated_at TIMESTAMP NOT NULL,
deleted_at TIMESTAMP
```

Add module-specific fields during implementation.


## Zero Trust Security Baseline
Every request in this module must enforce:

```txt
1. Authenticate the user/session.
2. Load current_user, current_business_id, current_role, current_plan from trusted backend context.
3. Never trust business_id, user_id, role, price, status, or permission values sent from the frontend.
4. Enforce tenant isolation: resource.business_id == current_user.business_id.
5. Enforce RBAC/permission checks before any read/write/delete/export.
6. Enforce subscription feature access where relevant.
7. Validate every input with allow-lists and strict schemas.
8. Audit all sensitive actions.
9. Deny by default.
```

## Secure Data Rules
- Use UUID primary keys.
- Include `business_id UUID NOT NULL` on tenant-owned records.
- Apply PostgreSQL Row-Level Security where practical.
- Use soft delete for legal, financial, payroll, tax, and compliance records.
- Encrypt sensitive fields at field level when required.
- Never expose internal IDs, storage keys, provider secrets, raw tokens, or cross-tenant data.

## Recommended Stack Usage
- **Frontend:** Flutter mobile + Flutter Web/React admin dashboard.
- **Backend:** Go REST API, with gRPC later for internal services.
- **Database:** PostgreSQL as source of truth.
- **Cache/queue:** Redis for sessions, rate limits, queues and short-lived state.
- **Files:** S3-compatible storage with signed URLs.
- **Realtime:** WebSocket for live updates where needed.


## Validation Rules
- Required fields must be explicit.
- Reject unknown fields.
- Validate UUIDs, dates, amounts, status values and file types.
- Validate all status transitions server-side.
- Use allow-listed enum values for statuses, roles, channels and categories.
- Apply request size limits.

## Audit Events
Create audit events such as:

```txt
QUOTE_TEMPLATES_MODULE_VIEWED
QUOTE_TEMPLATES_MODULE_CREATED
QUOTE_TEMPLATES_MODULE_UPDATED
QUOTE_TEMPLATES_MODULE_DELETED
QUOTE_TEMPLATES_MODULE_ACCESS_DENIED
QUOTE_TEMPLATES_MODULE_EXPORTED
```

For sensitive modules, include old/new values with masking.

## Frontend/Wireframe Requirements
- List/table view with search and filters.
- Detail page or slide-over panel.
- Create/edit form with validation messages.
- Empty state with clear action.
- Loading state and error state.
- Confirmation modal for destructive actions.
- Role-aware navigation visibility.
- Iconsax-style icon for this module.
- Smooth micro-interactions and card transitions.

## Implementation Phases
### Phase 1 — MVP
- Data model.
- Core CRUD.
- Tenant isolation.
- Owner permissions.
- Basic UI.

### Phase 2 — Workflow
- Status transitions.
- Notifications.
- Search/filter.
- Reports or exports where applicable.

### Phase 3 — Hardening
- PostgreSQL RLS.
- Advanced audit logs.
- Rate limits.
- Abuse detection.
- More detailed permission keys.

### Phase 4 — Scale
- Background jobs.
- WebSocket updates.
- Integration hooks.
- Analytics.

## Final Rule
This module must never rely on frontend-only security. Every action must be verified in the Go backend using authenticated user context, tenant isolation, RBAC, subscription access and audit logging.
