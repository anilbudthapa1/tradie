-- ── Module 12 (KPI Analytics Widgets) — table, permissions, RLS ──

-- Persisted user/owner-defined KPI tiles. Each row binds an
-- allow-listed metric_key + period + filter to a display slot. The
-- handler resolves the live value at read time; rows do not store
-- numeric data themselves.
CREATE TABLE IF NOT EXISTS kpi_widgets (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    target_user_id  UUID REFERENCES users(id) ON DELETE CASCADE,
    title           TEXT NOT NULL,
    metric_key      TEXT NOT NULL,
    period          TEXT NOT NULL DEFAULT 'month'
                    CHECK (period IN ('today','week','month','quarter','year')),
    color_token     TEXT NOT NULL DEFAULT 'blue'
                    CHECK (color_token IN ('blue','green','red','navy','grey')),
    icon_token      TEXT NOT NULL DEFAULT 'chart_2'
                    CHECK (icon_token IN (
                        'chart_2','dollar_circle','briefcase','document_text',
                        'receipt','wallet','health','warning_2','people'
                    )),
    display_order   INTEGER NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','archived')),
    is_personal     BOOLEAN NOT NULL DEFAULT false,
    filter_metadata JSONB NOT NULL DEFAULT '{}',
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_kpi_widgets_business
    ON kpi_widgets(business_id, status, display_order)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_kpi_widgets_personal
    ON kpi_widgets(target_user_id, status)
    WHERE deleted_at IS NULL AND is_personal = true;

-- Status transition guard — defence in depth for direct DB writes.
CREATE OR REPLACE FUNCTION kpi_widget_status_guard() RETURNS trigger AS $$
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

DROP TRIGGER IF EXISTS trg_kpi_widget_status_guard ON kpi_widgets;
CREATE TRIGGER trg_kpi_widget_status_guard
    BEFORE UPDATE ON kpi_widgets
    FOR EACH ROW EXECUTE FUNCTION kpi_widget_status_guard();

-- Optional RLS — Phase-3 hardening rail.
ALTER TABLE kpi_widgets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS kpi_widgets_tenant_isolation ON kpi_widgets;
CREATE POLICY kpi_widgets_tenant_isolation ON kpi_widgets
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys ─────────────────────────────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('analytics.view',          'View KPI analytics widgets',                'analytics'),
    ('analytics.widget_manage', 'Create / update / delete KPI widgets',      'analytics'),
    ('analytics.export',        'Export KPI widget values to CSV',           'analytics')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('analytics.view','analytics.widget_manage','analytics.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('analytics.view','analytics.widget_manage','analytics.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('analytics.view','analytics.widget_manage')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('analytics.view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('analytics.view','analytics.export')
ON CONFLICT DO NOTHING;
