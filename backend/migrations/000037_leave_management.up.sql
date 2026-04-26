-- ── Module 27 (Leave Management) — schema hardening ────────────
--
-- Adds the spec CRUD-pattern columns to leave_requests, extends the
-- status enum to include 'cancelled' (worker-initiated withdrawal),
-- adds a status-transition trigger, and seeds the leave.request /
-- leave.approve permission keys.

ALTER TABLE leave_requests ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE leave_requests ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE leave_requests ADD COLUMN IF NOT EXISTS metadata   JSONB NOT NULL DEFAULT '{}';
ALTER TABLE leave_requests ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Extend the legacy status check to add 'cancelled'.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'leave_requests_status_check'
    ) THEN
        ALTER TABLE leave_requests DROP CONSTRAINT leave_requests_status_check;
    END IF;
    ALTER TABLE leave_requests
        ADD CONSTRAINT leave_requests_status_check
        CHECK (status IN ('pending','approved','rejected','cancelled'));
END$$;

-- Date range sanity check.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'leave_requests_dates_check'
    ) THEN
        ALTER TABLE leave_requests
            ADD CONSTRAINT leave_requests_dates_check
            CHECK (end_date >= start_date);
    END IF;
END$$;

CREATE INDEX IF NOT EXISTS idx_leave_requests_business_status
    ON leave_requests(business_id, status, start_date DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_leave_requests_worker_range
    ON leave_requests(worker_id, start_date, end_date)
    WHERE deleted_at IS NULL;

-- Status transition guard. The directed flow:
--
--   pending → approved | rejected | cancelled
--   approved → cancelled        (e.g. correcting an approved leave)
--   rejected → cancelled        (terminal cleanup; rejected lives forever otherwise)
--
-- Once cancelled, the row is terminal. Reactivation requires a new request.
CREATE OR REPLACE FUNCTION leave_request_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('pending','approved'),
        ('pending','rejected'),
        ('pending','cancelled'),
        ('approved','cancelled'),
        ('rejected','cancelled')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_leave_request_status_guard ON leave_requests;
CREATE TRIGGER trg_leave_request_status_guard
    BEFORE UPDATE ON leave_requests
    FOR EACH ROW EXECUTE FUNCTION leave_request_status_guard();

ALTER TABLE leave_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS leave_requests_tenant_isolation ON leave_requests;
CREATE POLICY leave_requests_tenant_isolation ON leave_requests
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('leave.request', 'Submit leave requests (workers + managers)', 'leave'),
    ('leave.approve', 'Approve / reject leave requests',            'leave'),
    ('leave.view',    'View leave requests',                         'leave'),
    ('leave.manage',  'Edit / cancel leave requests',                'leave'),
    ('leave.export',  'Export leave data to CSV',                    'leave')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('leave.request','leave.approve','leave.view','leave.manage','leave.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('leave.request','leave.approve','leave.view','leave.manage','leave.export')
ON CONFLICT DO NOTHING;

-- Manager: request + approve + view, no export by default.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('leave.request','leave.approve','leave.view','leave.manage')
ON CONFLICT DO NOTHING;

-- Workers + accountants: request + view their own (handler scopes reads).
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('leave.request','leave.view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('leave.view','leave.export')
ON CONFLICT DO NOTHING;
