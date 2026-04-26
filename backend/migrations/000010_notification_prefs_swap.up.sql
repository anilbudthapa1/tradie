-- Replace per-(user,channel,event) notification_preferences with business-level
-- settings table that the handlers actually expect.
DROP TABLE IF EXISTS notification_preferences CASCADE;

CREATE TABLE notification_preferences (
    business_id UUID PRIMARY KEY REFERENCES businesses(id) ON DELETE CASCADE,
    settings    JSONB DEFAULT '{}',
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);
