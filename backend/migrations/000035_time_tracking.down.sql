DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('time.view','time.create','time.update','time.approve','time.delete','time.export');

DELETE FROM permissions WHERE key IN ('time.view','time.create','time.update','time.approve','time.delete','time.export');

DROP TRIGGER  IF EXISTS trg_timesheet_status_guard ON timesheets;
DROP FUNCTION IF EXISTS timesheet_status_guard();

DROP INDEX IF EXISTS idx_timesheets_business_status;
DROP INDEX IF EXISTS idx_timesheets_worker_date;

ALTER TABLE timesheets DROP CONSTRAINT IF EXISTS timesheets_window_check;

-- Restore the legacy status check.
ALTER TABLE timesheets DROP CONSTRAINT IF EXISTS timesheets_status_check;
ALTER TABLE timesheets
    ADD CONSTRAINT timesheets_status_check
    CHECK (status IN ('pending','approved','rejected'));

ALTER TABLE timesheets DROP COLUMN IF EXISTS submitted_at;
ALTER TABLE timesheets DROP COLUMN IF EXISTS rejection_reason;
ALTER TABLE timesheets DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE timesheets DROP COLUMN IF EXISTS metadata;
ALTER TABLE timesheets DROP COLUMN IF EXISTS updated_by;
ALTER TABLE timesheets DROP COLUMN IF EXISTS created_by;
