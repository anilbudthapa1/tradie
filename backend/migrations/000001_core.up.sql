-- ── Extensions ────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ── Businesses ─────────────────────────────────────────────────
CREATE TABLE businesses (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name          TEXT NOT NULL,
    slug          TEXT NOT NULL UNIQUE,
    abn           TEXT,
    phone         TEXT,
    email         TEXT,
    address_line1 TEXT,
    city          TEXT,
    state         TEXT,
    postcode      TEXT,
    country       TEXT NOT NULL DEFAULT 'AU',
    timezone      TEXT NOT NULL DEFAULT 'Australia/Sydney',
    logo_url      TEXT,
    is_active     BOOLEAN NOT NULL DEFAULT true,
    trial_ends_at TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Users ──────────────────────────────────────────────────────
CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id   UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    email         TEXT NOT NULL,
    password_hash TEXT,
    first_name    TEXT NOT NULL,
    last_name     TEXT NOT NULL DEFAULT '',
    role          TEXT NOT NULL DEFAULT 'worker'
                  CHECK (role IN ('owner','admin','manager','worker','accountant','customer')),
    phone         TEXT,
    avatar_url    TEXT,
    is_active     BOOLEAN NOT NULL DEFAULT true,
    is_verified   BOOLEAN NOT NULL DEFAULT false,
    mfa_enabled   BOOLEAN NOT NULL DEFAULT false,
    mfa_secret    TEXT,
    invited_at    TIMESTAMPTZ,
    last_login_at TIMESTAMPTZ,
    deleted_at    TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (email, business_id)
);

-- ── Refresh tokens ─────────────────────────────────────────────
CREATE TABLE refresh_tokens (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── MFA backup codes ───────────────────────────────────────────
CREATE TABLE mfa_backup_codes (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash  TEXT NOT NULL,
    used_at    TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Password reset tokens ──────────────────────────────────────
CREATE TABLE password_reset_tokens (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at    TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Email verification tokens ──────────────────────────────────
CREATE TABLE email_verify_tokens (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at    TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Sessions ───────────────────────────────────────────────────
CREATE TABLE sessions (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    business_id    UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    token_hash     TEXT NOT NULL UNIQUE,
    ip_address     TEXT,
    user_agent     TEXT,
    device_info    TEXT,
    location       TEXT,
    last_active_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Invitations ────────────────────────────────────────────────
CREATE TABLE invitations (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    email       TEXT NOT NULL,
    role        TEXT NOT NULL DEFAULT 'worker',
    token_hash  TEXT NOT NULL UNIQUE,
    invited_by  UUID REFERENCES users(id),
    accepted_at TIMESTAMPTZ,
    expires_at  TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '7 days',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Audit logs ─────────────────────────────────────────────────
CREATE TABLE audit_logs (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID REFERENCES users(id) ON DELETE SET NULL,
    action      TEXT NOT NULL,
    entity_type TEXT,
    entity_id   TEXT,
    old_values  JSONB,
    new_values  JSONB,
    ip_address  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Subscriptions ──────────────────────────────────────────────
CREATE TABLE subscriptions (
    id                     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id            UUID NOT NULL UNIQUE REFERENCES businesses(id) ON DELETE CASCADE,
    plan_slug              TEXT NOT NULL DEFAULT 'starter'
                           CHECK (plan_slug IN ('starter','pro','enterprise')),
    status                 TEXT NOT NULL DEFAULT 'trialing'
                           CHECK (status IN ('trialing','active','past_due','canceled','incomplete')),
    stripe_subscription_id TEXT UNIQUE,
    stripe_customer_id     TEXT UNIQUE,
    current_period_start   TIMESTAMPTZ,
    current_period_end     TIMESTAMPTZ,
    trial_ends_at          TIMESTAMPTZ,
    cancel_at_period_end   BOOLEAN NOT NULL DEFAULT false,
    max_workers            INT NOT NULL DEFAULT 5,
    max_jobs_month         INT NOT NULL DEFAULT 100,
    max_storage_gb         FLOAT NOT NULL DEFAULT 5,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── API keys ───────────────────────────────────────────────────
CREATE TABLE api_keys (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    key_hash    TEXT NOT NULL UNIQUE,
    key_prefix  TEXT NOT NULL,
    scopes      JSONB NOT NULL DEFAULT '[]',
    last_used_at TIMESTAMPTZ,
    created_by  UUID REFERENCES users(id),
    revoked_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Business settings ──────────────────────────────────────────
CREATE TABLE business_invoice_settings (
    business_id         UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    next_invoice_number INT NOT NULL DEFAULT 1001,
    next_quote_number   INT NOT NULL DEFAULT 1001,
    payment_terms       INT NOT NULL DEFAULT 14,
    footer_text         TEXT,
    bank_name           TEXT,
    bank_bsb            TEXT,
    bank_account        TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE security_settings (
    business_id              UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    mfa_required             BOOLEAN NOT NULL DEFAULT false,
    session_timeout_minutes  INT NOT NULL DEFAULT 480,
    ip_whitelist             JSONB NOT NULL DEFAULT '[]',
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE scheduling_settings (
    business_id           UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    work_start_time       TIME NOT NULL DEFAULT '07:00',
    work_end_time         TIME NOT NULL DEFAULT '18:00',
    slot_duration_minutes INT NOT NULL DEFAULT 30,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE job_settings (
    business_id       UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    require_sign_off  BOOLEAN NOT NULL DEFAULT false,
    require_photos    BOOLEAN NOT NULL DEFAULT false,
    require_materials BOOLEAN NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Indexes ────────────────────────────────────────────────────
CREATE INDEX idx_users_business_id ON users(business_id);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_deleted_at ON users(deleted_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_refresh_tokens_user_id ON refresh_tokens(user_id);
CREATE INDEX idx_sessions_user_id ON sessions(user_id);
CREATE INDEX idx_sessions_business_id ON sessions(business_id);
CREATE INDEX idx_audit_logs_business_id ON audit_logs(business_id);
CREATE INDEX idx_audit_logs_created_at ON audit_logs(created_at DESC);
CREATE INDEX idx_api_keys_business_id ON api_keys(business_id);
