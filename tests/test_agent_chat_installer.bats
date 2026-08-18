#!/usr/bin/env bats
# BATS tests for the agent-chat installer, register-agent, and plugin installer.
#
# Coverage:
#   TC-01..09: install.sh idempotency, schema application, no-op detection,
#              privilege errors, unreachable host, drift warnings.
#   TC-10..14: register-agent.sh name validation, --check, grant policy docs,
#              privilege errors.
#   TC-60/61: install-plugin.sh config injection, postgres.json section writes,
#             idempotency, main-field fixup.
#   Static: bash -n and shellcheck for all shipped scripts.

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

INSTALLER="$REPO_ROOT/install.sh"
REGISTER="$REPO_ROOT/register-agent.sh"
PLUGIN_INSTALLER="$REPO_ROOT/install-plugin.sh"

# Inline copy of the .pgpass helper under test (same behavior as register-agent.sh).
_ensure_pgpass_entry() {
    local host="$1"
    local port="$2"
    local database="$3"
    local user="$4"
    local password="$5"
    local pgpass="$PGPASS_FILE"
    local prefix="${host}:${port}:${database}:${user}:"
    local line="${prefix}${password}"

    if [ ! -f "$pgpass" ]; then
        touch "$pgpass"
        chmod 600 "$pgpass"
    fi

    if grep -qxF "$line" "$pgpass" 2>/dev/null; then
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)
    chmod 600 "$tmpfile"
    if [ -s "$pgpass" ]; then
        grep -vF "$prefix" "$pgpass" >"$tmpfile" 2>/dev/null || true
    fi
    printf '%s\n' "$line" >>"$tmpfile"
    mv "$tmpfile" "$pgpass"
    chmod 600 "$pgpass"
    return 0
}

