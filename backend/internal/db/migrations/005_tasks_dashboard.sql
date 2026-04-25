-- ============================================================
-- Migration 005: Tasks / Reminders & Activity Feed
-- ============================================================

CREATE TYPE task_priority AS ENUM ('low', 'medium', 'high', 'urgent');
CREATE TYPE task_status   AS ENUM ('pending', 'in_progress', 'completed', 'cancelled');

CREATE TABLE tasks (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by      UUID NOT NULL REFERENCES users(id),
    assigned_to     UUID REFERENCES users(id),
    job_id          UUID REFERENCES jobs(id),
    title           TEXT NOT NULL,
    description     TEXT,
    priority        task_priority DEFAULT 'medium',
    status          task_status DEFAULT 'pending',
    due_date        TIMESTAMPTZ,
    reminder_at     TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    completed_by    UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_tasks_business   ON tasks(business_id, status, due_date);
CREATE INDEX idx_tasks_assigned   ON tasks(assigned_to, status, due_date);
CREATE INDEX idx_tasks_job        ON tasks(job_id) WHERE job_id IS NOT NULL;
CREATE INDEX idx_tasks_reminder   ON tasks(reminder_at) WHERE reminder_at IS NOT NULL AND status = 'pending';

-- Activity feed view — combines audit_logs with human-readable details
CREATE OR REPLACE VIEW activity_feed AS
SELECT
    al.id,
    al.business_id,
    al.user_id,
    u.first_name || ' ' || u.last_name AS user_name,
    al.action,
    al.entity_type,
    al.entity_id,
    al.ip_address,
    al.created_at,
    -- Derive a display label and icon hint from action
    CASE
        WHEN al.action LIKE 'job.%'      THEN 'job'
        WHEN al.action LIKE 'invoice.%'  THEN 'invoice'
        WHEN al.action LIKE 'quote.%'    THEN 'quote'
        WHEN al.action LIKE 'customer.%' THEN 'customer'
        WHEN al.action LIKE 'worker.%'   THEN 'worker'
        WHEN al.action LIKE 'payment.%'  THEN 'payment'
        WHEN al.action LIKE 'session.%'  THEN 'auth'
        ELSE 'system'
    END AS category
FROM audit_logs al
LEFT JOIN users u ON u.id = al.user_id;
