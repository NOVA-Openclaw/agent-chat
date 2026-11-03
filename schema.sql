--
-- agent_chat database schema
-- Repository: NOVA-Openclaw/agent-chat
-- Issue lineage: nova-mind#320 (standalone bus), nova-mind#579 (extraction to dedicated repo)
--
-- This file is the AUTHORITATIVE schema for the agent_chat message bus.
-- It is kept in sync with the live database by the nova-workspace listener
-- scripts/pg-notify-listener-agent-chat.py (local nova tooling), which commits
-- the output of `pgschema dump --db agent_chat` after every schema-changing DDL
-- statement.
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
            'skipped',
            'handled'
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
    handled_at timestamp,
    expired_at timestamp,
    skipped_at timestamp,
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

-- Name: agent_chat_error_templates; Type: TABLE; Schema: public; Owner: -
-- agent-chat#11: denylist of runtime-error / non-actionable status templates.
-- send_agent_message() quarantines any outbound body matching an active
-- pattern here instead of inserting it into agent_chat. Additive-only: add
-- new occurrences via INSERT, retire old ones with active=false rather than
-- deleting rows.
CREATE TABLE IF NOT EXISTS public.agent_chat_error_templates (
    id SERIAL PRIMARY KEY,
    pattern text NOT NULL,
    description text,
    added_at timestamptz NOT NULL DEFAULT now(),
    active boolean NOT NULL DEFAULT true,
    CONSTRAINT agent_chat_error_templates_pattern_key UNIQUE (pattern)
);

COMMENT ON TABLE public.agent_chat_error_templates IS
    'agent-chat#11: denylist of case-insensitive regex patterns matched against '
    'outbound message bodies in send_agent_message(). A match is quarantined '
    '(logged to agent_chat_suppressed_log, never inserted into agent_chat).';

INSERT INTO public.agent_chat_error_templates (pattern, description) VALUES
    ('something went wrong while processing your request',
     'agent-chat#11 occurrences 2-3: generic runtime-failure UI affordance, never content for another agent to reason about'),
    ('context is too large and auto-compaction could not recover this turn',
     'agent-chat#11 occurrence 4: runtime auto-compaction-failure template'),
    ('context is saturated and cannot process turns',
     'agent-chat#11 occurrence 4: agent-authored saturation notice -- self-describes as non-actionable and sends anyway'),
    ('The tool run finished, but no final summary was produced',
     'agent-chat#36: gateway fallback text for silent/empty final turns; must never be delivered to agent_chat peers')
ON CONFLICT ON CONSTRAINT agent_chat_error_templates_pattern_key DO NOTHING;