# Inline copy of the postgres.json helper under test.
_ensure_agent_chat_postgres_json() {
    local pg_config="$1"
    local database="$2"
    local user="$3"
    local password="$4"

    if [ ! -f "$pg_config" ] || ! command -v jq &>/dev/null; then
        return 1
    fi

    local new_json
    new_json=$(jq --arg db "$database" --arg user "$user" --arg pass "$password" \
        'if (.agentChatDatabase // null) | type == "string" then . else .agentChatDatabase = $db end
         | if (.agent_chat // null) | type == "object" then
             .agent_chat |= . + {
                 database: (.database // $db),
                 user: (.user // $user),
                 password: (.password // $pass)
             }
           else
             .agent_chat = {"database": $db, "user": $user, "password": $pass}
           end' "$pg_config" 2>/dev/null) || return 1

    if [ "$(printf '%s\n' "$new_json" | jq -Sc .)" = "$(jq -Sc . < "$pg_config")" ]; then
        return 1
    fi

    printf '%s\n' "$new_json" >"${pg_config}.tmp" && \
        mv "${pg_config}.tmp" "$pg_config" && \
        chmod 600 "$pg_config"
}

setup() {
    FAKE_HOME="$(mktemp -d)"
    export PGPASS_FILE="$FAKE_HOME/.pgpass"
    export AGENT_CHAT_DB_NAME="agent_chat_chunk2_test_${BATS_TEST_NUMBER}_$$"
    # Create the per-test database so scripts that expect an existing bus can connect.
    createdb "$AGENT_CHAT_DB_NAME" >/dev/null 2>&1 || true

    # Install a fake crontab shim so cron installation tests never touch the
    # real user crontab of the test host.
    CRONTAB_SHIM_DIR="$(mktemp -d)"
    export CRONTAB_FILE="$CRONTAB_SHIM_DIR/crontab.txt"
    cat > "$CRONTAB_SHIM_DIR/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-l" ]; then
    if [ -f "$CRONTAB_FILE" ]; then cat "$CRONTAB_FILE"; fi
    exit 0
elif [ "${1:-}" = "-" ]; then
    cat > "$CRONTAB_FILE"
    exit 0
else
    echo "fake crontab: unsupported args $*" >&2
    exit 1
fi
EOF
    chmod +x "$CRONTAB_SHIM_DIR/crontab"
    export PATH="$CRONTAB_SHIM_DIR:$PATH"
}

teardown() {
    # Drop any test database created by this test.
    if [ -n "${AGENT_CHAT_DB_NAME:-}" ]; then
        psql -d postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"$AGENT_CHAT_DB_NAME\";" >/dev/null 2>&1 || true
    fi
    rm -rf "$FAKE_HOME"
    if [ -n "${CRONTAB_SHIM_DIR:-}" ]; then
        rm -rf "$CRONTAB_SHIM_DIR"
    fi
}

# ─── Static checks ──────────────────────────────────────────────────────────

@test "install.sh passes bash -n" {
    run bash -n "$INSTALLER"
    [ "$status" -eq 0 ]
}

@test "register-agent.sh passes bash -n" {
    run bash -n "$REGISTER"
    [ "$status" -eq 0 ]
}

@test "install-plugin.sh passes bash -n" {
    run bash -n "$PLUGIN_INSTALLER"
    [ "$status" -eq 0 ]
}

@test "lib/pg-env.sh passes bash -n" {
    run bash -n "$REPO_ROOT/lib/pg-env.sh"
    [ "$status" -eq 0 ]
}

@test "ShellCheck: zero warnings on install.sh" {
    if ! command -v shellcheck &>/dev/null; then
        skip "shellcheck not installed"
    fi
    run shellcheck "$INSTALLER"
    [ "$status" -eq 0 ]
}

@test "ShellCheck: zero warnings on register-agent.sh" {
    if ! command -v shellcheck &>/dev/null; then
        skip "shellcheck not installed"
    fi
    run shellcheck "$REGISTER"
    [ "$status" -eq 0 ]
}

@test "ShellCheck: zero warnings on install-plugin.sh" {
    if ! command -v shellcheck &>/dev/null; then
        skip "shellcheck not installed"
    fi
    run shellcheck "$PLUGIN_INSTALLER"
    [ "$status" -eq 0 ]
}

@test "ShellCheck: zero warnings on lib/pg-env.sh" {
    if ! command -v shellcheck &>/dev/null; then
        skip "shellcheck not installed"
    fi
    run shellcheck "$REPO_ROOT/lib/pg-env.sh"
    [ "$status" -eq 0 ]
}

# ─── expire_old_chat reap behavior (TC-04 regression / agent-chat#4) ────────

@test "TC-04: expire_old_chat deletes messages that have agent_chat_processed rows" {
    run "$INSTALLER"
    [ "$status" -eq 0 ]

    # In a non-superuser test environment the SECURITY DEFINER functions are
    # owned by the installing role, so the immutability trigger cannot be
    # bypassed through current_user = 'postgres'. Disable the trigger for this
    # test so we can exercise the FK path directly; the trigger itself is
    # covered by TC-01/TC-02 and the schema function tests.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c \
        "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;"

    # Insert an expired message directly. Use a timestamp in the past so it is
    # immediately eligible for reaping (retention_days = 0).
    local msg_id
    # psql -At still prints the command tag after RETURNING, so take the first line.
    msg_id=$(psql -d "$AGENT_CHAT_DB_NAME" -At -c "INSERT INTO public.agent_chat (sender, message, recipients, \"timestamp\", expires_at) VALUES ('nova', 'reap me', ARRAY['*'], now() - '1 day'::interval, now() - '1 day'::interval) RETURNING id;" | head -n 1)
    [ -n "$msg_id" ]

    # Simulate populated processing-state rows referencing the expiring message.
    # This is the FK path that staging tests 16/0/2 and 31/32 failed to exercise.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES ($msg_id, 'nova', 'responded'), ($msg_id, 'graybeard', 'routed');"

    # Reap must succeed and remove both the message and its processed-state rows.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT expire_old_chat(0);"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT COUNT(*) FROM public.agent_chat WHERE id = $msg_id;"
    [ "$output" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT COUNT(*) FROM public.agent_chat_processed WHERE chat_id = $msg_id;"
    [ "$output" -eq 0 ]
}

@test "TC-04: migration 004 is idempotent and leaves CASCADE FK validated" {
    run "$INSTALLER"
    [ "$status" -eq 0 ]

    # Re-apply migration 004 directly; must succeed without error.
    run psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/migrations/004-expire-old-chat-processed-cascade.sql"
    [ "$status" -eq 0 ]

    # FK must be ON DELETE CASCADE and VALIDATED.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT confdeltype FROM pg_constraint WHERE conname = 'agent_chat_processed_chat_id_fkey';"
    [ "$output" = "c" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT convalidated FROM pg_constraint WHERE conname = 'agent_chat_processed_chat_id_fkey';"
    [ "$output" = "t" ]
}

@test "TC-04: migration 004 cleans up orphaned processed rows and validates CASCADE FK" {
    run "$INSTALLER"
    [ "$status" -eq 0 ]

    # Disable the immutability trigger so tests can set up synthetic parent rows
    # directly. send_agent_message() is SECURITY DEFINER owned by postgres in
    # production, but in these non-superuser tests the installing role owns it,
    # so direct DML is otherwise blocked.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c \
        "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;"

    # Insert parent messages with fixed IDs and bump the sequence so later
    # installer/bootstrap inserts cannot collide with these rows.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c \
        "INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\")
         VALUES (1000, 'nova', 'parent 1', ARRAY['*'], now()),
                (1001, 'nova', 'parent 2', ARRAY['*'], now());
         SELECT setval('public.agent_chat_id_seq', 2000);"

    # Insert processed-state rows for the existing parents.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c \
        "INSERT INTO public.agent_chat_processed (chat_id, agent, status)
         VALUES (1000, 'nova', 'responded'),
                (1000, 'graybeard', 'routed'),
                (1001, 'nova', 'responded');"

    # Drop the FK to simulate the production window in which parent deletions
    # and bogus processed rows were not constrained. This is the only reliable
    # way to create orphan rows in PostgreSQL: remove the constraint, delete
    # the parent/insert bogus children, then re-add it as NOT VALID (which
    # skips validation of the already-orphaned rows).
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c \
        "ALTER TABLE public.agent_chat_processed DROP CONSTRAINT IF EXISTS agent_chat_processed_chat_id_fkey;
         DELETE FROM public.agent_chat WHERE id = 1001;
         INSERT INTO public.agent_chat_processed (chat_id, agent, status)
             VALUES (2000, 'nova', 'responded'),
                    (2001, 'graybeard', 'routed');
         ALTER TABLE public.agent_chat_processed ADD CONSTRAINT agent_chat_processed_chat_id_fkey
             FOREIGN KEY (chat_id) REFERENCES public.agent_chat (id) NOT VALID;"

    # Re-apply migration 004. It must delete the three orphans, validate the
    # new CASCADE FK, and leave the two valid rows for chat_id 1000 intact.
    run psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/migrations/004-expire-old-chat-processed-cascade.sql"
    [ "$status" -eq 0 ]

    # No orphans remain.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT COUNT(*) FROM public.agent_chat_processed WHERE chat_id NOT IN (SELECT id FROM public.agent_chat);"
    [ "$output" -eq 0 ]

    # Valid processed rows for the surviving parent are preserved.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT COUNT(*) FROM public.agent_chat_processed WHERE chat_id = 1000;"
    [ "$output" -eq 2 ]

    # FK is now ON DELETE CASCADE and VALIDATED.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT confdeltype FROM pg_constraint WHERE conname = 'agent_chat_processed_chat_id_fkey';"
    [ "$output" = "c" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT convalidated FROM pg_constraint WHERE conname = 'agent_chat_processed_chat_id_fkey';"
    [ "$output" = "t" ]
}

# ─── expire_old_chat cron (TC-66) ───────────────────────────────────────────

@test "TC-66: fresh install creates expire_old_chat cron entry targeting bus DB" {
    run "$INSTALLER"
    [ "$status" -eq 0 ]
    [ -f "$CRONTAB_FILE" ]
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 1 ]
    run grep -qxF "30 3 * * * psql -d \"$AGENT_CHAT_DB_NAME\" -c \"SELECT expire_old_chat();\" # agent-chat-expire-old-chat" "$CRONTAB_FILE"
    [ "$status" -eq 0 ]
}

@test "TC-66: re-run is idempotent (no duplicate expire_old_chat entries)" {
    "$INSTALLER" >/dev/null
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 1 ]
    "$INSTALLER" >/dev/null
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 1 ]
}

@test "TC-66: stale *_memory-targeting expire_old_chat entry is rewritten" {
    printf '%s\n' '30 4 * * * psql -d "nova_memory" -c "SELECT expire_old_chat();"' > "$CRONTAB_FILE"
    run "$INSTALLER"
    [ "$status" -eq 0 ]
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 1 ]
    run grep -qF 'nova_memory' "$CRONTAB_FILE"
    [ "$status" -ne 0 ]
    run grep -qxF "30 4 * * * psql -d \"$AGENT_CHAT_DB_NAME\" -c \"SELECT expire_old_chat();\" # agent-chat-expire-old-chat" "$CRONTAB_FILE"
    [ "$status" -eq 0 ]
}

@test "TC-66: unrelated crontab lines are preserved" {
    printf '%s\n' '0 5 * * * echo hello' > "$CRONTAB_FILE"
    run "$INSTALLER"
    [ "$status" -eq 0 ]
    run grep -qxF "0 5 * * * echo hello" "$CRONTAB_FILE"
    [ "$status" -eq 0 ]
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 1 ]
}

@test "TC-66: AGENT_CHAT_SKIP_CRON=1 skips cron installation" {
    printf '%s\n' '0 5 * * * echo hello' > "$CRONTAB_FILE"
    AGENT_CHAT_SKIP_CRON=1 run "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT_CHAT_SKIP_CRON=1; skipping expire_old_chat cron installation"* ]]
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 0 ]
    run grep -qxF "0 5 * * * echo hello" "$CRONTAB_FILE"
    [ "$status" -eq 0 ]
}

