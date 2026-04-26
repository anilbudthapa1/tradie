DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('payslips.view_own','payslips.generate');

DELETE FROM permissions WHERE key IN ('payslips.view_own','payslips.generate');

ALTER TABLE payslips DROP COLUMN IF EXISTS pdf_download_count;
ALTER TABLE payslips DROP COLUMN IF EXISTS pdf_generated_at;
