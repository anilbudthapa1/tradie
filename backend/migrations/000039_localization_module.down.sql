DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('localization.manage','localization.view','localization.export');

DELETE FROM permissions WHERE key IN ('localization.manage','localization.view','localization.export');

DROP TRIGGER IF EXISTS trg_localization_entry_status_guard ON localization_entries;
DROP FUNCTION IF EXISTS localization_entry_status_guard();

DROP INDEX IF EXISTS uq_localization_entries_business_key_language;
DROP INDEX IF EXISTS idx_localization_entries_business_status;

DROP TABLE IF EXISTS localization_entries;
