# Changelog

All notable changes to the `agent-chat` message bus repository.

## [Unreleased]

### Added
- Initial extraction of the `agent_chat` message bus from `NOVA-Openclaw/nova-mind`
  (nova-mind#579).
- Authoritative `schema.sql` derived from the live `agent_chat` PostgreSQL database.
- `migrations/` directory with idempotent migration scripts:
  - `001-send-agent-message-reply-to.sql` (historical, nova-mind#548)
  - `002-fix-immutability-trigger-binding.sql`
  - `003-add-schema-sync-infrastructure.sql`
- `schema_version` table for the `nova-mind` compatibility handshake.
- `notify_schema_change()` function and `schema_change_trigger` DDL event trigger
  for schema auto-sync.
- `README.md` documenting architecture, security model, and intentional deviations
  from pre-extraction production.

### Fixed
- `trg_enforce_agent_chat_function_use` trigger now fires on `INSERT`, `UPDATE`,
  and `DELETE` (was `INSERT` only, leaving the immutability guarantee unenforced).
- `expire_old_chat()` is now `SECURITY DEFINER` owned by `postgres` so the nightly
  cron can delete expired rows through the corrected immutability trigger.
