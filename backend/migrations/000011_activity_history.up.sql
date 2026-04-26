-- ============================================================
-- Migration 000011 — Batch 02: Activity Feed + Customer History
-- ============================================================
--
-- No new tables. Adds composite indexes that back the two new reads:
--   * Activity feed list   (audit_logs by business + created_at, with optional entity_type)
--   * Customer history     (jobs/quotes/invoices/customer_notes/invoice_payments by customer_id within tenant)
--
-- All migrations are idempotent so running them on a half-applied
-- environment is safe.

-- Activity feed: keyset/cursor on created_at descending within tenant.
CREATE INDEX IF NOT EXISTS idx_audit_logs_business_created
    ON audit_logs (business_id, created_at DESC);

-- Optional entity_type filter on the activity feed.
CREATE INDEX IF NOT EXISTS idx_audit_logs_business_entity_created
    ON audit_logs (business_id, entity_type, created_at DESC);

-- Customer history UNION legs — supports the per-customer/per-tenant scan.
-- Most of these already exist as bare (customer_id) indexes in earlier
-- migrations; the composites add tenant scoping for unindexed legs.
CREATE INDEX IF NOT EXISTS idx_jobs_customer_business_created
    ON jobs (customer_id, business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_quotes_customer_business_created
    ON quotes (customer_id, business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_invoices_customer_business_created
    ON invoices (customer_id, business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_customer_notes_customer_business_created
    ON customer_notes (customer_id, business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_invoice_payments_invoice_business_paid
    ON invoice_payments (invoice_id, business_id, paid_at DESC);
