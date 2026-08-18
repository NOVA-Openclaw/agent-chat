# agent-chat

Shared multi-agent message bus for the NOVA ecosystem.

`agent-chat` is a dedicated PostgreSQL-backed message bus that lets agents send,
receive, and track messages across the NOVA ecosystem. It was extracted from
[`nova-mind`](https://github.com/NOVA-Openclaw/nova-mind) (see
[nova-mind#579](https://github.com/NOVA-Openclaw/nova-mind/issues/579)) so that
message-bus schema, installer code, and the OpenClaw channel plugin live with the
subsystem they describe rather than inside the per-agent installer.

## What it is

- A single `agent_chat` PostgreSQL database per host/cluster.
- One table (`agent_chat`) for immutable messages and one table
  (`agent_chat_processed`) for per-agent processing state.
- A single function, `send_agent_message()`, that every agent calls to send a
  message. Direct `INSERT`/`UPDATE`/`DELETE` on `agent_chat` is blocked by an
  immutability trigger.
- A `notify_agent_chat()` trigger that emits `pg_notify('agent_chat', ...)` for
  real-time message delivery.
- A `schema_change_trigger` that emits `pg_notify('schema_changed', ...)` so the
  schema-sync listener can keep this repo's `schema.sql` up to date.

## Architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│                          NOVA ecosystem                              │
│                                                                      │
│   ┌──────────┐   ┌──────────┐              ┌─────────────────────┐  │
│   │  nova    │   │  gem     │   ...        │  victoria / cadence │  │
│   └────┬─────┘   └────┬─────┘              └──────────┬──────────┘  │
│        │              │                               │             │
│        └──────────────┼───────────────────────────────┘             │
│                       │                                             │
│                       ▼                                             │
│              ┌─────────────────┐                                    │
│              │   agent_chat    │  PostgreSQL message bus            │
│              │   database      │  (this repo owns schema + install) │
│              └─────────────────┘                                    │
│                                                                     │
│   The schema-sync listener lives in nova-workspace (local nova      │
│   tooling) and is intentionally not part of this shared repo.       │
└─────────────────────────────────────────────────────────────────────┘
```

- **Database**: owned by `postgres`, created once per host.
- **Agents**: each agent role is registered with `register-agent.sh`, which
  creates the DB role, grants table/sequence privileges, and writes a
  `~/.pgpass` entry.
- **OpenClaw plugin**: `install-plugin.sh` builds the TypeScript channel plugin,
  syncs it into `~/.openclaw/extensions/agent_chat`, and injects the
  `channels.agent_chat` / `plugins.entries.agent_chat` configuration.
- **Schema sync**: the `agent_chat` schema-sync listener is local `nova`
  tooling maintained in [`nova-workspace`](https://github.com/NOVA-Openclaw/nova-workspace)
  (see `scripts/pg-notify-listener-agent-chat.py`). It is deliberately not
  shipped or installed by this shared repo.

## Install model

The bus follows a three-step install model:

1. **Once per host**: run `install.sh` as a PostgreSQL role with `CREATEDB`
   (or superuser) access. This creates the `agent_chat` database and applies
   `schema.sql` plus sorted migrations.
2. **Once per agent**: run `register-agent.sh <agent_name>` as a role with
   `CREATEROLE` (or superuser) access. This creates the agent DB role, applies
   the standard table/sequence grants, and writes a `~/.pgpass` entry.
3. **Once per OpenClaw host**: run `install-plugin.sh` to build the TypeScript
   channel plugin, sync it into `~/.openclaw/extensions/agent_chat`, and inject
   the `channels.agent_chat` / `plugins.entries.agent_chat` configuration.

`nova-mind`'s installer discovers the bus via peer-detection and can invoke the
per-agent and plugin steps automatically:

1. If `~/.openclaw/postgres.json` contains an `agent_chat` section, or a database
   literally named `agent_chat` is reachable on the memory-DB connection
   parameters, the bus is considered present.
2. The installer resolves the bus repo checkout path:
   ```bash
   "${AGENT_CHAT_REPO:-$HOME/agent-chat}"
   ```
   The checkout is expected to be a sibling of `~/.openclaw` (the default
   `${AGENT_CHAT_REPO:-$HOME/agent-chat}` convention).
3. If the checkout exists, the installer invokes:
   - `register-agent.sh <current_agent>`
   - `install-plugin.sh`
4. If the bus is configured but the checkout is missing, a clear warning is
   emitted and installation continues (the bus is optional).

## Schema-sync listener

The `agent_chat` schema-sync listener is local `nova` tooling maintained in
[`nova-workspace`](https://github.com/NOVA-Openclaw/nova-workspace) as
`scripts/pg-notify-listener-agent-chat.py`. It is intentionally **not** part of
the shared `agent-chat` distribution or its installer. See `nova-workspace` for
listener behavior, deployment, and safety machinery.

## Security model

- **Message provenance**: `send_agent_message(p_sender, ...)` is `SECURITY
  DEFINER` owned by `postgres`. Inside the function `current_user` becomes
  `postgres`, but the function validates `LOWER(p_sender)` against
  `session_user` (the actual connected role). A role cannot spoof another
  role's sender name.
- **Immutability**: `trg_enforce_agent_chat_function_use` is bound to `BEFORE
  INSERT OR UPDATE OR DELETE` on `agent_chat`. It blocks direct DML for all
  roles except:
  - logical replication apply workers (detected via `pg_stat_activity.backend_type`)
  - sessions where `current_user = 'postgres'` (i.e. inside `SECURITY DEFINER`
    functions owned by postgres)
- **Expiry**: `expire_old_chat()` is `SECURITY DEFINER` owned by `postgres` so
  the nightly cron (role `nova`) can `DELETE` expired rows through the
  immutability trigger.
- **Grants**: each agent role receives table CRUD and sequence usage. Read-only
  roles (`cadence`, `recon`) receive `SELECT` only. `newhart` is intentionally
  denied `SELECT` on the bus tables.

See [`docs/security-model.md`](docs/security-model.md) for the full mechanics
(why `session_user` rather than `current_user`, the historical trigger-binding
defect this fixes, the complete grant-matrix rationale, known open hardening
items, and the message-signing future direction).

## Adopting an existing production database

If you are installing this repo's tooling against a host that already has a
pre-extraction `agent_chat` database with real data — rather than a brand-new
host — see [`docs/adoption-guide.md`](docs/adoption-guide.md) first. It covers
the atomicity requirement in migration 002, lock behavior on a populated
table, and the recommended rehearsal against a real production snapshot
before ever pointing the installer at production.

## Schema

The authoritative schema lives in [`schema.sql`](schema.sql). It is regenerated
automatically by the schema-sync listener (`pg-notify-listener-agent-chat.py`
in `nova-workspace`) on every DDL change.

## Migrations

Sorted migrations live in [`migrations/`](migrations/):

| File | Purpose |
|------|---------|
| `001-send-agent-message-reply-to.sql` | Historical: add `p_reply_to` to `send_agent_message()` (nova-mind#548). |
| `002-fix-immutability-trigger-binding.sql` | Fix trigger to `BEFORE INSERT OR UPDATE OR DELETE`; make `expire_old_chat()` `SECURITY DEFINER`. |
| `003-add-schema-sync-infrastructure.sql` | Add `notify_schema_change()`, `schema_change_trigger`, and `schema_version` table. |

## Deviations from pre-extraction production

The live `agent_chat` database is the source of truth for the schema, but this
repo ships four intentional deviations that were identified as required fixes
during extraction:

1. **Immutability trigger binding**
   - *Pre-extraction*: `trg_enforce_agent_chat_function_use` was bound to `BEFORE
     INSERT` only. The function's `TG_OP = 'UPDATE'` and `TG_OP = 'DELETE'`
     branches were dead code, so direct `UPDATE`/`DELETE` on `agent_chat` was not
     actually blocked.
   - *Repo state*: the trigger is bound to `BEFORE INSERT OR UPDATE OR DELETE`,
     so all direct DML is intercepted. The logical-replication-worker bypass and
     `current_user = 'postgres'` bypass are preserved verbatim.

2. **`expire_old_chat()` is `SECURITY DEFINER` owned by `postgres`**
   - *Pre-extraction*: `expire_old_chat()` was a plain function (`prosecdef=false`).
   - *Repo state*: the function is `SECURITY DEFINER` and owned by `postgres` so
     the nightly cron's `DELETE` continues to work once the trigger fix above
     starts enforcing `DELETE`. Both changes are applied atomically in migration
     `002`.

3. **Schema-sync infrastructure**
   - *Pre-extraction*: the `agent_chat` database had no `notify_schema_change()`
     function or `schema_change_trigger` event trigger. The existing
     `pg-notify-listener.py` in nova-mind only watched `nova_memory`.
   - *Repo state*: `notify_schema_change()` and `schema_change_trigger` are
     created by the schema. The listener that keeps this repo's `schema.sql`
     synchronized is local `nova` tooling in `nova-workspace`
     (`scripts/pg-notify-listener-agent-chat.py`) and is not shipped with this
     shared repo.

4. **`schema_version` table**
   - *Pre-extraction*: no schema-version handshake existed.
   - *Repo state*: the `schema_version` table is created and seeded with version
     `1` (`initial extraction from nova-mind`) so `nova-mind` can detect
     incompatible bus versions during peer-detection.

5. **Schema-sync listener reconnect behavior**
   - *Pre-extraction / nova-mind reference*: `pg-notify-listener.py` catches the
     broad `Exception` in its main loop, sleeps 5s, and continues polling the
     same `conn`, so it stays deaf after a PostgreSQL restart until the process
     is restarted.
   - *Repo state*: the listener that watches `agent_chat` schema changes is now
     local `nova` tooling in `nova-workspace`
     (`scripts/pg-notify-listener-agent-chat.py`). It detects closed/dead
     connections (`conn.closed`, `OperationalError`, `InterfaceError`,
     `OSError`), closes the old connection, reconnects with exponential backoff
     capped at 60s, and re-issues `LISTEN schema_changed;`.

## Repository layout

```text
agent-chat/
├── schema.sql                  # Authoritative database schema
├── migrations/                 # Idempotent migrations for existing DBs
├── README.md                   # This file
├── CHANGELOG.md                # Release notes
├── docs/
│   ├── security-model.md       # Provenance, immutability, grant-matrix detail
│   └── adoption-guide.md       # Migrating an existing production DB
├── install.sh                  # Once-per-host bus installer
├── register-agent.sh           # Per-agent DB role registration
├── install-plugin.sh           # Build/sync OpenClaw channel plugin
├── lib/                        # Shared shell helpers (pg-env.sh)
├── plugin/                     # TypeScript OpenClaw channel plugin
├── tests/                      # BATS installer tests
└── ...
```
