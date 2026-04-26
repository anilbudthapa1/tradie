-- ── Module 24 (Availability Roster) — schema build-out ─────────
--
-- Three concepts, three tables:
--
--   * worker_availability   recurring weekly pattern (already exists;
--                           hardened with spec CRUD-pattern columns)
--   * availability_blocks   date-range exceptions: leave, sick, training,
--                           custom block. Has a pending → approved/cancelled
--                           status pipeline so leave requests can flow
--                           through manager approval.
--   * roster_assignments    per-date scheduled shifts, optionally linked
--                           to a job_id. The actual roster.

-- ── Hardening of worker_availability ──────────────────────────────
ALTER TABLE worker_availability ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE worker_availability ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE worker_availability ADD COLUMN IF NOT EXISTS status     TEXT NOT NULL DEFAULT 'active';
ALTER TABLE worker_availability ADD COLUMN IF NOT EXISTS metadata   JSONB NOT NULL DEFAULT '{}';
ALTER TABLE worker_availability ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'worker_availability_status_check'
    ) THEN
        ALTER TABLE worker_availability
            ADD CONSTRAINT worker_availability_status_check
            CHECK (status IN ('active','archived'));
    END IF;
END$$;

ALTER TABLE worker_availability ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS worker_availability_tenant_isolation ON worker_availability;
CREATE POLICY worker_availability_tenant_isolation ON worker_availability
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Availability blocks (leave / training / custom) ──────────────

CREATE TABLE IF NOT EXISTS availability_blocks (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    block_type  TEXT NOT NULL DEFAULT 'leave'
                CHECK (block_type IN ('leave','sick','training','public_holiday','unavailable','custom')),
    starts_at   TIMESTAMPTZ NOT NULL,
    ends_at     TIMESTAMPTZ NOT NULL,
    all_day     BOOLEAN NOT NULL DEFAULT true,
    reason      TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','approved','cancelled')),
    approved_by UUID REFERENCES users(id) ON DELETE SET NULL,
    approved_at TIMESTAMPTZ,
    metadata    JSONB NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,
    CHECK (ends_at > starts_at)
);

CREATE INDEX IF NOT EXISTS idx_availability_blocks_user_range
    ON availability_blocks(user_id, starts_at, ends_at)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_availability_blocks_business_status
    ON availability_blocks(business_id, status, starts_at DESC)
    WHERE deleted_at IS NULL;

-- pending → approved → cancelled. Approved can be cancelled (e.g. leave
-- changed plans). Cancelled is terminal.
CREATE OR REPLACE FUNCTION availability_block_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('pending','approved'),
        ('pending','cancelled'),
        ('approved','cancelled')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_availability_block_status_guard ON availability_blocks;
CREATE TRIGGER trg_availability_block_status_guard
    BEFORE UPDATE ON availability_blocks
    FOR EACH ROW EXECUTE FUNCTION availability_block_status_guard();

ALTER TABLE availability_blocks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS availability_blocks_tenant_isolation ON availability_blocks;
CREATE POLICY availability_blocks_tenant_isolation ON availability_blocks
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Roster assignments (per-date shifts) ─────────────────────────

CREATE TABLE IF NOT EXISTS roster_assignments (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    job_id      UUID REFERENCES jobs(id) ON DELETE SET NULL,
    created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    starts_at   TIMESTAMPTZ NOT NULL,
    ends_at     TIMESTAMPTZ NOT NULL,
    notes       TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'scheduled'
                CHECK (status IN ('scheduled','confirmed','completed','cancelled')),
    metadata    JSONB NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,
    CHECK (ends_at > starts_at)
);

CREATE INDEX IF NOT EXISTS idx_roster_user_range
    ON roster_assignments(user_id, starts_at, ends_at)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_roster_business_range
    ON roster_assignments(business_id, starts_at, ends_at)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_roster_job
    ON roster_assignments(job_id)
    WHERE deleted_at IS NULL AND job_id IS NOT NULL;

-- scheduled → confirmed → completed; cancelled reachable from any
-- non-completed state.
CREATE OR REPLACE FUNCTION roster_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('scheduled','confirmed'),
        ('scheduled','cancelled'),
        ('scheduled','completed'),
        ('confirmed','completed'),
        ('confirmed','cancelled')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_roster_status_guard ON roster_assignments;
CREATE TRIGGER trg_roster_status_guard
    BEFORE UPDATE ON roster_assignments
    FOR EACH ROW EXECUTE FUNCTION roster_status_guard();

ALTER TABLE roster_assignments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS roster_assignments_tenant_isolation ON roster_assignments;
CREATE POLICY roster_assignments_tenant_isolation ON roster_assignments
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('roster.view',    'View availability + roster',                  'roster'),
    ('roster.update',  'Update recurring availability + roster',      'roster'),
    ('roster.approve', 'Approve / cancel leave & training blocks',    'roster'),
    ('roster.export',  'Export roster + leave to CSV',                'roster')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('roster.view','roster.update','roster.approve','roster.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('roster.view','roster.update','roster.approve','roster.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('roster.view','roster.update','roster.approve')
ON CONFLICT DO NOTHING;

-- Workers: view + create their own leave requests via the handler's
-- self-scoping (handler enforces target == caller for non-manager).
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('roster.view','roster.update')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('roster.view')
ON CONFLICT DO NOTHING;
