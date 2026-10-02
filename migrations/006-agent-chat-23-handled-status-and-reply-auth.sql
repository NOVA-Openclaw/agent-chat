-- Migration: agent-chat#23 (Chunk A)
-- Add terminal 'handled' status, mark_agent_chat_status(), and reply-to
-- authorization with auto-mark-responded in send_agent_message().
--
-- Idempotency: all CREATE/DROP IF EXISTS/ALTER TYPE ADD VALUE IF NOT EXISTS
-- operations are safe to replay. The enum value addition is in its own
-- migration file so it is committed before any later migration uses it.

BEGIN;

-- ─── Requirement 4 schema: additive enum value ─────────────────────────────
-- ALTER TYPE ... ADD VALUE is not transactional for the new value's
-- usability inside the same transaction; keeping it in a dedicated migration
-- file guarantees the value is committed before any code tries to use it.
ALTER TYPE public.agent_chat_status ADD VALUE IF NOT EXISTS 'handled';

-- ─── Requirement 6 schema: timestamp columns for terminal transitions ─────
-- Additive-only: new columns for handled_at / expired_at transitions.
ALTER TABLE public.agent_chat_processed
    ADD COLUMN IF NOT EXISTS handled_at timestamp,
    ADD COLUMN IF NOT EXISTS expired_at timestamp;

-- ─── Requirement 6: mark_agent_chat_status ────────────────────────────────
-- SECURITY DEFINER function that lets an agent mark its own rows as terminal
-- ('handled' or 'expired'). Cross-agent ids and missing ids are silently
-- ignored (partial success, no error). Terminal statuses never regress.
DROP FUNCTION IF EXISTS public.mark_agent_chat_status(bigint[], text);

