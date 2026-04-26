-- ── Module 15 (Customer Management) — schema hardening ─────────
--
-- The customers table predates the spec's CRUD-pattern columns and
-- a previous handler change started querying `deleted_at` without
-- the column existing. This migration:
--   * Adds the spec-required columns (deleted_at, created_by,
--     updated_by, status, metadata) — fixes the broken delete path
--   * Backfills status='active' for existing rows
--   * Adds a status-transition guard trigger
--   * Enables RLS as a Phase-3 hardening rail
--
-- Permission keys (customers.view/.create/.update/.delete) are
-- already seeded by 000020_batch11_security.up.sql.

ALTER TABLE customers ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE customers ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active';
ALTER TABLE customers ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}';

-- Backfill status from is_active for existing rows (idempotent).
UPDATE customers
   SET status = CASE WHEN is_active THEN 'active' ELSE 'inactive' END
 WHERE status NOT IN ('lead','active','inactive','archived');

-- Constraint added separately so existing rows can be backfilled first.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'customers_status_check'
    ) THEN
        ALTER TABLE customers
            ADD CONSTRAINT customers_status_check
            CHECK (status IN ('lead','active','inactive','archived'));
    END IF;
END$$;

-- Index for the soft-delete filter and the active-customer KPI.
CREATE INDEX IF NOT EXISTS idx_customers_business_status
    ON customers(business_id, status)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_customers_business_active
    ON customers(business_id)
    WHERE deleted_at IS NULL;

-- Status-transition guard. Soft-archived rows can be reactivated, but
-- deleted rows (deleted_at IS NOT NULL) cannot transition status.
CREATE OR REPLACE FUNCTION customer_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF OLD.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'cannot_change_status_on_deleted_customer'
            USING ERRCODE = 'check_violation';
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('lead','active'),
        ('lead','archived'),
        ('active','inactive'),
        ('active','archived'),
        ('inactive','active'),
        ('inactive','archived'),
        ('archived','active'),
        ('archived','inactive')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_customer_status_guard ON customers;
CREATE TRIGGER trg_customer_status_guard
    BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION customer_status_guard();

-- RLS rail (off by default; enabled when ops sets app.business_id).
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customers_tenant_isolation ON customers;
CREATE POLICY customers_tenant_isolation ON customers
    USING (business_id::text = current_setting('app.business_id', true));