# ─── install.sh (TC-01..09) ─────────────────────────────────────────────────

@test "TC-01: fresh install creates DB, schema, and expected objects" {
    run "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applied schema.sql"* ]]
    [[ "$output" == *"Applied 001"* ]]
    [[ "$output" == *"Applied 004"* ]]

    # Verify schema_version.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT MAX(version) FROM public.schema_version;"
    [ "$output" = "4" ]

    # Verify core objects.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT proname FROM pg_proc WHERE proname = 'send_agent_message';"
    [ "$output" = "send_agent_message" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tgname FROM pg_trigger WHERE tgname = 'trg_enforce_agent_chat_function_use';"
    [ "$output" = "trg_enforce_agent_chat_function_use" ]
}

@test "TC-02: idempotent re-run reports 'up to date'" {
    "$INSTALLER" >/dev/null
    run "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
}

@test "TC-08: re-run after partial failure completes without duplicate errors" {
    # Simulate partial state: drop any DB from setup and create an empty one,
    # then run installer to complete it.
    psql -d postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"$AGENT_CHAT_DB_NAME\";" >/dev/null 2>&1 || true
    createdb "$AGENT_CHAT_DB_NAME" >/dev/null
    run "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applied schema.sql"* ]]
    [[ "$output" != *"database already exists"* ]]
}

