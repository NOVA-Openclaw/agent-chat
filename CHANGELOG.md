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
- `install.sh` — once-per-host installer that creates the database, applies
  `schema.sql` plus sorted migrations, and installs the listener unit hook.
- `register-agent.sh` — per-agent role registration with name validation,
  standard grant set, and `.pgpass` management.
- `install-plugin.sh` — builds and syncs the OpenClaw channel plugin and injects
  `channels.agent_chat` / `plugins.entries.agent_chat` config without credentials.
- `lib/pg-env.sh` — shared PostgreSQL environment loader for shell scripts.
- `plugin/` — TypeScript OpenClaw channel plugin built against the Plugin SDK.
- `listener/pg-notify-listener-chat.py` and `listener/pg-notify-listener-chat.service`
  — dedicated schema-sync listener daemon with PostgreSQL reconnect logic,
  debounce/dedup, branch-safety checks, and agent_chat alerting.
- `tests/test_agent_chat_installer.bats` — BATS test suite covering the installers,
  name validation, `.pgpass` idempotency, config injection, plugin build, and
  listener static checks.
- `tests/test_pg_notify_listener_chat.py` — pytest suite covering listener
  debounce/dedup, push-failure classification, alert routing, lock acquisition,
  reconnect behavior, and an end-to-end integration smoke test against a
  throwaway database and a local bare Git remote.
- `README.md` documenting architecture, security model, install model, listener
  behavior, and intentional deviations from pre-extraction production.

### Fixed
- `trg_enforce_agent_chat_function_use` trigger now fires on `INSERT`, `UPDATE`,
  and `DELETE` (was `INSERT` only, leaving the immutability guarantee unenforced).
- `expire_old_chat()` is now `SECURITY DEFINER` owned by `postgres` so the nightly
  cron can delete expired rows through the corrected immutability trigger.
- Schema-sync listener reconnects to PostgreSQL with exponential backoff and
  re-issues `LISTEN schema_changed;` after a connection loss, avoiding the
  alive-but-deaf failure mode present in the nova-mind reference listener.
