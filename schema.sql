--
-- agent_chat database schema
-- Repository: NOVA-Openclaw/agent-chat
-- Issue lineage: nova-mind#320 (standalone bus), nova-mind#579 (extraction to dedicated repo)
--
-- This file is the AUTHORITATIVE schema for the agent_chat message bus.
-- It is kept in sync with the live database by pg-notify-listener-chat.py,
-- which commits the output of `pgschema dump --db agent_chat` after every
-- schema-changing DDL statement.
--
-- Design decisions (authoritative, 2026-08-11):
--   * PostgreSQL-backed, once-per-host install model. The bus is optional for
--     any single agent; nova-mind discovers it via peer-detection.
--   * Messages are immutable: all INSERTs must go through send_agent_message().
--     Direct DML on agent_chat is blocked by trg_enforce_agent_chat_function_use.
--   * send_agent_message() is SECURITY DEFINER owned by postgres and validates
--     p_sender against session_user (#475 hardening).
--   * expire_old_chat() is SECURITY DEFINER owned by postgres so the nightly
--     cron (running as role nova) can DELETE expired rows once the immutability
--     trigger enforces DELETE.
--   * Logical replication apply workers and postgres-role sessions bypass the
--     immutability trigger so that replication and admin tooling work.
--   * schema_change_trigger auto-notifies the schema-sync listener.
--

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

--
-- Name: agent_chat_status; Type: TYPE; Schema: public; Owner: -
--
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'public' AND t.typname = 'agent_chat_status') THEN
        CREATE TYPE public.agent_chat_status AS ENUM (
            'received',
            'routed',
            'responded',
            'failed',
            'expired',
            'skipped'
        );
    END IF;
END $$;

--
-- Name: agent_chat; Type: TABLE; Schema: public; Owner: -
--
CREATE TABLE IF NOT EXISTS public.agent_chat (
    id SERIAL,
    sender varchar(50) NOT NULL,
    message text NOT NULL,
    recipients text[] NOT NULL,
    reply_to integer,
    "timestamp" timestamptz DEFAULT now() NOT NULL,
    expires_at timestamptz,
    CONSTRAINT agent_chat_pkey PRIMARY KEY (id),
    CONSTRAINT agent_chat_recipients_check CHECK (array_length(recipients, 1) > 0)
);

