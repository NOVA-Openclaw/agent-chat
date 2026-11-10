-- Migration: agent-chat#34/#36 (DB layer)
-- Alert-only pair breaker, 'skipped' status + applied-id return, and fallback
-- error template.
--
-- Base: main 018f076 (includes agent-chat#23 migrations 006-007). This
-- migration supersedes the unmerged agent-chat#18 branch (PR #19), which
-- targeted the old migration slot 006 and implemented suppression-based
-- breaker behaviour. The new design (I)ruid 2026-11-03 05:08Z) is:
--
--   * Count both directions of an unordered pair together.
--   * Do NOT reset the count on #N patterns.
--   * Configurable threshold/window (default 6 messages in 5 minutes).
--   * When the threshold is crossed, deliver the message normally and record
--     one alert per trip per pair/window.
--   * The breaker NEVER suppresses, pauses, or blocks delivery.
--
-- mark_agent_chat_status changes:
--   * Accepts 'skipped' in addition to 'handled' and 'expired'.
--   * Returns the ids actually applied as bigint[] (backwards compatible:
--     raw SQL callers that ignore the result still work).
--   * Never downgrades a message already in a terminal status.
--
-- Idempotency: all CREATE/DROP IF EXISTS/ALTER ... IF NOT EXISTS operations
-- are safe to replay.

BEGIN;

-- ─── agent_chat_processed: skipped timestamp ───────────────────────────────
ALTER TABLE public.agent_chat_processed
    ADD COLUMN IF NOT EXISTS skipped_at timestamp;

-- ─── Error-template denylist: gateway fallback text (#36) ──────────────────
INSERT INTO public.agent_chat_error_templates (pattern, description)
VALUES (
    'The tool run finished, but no final summary was produced',
    'agent-chat#36: gateway fallback text for silent/empty final turns; must never be delivered to agent_chat peers'
)
ON CONFLICT ON CONSTRAINT agent_chat_error_templates_pattern_key DO NOTHING;

-- ─── Breaker configuration table ───────────────────────────────────────────
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

INSERT INTO public.agent_chat_breaker_config (pair_a, pair_b, threshold, "window")
VALUES (NULL, NULL, 6, interval '5 minutes')
ON CONFLICT ON CONSTRAINT agent_chat_breaker_config_pair_key DO NOTHING;

-- ─── Breaker state: migrate from ordered (sender, recipient) to unordered pair
-- The new design counts both directions together, so we collapse the old
-- ordered rows into one row per sorted pair. Broadcast rows (recipient='*')
-- are not migrated because the new breaker does not scope to broadcasts.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'agent_chat_breaker_state'
          AND column_name = 'sender'
    ) THEN
        CREATE TABLE public.agent_chat_breaker_state_new (
            pair_a text NOT NULL,
            pair_b text NOT NULL,
            window_start timestamptz NOT NULL DEFAULT now(),
            message_count integer NOT NULL DEFAULT 0,
            alerted boolean NOT NULL DEFAULT false,
            last_message_at timestamptz NOT NULL DEFAULT now(),
            CONSTRAINT agent_chat_breaker_state_new_pkey PRIMARY KEY (pair_a, pair_b),
            CONSTRAINT agent_chat_breaker_state_new_pair_order CHECK (pair_a < pair_b)
        );

        INSERT INTO public.agent_chat_breaker_state_new
            (pair_a, pair_b, window_start, message_count, alerted, last_message_at)
        SELECT
            LEAST(sender, recipient),
            GREATEST(sender, recipient),
            MIN(window_start),
            SUM(message_count),
            BOOL_OR(tripped),
            MAX(last_message_at)
        FROM public.agent_chat_breaker_state
        WHERE recipient <> '*'
        GROUP BY LEAST(sender, recipient), GREATEST(sender, recipient);

        DROP TABLE public.agent_chat_breaker_state;
        ALTER TABLE public.agent_chat_breaker_state_new RENAME TO agent_chat_breaker_state;
        ALTER TABLE public.agent_chat_breaker_state RENAME CONSTRAINT agent_chat_breaker_state_new_pkey TO agent_chat_breaker_state_pkey;
        ALTER TABLE public.agent_chat_breaker_state RENAME CONSTRAINT agent_chat_breaker_state_new_pair_order TO agent_chat_breaker_state_pair_order;
    ELSE
        -- Fresh target shape already present (e.g. partial apply); ensure table.
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
    END IF;
