-- ============================================================
-- Migration 001: Core schema — users, businesses, auth, multi-tenant
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Enums ────────────────────────────────────────────────────
CREATE TYPE user_role AS ENUM ('owner', 'admin', 'worker', 'accountant', 'customer', 'platform_admin');
CREATE TYPE subscription_status AS ENUM ('trialing', 'active', 'past_due', 'canceled', 'paused');
CREATE TYPE job_status AS ENUM ('draft', 'scheduled', 'in_progress', 'on_hold', 'completed', 'cancelled', 'invoiced');
CREATE TYPE quote_status AS ENUM ('draft', 'sent', 'viewed', 'approved', 'rejected', 'expired', 'converted');
CREATE TYPE invoice_status AS ENUM ('draft', 'sent', 'viewed', 'partial', 'paid', 'overdue', 'cancelled', 'refunded');
CREATE TYPE payment_method AS ENUM ('stripe', 'bank_transfer', 'cash', 'cheque', 'other');
CREATE TYPE notification_channel AS ENUM ('email', 'sms', 'push', 'in_app');
CREATE TYPE leave_status AS ENUM ('pending', 'approved', 'rejected', 'cancelled');
CREATE TYPE incident_severity AS ENUM ('low', 'medium', 'high', 'critical');

-- ── Businesses (tenants) ─────────────────────────────────────
CREATE TABLE businesses (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            TEXT NOT NULL,
    slug            TEXT UNIQUE NOT NULL,
    abn             TEXT,
    acn             TEXT,
    phone           TEXT,
    email           TEXT,
    website         TEXT,
    address_line1   TEXT,
    address_line2   TEXT,
    city            TEXT,
    state           TEXT,
    postcode        TEXT,
    country         TEXT DEFAULT 'AU',
    timezone        TEXT DEFAULT 'Australia/Sydney',
    logo_url        TEXT,
    is_active       BOOLEAN DEFAULT TRUE,
    trial_ends_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Users ────────────────────────────────────────────────────
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    email           TEXT NOT NULL,
    phone           TEXT,
    first_name      TEXT NOT NULL,
    last_name       TEXT NOT NULL,
    role            user_role NOT NULL DEFAULT 'worker',
    password_hash   TEXT,
    avatar_url      TEXT,
    is_active       BOOLEAN DEFAULT TRUE,
    is_verified     BOOLEAN DEFAULT FALSE,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,
    UNIQUE(business_id, email)
);
CREATE INDEX idx_users_business_id ON users(business_id);
CREATE INDEX idx_users_email ON users(email) WHERE deleted_at IS NULL;

