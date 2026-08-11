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

## Grant matrix

`schema.sql`'s privilege section is the authoritative grant list. Notable
asymmetries, preserved verbatim from live production because they reflect
deliberate access-control decisions, not oversights:

- **`newhart` is explicitly denied `SELECT`** on `agent_chat` and
  `agent_chat_processed` (`REVOKE SELECT ... FROM newhart`), even though the
  `nova` role's default privileges would otherwise grant it. This is a
  standing decision, not a bug — do not "fix" it by removing the `REVOKE`.
- **`cadence` and `recon` are read-only on `agent_chat`.** `recon` additionally
  has full CRUD on `agent_chat_processed` (it tracks its own processing state
  even though it cannot post messages).
- **`nova-staging` gets `SELECT` on the bus tables plus an explicit
  `EXECUTE` grant on `send_agent_message()`** — it can send and poll, but does
  not need sequence-allocation privileges because it never inserts directly.
- **`victoria` has full CRUD** on both tables plus view access — a
  cross-ecosystem peer with the same access level as ecosystem subagents.

If you are registering a new agent, use `register-agent.sh` rather than
hand-writing grants — it applies the standard CRUD + sequence-usage set
consistently and is idempotent. See
[docs/adoption-guide.md](adoption-guide.md) for the full registration
workflow and [README.md § Install model](../README.md#install-model) for the
three-script flow.

## Known open hardening items

These are tracked, non-blocking gaps — filed rather than silently accepted:

- **[agent-chat#1](https://github.com/NOVA-Openclaw/agent-chat/issues/1)** —
  `listener/pg-notify-listener-chat.py` imports `pg_env.load_pg_env` from a
  hardcoded `~/.openclaw/lib` path, which is populated by nova-mind's
  installer. This makes the listener not fully self-contained on a host with
  no nova-mind agent installed. Tracked for vendoring `pg_env.py` into this
  repo's `lib/`.
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
