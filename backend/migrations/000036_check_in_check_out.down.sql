DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('checkin.create','checkout.create','checkin.view','checkin.manage','checkin.export');

DELETE FROM permissions WHERE key IN ('checkin.create','checkout.create','checkin.view','checkin.manage','checkin.export');

DROP TRIGGER  IF EXISTS trg_worker_check_in_status_guard ON worker_check_ins;
DROP FUNCTION IF EXISTS worker_check_in_status_guard();

DROP INDEX IF EXISTS uq_worker_check_ins_one_active;
DROP INDEX IF EXISTS idx_worker_check_ins_business_status;
DROP INDEX IF EXISTS idx_worker_check_ins_job;
DROP INDEX IF EXISTS idx_worker_check_ins_user_active;

ALTER TABLE worker_check_ins DROP CONSTRAINT IF EXISTS worker_check_ins_status_check;
ALTER TABLE worker_check_ins DROP CONSTRAINT IF EXISTS worker_check_ins_latlng_check;

ALTER TABLE worker_check_ins DROP COLUMN IF EXISTS accuracy_m;
ALTER TABLE worker_check_ins DROP COLUMN IF EXISTS status;
ALTER TABLE worker_check_ins DROP COLUMN IF EXISTS updated_at;
ALTER TABLE worker_check_ins DROP COLUMN IF EXISTS created_at;
ALTER TABLE worker_check_ins DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE worker_check_ins DROP COLUMN IF EXISTS metadata;
ALTER TABLE worker_check_ins DROP COLUMN IF EXISTS updated_by;
ALTER TABLE worker_check_ins DROP COLUMN IF EXISTS created_by;
