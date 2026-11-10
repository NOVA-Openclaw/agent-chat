-- Migration: agent-chat#39
-- Replace all named per-agent grants with a dynamic, role-name-agnostic
-- grant re-application. This migration discovers the roles that currently
-- hold bus access (SELECT on agent_chat or EXECUTE on send_agent_message)
-- and re-applies the hardened standard grant set to each of them:
--
--   * SELECT on public.agent_chat
--   * SELECT, INSERT, UPDATE on public.agent_chat_processed
--   * SELECT on breaker/mute control tables
--   * NO direct INSERT/UPDATE/DELETE on public.agent_chat
--   * NO direct INSERT/UPDATE/DELETE on breaker/mute control tables
--
-- It never names a role, never grants to PUBLIC, and never grants EXECUTE
-- (bus functions remain PUBLIC EXECUTE by default). Roles that have no
-- existing bus access are left untouched, so this is idempotent and safe
-- to re-run.

BEGIN;

DO $$
DECLARE
    v_role text;
    v_table text;
    v_control_tables text[] := ARRAY[
        'agent_chat_error_templates',
        'agent_chat_breaker_config',
        'agent_chat_breaker_state',
        'agent_chat_breaker_alerts',
        'agent_chat_mutes',
        'agent_chat_suppressed_log'
    ];
BEGIN
    -- Discover roles that already have bus access through either the
    -- table-grant path (register-agent.sh grants SELECT on agent_chat) or
    -- the routine-grant path (legacy named EXECUTE on send_agent_message).
    FOR v_role IN
        -- grantee is sql_identifier text; %I below quotes exactly once.
        SELECT DISTINCT grantee
        FROM information_schema.role_table_grants
        WHERE table_schema = 'public'
          AND table_name = 'agent_chat'
          AND privilege_type = 'SELECT'
          AND grantee NOT IN ('PUBLIC', 'postgres', session_user)
        UNION
        SELECT DISTINCT grantee
        FROM information_schema.role_routine_grants
        WHERE routine_schema = 'public'
          AND routine_name = 'send_agent_message'
          AND privilege_type = 'EXECUTE'
          AND grantee NOT IN ('PUBLIC', 'postgres', session_user)
    LOOP
        -- Never touch the owner or superuser role; the owner must keep
        -- inherent privileges for migrations to work in dev/test.
        IF v_role = session_user OR v_role = 'postgres' THEN
            CONTINUE;
        END IF;

        -- Hardened standard grant set (matches register-agent.sh).
        EXECUTE format('GRANT SELECT ON TABLE public.agent_chat TO %I', v_role);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE ON TABLE public.agent_chat_processed TO %I', v_role);

        -- Defense in depth: ensure no direct DML on the immutable message table.
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON TABLE public.agent_chat FROM %I', v_role);

        -- Lock down control tables to SELECT only for existing bus users.
        FOREACH v_table IN ARRAY v_control_tables
        LOOP
            EXECUTE format(
                'REVOKE INSERT, UPDATE, DELETE ON TABLE public.%I FROM %I',
                v_table, v_role
            );
            EXECUTE format(
                'GRANT SELECT ON TABLE public.%I TO %I',
                v_table, v_role
            );
        END LOOP;
    END LOOP;
END $$;

-- Version handshake.
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);

INSERT INTO public.schema_version (version, description)
VALUES (9, 'agent-chat#39: generic dynamic grant re-application, no named agent grants')
ON CONFLICT (version) DO NOTHING;

COMMIT;