-- Name: agent_chat_normalize_for_match(text); Type: FUNCTION; Schema: public; Owner: -
-- agent-chat#11 BLOCKING #1 fix (2026-09-03 QA remediation): lowercases and
-- collapses every run of non-alphanumeric characters (whitespace, punctuation,
-- emoji) to a single space, then trims. Used by agent_chat_is_error_template()
-- so pattern matching is insensitive to case and incidental punctuation/emoji
-- framing while still supporting a whole-message coverage check.
CREATE OR REPLACE FUNCTION public.agent_chat_normalize_for_match(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT trim(regexp_replace(lower(p_text), '[^a-z0-9]+', ' ', 'g'));
$$;

COMMENT ON FUNCTION public.agent_chat_normalize_for_match(text) IS
    'agent-chat#11: lowercase + non-alphanumeric-collapse normalization used by '
    'agent_chat_is_error_template() for whole-message coverage matching.';

-- Name: agent_chat_is_error_template(text); Type: FUNCTION; Schema: public; Owner: -
-- agent-chat#11 BLOCKING #1 fix (2026-09-03 QA remediation, Gem QA): the
-- original unanchored `~*` substring match suppressed ANY message that merely
-- quoted or paraphrased a known template, including substantive error
-- reports, peer-investigation requests, an all-caps restatement, and a
-- third-party observation about another agent's degraded state -- exactly the
-- messages a human/agent most needs to see. Fixed: require the pattern to
-- constitute essentially the ENTIRE message (case/punctuation-insensitive),
-- not merely appear somewhere inside it: coverage_ratio (normalized pattern
-- length / normalized message length) must be >= 0.25, and the match must
-- start within the first 5 normalized characters of the message.
CREATE OR REPLACE FUNCTION public.agent_chat_is_error_template(p_message text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.agent_chat_error_templates t
        CROSS JOIN LATERAL (
            SELECT
                public.agent_chat_normalize_for_match(p_message) AS m_norm,
                public.agent_chat_normalize_for_match(t.pattern)  AS p_norm
        ) n
        WHERE t.active
          AND length(n.p_norm) > 0
          AND length(n.m_norm) > 0
          AND position(n.p_norm IN n.m_norm) > 0
          AND (position(n.p_norm IN n.m_norm) - 1) <= 5
          AND length(n.p_norm)::numeric / length(n.m_norm) >= 0.25
    );
$$;

COMMENT ON FUNCTION public.agent_chat_is_error_template(text) IS
    'agent-chat#11: true if p_message is essentially a bare known error/status '
    'template (normalized coverage_ratio >= 0.25, match starts within the first '
    '5 normalized chars) -- not merely a message that quotes or references one. '
    'STABLE (reads a table) not IMMUTABLE.';

-- Name: agent_chat_has_artifact_ref(text); Type: FUNCTION; Schema: public; Owner: -
-- agent-chat#11: used by the circuit breaker to detect whether a message
-- references new, substantive content (issue/PR/task number or file path).
-- ACCEPTED RISK (2026-09-03 QA remediation, Gem QA, non-blocking): the
-- `#\d+` clause is context-free -- "room #12" or "rule #1" inside an
-- otherwise non-substantive message resets the counter just as a real
-- issue/PR reference would. Intentional recall-over-precision tradeoff, not
-- redesigned per QA guidance.
CREATE OR REPLACE FUNCTION public.agent_chat_has_artifact_ref(p_message text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_message ~* '#\d+|\y(?:issue|pr|task)[-_ ]*#?\d+\y|[/\\][\w.-]+\.[a-zA-Z0-9]{1,6}\y';
$$;

-- Name: agent_chat_message_shape(text); Type: FUNCTION; Schema: public; Owner: -
-- agent-chat#11 BLOCKING #2 fix (2026-09-03 QA remediation): normalized
-- "shape" of a message body used by the circuit breaker's content-novelty
-- escape check -- lowercase, digits removed, non-letters collapsed to single
-- spaces, trimmed. Two messages with the same shape are treated as the same
-- repeating storm body even if a counter/id differs; a different shape is
-- treated as genuinely new content and can escape a tripped breaker.
CREATE OR REPLACE FUNCTION public.agent_chat_message_shape(p_message text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT trim(regexp_replace(regexp_replace(lower(p_message), '[0-9]+', '', 'g'), '[^a-z]+', ' ', 'g'));
$$;

COMMENT ON FUNCTION public.agent_chat_message_shape(text) IS
    'agent-chat#11: digit-stripped, letters-only normalized shape of a message '
    'body. Used by the circuit breaker''s content-novelty escape hatch to '
    'distinguish a repeating storm body from genuinely new content.';

-- Name: agent_chat_breaker_config; Type: TABLE; Schema: public; Owner: -
-- agent-chat#34/#36: configurable per-pair loop-detection threshold and
-- rolling window. A NULL pair acts as the global default. Per-pair rows
-- override the default for that unordered pair.
CREATE TABLE IF NOT EXISTS public.agent_chat_breaker_config (
    id SERIAL PRIMARY KEY,
    pair_a text,
    pair_b text,
    threshold integer NOT NULL DEFAULT 6,
    "window" interval NOT NULL DEFAULT interval '5 minutes',
    CONSTRAINT agent_chat_breaker_config_pair_key UNIQUE (pair_a, pair_b),
    CONSTRAINT agent_chat_breaker_config_pair_order CHECK (
        pair_a IS NULL OR pair_b IS NULL OR pair_a < pair_b
    ),
    CONSTRAINT agent_chat_breaker_config_positive_threshold CHECK (threshold > 0)
);

COMMENT ON TABLE public.agent_chat_breaker_config IS
    'agent-chat#34/#36: configurable loop-detection threshold and rolling '
    'window. NULL pair = global default; concrete pair rows override it.';

-- Seed the global default: 6 messages in 5 minutes.
INSERT INTO public.agent_chat_breaker_config (pair_a, pair_b, threshold, "window")
VALUES (NULL, NULL, 6, interval '5 minutes')
ON CONFLICT ON CONSTRAINT agent_chat_breaker_config_pair_key DO NOTHING;

-- Name: agent_chat_breaker_state; Type: TABLE; Schema: public; Owner: -
-- agent-chat#34/#36: per unordered pair rolling-window counter. The breaker
-- never suppresses delivery; when the threshold is crossed it records one
-- alert per trip/window and continues delivering normally.
CREATE TABLE IF NOT EXISTS public.agent_chat_breaker_state (
    pair_a text NOT NULL,
    pair_b text NOT NULL,
    window_start timestamptz NOT NULL DEFAULT now(),
    message_count integer NOT NULL DEFAULT 0,
    alerted boolean NOT NULL DEFAULT false,
    last_message_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agent_chat_breaker_state_pkey PRIMARY KEY (pair_a, pair_b),
    CONSTRAINT agent_chat_breaker_state_pair_order CHECK (pair_a < pair_b)
);

COMMENT ON TABLE public.agent_chat_breaker_state IS
    'agent-chat#34/#36: per unordered pair rolling-window message counter. '
    'alerted=true means an alert has already been emitted for the current '
    'window; it resets to false when the window rolls forward.';

-- Name: agent_chat_breaker_alerts; Type: TABLE; Schema: public; Owner: -
-- agent-chat#34/#36: one row per trip per pair/window. The plugin reads
-- pending alerts via agent_chat_pending_alerts(agent) and can mark them
-- seen via agent_chat_mark_alerts_seen(integer[]).
CREATE TABLE IF NOT EXISTS public.agent_chat_breaker_alerts (
    id SERIAL PRIMARY KEY,
    pair_a text NOT NULL,
    pair_b text NOT NULL,
    window_start timestamptz NOT NULL,
    window_end timestamptz NOT NULL,
    message_count integer NOT NULL,
    threshold integer NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    seen_at timestamptz,
    CONSTRAINT agent_chat_breaker_alerts_pair_order CHECK (pair_a < pair_b)
);

CREATE INDEX IF NOT EXISTS idx_agent_chat_breaker_alerts_unseen
    ON public.agent_chat_breaker_alerts (pair_a, pair_b) WHERE seen_at IS NULL;

-- Name: notify_agent_chat_breaker_alert(); Type: FUNCTION; Schema: public; Owner: -
CREATE OR REPLACE FUNCTION public.notify_agent_chat_breaker_alert()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    PERFORM pg_notify('agent_chat_breaker_alert', json_build_object(
        'alert_id', NEW.id,
        'pair_a', NEW.pair_a,
        'pair_b', NEW.pair_b,
        'message_count', NEW.message_count,
        'threshold', NEW.threshold
    )::text);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_agent_chat_breaker_alert ON public.agent_chat_breaker_alerts;
CREATE TRIGGER trg_notify_agent_chat_breaker_alert
    AFTER INSERT ON public.agent_chat_breaker_alerts
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_agent_chat_breaker_alert();

ALTER TABLE public.agent_chat_breaker_alerts ENABLE ALWAYS TRIGGER trg_notify_agent_chat_breaker_alert;

-- Name: agent_chat_mutes; Type: TABLE; Schema: public; Owner: -
-- agent-chat#34/#36: agent-initiated peer mutes. An agent can pause inbound
-- turn waking from a specific peer for a duration. Messages are still stored
-- in agent_chat normally, but the plugin checks agent_chat_is_muted() before
-- dispatching/waking the muting agent's session.
CREATE TABLE IF NOT EXISTS public.agent_chat_mutes (
    agent text NOT NULL,
    peer text NOT NULL,
    muted_until timestamptz NOT NULL,
    reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agent_chat_mutes_pkey PRIMARY KEY (agent, peer),
    CONSTRAINT agent_chat_mutes_no_self CHECK (agent <> peer)
);

COMMENT ON TABLE public.agent_chat_mutes IS
    'agent-chat#34/#36: per-(agent, peer) mute window. Messages are stored in '
    'agent_chat, but inbound wakes for agent from peer are suppressed while NOW() < muted_until.';

-- Name: agent_chat_suppressed_log; Type: TABLE; Schema: public; Owner: -
-- agent-chat#11/#36: audit trail for sender-side filters only. Under the new
-- design the circuit breaker never suppresses delivery, so loop_breaker rows
-- are historical only.
CREATE TABLE IF NOT EXISTS public.agent_chat_suppressed_log (
    id SERIAL PRIMARY KEY,
    suppressed_at timestamptz NOT NULL DEFAULT now(),
    reason text NOT NULL,
    sender text NOT NULL,
    recipients text[] NOT NULL,
    message_sample text NOT NULL,
    window_message_count integer,
    CONSTRAINT agent_chat_suppressed_log_reason_check
        CHECK (reason IN ('sender_filter_error_template'))
);

CREATE INDEX IF NOT EXISTS idx_agent_chat_suppressed_log_time
    ON public.agent_chat_suppressed_log (suppressed_at DESC);

-- Name: mark_agent_chat_status(bigint[], text); Type: FUNCTION; Schema: public; Owner: -
-- SECURITY DEFINER function that lets an agent mark its own agent_chat_processed
-- rows as terminal ('handled', 'expired', or 'skipped').
--
-- Authorization rule (mirrors send_agent_message reply_to authorization):
-- the caller may mark a message only if they are a named recipient of it
-- (case-insensitive) OR the message is a broadcast ('*' in recipients).
--
-- If no processed row exists for (chat_id, caller) yet, one is created with the
-- requested terminal status. This closes the gap where messages never picked up
-- (or broadcasts, deliberately excluded from migration 007) would otherwise
-- reappear in every startup digest forever.
--
-- Race safety: claimMessage may insert a 'received' row concurrently. We use
-- INSERT ... ON CONFLICT (chat_id, agent) DO NOTHING, then the guarded UPDATE.
-- If the insert lost the race, the update still applies; if the insert won,
-- the row already has the requested terminal status and the update is a no-op.
--
-- Returns the ids that were actually applied. The return type changed from
-- void to bigint[], which is backwards compatible for raw SQL callers that
-- ignore the result. Terminal statuses never regress.
DROP FUNCTION IF EXISTS public.mark_agent_chat_status(bigint[], text);

CREATE OR REPLACE FUNCTION public.mark_agent_chat_status(
    p_chat_ids bigint[],
    p_status text
)
RETURNS bigint[]
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_applied bigint[];
BEGIN
    IF p_chat_ids IS NULL THEN
        RAISE EXCEPTION 'mark_agent_chat_status: p_chat_ids cannot be NULL';
    END IF;

    IF p_status IS NULL OR trim(p_status) = '' THEN
        RAISE EXCEPTION 'mark_agent_chat_status: p_status cannot be NULL or empty';
    END IF;

    IF p_status NOT IN ('handled', 'expired', 'skipped') THEN
        -- Valid enum labels that are not allowed get our own clear error;
        -- non-existent labels (e.g. 'foo') fail naturally with the PostgreSQL
        -- invalid-input-value error for the enum type.
        PERFORM p_status::public.agent_chat_status;
        RAISE EXCEPTION 'mark_agent_chat_status: status must be "handled", "expired" or "skipped" (got %)', p_status;
    END IF;

    -- Create a processed row for authorized messages when none exists,
    -- or update an existing non-terminal row. Terminal statuses never regress.
    WITH inserted AS (
        INSERT INTO public.agent_chat_processed (chat_id, agent, status, handled_at, expired_at, skipped_at)
        SELECT ac.id, session_user, p_status::public.agent_chat_status,
               CASE WHEN p_status = 'handled' THEN NOW() ELSE NULL END,
               CASE WHEN p_status = 'expired' THEN NOW() ELSE NULL END,
               CASE WHEN p_status = 'skipped' THEN NOW() ELSE NULL END
        FROM public.agent_chat ac
        WHERE ac.id = ANY(p_chat_ids)
          AND (
              session_user = ANY(ARRAY(SELECT LOWER(unnest(ac.recipients))))
              OR '*' = ANY(ac.recipients)
          )
        ON CONFLICT (chat_id, agent) DO NOTHING
        RETURNING chat_id
    ),
    updated AS (
        UPDATE public.agent_chat_processed
        SET status = p_status::public.agent_chat_status,
            handled_at = CASE WHEN p_status = 'handled' THEN NOW() ELSE handled_at END,
            expired_at = CASE WHEN p_status = 'expired' THEN NOW() ELSE expired_at END,
            skipped_at = CASE WHEN p_status = 'skipped' THEN NOW() ELSE skipped_at END
        WHERE chat_id = ANY(p_chat_ids)
          AND agent = session_user
          AND status NOT IN ('responded', 'expired', 'handled', 'skipped', 'failed')
        RETURNING chat_id
    )
    SELECT array_agg(DISTINCT x.chat_id) INTO v_applied
    FROM (SELECT chat_id FROM inserted UNION ALL SELECT chat_id FROM updated) x;

    RETURN COALESCE(v_applied, ARRAY[]::bigint[]);
END;
$$;

DO $$
BEGIN
    ALTER FUNCTION public.mark_agent_chat_status(bigint[], text) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping mark_agent_chat_status owner assignment: current user is not a superuser';
END $$;

-- Name: agent_chat_pending_alerts(text); Type: FUNCTION; Schema: public; Owner: -
-- Returns unseen breaker alerts for any pair involving the calling agent.
-- The plugin calls this after receiving an 'agent_chat_breaker_alert' NOTIFY
-- or on poll to decide whether to investigate a possible loop.
CREATE OR REPLACE FUNCTION public.agent_chat_pending_alerts(p_agent text)
RETURNS TABLE (
    alert_id integer,
    pair_a text,
    pair_b text,
    window_start timestamptz,
    window_end timestamptz,
    message_count integer,
    threshold integer,
    created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT id, pair_a, pair_b, window_start, window_end, message_count, threshold, created_at
    FROM public.agent_chat_breaker_alerts
    WHERE seen_at IS NULL
      AND (LOWER(p_agent) = pair_a OR LOWER(p_agent) = pair_b)
    ORDER BY created_at DESC;
$$;

DO $$
BEGIN
    ALTER FUNCTION public.agent_chat_pending_alerts(text) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping agent_chat_pending_alerts owner assignment: current user is not a superuser';
END $$;

GRANT EXECUTE ON FUNCTION public.agent_chat_pending_alerts(text) TO victoria, "nova-staging";

-- Name: agent_chat_mark_alerts_seen(integer[]); Type: FUNCTION; Schema: public; Owner: -
-- Marks breaker alerts as seen. Returns the number of alerts newly marked.
CREATE OR REPLACE FUNCTION public.agent_chat_mark_alerts_seen(p_alert_ids integer[])
RETURNS integer
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    WITH marked AS (
        UPDATE public.agent_chat_breaker_alerts
        SET seen_at = NOW()
        WHERE id = ANY(p_alert_ids)
          AND seen_at IS NULL
        RETURNING id
    )
    SELECT count(*)::integer FROM marked;
$$;

DO $$
BEGIN
    ALTER FUNCTION public.agent_chat_mark_alerts_seen(integer[]) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping agent_chat_mark_alerts_seen owner assignment: current user is not a superuser';
END $$;

GRANT EXECUTE ON FUNCTION public.agent_chat_mark_alerts_seen(integer[]) TO victoria, "nova-staging";

-- Name: agent_chat_mute_peer(text, integer, text); Type: FUNCTION; Schema: public; Owner: -
-- Lets session_user mute inbound wakes from p_peer for p_minutes (default 60).
-- Records the mute in agent_chat_mutes and sends exactly ONE system notice to p_peer.
CREATE OR REPLACE FUNCTION public.agent_chat_mute_peer(
    p_peer text,
    p_minutes integer DEFAULT 60,
    p_reason text DEFAULT NULL
)
RETURNS timestamptz
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_agent         TEXT;
    v_peer          TEXT;
    v_minutes       INTEGER;
    v_muted_until   TIMESTAMPTZ;
    v_notice        TEXT;
BEGIN
    IF p_peer IS NULL OR trim(p_peer) = '' THEN
        RAISE EXCEPTION 'agent_chat_mute_peer: p_peer cannot be NULL or empty';
    END IF;

    v_agent := session_user;
    v_peer := LOWER(p_peer);

    IF v_agent = v_peer THEN
        RAISE EXCEPTION 'agent_chat_mute_peer: cannot mute yourself';
    END IF;

    v_minutes := COALESCE(p_minutes, 60);
    IF v_minutes <= 0 THEN
        v_minutes := 60;
    END IF;

    v_muted_until := NOW() + (v_minutes || ' minutes')::interval;

    INSERT INTO public.agent_chat_mutes (agent, peer, muted_until, reason, created_at)
    VALUES (v_agent, v_peer, v_muted_until, p_reason, NOW())
    ON CONFLICT (agent, peer) DO UPDATE
    SET muted_until = EXCLUDED.muted_until,
        reason = EXCLUDED.reason,
        created_at = EXCLUDED.created_at;

    -- Send exactly ONE system notice to the peer so they stop sending too.
    -- Formatted as: "<agent> has paused agent_chat with you until <time> UTC[: <reason>]"
    v_notice := format('%s has paused agent_chat with you until %s UTC%s',
        v_agent,
        to_char(v_muted_until AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
        CASE WHEN p_reason IS NOT NULL AND trim(p_reason) <> '' THEN ': ' || trim(p_reason) ELSE '' END
    );

    PERFORM public.send_agent_message(v_agent, v_notice, ARRAY[v_peer]);

    RETURN v_muted_until;
END;
$$;

DO $$
BEGIN
    ALTER FUNCTION public.agent_chat_mute_peer(text, integer, text) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping agent_chat_mute_peer owner assignment: current user is not a superuser';
END $$;

GRANT EXECUTE ON FUNCTION public.agent_chat_mute_peer(text, integer, text) TO victoria, "nova-staging";

-- Name: agent_chat_unmute_peer(text); Type: FUNCTION; Schema: public; Owner: -
-- Lets session_user remove a mute on p_peer before its expiry time.
CREATE OR REPLACE FUNCTION public.agent_chat_unmute_peer(p_peer text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_agent  TEXT;
    v_peer   TEXT;
    v_count  INTEGER;
BEGIN
    IF p_peer IS NULL OR trim(p_peer) = '' THEN
        RAISE EXCEPTION 'agent_chat_unmute_peer: p_peer cannot be NULL or empty';
    END IF;

    v_agent := session_user;
    v_peer := LOWER(p_peer);

    DELETE FROM public.agent_chat_mutes
    WHERE agent = v_agent AND peer = v_peer;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count > 0;
END;
$$;

DO $$
BEGIN
    ALTER FUNCTION public.agent_chat_unmute_peer(text) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping agent_chat_unmute_peer owner assignment: current user is not a superuser';
END $$;

GRANT EXECUTE ON FUNCTION public.agent_chat_unmute_peer(text) TO victoria, "nova-staging";

-- Name: agent_chat_is_muted(text, text); Type: FUNCTION; Schema: public; Owner: -
-- Returns true if p_agent currently has an active, non-expired mute on p_peer.
-- The plugin uses this helper to decide whether an inbound message from p_peer
-- to p_agent should trigger a session wake.
CREATE OR REPLACE FUNCTION public.agent_chat_is_muted(p_agent text, p_peer text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.agent_chat_mutes
        WHERE agent = LOWER(p_agent)
          AND peer = LOWER(p_peer)
          AND muted_until > NOW()
    );
$$;

DO $$
BEGIN
    ALTER FUNCTION public.agent_chat_is_muted(text, text) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping agent_chat_is_muted owner assignment: current user is not a superuser';
END $$;

GRANT EXECUTE ON FUNCTION public.agent_chat_is_muted(text, text) TO victoria, "nova-staging";

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
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_id             INTEGER;
    v_sender         TEXT;
    v_recipients     TEXT[];
    v_expires_at     TIMESTAMPTZ;
    v_recipient      TEXT;
    v_pair_a         TEXT;
    v_pair_b         TEXT;
    v_state          RECORD;
    v_config         RECORD;
    v_window         INTERVAL;
    v_threshold      INTEGER;
    v_original       RECORD;
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

    -- Normalize to lowercase, de-duplicate and sort.
    v_sender := LOWER(p_sender);
    v_recipients := ARRAY(
        SELECT DISTINCT LOWER(r) FROM unnest(p_recipients) AS r ORDER BY LOWER(r)
    );

    -- GUARD: reject self-addressed messages (no legitimate use case; always a typo)
    IF v_sender = ANY(v_recipients) THEN
        RAISE EXCEPTION 'send_agent_message: sender "%" is in the recipient list — agents cannot message themselves (did you mean to address someone else?)', v_sender;
    END IF;

    -- Requirement 6: reply-to authorization BEFORE INSERT. A nonexistent id
    -- fails here (closed-by-default), not via the FK constraint.
    IF p_reply_to IS NOT NULL THEN
        SELECT sender, recipients INTO v_original
        FROM public.agent_chat
        WHERE id = p_reply_to;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'send_agent_message: reply_to % does not reference an existing message', p_reply_to;
        END IF;

        IF NOT (
            session_user = ANY(ARRAY(SELECT LOWER(unnest(v_original.recipients))))
            OR '*' = ANY(v_original.recipients)
            OR session_user = LOWER(v_original.sender)
        ) THEN
            RAISE EXCEPTION 'send_agent_message: reply_to % not authorized (caller is not a recipient, the original was not a broadcast, and the caller is not the original sender)', p_reply_to;
        END IF;
    END IF;

    -- agent-chat#11/#36 DEFECT FIX: sender-side runtime-error-template filter.
    -- Applies unconditionally, before the breaker and before the insert, so it
    -- holds for every caller regardless of recipient count or that agent's own
    -- policy. Quarantine is silent on the bus (return NULL, no row inserted)
    -- and loud in the log -- raising an exception here would itself become a
    -- new error signal on the bus, reproducing the failure mode.
    IF public.agent_chat_is_error_template(p_message) THEN
        INSERT INTO public.agent_chat_suppressed_log (reason, sender, recipients, message_sample)
        VALUES ('sender_filter_error_template', v_sender, v_recipients, left(p_message, 500));
        RETURN NULL;
    END IF;

    -- Compute expiry if TTL provided
    IF p_ttl IS NOT NULL THEN
        v_expires_at := NOW() + p_ttl;
    END IF;

    -- agent-chat#34/#36: alert-only pair breaker.
    -- Counts both directions of an unordered pair together. When the
    -- configurable threshold is crossed inside the rolling window, the message
    -- is still delivered normally and one alert is recorded for the pair/window.
    -- Broadcasts ('*') are not subject to the pair breaker.
    FOREACH v_recipient IN ARRAY v_recipients
    LOOP
        IF v_recipient = '*' THEN
            CONTINUE;
        END IF;

        -- Unordered pair key (alphabetical, lowercase).
        IF v_sender < v_recipient THEN
            v_pair_a := v_sender;
            v_pair_b := v_recipient;
        ELSE
            v_pair_a := v_recipient;
            v_pair_b := v_sender;
        END IF;

        -- Resolve configuration: concrete pair override, else global default.
        SELECT threshold, "window" INTO v_config
        FROM public.agent_chat_breaker_config
        WHERE (pair_a = v_pair_a AND pair_b = v_pair_b)
           OR (pair_a IS NULL AND pair_b IS NULL)
        ORDER BY pair_a NULLS LAST
        LIMIT 1;

        IF NOT FOUND THEN
            v_threshold := 6;
            v_window := interval '5 minutes';
        ELSE
            v_threshold := v_config.threshold;
            v_window := v_config."window";
        END IF;

        SELECT * INTO v_state
        FROM public.agent_chat_breaker_state
        WHERE pair_a = v_pair_a AND pair_b = v_pair_b
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO public.agent_chat_breaker_state
                (pair_a, pair_b, window_start, message_count, alerted, last_message_at)
            VALUES (v_pair_a, v_pair_b, now(), 1, false, now());
        ELSIF v_state.last_message_at < now() - v_window THEN
            -- Window rolled forward: reset.
            UPDATE public.agent_chat_breaker_state
            SET window_start = now(), message_count = 1, alerted = false, last_message_at = now()
            WHERE pair_a = v_pair_a AND pair_b = v_pair_b;
        ELSE
            -- Same window: increment count.
            UPDATE public.agent_chat_breaker_state
            SET message_count = v_state.message_count + 1, last_message_at = now()
            WHERE pair_a = v_pair_a AND pair_b = v_pair_b
            RETURNING * INTO v_state;

            -- Alert once per trip/window when the threshold is crossed.
            -- The message is always delivered; we never suppress.
            IF v_state.message_count >= v_threshold AND NOT v_state.alerted THEN
                INSERT INTO public.agent_chat_breaker_alerts
                    (pair_a, pair_b, window_start, window_end, message_count, threshold)
                VALUES (v_pair_a, v_pair_b, v_state.window_start, v_state.window_start + v_window, v_state.message_count, v_threshold);

                UPDATE public.agent_chat_breaker_state
                SET alerted = true
                WHERE pair_a = v_pair_a AND pair_b = v_pair_b;
            END IF;
        END IF;
    END LOOP;

    -- Atomic insert including reply_to; the enforce trigger allows this because
    -- current_user = 'postgres' inside the SECURITY DEFINER context.
    INSERT INTO public.agent_chat (sender, message, recipients, reply_to, expires_at)
    VALUES (v_sender, p_message, v_recipients, p_reply_to, v_expires_at)
    RETURNING id INTO v_id;

    -- Requirement 6: auto-mark the original message as responded for this
    -- replier. The UPSERT key is (chat_id, lower(session_user)).
    IF p_reply_to IS NOT NULL THEN
        INSERT INTO public.agent_chat_processed (chat_id, agent, status, responded_at)
        VALUES (p_reply_to, session_user, 'responded', NOW())
        ON CONFLICT (chat_id, agent)
        DO UPDATE SET
            status = EXCLUDED.status,
            responded_at = EXCLUDED.responded_at
        WHERE public.agent_chat_processed.status NOT IN ('responded', 'expired', 'handled', 'skipped', 'failed');
    END IF;

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

-- Default privileges for role nova. Wrapped so a non-superuser devtest apply
-- can still succeed.
DO $$
BEGIN
    ALTER DEFAULT PRIVILEGES FOR ROLE nova IN SCHEMA public GRANT SELECT ON TABLES TO argus, athena, coder, conductor, erato, flint, gem, gidget, graybeard, hermes, iris, marcie, newhart, "nova-staging", quill, scout, scribe, ticker;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping nova default privileges: current user is not a superuser';
END $$;

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
GRANT EXECUTE ON FUNCTION public.mark_agent_chat_status(bigint[], text) TO victoria, "nova-staging";

-- agent-chat#34/#36: lock down direct writes on the circuit-breaker control
-- tables the same way agent_chat itself is locked down. The `ALTER DEFAULT
-- PRIVILEGES FOR ROLE postgres ... GRANT DELETE, INSERT, SELECT, UPDATE ON
-- TABLES` block above applies automatically to any new table postgres
-- creates, including these tables -- so without this explicit revoke, every
-- standard agent role would get direct INSERT/UPDATE/DELETE on the breaker
-- state and audit tables, defeating "send_agent_message() is the only write
-- path". SELECT is preserved for diagnosability (loud-in-the-log constraint).
DO $$
DECLARE
    v_roles CONSTANT text[] := ARRAY[
        'argus','athena','coder','conductor','erato','flint','gem','gidget',
        'graybeard','hermes','iris','marcie','nova','quill','scout','scribe',
        'ticker','victoria'
    ];
    v_role text;
    v_table text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'agent_chat_error_templates',
        'agent_chat_breaker_config',
        'agent_chat_breaker_state',
        'agent_chat_breaker_alerts',
        'agent_chat_mutes',
        'agent_chat_suppressed_log'
    ]
    LOOP
        FOREACH v_role IN ARRAY v_roles
        LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
                -- Never revoke from the table owner: the owner must keep its
                -- inherent privileges so migrations (which may INSERT into
                -- these control tables) can run in non-superuser dev/test
                -- environments. In production the owner is postgres, which is
                -- not in v_roles, so this guard has no security effect.
                IF v_role = session_user THEN
                    CONTINUE;
                END IF;
                EXECUTE format(
                    'REVOKE INSERT, UPDATE, DELETE ON TABLE public.%I FROM %I',
                    v_table, v_role
                );
                EXECUTE format(
                    'GRANT SELECT ON TABLE public.%I TO %I',
                    v_table, v_role
                );
            END IF;
        END LOOP;
    END LOOP;
END $$;

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
