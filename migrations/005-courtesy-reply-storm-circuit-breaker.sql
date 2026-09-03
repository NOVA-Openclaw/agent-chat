-- Migration: agent-chat#11
-- Courtesy-reply storm circuit breaker.
--
-- Two independent defects, per the issue's root-cause analysis (4 occurrences
-- as of 2026-09-01, up to 738 msgs/24h and a 625-msg/15h mutual-saturation
-- ladder):
--
--   1. SENDER-SIDE FILTER (primary): runtime error bodies and agent-authored
--      "nothing actionable" status notices are never worth sending as an
--      inter-agent message. Quarantine them at the send_agent_message() write
--      path itself so the guard holds for every caller regardless of that
--      agent's own bootstrap/politeness policy.
--   2. BUS-SIDE CIRCUIT BREAKER (defense in depth, and per occurrence 4 the
--      load-bearing half when both ends of an exchange are degraded and
--      cannot apply per-agent judgement at all): if the same ordered
--      sender->recipient pair exchanges more than N messages inside a
--      rolling idle-reset window with no newly referenced artifact
--      (issue/PR/task/file id), suppress further sends and log once.
--
-- Design notes:
--   * Suppression is loud in the log, silent on the bus: a suppressed send
--     returns NULL (no agent_chat row, no exception -- raising here would
--     itself be a new error signal on the bus, which is the exact failure
--     mode being fixed) and writes one row to agent_chat_suppressed_log.
--   * The breaker window is idle-reset, not a fixed bucket: as long as
--     messages keep arriving faster than v_window apart, the counter keeps
--     accumulating (this is what makes a sustained storm trip and stay
--     tripped); a genuine pause longer than v_window, or a message that
--     references a new artifact, resets the pair's counter to 1.
--   * N=5 (trips on message #6) and window=15 minutes. Reasoning: occurrence
--     3 was ~4 round trips (8 messages) in 7 minutes -- N=5 stops that shape
--     well before it reaches 8. Occurrence 4 was sustained at roughly one
--     message per 3-6 minutes per side for 15+ hours -- a 15-minute idle
--     window never lets that pair's counter reset on its own, so it trips
--     once near the start and stays tripped for the duration of the storm.
--     5 is intentionally generous: ordinary back-and-forth exchanges
--     (a question, an answer, a clarifying follow-up) resolve in 2-3 turns
--     and never approach the threshold.
--   * New object writes are protected the same way as existing bus tables:
--     only send_agent_message() (SECURITY DEFINER, owned by postgres) writes
--     agent_chat_breaker_state and agent_chat_suppressed_log. Because
--     schema.sql's `ALTER DEFAULT PRIVILEGES FOR ROLE postgres ... GRANT
--     DELETE, INSERT, SELECT, UPDATE ON TABLES` applies automatically to any
--     new table postgres creates, this migration explicitly REVOKEs
--     INSERT/UPDATE/DELETE from the standard agent role list on all three new
--     tables immediately after creation, leaving SELECT only for
--     diagnosability (verified empirically against a live default-privileges
--     database; this is not a hypothetical risk).
--   * agent_chat_error_templates is an operator-editable denylist (additive
--     rows only per the ADDITIVE-ONLY schema-change constraint; no columns
--     removed from any existing table). It is intentionally NOT hardcoded
--     into the function body so a future occurrence's new template string can
--     be added with an INSERT instead of another migration.
--
-- Idempotency: all CREATE TABLE use IF NOT EXISTS; the template seed uses
-- ON CONFLICT on a UNIQUE(pattern) constraint; CREATE OR REPLACE FUNCTION is
-- idempotent; REVOKE is idempotent (revoking a privilege that is not held is
-- a no-op, not an error).
--
-- ─── 2026-09-03 QA remediation (Gem adversarial review, PR #12) ────────────
-- Three BLOCKING defects were found by live testing against real PG 16.15 and
-- fixed in place (this migration has not shipped, so it is amended directly
-- rather than adding a migration 006):
--
--   BLOCKING #1 -- sender-side filter false positives. The original
--   agent_chat_is_error_template() was an unanchored `~*` substring match: any
--   message that merely QUOTED or paraphrased a known template string --
--   including a genuine error report asking for help, a peer-investigation
--   request, an all-caps restatement, or a third-party observation about
--   another agent's degraded state -- was silently swallowed. Fixed by
--   requiring the pattern to constitute essentially the ENTIRE message
--   (normalized coverage_ratio >= 0.25 and the match must start within the
--   first 5 normalized characters), not merely appear somewhere inside it.
--   See agent_chat_normalize_for_match() and the updated
--   agent_chat_is_error_template().
--
--   BLOCKING #2 -- a tripped breaker suppressed ALL subsequent traffic for
--   the pair indefinitely, including a genuinely new, unrelated, urgent
--   message ("URGENT: production database is down" was silently dropped
--   right after a storm of "still working on it" pings tripped the breaker).
--   Fixed with a content-novelty escape hatch: agent_chat_message_shape()
--   reduces a body to lowercase, digit-stripped, whitespace-collapsed text so
--   that "Note 1 concludes nothing" and "Note 2 concludes nothing" are the
--   SAME shape (still capped -- this is what a real storm looks like) but
--   "URGENT: production database is down" is a DIFFERENT shape. A message
--   whose shape differs from the shape currently driving the trip is let
--   through once the pair's escape_count budget (3, generous but bounded so
--   varying the wording every time cannot become an infinite bypass) is not
--   exhausted. The existing idle-window reset (TC-115) remains the
--   time-based liveness mechanism; this adds a content-based one for
--   messages that cannot wait out the window.
--
--   BLOCKING #3 -- broadcasts (`ARRAY['*']`) bypassed the breaker entirely;
--   10 consecutive non-substantive broadcasts all delivered with zero
--   throttling. Fixed by extending the breaker to broadcasts, keyed on
--   (sender, '*') -- a sender-scoped breaker, since a broadcast has no
--   well-defined ordered pair with a single counterparty. This required no
--   schema change: agent_chat_breaker_state's existing (sender, recipient)
--   primary key already accommodates recipient = '*' as an ordinary key
--   value. The scoping condition changed from `array_length(v_recipients,1)
--   = 1 AND v_recipients[1] != '*'` to `array_length(v_recipients,1) = 1`
--   (multi-recipient, non-broadcast sends -- e.g. an explicit list of several
--   named agents -- remain out of scope, unchanged from the original design;
--   no occurrence of this failure mode has ever used that shape).
--
--   ACCEPTED RISK (non-blocking, called out per QA review): agent_chat_has_
--   artifact_ref()'s `#\d+` clause is context-free -- "room #12" or "rule #1"
--   inside an otherwise non-substantive message resets the breaker's counter
--   just as a real issue/PR reference would. This is an intentional
--   recall-over-precision tradeoff: a false "has artifact" only costs one
--   early reset of a pair's counter, whereas a false "no artifact" is exactly
--   what lets a real storm run unchecked. Not redesigned per QA guidance;
--   documented here and in the PR body as an accepted risk.
BEGIN;

-- ─── Sender-side filter: error-template denylist ───────────────────────────

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
    '(logged to agent_chat_suppressed_log, never inserted into agent_chat). '
    'Additive: add new occurrences via INSERT, do not delete historical rows -- '
    'set active=false to retire a pattern instead.';

INSERT INTO public.agent_chat_error_templates (pattern, description) VALUES
    ('something went wrong while processing your request',
     'agent-chat#11 occurrences 2-3: generic runtime-failure UI affordance, never content for another agent to reason about'),
    ('context is too large and auto-compaction could not recover this turn',
     'agent-chat#11 occurrence 4: runtime auto-compaction-failure template'),
    ('context is saturated and cannot process turns',
     'agent-chat#11 occurrence 4: agent-authored saturation notice -- self-describes as non-actionable and sends anyway')
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
-- not merely appear somewhere inside it:
--   * coverage_ratio = normalized(pattern) length / normalized(message) length
--     must be >= 0.25 -- the pattern must be the dominant content of the
--     message, not a small fragment quoted inside a much longer, substantive
--     body.
--   * the match must start within the first 5 normalized characters of the
--     message -- tolerance for a leading emoji/glyph that normalization has
--     already collapsed to nothing, or a short lead-in token like "The " --
--     while still rejecting a message that leads with substantive framing
--     before reaching the template text.
-- Both known real occurrences (the runtime UI affordance strings, bare or
-- with a trailing "try again"/"/compact" instruction) satisfy both
-- conditions; every constructed false positive found in QA fails at least
-- one (see tests/test_agent_chat_installer.bats TC-118).
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

-- ─── Bus-side circuit breaker: artifact-reference detector ─────────────────

CREATE OR REPLACE FUNCTION public.agent_chat_has_artifact_ref(p_message text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    -- Matches: "#123" (issue/PR shorthand), "issue 12"/"issue-12"/"issue_12"/
    -- "issue#12" (and the same for pr/task), or a path-like file reference
    -- ("dir/file.ext", "dir\file.ext"). Deliberately loose (recall over
    -- precision) -- a false "has artifact" only means the breaker resets one
    -- exchange early, whereas a false "no artifact" is what causes storms.
    --
    -- ACCEPTED RISK (2026-09-03 QA remediation, Gem QA, non-blocking): the
    -- `#\d+` clause is context-free -- "room #12" or "rule #1" inside an
    -- otherwise non-substantive message resets the counter just as a real
    -- issue/PR reference would. Not redesigned per QA guidance (the
    -- recall-over-precision tradeoff is intentional and was explicitly
    -- accepted); documented here and in the PR body.
    SELECT p_message ~* '#\d+|\y(?:issue|pr|task)[-_ ]*#?\d+\y|[/\\][\w.-]+\.[a-zA-Z0-9]{1,6}\y';
$$;

COMMENT ON FUNCTION public.agent_chat_has_artifact_ref(text) IS
    'agent-chat#11: true if p_message references an issue/PR/task number or a '
    'file path. Used by the circuit breaker to reset a sender/recipient pair''s '
    'window when new, substantive content appears. ACCEPTED RISK: #\d+ is '
    'context-free ("room #12" also matches) -- intentional recall-over-'
    'precision tradeoff, not redesigned per QA guidance (2026-09-03).';

-- Name: agent_chat_message_shape(text); Type: FUNCTION; Schema: public; Owner: -
-- agent-chat#11 BLOCKING #2 fix (2026-09-03 QA remediation): normalized
-- "shape" of a message body used by the circuit breaker's content-novelty
-- escape check -- lowercase, digits removed (so "note 1"/"note 2" collapse to
-- the same shape), non-letters collapsed to single spaces, trimmed. Two
-- messages with the same shape are treated as the same repeating storm body
-- even if a counter/id differs; a different shape is treated as genuinely new
-- content and can escape a tripped breaker (see send_agent_message()).
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

-- ─── Bus-side circuit breaker: state and audit tables ──────────────────────

CREATE TABLE IF NOT EXISTS public.agent_chat_breaker_state (
    sender text NOT NULL,
    recipient text NOT NULL,
    window_start timestamptz NOT NULL DEFAULT now(),
    message_count integer NOT NULL DEFAULT 0,
    tripped boolean NOT NULL DEFAULT false,
    suppressed_count integer NOT NULL DEFAULT 0,
    last_message_at timestamptz NOT NULL DEFAULT now(),
    last_shape text NOT NULL DEFAULT '',
    escape_count integer NOT NULL DEFAULT 0,
    CONSTRAINT agent_chat_breaker_state_pkey PRIMARY KEY (sender, recipient)
);

-- Idempotent column add for any environment where this migration was applied
-- before the 2026-09-03 QA remediation added these two columns (defense in
-- depth; this migration has not shipped, so no live database should hit this
-- path, but ADD COLUMN IF NOT EXISTS costs nothing and removes any ordering
-- hazard).
ALTER TABLE public.agent_chat_breaker_state ADD COLUMN IF NOT EXISTS last_shape text NOT NULL DEFAULT '';
ALTER TABLE public.agent_chat_breaker_state ADD COLUMN IF NOT EXISTS escape_count integer NOT NULL DEFAULT 0;

COMMENT ON TABLE public.agent_chat_breaker_state IS
    'agent-chat#11: per ordered (sender, recipient) rolling-window counter for '
    'the courtesy-reply-storm circuit breaker. recipient may be ''*'' -- a '
    'sender-scoped breaker for broadcasts, since a broadcast has no single '
    'well-defined counterparty. message_count resets to 1 when the pair has '
    'been idle longer than the breaker window or a message references a new '
    'artifact; otherwise it accumulates and, once it exceeds the threshold, '
    'tripped flips true and further sends for the pair are suppressed '
    '(suppressed_count keeps counting) unless the content-novelty escape hatch '
    '(last_shape/escape_count) admits a genuinely new-shaped body.';

COMMENT ON COLUMN public.agent_chat_breaker_state.last_shape IS
    'agent-chat#11 BLOCKING #2 fix: agent_chat_message_shape() of the most '
    'recently processed message for this pair. A subsequent message whose '
    'shape differs is treated as content-novel and may escape a tripped '
    'breaker (bounded by escape_count).';

COMMENT ON COLUMN public.agent_chat_breaker_state.escape_count IS
    'agent-chat#11 BLOCKING #2 fix: number of content-novelty escapes granted '
    'since the last full reset. Capped at 3 (generous but bounded) so varying '
    'the wording every message cannot become an infinite bypass of the '
    'breaker.';

CREATE TABLE IF NOT EXISTS public.agent_chat_suppressed_log (
    id SERIAL PRIMARY KEY,
    suppressed_at timestamptz NOT NULL DEFAULT now(),
    reason text NOT NULL,
    sender text NOT NULL,
    recipients text[] NOT NULL,
    message_sample text NOT NULL,
    window_message_count integer,
    CONSTRAINT agent_chat_suppressed_log_reason_check
        CHECK (reason IN ('sender_filter_error_template', 'loop_breaker'))
);

COMMENT ON TABLE public.agent_chat_suppressed_log IS
    'agent-chat#11: audit trail for every message send_agent_message() refused '
    'to deliver. reason=sender_filter_error_template is logged once per refused '
    'send (the filter is stateless); reason=loop_breaker is logged once per trip '
    '(the moment a pair crosses the threshold) -- ongoing suppression while '
    'still tripped is tracked via agent_chat_breaker_state.suppressed_count, not '
    'by inserting a row per suppressed message, so a live storm cannot itself '
    'flood this table.';

CREATE INDEX IF NOT EXISTS idx_agent_chat_suppressed_log_time
    ON public.agent_chat_suppressed_log (suppressed_at DESC);

-- ─── send_agent_message(): wire in both defenses ───────────────────────────
-- Signature is unchanged (still the 5-arg form from migration 001), so
-- CREATE OR REPLACE is sufficient -- no defensive DROP FUNCTION needed since
-- there is no overload-ambiguity risk from adding a differently-shaped
-- signature (unlike migration 001's arg-count change).

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
    v_expires_at     TIMESTAMPTZ;
    v_has_artifact   BOOLEAN;
    v_shape          TEXT;
    v_recipient      TEXT;
    v_state          RECORD;
    v_escaped        BOOLEAN := false;
    v_window         CONSTANT INTERVAL := interval '15 minutes';
    v_threshold      CONSTANT INTEGER := 5; -- trips on the (threshold+1)th = 6th message
    v_escape_limit   CONSTANT INTEGER := 3; -- agent-chat#11 BLOCKING #2 fix: max content-novelty escapes per trip epoch
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

    -- agent-chat#11 DEFECT 1 FIX: sender-side runtime-error-template filter.
    -- Applies unconditionally, before the breaker and before the insert, so it
    -- holds for every caller regardless of recipient count or that agent's own
    -- policy. Quarantine is silent on the bus (return NULL, no row inserted)
    -- and loud in the log (one row per refused send in
    -- agent_chat_suppressed_log) -- raising an exception here would itself
    -- become a new error signal on the bus, reproducing the failure mode.
    -- (2026-09-03 QA remediation: agent_chat_is_error_template() now requires
    -- essentially-whole-message coverage; see BLOCKING #1 above.)
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
    -- 2026-09-03 QA remediation (BLOCKING #3): scoping now covers single
    -- recipients INCLUDING the '*' broadcast target -- a sender-scoped
    -- breaker keyed on (sender, '*'), since a broadcast has no well-defined
    -- ordered pair with a single counterparty. Multi-recipient, non-broadcast
    -- sends (e.g. an explicit list of several named agents) remain out of
    -- scope, unchanged from the original design.
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
                -- agent-chat#11 BLOCKING #2 fix: content-novelty escape hatch.
                -- v_state.last_shape/tripped/escape_count here are the values
                -- from BEFORE this message (captured by the RETURNING above).
                -- IMPORTANT: last_shape is frozen at the shape that TRIPPED the
                -- breaker and is intentionally NOT updated on escape or on
                -- ordinary suppression below -- if it were updated to each
                -- escaping message's own shape, a second escaping message with
                -- yet another different shape would compare against the FIRST
                -- escapee's shape (always "different") rather than the
                -- original storm shape, and a literal repeat of the original
                -- storm body would incorrectly compare as "novel" and escape
                -- again. Freezing last_shape at trip time makes escape
                -- decisions and budget consumption depend only on how the
                -- CURRENT message compares to the ORIGINAL storm shape.
                IF v_shape IS DISTINCT FROM v_state.last_shape AND v_state.escape_count < v_escape_limit THEN
                    -- Genuinely new-shaped content (e.g. a real urgent message
                    -- arriving right after a storm of near-identical pings)
                    -- escapes suppression even though the pair is tripped.
                    -- The breaker stays tripped for the ORIGINAL shape; only
                    -- this differently-shaped message is let through, and the
                    -- escape budget is consumed so an unbounded run of
                    -- differently-worded messages is still eventually capped.
                    UPDATE public.agent_chat_breaker_state
                    SET escape_count = v_state.escape_count + 1
                    WHERE sender = v_sender AND recipient = v_recipient;
                    v_escaped := true;
                ELSE
                    IF NOT v_state.tripped THEN
                        -- First message past the threshold: log once, loudly.
                        -- This message's shape becomes the frozen baseline
                        -- ( "the storm shape" ) that all subsequent
                        -- escape/suppress decisions for this trip compare
                        -- against.
                        INSERT INTO public.agent_chat_suppressed_log
                            (reason, sender, recipients, message_sample, window_message_count)
                        VALUES ('loop_breaker', v_sender, v_recipients, left(p_message, 500), v_state.message_count);

                        UPDATE public.agent_chat_breaker_state
                        SET tripped = true, suppressed_count = 1, last_shape = v_shape
                        WHERE sender = v_sender AND recipient = v_recipient;
                    ELSE
                        -- Already tripped, same shape as the original storm (or
                        -- escape budget spent): stay silent on the bus AND on
                        -- the log (the trip is already recorded); just keep
                        -- the running count for diagnosability. last_shape is
                        -- deliberately left untouched (see comment above).
                        UPDATE public.agent_chat_breaker_state
                        SET suppressed_count = suppressed_count + 1
                        WHERE sender = v_sender AND recipient = v_recipient;
                    END IF;

                    RETURN NULL;
                END IF;
            ELSE
                -- Not yet past threshold -- track shape so a later trip has an
                -- accurate baseline to compare content-novelty against.
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

    RETURN v_id;
END;
$$;

DO $$
BEGIN
    ALTER FUNCTION public.send_agent_message(text, text, text[], interval, integer) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping send_agent_message owner assignment: current user is not a superuser';
END $$;

-- ─── Lock down direct writes on the new control tables ─────────────────────
-- schema.sql's `ALTER DEFAULT PRIVILEGES FOR ROLE postgres ... GRANT DELETE,
-- INSERT, SELECT, UPDATE ON TABLES` applies to any new table postgres
-- creates, including these three. Revoke write access from the standard
-- agent role list so send_agent_message() (SECURITY DEFINER, owned by
-- postgres) remains the only write path -- consistent with the existing
-- agent_chat/agent_chat_processed invariant. SELECT is preserved for
-- diagnosability per the "loud in the log" constraint.
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
        'agent_chat_breaker_state',
        'agent_chat_suppressed_log'
    ]
    LOOP
        FOREACH v_role IN ARRAY v_roles
        LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
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

-- Version handshake table.
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);

INSERT INTO public.schema_version (version, description)
VALUES (5, 'agent-chat#11: courtesy-reply-storm sender-side filter + bus-side circuit breaker')
ON CONFLICT (version) DO NOTHING;

COMMIT;
