-- ── Module 20 (Lead Management) — schema hardening ─────────────
--
-- Bug fix: handlers/leads queries `WHERE deleted_at IS NULL` and
-- `UPDATE leads SET deleted_at=NOW()` but the column never existed.
-- This migration adds it (idempotent) plus the rest of the spec
-- CRUD-pattern columns, status-transition trigger, and seeds the
-- leads.view / .create / .convert permission keys.

ALTER TABLE leads ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS metadata   JSONB NOT NULL DEFAULT '{}';

-- Status pipeline transition guard. Existing CHECK constraint already
-- pins the allow-list; this enforces the directed flow:
--
--   new → contacted → qualified → proposal → won
--                  ↘            ↘          ↘
--                                          lost
--
-- Re-opening (e.g. won → contacted) is blocked. Reactivation is via a
-- new lead row, not a status flip.
CREATE OR REPLACE FUNCTION lead_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF OLD.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'cannot_change_status_on_deleted_lead'
            USING ERRCODE = 'check_violation';
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('new','contacted'),
        ('new','qualified'),
        ('new','lost'),
        ('contacted','qualified'),
        ('contacted','proposal'),
        ('contacted','lost'),
        ('qualified','proposal'),
        ('qualified','lost'),
        ('proposal','won'),
        ('proposal','lost')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_lead_status_guard ON leads;
CREATE TRIGGER trg_lead_status_guard
    BEFORE UPDATE ON leads
    FOR EACH ROW EXECUTE FUNCTION lead_status_guard();

-- Soft-delete-aware composite indexes.
CREATE INDEX IF NOT EXISTS idx_leads_business_status
    ON leads(business_id, status, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_leads_business_assigned
    ON leads(business_id, assigned_to, status)
    WHERE deleted_at IS NULL AND assigned_to IS NOT NULL;

ALTER TABLE leads ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leads_tenant_isolation ON leads;
CREATE POLICY leads_tenant_isolation ON leads
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('leads.view',    'View leads',                    'leads'),
    ('leads.create',  'Create leads',                  'leads'),
    ('leads.update',  'Update leads / re-assign',      'leads'),
    ('leads.convert', 'Convert leads to customers',    'leads'),
    ('leads.delete',  'Soft-delete leads',             'leads'),
    ('leads.export',  'Export leads to CSV',           'leads')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('leads.view','leads.create','leads.update','leads.convert','leads.delete','leads.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('leads.view','leads.create','leads.update','leads.convert','leads.delete','leads.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('leads.view','leads.create','leads.update','leads.convert')
ON CONFLICT DO NOTHING;

-- Workers can read leads assigned to them and create new ones from the
-- field; backend enforces the assigned-to-self constraint for non-managers.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('leads.view','leads.create')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('leads.view')
ON CONFLICT DO NOTHING;
