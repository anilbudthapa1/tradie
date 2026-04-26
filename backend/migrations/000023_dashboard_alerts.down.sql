-- ── Reverse Batch 14: Dashboard Module ──────────────────────────

DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN (
      'dashboard.view','dashboard.owner_view','dashboard.employee_view',
      'dashboard.alert_manage','dashboard.export'
  );

DELETE FROM permissions WHERE key IN (
    'dashboard.view','dashboard.owner_view','dashboard.employee_view',
    'dashboard.alert_manage','dashboard.export'
);

DROP TRIGGER  IF EXISTS trg_dashboard_alert_status_guard ON dashboard_alerts;
DROP FUNCTION IF EXISTS dashboard_alert_status_guard();
DROP TABLE    IF EXISTS dashboard_alerts;