END $$;

COMMENT ON TABLE public.agent_chat_breaker_state IS
    'agent-chat#34/#36: per unordered pair rolling-window message counter. '
    'alerted=true means an alert has already been emitted for the current '
    'window; it resets to false when the window rolls forward.';

-- ─── Breaker alert log ─────────────────────────────────────────────────────
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

-- ─── NOTIFY on new breaker alerts ──────────────────────────────────────────
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

-- ─── Mute table ────────────────────────────────────────────────────────────
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

-- ─── Update send_agent_message() with alert-only breaker ───────────────────
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
    IF LOWER(p_sender) != session_user THEN
        RAISE EXCEPTION 'send_agent_message: sender must match session_user (got % but connected as %)', p_sender, session_user;
    END IF;

    IF p_message IS NULL OR trim(p_message) = '' THEN
        RAISE EXCEPTION 'send_agent_message: message cannot be empty';
    END IF;

    IF p_recipients IS NULL OR array_length(p_recipients, 1) IS NULL THEN
        RAISE EXCEPTION 'send_agent_message: recipients cannot be NULL or empty — use ARRAY[''*''] for broadcast';
    END IF;

    v_sender := LOWER(p_sender);
    v_recipients := ARRAY(
        SELECT DISTINCT LOWER(r) FROM unnest(p_recipients) AS r ORDER BY LOWER(r)
    );

    IF v_sender = ANY(v_recipients) THEN
        RAISE EXCEPTION 'send_agent_message: sender "%" is in the recipient list — agents cannot message themselves (did you mean to address someone else?)', v_sender;
    END IF;

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

    IF public.agent_chat_is_error_template(p_message) THEN
        INSERT INTO public.agent_chat_suppressed_log (reason, sender, recipients, message_sample)
        VALUES ('sender_filter_error_template', v_sender, v_recipients, left(p_message, 500));
        RETURN NULL;
    END IF;

    IF p_ttl IS NOT NULL THEN
        v_expires_at := NOW() + p_ttl;
    END IF;

    FOREACH v_recipient IN ARRAY v_recipients
    LOOP
        IF v_recipient = '*' THEN
            CONTINUE;
        END IF;

        IF v_sender < v_recipient THEN
            v_pair_a := v_sender;
            v_pair_b := v_recipient;
        ELSE
            v_pair_a := v_recipient;
            v_pair_b := v_sender;
        END IF;

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
            UPDATE public.agent_chat_breaker_state
            SET window_start = now(), message_count = 1, alerted = false, last_message_at = now()
            WHERE pair_a = v_pair_a AND pair_b = v_pair_b;
        ELSE
            UPDATE public.agent_chat_breaker_state
            SET message_count = v_state.message_count + 1, last_message_at = now()
            WHERE pair_a = v_pair_a AND pair_b = v_pair_b
            RETURNING * INTO v_state;

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

    INSERT INTO public.agent_chat (sender, message, recipients, reply_to, expires_at)
    VALUES (v_sender, p_message, v_recipients, p_reply_to, v_expires_at)
    RETURNING id INTO v_id;

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

DO $$
BEGIN
    ALTER FUNCTION public.send_agent_message(text, text, text[], interval, integer) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    IF coalesce(current_setting('agent_chat.devtest', true),'') = 'on' THEN
        RAISE NOTICE 'Skipping send_agent_message owner assignment: current user is not a superuser';
    ELSE
        RAISE;
    END IF;
END $$;

-- agent-chat#39: no named EXECUTE grants; PUBLIC EXECUTE remains in effect.

-- ─── Update mark_agent_chat_status(): add 'skipped' and return applied ids ──
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
        PERFORM p_status::public.agent_chat_status;
        RAISE EXCEPTION 'mark_agent_chat_status: status must be "handled", "expired" or "skipped" (got %)', p_status;
    END IF;

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
    IF coalesce(current_setting('agent_chat.devtest', true),'') = 'on' THEN
        RAISE NOTICE 'Skipping mark_agent_chat_status owner assignment: current user is not a superuser';
    ELSE
        RAISE;
    END IF;
