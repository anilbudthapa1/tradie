-- Reverse Migration 000011 — Batch 02 indexes.

DROP INDEX IF EXISTS idx_audit_logs_business_created;
DROP INDEX IF EXISTS idx_audit_logs_business_entity_created;
DROP INDEX IF EXISTS idx_jobs_customer_business_created;
DROP INDEX IF EXISTS idx_quotes_customer_business_created;
DROP INDEX IF EXISTS idx_invoices_customer_business_created;
DROP INDEX IF EXISTS idx_customer_notes_customer_business_created;
DROP INDEX IF EXISTS idx_invoice_payments_invoice_business_paid;