CREATE OR REPLACE FUNCTION public.mark_agent_chat_status(
    p_chat_ids bigint[],
    p_status text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF p_chat_ids IS NULL THEN
        RAISE EXCEPTION 'mark_agent_chat_status: p_chat_ids cannot be NULL';
    END IF;

    IF p_status IS NULL OR trim(p_status) = '' THEN
        RAISE EXCEPTION 'mark_agent_chat_status: p_status cannot be NULL or empty';
    END IF;

    IF p_status NOT IN ('handled', 'expired') THEN
        -- Valid enum labels that are not allowed get our own clear error;
        -- non-existent labels (e.g. 'foo') fail naturally with the PostgreSQL
        -- invalid-input-value error for the enum type.
        PERFORM p_status::public.agent_chat_status;
        RAISE EXCEPTION 'mark_agent_chat_status: status must be "handled" or "expired" (got %)', p_status;
    END IF;

    -- Only touch rows owned by the calling session user, and never flip an
    -- already-terminal status. Missing ids or other agents' rows are ignored.
    IF p_status = 'handled' THEN
        UPDATE public.agent_chat_processed
        SET status = 'handled',
            handled_at = NOW()
        WHERE chat_id = ANY(p_chat_ids)
          AND agent = session_user
          AND status NOT IN ('responded', 'expired', 'handled', 'skipped', 'failed');
    ELSIF p_status = 'expired' THEN
        UPDATE public.agent_chat_processed
        SET status = 'expired',
            expired_at = NOW()
        WHERE chat_id = ANY(p_chat_ids)
          AND agent = session_user
          AND status NOT IN ('responded', 'expired', 'handled', 'skipped', 'failed');
    END IF;
END;
$$;

DO $$
BEGIN
    ALTER FUNCTION public.mark_agent_chat_status(bigint[], text) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping mark_agent_chat_status owner assignment: current user is not a superuser';
END $$;

-- ─── Requirement 6: send_agent_message reply-to authorization + auto-mark ───
-- Drop all known historical signatures so a fresh apply leaves exactly one
-- public.send_agent_message behind, matching migration 001's idempotent
-- pattern. The signature is unchanged; only the body gains authorization
-- before the INSERT and an auto-mark-responded UPSERT after success.
DROP FUNCTION IF EXISTS public.send_agent_message(text, text, text[]);
DROP FUNCTION IF EXISTS public.send_agent_message(text, text, text[], interval);
DROP FUNCTION IF EXISTS public.send_agent_message(text, text, text[], interval, integer);

CREATE OR REPLACE FUNCTION public.send_agent_message(
    p_sender     text,
    p_message    text,
    p_recipients text[],
    p_ttl        interval DEFAULT NULL::interval,
    p_reply_to   integer DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_id             INTEGER;
    v_sender         TEXT;
    v_recipients     TEXT[];
    v_expires_at     TIMESTAMPTZ;
    v_has_artifact   BOOLEAN;
    v_shape          TEXT;
    v_recipient      TEXT;
    v_state          RECORD;
    v_escaped        BOOLEAN := false;
    v_window         CONSTANT INTERVAL := interval '15 minutes';
    v_threshold      CONSTANT INTEGER := 5;
    v_escape_limit   CONSTANT INTEGER := 3;
    v_original       RECORD;
BEGIN
    -- Validate sender matches the actual connected database user.
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

    -- GUARD: reject self-addressed messages
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

    -- agent-chat#11 DEFECT 1 FIX: sender-side runtime-error-template filter.
    IF public.agent_chat_is_error_template(p_message) THEN
        INSERT INTO public.agent_chat_suppressed_log (reason, sender, recipients, message_sample)
        VALUES ('sender_filter_error_template', v_sender, v_recipients, left(p_message, 500));
        RETURN NULL;
    END IF;

    -- Compute expiry if TTL provided
    IF p_ttl IS NOT NULL THEN
        v_expires_at := NOW() + p_ttl;
    END IF;

    -- agent-chat#11 DEFECT 2 FIX: bus-side circuit breaker.
    IF array_length(v_recipients, 1) = 1 THEN
        v_recipient := v_recipients[1];
        v_has_artifact := public.agent_chat_has_artifact_ref(p_message);
        v_shape := public.agent_chat_message_shape(p_message);

        SELECT * INTO v_state
        FROM public.agent_chat_breaker_state
        WHERE sender = v_sender AND recipient = v_recipient
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO public.agent_chat_breaker_state
                (sender, recipient, window_start, message_count, tripped, suppressed_count, last_message_at, last_shape, escape_count)
            VALUES (v_sender, v_recipient, now(), 1, false, 0, now(), v_shape, 0);
        ELSIF v_has_artifact OR v_state.last_message_at < now() - v_window THEN
            UPDATE public.agent_chat_breaker_state
            SET window_start = now(), message_count = 1, tripped = false,
                suppressed_count = 0, last_message_at = now(),
                last_shape = v_shape, escape_count = 0
            WHERE sender = v_sender AND recipient = v_recipient;
        ELSE
            UPDATE public.agent_chat_breaker_state
            SET message_count = v_state.message_count + 1,
                last_message_at = now()
            WHERE sender = v_sender AND recipient = v_recipient
            RETURNING * INTO v_state;

            IF v_state.message_count > v_threshold THEN
                IF v_shape IS DISTINCT FROM v_state.last_shape AND v_state.escape_count < v_escape_limit THEN
                    UPDATE public.agent_chat_breaker_state
                    SET escape_count = v_state.escape_count + 1
                    WHERE sender = v_sender AND recipient = v_recipient;
                    v_escaped := true;
                ELSE
                    IF NOT v_state.tripped THEN
                        INSERT INTO public.agent_chat_suppressed_log
                            (reason, sender, recipients, message_sample, window_message_count)
                        VALUES ('loop_breaker', v_sender, v_recipients, left(p_message, 500), v_state.message_count);

                        UPDATE public.agent_chat_breaker_state
                        SET tripped = true, suppressed_count = 1, last_shape = v_shape
                        WHERE sender = v_sender AND recipient = v_recipient;
                    ELSE
                        UPDATE public.agent_chat_breaker_state
                        SET suppressed_count = suppressed_count + 1
                        WHERE sender = v_sender AND recipient = v_recipient;
                    END IF;

                    RETURN NULL;
                END IF;
            ELSE
                UPDATE public.agent_chat_breaker_state
                SET last_shape = v_shape
                WHERE sender = v_sender AND recipient = v_recipient;
            END IF;
        END IF;
    END IF;

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

DO $$
BEGIN
    ALTER FUNCTION public.send_agent_message(text, text, text[], interval, integer) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping send_agent_message owner assignment: current user is not a superuser';
END $$;

-- Preserve explicit EXECUTE grants for cross-ecosystem callers.
GRANT EXECUTE ON FUNCTION public.send_agent_message(text, text, text[], interval, integer) TO victoria, "nova-staging";

-- mark_agent_chat_status is intended for all agent roles; default PUBLIC
-- EXECUTE is left in place per the repo convention (schema.sql documents
-- required EXECUTE without revoking PUBLIC access). Explicit grants are
-- added for cross-ecosystem and special roles for clarity.
GRANT EXECUTE ON FUNCTION public.mark_agent_chat_status(bigint[], text) TO victoria, "nova-staging";

-- Version handshake.
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);

INSERT INTO public.schema_version (version, description)
VALUES (6, 'agent-chat#23: handled status, mark_agent_chat_status(), reply-to authorization')
ON CONFLICT (version) DO NOTHING;

COMMIT;
