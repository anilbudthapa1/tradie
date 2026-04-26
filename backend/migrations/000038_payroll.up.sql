-- ── Module 28 (Payroll) — schema hardening ─────────────────────
--
-- Adds the spec CRUD-pattern columns to pay_runs / payslips /
-- superannuation, extends the pay_runs status enum to include
-- 'cancelled', adds status-transition triggers, and seeds the
-- payroll.view / payroll.process permission keys.
--
-- Also adds tax_rate to business_payroll_settings so the placeholder
-- 19% in the legacy ProcessPayRun is configurable per tenant. The
-- per-worker hourly_rate already exists on business_employee_details
-- (000008_missing_tables) and super_rate on business_payroll_settings.

-- pay_runs
ALTER TABLE pay_runs ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE pay_runs ADD COLUMN IF NOT EXISTS metadata   JSONB NOT NULL DEFAULT '{}';
ALTER TABLE pay_runs ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE pay_runs ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ;
ALTER TABLE pay_runs ADD COLUMN IF NOT EXISTS paid_at      TIMESTAMPTZ;

-- Extend status to include 'cancelled'.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'pay_runs_status_check'
    ) THEN
        ALTER TABLE pay_runs DROP CONSTRAINT pay_runs_status_check;
    END IF;
    ALTER TABLE pay_runs
        ADD CONSTRAINT pay_runs_status_check
        CHECK (status IN ('draft','processed','paid','cancelled'));

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'pay_runs_dates_check'
    ) THEN
        ALTER TABLE pay_runs
            ADD CONSTRAINT pay_runs_dates_check
            CHECK (period_end >= period_start AND pay_date >= period_start);
    END IF;
END$$;

CREATE INDEX IF NOT EXISTS idx_pay_runs_business_status
    ON pay_runs(business_id, status, period_start DESC)
    WHERE deleted_at IS NULL;

-- Status transition guard:
--   draft → processed | cancelled
--   processed → paid | cancelled
--   paid is terminal (financial integrity)
--   cancelled is terminal
CREATE OR REPLACE FUNCTION pay_run_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('draft','processed'),
        ('draft','cancelled'),
        ('processed','paid'),
        ('processed','cancelled')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pay_run_status_guard ON pay_runs;
CREATE TRIGGER trg_pay_run_status_guard
    BEFORE UPDATE ON pay_runs
    FOR EACH ROW EXECUTE FUNCTION pay_run_status_guard();

ALTER TABLE pay_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pay_runs_tenant_isolation ON pay_runs;
CREATE POLICY pay_runs_tenant_isolation ON pay_runs
    USING (business_id::text = current_setting('app.business_id', true));

-- payslips
ALTER TABLE payslips ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE payslips ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE payslips ADD COLUMN IF NOT EXISTS metadata   JSONB NOT NULL DEFAULT '{}';
ALTER TABLE payslips ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE payslips ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE payslips ADD COLUMN IF NOT EXISTS status     TEXT NOT NULL DEFAULT 'draft';
ALTER TABLE payslips ADD COLUMN IF NOT EXISTS hours_worked FLOAT NOT NULL DEFAULT 0;
ALTER TABLE payslips ADD COLUMN IF NOT EXISTS hourly_rate FLOAT NOT NULL DEFAULT 0;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'payslips_status_check'
    ) THEN
        ALTER TABLE payslips
            ADD CONSTRAINT payslips_status_check
            CHECK (status IN ('draft','locked','paid','cancelled'));
    END IF;
END$$;

CREATE INDEX IF NOT EXISTS idx_payslips_business_status
    ON payslips(business_id, status, period_start DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payslips_worker
    ON payslips(worker_id, period_start DESC)
    WHERE deleted_at IS NULL;

ALTER TABLE payslips ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS payslips_tenant_isolation ON payslips;
CREATE POLICY payslips_tenant_isolation ON payslips
    USING (business_id::text = current_setting('app.business_id', true));

-- superannuation
ALTER TABLE superannuation ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE superannuation ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE superannuation ADD COLUMN IF NOT EXISTS metadata   JSONB NOT NULL DEFAULT '{}';
ALTER TABLE superannuation ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE superannuation ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

ALTER TABLE superannuation ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS superannuation_tenant_isolation ON superannuation;
CREATE POLICY superannuation_tenant_isolation ON superannuation
    USING (business_id::text = current_setting('app.business_id', true));

-- business_payroll_settings: add tax_rate for tenant-configurable PAYG.
-- Simple flat rate; progressive PAYG tables are a Phase-4 concern.
ALTER TABLE business_payroll_settings ADD COLUMN IF NOT EXISTS tax_rate NUMERIC(5,2) DEFAULT 19.00;

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('payroll.view',    'View pay runs and payslips',     'payroll'),
    ('payroll.process', 'Create and process pay runs',    'payroll'),
    ('payroll.export',  'Export payroll data to CSV',     'payroll')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('payroll.view','payroll.process','payroll.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('payroll.view','payroll.process','payroll.export')
ON CONFLICT DO NOTHING;

-- Manager: view only by default. Tenants can grant .process via the
-- /permissions endpoint if they want non-owner managers to run payroll.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('payroll.view')
ON CONFLICT DO NOTHING;

-- Accountant: view + export (their core need).
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('payroll.view','payroll.export')
ON CONFLICT DO NOTHING;

-- Workers: NO catalogue grant. Each worker still sees their own
-- payslips because the handler short-circuits to claims.UserID for
-- non-elevated callers. The /me/payroll_module endpoint is the
-- canonical worker surface.
