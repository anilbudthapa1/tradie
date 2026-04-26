-- ── Module 19 (Customer History) — annotations + permissions ───
--
-- Customer history has two streams:
--
--   1. Derived timeline — UNION ALL across jobs/quotes/invoices/
--      payments/customer_notes for a single customer. Read-only.
--      Existing handler (customers.History) covers this; the router
--      wiring is added separately.
--
--   2. Owner-authored history annotations — extends customer_notes
--      with the spec's CRUD-pattern columns plus a `kind` field
--      (note / call / sms / email / site_visit / other) so the UI
--      can render type-aware badges.

ALTER TABLE customer_notes ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE customer_notes ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE customer_notes ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE customer_notes ADD COLUMN IF NOT EXISTS status     TEXT NOT NULL DEFAULT 'active';
ALTER TABLE customer_notes ADD COLUMN IF NOT EXISTS metadata   JSONB NOT NULL DEFAULT '{}';
ALTER TABLE customer_notes ADD COLUMN IF NOT EXISTS kind       TEXT NOT NULL DEFAULT 'note';

-- Constraints — added separately so existing rows backfill cleanly.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'customer_notes_status_check'
    ) THEN
        ALTER TABLE customer_notes
            ADD CONSTRAINT customer_notes_status_check
            CHECK (status IN ('active','archived'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'customer_notes_kind_check'
    ) THEN
        ALTER TABLE customer_notes
            ADD CONSTRAINT customer_notes_kind_check
            CHECK (kind IN ('note','call','sms','email','site_visit','other'));
    END IF;
END$$;

-- Soft-delete-aware composite indexes for the history list query.
CREATE INDEX IF NOT EXISTS idx_customer_notes_business_kind
    ON customer_notes(business_id, kind, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_customer_notes_customer_active
    ON customer_notes(customer_id, business_id, created_at DESC)
    WHERE deleted_at IS NULL;

-- Status transition guard.
CREATE OR REPLACE FUNCTION customer_note_status_guard() RETURNS trigger AS $$
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

DROP TRIGGER IF EXISTS trg_customer_note_status_guard ON customer_notes;
CREATE TRIGGER trg_customer_note_status_guard
    BEFORE UPDATE ON customer_notes
    FOR EACH ROW EXECUTE FUNCTION customer_note_status_guard();

ALTER TABLE customer_notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS customer_notes_tenant_isolation ON customer_notes;
CREATE POLICY customer_notes_tenant_isolation ON customer_notes
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('customers.history.view',   'View customer history timeline',          'customers'),
    ('customers.history.create', 'Author customer history annotations',      'customers'),
    ('customers.history.manage', 'Update / archive history annotations',     'customers'),
    ('customers.history.export', 'Export customer history to CSV',           'customers')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('customers.history.view','customers.history.create','customers.history.manage','customers.history.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('customers.history.view','customers.history.create','customers.history.manage','customers.history.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('customers.history.view','customers.history.create','customers.history.manage')
ON CONFLICT DO NOTHING;

-- Workers can view + author for customers they have jobs for; backend
-- still scopes the read to assigned jobs via /me/customer_history_module.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('customers.history.view','customers.history.create')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('customers.history.view')
ON CONFLICT DO NOTHING;
