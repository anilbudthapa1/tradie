DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('leave.request','leave.approve','leave.view','leave.manage','leave.export');

DELETE FROM permissions WHERE key IN ('leave.request','leave.approve','leave.view','leave.manage','leave.export');

DROP TRIGGER  IF EXISTS trg_leave_request_status_guard ON leave_requests;
DROP FUNCTION IF EXISTS leave_request_status_guard();

DROP INDEX IF EXISTS idx_leave_requests_business_status;
DROP INDEX IF EXISTS idx_leave_requests_worker_range;

ALTER TABLE leave_requests DROP CONSTRAINT IF EXISTS leave_requests_dates_check;

-- Restore the legacy status check.
ALTER TABLE leave_requests DROP CONSTRAINT IF EXISTS leave_requests_status_check;
ALTER TABLE leave_requests
    ADD CONSTRAINT leave_requests_status_check
    CHECK (status IN ('pending','approved','rejected'));

ALTER TABLE leave_requests DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE leave_requests DROP COLUMN IF EXISTS metadata;
ALTER TABLE leave_requests DROP COLUMN IF EXISTS updated_by;
ALTER TABLE leave_requests DROP COLUMN IF EXISTS created_by;
