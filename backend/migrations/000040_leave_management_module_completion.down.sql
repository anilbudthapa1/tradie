DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND role_permissions.role = 'worker'
  AND permissions.key = 'leave.manage';
