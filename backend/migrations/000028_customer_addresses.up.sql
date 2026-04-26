-- ── Module 17 (Customer Address) — schema hardening ────────────
--
-- Adds the spec-required CRUD-pattern columns to customer_addresses,
-- introduces address_type (service/billing/postal/other) so callers
-- can distinguish them, and seeds the customers.addresses.manage
-- permission key.
--
-- DELETE on this table previously hard-deleted; soft-delete via the
-- new deleted_at column is now the canonical path.

ALTER TABLE customer_addresses ADD COLUMN IF NOT EXISTS created_by   UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE customer_addresses ADD COLUMN IF NOT EXISTS updated_by   UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE customer_addresses ADD COLUMN IF NOT EXISTS updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE customer_addresses ADD COLUMN IF NOT EXISTS deleted_at   TIMESTAMPTZ;
ALTER TABLE customer_addresses ADD COLUMN IF NOT EXISTS status       TEXT NOT NULL DEFAULT 'active';
ALTER TABLE customer_addresses ADD COLUMN IF NOT EXISTS metadata     JSONB NOT NULL DEFAULT '{}';
ALTER TABLE customer_addresses ADD COLUMN IF NOT EXISTS address_type TEXT NOT NULL DEFAULT 'service';

-- Backfill address_type from the legacy free-text label when possible.
UPDATE customer_addresses
   SET address_type = CASE
       WHEN lower(coalesce(label,'')) LIKE '%bill%'   THEN 'billing'
       WHEN lower(coalesce(label,'')) LIKE '%post%'   THEN 'postal'
       WHEN lower(coalesce(label,'')) LIKE '%mail%'   THEN 'postal'
       WHEN lower(coalesce(label,'')) IN ('site','service','job','work') THEN 'service'
       ELSE address_type
   END
 WHERE address_type = 'service';

-- Constraints — added separately so backfill above runs first.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'customer_addresses_status_check'
    ) THEN
        ALTER TABLE customer_addresses
            ADD CONSTRAINT customer_addresses_status_check
            CHECK (status IN ('active','archived'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'customer_addresses_type_check'
    ) THEN
        ALTER TABLE customer_addresses
            ADD CONSTRAINT customer_addresses_type_check
            CHECK (address_type IN ('service','billing','postal','other'));
    END IF;
END$$;

-- Soft-delete-aware composite indexes.
CREATE INDEX IF NOT EXISTS idx_customer_addresses_business_status
    ON customer_addresses(business_id, status)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_customer_addresses_customer_active
    ON customer_addresses(customer_id, is_primary, created_at)
    WHERE deleted_at IS NULL;

-- Status transition guard (mirrors the customer pattern).
CREATE OR REPLACE FUNCTION customer_address_status_guard() RETURNS trigger AS $$
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

DROP TRIGGER IF EXISTS trg_customer_address_status_guard ON customer_addresses;
CREATE TRIGGER trg_customer_address_status_guard
    BEFORE UPDATE ON customer_addresses
    FOR EACH ROW EXECUTE FUNCTION customer_address_status_guard();

ALTER TABLE customer_addresses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS customer_addresses_tenant_isolation ON customer_addresses;
CREATE POLICY customer_addresses_tenant_isolation ON customer_addresses
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('customers.addresses.manage', 'Create, update, archive customer addresses', 'customers'),
    ('customers.addresses.export', 'Export customer addresses to CSV',          'customers')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('customers.addresses.manage','customers.addresses.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('customers.addresses.manage','customers.addresses.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('customers.addresses.manage')
ON CONFLICT DO NOTHING;
