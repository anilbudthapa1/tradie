DROP TRIGGER  IF EXISTS trg_customer_status_guard ON customers;
DROP FUNCTION IF EXISTS customer_status_guard();

ALTER TABLE customers DROP CONSTRAINT IF EXISTS customers_status_check;

DROP INDEX IF EXISTS idx_customers_business_status;
DROP INDEX IF EXISTS idx_customers_business_active;

ALTER TABLE customers DROP COLUMN IF EXISTS metadata;
ALTER TABLE customers DROP COLUMN IF EXISTS status;
ALTER TABLE customers DROP COLUMN IF EXISTS updated_by;
ALTER TABLE customers DROP COLUMN IF EXISTS created_by;
ALTER TABLE customers DROP COLUMN IF EXISTS deleted_at;
