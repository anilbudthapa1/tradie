DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('reminders.view','reminders.create','reminders.manage','reminders.export');

DELETE FROM permissions WHERE key IN ('reminders.view','reminders.create','reminders.manage','reminders.export');

DROP TRIGGER  IF EXISTS trg_task_reminder_status_guard ON task_reminders;
DROP FUNCTION IF EXISTS task_reminder_status_guard();
DROP TABLE    IF EXISTS task_reminders;