@test "TC-05: installer warns on unrecognized column drift but does not fail" {
    "$INSTALLER" >/dev/null
    psql -d "$AGENT_CHAT_DB_NAME" -c "ALTER TABLE public.agent_chat ADD COLUMN drift_col text;" >/dev/null
    run "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected column drift"* ]]
    # The drift column must survive.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT 1 FROM information_schema.columns WHERE table_name = 'agent_chat' AND column_name = 'drift_col';"
    [ "$output" = "1" ]
}

@test "TC-06: installer fails clearly with a non-CREATEDB role" {
    # Re-use the limited cadence/recon-style role if it exists; otherwise test
    # via a deliberately bad user string. The goal is a clean error, not a raw
    # stack trace.
    if psql -d postgres -At -c "SELECT 1 FROM pg_roles WHERE rolname = 'recon';" | grep -q "1"; then
        run env PGUSER=recon "$INSTALLER"
    else
        # Fall back to an unreachable-auth scenario: force a connection failure
        # that the script must surface cleanly.
        run env PGUSER="__no_such_user__" "$INSTALLER"
    fi
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot connect"* ]] || [[ "$output" == *"lacks CREATEDB"* ]]
}

@test "TC-07: installer against unreachable host exits cleanly without artifacts" {
    # Pick a port that is very unlikely to be used.
    run env PGPORT="65432" "$INSTALLER"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot connect"* ]]
}

