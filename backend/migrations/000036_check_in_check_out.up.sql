-- ── Module 26 (Check-In Check-Out) — schema hardening ──────────
--
-- Adds the spec CRUD-pattern columns to worker_check_ins, introduces
-- an explicit lifecycle status separate from the checked_out_at flag,
-- and seeds the checkin.create / checkout.create permission keys.
--
-- Also enforces "at most one active check-in per user" via a partial
-- unique index. The legacy handler had no such guard so we backfill
-- and dedupe before applying it.

ALTER TABLE worker_check_ins ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE worker_check_ins ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE worker_check_ins ADD COLUMN IF NOT EXISTS metadata   JSONB NOT NULL DEFAULT '{}';
ALTER TABLE worker_check_ins ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE worker_check_ins ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE worker_check_ins ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE worker_check_ins ADD COLUMN IF NOT EXISTS status     TEXT NOT NULL DEFAULT 'active';
ALTER TABLE worker_check_ins ADD COLUMN IF NOT EXISTS accuracy_m FLOAT;

-- Backfill status from checked_out_at.
UPDATE worker_check_ins
   SET status = CASE
       WHEN deleted_at IS NOT NULL    THEN 'cancelled'
       WHEN checked_out_at IS NOT NULL THEN 'closed'
       ELSE 'active'
   END
 WHERE status NOT IN ('active','closed','cancelled');

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'worker_check_ins_status_check'
    ) THEN
        ALTER TABLE worker_check_ins
            ADD CONSTRAINT worker_check_ins_status_check
            CHECK (status IN ('active','closed','cancelled'));
    END IF;
END$$;

-- Lat/lng sanity checks. Postgres lacks a CHECK with subqueries but
-- a simple range is fine here.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'worker_check_ins_latlng_check'
    ) THEN
        ALTER TABLE worker_check_ins
            ADD CONSTRAINT worker_check_ins_latlng_check
            CHECK (
                (lat IS NULL OR (lat BETWEEN -90 AND 90))
                AND (lng IS NULL OR (lng BETWEEN -180 AND 180))
            );
    END IF;
END$$;

-- Pre-deduplicate before the unique index lands. Resolve any
-- multiple-active-check-in rows by closing all but the most recent.
WITH ranked AS (
    SELECT id,
           row_number() OVER (
               PARTITION BY business_id, user_id
               ORDER BY checked_in_at DESC, id
           ) AS rn
    FROM worker_check_ins
    WHERE status = 'active' AND deleted_at IS NULL
)
UPDATE worker_check_ins w
   SET status = 'closed',
       checked_out_at = COALESCE(checked_out_at, w.checked_in_at),
       duration_minutes = COALESCE(duration_minutes, 0),
       updated_at = NOW()
  FROM ranked r
 WHERE w.id = r.id AND r.rn > 1;

-- One active check-in per user per tenant.
CREATE UNIQUE INDEX IF NOT EXISTS uq_worker_check_ins_one_active
    ON worker_check_ins(business_id, user_id)
    WHERE status = 'active' AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_worker_check_ins_business_status
    ON worker_check_ins(business_id, status, checked_in_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_worker_check_ins_job
    ON worker_check_ins(job_id, status)
    WHERE deleted_at IS NULL AND job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_worker_check_ins_user_active
    ON worker_check_ins(user_id, checked_in_at DESC)
    WHERE deleted_at IS NULL AND status = 'active';

-- Status transition guard.
--   active → closed | cancelled
--   cancelled / closed are terminal.
CREATE OR REPLACE FUNCTION worker_check_in_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('active','closed'),
        ('active','cancelled')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_worker_check_in_status_guard ON worker_check_ins;
CREATE TRIGGER trg_worker_check_in_status_guard
    BEFORE UPDATE ON worker_check_ins
    FOR EACH ROW EXECUTE FUNCTION worker_check_in_status_guard();

ALTER TABLE worker_check_ins ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS worker_check_ins_tenant_isolation ON worker_check_ins;
CREATE POLICY worker_check_ins_tenant_isolation ON worker_check_ins
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('checkin.create',  'Create check-in (start a shift)',     'checkin'),
    ('checkout.create', 'Create check-out (end a shift)',      'checkin'),
    ('checkin.view',    'View check-in history',               'checkin'),
    ('checkin.manage',  'Cancel / amend check-ins',            'checkin'),
    ('checkin.export',  'Export check-in data to CSV',         'checkin')
ON CONFLICT (key) DO NOTHING;

-- Owner / admin / manager: all keys.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('checkin.create','checkout.create','checkin.view','checkin.manage','checkin.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('checkin.create','checkout.create','checkin.view','checkin.manage','checkin.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('checkin.create','checkout.create','checkin.view','checkin.manage','checkin.export')
ON CONFLICT DO NOTHING;

-- Workers: create + view their own. The handler scopes reads/writes
-- to self for non-managers.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('checkin.create','checkout.create','checkin.view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('checkin.view','checkin.export')
ON CONFLICT DO NOTHING;
