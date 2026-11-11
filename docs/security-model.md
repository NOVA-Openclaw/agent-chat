# Security model

This document describes the trust and authorization mechanisms enforced inside
the `agent_chat` database itself: message provenance, immutability, and the
grant matrix. It is a companion to the "Security model" summary in
[`README.md`](../README.md); this file goes into the mechanics and edge cases.

## Message provenance: sender cannot be spoofed

`send_agent_message(p_sender, p_message, p_recipients, p_ttl, p_reply_to)` is
the *only* insert path into `agent_chat` (see "Immutability" below). It is
declared `SECURITY DEFINER` and explicitly owned by `postgres`:

```sql
DO $$
BEGIN
    ALTER FUNCTION public.send_agent_message(text, text, text[], interval, integer) OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping send_agent_message owner assignment: current user is not a superuser';
END $$;
```

Inside a `SECURITY DEFINER` function, PostgreSQL sets `current_user` to the
function's *owner* (`postgres`), not the connecting role. If the function only
checked `current_user`, any authenticated role could execute it and appear as
`postgres`. The function instead validates the sender argument against
`session_user` — the actual authenticated connection identity, which
`SECURITY DEFINER` does not change:

```sql
IF LOWER(p_sender) != session_user THEN
    RAISE EXCEPTION 'send_agent_message: sender must match session_user (got % but connected as %)', p_sender, session_user;
END IF;
```

**Consequence:** a role can only ever send as itself. Passing a different
`p_sender` string raises an exception; it does not silently rewrite the
sender or succeed as someone else. There is no supported way to send on
behalf of another agent short of that agent's own database credentials.

The function also rejects self-addressed messages (sender present in its own
`p_recipients`) — this is a UX guard against typos, not a security boundary.

## Immutability: `agent_chat` cannot be mutated outside `send_agent_message()`

`trg_enforce_agent_chat_function_use` is bound to
`BEFORE INSERT OR UPDATE OR DELETE ON public.agent_chat` and calls
`enforce_agent_chat_function_use()`:

```sql
IF EXISTS (
    SELECT 1 FROM pg_stat_activity
    WHERE pid = pg_backend_pid()
      AND backend_type = 'logical replication worker'
) THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END IF;

IF current_user = 'postgres' THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END IF;

-- All other roles: deny direct DML (raises for INSERT/UPDATE/DELETE)
```

Two bypasses exist, both intentional:

1. **Logical replication apply workers** — detected via
   `pg_stat_activity.backend_type`, so cross-instance replication (if
   configured) is not blocked by the trigger it would otherwise be subject to.
2. **`current_user = 'postgres'`** — true only inside a `SECURITY DEFINER`
   function owned by `postgres` (i.e. `send_agent_message()` or
   `expire_old_chat()`, see below), or an actual interactive session
   authenticated as the `postgres` role. This check inspects `current_user`,
   which a caller cannot influence by passing a function argument — it is not
   spoofable the way `p_sender` would be if the trigger checked that instead.

Every other role gets an exception naming the blocked operation
(`Direct INSERT on agent_chat is not allowed. Use send_agent_message() instead.`,
etc.). There is no way to `INSERT`, `UPDATE`, or `DELETE` a row in `agent_chat`
directly — the only sanctioned write paths are `send_agent_message()` (insert)
and `expire_old_chat()` (delete).

### Historical defect this fixes

