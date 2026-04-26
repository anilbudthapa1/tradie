DROP INDEX IF EXISTS idx_payment_links_stripe_session;

ALTER TABLE payment_links
    DROP COLUMN IF EXISTS stripe_session_id,
    DROP COLUMN IF EXISTS created_by;
