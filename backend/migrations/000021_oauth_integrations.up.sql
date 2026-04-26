-- Batch 12 / Agent 12 — OAuth integrations (Xero, MYOB, QuickBooks, Google Calendar)
--
-- The legacy `integration_tokens` table is created in
-- backend/internal/db/migrations/003_payroll_safety.sql for older deployments.
-- This migration ensures the same shape exists in fresh `migrations/` deployments
-- and adds an `oauth_state` table for CSRF protection across the OAuth dance.

CREATE TABLE IF NOT EXISTS integration_tokens (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    provider        TEXT NOT NULL,
    access_token    TEXT,
    refresh_token   TEXT,
    token_expiry    TIMESTAMPTZ,
    metadata        JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (business_id, provider)
);

CREATE INDEX IF NOT EXISTS idx_integration_tokens_business ON integration_tokens(business_id);

-- Short-lived state token for CSRF / replay protection during the OAuth redirect.
CREATE TABLE IF NOT EXISTS oauth_state (
    state           TEXT PRIMARY KEY,
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider        TEXT NOT NULL,
    redirect_uri    TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '10 minutes')
);

CREATE INDEX IF NOT EXISTS idx_oauth_state_expires ON oauth_state(expires_at);
