-- Add columns needed for Stripe Checkout invoice payments.
--
-- created_by was already referenced by the CreatePaymentLink handler
-- but never actually added to the table — fixing here.
-- stripe_session_id stores the Stripe Checkout Session ID so the
-- webhook can reconcile a paid checkout back to its invoice without
-- relying solely on metadata.

ALTER TABLE payment_links
    ADD COLUMN IF NOT EXISTS created_by         UUID REFERENCES users(id),
    ADD COLUMN IF NOT EXISTS stripe_session_id  TEXT;

CREATE INDEX IF NOT EXISTS idx_payment_links_stripe_session
    ON payment_links(stripe_session_id)
    WHERE stripe_session_id IS NOT NULL;
