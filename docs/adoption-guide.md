# Adoption guide: migrating an existing production `agent_chat` database

This guide is for running this repository's installer against a database
that **already has data and a pre-extraction schema** — i.e. an existing
production `agent_chat` bus that predates this repo, rather than a brand-new
host getting its first-ever install. If you are installing on a host with no
existing bus, use the plain [install model](../README.md#install-model)
instead; this guide's extra caution does not apply to you.

## Why this needs its own guide

A fresh install applies `schema.sql` (which is fully idempotent —
`CREATE IF NOT EXISTS` / `CREATE OR REPLACE` throughout) against an empty
database. There is nothing to migrate away from, no existing rows, and no
window where an old and a new definition of an object coexist.

An adoption run is different. The live pre-extraction database has:

- **No `schema_version` table** — this repo's version handshake did not
  exist before the extraction, so `install.sh`'s idempotency check
  (`_is_up_to_date`, which looks for `schema_version` MAX = 3) will correctly
  treat an unmigrated production DB as needing the full schema + migrations
  applied.
- **The old, broken trigger binding** — `trg_enforce_agent_chat_function_use`
  bound to `BEFORE INSERT` only (not `UPDATE`/`DELETE`). See
  [docs/security-model.md](security-model.md#historical-defect-this-fixes)
  for the full defect description.
- **`expire_old_chat()` as a plain function**, not `SECURITY DEFINER`.
- **Real message rows** — potentially tens of thousands, with a sequence
  value in the hundreds of thousands or more, actively receiving inserts from
  live agent traffic while you run the installer.
- **An existing, hand-maintained grant matrix** across every ecosystem agent
  role plus cross-ecosystem read-only consumers.

The migration path (`schema.sql`'s idempotent apply, then
`migrations/001` → `002` → `003` in sorted order) is designed to transition
this exact starting state safely. This guide walks through what to verify
before, during, and after.

## Before you run anything: back up

```bash
pg_dump -Fc -d agent_chat -f agent_chat-pre-adoption-$(date +%Y%m%d).dump
```

Or, for a live cluster with replication already configured, take a logical
replica snapshot instead of a `pg_dump` if that's your normal backup path —
either way, **do not run the installer against production without a fresh,
verified-restorable backup taken immediately before.**

## The atomicity requirement

`migrations/002-fix-immutability-trigger-binding.sql` fixes two things in a
single transaction:

1. Rebinds `trg_enforce_agent_chat_function_use` to
   `BEFORE INSERT OR UPDATE OR DELETE`.
2. Makes `expire_old_chat()` `SECURITY DEFINER` owned by `postgres`.

The migration file's own header comment states why these cannot land
separately:

> This migration must be applied atomically in a single transaction with both
> changes, or the nightly cron breaks between them.

If the trigger fix landed first, the nightly `expire_old_chat()` cron — which
runs as role `nova`, not `postgres` — would immediately start failing every
night with a permission-denied error from the newly-enforcing `DELETE`
branch, because `expire_old_chat()` would not yet have the ownership fix that
lets its `DELETE` bypass the trigger. If the ownership fix landed first
without the trigger fix, nothing would break, but you'd have a false sense
that the "fix" was complete when the actual immutability enforcement gap
(direct `UPDATE`/`DELETE` from arbitrary roles) would still be open.

`install.sh` applies each migration file inside its own `_apply_sql_file`
call using `psql -f`, and each migration file wraps itself in
`BEGIN; ... COMMIT;`. The installer's file-by-file loop does not split a
migration's internal transaction — you get both changes or neither, never a
partial state, even if the installer process is killed between migration
files (it will simply be re-run from the top; already-applied idempotent
migrations are safe to re-apply).

## Lock behavior on a populated table

`DROP TRIGGER` / `CREATE TRIGGER` (inside migration 002) takes an
`ACCESS EXCLUSIVE` lock on `agent_chat` for the duration of the statement.
On an empty or lightly-populated table this is effectively instantaneous. On
a table with a large number of rows and concurrent `INSERT` traffic from live
`send_agent_message()` calls, expect:

- A brief lock-wait window for any concurrent `send_agent_message()` calls
  attempting to insert while the `DROP`/`CREATE TRIGGER` pair holds the lock.
  This should resolve in well under a second on typical hardware — it is not
  a full-table rewrite, just a catalog-level trigger rebind.
- No permanent blocking: once the migration's transaction commits, queued
  inserts proceed normally.

If your bus receives very high-frequency writes, consider running the
adoption migration during a lower-traffic window, even though the lock
duration itself should be short.

## Recommended: rehearse against a real snapshot first

Before running against actual production, rehearse the full sequence against
an isolated restore of a **real** production snapshot — not a synthetic
fixture. A synthetic fixture (fresh schema, no data, no drift) proves the
migration SQL is correct in isolation; it does not prove the migration
behaves correctly against your specific database's actual row volume,
sequence position, and any accumulated schema drift.

```bash
# 1. Restore a real production snapshot to an isolated instance/database.
createdb agent_chat_rehearsal
pg_restore -d agent_chat_rehearsal agent_chat-pre-adoption-YYYYMMDD.dump

# 2. Point the installer at the rehearsal database.
AGENT_CHAT_DB_NAME=agent_chat_rehearsal bash install.sh

# 3. Verify.
psql -d agent_chat_rehearsal -c "SELECT MAX(version) FROM schema_version;"   # expect 3
psql -d agent_chat_rehearsal -c "SELECT COUNT(*) FROM agent_chat;"          # compare to pre-migration count
psql -d agent_chat_rehearsal -c "\d agent_chat"                              # confirm trigger binding
```

This rehearsal is what SE run #643's QA validation step (step 8) flagged as
a **hard precondition before a production deploy/cutover** — not before
merging code or writing documentation, since neither of those touches the
live database, but specifically before the installer is ever pointed at
real production. The rehearsal should confirm, against the actual production
snapshot:

1. **Zero data loss** — same row count, same `agent_chat_id_seq` current
   value, matching content for a sample of rows (compare a hash or a
   spot-checked sample before/after).
2. **Schema diff is additive only** — `pgschema dump` before and after the
   migration should show only new objects (`schema_change_trigger`,
   `notify_schema_change()`, `schema_version`) appearing; no existing
   table/column/trigger/function should be altered or dropped outside the
   two intentional fixes in migration 002.
3. **The full grant matrix round-trips unchanged** — every existing
   per-agent grant (see [docs/security-model.md § Grant
   matrix](security-model.md#grant-matrix)) should still be present with an
   identical privilege set after the migration. `schema.sql`'s grant
   statements do not `REVOKE` before `GRANT` in the general case, so this
   risk is expected to be low, but confirm it against your actual grant list
   rather than assuming.
4. **`send_agent_message()`'s function body is unchanged** except for the
   documented, reviewed changes in this extraction (the 5-argument signature
   with `p_reply_to`, the `session_user` validation, and the self-address
   guard — all pre-existing on production before this repo's install, not
   new behavior introduced by adoption).

## Rollback

If something goes wrong mid-migration and you need to restore:

```bash
dropdb agent_chat   # or whichever database name you targeted
createdb agent_chat -O postgres
pg_restore -d agent_chat agent_chat-pre-adoption-YYYYMMDD.dump
```

Because each migration file is wrapped in its own transaction, a mid-file
failure will not leave that specific file half-applied — but if a later
migration failed after an earlier one committed, you may be at a
partially-migrated `schema_version` state. Restoring the full pre-adoption
backup is the safe, unambiguous recovery path; do not attempt to hand-roll a
partial rollback of individual migration files.

## After a successful adoption run

- Confirm `install.sh`'s idempotent re-run reports "up to date"
  (`schema_version 3, all expected objects present`) rather than re-applying
  anything.
- Run `register-agent.sh --check <agent_name>` for a few existing agents to
  confirm their roles/grants survived unchanged.
- If nova-mind hosts on this cluster use peer-detection
  (see the main [README.md § Install model](../README.md#install-model)),
  confirm the schema-version handshake reports version 3 as expected —
  though note
  [nova-mind#584](https://github.com/NOVA-Openclaw/nova-mind/issues/584)
  describes a known gap where the handshake silently no-ops on hosts where
  the bus database name differs from the literal `agent_chat` (isolated
  staging-style deployments are the common case affected; a host using the
  plain default database name is not affected).
