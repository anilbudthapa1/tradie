-- ============================================================
-- Migration 004: API Keys, Billing columns, Manager role
-- ============================================================

-- ── Stripe customer on businesses ────────────────────────────
ALTER TABLE businesses ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT;

-- ── Manager role (add to enum if not exists) ─────────────────
DO $$ BEGIN
  ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'manager';
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── API Keys ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS api_keys (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by      UUID REFERENCES users(id),
    name            TEXT NOT NULL,
    key_hash        TEXT NOT NULL UNIQUE,
    key_prefix      TEXT NOT NULL,
    scopes          TEXT[] DEFAULT '{}',
    last_used_at    TIMESTAMPTZ,
    revoked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_api_keys_business ON api_keys(business_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(key_hash);

-- ── Business Settings ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS business_settings (
    business_id                 UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    date_format                 TEXT DEFAULT 'DD/MM/YYYY',
    currency                    TEXT DEFAULT 'AUD',
    language                    TEXT DEFAULT 'en',
    default_job_duration_minutes INT DEFAULT 60,
    auto_send_reminders         BOOLEAN DEFAULT TRUE,
    updated_at                  TIMESTAMPTZ DEFAULT NOW()
);

-- ── Security Settings ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS security_settings (
    business_id         UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    require_2fa         BOOLEAN DEFAULT FALSE,
    session_timeout_min INT DEFAULT 480,
    allowed_ips         TEXT[] DEFAULT '{}',
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- ── Scheduling Settings ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS scheduling_settings (
    business_id     UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    work_days       INT[] DEFAULT '{1,2,3,4,5}',
    work_start      TIME DEFAULT '08:00',
    work_end        TIME DEFAULT '17:00',
    slot_minutes    INT DEFAULT 30,
    buffer_minutes  INT DEFAULT 15,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Job Settings ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS job_settings (
    business_id             UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    default_duration_minutes INT DEFAULT 60,
    require_sign_off        BOOLEAN DEFAULT FALSE,
    require_photos          BOOLEAN DEFAULT FALSE,
    allow_worker_notes      BOOLEAN DEFAULT TRUE,
    updated_at              TIMESTAMPTZ DEFAULT NOW()
);

-- ── Notification Templates ────────────────────────────────────
CREATE TABLE IF NOT EXISTS notification_templates (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID REFERENCES businesses(id) ON DELETE CASCADE,
    type            TEXT NOT NULL,
    channel         TEXT NOT NULL,
    subject         TEXT,
    body            TEXT NOT NULL,
    variables       TEXT[] DEFAULT '{}',
    is_default      BOOLEAN DEFAULT FALSE,
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (business_id, type, channel)
);
CREATE INDEX IF NOT EXISTS idx_notif_templates_biz ON notification_templates(business_id);

-- ── Notification Delivery Logs ────────────────────────────────
CREATE TABLE IF NOT EXISTS notification_delivery_logs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    notification_id UUID REFERENCES notifications(id),
    channel         TEXT NOT NULL,
    recipient       TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'sent',
    provider_id     TEXT,
    error           TEXT,
    sent_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_delivery_logs_biz ON notification_delivery_logs(business_id, created_at DESC);

-- ── User Notification Preferences ────────────────────────────
CREATE TABLE IF NOT EXISTS user_notification_preferences (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    email           BOOLEAN DEFAULT TRUE,
    sms             BOOLEAN DEFAULT TRUE,
    push            BOOLEAN DEFAULT TRUE,
    in_app          BOOLEAN DEFAULT TRUE,
    preferences     JSONB DEFAULT '{}',
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Business Notification Preferences ────────────────────────
CREATE TABLE IF NOT EXISTS notification_preferences (
    business_id     UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    settings        JSONB DEFAULT '{}',
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Business Profile ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS business_profiles (
    business_id     UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    description     TEXT,
    industry        TEXT,
    employee_count  INT,
    founded_year    INT,
    facebook_url    TEXT,
    instagram_url   TEXT,
    linkedin_url    TEXT,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS business_tax_settings (
    business_id     UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    gst_registered  BOOLEAN DEFAULT FALSE,
    gst_rate        NUMERIC(5,4) DEFAULT 0.10,
    tax_year_end    TEXT DEFAULT '06-30',
    bas_frequency   TEXT DEFAULT 'quarterly',
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS business_invoice_settings (
    business_id         UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    payment_terms_days  INT DEFAULT 14,
    invoice_prefix      TEXT DEFAULT 'INV',
    quote_prefix        TEXT DEFAULT 'QTE',
    next_invoice_number INT DEFAULT 1,
    next_quote_number   INT DEFAULT 1,
    default_notes       TEXT,
    default_footer      TEXT,
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS business_payroll_settings (
    business_id         UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    pay_frequency       TEXT DEFAULT 'fortnightly',
    pay_day             INT DEFAULT 5,
    super_rate          NUMERIC(5,4) DEFAULT 0.11,
    overtime_threshold  NUMERIC(5,2) DEFAULT 38.0,
    overtime_multiplier NUMERIC(4,2) DEFAULT 1.5,
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS business_branding_settings (
    business_id     UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    primary_color   TEXT DEFAULT '#1E40AF',
    secondary_color TEXT DEFAULT '#F97316',
    logo_url        TEXT,
    email_header    TEXT,
    email_footer    TEXT,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS business_compliance_details (
    business_id         UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    licence_number      TEXT,
    licence_expiry      DATE,
    insurance_provider  TEXT,
    insurance_policy    TEXT,
    insurance_expiry    DATE,
    worksafe_number     TEXT,
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- ── Seed default settings on business creation ────────────────
-- (handled by INSERT ... ON CONFLICT in application code, but also here for existing rows)
INSERT INTO business_settings (business_id)
    SELECT id FROM businesses WHERE TRUE
    ON CONFLICT (business_id) DO NOTHING;

INSERT INTO security_settings (business_id)
    SELECT id FROM businesses WHERE TRUE
    ON CONFLICT (business_id) DO NOTHING;

INSERT INTO scheduling_settings (business_id)
    SELECT id FROM businesses WHERE TRUE
    ON CONFLICT (business_id) DO NOTHING;

INSERT INTO job_settings (business_id)
    SELECT id FROM businesses WHERE TRUE
    ON CONFLICT (business_id) DO NOTHING;

INSERT INTO notification_preferences (business_id)
    SELECT id FROM businesses WHERE TRUE
    ON CONFLICT (business_id) DO NOTHING;
