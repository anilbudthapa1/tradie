-- ── Batch 14: Dashboard Module (M11) — alerts, permissions, RLS ───

-- ── Dashboard alerts ─────────────────────────────────────────────
-- Records the spec-required CRUD entity. Alerts are owner-managed,
-- can target a specific user (employee self-service view) or the
-- whole tenant.
CREATE TABLE IF NOT EXISTS dashboard_alerts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    target_user_id  UUID REFERENCES users(id) ON DELETE CASCADE,
    title           TEXT NOT NULL,
    message         TEXT NOT NULL DEFAULT '',
    severity        TEXT NOT NULL DEFAULT 'info'
                    CHECK (severity IN ('info','warning','critical')),
    alert_type      TEXT NOT NULL DEFAULT 'custom'
                    CHECK (alert_type IN ('custom','kpi_threshold','overdue','compliance','system')),
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','acknowledged','resolved','dismissed')),
    metadata        JSONB NOT NULL DEFAULT '{}',
    acknowledged_at TIMESTAMPTZ,
    acknowledged_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_dashboard_alerts_business
    ON dashboard_alerts(business_id, status, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_dashboard_alerts_target
    ON dashboard_alerts(target_user_id, status)
    WHERE deleted_at IS NULL AND target_user_id IS NOT NULL;

-- Allowed status transitions enforced server-side; this trigger acts
-- as a defence-in-depth backstop should any caller bypass the handler.
CREATE OR REPLACE FUNCTION dashboard_alert_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('active','acknowledged'),
        ('active','dismissed'),
        ('active','resolved'),
        ('acknowledged','resolved'),
        ('acknowledged','dismissed')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dashboard_alert_status_guard ON dashboard_alerts;
CREATE TRIGGER trg_dashboard_alert_status_guard
    BEFORE UPDATE ON dashboard_alerts
    FOR EACH ROW EXECUTE FUNCTION dashboard_alert_status_guard();

-- Optional RLS — enabled but off by default; app uses BusinessIDFromCtx.
-- Provided as a hardening rail callable by ops without code change.
ALTER TABLE dashboard_alerts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dashboard_alerts_tenant_isolation ON dashboard_alerts;
CREATE POLICY dashboard_alerts_tenant_isolation ON dashboard_alerts
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys ──────────────────────────────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('dashboard.view',          'View dashboard KPIs and alerts',           'dashboard'),
    ('dashboard.owner_view',    'Owner-level dashboard (revenue, unpaid)',  'dashboard'),
    ('dashboard.employee_view', 'Self-service dashboard (assigned work)',   'dashboard'),
    ('dashboard.alert_manage',  'Create, update, dismiss dashboard alerts', 'dashboard'),
    ('dashboard.export',        'Export dashboard CSV',                     'dashboard')
ON CONFLICT (key) DO NOTHING;

-- Owner / admin: every dashboard permission.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN (
    'dashboard.view','dashboard.owner_view','dashboard.employee_view',
    'dashboard.alert_manage','dashboard.export'
)
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN (
    'dashboard.view','dashboard.owner_view','dashboard.employee_view',
    'dashboard.alert_manage','dashboard.export'
)
ON CONFLICT DO NOTHING;

-- Manager: owner_view (financial KPIs) + alert management, no export.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN (
    'dashboard.view','dashboard.owner_view','dashboard.employee_view','dashboard.alert_manage'
)
ON CONFLICT DO NOTHING;

-- Worker / accountant: self-service only.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('dashboard.view','dashboard.employee_view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('dashboard.view','dashboard.owner_view')
ON CONFLICT DO NOTHING;
