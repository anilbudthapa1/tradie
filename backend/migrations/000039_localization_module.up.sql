-- ── Module 127 (Multi Language) — tenant localization catalogue ──

CREATE TABLE IF NOT EXISTS localization_entries (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    namespace       TEXT NOT NULL DEFAULT 'common',
    translation_key TEXT NOT NULL,
    language        TEXT NOT NULL CHECK (language IN ('en','en-AU','zh','vi','ar')),
    value           TEXT NOT NULL,
    template_type   TEXT NOT NULL DEFAULT 'ui'
                    CHECK (template_type IN ('ui','email','sms','push','document','customer_portal')),
    status          TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','active','archived')),
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_localization_entries_business_key_language
    ON localization_entries(business_id, lower(namespace), lower(translation_key), language)
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_localization_entries_business_status
    ON localization_entries(business_id, status, language, namespace)
    WHERE deleted_at IS NULL;

CREATE OR REPLACE FUNCTION localization_entry_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('draft','active'),
        ('draft','archived'),
        ('active','archived'),
        ('archived','draft'),
        ('archived','active')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_localization_entry_status_guard ON localization_entries;
CREATE TRIGGER trg_localization_entry_status_guard
    BEFORE UPDATE ON localization_entries
    FOR EACH ROW EXECUTE FUNCTION localization_entry_status_guard();

ALTER TABLE localization_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS localization_entries_tenant_isolation ON localization_entries;
CREATE POLICY localization_entries_tenant_isolation ON localization_entries
    USING (business_id::text = current_setting('app.business_id', true));

INSERT INTO permissions (key, description, category) VALUES
    ('localization.manage', 'Create, update, archive, delete and export tenant localization entries', 'localization'),
    ('localization.view',   'View active tenant localization entries', 'localization'),
    ('localization.export', 'Export tenant localization entries to CSV', 'localization')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('localization.manage','localization.view','localization.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('localization.manage','localization.view','localization.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('localization.view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('localization.view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('localization.view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'customer', id, NULL FROM permissions
WHERE key IN ('localization.view')
ON CONFLICT DO NOTHING;
