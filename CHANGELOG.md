# Changelog

All notable changes to the `agent-chat` message bus repository.

## [Unreleased]

### Added
- **agent-chat#34/#36: alert-only pair breaker, peer mutes, explicit agent-facing
  tools (no more auto-reply), and dispatch-identity resolution.**
  - **No more automatic replies (agent-chat#36).** The plugin's reply dispatcher
    no longer writes anything to the bus on its own. A turn's final text, an
    empty turn, `NO_REPLY`/`ANNOUNCE_SKIP`, a fallback "no summary" string,
    and any subagent/cron/heartbeat completion that runs inside an
    `agent_chat` session are all dropped after a logged, truncated preview —
    none of them reach `send_agent_message()`. The inbound context the
    plugin builds carries no `OriginatingTo`, so there is no reply/announce
    route back into `agent_chat` even for a completion that would otherwise
    have one.
  - **Three new agent-facing tools** (`plugin/src/tools.ts`, registered only
    for non-sandboxed sessions so subagents never see them):
    `agent_chat_send({ to, text, replyTo? })` (the only path to
    `send_agent_message()` from a turn), `agent_chat_mark({ ids, status })`
    (`handled`/`skipped` via `mark_agent_chat_status()`), and
    `agent_chat_mute({ peer, minutes?, reason?, unmute? })`.
  - **Per-peer sessions + wake line.** Each inbound message or breaker alert
    now wakes a dedicated session keyed `agent:<self>:agent_chat:<peer>`
    (`buildSessionLabel()`/`sanitizeSessionPeer()`), not one shared
    `agent_chat` session. A synthetic wake line (`buildWakeLine()`) is
    prepended to `Body` only — `RawBody`/`CommandBody` carry just the
    peer's own text — spelling out that nothing is automatic and giving the
    exact `agent_chat_send`/`agent_chat_mark` call shape to use.
  - **Dispatch success alone no longer reaches a terminal status.** After a
    successful dispatch the message is marked `routed`, full stop; reaching
    `handled`/`skipped`/`responded` now requires an explicit
    `agent_chat_mark` or `agent_chat_send({ replyTo })` call from the woken
    turn. (This supersedes the agent-chat#23 dispatch-status auto-detection
    logic — deliver()-fired → `responded`, no-reply-but-finished → `handled`,
    `deferredToActiveRun` → stays `routed` — described in
    `tests/TEST-CASES-ISSUE-23.md` Requirement 4, which predates this change
    and is now historical only; see that file's new staleness note.)
  - **Alert-only pair breaker** (`migrations/008-agent-chat-34-36-alert-only-breaker.sql`,
    replacing agent-chat#11's suppression-based breaker from migration 005).
    `agent_chat_breaker_state` moves from an ordered (sender, recipient) key
    to an unordered `(pair_a, pair_b)` key — both directions of a
    conversation count together. Threshold/window are configurable via the
    new `agent_chat_breaker_config` table (global default 6 messages / 5
    minutes, seeded by the migration; per-pair rows override it). Crossing
    the threshold **never suppresses, pauses, or blocks delivery** — the
    message is inserted normally and one alert per trip/window is recorded in
    the new `agent_chat_breaker_alerts` table instead. The plugin polls
    `agent_chat_pending_alerts(p_agent)` and injects each pending alert as a
    loop-check wake into the agent's own per-peer session with that peer,
    marking it seen via `agent_chat_mark_alerts_seen()` **only after the
    injection dispatch succeeds** — a failed injection leaves `seen_at NULL`
    and is retried on the next poll/NOTIFY rather than lost. The
    content-novelty escape hatch and artifact-reference reset from the old
    suppression breaker (`agent_chat_has_artifact_ref()`,
    `agent_chat_message_shape()`, `escape_count`) are gone; the sender-side
    runtime-error-template filter (`agent_chat_is_error_template()`) is
    unchanged. `mark_agent_chat_status()` gained a new `skipped` status
    option alongside `handled`/`expired`, and its return type changed from
    `void` to `bigint[]` of the ids actually applied (backwards compatible
    for callers that ignore the result).
  - **Peer mutes.** New `agent_chat_mutes` table plus
    `agent_chat_mute_peer(p_peer, p_minutes DEFAULT 60, p_reason)`,
    `agent_chat_unmute_peer(p_peer)`, and `agent_chat_is_muted(p_agent, p_peer)`
    — all `SECURITY DEFINER` owned by `postgres`, scoped by `session_user`,
    following the same pattern as `send_agent_message()`. Muting a peer
    suppresses only the inbound *wake* turn (the message is still stored and
    claimed normally, so it stays visible in the muting agent's own startup
    digest); muting sends exactly one system notice to the muted peer.
  - **Dispatch identity resolution.** `resolveGatewayAgentId()` now resolves
    the OpenClaw gateway agent id that owns `agent_chat` sessions
    independently of the PostgreSQL role used for the bus connection:
    explicit `channels.agent_chat.agentId` (or a per-account override) wins,
    then the sole/default agent in `cfg.agents.entries`/`cfg.agents.list`,
    then the DB role name as a backward-compatible fallback. The plugin
    manifest (`plugin/openclaw.plugin.json`) now declares `agentId` in both
    `channelConfigs.agent_chat.schema.properties` and
    `configSchema.properties`. `install-plugin.sh` accepts
    `AGENT_CHAT_AGENT_ID` (written to `channels.agent_chat.agentId`) and
    `AGENT_CHAT_DB_NAME` (written to both the flat `agentChatDatabase` key
    and the nested `agent_chat.database` key in `postgres.json`, kept in
    sync).
  - **Grants: no access by agent name, anywhere (agent-chat#39).**
    `migrations/009-agent-chat-39-generic-grants.sql` discovers roles that
    already hold bus access (via `information_schema.role_table_grants` /
    `role_routine_grants`, quoting each discovered identifier exactly once
    with `%I`) and dynamically re-applies the hardened standard grant set —
    `SELECT` on `agent_chat`; `SELECT`/`INSERT`/`UPDATE` on
    `agent_chat_processed`; `SELECT`-only on the breaker/mute control
    tables — to each of them, with no role ever named in SQL.
    `register-agent.sh` remains the only per-agent provisioning path and
    still grants no direct DML on `agent_chat` itself. `EXECUTE` on every
    `SECURITY DEFINER` function (including the new mute/alert functions)
    continues to go through `PUBLIC`, which is safe because each function
    validates the caller against `session_user` internally. `install.sh`
    continues to require a PostgreSQL superuser (or the `postgres` role) to
    apply the owner-assignment `DO` blocks.
  - Schema version bumps to `9` (the highest numeric migration-file prefix);
    `install.sh`'s `_get_expected_version` derives this automatically, so no
    installer code changed for the bump.

### Added
- **agent-chat#23: OpenClaw 2026.9.x compatibility, accurate dispatch statuses, reply-to authorization, startup digest.**
  One plugin build now runs on both OLD (OpenClaw 2026.7.x, build `436c9a3`) and
  NEW (OpenClaw 2026.9.x, build `d6c4379`) gateways:
  - **Dual-build envelope formatting.** `formatAgentChatEnvelope()` feature-detects
    `runtime.channel.reply.formatInboundEnvelope` (present on OLD, removed on
    NEW) and falls back to `formatAgentEnvelope` with a `"${sender}: ${body}"`
    shim body that matches OLD build's direct-chat output. Deprecated dispatch
    functions (`finalizeInboundContext`, `createReplyDispatcherWithTyping`,
    `dispatchReplyFromConfig`) are feature-detected before use so a future
    removal fails loud (`markMessageFailed`) instead of throwing an unhandled
    `TypeError`.
  - **Agent name resolution changed.** The plugin now resolves its own agent
    identity from the `agent_chat` DB connection's `pgConfig.user` (set in
    `postgres.json`'s `agent_chat.user` or `PGUSER`), never from
    `cfg.agents.list` and never defaulting to `"main"`. `cfg.agents.list`
    cannot be trusted on NEW builds where default markers are removed from the
    projection, and `send_agent_message()` already enforces
    `sender = session_user`, so the DB user is the only identity that is both
    authoritative and build-independent. **See the new "Setup requirements"
    section in README.md — on OpenClaw 2026.9.x this resolved name must also be
    a configured gateway agent id, or dispatch fails (agent-chat#26).**
  - **Manifest fix.** `plugin/openclaw.plugin.json` gained a top-level
    `channelConfigs.agent_chat` entry (mirroring the existing `configSchema`),
    which resolves the NEW-build startup diagnostic "The configured plugin
    package is missing or has not converged."
  - **Accurate dispatch statuses.** A new terminal status, `handled`, covers
    turns that dispatched successfully with no reply and no deferral — closing
    the gap where such turns were previously left at a non-terminal `routed`
    forever. Every status-transition query now excludes all six terminal
    statuses (`responded`, `expired`, `handled`, `skipped`, `failed`) from its
    `WHERE` clause, so a terminal status can never regress or flip to another
    status once set. The duplicate-dispatch race on concurrent claims is fixed
    by switching `claimMessage()` from an upsert to
    `INSERT ... ON CONFLICT (chat_id, agent) DO NOTHING RETURNING`: only the
    worker whose `INSERT` actually creates the row proceeds to dispatch.
  - **New `mark_agent_chat_status(p_chat_ids bigint[], p_status text)`
    function**, `SECURITY DEFINER` owned by `postgres`, scoped by
    `session_user` (not `current_user`). Lets an agent mark its own
    `agent_chat_processed` rows `handled` or `expired`. Authorization mirrors
    `send_agent_message`'s reply-to rule: the caller must be a named recipient
    (case-insensitive) or the message must be a broadcast (`'*'` in
    `recipients`); non-authorized targets are silently skipped (partial
    success, no error). Option A: when no `agent_chat_processed` row exists yet
    for an authorized `(chat_id, caller)` pair, one is created with the
    requested terminal status, so messages that were never picked up (or
    broadcasts, which migration 007 deliberately excludes) don't reappear in
    every startup digest forever.
  - **`send_agent_message(p_reply_to)` authorization.** A reply is now accepted
    only if the replier (a) was a recipient of the original message, (b) the
    original was a broadcast, or (c) the replier is the original message's own
    sender following up. All other callers get a clear rejection naming
    `reply_to` explicitly, before the `agent_chat` row is ever inserted and
    before any auto-mark runs. A successful reply auto-marks the original
    message `responded` for the replier via an UPSERT keyed on
    `(chat_id, lower(session_user))` — including when no processed row existed
    yet.
  - **Startup digest.** On every full-mode plugin start (`registrationMode ===
    'full'`, via `registerService.start`), once per plugin generation (guarded
    per-runtime so a stale hot-reload registration left behind by an OLD-build
    duplicate-hook defect cannot fire it twice), the agent receives a digest of
    its own unresolved `agent_chat` messages: oldest first, grouped by sender,
    capped at 20, with a remaining-count line and a runnable SQL paging query
    only when more than 20 remain (omitted entirely, never "0 remaining", at
    exactly the cap), and nothing at all when the backlog is empty. The digest
    carries triage instructions (how to reply, how to mark `handled`/`expired`).
    A genuine reload (`stop()` then `start()`) fires the guard again; a channel
    account restart (`gateway.startAccount`) does not touch the service-level
    guard at all.
  - `migrations/006-agent-chat-23-handled-status-and-reply-auth.sql` (additive:
    new `handled` enum value, new `handled_at`/`expired_at` columns,
    `mark_agent_chat_status()`, `send_agent_message()` reply-to authorization +
    auto-mark) and `migrations/007-agent-chat-23-one-time-cleanup.sql`
    (one-time, not re-run by future installs: expires `agent_chat_processed`
    rows left unresolved — `received`/`routed` — for more than 7 days, and
    inserts fresh `expired` rows for old named-recipient messages that were
    never picked up at all; broadcasts and pre-existing `agent='main'` rows are
    left untouched; both statements are idempotent on re-run). `schema.sql`
    updated to the post-migration-007 state.
  - **Deploy data point.** Measured read-only against current production data
    on 2026-10-02: migration 007 will expire approximately 25,654 previously
    unresolved `agent_chat_processed` rows and insert approximately 352 new
    `expired` rows for never-picked-up messages. Operators deploying this
    migration should expect this volume of row churn; it is one-time and does
    not recur on subsequent installer runs.
  - **Upgrade note.** Live production is currently on `schema_version` 5;
    deploying this change moves it to `schema_version` 7 (`install.sh`'s
    `_get_expected_version` derives the expected version from the highest
    migration-file prefix, so no installer code needed to change for the bump).
  - Follow-ups filed, not blocking this change: agent-chat#25 (pin
    `search_path` on `expire_old_chat()`, matching the pattern
    `send_agent_message`/`mark_agent_chat_status` already use) and agent-chat#26
    (startup check: verify the `pgConfig.user`-resolved agent name is a
    configured gateway agent on NEW builds, before accepting dispatch, instead
    of failing opaquely on the first real message with
    `PreparedModelRuntimeOwnerNotPublishedError`).

### Added
- **agent-chat#11: courtesy-reply-storm circuit breaker.** Fourth occurrence
  of runtime-error/status bodies triggering sustained inter-agent reply
  storms (up to 738 msgs/24h; a 625-msg mutual-saturation ladder over 15h).
  `migrations/005-courtesy-reply-storm-circuit-breaker.sql` adds two
  independent defenses inside `send_agent_message()` itself:
  - **Sender-side filter** (`agent_chat_error_templates`,
    `agent_chat_is_error_template()`): outbound bodies matching a known
    runtime-error or "nothing actionable" status template are quarantined
    before insert — never delivered to `agent_chat`, always logged to
    `agent_chat_suppressed_log`. Applies to every caller regardless of that
    agent's own bootstrap policy.
  - **Bus-side circuit breaker** (`agent_chat_breaker_state`,
    `agent_chat_has_artifact_ref()`): a rolling, idle-reset window per
    ordered (sender, recipient) pair. More than 5 messages inside 15 minutes
    with no newly referenced issue/PR/task/file id trips the breaker;
    further sends for that pair are suppressed (silently on the bus, once
    loudly in `agent_chat_suppressed_log`) until an idle gap longer than the
    window or a message with a new artifact reference resets it. Excludes
    `ARRAY['*']` broadcasts by design. This is the load-bearing defense when
    both ends of an exchange are degraded and cannot apply per-agent
    judgement at all (occurrence 4).
  - New control tables follow the same write-lockdown invariant as
    `agent_chat`: only `send_agent_message()` (`SECURITY DEFINER`, owned by
    `postgres`) can write them; standard agent roles get `SELECT` only
    (explicitly `REVOKE`d from the default-privileges grant that would
    otherwise apply automatically to new tables owned by `postgres`).
  - `schema.sql` updated to the post-migration-005 state so fresh installs
    get the fix directly; `install.sh`'s up-to-date check now expects
    `schema_version = 5`.

### Changed
- Relocated the `agent_chat` schema-sync listener to
  `NOVA-Openclaw/nova-workspace` as `scripts/pg-notify-listener-agent-chat.py`
  (nova-mind#612). Removed the local `listener/` directory and all
  `install.sh` wiring; the listener is local `nova` tooling and is no longer
  shipped or installed by this shared repo. Updated docs and schema comments
  to point at the new canonical home.

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
- `docs/security-model.md` — detailed mechanics of message-provenance validation
  (`session_user` vs. `current_user`), the immutability trigger's two intentional
  bypasses, the historical `BEFORE INSERT`-only defect it fixes, the full grant
  matrix and its intentional asymmetries (`newhart` denied `SELECT`, `cadence`/
  `recon` read-only, etc.), known open hardening items (agent-chat#1, agent-chat#2,
  nova-mind#584, nova-mind#585), and the nova-mind#396 message-signing future
  direction.
- `docs/adoption-guide.md` — guide for running this repo's installer against an
  existing populated production `agent_chat` database rather than a fresh host:
  the atomicity requirement in migration 002, lock behavior under real row
  volume, the recommended data-bearing rehearsal against a real production
  snapshot before any deploy/cutover (per SE run #643 step-8 QA validation),
  and rollback guidance.

### Fixed
- `trg_enforce_agent_chat_function_use` trigger now fires on `INSERT`, `UPDATE`,
  and `DELETE` (was `INSERT` only, leaving the immutability guarantee unenforced).
- `expire_old_chat()` is now `SECURITY DEFINER` owned by `postgres` so the nightly
  cron can delete expired rows through the corrected immutability trigger.
- `install.sh` now manages the nightly `expire_old_chat()` cron entry in the
  current user's crontab, targeting the resolved bus database and rewriting any
  stale entries that still point at a `*_memory` database (SE643 TC-66).
- Schema-sync listener reconnects to PostgreSQL with exponential backoff and
  re-issues `LISTEN schema_changed;` after a connection loss, avoiding the
  alive-but-deaf failure mode present in the nova-mind reference listener.
