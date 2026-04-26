DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('payroll.view','payroll.process','payroll.export');

DELETE FROM permissions WHERE key IN ('payroll.view','payroll.process','payroll.export');

ALTER TABLE business_payroll_settings DROP COLUMN IF EXISTS tax_rate;

ALTER TABLE superannuation DROP COLUMN IF EXISTS updated_at;
ALTER TABLE superannuation DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE superannuation DROP COLUMN IF EXISTS metadata;
ALTER TABLE superannuation DROP COLUMN IF EXISTS updated_by;
ALTER TABLE superannuation DROP COLUMN IF EXISTS created_by;

DROP INDEX IF EXISTS idx_payslips_business_status;
DROP INDEX IF EXISTS idx_payslips_worker;
ALTER TABLE payslips DROP CONSTRAINT IF EXISTS payslips_status_check;
ALTER TABLE payslips DROP COLUMN IF EXISTS hourly_rate;
ALTER TABLE payslips DROP COLUMN IF EXISTS hours_worked;
ALTER TABLE payslips DROP COLUMN IF EXISTS status;
ALTER TABLE payslips DROP COLUMN IF EXISTS updated_at;
ALTER TABLE payslips DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE payslips DROP COLUMN IF EXISTS metadata;
ALTER TABLE payslips DROP COLUMN IF EXISTS updated_by;
ALTER TABLE payslips DROP COLUMN IF EXISTS created_by;

DROP TRIGGER  IF EXISTS trg_pay_run_status_guard ON pay_runs;
DROP FUNCTION IF EXISTS pay_run_status_guard();
DROP INDEX    IF EXISTS idx_pay_runs_business_status;
ALTER TABLE pay_runs DROP CONSTRAINT IF EXISTS pay_runs_dates_check;
ALTER TABLE pay_runs DROP CONSTRAINT IF EXISTS pay_runs_status_check;
ALTER TABLE pay_runs ADD CONSTRAINT pay_runs_status_check
    CHECK (status IN ('draft','processed','paid'));
ALTER TABLE pay_runs DROP COLUMN IF EXISTS paid_at;
ALTER TABLE pay_runs DROP COLUMN IF EXISTS processed_at;
ALTER TABLE pay_runs DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE pay_runs DROP COLUMN IF EXISTS metadata;
ALTER TABLE pay_runs DROP COLUMN IF EXISTS updated_by;
