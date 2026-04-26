-- Reverse: drop policies + disable RLS on every table with business_id.

DO $$
DECLARE
    t text;
BEGIN
    FOR t IN
        SELECT c.table_name
          FROM information_schema.columns c
         WHERE c.table_schema = 'public'
           AND c.column_name = 'business_id'
           AND c.table_name NOT IN ('businesses')
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', t);
        EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I DISABLE ROW LEVEL SECURITY', t);
    END LOOP;
END $$;

DROP FUNCTION IF EXISTS clear_tenant();
DROP FUNCTION IF EXISTS set_tenant(uuid);