# ─── register-agent.sh (TC-10..14) ──────────────────────────────────────────

@test "TC-14: rejects invalid/malicious agent names" {
    run "$REGISTER" '"; DROP TABLE agent_chat; --'
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid lowercase PostgreSQL identifier"* ]]

    run "$REGISTER" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"Agent name cannot be empty"* ]]

    run "$REGISTER" "postgres"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved PostgreSQL role"* ]]

    run "$REGISTER" "public"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved PostgreSQL role"* ]]

    # 64-character name exceeds 63-byte Postgres identifier limit.
    local long_name
    long_name=$(printf '%064s' | tr ' ' 'a')
    run "$REGISTER" "$long_name"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exceeds 63 bytes"* ]]
}

@test "TC-10/TC-14: accepts valid 63-byte boundary name" {
    local boundary_name
    boundary_name=$(printf '%063s' | tr ' ' 'a')
    run "$REGISTER" --check "$boundary_name"
    # Role does not exist, but validation must pass and exit non-zero only
    # because the role is missing.
    [ "$status" -ne 0 ]
    [[ "$output" == *"is NOT registered"* ]]
}

@test "TC-11/TC-12: .pgpass helper replaces stale entries and avoids duplicates" {
    run _ensure_pgpass_entry "localhost" "5432" "agent_chat" "nova" "oldpass"
    [ "$status" -eq 0 ]

    run _ensure_pgpass_entry "localhost" "5432" "agent_chat" "nova" "newpass"
    [ "$status" -eq 0 ]

    run grep -cF "localhost:5432:agent_chat:nova:" "$PGPASS_FILE"
    [ "$output" -eq 1 ]

    run grep -qxF "localhost:5432:agent_chat:nova:newpass" "$PGPASS_FILE"
    [ "$status" -eq 0 ]

    run grep -qF "localhost:5432:agent_chat:nova:oldpass" "$PGPASS_FILE"
    [ "$status" -ne 0 ]
}

@test "TC-13: grant always-standard policy is documented in --help" {
    run "$REGISTER" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"always applies the standard grant set"* ]]
}

@test "register-agent: --check reports missing role" {
    run "$REGISTER" --check "chunk2_nonexistent_agent_$$"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT registered"* ]]
}

@test "register-agent: fails clearly when run without CREATEROLE" {
    run "$REGISTER" "chunk2_some_agent_$$"
    [ "$status" -ne 0 ]
    [[ "$output" == *"lacks CREATEROLE"* ]]
}

# ─── install-plugin.sh (TC-60/61) ───────────────────────────────────────────

