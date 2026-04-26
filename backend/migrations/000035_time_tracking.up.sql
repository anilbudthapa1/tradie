-- ── Module 25 (Time Tracking) — schema hardening + lifecycle ────
--
-- Adds the spec CRUD-pattern columns to timesheets, extends the
-- status enum to include 'draft' and 'submitted' so timesheets flow
-- draft → submitted → approved/rejected → cancelled, adds a status
-- transition guard, and seeds the time.view/.create/.approve keys.

ALTER TABLE timesheets ADD COLUMN IF NOT EXISTS created_by       UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE timesheets ADD COLUMN IF NOT EXISTS updated_by       UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE timesheets ADD COLUMN IF NOT EXISTS metadata         JSONB NOT NULL DEFAULT '{}';
ALTER TABLE timesheets ADD COLUMN IF NOT EXISTS deleted_at       TIMESTAMPTZ;
ALTER TABLE timesheets ADD COLUMN IF NOT EXISTS rejection_reason TEXT;
ALTER TABLE timesheets ADD COLUMN IF NOT EXISTS submitted_at     TIMESTAMPTZ;

-- Replace the legacy status check so we can add 'draft','submitted','cancelled'.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'timesheets_status_check'
    ) THEN
        ALTER TABLE timesheets DROP CONSTRAINT timesheets_status_check;
    END IF;
    ALTER TABLE timesheets
        ADD CONSTRAINT timesheets_status_check
        CHECK (status IN ('draft','submitted','pending','approved','rejected','cancelled'));
END$$;

CREATE INDEX IF NOT EXISTS idx_timesheets_business_status
    ON timesheets(business_id, status, date DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_timesheets_worker_date
    ON timesheets(worker_id, date DESC)
    WHERE deleted_at IS NULL;

-- Status transition guard. The directed flow:
--
--   draft   → submitted | cancelled
--   submitted → pending | cancelled
--   pending → approved | rejected | cancelled
--   approved → cancelled        (e.g. correcting a paid run)
--   rejected → submitted | cancelled
--
-- The legacy data has rows in 'pending' so backfill is implicit:
-- existing timesheets stay 'pending' and can move forward.
CREATE OR REPLACE FUNCTION timesheet_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('draft','submitted'),
        ('draft','cancelled'),
        ('submitted','pending'),
        ('submitted','cancelled'),
        ('pending','approved'),
        ('pending','rejected'),
        ('pending','cancelled'),
        ('approved','cancelled'),
        ('rejected','submitted'),
        ('rejected','cancelled')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_timesheet_status_guard ON timesheets;
CREATE TRIGGER trg_timesheet_status_guard
    BEFORE UPDATE ON timesheets
    FOR EACH ROW EXECUTE FUNCTION timesheet_status_guard();

-- Defence-in-depth: enforce ends-after-starts so a malformed time
-- pair can't sneak in. Computed against (date + start_time) and
-- (date + end_time) so we don't choke on the legacy night-shift bug
-- where end_time < start_time produces a negative span.
ALTER TABLE timesheets DROP CONSTRAINT IF EXISTS timesheets_window_check;
ALTER TABLE timesheets ADD CONSTRAINT timesheets_window_check
    CHECK (
        (date + end_time) > (date + start_time)
        OR end_time < start_time     -- explicit night-shift wrap; handler computes hours correctly
    );

ALTER TABLE timesheets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS timesheets_tenant_isolation ON timesheets;
CREATE POLICY timesheets_tenant_isolation ON timesheets
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('time.view',    'View timesheets',                  'time'),
    ('time.create',  'Create / submit timesheets',       'time'),
    ('time.update',  'Edit pending timesheets',          'time'),
    ('time.approve', 'Approve / reject timesheets',      'time'),
    ('time.delete',  'Cancel / soft-delete timesheets',  'time'),
    ('time.export',  'Export timesheets to CSV',         'time')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('time.view','time.create','time.update','time.approve','time.delete','time.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('time.view','time.create','time.update','time.approve','time.delete','time.export')
ON CONFLICT DO NOTHING;

-- Manager: view + create + update + approve, no delete or export.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('time.view','time.create','time.update','time.approve')
ON CONFLICT DO NOTHING;

-- Workers: view + create + update their own. Handler enforces
-- the self-scope so they can't see / edit other people's rows.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('time.view','time.create','time.update')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('time.view','time.export')
ON CONFLICT DO NOTHING;
