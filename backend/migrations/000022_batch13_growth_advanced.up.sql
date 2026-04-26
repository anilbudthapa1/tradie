-- ── Batch 13: Growth, Mobile & Advanced (M122/M123/M125/M126/M127/M128) ──

-- ── M125: AI conversation logs (audit trail + context for assistant) ──
CREATE TABLE IF NOT EXISTS ai_conversation_logs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL,
    role            TEXT NOT NULL CHECK (role IN ('user','assistant')),
    content         TEXT NOT NULL,
    tokens_used     INT NOT NULL DEFAULT 0,
    model           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ai_conv_logs_biz ON ai_conversation_logs(business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_conv_logs_conv ON ai_conversation_logs(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_ai_conv_logs_user ON ai_conversation_logs(user_id, created_at DESC);

-- ── M126: Voice notes ──
CREATE TABLE IF NOT EXISTS voice_notes (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id          UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id               UUID REFERENCES jobs(id) ON DELETE SET NULL,
    user_id              UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    file_id              UUID REFERENCES files(id) ON DELETE SET NULL,
    duration_seconds     INT NOT NULL DEFAULT 0,
    transcript           TEXT,
    transcription_status TEXT NOT NULL DEFAULT 'pending'
                         CHECK (transcription_status IN ('pending','processing','completed','error')),
    error_message        TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_voice_notes_biz ON voice_notes(business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_voice_notes_job ON voice_notes(job_id) WHERE job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_voice_notes_user ON voice_notes(user_id);

-- ── M128: Franchise / multi-branch ──
ALTER TABLE businesses
    ADD COLUMN IF NOT EXISTS parent_business_id UUID REFERENCES businesses(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS is_franchise_parent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS idx_businesses_parent ON businesses(parent_business_id) WHERE parent_business_id IS NOT NULL;

-- ── M122: White-label branding extensions ──
-- business_branding_settings is created by an earlier migration (Phase A 000008).
-- These columns are additive only and idempotent.
ALTER TABLE business_branding_settings
    ADD COLUMN IF NOT EXISTS custom_domain    TEXT,
    ADD COLUMN IF NOT EXISTS footer_text      TEXT,
    ADD COLUMN IF NOT EXISTS email_from_name  TEXT,
    ADD COLUMN IF NOT EXISTS hide_powered_by  BOOLEAN NOT NULL DEFAULT FALSE;
CREATE UNIQUE INDEX IF NOT EXISTS idx_branding_custom_domain
    ON business_branding_settings(custom_domain)
    WHERE custom_domain IS NOT NULL;

-- ── M123: Referral program ──
CREATE TABLE IF NOT EXISTS referrals (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id       UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    referrer_user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    referee_email     TEXT NOT NULL,
    referral_code     TEXT NOT NULL UNIQUE,
    status            TEXT NOT NULL DEFAULT 'sent'
                      CHECK (status IN ('sent','signed_up','converted')),
    reward_amount     NUMERIC(12,2) NOT NULL DEFAULT 0,
    reward_paid_at    TIMESTAMPTZ,
    converted_at      TIMESTAMPTZ,
    notes             TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_referrals_biz ON referrals(business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_referrals_referrer ON referrals(referrer_user_id);
CREATE INDEX IF NOT EXISTS idx_referrals_status ON referrals(business_id, status);

-- ── M127: Multi-language i18n strings ──
CREATE TABLE IF NOT EXISTS translation_strings (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    namespace   TEXT NOT NULL DEFAULT 'common',
    key         TEXT NOT NULL,
    language    TEXT NOT NULL CHECK (language IN ('en','en-AU','zh','vi','ar')),
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (namespace, key, language)
);
CREATE INDEX IF NOT EXISTS idx_translation_lang ON translation_strings(language);

-- Seed: minimal English fallback set so /api/v1/i18n/en returns something usable.
INSERT INTO translation_strings (namespace, key, language, value) VALUES
    ('common', 'app.name',         'en', 'Tradie Job Manager'),
    ('common', 'action.save',      'en', 'Save'),
    ('common', 'action.cancel',    'en', 'Cancel'),
    ('common', 'action.delete',    'en', 'Delete'),
    ('common', 'action.edit',      'en', 'Edit'),
    ('common', 'nav.dashboard',    'en', 'Dashboard'),
    ('common', 'nav.jobs',         'en', 'Jobs'),
    ('common', 'nav.invoices',     'en', 'Invoices'),
    ('common', 'nav.customers',    'en', 'Customers'),
    ('common', 'nav.workers',      'en', 'Workers'),
    ('common', 'status.paid',      'en', 'Paid'),
    ('common', 'status.overdue',   'en', 'Overdue'),
    ('common', 'status.pending',   'en', 'Pending')
ON CONFLICT (namespace, key, language) DO NOTHING;
