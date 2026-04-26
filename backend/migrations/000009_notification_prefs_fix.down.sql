-- Note: cannot safely revert if rows exist with NULL user_id
ALTER TABLE notification_preferences ALTER COLUMN user_id SET NOT NULL;
