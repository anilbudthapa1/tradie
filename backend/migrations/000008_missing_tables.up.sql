-- Auto-generated: tables/indexes from internal/db/migrations not present in primary set
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

DO $$ BEGIN CREATE TYPE user_role AS ENUM ('owner','admin','worker','accountant','customer','platform_admin'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE job_status AS ENUM ('draft','scheduled','in_progress','on_hold','completed','cancelled','invoiced'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE payment_method AS ENUM ('stripe','bank_transfer','cash','cheque','other'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE notification_channel AS ENUM ('email','sms','push','in_app'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

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

CREATE TABLE login_attempts (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email       TEXT NOT NULL,
    ip_address  INET,
    success     BOOLEAN NOT NULL,
    risk_score  INT DEFAULT 0,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

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

CREATE TABLE user_preferences (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE UNIQUE,
    theme       TEXT DEFAULT 'light',
    language    TEXT DEFAULT 'en-AU',
    timezone    TEXT DEFAULT 'Australia/Sydney',
    preferences JSONB DEFAULT '{}',
    updated_at  TIMESTAMPTZ DEFAULT NOW()
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

CREATE TABLE file_settings (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE UNIQUE,
    max_file_size_mb INT DEFAULT 10,
    allowed_types   TEXT[] DEFAULT '{image/jpeg,image/png,application/pdf}',
    retention_days  INT DEFAULT 2555,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE job_status_history (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id      UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    from_status job_status,
    to_status   job_status NOT NULL,
    changed_by  UUID REFERENCES users(id),
    note        TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE payments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    invoice_id      UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    amount          NUMERIC(10,2) NOT NULL,
    method          payment_method NOT NULL,
    reference       TEXT,
    notes           TEXT,
    stripe_charge_id TEXT,
    received_at     TIMESTAMPTZ DEFAULT NOW(),
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE check_ins (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    job_id      UUID REFERENCES jobs(id),
    type        TEXT NOT NULL DEFAULT 'check_in',
    lat         DOUBLE PRECISION,
    lng         DOUBLE PRECISION,
    address     TEXT,
    device_info JSONB,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE availability (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day_of_week INT,
    date        DATE,
    start_time  TIME,
    end_time    TIME,
    is_available BOOLEAN DEFAULT TRUE,
    notes       TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE super_contributions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    payslip_id      UUID NOT NULL REFERENCES payslips(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id),
    fund_name       TEXT,
    fund_usi        TEXT,
    member_number   TEXT,
    amount          NUMERIC(10,2) NOT NULL,
    quarter         TEXT,
    status          TEXT DEFAULT 'pending',
    paid_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE performance_reviews (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id),
    reviewed_by     UUID REFERENCES users(id),
    period_start    DATE,
    period_end      DATE,
    rating          INT CHECK (rating BETWEEN 1 AND 5),
    notes           TEXT,
    goals           JSONB DEFAULT '[]',
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE ppe_records (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id          UUID REFERENCES jobs(id),
    user_id         UUID REFERENCES users(id),
    items           JSONB NOT NULL DEFAULT '[]',
    checked_at      TIMESTAMPTZ DEFAULT NOW(),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE compliance_documents (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id),
    type            TEXT NOT NULL,
    number          TEXT,
    issuer          TEXT,
    issued_date     DATE,
    expiry_date     DATE,
    file_id         UUID REFERENCES files(id),
    reminder_days   INT DEFAULT 30,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE integration_tokens (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    provider        TEXT NOT NULL,
    access_token    TEXT,
    refresh_token   TEXT,
    token_expiry    TIMESTAMPTZ,
    metadata        JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(business_id, provider)
);

CREATE INDEX idx_login_attempts_email ON login_attempts(email, created_at DESC);
CREATE INDEX idx_security_audit_business ON security_audit_logs(business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notif_templates_biz ON notification_templates(business_id);
CREATE INDEX IF NOT EXISTS idx_delivery_logs_biz ON notification_delivery_logs(business_id, created_at DESC);
