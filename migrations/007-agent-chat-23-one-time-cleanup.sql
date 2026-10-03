-- Migration: agent-chat#23 (Chunk B)
-- One-time cleanup: expire unresolved agent_chat_processed rows older than 7 days,
-- and insert `expired` rows for old named-recipient messages that were never
-- picked up.
--
-- Design notes:
--   * "Older than 7 days" means strictly older: agent_chat.timestamp < now() -
--     interval '7 days'. Exactly-7-day rows are NOT touched.
--   * Only the unresolved statuses `received` and `routed` are flipped. Terminal
--     statuses (`responded`, `expired`, `handled`, `skipped`, `failed`) are never
--     modified, including on re-run.
--   * Broadcasts (recipients containing '*') are excluded entirely: no updates
--     and no inserts are performed for them.
--   * Existing agent='main' rows are left untouched; the cleanup does not
--     reassign or delete them.
--   * Messages addressed to named recipients that have no agent_chat_processed
--     row at all get a fresh `expired` row so the first post-deploy digest does
--     not live-dispatch ancient backlog.
--
-- Idempotency:
--   * UPDATE is scoped to status IN ('received', 'routed') only, so re-running
--     cannot flip already-terminal rows.
--   * INSERT uses ON CONFLICT (chat_id, agent) DO NOTHING, so re-running cannot
--     create duplicates or raise unique-violation errors.
--   * Fresh installs: zero old rows exist, so the migration is a clean no-op.

BEGIN;

DO $$
DECLARE
    v_cutoff      timestamptz := NOW() - interval '7 days';
    v_updated     integer;
    v_inserted    integer;
BEGIN
    -- 1) Flip unresolved processed rows older than 7 days to expired.
    --    Leave agent='main' rows untouched and skip broadcasts entirely.
    UPDATE public.agent_chat_processed p
    SET status     = 'expired',
        expired_at = NOW()
    FROM public.agent_chat c
    WHERE p.chat_id = c.id
      AND p.agent <> 'main'
      AND p.status IN ('received', 'routed')
      AND c."timestamp" < v_cutoff
      AND NOT ('*' = ANY(c.recipients));

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- 2) Insert expired rows for old named-recipient messages that were never
    --    picked up. Broadcasts and the synthetic 'main' agent are excluded.
    WITH old_named_messages AS (
        SELECT c.id AS chat_id, lower(r) AS agent
        FROM public.agent_chat c
        CROSS JOIN LATERAL unnest(c.recipients) AS r
        WHERE c."timestamp" < v_cutoff
          AND NOT ('*' = ANY(c.recipients))
          AND lower(r) <> 'main'
    ),
    missing AS (
        SELECT m.chat_id, m.agent
        FROM old_named_messages m
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.agent_chat_processed p
            WHERE p.chat_id = m.chat_id
              AND p.agent   = m.agent
        )
    )
    INSERT INTO public.agent_chat_processed (chat_id, agent, status, expired_at)
    SELECT chat_id, agent, 'expired', NOW()
    FROM missing
    ON CONFLICT (chat_id, agent) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    RAISE NOTICE 'agent-chat#23 one-time cleanup: updated % row(s) to expired, inserted % new expired row(s)', v_updated, v_inserted;
END $$;

-- Version handshake.
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);

INSERT INTO public.schema_version (version, description)
VALUES (7, 'agent-chat#23: one-time cleanup of unresolved >7d agent_chat_processed rows and never-picked-up messages')
ON CONFLICT (version) DO NOTHING;

COMMIT;