-- ── Employee profiles ─────────────────────────────────────────
CREATE TABLE employee_profiles (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    employee_number     TEXT,
    title               TEXT,
    department          TEXT,
    hourly_rate         NUMERIC(10,2),
    tax_file_number     TEXT,
    super_fund_name     TEXT,
    super_fund_usi      TEXT,
    super_member_number TEXT,
    bank_bsb            TEXT,
    bank_account        TEXT,
    bank_name           TEXT,
    emergency_contact   JSONB,
    skills              TEXT[],
    licence_types       TEXT[],
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- ── Auth ─────────────────────────────────────────────────────
CREATE TABLE refresh_tokens (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  TEXT NOT NULL UNIQUE,
    device_info JSONB,
    ip_address  INET,
    expires_at  TIMESTAMPTZ NOT NULL,
    revoked_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_refresh_tokens_user ON refresh_tokens(user_id);

CREATE TABLE login_attempts (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email       TEXT NOT NULL,
    ip_address  INET,
    success     BOOLEAN NOT NULL,
    risk_score  INT DEFAULT 0,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_login_attempts_email ON login_attempts(email, created_at DESC);

CREATE TABLE login_sessions (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_info JSONB,
    ip_address  INET,
    user_agent  TEXT,
    location    TEXT,
    is_current  BOOLEAN DEFAULT FALSE,
    last_seen   TIMESTAMPTZ DEFAULT NOW(),
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE mfa_secrets (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE UNIQUE,
    secret      TEXT NOT NULL,
    backup_codes TEXT[],
    enabled     BOOLEAN DEFAULT FALSE,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE mfa_challenges (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash   TEXT NOT NULL,
    method      TEXT NOT NULL DEFAULT 'totp',
    expires_at  TIMESTAMPTZ NOT NULL,
    used        BOOLEAN DEFAULT FALSE,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE passkeys (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credential_id   BYTEA NOT NULL UNIQUE,
    public_key      BYTEA NOT NULL,
    aaguid          BYTEA,
    sign_count      BIGINT DEFAULT 0,
    name            TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    last_used_at    TIMESTAMPTZ
);

CREATE TABLE passkey_challenges (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
    challenge   BYTEA NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE password_reset_tokens (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  TEXT NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE registration_tokens (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email       TEXT NOT NULL,
    token_hash  TEXT NOT NULL UNIQUE,
    business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
    role        user_role DEFAULT 'worker',
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE team_invites (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    invited_by  UUID NOT NULL REFERENCES users(id),
    email       TEXT NOT NULL,
    role        user_role NOT NULL DEFAULT 'worker',
    token_hash  TEXT NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    accepted_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ── Business settings ──────────────────────────────────────
CREATE TABLE business_profiles (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    trading_name    TEXT,
    industry_type   TEXT,
    description     TEXT,
    licence_number  TEXT,
    insurance_policy TEXT,
    insurance_expiry DATE,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE business_settings (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    date_format     TEXT DEFAULT 'DD/MM/YYYY',
    currency        TEXT DEFAULT 'AUD',
    language        TEXT DEFAULT 'en-AU',
    default_job_duration_minutes INT DEFAULT 60,
    auto_send_reminders BOOLEAN DEFAULT TRUE,
    settings_json   JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE business_tax_settings (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    gst_registered  BOOLEAN DEFAULT TRUE,
    gst_rate        NUMERIC(5,2) DEFAULT 10.00,
    fiscal_year_end TEXT DEFAULT 'June',
    bas_frequency   TEXT DEFAULT 'quarterly',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE business_invoice_settings (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    invoice_prefix      TEXT DEFAULT 'INV',
    quote_prefix        TEXT DEFAULT 'QT',
    next_invoice_number INT DEFAULT 1001,
    next_quote_number   INT DEFAULT 1001,
    payment_terms_days  INT DEFAULT 14,
    default_notes       TEXT,
    default_footer      TEXT,
    bank_bsb            TEXT,
    bank_account        TEXT,
    bank_name           TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE business_payroll_settings (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    payroll_frequency   TEXT DEFAULT 'fortnightly',
    pay_day             INT DEFAULT 5,
    super_rate          NUMERIC(5,2) DEFAULT 11.00,
    default_work_hours  NUMERIC(5,2) DEFAULT 38.00,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE business_branding_settings (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    primary_color   TEXT DEFAULT '#1E40AF',
    secondary_color TEXT DEFAULT '#F97316',
    font_family     TEXT DEFAULT 'Inter',
    logo_url        TEXT,
    favicon_url     TEXT,
    email_header    TEXT,
    email_footer    TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE business_compliance_details (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    worksafe_licence    TEXT,
    worksafe_expiry     DATE,
    public_liability    TEXT,
    public_liability_expiry DATE,
    workers_comp        TEXT,
    workers_comp_expiry DATE,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE business_payment_details (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    stripe_customer_id      TEXT,
    stripe_payment_method   TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE business_accountant_details (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    firm_name       TEXT,
    contact_name    TEXT,
    email           TEXT,
    phone           TEXT,
    xero_tenant_id  TEXT,
    myob_company_id TEXT,
    qbo_realm_id    TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Subscriptions ─────────────────────────────────────────────
CREATE TABLE plans (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            TEXT NOT NULL,
    slug            TEXT NOT NULL UNIQUE,
    stripe_price_id TEXT,
    price_monthly   NUMERIC(10,2),
    price_yearly    NUMERIC(10,2),
    max_workers     INT DEFAULT 5,
    max_jobs_month  INT DEFAULT 100,
    max_storage_gb  NUMERIC(8,2) DEFAULT 5.0,
    features        JSONB DEFAULT '{}',
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE subscriptions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    plan_id             UUID NOT NULL REFERENCES plans(id),
    stripe_subscription_id TEXT,
    status              subscription_status NOT NULL DEFAULT 'trialing',
    current_period_start TIMESTAMPTZ,
    current_period_end   TIMESTAMPTZ,
    cancel_at_period_end BOOLEAN DEFAULT FALSE,
    canceled_at         TIMESTAMPTZ,
    trial_ends_at       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE plan_features (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    plan_id     UUID NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    feature_key TEXT NOT NULL,
    value       JSONB,
    UNIQUE(plan_id, feature_key)
);

CREATE TABLE usage_counters (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    metric      TEXT NOT NULL,
    period      TEXT NOT NULL,
    count       BIGINT DEFAULT 0,
    updated_at  TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(business_id, metric, period)
);

CREATE TABLE billing_events (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    event_type  TEXT NOT NULL,
    amount      NUMERIC(10,2),
    currency    TEXT DEFAULT 'AUD',
    stripe_event_id TEXT,
    metadata    JSONB,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ── Permissions ───────────────────────────────────────────────
CREATE TABLE user_preferences (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE UNIQUE,
    theme       TEXT DEFAULT 'light',
    language    TEXT DEFAULT 'en-AU',
    timezone    TEXT DEFAULT 'Australia/Sydney',
    preferences JSONB DEFAULT '{}',
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE security_settings (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    require_2fa         BOOLEAN DEFAULT FALSE,
    session_timeout_min INT DEFAULT 480,
    allowed_ips         INET[],
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE security_audit_logs (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID REFERENCES users(id),
    action      TEXT NOT NULL,
    resource    TEXT,
    resource_id UUID,
    ip_address  INET,
    user_agent  TEXT,
    metadata    JSONB,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_security_audit_business ON security_audit_logs(business_id, created_at DESC);

-- ── Audit logs ────────────────────────────────────────────────
CREATE TABLE audit_logs (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID REFERENCES users(id),
    action      TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id   UUID,
    old_data    JSONB,
    new_data    JSONB,
    ip_address  INET,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_audit_logs_business ON audit_logs(business_id, created_at DESC);
CREATE INDEX idx_audit_logs_entity ON audit_logs(entity_type, entity_id);

-- ── Notifications ─────────────────────────────────────────────
CREATE TABLE notifications (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID REFERENCES users(id) ON DELETE SET NULL,
    type        TEXT NOT NULL,
    title       TEXT NOT NULL,
    body        TEXT,
    data        JSONB,
    read_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_notifications_user ON notifications(user_id, created_at DESC);

CREATE TABLE notification_preferences (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    settings    JSONB DEFAULT '{}',
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE user_notification_preferences (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE UNIQUE,
    email       BOOLEAN DEFAULT TRUE,
    sms         BOOLEAN DEFAULT TRUE,
    push        BOOLEAN DEFAULT TRUE,
    in_app      BOOLEAN DEFAULT TRUE,
    preferences JSONB DEFAULT '{}',
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE notification_templates (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,
    type        TEXT NOT NULL,
    channel     notification_channel NOT NULL,
    subject     TEXT,
    body        TEXT NOT NULL,
    variables   TEXT[],
    is_default  BOOLEAN DEFAULT FALSE,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE notification_delivery_logs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    notification_id UUID REFERENCES notifications(id),
    channel         notification_channel NOT NULL,
    recipient       TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    provider_id     TEXT,
    error           TEXT,
    sent_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Settings ──────────────────────────────────────────────────
CREATE TABLE job_settings (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    default_duration_minutes INT DEFAULT 60,
    require_sign_off BOOLEAN DEFAULT TRUE,
    require_photos  BOOLEAN DEFAULT FALSE,
    allow_worker_notes BOOLEAN DEFAULT TRUE,
    settings_json   JSONB DEFAULT '{}',
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE scheduling_settings (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    work_days       INT[] DEFAULT '{1,2,3,4,5}',
    work_start      TIME DEFAULT '08:00',
    work_end        TIME DEFAULT '17:00',
    slot_minutes    INT DEFAULT 30,
    buffer_minutes  INT DEFAULT 15,
    settings_json   JSONB DEFAULT '{}',
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE file_settings (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    max_file_size_mb INT DEFAULT 10,
    allowed_types   TEXT[] DEFAULT '{image/jpeg,image/png,application/pdf}',
    retention_days  INT DEFAULT 2555,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE files (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    uploaded_by UUID REFERENCES users(id),
    entity_type TEXT,
    entity_id   UUID,
    name        TEXT NOT NULL,
    mime_type   TEXT,
    size_bytes  BIGINT,
    s3_key      TEXT NOT NULL,
    url         TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ
);
CREATE INDEX idx_files_entity ON files(entity_type, entity_id) WHERE deleted_at IS NULL;

-- Default seed plans
INSERT INTO plans (name, slug, price_monthly, price_yearly, max_workers, max_jobs_month, max_storage_gb, features) VALUES
('Starter',    'starter',    49.00,  490.00,  3,   50,  2.0,  '{"reports":false,"integrations":false,"ai":false}'),
('Pro',        'pro',        99.00,  990.00,  10,  500, 20.0, '{"reports":true,"integrations":true,"ai":false}'),
('Enterprise', 'enterprise', 199.00, 1990.00, 999, 9999, 100.0, '{"reports":true,"integrations":true,"ai":true,"white_label":true}');
