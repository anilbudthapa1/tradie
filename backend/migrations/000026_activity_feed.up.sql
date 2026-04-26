-- ── Module 14 (Activity Feed) — tenant entries + permissions ────
--
-- The audit_logs table remains immutable and serves the read-only
-- timeline. This new table holds tenant-AUTHORED entries — owner
-- announcements, milestones, pinned notes — that satisfy the spec's
-- "Create, read, update, and manage module-specific records" rule.
--
-- The two streams (audit-derived + tenant-authored) are joined at
-- read time by the activity handler so the UI sees one feed.

CREATE TABLE IF NOT EXISTS tenant_activity_entries (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    target_user_id  UUID REFERENCES users(id) ON DELETE CASCADE,
    title           TEXT NOT NULL,
    body            TEXT NOT NULL DEFAULT '',
    category        TEXT NOT NULL DEFAULT 'announcement'
                    CHECK (category IN ('announcement','milestone','alert','note','system')),
    entity_type     TEXT
                    CHECK (entity_type IS NULL OR entity_type IN (
                        'job','invoice','quote','customer','worker','payment',
                        'task','lead','expense','safety','tenant'
                    )),
    entity_id       UUID,
    visibility      TEXT NOT NULL DEFAULT 'tenant'
                    CHECK (visibility IN ('tenant','managers','self')),
    pinned          BOOLEAN NOT NULL DEFAULT false,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','archived')),
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_tenant_activity_business_created
    ON tenant_activity_entries(business_id, status, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tenant_activity_pinned
    ON tenant_activity_entries(business_id, pinned, created_at DESC)
    WHERE deleted_at IS NULL AND pinned = true;
CREATE INDEX IF NOT EXISTS idx_tenant_activity_target
    ON tenant_activity_entries(target_user_id, status)
    WHERE deleted_at IS NULL AND target_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tenant_activity_entity
    ON tenant_activity_entries(business_id, entity_type, entity_id)
    WHERE deleted_at IS NULL AND entity_id IS NOT NULL;

CREATE OR REPLACE FUNCTION tenant_activity_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('active','archived'),
        ('archived','active')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_tenant_activity_status_guard ON tenant_activity_entries;
CREATE TRIGGER trg_tenant_activity_status_guard
    BEFORE UPDATE ON tenant_activity_entries
    FOR EACH ROW EXECUTE FUNCTION tenant_activity_status_guard();

ALTER TABLE tenant_activity_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_activity_isolation ON tenant_activity_entries;
CREATE POLICY tenant_activity_isolation ON tenant_activity_entries
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('activity.view',    'View activity feed',                 'activity'),
    ('activity.create',  'Author tenant activity entries',     'activity'),
    ('activity.manage',  'Update / archive activity entries',  'activity'),
    ('activity.export',  'Export activity feed to CSV',        'activity')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('activity.view','activity.create','activity.manage','activity.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('activity.view','activity.create','activity.manage','activity.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('activity.view','activity.create','activity.manage')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('activity.view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('activity.view')
ON CONFLICT DO NOTHING;