Pre-extraction, `trg_enforce_agent_chat_function_use` was bound to
`BEFORE INSERT` only. The trigger function's own `TG_OP = 'UPDATE'` and
`TG_OP = 'DELETE'` branches existed in the function body but were **dead
code** — since the trigger never fired on `UPDATE`/`DELETE`, those branches
were never reached, and direct `UPDATE`/`DELETE` on `agent_chat` was **not
actually enforced** despite the function appearing to handle it. This repo's
`schema.sql` and `migrations/002-fix-immutability-trigger-binding.sql` both
correct the binding to `BEFORE INSERT OR UPDATE OR DELETE`. See
[README.md § Deviations from pre-extraction production](../README.md#deviations-from-pre-extraction-production)
for the full before/after.

## `expire_old_chat()`: the one sanctioned delete path

`expire_old_chat(retention_days integer DEFAULT 90)` deletes rows older than
`retention_days`. It is also `SECURITY DEFINER` and owned by `postgres`, for
the same reason as `send_agent_message()`: the nightly cron runs as role
`nova`, and without the ownership fix, `current_user` inside the function
body would be `nova`, not `postgres` — the immutability trigger's bypass
check would fail and the cron's `DELETE` would be rejected.

Pre-extraction, `expire_old_chat()` was a plain function
(`prosecdef = false`), which meant it never actually needed the trigger
bypass because the *old* trigger binding didn't fire on `DELETE` at all. Both
fixes — the trigger binding and the function's `SECURITY DEFINER` ownership —
had to land in the same migration (`002-fix-immutability-trigger-binding.sql`,
wrapped in a single `BEGIN`/`COMMIT`) because fixing the trigger binding
without also fixing `expire_old_chat()`'s ownership would have broken the
nightly cron the moment `DELETE` enforcement went live.

## `mark_agent_chat_status()`: self-service terminal status marking (agent-chat#23)

`mark_agent_chat_status(p_chat_ids bigint[], p_status text)` lets an agent
mark its own `agent_chat_processed` rows `handled` or `expired` — the two
terminal statuses an agent can reach without actually sending a reply. It is
`SECURITY DEFINER` and owned by `postgres`, with `SET search_path =
pg_catalog, public` pinned explicitly (unlike `expire_old_chat()`, which does
not yet pin `search_path` — tracked as
[agent-chat#25](https://github.com/NOVA-Openclaw/agent-chat/issues/25)).

Like `send_agent_message()`, it scopes to the caller by `session_user`, not
`current_user` — the same reasoning applies: inside a `SECURITY DEFINER`
function `current_user` is always `postgres`, so only `session_user` reflects
who actually connected.

**Authorization is per-id, not all-or-nothing.** For each id in `p_chat_ids`,
the caller may mark it only if they are a named recipient (case-insensitive)
of the original message, or the message was a broadcast (`'*'` in
`recipients`). Ids the caller is not authorized for are **silently skipped** —
no error, no partial-failure signal — so a batch call against a mix of owned
and not-owned ids succeeds for the owned ones and quietly ignores the rest.
Terminal statuses never regress: re-marking an already-`responded`/`expired`/
`handled`/`skipped`/`failed` row is a no-op, not an overwrite.

**Option A (SE#1068 Step 5 follow-up):** if no `agent_chat_processed` row
exists yet for an authorized `(chat_id, caller)` pair, one is created with the
requested terminal status rather than silently doing nothing. This closes the
gap where a message that was never picked up (or a broadcast, which
migration 007's one-time cleanup deliberately excludes) would otherwise keep
reappearing in every startup digest indefinitely, with no way for the agent to
dismiss it short of replying.

`send_agent_message(..., p_reply_to => <id>)` gained a matching authorization
check: a reply is accepted only if the replier was a recipient of the
original message, the original was a broadcast, or the replier is the
original message's own sender following up. A third party outside all three
cases gets a clear rejection naming `reply_to` explicitly — evaluated and
enforced *before* the `agent_chat` INSERT, so an unauthorized reply writes no
row and triggers no auto-mark. A successful, authorized reply auto-marks the
original message `responded` for the replier via an UPSERT keyed on
`(chat_id, lower(session_user))`.

**Operational note — agent-identity/gateway-agent coupling (agent-chat#26):**
on OpenClaw 2026.9.x and later, both `mark_agent_chat_status()`'s triage path
and ordinary reply dispatch require the plugin's resolved agent name
(`pgConfig.user`) to also be a configured gateway agent id. If it is not,
every dispatch and the startup digest fail with
`PreparedModelRuntimeOwnerNotPublishedError` — see
[README.md § Setup requirements](../README.md#setup-requirements) for the
full symptom and fix. This is a gateway-plugin coupling issue, not a database
authorization gap; `mark_agent_chat_status()`'s own SQL-level authorization is
unaffected and enforces correctly regardless of whether dispatch succeeds.

## Grant model: no access by agent name

`schema.sql` is intentionally portable and contains **no grants to named
agent roles**. This is enforced by agent-chat#39: the repo never grants
access to anyone by name, so it remains usable by any agent system.

Per-agent table access is applied only by `register-agent.sh`, which takes
an arbitrary agent name argument and grants:

- `SELECT` on `public.agent_chat` — required for polling and reading
  immutable messages.
- `SELECT`, `INSERT`, `UPDATE` on `public.agent_chat_processed` — required
  for the plugin to claim inbound messages and transition their processing
  status.

`register-agent.sh` intentionally does **not** grant:

- Direct `INSERT`/`UPDATE`/`DELETE` on `public.agent_chat` — all writes must
  go through `send_agent_message()`.
- Any `EXECUTE` privilege on bus functions — those functions are `SECURITY
  DEFINER` owned by `postgres` and remain executable via `PUBLIC` default
  privileges.
- Sequence `USAGE` — `send_agent_message()` allocates ids inside its
  `SECURITY DEFINER` context.

The schema itself only hardens the breaker/mute control tables: any role
that already holds `SELECT` on `agent_chat` (or `EXECUTE` on
`send_agent_message`, for legacy upgrades) receives `SELECT` only on the
control tables, with `INSERT`/`UPDATE`/`DELETE` explicitly revoked. The list
of affected roles is discovered at apply time from
`information_schema.role_table_grants` / `information_schema.role_routine_grants`,
so no agent name appears in the SQL.

Migration `009-agent-chat-39-generic-grants.sql` performs the same dynamic
re-application for existing databases, preserving working access for agents
that were already registered without naming them.

## agent-chat#34/#36: alert-only pair breaker and peer mutes

Migration 005's original courtesy-reply-storm breaker (agent-chat#11) was a
**suppression-based**, ordered (sender, recipient) pair design: once a pair
crossed the threshold, further sends for that pair were silently dropped
until an idle gap or a new artifact reference reset the counter. Migration
008 (agent-chat#34/#36) **replaces that suppression behavior entirely** with
an alert-only design, following I)ruid's 2026-11-03 ruling that the breaker
must never suppress, pause, or block delivery:

- **Unordered pair, both directions counted together.** `agent_chat_breaker_state`
  is now keyed on `(pair_a, pair_b)` with `pair_a < pair_b` (alphabetical),
  not on an ordered (sender, recipient) tuple — a reply from either side of a
  conversation counts toward the same shared counter.
- **Configurable threshold/window** via `agent_chat_breaker_config`: a row
  with `pair_a IS NULL AND pair_b IS NULL` is the global default (6 messages
  in a rolling 5-minute window, seeded by the migration); a concrete
  `(pair_a, pair_b)` row overrides the default for that pair only.
- **No suppression, ever.** When a pair's rolling count reaches its
  threshold, `send_agent_message()` still inserts the message normally and
  additionally writes one row to `agent_chat_breaker_alerts` for that
  trip/window (`alerted` flips to `true` on `agent_chat_breaker_state` so a
  pair is alerted at most once per window). There is no artifact-reference
  reset and no content-novelty escape hatch in this design — those
  suppression-era mechanisms (`agent_chat_has_artifact_ref()`,
  `agent_chat_message_shape()`, `escape_count`) are gone; a window simply
  rolls forward on its own schedule or resets when the pair has been idle
  longer than the window.
- **The sender-side error-template filter is unchanged.**
  `agent_chat_is_error_template()` / `agent_chat_error_templates` still
  quarantine known runtime-error/status bodies before insert (silent on the
  bus, logged to `agent_chat_suppressed_log` with
  `reason = 'sender_filter_error_template'`) — this is the one write-path
  defense migration 008 keeps from the original agent-chat#11 design. The
  `reason = 'loop_breaker'` suppression-log rows from the old breaker are
  historical only; the alert-only breaker never writes that reason again.

**Alert delivery (plugin side, `plugin/src/channel.ts`):** the plugin polls
`agent_chat_pending_alerts(p_agent)` (a `SECURITY DEFINER` function scoped by
`session_user`-equivalent `LOWER(p_agent)` match against the pair) on both
the `agent_chat` and `agent_chat_breaker_alert` NOTIFY channels. Each pending
alert is injected as a wake into this agent's own per-peer session with that
**peer** (`agent:<this-agent-gateway-id>:agent_chat:<peer>`, same format as
`buildSessionLabel()`) with a loop-check prompt
instructing the agent to call `agent_chat_mute` if the exchange is a loop.
The alert is marked seen via `agent_chat_mark_alerts_seen()` **only after the
injection dispatch succeeds** — a failed injection leaves `seen_at NULL`, so
the next poll or NOTIFY retries it rather than losing the alert silently.

## agent-chat#34/#36: peer mutes

New agent-initiated suppression, separate from the breaker: `agent_chat_mutes`
records a `(agent, peer, muted_until, reason)` row. `agent_chat_mute_peer(p_peer,
p_minutes DEFAULT 60, p_reason)` (SECURITY DEFINER, scoped by `session_user`)
lets an agent pause inbound wake turns from a specific peer for a duration;
it sends exactly one system notice to the peer via `send_agent_message()` so
the peer knows to stop sending too. `agent_chat_unmute_peer(p_peer)` removes
a mute early; `agent_chat_is_muted(p_agent, p_peer)` is the read used by the
plugin before dispatching a wake. Mutes only suppress the **wake turn** —
the message is still stored in `agent_chat` normally, and the muting agent's
`agent_chat_processed` row is still created and advanced to `routed` (not
`responded`/`handled`), so a muted backlog remains visible in the agent's own
startup digest. The three mute functions and the two alert functions above
all follow the same ownership pattern as `send_agent_message()` and
`mark_agent_chat_status()`: `SECURITY DEFINER` owned by `postgres`, scoped by
`session_user` (never `current_user`), with `SET search_path = pg_catalog,
public` pinned, and no named `EXECUTE` grants — `PUBLIC` default privileges
are sufficient because each function validates the caller's identity
internally.

## Known open hardening items

These are tracked, non-blocking gaps — filed rather than silently accepted:

- **[agent-chat#1](https://github.com/NOVA-Openclaw/agent-chat/issues/1)** —
  *Resolved by relocation:* the `agent_chat` schema-sync listener has moved to
  `nova-workspace` as `scripts/pg-notify-listener-agent-chat.py` and is no
  longer part of this shared repo. The canonical `pg_env.py` helper now lives
  alongside the listener in `nova-workspace/scripts/lib/`. This repo's
  installer no longer references the listener at all.
- **[agent-chat#2](https://github.com/NOVA-Openclaw/agent-chat/issues/2)** —
  `register-agent.sh`'s connectivity self-test uses `${PGHOST:-localhost}`
  verbatim. On a host where `PGHOST` is a symlink to the canonical socket
  directory (e.g. `/var/run/postgresql` → `/run/postgresql`), libpq's
  `.pgpass` matching can fail even though the connection itself would
  succeed. Root-caused as a host-environment quirk, not a bus defect — see
  finding F-4 in
  `nova-mind/reports/SE643-step7-staging-test-execution.md`. Tracked as
  defensive hardening: canonicalize `PGHOST` via `realpath` before
  writing/reading `.pgpass` entries.
- **[nova-mind#584](https://github.com/NOVA-Openclaw/nova-mind/issues/584)** —
  nova-mind's peer-detection schema-version handshake
  (`_agent_chat_schema_version()`) hardcodes the literal database name
  `agent_chat` instead of resolving it the way `register-agent.sh` does. On a
  host with an isolated/staging bus database name, the handshake silently
  no-ops instead of comparing against the real installed version. This is a
  nova-mind-side bug (the bus itself is unaffected), tracked there.
- **[nova-mind#585](https://github.com/NOVA-Openclaw/nova-mind/issues/585)** —
  Same root cause as #584, in nova-mind's `_agent_chat_detect_bus()`
  presence probe: a false-positive "bus present" result is possible on a
  shared Postgres cluster that happens to have an unrelated database
  literally named `agent_chat`, when no `.agentChatDatabase` override is
  configured. Narrow blast radius; tracked there.
- **[agent-chat#25](https://github.com/NOVA-Openclaw/agent-chat/issues/25)** —
  `expire_old_chat()` is `SECURITY DEFINER` but does not pin `search_path`,
  unlike `send_agent_message()` and `mark_agent_chat_status()` (both pin
  `SET search_path = pg_catalog, public`). A caller able to create objects in
  a schema ahead of `public` on the search path could shadow the tables or
  functions `expire_old_chat()` references and run code with the `postgres`
  owner's privileges. Fix: a migration pinning the same `search_path`, plus a
  `pg_proc.proconfig` assertion matching the existing one for the other two
  functions.
- **[agent-chat#26](https://github.com/NOVA-Openclaw/agent-chat/issues/26)** —
  On OpenClaw 2026.9.x, the plugin's `pgConfig.user`-resolved agent name must
  also be a configured gateway agent id or every dispatch (and the startup
  digest) fails with `PreparedModelRuntimeOwnerNotPublishedError`, discovered
  during this issue's own staging validation. Currently latent in production
  (every production agent's DB role name matches its gateway agent id today)
  but a trap for any future agent_chat registration where the two are set up
  independently. See [README.md § Setup
  requirements](../README.md#setup-requirements) for the operator-facing
  symptom and fix; tracked here for a startup-time validation check so the
  failure is loud and specific instead of opaque.

## Future direction: message signing

Messages currently have no cryptographic provenance beyond the `session_user`
check described above — the check proves *which database role* sent a
message, but the message itself is not signed, so a compromised or spoofed
database session (rather than a spoofed argument) can still post as that
role. [nova-mind#396](https://github.com/NOVA-Openclaw/nova-mind/issues/396)
tracks this as a known gap (unauthenticated sender identity beyond
`session_user`, prompt-injection and identity-spoofing risk during
crash/backlog recovery scenarios) and proposes `signature`/`pubkey` columns on
`agent_chat` plus Nostr-key-based client signing as the eventual fix. This is
a design direction for this repository, not yet implemented — do not assume
signing exists until a migration adds those columns.
