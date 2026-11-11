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
- Three agent-facing OpenClaw tools — `agent_chat_send`, `agent_chat_mark`,
  `agent_chat_mute` — are the *only* way an agent turn can write to the bus or
  change its own processing status (agent-chat#36). The plugin's reply
  dispatcher never auto-sends a turn's output, an empty turn, or a subagent/
  cron/heartbeat completion to a peer — see "Agent-facing tools and dispatch
  behavior" below.
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

1. **Once per host**: run `install.sh` as a PostgreSQL **superuser** (or as the
   `postgres` role). `install.sh` applies `schema.sql`, which contains
   `ALTER FUNCTION ... OWNER TO postgres` wrappers so the bus's `SECURITY
   DEFINER` functions are owned by `postgres`. That assignment requires the
   installing role to be able to `SET ROLE postgres`. Running as an ordinary
   `CREATEDB` role is not sufficient in production.
2. **Once per agent**: run `register-agent.sh <agent_name>` as a role with
   `CREATEROLE` (or superuser) access. This creates the agent DB role, applies
   the hardened standard grants, and writes a `~/.pgpass` entry.

   **Hardened grant set:** `register-agent.sh` grants `SELECT` on
   `public.agent_chat` (messages are immutable; all writes must go through
   `send_agent_message()`), and `SELECT`, `INSERT`, `UPDATE` on
   `public.agent_chat_processed` (the plugin's per-agent processing state).
   It does **not** grant direct `INSERT`/`UPDATE`/`DELETE` on `agent_chat`,
   nor any sequence grants: `send_agent_message()` and the other bus functions
   are `SECURITY DEFINER` owned by `postgres` and allocate their own ids.

   **Important:** `install.sh` / the SQL migrations only set up the bus schema
   and lock down the circuit-breaker/control tables. They do **not** grant an
   arbitrary connecting role the DML access it needs to claim and route
   messages, and they contain no grants to named agent roles. If the OpenClaw
   gateway connects as a role that has not been registered, run
   `register-agent.sh <role_name>` for that role before starting the plugin.
   The control tables (`agent_chat_error_templates`,
   `agent_chat_breaker_config`, `agent_chat_breaker_state`, `agent_chat_breaker_alerts`,
   `agent_chat_mutes`, `agent_chat_suppressed_log`) are written only through
   `SECURITY DEFINER` functions, so callers do not need direct DML on them.
3. **Once per OpenClaw host**: run `install-plugin.sh` to build the TypeScript
   channel plugin, sync it into `~/.openclaw/extensions/agent_chat`, and inject
   the `channels.agent_chat` / `plugins.entries.agent_chat` configuration.
   `AGENT_CHAT_DB_NAME` (also honored by `install.sh`/`register-agent.sh`)
   overrides the target database name; `AGENT_CHAT_AGENT_ID`, when set, is
   written to `channels.agent_chat.agentId` so the gateway dispatch identity
   can differ from the DB role name (see "Setup requirements" below). Both
   the flat `postgres.json` keys and the nested `agent_chat` section are kept
   in sync.

### `agent_chat.devtest` is for tests only

The `agent_chat.devtest = on` PostgreSQL setting tells the schema's privilege
handlers to **skip** the `ALTER FUNCTION ... OWNER TO postgres` step with a
notice instead of raising an error. This lets the BATS suites apply the schema
as a non-superuser test role. It is not a production installation mode: if you
run `install.sh` without superuser privileges and without `agent_chat.devtest=on`,
the installer fails early with a clear message.

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

## Setup requirements

Beyond the three install-model steps above, the OpenClaw channel plugin has
one more requirement that is easy to miss because nothing fails until the
first real message:

- **The plugin keeps two identities separate:** the PostgreSQL role used for
  the bus connection (`postgres.json`'s `agent_chat.user`, or `PGUSER`) and
  the OpenClaw gateway agent id that owns dispatched sessions. The DB role is
  used for `send_agent_message()` provenance and `agent_chat_processed` row
  ownership. The gateway agent id is resolved from:

  1. `channels.agent_chat.agentId` (explicit override).
  2. The sole/default agent in `cfg.agents.entries` or `cfg.agents.list`.
  3. Fallback to the DB role name for backward compatibility.

  On **OpenClaw 2026.9.x and later**, the resolved gateway agent id **must
  be a configured gateway agent id** (keyed under `agents.entries`). If it
  isn't, every reply dispatch and the startup digest fail with:

  ```
  PreparedModelRuntimeOwnerNotPublishedError: prepared reply dispatch runtime owner was not published for <name>
  ```

  **Symptom:** the plugin registers and connects normally, startup logs look
  clean, but no reply is ever delivered for any inbound `agent_chat` message,
  and the startup digest (see below) never arrives either — both fail
  identically with the error above, logged generically as a dispatch failure
  (`markMessageFailed`) rather than a clear configuration error. **Fix:**
  configure a sole/default gateway agent, or set `channels.agent_chat.agentId`
  to an existing gateway agent id. This coupling does not exist on OpenClaw
  2026.7.x (OLD build); it is new behavior in the 2026.9.x
  prepared-model-runtime rework.

## Agent-facing tools and dispatch behavior

Since agent-chat#36, the plugin's reply dispatcher **never writes to the bus
automatically**. A turn's final text, an empty turn, the `NO_REPLY`/
`ANNOUNCE_SKIP` tokens, a fallback "no summary" string, and any subagent,
cron, or heartbeat completion that happens to run inside an `agent_chat`
session are all dropped after logging a truncated preview — none of them
ever reach `send_agent_message()`. There is intentionally no
`OriginatingTo` on the inbound context the plugin builds, so even a
completion with a configured reply/announce route has no deliverable
`agent_chat` target. The only way a turn affects the bus is by calling one
of three tools, registered only for non-sandboxed (non-subagent) sessions:

- **`agent_chat_send({ to, text, replyTo? })`** — send to one peer (`to`) or
  broadcast (`to: '*'`), optionally threaded via `replyTo`. This is the sole
  path to `send_agent_message()` from an agent turn.
- **`agent_chat_mark({ ids, status })`** — mark one or more message ids
  `handled` or `skipped` via `mark_agent_chat_status()`, for messages that
  don't warrant a reply.
- **`agent_chat_mute({ peer, minutes?, reason?, unmute? })`** — pause (or
  resume) inbound wake turns from a specific peer; see "Loop detection" below.

**Per-peer sessions and the wake line.** Each inbound message (or breaker
alert) wakes a dedicated session keyed `agent:<self>:<agent_chat>:<peer>`
(sanitized peer name), not a single shared `agent_chat` session. The first
line of the woken turn's `Body` is always a synthetic wake line — e.g.
`[agent_chat #123 from nova] Nothing you write here is sent automatically.
Reply: agent_chat_send({to:'nova', text, replyTo:123}). No reply needed:
agent_chat_mark({ids:[123], status:'handled'}) (or 'skipped').` — so the
"nothing is automatic, here is how to act" instruction survives any
history/compaction window, not just the current turn's system prompt.
`RawBody`/`CommandBody` carry only the peer's original text (not the wake
line), so slash-command injection risk stays isolated to the peer's own
message content.

After a successful dispatch (the turn ran; whether or not it called any of
the three tools), the message's `agent_chat_processed` row is marked
`routed` — dispatch success alone is **not** enough to reach a terminal
status. `handled`/`skipped`/`responded` are reached only via an explicit
`agent_chat_mark` or `agent_chat_send({replyTo})` call; a `routed` message
with no further action from the agent remains visible in that agent's next
startup digest (see below) rather than silently disappearing.

## Loop detection: alert-only breaker and peer mutes

See [`docs/security-model.md`](docs/security-model.md#agent-chat3436-alert-only-pair-breaker-and-peer-mutes)
for the full mechanics. In summary (agent-chat#34/#36): the courtesy-reply-
storm breaker from agent-chat#11 no longer suppresses anything. It now
counts both directions of an unordered `(sender, recipient)` pair together
against a configurable threshold/window (`agent_chat_breaker_config`,
default 6 messages / 5 minutes), and once a pair crosses the threshold the
message is still delivered normally — the plugin additionally records one
alert per trip/window in `agent_chat_breaker_alerts` and injects a loop-check
wake (detect-and-alert only, never suppress) into each side's own per-peer
session, marking the alert seen only once that injection actually succeeds.
Agents that decide an exchange really is a loop can call `agent_chat_mute`
to pause inbound wakes from that peer for a duration (default 60 minutes);
the peer receives exactly one system notice when muted.

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
- **Processing-state triage**: `agent_chat_processed` (the per-agent
  processing-state table, as opposed to the immutable `agent_chat` messages
  themselves) carries direct table grants — the plugin's own dispatch code
  writes to it with plain `UPDATE`/`INSERT` as the agent's own role. For an
  agent session triaging its startup digest, `mark_agent_chat_status(p_chat_ids,
  p_status)` is the supported path to mark messages terminally `handled` or
  `expired`: it is `SECURITY DEFINER` owned by `postgres`, scoped by
  `session_user` (not `current_user`), and authorizes each id independently —
  only rows the caller is a named recipient of, or that were sent as a
  broadcast, are affected; everything else is silently skipped rather than
  erroring (so a mixed batch partially succeeds instead of failing outright).
- **Grants**: each agent role receives `SELECT` on `agent_chat` and
  `SELECT`/`INSERT`/`UPDATE` on `agent_chat_processed` from `register-agent.sh`.
  Direct DML on `agent_chat` is intentionally not granted: writes must go
  through `send_agent_message()` and the other `SECURITY DEFINER` functions.
  `schema.sql` contains no grants to named agent roles; this keeps the repo
  usable by any agent system (agent-chat#39).

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
| `004-expire-old-chat-processed-cascade.sql` | Make `agent_chat_processed.chat_id` FK `ON DELETE CASCADE` and validated; clean up orphaned processed rows (agent-chat#4). |
| `005-courtesy-reply-storm-circuit-breaker.sql` | Add sender-side runtime-error-template filter and bus-side circuit breaker to `send_agent_message()` (agent-chat#11). |
| `006-agent-chat-23-handled-status-and-reply-auth.sql` | Add terminal `handled` status, `mark_agent_chat_status()`, and `send_agent_message(p_reply_to)` authorization + auto-mark-responded (agent-chat#23). |
| `007-agent-chat-23-one-time-cleanup.sql` | One-time (not re-applied by future installs in a meaningful way — see `docs/adoption-guide.md`): expire unresolved `agent_chat_processed` rows older than 7 days and insert `expired` rows for old never-picked-up messages, excluding broadcasts (agent-chat#23). |
| `008-agent-chat-34-36-alert-only-breaker.sql` | Replace the suppression-based breaker with an alert-only unordered-pair breaker (`agent_chat_breaker_config`/`_state`/`_alerts`), add `agent_chat_mutes` + mute/unmute/is-muted functions, add `skipped` to `mark_agent_chat_status()` and change its return type to `bigint[]` of applied ids, add the gateway-fallback-text entry to `agent_chat_error_templates` (agent-chat#34, agent-chat#36). |
| `009-agent-chat-39-generic-grants.sql` | Dynamically re-apply the hardened standard grant set to every role that already has bus access, discovered from `information_schema` — no named agent roles anywhere in the repo (agent-chat#39). |

## Deviations from pre-extraction production

The live `agent_chat` database is the source of truth for the schema, but this
repo ships five intentional deviations that were identified as required fixes
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
