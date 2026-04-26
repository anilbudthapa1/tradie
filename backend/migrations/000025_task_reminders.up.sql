-- ── Module 13 (Task Reminder) — standalone CRUD entity + perms ──
--
-- This table is intentionally separate from `tasks.reminder_at`. The
-- spec scopes reminders across jobs, invoices, safety, licences and
-- follow-ups; a Task wrapper is too narrow for those. The existing
-- task-reminder-at flow is preserved untouched.

CREATE TABLE IF NOT EXISTS task_reminders (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    target_user_id  UUID REFERENCES users(id) ON DELETE CASCADE,
    title           TEXT NOT NULL,
    note            TEXT NOT NULL DEFAULT '',
    entity_type     TEXT NOT NULL DEFAULT 'custom'
                    CHECK (entity_type IN ('job','invoice','quote','safety','licence','followup','custom')),
    entity_id       UUID,
    remind_at       TIMESTAMPTZ NOT NULL,
    channel         TEXT NOT NULL DEFAULT 'inapp'
                    CHECK (channel IN ('inapp','email','sms','push')),
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','sent','snoozed','dismissed','cancelled')),
    sent_at         TIMESTAMPTZ,
    snoozed_until   TIMESTAMPTZ,
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_task_reminders_due
    ON task_reminders(business_id, status, remind_at)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_reminders_target
    ON task_reminders(target_user_id, status, remind_at)
    WHERE deleted_at IS NULL AND target_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_task_reminders_entity
    ON task_reminders(business_id, entity_type, entity_id)
    WHERE deleted_at IS NULL AND entity_id IS NOT NULL;

-- Status transition guard.
CREATE OR REPLACE FUNCTION task_reminder_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('pending','sent'),
        ('pending','snoozed'),
        ('pending','dismissed'),
        ('pending','cancelled'),
        ('snoozed','pending'),
        ('snoozed','dismissed'),
        ('snoozed','cancelled'),
        ('sent','dismissed')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_task_reminder_status_guard ON task_reminders;
CREATE TRIGGER trg_task_reminder_status_guard
    BEFORE UPDATE ON task_reminders
    FOR EACH ROW EXECUTE FUNCTION task_reminder_status_guard();

ALTER TABLE task_reminders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS task_reminders_tenant_isolation ON task_reminders;
CREATE POLICY task_reminders_tenant_isolation ON task_reminders
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions) ────────────────────
INSERT INTO permissions (key, description, category) VALUES
    ('reminders.view',    'View task reminders',          'reminders'),
    ('reminders.create',  'Create task reminders',        'reminders'),
    ('reminders.manage',  'Update / dismiss reminders',   'reminders'),
    ('reminders.export',  'Export task reminders to CSV', 'reminders')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('reminders.view','reminders.create','reminders.manage','reminders.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('reminders.view','reminders.create','reminders.manage','reminders.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('reminders.view','reminders.create','reminders.manage')
ON CONFLICT DO NOTHING;

-- Workers can view their own reminders and create reminders for themselves.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('reminders.view','reminders.create')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN ('reminders.view')
ON CONFLICT DO NOTHING;
