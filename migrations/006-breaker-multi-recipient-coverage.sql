-- Migration: agent-chat#18
-- Circuit breaker: close the multi-recipient bypass.
--
-- PROBLEM
-- -------
-- Migration 005 (#11) scoped the bus-side circuit breaker to:
--
--     IF array_length(v_recipients, 1) = 1 THEN
--
-- so multi-recipient, non-broadcast sends were never counted, never tripped,
-- and never suppressed. 005's design notes acknowledged this as a deliberate
-- scope cut ("no occurrence of this failure mode has ever used that shape").
--
-- Verified live on the deployed breaker state after 005 went in:
--
--     sender    | recipient | message_count | tripped
--     graybeard | nova      | 6             | t
--     graybeard | newhart   | 2             | f
--
-- With graybeard->nova ALREADY TRIPPED, a send to ARRAY['nova','newhart']
-- delivers to nova anyway. That makes this not merely a coverage gap but a
-- TRIVIAL CIRCUMVENTION OF AN ACTIVE TRIP, reachable by accident: appending an
-- unrelated second recipient silently defeats a live suppression.
--
-- APPROACH
-- --------
-- Evaluate the breaker PER (sender, recipient) PAIR for every named recipient,
-- regardless of array length, then deliver to the surviving recipients only.
--
--   * A pair that is tripped (and not admitted by the content-novelty escape
--     hatch) is DROPPED FROM THE RECIPIENT LIST for this send.
--   * If EVERY pair is suppressed, the whole send is suppressed: return NULL,
--     insert no agent_chat row -- identical to 005's single-recipient
--     behaviour.
--   * If SOME pairs survive, the message is delivered to exactly those
--     recipients. Rejected alternative: suppress wholesale when any pair is
--     tripped. That would let one noisy pair censor delivery to an unrelated
--     agent -- a worse failure than the one being fixed.
--
-- Broadcast (ARRAY['*']) keeps 005 BLOCKING #3 semantics exactly: a single
-- sender-scoped pair keyed (sender, '*'). It is handled by the same per-pair
-- loop because '*' is just an ordinary key value in
-- agent_chat_breaker_state's (sender, recipient) primary key.
--
-- Per-pair counter semantics are UNCHANGED from 005 and simply now apply to
-- every pair: idle-reset window (15 min), artifact-reference reset,
-- threshold 5 (trips on the 6th), and the content-novelty escape hatch with
-- last_shape frozen at trip time and escape_count capped at 3.
--
-- NO SCHEMA CHANGE. agent_chat_breaker_state's existing (sender, recipient)
-- PK already accommodates one row per pair. No columns added, none removed
-- (ADDITIVE-ONLY constraint respected). agent_chat_suppressed_log gains no
-- new reason value: a per-pair trip still logs reason='loop_breaker' once at
-- trip time, with recipients recording the pair actually suppressed.
--
-- DETERMINISTIC LOCK ORDER
-- ------------------------
-- 005 took FOR UPDATE on a single breaker row, so deadlock was impossible.
-- Locking several rows per call reintroduces the classic ABBA hazard: two
-- concurrent senders whose recipient arrays overlap in opposite orders could
-- deadlock. Recipients are therefore processed in SORTED ORDER, so every
-- caller acquires pair locks in the same sequence. Sorting also makes
-- suppressed-recipient reporting stable for tests.
--
-- Idempotency: CREATE OR REPLACE FUNCTION with the unchanged 5-arg signature;
-- schema_version INSERT uses ON CONFLICT DO NOTHING.

BEGIN;

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
    v_id             INTEGER;
    v_sender         TEXT;
    v_recipients     TEXT[];
    v_delivered      TEXT[] := ARRAY[]::TEXT[];
    v_suppressed     TEXT[] := ARRAY[]::TEXT[];
    v_expires_at     TIMESTAMPTZ;
    v_has_artifact   BOOLEAN;
    v_shape          TEXT;
    v_recipient      TEXT;
    v_state          RECORD;
    v_suppress       BOOLEAN;
    v_window         CONSTANT INTERVAL := interval '15 minutes';
    v_threshold      CONSTANT INTEGER := 5; -- trips on the (threshold+1)th = 6th message
    v_escape_limit   CONSTANT INTEGER := 3; -- max content-novelty escapes per trip epoch
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

    -- Normalize to lowercase, de-duplicate, and SORT.
    -- Sorting gives every caller the same pair-lock acquisition order, which
    -- is what makes the multi-row FOR UPDATE below deadlock-free (agent-chat#18).
    v_sender := LOWER(p_sender);
    v_recipients := ARRAY(
        SELECT DISTINCT LOWER(r) FROM unnest(p_recipients) AS r ORDER BY 1
    );

    -- GUARD: reject self-addressed messages (no legitimate use case; always a typo)
    IF v_sender = ANY(v_recipients) THEN
        RAISE EXCEPTION 'send_agent_message: sender "%" is in the recipient list — agents cannot message themselves (did you mean to address someone else?)', v_sender;
    END IF;

    -- agent-chat#11 DEFECT 1 FIX: sender-side runtime-error-template filter.
    -- Applies unconditionally, before the breaker and before the insert, so it
    -- holds for every caller regardless of recipient count or that agent's own
    -- policy. Quarantine is silent on the bus (return NULL, no row inserted)
    -- and loud in the log -- raising an exception here would itself become a
    -- new error signal on the bus, reproducing the failure mode being fixed.
    IF public.agent_chat_is_error_template(p_message) THEN
        INSERT INTO public.agent_chat_suppressed_log (reason, sender, recipients, message_sample)
        VALUES ('sender_filter_error_template', v_sender, v_recipients, left(p_message, 500));
        RETURN NULL;
    END IF;

    -- Compute expiry if TTL provided
    IF p_ttl IS NOT NULL THEN
        v_expires_at := NOW() + p_ttl;
    END IF;

    -- agent-chat#11 DEFECT 2 FIX / agent-chat#18: bus-side circuit breaker,
    -- now evaluated PER PAIR for every recipient regardless of array length.
    -- 005 restricted this to array_length = 1, which let a multi-recipient
    -- array bypass an already-tripped pair entirely.
    v_has_artifact := public.agent_chat_has_artifact_ref(p_message);
    v_shape := public.agent_chat_message_shape(p_message);

    FOREACH v_recipient IN ARRAY v_recipients
    LOOP
        v_suppress := false;

        SELECT * INTO v_state
        FROM public.agent_chat_breaker_state
        WHERE sender = v_sender AND recipient = v_recipient
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO public.agent_chat_breaker_state
                (sender, recipient, window_start, message_count, tripped, suppressed_count, last_message_at, last_shape, escape_count)
            VALUES (v_sender, v_recipient, now(), 1, false, 0, now(), v_shape, 0);
        ELSIF v_has_artifact OR v_state.last_message_at < now() - v_window THEN
            -- New artifact referenced, or the pair has been quiet longer than
            -- the window: this is not a loop. Reset the counter (and the
            -- content-novelty escape budget/shape tracking).
            UPDATE public.agent_chat_breaker_state
            SET window_start = now(), message_count = 1, tripped = false,
                suppressed_count = 0, last_message_at = now(),
                last_shape = v_shape, escape_count = 0
            WHERE sender = v_sender AND recipient = v_recipient;
        ELSE
            -- Same ordered pair, still inside the idle window, no new artifact.
            UPDATE public.agent_chat_breaker_state
            SET message_count = v_state.message_count + 1,
                last_message_at = now()
            WHERE sender = v_sender AND recipient = v_recipient
            RETURNING * INTO v_state;

            IF v_state.message_count > v_threshold THEN
                -- Content-novelty escape hatch (005 BLOCKING #2). last_shape is
                -- frozen at the shape that TRIPPED the breaker and is
                -- intentionally NOT updated on escape or ordinary suppression:
                -- if it tracked each escapee's own shape, a second differently
                -- shaped message would compare against the first escapee
                -- (always "different") and a literal repeat of the original
                -- storm body would wrongly read as novel.
                IF v_shape IS DISTINCT FROM v_state.last_shape AND v_state.escape_count < v_escape_limit THEN
                    UPDATE public.agent_chat_breaker_state
                    SET escape_count = v_state.escape_count + 1
                    WHERE sender = v_sender AND recipient = v_recipient;
                ELSE
                    IF NOT v_state.tripped THEN
                        -- First message past the threshold for this pair: log
                        -- once, loudly. recipients records the specific pair
                        -- suppressed, not the caller's whole array, so the log
                        -- attributes the trip correctly.
                        INSERT INTO public.agent_chat_suppressed_log
                            (reason, sender, recipients, message_sample, window_message_count)
                        VALUES ('loop_breaker', v_sender, ARRAY[v_recipient], left(p_message, 500), v_state.message_count);

                        UPDATE public.agent_chat_breaker_state
                        SET tripped = true, suppressed_count = 1, last_shape = v_shape
                        WHERE sender = v_sender AND recipient = v_recipient;
                    ELSE
                        -- Already tripped, same shape (or escape budget spent):
                        -- silent on the bus AND on the log (trip already
                        -- recorded); keep the running count for diagnosability.
                        UPDATE public.agent_chat_breaker_state
                        SET suppressed_count = suppressed_count + 1
                        WHERE sender = v_sender AND recipient = v_recipient;
                    END IF;

                    v_suppress := true;
                END IF;
            ELSE
                -- Not yet past threshold -- track shape so a later trip has an
                -- accurate baseline to compare content-novelty against.
                UPDATE public.agent_chat_breaker_state
                SET last_shape = v_shape
                WHERE sender = v_sender AND recipient = v_recipient;
            END IF;
        END IF;

        IF v_suppress THEN
            v_suppressed := array_append(v_suppressed, v_recipient);
        ELSE
            v_delivered := array_append(v_delivered, v_recipient);
        END IF;
    END LOOP;

    -- Every pair suppressed: behave exactly as 005 did for a suppressed
    -- single-recipient send -- no row, no exception, NULL return.
    IF array_length(v_delivered, 1) IS NULL THEN
        RETURN NULL;
    END IF;

    -- Deliver to the surviving recipients only. A tripped pair is removed from
    -- the recipient list rather than censoring the whole send, so one noisy
    -- pair cannot block delivery to an unrelated agent (agent-chat#18).
    INSERT INTO public.agent_chat (sender, message, recipients, reply_to, expires_at)
    VALUES (v_sender, p_message, v_delivered, p_reply_to, v_expires_at)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.send_agent_message(text, text, text[], interval, integer) IS
    'agent-chat#18: inter-agent send with sender-side error-template filter and '
    'per-(sender,recipient) circuit breaker. The breaker is evaluated for EVERY '
    'named recipient regardless of array length -- 005 scoped it to '
    'array_length=1, which let a multi-recipient array bypass an already-'
    'tripped pair. Suppressed pairs are dropped from the recipient list; the '
    'send returns NULL only when every pair is suppressed. Recipients are '
    'sorted so concurrent callers lock breaker rows in a consistent order.';

DO $$
BEGIN
    ALTER FUNCTION public.send_agent_message(text, text, text[], interval, integer) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping send_agent_message owner assignment: current user is not a superuser';
END $$;

INSERT INTO public.schema_version (version, description)
VALUES (6, 'agent-chat#18: circuit breaker evaluated per recipient pair — closes multi-recipient bypass')
ON CONFLICT (version) DO NOTHING;

COMMIT;
