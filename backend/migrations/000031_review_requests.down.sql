DELETE FROM role_permissions
USING permissions
WHERE role_permissions.permission_id = permissions.id
  AND permissions.key IN ('reviews.request','reviews.view','reviews.manage','reviews.export');

DELETE FROM permissions WHERE key IN ('reviews.request','reviews.view','reviews.manage','reviews.export');

DROP TRIGGER  IF EXISTS trg_review_request_status_guard ON review_requests;
DROP FUNCTION IF EXISTS review_request_status_guard();

DROP INDEX IF EXISTS uq_review_requests_token;
DROP INDEX IF EXISTS idx_review_requests_business_status;
DROP INDEX IF EXISTS idx_review_requests_job;
DROP INDEX IF EXISTS idx_review_requests_customer;

ALTER TABLE review_requests DROP CONSTRAINT IF EXISTS review_requests_status_check;
ALTER TABLE review_requests DROP CONSTRAINT IF EXISTS review_requests_channel_check;

ALTER TABLE review_requests
    ADD CONSTRAINT review_requests_status_check
    CHECK (status IN ('sent','opened','responded','declined'));

ALTER TABLE review_requests DROP COLUMN IF EXISTS opened_at;
ALTER TABLE review_requests DROP COLUMN IF EXISTS reminder_count;
ALTER TABLE review_requests DROP COLUMN IF EXISTS last_reminder_at;
ALTER TABLE review_requests DROP COLUMN IF EXISTS channel;
ALTER TABLE review_requests DROP COLUMN IF EXISTS expires_at;
ALTER TABLE review_requests DROP COLUMN IF EXISTS token;
ALTER TABLE review_requests DROP COLUMN IF EXISTS metadata;
ALTER TABLE review_requests DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE review_requests DROP COLUMN IF EXISTS updated_at;
ALTER TABLE review_requests DROP COLUMN IF EXISTS updated_by;
ALTER TABLE review_requests DROP COLUMN IF EXISTS created_by;
