-- Migration: agent-chat#4
-- Change agent_chat_processed_chat_id_fkey to ON DELETE CASCADE.
--
-- Background:
--   * expire_old_chat() DELETEs rows from public.agent_chat older than the
--     retention window. Prior to this migration, agent_chat_processed.chat_id
--     referenced agent_chat(id) with no ON DELETE action, so any expired
--     message that had processing-state rows caused a foreign-key violation
--     and aborted the reaper (SE#643 TC-04 data-bearing rehearsal finding).
--   * Processed-state rows are meaningless once the parent message is gone,
--     so CASCADE is the correct semantics.
--
-- Idempotency:
--   * Fresh installs: schema.sql already creates the CASCADE FK, so this
--     DROP/ADD pair is a no-op at the constraint level.
--   * Existing production DBs: the old non-CASCADE FK is dropped and re-added
--     with CASCADE. The FK remains NOT VALID to avoid a full table validation
--     scan against large production tables on adoption.
--   * Already-fixed DBs: DROP IF EXISTS + ADD with CASCADE is safe to replay.
--
-- NOT VALID is intentionally preserved to match the live production schema
-- state (nova-mind#475 drift); the FK is still enforced for new rows.

BEGIN;

ALTER TABLE public.agent_chat_processed
    DROP CONSTRAINT IF EXISTS agent_chat_processed_chat_id_fkey;

ALTER TABLE public.agent_chat_processed
    ADD CONSTRAINT agent_chat_processed_chat_id_fkey
    FOREIGN KEY (chat_id) REFERENCES public.agent_chat (id)
    ON DELETE CASCADE
    NOT VALID;

-- Version handshake table.
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);

INSERT INTO public.schema_version (version, description)
VALUES (4, 'agent-chat#4: cascade delete agent_chat_processed rows on parent message expiration')
ON CONFLICT (version) DO NOTHING;

COMMIT;
