DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('leads.view','leads.create','leads.update','leads.convert','leads.delete','leads.export');

DELETE FROM permissions WHERE key IN ('leads.view','leads.create','leads.update','leads.convert','leads.delete','leads.export');

DROP TRIGGER  IF EXISTS trg_lead_status_guard ON leads;
DROP FUNCTION IF EXISTS lead_status_guard();

DROP INDEX IF EXISTS idx_leads_business_status;
DROP INDEX IF EXISTS idx_leads_business_assigned;

ALTER TABLE leads DROP COLUMN IF EXISTS metadata;
ALTER TABLE leads DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE leads DROP COLUMN IF EXISTS updated_by;
ALTER TABLE leads DROP COLUMN IF EXISTS created_by;
