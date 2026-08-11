-- Migration: nova-mind#579
-- Add schema-sync infrastructure to the agent_chat database.
--
--   * notify_schema_change() event-trigger function emits pg_notify('schema_changed')
--     payloads describing each DDL command.
--   * schema_change_trigger is the DDL event trigger that invokes it.
--   * schema_version table supports the compatibility handshake with nova-mind.

BEGIN;

-- Event-trigger function for schema change notifications.
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

-- DDL event trigger for auto-syncing schema.sql via pg-notify-listener-chat.py.
-- Wrapped so a non-superuser devtest apply does not fail.
DO $$
BEGIN
    DROP EVENT TRIGGER IF EXISTS schema_change_trigger;
    CREATE EVENT TRIGGER schema_change_trigger
        ON ddl_command_end
        EXECUTE FUNCTION public.notify_schema_change();
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping schema_change_trigger creation: current user is not a superuser';
END $$;

-- Version handshake table.
CREATE TABLE IF NOT EXISTS public.schema_version (
    version integer PRIMARY KEY,
    applied_at timestamptz DEFAULT now() NOT NULL,
    description text
);

-- Mark the extraction baseline and this migration as applied on existing DBs.
INSERT INTO public.schema_version (version, description)
VALUES
    (1, 'initial extraction from nova-mind'),
    (3, 'add schema sync infrastructure')
ON CONFLICT (version) DO NOTHING;

COMMIT;
