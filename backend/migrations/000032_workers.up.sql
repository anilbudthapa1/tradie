-- ── Module 22 (Worker Management) — schema hardening ───────────
--
-- The users table predates the spec's CRUD-pattern columns. This
-- migration adds them (idempotent), introduces an explicit worker
-- lifecycle status separate from is_active, and seeds the
-- employees.view / .create / .update permission keys.
--
-- We can't rename `users` (auth + every other module joins on it)
-- so the spec mapping is: users.role+is_active → workers as a
-- view; the new worker_status column gives us a proper lifecycle.

ALTER TABLE users ADD COLUMN IF NOT EXISTS created_by    UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_by    UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS metadata      JSONB NOT NULL DEFAULT '{}';
ALTER TABLE users ADD COLUMN IF NOT EXISTS worker_status TEXT NOT NULL DEFAULT 'active';

-- Backfill worker_status from existing flags. Customers stay 'active'
-- but the worker UI never reads them.
UPDATE users
   SET worker_status = CASE
       WHEN deleted_at IS NOT NULL              THEN 'archived'
       WHEN is_active = false                   THEN 'suspended'
       WHEN is_verified = false AND invited_at IS NOT NULL THEN 'invited'
       ELSE 'active'
   END
 WHERE worker_status NOT IN ('invited','active','suspended','archived');

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'users_worker_status_check'
    ) THEN
        ALTER TABLE users
            ADD CONSTRAINT users_worker_status_check
            CHECK (worker_status IN ('invited','active','suspended','archived'));
    END IF;
END$$;

CREATE INDEX IF NOT EXISTS idx_users_business_worker_status
    ON users(business_id, worker_status)
    WHERE deleted_at IS NULL AND role <> 'customer';

-- Status transition guard. Directed flow:
--
--   invited → active
--   active  ↔ suspended
--   *       → archived
--
-- archived is terminal; reactivation requires a new invite (new row).
CREATE OR REPLACE FUNCTION worker_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.worker_status = NEW.worker_status THEN
        RETURN NEW;
    END IF;
    IF (OLD.worker_status, NEW.worker_status) NOT IN (
        ('invited','active'),
        ('invited','archived'),
        ('active','suspended'),
        ('active','archived'),
        ('suspended','active'),
        ('suspended','archived')
    ) THEN
        RAISE EXCEPTION 'invalid_worker_status_transition: % -> %', OLD.worker_status, NEW.worker_status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_worker_status_guard ON users;
CREATE TRIGGER trg_worker_status_guard
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION worker_status_guard();

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('employees.view',   'View workers / employees',                   'employees'),
    ('employees.create', 'Invite new workers',                          'employees'),
    ('employees.update', 'Update worker profile / role / status',       'employees'),
    ('employees.delete', 'Soft-delete (archive) workers',               'employees'),
    ('employees.export', 'Export worker roster to CSV',                 'employees')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('employees.view','employees.create','employees.update','employees.delete','employees.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('employees.view','employees.create','employees.update','employees.delete','employees.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('employees.view','employees.update')
ON CONFLICT DO NOTHING;

-- Workers can view the roster (so they know who else is on the team)
-- but cannot modify it.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('employees.view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('employees.view','employees.export')
ON CONFLICT DO NOTHING;
