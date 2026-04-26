DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('customers.history.view','customers.history.create','customers.history.manage','customers.history.export');

DELETE FROM permissions WHERE key IN ('customers.history.view','customers.history.create','customers.history.manage','customers.history.export');

DROP TRIGGER  IF EXISTS trg_customer_note_status_guard ON customer_notes;
DROP FUNCTION IF EXISTS customer_note_status_guard();

ALTER TABLE customer_notes DROP CONSTRAINT IF EXISTS customer_notes_kind_check;
ALTER TABLE customer_notes DROP CONSTRAINT IF EXISTS customer_notes_status_check;

DROP INDEX IF EXISTS idx_customer_notes_business_kind;
DROP INDEX IF EXISTS idx_customer_notes_customer_active;

ALTER TABLE customer_notes DROP COLUMN IF EXISTS kind;
ALTER TABLE customer_notes DROP COLUMN IF EXISTS metadata;
ALTER TABLE customer_notes DROP COLUMN IF EXISTS status;
ALTER TABLE customer_notes DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE customer_notes DROP COLUMN IF EXISTS updated_at;
ALTER TABLE customer_notes DROP COLUMN IF EXISTS updated_by;
