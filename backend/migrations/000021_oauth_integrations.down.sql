DROP TABLE IF EXISTS oauth_state;
-- integration_tokens is shared with legacy migrations; only drop if it was created by this migration.
-- For safety we leave integration_tokens in place on rollback.