END $$;

-- agent-chat#39: no named EXECUTE grants; PUBLIC EXECUTE remains in effect.

-- ─── New alert read/mark functions ─────────────────────────────────────────
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
    IF coalesce(current_setting('agent_chat.devtest', true),'') = 'on' THEN
        RAISE NOTICE 'Skipping agent_chat_pending_alerts owner assignment: current user is not a superuser';
    ELSE
        RAISE;
    END IF;
END $$;

-- agent-chat#39: no named EXECUTE grants; PUBLIC EXECUTE remains in effect.

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
    IF coalesce(current_setting('agent_chat.devtest', true),'') = 'on' THEN
        RAISE NOTICE 'Skipping agent_chat_mark_alerts_seen owner assignment: current user is not a superuser';
    ELSE
        RAISE;
    END IF;
END $$;

-- agent-chat#39: no named EXECUTE grants; PUBLIC EXECUTE remains in effect.

-- ─── Mute functions ────────────────────────────────────────────────────────
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
    IF coalesce(current_setting('agent_chat.devtest', true),'') = 'on' THEN
        RAISE NOTICE 'Skipping agent_chat_mute_peer owner assignment: current user is not a superuser';
    ELSE
        RAISE;
    END IF;
END $$;

-- agent-chat#39: no named EXECUTE grants; PUBLIC EXECUTE remains in effect.

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
    IF coalesce(current_setting('agent_chat.devtest', true),'') = 'on' THEN
        RAISE NOTICE 'Skipping agent_chat_unmute_peer owner assignment: current user is not a superuser';
    ELSE
        RAISE;
    END IF;
END $$;

-- agent-chat#39: no named EXECUTE grants; PUBLIC EXECUTE remains in effect.

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
    IF coalesce(current_setting('agent_chat.devtest', true),'') = 'on' THEN
        RAISE NOTICE 'Skipping agent_chat_is_muted owner assignment: current user is not a superuser';
    ELSE
        RAISE;
    END IF;
END $$;

-- agent-chat#39: no named EXECUTE grants; PUBLIC EXECUTE remains in effect.

-- ─── Lock down direct writes on new breaker control tables ─────────────────
-- agent-chat#39: discover roles that already have bus access instead of
-- hardcoding a roster.
DO $$
DECLARE
    v_role text;
    v_table text;
BEGIN
    FOR v_role IN
        SELECT DISTINCT grantee::regrole::text
        FROM information_schema.role_table_grants
        WHERE table_schema = 'public'
          AND table_name = 'agent_chat'
          AND privilege_type = 'SELECT'
          AND grantee NOT IN ('PUBLIC', 'postgres', session_user)
        UNION
        SELECT DISTINCT grantee::regrole::text
        FROM information_schema.role_routine_grants
        WHERE routine_schema = 'public'
          AND routine_name = 'send_agent_message'
          AND privilege_type = 'EXECUTE'
          AND grantee NOT IN ('PUBLIC', 'postgres', session_user)
    LOOP
        -- Never revoke from the table owner: migrations may INSERT into
        -- these control tables and must keep the owner's privileges in
        -- non-superuser dev/test environments. In production the owner is
        -- postgres, which is not discovered by the query above.
        IF v_role = session_user OR v_role = 'postgres' THEN
            CONTINUE;
        END IF;
        FOREACH v_table IN ARRAY ARRAY[
            'agent_chat_error_templates',
            'agent_chat_breaker_config',
            'agent_chat_breaker_state',
            'agent_chat_breaker_alerts',
            'agent_chat_mutes',
            'agent_chat_suppressed_log'
        ]
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

-- ─── Version handshake ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);

INSERT INTO public.schema_version (version, description)
VALUES (8, 'agent-chat#34/#36: alert-only pair breaker, skipped status + applied ids, agent mute, fallback template')
ON CONFLICT (version) DO NOTHING;

-- agent-chat#39: no named default privileges. Per-agent grants are applied
-- by register-agent.sh; bus functions remain executable via PUBLIC.

COMMIT;
