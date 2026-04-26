DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('analytics.view','analytics.widget_manage','analytics.export');

DELETE FROM permissions WHERE key IN ('analytics.view','analytics.widget_manage','analytics.export');

DROP TRIGGER  IF EXISTS trg_kpi_widget_status_guard ON kpi_widgets;
DROP FUNCTION IF EXISTS kpi_widget_status_guard();
DROP TABLE    IF EXISTS kpi_widgets;
