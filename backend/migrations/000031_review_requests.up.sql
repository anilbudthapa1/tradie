-- ── Module 21 (Review Request) — schema hardening + public token ─
--
-- The bare table was created in M007. This migration:
--   * Adds the spec CRUD-pattern columns (created_by, updated_by,
--     updated_at, deleted_at, metadata)
--   * Adds the public review-link mechanics: token, expires_at,
--     channel, last_reminder_at, reminder_count
--   * Extends the status check to include 'expired'
--   * Adds a status-transition trigger
--   * Seeds the reviews.request permission key (spec) plus
--     fine-grained .view / .manage / .export
--   * Enables RLS

ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS created_by       UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS updated_by       UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS deleted_at       TIMESTAMPTZ;
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS metadata         JSONB NOT NULL DEFAULT '{}';
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS token            TEXT;
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS expires_at       TIMESTAMPTZ;
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS channel          TEXT NOT NULL DEFAULT 'email';
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS last_reminder_at TIMESTAMPTZ;
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS reminder_count   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE review_requests ADD COLUMN IF NOT EXISTS opened_at        TIMESTAMPTZ;

-- Drop the legacy status check so we can add 'expired'.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'review_requests_status_check'
    ) THEN
        ALTER TABLE review_requests DROP CONSTRAINT review_requests_status_check;
    END IF;
    ALTER TABLE review_requests
        ADD CONSTRAINT review_requests_status_check
        CHECK (status IN ('sent','opened','responded','declined','expired'));

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
         WHERE constraint_name = 'review_requests_channel_check'
    ) THEN
        ALTER TABLE review_requests
            ADD CONSTRAINT review_requests_channel_check
            CHECK (channel IN ('email','sms','push','manual'));
    END IF;
END$$;

-- Token is unique when present — soft-deleted rows can keep the row but
-- the token may be reused if it's NULL'd out.
CREATE UNIQUE INDEX IF NOT EXISTS uq_review_requests_token
    ON review_requests(token)
    WHERE token IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_review_requests_business_status
    ON review_requests(business_id, status, sent_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_review_requests_job
    ON review_requests(job_id, business_id)
    WHERE deleted_at IS NULL AND job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_review_requests_customer
    ON review_requests(customer_id, business_id)
    WHERE deleted_at IS NULL AND customer_id IS NOT NULL;

-- Status transition guard. The directed flow:
--
--   sent ──┬─→ opened ──┬─→ responded
--          │            └─→ declined
--          ├─→ declined
--          └─→ expired
--
-- Once responded/declined/expired, the row is terminal; reopening
-- requires a new review_request row.
CREATE OR REPLACE FUNCTION review_request_status_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF (OLD.status, NEW.status) NOT IN (
        ('sent','opened'),
        ('sent','declined'),
        ('sent','expired'),
        ('opened','responded'),
        ('opened','declined'),
        ('opened','expired')
    ) THEN
        RAISE EXCEPTION 'invalid_status_transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_review_request_status_guard ON review_requests;
CREATE TRIGGER trg_review_request_status_guard
    BEFORE UPDATE ON review_requests
    FOR EACH ROW EXECUTE FUNCTION review_request_status_guard();

ALTER TABLE review_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS review_requests_tenant_isolation ON review_requests;
CREATE POLICY review_requests_tenant_isolation ON review_requests
    USING (business_id::text = current_setting('app.business_id', true));

-- ── Permission keys (spec §Core Permissions: reviews.request) ───
INSERT INTO permissions (key, description, category) VALUES
    ('reviews.request', 'Send post-job review requests',          'reviews'),
    ('reviews.view',    'View review requests and feedback',      'reviews'),
    ('reviews.manage',  'Update / cancel / resend review requests','reviews'),
    ('reviews.export',  'Export review request data to CSV',      'reviews')
ON CONFLICT (key) DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
WHERE key IN ('reviews.request','reviews.view','reviews.manage','reviews.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key IN ('reviews.request','reviews.view','reviews.manage','reviews.export')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN ('reviews.request','reviews.view','reviews.manage')
ON CONFLICT DO NOTHING;

-- Workers can request reviews for jobs they completed and view
-- responses; the handler scopes to assigned jobs.
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN ('reviews.request','reviews.view')
ON CONFLICT DO NOTHING;
