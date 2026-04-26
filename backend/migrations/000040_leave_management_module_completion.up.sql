-- ── Module 27 completion — self-service withdraw/edit permission ──
--
-- Workers can update/cancel only their own pending leave because the
-- handler scopes non-manager access by worker_id and status.

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('leave.manage')
ON CONFLICT DO NOTHING;
