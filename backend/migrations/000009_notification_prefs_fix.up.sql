-- Allow business-level notification preferences (user_id NULL = applies to whole business)
ALTER TABLE notification_preferences ALTER COLUMN user_id DROP NOT NULL;
