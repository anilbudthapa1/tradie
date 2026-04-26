DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('customers.addresses.manage','customers.addresses.export');

DELETE FROM permissions WHERE key IN ('customers.addresses.manage','customers.addresses.export');

DROP TRIGGER  IF EXISTS trg_customer_address_status_guard ON customer_addresses;
DROP FUNCTION IF EXISTS customer_address_status_guard();

ALTER TABLE customer_addresses DROP CONSTRAINT IF EXISTS customer_addresses_type_check;
ALTER TABLE customer_addresses DROP CONSTRAINT IF EXISTS customer_addresses_status_check;

DROP INDEX IF EXISTS idx_customer_addresses_business_status;
DROP INDEX IF EXISTS idx_customer_addresses_customer_active;

ALTER TABLE customer_addresses DROP COLUMN IF EXISTS address_type;
ALTER TABLE customer_addresses DROP COLUMN IF EXISTS metadata;
ALTER TABLE customer_addresses DROP COLUMN IF EXISTS status;
ALTER TABLE customer_addresses DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE customer_addresses DROP COLUMN IF EXISTS updated_at;
ALTER TABLE customer_addresses DROP COLUMN IF EXISTS updated_by;
ALTER TABLE customer_addresses DROP COLUMN IF EXISTS created_by;
