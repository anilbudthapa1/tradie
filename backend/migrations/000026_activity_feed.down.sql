DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('activity.view','activity.create','activity.manage','activity.export');

DELETE FROM permissions WHERE key IN ('activity.view','activity.create','activity.manage','activity.export');

DROP TRIGGER  IF EXISTS trg_tenant_activity_status_guard ON tenant_activity_entries;
DROP FUNCTION IF EXISTS tenant_activity_status_guard();
DROP TABLE    IF EXISTS tenant_activity_entries;
