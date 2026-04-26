DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('employees.view','employees.create','employees.update','employees.delete','employees.export');

DELETE FROM permissions WHERE key IN ('employees.view','employees.create','employees.update','employees.delete','employees.export');

DROP TRIGGER  IF EXISTS trg_worker_status_guard ON users;
DROP FUNCTION IF EXISTS worker_status_guard();

DROP INDEX IF EXISTS idx_users_business_worker_status;

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_worker_status_check;
ALTER TABLE users DROP COLUMN IF EXISTS worker_status;
ALTER TABLE users DROP COLUMN IF EXISTS metadata;
ALTER TABLE users DROP COLUMN IF EXISTS updated_by;
ALTER TABLE users DROP COLUMN IF EXISTS created_by;
