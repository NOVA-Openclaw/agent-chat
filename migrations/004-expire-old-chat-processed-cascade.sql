-- Migration: agent-chat#4
-- Change agent_chat_processed_chat_id_fkey to ON DELETE CASCADE and VALIDATED.
-- Clean up orphaned processed-state rows that accumulated while the FK was
-- NOT VALID or absent.
--
-- Background:
--   * expire_old_chat() DELETEs rows from public.agent_chat older than the
--     retention window. Prior to this migration, agent_chat_processed.chat_id
--     referenced agent_chat(id) with no ON DELETE action (and, for much of
--     production history, was NOT VALID), so any expired message that had
--     processing-state rows caused a foreign-key violation and aborted the
--     reaper (SE#643 TC-04 data-bearing rehearsal finding).
--   * Processed-state rows are meaningless once the parent message is gone,
--     so CASCADE is the correct semantics.
--   * Rehearsal against a 14,452-row production clone found 2,912 orphaned
--     processed rows referencing chat_ids no longer present in agent_chat.
--     These dead rows must be removed before VALIDATE CONSTRAINT can succeed.
--
-- Idempotency:
--   * Fresh installs: schema.sql already creates the validated CASCADE FK, so
--     this DROP/ADD pair is a no-op at the constraint level and the orphan
--     DELETE removes zero rows.
--   * Existing production DBs: the old non-CASCADE FK is dropped, re-added
--     with CASCADE (NOT VALID to avoid blocking), orphaned rows are deleted,
--     and the constraint is VALIDATED.
--   * Already-fixed DBs: DROP IF EXISTS + ADD with CASCADE is safe to replay;
--     the orphan DELETE is scoped to real orphans only; VALIDATE CONSTRAINT is
--     idempotent on an already-validated constraint.
--
-- End state: ON DELETE CASCADE, VALIDATED. This is strictly stronger than the
-- previous NOT VALID state and costs almost nothing because
-- agent_chat_processed is small.

BEGIN;

ALTER TABLE public.agent_chat_processed
    DROP CONSTRAINT IF EXISTS agent_chat_processed_chat_id_fkey;

ALTER TABLE public.agent_chat_processed
    ADD CONSTRAINT agent_chat_processed_chat_id_fkey
    FOREIGN KEY (chat_id) REFERENCES public.agent_chat (id)
    ON DELETE CASCADE
    NOT VALID;

-- Remove orphaned processed-state rows whose parent messages were deleted
-- while the FK was NOT VALID or absent. These rows are dead state and would
-- otherwise block VALIDATE CONSTRAINT.
DO $$
DECLARE
    v_deleted_count integer;
BEGIN
    DELETE FROM public.agent_chat_processed
    WHERE NOT EXISTS (
        SELECT 1 FROM public.agent_chat WHERE id = agent_chat_processed.chat_id
    );
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RAISE NOTICE 'Deleted % orphaned agent_chat_processed rows', v_deleted_count;
END $$;

-- Validate all remaining rows against the new CASCADE FK. The table is small,
-- so the scan is cheap, and a validated constraint is strictly stronger than
-- NOT VALID.
ALTER TABLE public.agent_chat_processed
    VALIDATE CONSTRAINT agent_chat_processed_chat_id_fkey;

-- Version handshake table.
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);

INSERT INTO public.schema_version (version, description)
VALUES (4, 'agent-chat#4: cascade delete agent_chat_processed rows on parent message expiration, validate FK')
ON CONFLICT (version) DO NOTHING;

COMMIT;
