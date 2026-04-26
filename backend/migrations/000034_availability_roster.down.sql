DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('roster.view','roster.update','roster.approve','roster.export');

DELETE FROM permissions WHERE key IN ('roster.view','roster.update','roster.approve','roster.export');

DROP TRIGGER  IF EXISTS trg_roster_status_guard ON roster_assignments;
DROP FUNCTION IF EXISTS roster_status_guard();
DROP TABLE    IF EXISTS roster_assignments;

DROP TRIGGER  IF EXISTS trg_availability_block_status_guard ON availability_blocks;
DROP FUNCTION IF EXISTS availability_block_status_guard();
DROP TABLE    IF EXISTS availability_blocks;

ALTER TABLE worker_availability DROP CONSTRAINT IF EXISTS worker_availability_status_check;
ALTER TABLE worker_availability DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE worker_availability DROP COLUMN IF EXISTS metadata;
ALTER TABLE worker_availability DROP COLUMN IF EXISTS status;
ALTER TABLE worker_availability DROP COLUMN IF EXISTS updated_by;
ALTER TABLE worker_availability DROP COLUMN IF EXISTS created_by;