@test "TC-60: install-plugin.sh writes postgres.json agent_chat section" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    echo '{}' > "$oc_dir/openclaw.json"

    AGENT_CHAT_DB_NAME="agent_chat" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "testpass"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.agent_chat.database' "$oc_dir/postgres.json")" = "agent_chat" ]
    [ "$(jq -r '.agent_chat.user' "$oc_dir/postgres.json")" = "testagent" ]
    [ "$(jq -r '.agent_chat.password' "$oc_dir/postgres.json")" = "testpass" ]
}

@test "TC-60: install-plugin.sh injects openclaw config without credentials" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    cat > "$oc_dir/postgres.json" <<'EOF'
{
  "host": "localhost",
  "port": 5432,
  "database": "nova_memory",
  "user": "nova",
  "password": "secret1"
}
EOF
    cat > "$oc_dir/openclaw.json" <<'EOF'
{
  "channels": {
    "agent_chat": {
      "enabled": false,
      "database": "nova_memory",
      "host": "localhost",
      "port": 5432,
      "user": "nova",
      "password": "secret1",
      "pollIntervalMs": 500
    }
  },
  "plugins": {
    "entries": {
      "agent_chat": {
        "enabled": false,
        "config": {
          "database": "nova_memory",
          "host": "localhost",
          "port": 5432,
          "user": "nova",
          "password": "secret1",
          "routeToSession": "other"
        }
      }
    }
  }
}
EOF

    AGENT_CHAT_DB_NAME="agent_chat" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "testpass"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.channels.agent_chat.enabled' "$oc_dir/openclaw.json")" = "true" ]
    [ "$(jq -r '.channels.agent_chat.database' "$oc_dir/openclaw.json")" = "null" ]
    [ "$(jq -r '.channels.agent_chat.pollIntervalMs' "$oc_dir/openclaw.json")" = "500" ]
    [ "$(jq -r '.plugins.entries.agent_chat.enabled' "$oc_dir/openclaw.json")" = "true" ]
    [ "$(jq -r '.plugins.entries.agent_chat.config.routeToSession' "$oc_dir/openclaw.json")" = "main" ]
    [ "$(jq -r '.plugins.entries.agent_chat.config.password' "$oc_dir/openclaw.json")" = "null" ]
}

@test "TC-60: install-plugin.sh is idempotent (no duplicate keys)" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    echo '{}' > "$oc_dir/openclaw.json"

    AGENT_CHAT_DB_NAME="agent_chat" "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "testpass" >/dev/null
    AGENT_CHAT_DB_NAME="agent_chat" "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "testpass" >/dev/null

    run jq '.channels.agent_chat | keys | length' "$oc_dir/openclaw.json"
    [ "$output" -eq 1 ]

    run jq '.plugins.entries.agent_chat.config | keys | length' "$oc_dir/openclaw.json"
    [ "$output" -eq 1 ]
}

@test "TC-60: install-plugin.sh fixes openclaw.plugin.json main field" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    echo '{}' > "$oc_dir/openclaw.json"

    # Create a broken plugin manifest in the synced target and verify fixup.
    AGENT_CHAT_DB_NAME="agent_chat" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "testpass"
    [ "$status" -eq 0 ]

    # The source manifest is correct; ensure the target copied it and fixup idempotently keeps it correct.
    [ "$(jq -r '.main' "$oc_dir/extensions/agent_chat/openclaw.plugin.json")" = "./dist/index.js" ]

    # Simulate a broken target manifest and re-run to verify fixup.
    sed -i 's|"main": "./dist/index.js"|"main": "./index.ts"|' "$oc_dir/extensions/agent_chat/openclaw.plugin.json"
    AGENT_CHAT_DB_NAME="agent_chat" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "testpass"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.main' "$oc_dir/extensions/agent_chat/openclaw.plugin.json")" = "./dist/index.js" ]
}

# ─── Plugin build verification ──────────────────────────────────────────────

@test "Plugin builds successfully in repo" {
    cd "$REPO_ROOT/plugin"
    run npm run build
    [ "$status" -eq 0 ]
    [ -f "$REPO_ROOT/plugin/dist/index.js" ]
}
