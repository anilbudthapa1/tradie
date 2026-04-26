-- ── Reverse Batch 13 ──
DROP TABLE IF EXISTS translation_strings;
DROP TABLE IF EXISTS referrals;

ALTER TABLE business_branding_settings
    DROP COLUMN IF EXISTS hide_powered_by,
    DROP COLUMN IF EXISTS email_from_name,
    DROP COLUMN IF EXISTS footer_text,
    DROP COLUMN IF EXISTS custom_domain;
DROP INDEX IF EXISTS idx_branding_custom_domain;

ALTER TABLE businesses
    DROP COLUMN IF EXISTS is_franchise_parent,
    DROP COLUMN IF EXISTS parent_business_id;

DROP TABLE IF EXISTS voice_notes;
DROP TABLE IF EXISTS ai_conversation_logs;
