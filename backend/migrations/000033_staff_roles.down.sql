DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('roles.manage','roles.view','roles.assign','roles.export');

DELETE FROM permissions WHERE key IN ('roles.manage','roles.view','roles.assign','roles.export');

DROP TRIGGER  IF EXISTS trg_users_staff_role_tenant_guard ON users;
DROP FUNCTION IF EXISTS users_staff_role_tenant_guard();

DROP INDEX IF EXISTS idx_users_staff_role;
ALTER TABLE users DROP COLUMN IF EXISTS staff_role_id;

DROP TRIGGER  IF EXISTS trg_staff_role_status_guard ON staff_roles;
DROP FUNCTION IF EXISTS staff_role_status_guard();

DROP INDEX IF EXISTS uq_staff_roles_business_slug;
DROP INDEX IF EXISTS idx_staff_roles_business_status;

DROP TABLE IF EXISTS staff_roles;
