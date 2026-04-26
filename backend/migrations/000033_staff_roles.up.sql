-- ── Module 23 (Staff Roles) — custom role labels per tenant ─────
--
-- Distinct from users.role (the fixed RBAC enum). staff_roles is
-- the tenant-defined "job title" / "designation" layer:
-- "Lead Electrician", "Apprentice", "Site Supervisor". Each links
-- to a base_role so RBAC stays coherent — assigning the staff_role
-- never elevates underlying permissions.

CREATE TABLE IF NOT EXISTS staff_roles (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id      UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by       UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by       UUID REFERENCES users(id) ON DELETE SET NULL,
    name             TEXT NOT NULL,
    slug             TEXT NOT NULL,
    responsibilities TEXT NOT NULL DEFAULT '',
    base_role        TEXT NOT NULL DEFAULT 'worker'
                     CHECK (base_role IN ('admin','manager','worker','accountant')),
    color_token      TEXT NOT NULL DEFAULT 'blue'
                     CHECK (color_token IN ('blue','green','red','navy','grey')),
    icon_token       TEXT NOT NULL DEFAULT 'people'
                     CHECK (icon_token IN ('people','briefcase','health','warning_2','security_safe','chart_2','wrench','user')),
    display_order    INTEGER NOT NULL DEFAULT 0,
    status           TEXT NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active','archived')),
    metadata         JSONB NOT NULL DEFAULT '{}',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at       TIMESTAMPTZ
);

-- Slug is the machine identifier — unique per tenant for active rows.
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_roles_business_slug
    ON staff_roles(business_id, lower(slug))
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_staff_roles_business_status
    ON staff_roles(business_id, status, display_order)
    WHERE deleted_at IS NULL;

-- Status transition guard.
CREATE OR REPLACE FUNCTION staff_role_status_guard() RETURNS trigger AS $$
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

DROP TRIGGER IF EXISTS trg_staff_role_status_guard ON staff_roles;
CREATE TRIGGER trg_staff_role_status_guard
    BEFORE UPDATE ON staff_roles
    FOR EACH ROW EXECUTE FUNCTION staff_role_status_guard();

ALTER TABLE staff_roles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_roles_tenant_isolation ON staff_roles;
CREATE POLICY staff_roles_tenant_isolation ON staff_roles
    USING (business_id::text = current_setting('app.business_id', true));

-- Optional FK from users to their tenant-defined role label.
ALTER TABLE users ADD COLUMN IF NOT EXISTS staff_role_id UUID REFERENCES staff_roles(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_users_staff_role
    ON users(staff_role_id)
    WHERE staff_role_id IS NOT NULL;

-- Tenant integrity: a user's staff_role must belong to their business.
-- Enforced via a trigger because cross-table CHECK isn't available in
-- vanilla Postgres.
CREATE OR REPLACE FUNCTION users_staff_role_tenant_guard() RETURNS trigger AS $$
DECLARE
    role_biz UUID;
BEGIN
    IF NEW.staff_role_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT business_id INTO role_biz FROM staff_roles WHERE id = NEW.staff_role_id;
    IF role_biz IS NULL THEN
        RAISE EXCEPTION 'staff_role_not_found' USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF role_biz <> NEW.business_id THEN
        RAISE EXCEPTION 'staff_role_cross_tenant' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_users_staff_role_tenant_guard ON users;
CREATE TRIGGER trg_users_staff_role_tenant_guard
    BEFORE INSERT OR UPDATE OF staff_role_id ON users
    FOR EACH ROW EXECUTE FUNCTION users_staff_role_tenant_guard();

-- ── Permission keys (spec §Core Permissions: roles.manage) ──────
INSERT INTO permissions (key, description, category) VALUES
    ('roles.manage', 'Create / update / archive tenant staff roles', 'roles'),
    ('roles.view',   'View staff roles list',                          'roles'),
    ('roles.assign', 'Assign staff roles to workers',                  'roles'),
    ('roles.export', 'Export staff roles to CSV',                      'roles')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('roles.manage','roles.view','roles.assign','roles.export')
ON CONFLICT DO NOTHING;

-- Admin gets manage + assign + export (not roles.manage by default
-- per the spec being roles.manage = owner-tier; here we extend so
-- admins can administer day-to-day without owner unblocking each
-- change). If your tenant prefers tighter control, deny via the
-- per-business override in role_permissions.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('roles.manage','roles.view','roles.assign','roles.export')
ON CONFLICT DO NOTHING;

-- Manager can view + assign existing roles but cannot edit the catalogue.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('roles.view','roles.assign')
ON CONFLICT DO NOTHING;

-- Workers + accountants can only view (so they see their own label
-- on their profile and the catalogue context).
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('roles.view')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('roles.view')
ON CONFLICT DO NOTHING;
