-- Migration: nova-mind#579
-- Fix the immutability trigger binding and make expire_old_chat SECURITY DEFINER.
--
-- Background:
--   * The live agent_chat DB had trg_enforce_agent_chat_function_use bound to
--     BEFORE INSERT only. The function body contained UPDATE/DELETE branches that
--     were never invoked, so direct UPDATE/DELETE on agent_chat was not actually
--     blocked (blocking finding §10.1 in TEST-CASES-ISSUE-579.md).
--   * expire_old_chat() was a plain function (prosecdef=false). Once the trigger
--     is corrected to fire on DELETE, the nightly cron (running as role nova)
--     would be blocked because current_user would be 'nova', not 'postgres'.
--
-- This migration must be applied atomically in a single transaction with both
-- changes, or the nightly cron breaks between them.

BEGIN;

-- Drop and recreate the enforce trigger with the full DML binding that matches
-- the function body's TG_OP branches. Preserve the same function; only the
-- trigger binding changes.
DROP TRIGGER IF EXISTS trg_enforce_agent_chat_function_use ON public.agent_chat;
CREATE TRIGGER trg_enforce_agent_chat_function_use
    BEFORE INSERT OR UPDATE OR DELETE ON public.agent_chat
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_agent_chat_function_use();

-- Make expire_old_chat SECURITY DEFINER and owned by postgres so the cron's
-- DELETE is authorized by the trigger's current_user = 'postgres' bypass.
CREATE OR REPLACE FUNCTION public.expire_old_chat(
    retention_days integer DEFAULT 90
)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE deleted_count integer;
BEGIN
    DELETE FROM public.agent_chat WHERE "timestamp" < now() - (retention_days || ' days')::interval;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

DO $$
BEGIN
    ALTER FUNCTION public.expire_old_chat(integer) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping expire_old_chat owner assignment: current user is not a superuser';
END $$;

-- Track this migration.
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);
INSERT INTO public.schema_version (version, description)
VALUES (2, 'fix immutability trigger binding and make expire_old_chat SECURITY DEFINER')
ON CONFLICT (version) DO NOTHING;

COMMIT;
