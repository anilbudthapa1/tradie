-- Multi-tenant Row-Level Security backstop.
--
-- Every table that has a business_id column gets a tenant_isolation
-- policy enforcing that any row read or written matches the value
-- in the per-session GUC `app.current_business_id`.
--
-- Behaviour: PERMISSIVE WHEN UNSET. If a connection has not set
-- app.current_business_id, the policy passes (current_setting
-- returns '' with the second arg = true). This means existing
-- handlers continue to work unchanged after migration. Once the
-- TenantGuard middleware is updated to call set_tenant() on every
-- request, RLS becomes a hard backstop against any handler that
-- forgets to filter by business_id.
--
-- FORCE is intentionally enabled — without it, table owners
-- (typically the app's DB user) bypass RLS entirely and the
-- policy is decorative.
--
-- To activate enforcement: have TenantGuard call
--   SELECT set_tenant($1::uuid)
-- once per request (inside a tx, or after pool acquire). Set
-- app.current_business_id to the empty string in any admin /
-- migration / cron context that legitimately needs cross-tenant
-- access — set_config('app.current_business_id', '', false).

-- ── helper ─────────────────────────────────────────────────────────────
-- One call per request in TenantGuard; used by policies below.
CREATE OR REPLACE FUNCTION set_tenant(business_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM set_config('app.current_business_id', business_uuid::text, false);
END;
$$;

CREATE OR REPLACE FUNCTION clear_tenant()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM set_config('app.current_business_id', '', false);
END;
$$;

-- ── apply policies to every per-tenant table ───────────────────────────
DO $$
DECLARE
    t text;
BEGIN
    FOR t IN
        SELECT c.table_name
          FROM information_schema.columns c
         WHERE c.table_schema = 'public'
           AND c.column_name = 'business_id'
           AND c.table_name NOT IN ('businesses') -- skip the tenant root itself
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);

        -- Drop the policy first so the migration is idempotent.
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', t);

        EXECUTE format($p$
            CREATE POLICY tenant_isolation ON %I
            USING (
                current_setting('app.current_business_id', true) = ''
                OR business_id::text = current_setting('app.current_business_id', true)
            )
            WITH CHECK (
                current_setting('app.current_business_id', true) = ''
                OR business_id::text = current_setting('app.current_business_id', true)
            )
        $p$, t);
    END LOOP;
END $$;