-- Self-reference FK is intentionally NOT VALID to match the live production
-- schema state (nova-mind#475 drift). It is still enforced for new rows.
ALTER TABLE public.agent_chat DROP CONSTRAINT IF EXISTS agent_chat_reply_to_fkey;
ALTER TABLE public.agent_chat ADD CONSTRAINT agent_chat_reply_to_fkey FOREIGN KEY (reply_to) REFERENCES public.agent_chat (id) NOT VALID;

COMMENT ON TABLE public.agent_chat IS 'Agent messaging. INSERT allowed for all, UPDATE/DELETE only Newhart.';
COMMENT ON COLUMN public.agent_chat.expires_at IS 'Optional TTL. Rows with expires_at < NOW() are eligible for reaper cleanup. NULL = no expiry.';

--
-- Name: agent_chat_processed; Type: TABLE; Schema: public; Owner: -
--
CREATE TABLE IF NOT EXISTS public.agent_chat_processed (
    chat_id integer,
    agent varchar(50),
    received_at timestamp,
    routed_at timestamp,
    responded_at timestamp,
    error_message text,
    status public.agent_chat_status DEFAULT 'responded'::public.agent_chat_status,
    CONSTRAINT agent_chat_processed_pkey PRIMARY KEY (chat_id, agent)
);

-- FK to agent_chat is VALIDATED with ON DELETE CASCADE. Processed-state rows
-- are meaningless once the parent message is deleted, and expire_old_chat()
-- must be able to reap old messages that have processing state (agent-chat#4).
-- Migration 004 deletes any orphan rows that accumulated while the constraint
-- was previously NOT VALID and then validates it.
ALTER TABLE public.agent_chat_processed DROP CONSTRAINT IF EXISTS agent_chat_processed_chat_id_fkey;
ALTER TABLE public.agent_chat_processed ADD CONSTRAINT agent_chat_processed_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.agent_chat (id) ON DELETE CASCADE;

COMMENT ON TABLE public.agent_chat_processed IS 'Message processing state. Agents can track, Newhart manages.';

--
-- Indexes
--
CREATE INDEX IF NOT EXISTS idx_agent_chat_recipients ON public.agent_chat USING gin (recipients);
CREATE INDEX IF NOT EXISTS idx_agent_chat_sender ON public.agent_chat (sender, "timestamp" DESC);
CREATE INDEX IF NOT EXISTS idx_agent_chat_timestamp ON public.agent_chat ("timestamp");
CREATE INDEX IF NOT EXISTS idx_agent_chat_expires ON public.agent_chat (expires_at) WHERE expires_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_agent_chat_processed_agent ON public.agent_chat_processed (agent);
CREATE INDEX IF NOT EXISTS idx_agent_chat_processed_status ON public.agent_chat_processed (status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_chat_processed_unique ON public.agent_chat_processed (chat_id, agent);

--
-- Functions
--

-- Name: notify_agent_chat(); Type: FUNCTION; Schema: public; Owner: -
CREATE OR REPLACE FUNCTION public.notify_agent_chat()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    PERFORM pg_notify('agent_chat', json_build_object(
        'id', NEW.id,
        'sender', NEW.sender,
        'recipients', NEW.recipients
    )::text);
    RETURN NEW;
END;
$$;

-- Name: send_agent_message(text, text, text[], interval, integer); Type: FUNCTION; Schema: public; Owner: -
-- Defensive drop of all known historical signatures before CREATE OR REPLACE.
-- Without this, applying this 5-arg schema against a database that still has
-- the live 4-arg (or stale 3-arg) signature would CREATE a second overload,
-- producing a transient ambiguous-function window for 3-arg callers between
-- schema-apply and migration 001. Matches migration 001's idempotent pattern.
DROP FUNCTION IF EXISTS public.send_agent_message(text, text, text[]);
DROP FUNCTION IF EXISTS public.send_agent_message(text, text, text[], interval);
DROP FUNCTION IF EXISTS public.send_agent_message(text, text, text[], interval, integer);

CREATE OR REPLACE FUNCTION public.send_agent_message(
    p_sender text,
    p_message text,
    p_recipients text[],
    p_ttl interval DEFAULT NULL::interval,
    p_reply_to integer DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
    v_id         INTEGER;
    v_sender     TEXT;
    v_recipients TEXT[];
    v_expires_at TIMESTAMPTZ;
BEGIN
    -- Validate sender matches the actual connected database user.
    -- Must use session_user (not current_user) because SECURITY DEFINER
    -- sets current_user to the function owner (postgres).
    IF LOWER(p_sender) != session_user THEN
        RAISE EXCEPTION 'send_agent_message: sender must match session_user (got % but connected as %)', p_sender, session_user;
    END IF;

    -- Validate inputs
    IF p_message IS NULL OR trim(p_message) = '' THEN
        RAISE EXCEPTION 'send_agent_message: message cannot be empty';
    END IF;

    IF p_recipients IS NULL OR array_length(p_recipients, 1) IS NULL THEN
        RAISE EXCEPTION 'send_agent_message: recipients cannot be NULL or empty — use ARRAY[''*''] for broadcast';
    END IF;

    -- Normalize to lowercase
    v_sender := LOWER(p_sender);
    v_recipients := ARRAY(SELECT LOWER(unnest(p_recipients)));

    -- GUARD: reject self-addressed messages (no legitimate use case; always a typo)
    IF v_sender = ANY(v_recipients) THEN
        RAISE EXCEPTION 'send_agent_message: sender "%" is in the recipient list — agents cannot message themselves (did you mean to address someone else?)', v_sender;
    END IF;

    -- Compute expiry if TTL provided
    IF p_ttl IS NOT NULL THEN
        v_expires_at := NOW() + p_ttl;
    END IF;

    -- Atomic insert including reply_to; the enforce trigger allows this because
    -- current_user = 'postgres' inside the SECURITY DEFINER context.
    INSERT INTO public.agent_chat (sender, message, recipients, reply_to, expires_at)
    VALUES (v_sender, p_message, v_recipients, p_reply_to, v_expires_at)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- Explicit ownership: the function must be owned by postgres so the SECURITY
-- DEFINER context sets current_user = 'postgres' and the DML lockdown trigger
-- authorizes INSERTs. Without this, a non-postgres superuser applying the
-- schema becomes the owner and agents get permission-denied on every send
-- (nova-mind#569). Wrapped so a non-superuser devtest apply still succeeds.
DO $$
BEGIN
    ALTER FUNCTION public.send_agent_message(text, text, text[], interval, integer) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping send_agent_message owner assignment: current user is not a superuser';
END $$;

-- Name: enforce_agent_chat_function_use(); Type: FUNCTION; Schema: public; Owner: -
CREATE OR REPLACE FUNCTION public.enforce_agent_chat_function_use()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    -- Allow logical replication apply workers.
    IF EXISTS (
        SELECT 1 FROM pg_stat_activity
        WHERE pid = pg_backend_pid()
          AND backend_type = 'logical replication worker'
    ) THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    -- Allow postgres role (SECURITY DEFINER functions + admin sessions).
    -- send_agent_message() is SECURITY DEFINER owned by postgres, so
    -- current_user = 'postgres' inside it. Agent sessions have current_user
    -- set to their own role — this check cannot be spoofed.
    IF current_user = 'postgres' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END IF;

    -- All other roles: deny direct DML
    IF TG_OP = 'INSERT' THEN
        RAISE EXCEPTION 'Direct INSERT on agent_chat is not allowed. Use send_agent_message() instead.';
    ELSIF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Direct UPDATE on agent_chat is not allowed. Messages are immutable.';
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Direct DELETE on agent_chat is not allowed.';
    END IF;

    RETURN NULL;
END;
$$;

-- Name: expire_old_chat(integer); Type: FUNCTION; Schema: public; Owner: -
-- SECURITY DEFINER so the nightly cron (role nova) can DELETE expired rows
-- while the immutability trigger blocks direct DELETEs for non-postgres roles.
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

-- expire_old_chat must be owned by postgres for the SECURITY DEFINER context
-- to set current_user = 'postgres' and satisfy the immutability trigger bypass.
DO $$
BEGIN
    ALTER FUNCTION public.expire_old_chat(integer) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping expire_old_chat owner assignment: current user is not a superuser';
END $$;

-- Name: notify_schema_change(); Type: FUNCTION; Schema: public; Owner: -
CREATE OR REPLACE FUNCTION public.notify_schema_change()
RETURNS event_trigger
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE payload text; obj record;
BEGIN
  SELECT INTO obj command_tag, object_type, schema_name, object_identity
  FROM (SELECT DISTINCT ON (object_identity) command_tag, object_type, schema_name, object_identity
        FROM pg_event_trigger_ddl_commands()) deduped LIMIT 1;
  IF obj IS NOT NULL THEN
    payload := json_build_object('command_tag', obj.command_tag, 'object_type', obj.object_type,
      'schema_name', obj.schema_name, 'object_identity', obj.object_identity)::text;
    PERFORM pg_notify('schema_changed', payload);
  END IF;
END;
$$;

--
-- Views
--

-- Name: v_agent_chat_recent; Type: VIEW; Schema: public; Owner: -
CREATE OR REPLACE VIEW public.v_agent_chat_recent AS
 SELECT id,
    sender,
    message,
    recipients,
    reply_to,
    "timestamp"
   FROM public.agent_chat
  WHERE "timestamp" > (now() - '30 days'::interval)
  ORDER BY "timestamp" DESC;

-- Name: v_agent_chat_stats; Type: VIEW; Schema: public; Owner: -
CREATE OR REPLACE VIEW public.v_agent_chat_stats AS
 SELECT count(*) AS total_messages,
    count(*) FILTER (WHERE "timestamp" > (now() - '24:00:00'::interval)) AS messages_24h,
    count(*) FILTER (WHERE "timestamp" > (now() - '7 days'::interval)) AS messages_7d,
    count(DISTINCT sender) AS unique_senders,
    pg_size_pretty(pg_total_relation_size('agent_chat'::regclass)) AS table_size,
    min("timestamp") AS oldest_message,
    max("timestamp") AS newest_message
   FROM public.agent_chat;

--
-- Triggers
--

-- Name: trg_notify_agent_chat; Type: TRIGGER; Schema: public; Owner: -
-- ENABLE ALWAYS is required so that replication-apply-worker-originated inserts
-- still notify bus listeners.
DROP TRIGGER IF EXISTS trg_notify_agent_chat ON public.agent_chat;
CREATE TRIGGER trg_notify_agent_chat
    AFTER INSERT ON public.agent_chat
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_agent_chat();

ALTER TABLE public.agent_chat ENABLE ALWAYS TRIGGER trg_notify_agent_chat;

-- Name: trg_enforce_agent_chat_function_use; Type: TRIGGER; Schema: public; Owner: -
DROP TRIGGER IF EXISTS trg_enforce_agent_chat_function_use ON public.agent_chat;
CREATE TRIGGER trg_enforce_agent_chat_function_use
    BEFORE INSERT OR UPDATE OR DELETE ON public.agent_chat
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_agent_chat_function_use();

--
-- Privileges
--
-- Default privileges mirror the live production dump so future objects created
-- by postgres/nova get the same grants; explicit grants make current objects
-- deterministic regardless of which role creates them.
--

-- Default privileges for role postgres. Wrapped so a non-superuser devtest apply
-- can still succeed.
DO $$
BEGIN
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT USAGE ON SEQUENCES TO argus, athena, coder, conductor, erato, flint, gem, gidget, hermes, iris, marcie, nova, quill, scout, scribe, ticker;
    ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT DELETE, INSERT, SELECT, UPDATE ON TABLES TO argus, athena, coder, conductor, erato, flint, gem, gidget, hermes, iris, marcie, nova, quill, scout, scribe, ticker;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping postgres default privileges: current user is not a superuser';
END $$;

ALTER DEFAULT PRIVILEGES FOR ROLE nova IN SCHEMA public GRANT SELECT ON TABLES TO argus, athena, coder, conductor, erato, flint, gem, gidget, graybeard, hermes, iris, marcie, newhart, "nova-staging", quill, scout, scribe, ticker;

-- Explicit table grants for nova-ecosystem agent roles
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.agent_chat TO argus, athena, coder, conductor, erato, flint, gem, gidget, hermes, iris, marcie, nova, quill, scout, scribe, ticker;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.agent_chat_processed TO argus, athena, coder, conductor, erato, flint, gem, gidget, hermes, iris, marcie, nova, quill, scout, scribe, ticker;

-- Newhart's access is intentionally restricted: revoke SELECT that would
-- otherwise be granted by nova default privileges.
REVOKE SELECT ON TABLE public.agent_chat FROM newhart;
REVOKE SELECT ON TABLE public.agent_chat_processed FROM newhart;

-- Peer agent graybeard gets the same full CRUD as subagents.
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.agent_chat TO graybeard;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.agent_chat_processed TO graybeard;

-- nova-staging: SEND capability. EXECUTE on send_agent_message is granted
-- explicitly below; SELECT on the bus tables lets it read/poll.
GRANT SELECT ON TABLE public.agent_chat TO "nova-staging";
GRANT SELECT ON TABLE public.agent_chat_processed TO "nova-staging";

-- victoria: send+receive capability on the shared cross-ecosystem bus.
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.agent_chat TO victoria;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.agent_chat_processed TO victoria;

-- Cross-ecosystem consumers. cadence is read-only on agent_chat; recon is
-- read-only on agent_chat but has full CRUD on agent_chat_processed.
GRANT SELECT ON TABLE public.agent_chat TO cadence, recon;
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.agent_chat_processed TO recon;

-- Sequence grants (replicate live production matrix; newhart intentionally absent)
GRANT USAGE ON SEQUENCE public.agent_chat_id_seq TO argus, coder, conductor, erato, flint, gem, gidget, graybeard, hermes, iris, marcie, nova, quill, recon, scribe, ticker;
GRANT SELECT, USAGE ON SEQUENCE public.agent_chat_id_seq TO athena, scout;
GRANT USAGE ON SEQUENCE public.agent_chat_id_seq TO victoria;
GRANT SELECT ON SEQUENCE public.agent_chat_id_seq TO newhart;
-- nova-staging only needs SEND capability; it does not need to allocate sequence values.

-- View grants (replicate live production matrix)
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.v_agent_chat_recent TO argus, athena, coder, conductor, erato, flint, gem, gidget, hermes, iris, marcie, newhart, nova, quill, scout, scribe, ticker;
GRANT SELECT ON TABLE public.v_agent_chat_recent TO graybeard, "nova-staging";
GRANT DELETE, INSERT, SELECT, UPDATE ON TABLE public.v_agent_chat_stats TO argus, athena, coder, conductor, erato, flint, gem, gidget, hermes, iris, marcie, newhart, nova, quill, scout, scribe, ticker;
GRANT SELECT ON TABLE public.v_agent_chat_stats TO graybeard, "nova-staging";

-- victoria view grants (read access for receive/polling)
GRANT SELECT ON TABLE public.v_agent_chat_recent TO victoria;
GRANT SELECT ON TABLE public.v_agent_chat_stats TO victoria;

-- Function grants: existing functions default to PUBLIC EXECUTE. We explicitly
-- document the required EXECUTE capability for victoria and nova-staging
-- without revoking PUBLIC access.
GRANT EXECUTE ON FUNCTION public.send_agent_message(text, text, text[], interval, integer) TO victoria, "nova-staging";

--
-- Name: schema_version; Type: TABLE; Schema: public; Owner: -
--
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);

COMMENT ON TABLE public.schema_version IS 'Migration/version handshake table. Inserted by the installer; read by nova-mind peer-detection for compatibility checks.';

-- Seed initial extraction version.
INSERT INTO public.schema_version (version, applied_at, description)
VALUES (1, now(), 'initial extraction from nova-mind')
ON CONFLICT (version) DO NOTHING;

--
-- Name: schema_change_trigger; Type: EVENT TRIGGER; Schema: public; Owner: -
-- Event triggers require superuser privileges. Wrap so devtest applies by a
-- non-superuser role do not fail; in production the installer runs as postgres.
DO $$
BEGIN
    DROP EVENT TRIGGER IF EXISTS schema_change_trigger;
    CREATE EVENT TRIGGER schema_change_trigger
        ON ddl_command_end
        EXECUTE FUNCTION public.notify_schema_change();
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping schema_change_trigger creation: current user is not a superuser';
END $$;
