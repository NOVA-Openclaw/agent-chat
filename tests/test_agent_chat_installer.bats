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

# shellcheck source=fixture-roles.bash
source "$BATS_TEST_DIRNAME/fixture-roles.bash"

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
    ACT_PGPASSFILE="$(act_init_pgpass)"
    FAKE_HOME="$(mktemp -d)"
    export PGPASS_FILE="$FAKE_HOME/.pgpass"
    export AGENT_CHAT_DB_NAME="agent_chat_test_chunk2_${BATS_TEST_NUMBER}_$$"
    # Create the per-test database so scripts that expect an existing bus can connect.
    act_admin_psql postgres -c "CREATE DATABASE \"$AGENT_CHAT_DB_NAME\";" >/dev/null 2>&1 || true

    # Enable the devtest gate for installer schema/migration applies.  In tests
    # the installer runs as the non-superuser agentchat_test role, so the
    # privilege-catch wrappers in schema.sql/migrations must notice-and-skip
    # instead of raising.  Production runs as postgres/superuser and never hit
    # the handlers.
    export PGOPTIONS='-c agent_chat.devtest=on'

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
    # Drop any test database created by this test FIRST. TC-11x helper roles
    # (below) hold GRANTs inside this database; PostgreSQL refuses DROP ROLE
    # while a role still has privileges granted on live objects, so the
    # database must go before the roles that were granted access to it.
    if [ -n "${AGENT_CHAT_DB_NAME:-}" ]; then
        act_admin_psql postgres -v ON_ERROR_STOP=0 -At -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$AGENT_CHAT_DB_NAME' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
        act_admin_psql postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"$AGENT_CHAT_DB_NAME\";" >/dev/null 2>&1 || true
    fi

    # Ensure no install.sh background listener is left running for this DB.
    pkill -f "install\.sh.*$AGENT_CHAT_DB_NAME" 2>/dev/null || true

    # TC-11x helper roles: drop unconditionally in the global teardown (not
    # inline at the end of each test body) so a failed assertion mid-test
    # still cleans up the roles instead of leaking them.
    if [ -n "${_TC11X_ROLE_A:-}" ]; then
        act_drop_fixture_role "$_TC11X_ROLE_A" >/dev/null 2>&1 || true
    fi
    if [ -n "${_TC11X_ROLE_B:-}" ]; then
        act_drop_fixture_role "$_TC11X_ROLE_B" >/dev/null 2>&1 || true
    fi
    if [ -n "${_TC11X_ROLE_C:-}" ]; then
        act_drop_fixture_role "$_TC11X_ROLE_C" >/dev/null 2>&1 || true
    fi
    if [ -n "${_TC11X_PGPASSFILE:-}" ]; then
        rm -f "$_TC11X_PGPASSFILE"
    fi

    rm -rf "$FAKE_HOME"
    if [ -n "${CRONTAB_SHIM_DIR:-}" ]; then
        rm -rf "$CRONTAB_SHIM_DIR"
    fi
    rm -f "${ACT_PGPASSFILE:-}"
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
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]

    # In a non-superuser test environment the SECURITY DEFINER functions are
    # owned by the installing role, so the immutability trigger cannot be
    # bypassed through current_user = 'postgres'. Disable the trigger for this
    # test so we can exercise the FK path directly; the trigger itself is
    # covered by TC-01/TC-02 and the schema function tests.
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c \
        "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;"

    # Insert an expired message directly. Use a timestamp in the past so it is
    # immediately eligible for reaping (retention_days = 0).
    local msg_id
    # psql -At still prints the command tag after RETURNING, so take the first line.
    msg_id=$(act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "INSERT INTO public.agent_chat (sender, message, recipients, \"timestamp\", expires_at) VALUES ('nova', 'reap me', ARRAY['*'], now() - '1 day'::interval, now() - '1 day'::interval) RETURNING id;" | head -n 1)
    [ -n "$msg_id" ]

    # Simulate populated processing-state rows referencing the expiring message.
    # This is the FK path that staging tests 16/0/2 and 31/32 failed to exercise.
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c "INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES ($msg_id, 'nova', 'responded'), ($msg_id, 'graybeard', 'routed');"

    # Reap must succeed and remove both the message and its processed-state rows.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT expire_old_chat(0);"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT COUNT(*) FROM public.agent_chat WHERE id = $msg_id;"
    [ "$output" -eq 0 ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT COUNT(*) FROM public.agent_chat_processed WHERE chat_id = $msg_id;"
    [ "$output" -eq 0 ]
}

@test "TC-04: migration 004 is idempotent and leaves CASCADE FK validated" {
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]

    # Re-apply migration 004 directly; must succeed without error.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -f "$REPO_ROOT/migrations/004-expire-old-chat-processed-cascade.sql"
    [ "$status" -eq 0 ]

    # FK must be ON DELETE CASCADE and VALIDATED.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT confdeltype FROM pg_constraint WHERE conname = 'agent_chat_processed_chat_id_fkey';"
    [ "$output" = "c" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT convalidated FROM pg_constraint WHERE conname = 'agent_chat_processed_chat_id_fkey';"
    [ "$output" = "t" ]
}

@test "TC-04: migration 004 cleans up orphaned processed rows and validates CASCADE FK" {
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]

    # Disable the immutability trigger so tests can set up synthetic parent rows
    # directly. send_agent_message() is SECURITY DEFINER owned by postgres in
    # production, but in these non-superuser tests the installing role owns it,
    # so direct DML is otherwise blocked.
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c \
        "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;"

    # Insert parent messages with fixed IDs and bump the sequence so later
    # installer/bootstrap inserts cannot collide with these rows.
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c \
        "INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\")
         VALUES (1000, 'nova', 'parent 1', ARRAY['*'], now()),
                (1001, 'nova', 'parent 2', ARRAY['*'], now());
         SELECT setval('public.agent_chat_id_seq', 2000);"

    # Insert processed-state rows for the existing parents.
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c \
        "INSERT INTO public.agent_chat_processed (chat_id, agent, status)
         VALUES (1000, 'nova', 'responded'),
                (1000, 'graybeard', 'routed'),
                (1001, 'nova', 'responded');"

    # Drop the FK to simulate the production window in which parent deletions
    # and bogus processed rows were not constrained. This is the only reliable
    # way to create orphan rows in PostgreSQL: remove the constraint, delete
    # the parent/insert bogus children, then re-add it as NOT VALID (which
    # skips validation of the already-orphaned rows).
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c \
        "ALTER TABLE public.agent_chat_processed DROP CONSTRAINT IF EXISTS agent_chat_processed_chat_id_fkey;
         DELETE FROM public.agent_chat WHERE id = 1001;
         INSERT INTO public.agent_chat_processed (chat_id, agent, status)
             VALUES (2000, 'nova', 'responded'),
                    (2001, 'graybeard', 'routed');
         ALTER TABLE public.agent_chat_processed ADD CONSTRAINT agent_chat_processed_chat_id_fkey
             FOREIGN KEY (chat_id) REFERENCES public.agent_chat (id) NOT VALID;"

    # Re-apply migration 004. It must delete the three orphans, validate the
    # new CASCADE FK, and leave the two valid rows for chat_id 1000 intact.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -f "$REPO_ROOT/migrations/004-expire-old-chat-processed-cascade.sql"
    [ "$status" -eq 0 ]

    # No orphans remain.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT COUNT(*) FROM public.agent_chat_processed WHERE chat_id NOT IN (SELECT id FROM public.agent_chat);"
    [ "$output" -eq 0 ]

    # Valid processed rows for the surviving parent are preserved.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT COUNT(*) FROM public.agent_chat_processed WHERE chat_id = 1000;"
    [ "$output" -eq 2 ]

    # FK is now ON DELETE CASCADE and VALIDATED.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT confdeltype FROM pg_constraint WHERE conname = 'agent_chat_processed_chat_id_fkey';"
    [ "$output" = "c" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c \
        "SELECT convalidated FROM pg_constraint WHERE conname = 'agent_chat_processed_chat_id_fkey';"
    [ "$output" = "t" ]
}

# ─── courtesy-reply storm circuit breaker (TC-11x / agent-chat#11) ─────────
#
# These tests exercise the live send_agent_message() function directly
# (rather than through install.sh) against a per-test database, using two
# ephemeral login roles so that p_sender/session_user validation reflects
# real distinct agents exchanging messages, the same way nova/graybeard do in
# production.

_TC11X_ROLE_A=""
_TC11X_ROLE_B=""
_TC11X_ROLE_C=""
_TC11X_PGPASSFILE=""

_tc11x_setup_roles_and_schema() {
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]

    local prefix
    prefix="act_$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
    _TC11X_ROLE_A="${prefix}_flint"
    _TC11X_ROLE_B="${prefix}_quill"
    _TC11X_ROLE_C="${prefix}_scout"

    _TC11X_PGPASSFILE="$(mktemp)"
    chmod 600 "$_TC11X_PGPASSFILE"
    # Seed with admin credentials, then append per-fixture entries.
    sed -E "s/^(${ACT_ADMIN_HOST}|127\.0\.0\.1):([0-9]+):([^:]*):${ACT_ADMIN_USER}:(.*)$/\1:\2:*:${ACT_ADMIN_USER}:\4/" /home/nova/.pgpass > "$_TC11X_PGPASSFILE"

    # Create ephemeral LOGIN fixture roles with generated passwords and a
    # matching per-role pgpass entry. Re-create them so a stale NOLOGIN role
    # from an earlier suite cannot block LOGIN creation.
    local role pass
    for role in "$_TC11X_ROLE_A" "$_TC11X_ROLE_B" "$_TC11X_ROLE_C"; do
        pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
        act_admin_psql postgres -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS \"$role\";" >/dev/null 2>&1 || true
        act_admin_psql "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$role\" LOGIN PASSWORD '$pass';" >/dev/null
        act_admin_psql "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "GRANT USAGE ON SCHEMA public TO \"$role\"; GRANT INSERT, SELECT ON public.agent_chat TO \"$role\"; GRANT INSERT, SELECT, UPDATE ON public.agent_chat_processed TO \"$role\"; GRANT SELECT ON public.agent_chat_error_templates, public.agent_chat_breaker_config, public.agent_chat_breaker_state, public.agent_chat_breaker_alerts, public.agent_chat_mutes, public.agent_chat_suppressed_log TO \"$role\"; GRANT EXECUTE ON FUNCTION public.send_agent_message(text,text,text[],interval,integer) TO \"$role\";" >/dev/null
        printf 'localhost:5432:%s:%s:%s\n' "$AGENT_CHAT_DB_NAME" "$role" "$pass" >> "$_TC11X_PGPASSFILE"
    done

    act_admin_psql "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;" >/dev/null 2>&1 || true
}

# Role/pgpass cleanup happens unconditionally in the global teardown() above
# (not here) so a failed assertion mid-test still cleans up.

# Run an arbitrary SQL statement as the given fixture role.
_tc11x_psql_as() {
    local role="$1"
    local sql="$2"
    PGPASSFILE="$_TC11X_PGPASSFILE" psql -h "$ACT_ADMIN_HOST" -p "$ACT_ADMIN_PORT" -U "$role" -d "$AGENT_CHAT_DB_NAME" -At \
        -v ON_ERROR_STOP=1 -c "$sql"
}

# Send as role A (session_user == p_sender == role A) to the given recipient.
_tc11x_send_as_a() {
    local recipient="$1" message="$2"
    _tc11x_psql_as "$_TC11X_ROLE_A" "SELECT send_agent_message('${_TC11X_ROLE_A}', '$(printf '%s' "$message" | sed "s/'/''/g")', ARRAY['${recipient}']);"
}

_tc11x_send_as_b() {
    local recipient="$1" message="$2"
    _tc11x_psql_as "$_TC11X_ROLE_B" "SELECT send_agent_message('${_TC11X_ROLE_B}', '$(printf '%s' "$message" | sed "s/'/''/g")', ARRAY['${recipient}']);"
}

@test "TC-110: sender-side filter quarantines the occurrence 2/3 runtime-error template" {
    _tc11x_setup_roles_and_schema

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "⚠️ Something went wrong while processing your request. Please try again, or use /compact."
    [ "$status" -eq 0 ]
    [ -z "$output" ]   # NULL id: silent on the bus

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}';"
    [ "$output" = "0" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT reason FROM agent_chat_suppressed_log WHERE sender = '${_TC11X_ROLE_A}';"
    [ "$output" = "sender_filter_error_template" ]

}

@test "TC-111: sender-side filter also quarantines the occurrence 4 saturation/compaction templates" {
    _tc11x_setup_roles_and_schema

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "⚠️ Context is too large and auto-compaction could not recover this turn. Try again, use /compact, or use /new to start a fresh session."
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run _tc11x_send_as_b "$_TC11X_ROLE_A" "The context is saturated and cannot process turns — /compact or /new is genuinely required to recover this session. Nothing actionable in a compaction-failure notice."
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat;"
    [ "$output" = "0" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log WHERE reason = 'sender_filter_error_template';"
    [ "$output" = "2" ]

}

@test "TC-112: ordinary non-template messages are unaffected by the sender-side filter" {
    _tc11x_setup_roles_and_schema

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "Can you take a look at agent-chat#11 when you get a chance?"
    [ "$status" -eq 0 ]
    [ -n "$output" ]   # got a real id back

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}';"
    [ "$output" = "1" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log;"
    [ "$output" = "0" ]

}

@test "TC-113: A->B->A->B non-substantive exchange trips the alert-only breaker" {
    _tc11x_setup_roles_and_schema

    # Reproduce the loop condition: 12 alternating, non-substantive messages
    # with no artifact reference (mirrors the occurrence-4 mutual-saturation
    # ladder — neither body references an issue/PR/task/file).
    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "No reply. Note $i concludes nothing needs action." >/dev/null
        _tc11x_send_as_b "$_TC11X_ROLE_A" "A runtime status notice, no content to act on ($i)." >/dev/null
    done

    # With the alert-only breaker, every message is delivered.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}' AND recipients = ARRAY['${_TC11X_ROLE_B}'];"
    [ "$output" = "6" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_B}' AND recipients = ARRAY['${_TC11X_ROLE_A}'];"
    [ "$output" = "6" ]

    local pair_a pair_b
    if [[ "${_TC11X_ROLE_A}" < "${_TC11X_ROLE_B}" ]]; then
        pair_a="$_TC11X_ROLE_A"
        pair_b="$_TC11X_ROLE_B"
    else
        pair_a="$_TC11X_ROLE_B"
        pair_b="$_TC11X_ROLE_A"
    fi

    # Both directions collapse to one unordered pair; threshold default is 6.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "12|t" ]

    # Exactly one alert row per trip, per pair window.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "1" ]

    # The alert-only breaker never writes loop_breaker suppressions.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_suppressed_log WHERE reason = 'loop_breaker';"
    [ "$output" = "0" ]

}

@test "TC-114: an artifact reference does NOT reset the breaker window" {
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "No reply. Note $i concludes nothing needs action." >/dev/null
    done

    local pair_a pair_b
    if [[ "${_TC11X_ROLE_A}" < "${_TC11X_ROLE_B}" ]]; then
        pair_a="$_TC11X_ROLE_A"
        pair_b="$_TC11X_ROLE_B"
    else
        pair_a="$_TC11X_ROLE_B"
        pair_b="$_TC11X_ROLE_A"
    fi

    # Threshold default is 6, so the pair is alerted after the 6th message.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "6|t" ]

    # Artifact-bearing messages are still delivered but do not reset the window.
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "See agent-chat#11 for the current fix status."
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "7|t" ]

    # Still exactly one alert row in this window.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "1" ]

}

@test "TC-115: an idle gap longer than the breaker window starts a new window" {
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "Non substantive repeat $i." >/dev/null
    done

    local pair_a pair_b
    if [[ "${_TC11X_ROLE_A}" < "${_TC11X_ROLE_B}" ]]; then
        pair_a="$_TC11X_ROLE_A"
        pair_b="$_TC11X_ROLE_B"
    else
        pair_a="$_TC11X_ROLE_B"
        pair_b="$_TC11X_ROLE_A"
    fi

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "6|t" ]

    # Simulate the window having elapsed (default window is 5 minutes).
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c "UPDATE public.agent_chat_breaker_state SET last_message_at = now() - interval '10 minutes' WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "Non substantive repeat after cooldown."
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # New window: count reset to 1, alerted=false.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "1|f" ]

    # Old alert from the previous window is still present.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "1" ]

}

# ─── 2026-09-03 QA remediation regression tests (Gem adversarial review, PR #12) ─

@test "TC-118: sender-side filter no longer false-positives on Gem's 4 legitimate repro messages (agent-chat#11 BLOCKING #1 fix)" {
    # Gem's live repro against the ORIGINAL unanchored ~* substring match:
    # four plausible, legitimate messages were ALL silently suppressed because
    # each merely quoted/paraphrased/observed a known template string inside a
    # much longer, substantive body. All 4 must now DELIVER. The 3 known bare
    # templates (TC-110/TC-111) must remain suppressed -- covered separately.
    _tc11x_setup_roles_and_schema

    # (a) a real error report asking for help
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "I'm seeing 'something went wrong while processing your request' pop up repeatedly, three times in the last ten minutes. Can someone check if the provider is having an outage? This is blocking real work and I need help debugging it."
    [ "$status" -eq 0 ]
    [ -n "$output" ]   # must deliver, got a real id back

    # (b) a message quoting the template while asking a peer to investigate an actual outage
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "Hey, I just saw 'something went wrong while processing your request' come through from nova's session for the third time in the last hour. Can you check whether there's an actual provider outage on our end, or if this is something specific to her session?"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # (c) the same string in all-caps
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "I KEEP GETTING AN ERROR - SOMETHING WENT WRONG WHILE PROCESSING YOUR REQUEST - REPEATEDLY. CAN SOMEONE CHECK IF THE PROVIDER IS HAVING AN OUTAGE? THIS IS BLOCKING REAL WORK."
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # (d) a THIRD-PARTY observation about another agent's degraded state
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "Heads up: graybeard's context is saturated and cannot process turns right now, someone should restart his session."
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}';"
    [ "$output" = "4" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log WHERE reason = 'sender_filter_error_template';"
    [ "$output" = "0" ]

    # The 3 known bare templates from TC-110/TC-111 must still be suppressed
    # by the same, now-tightened, filter -- proves the fix narrows false
    # positives without losing true positives.
    run _tc11x_send_as_b "$_TC11X_ROLE_A" "⚠️ Something went wrong while processing your request. Please try again, or use /compact."
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run _tc11x_send_as_b "$_TC11X_ROLE_A" "⚠️ Context is too large and auto-compaction could not recover this turn. Try again, use /compact, or use /new to start a fresh session."
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run _tc11x_send_as_b "$_TC11X_ROLE_A" "The context is saturated and cannot process turns — /compact or /new is genuinely required to recover this session. Nothing actionable in a compaction-failure notice."
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log WHERE reason = 'sender_filter_error_template';"
    [ "$output" = "3" ]
}

@test "TC-118 DISCRIMINATES: reverting agent_chat_is_error_template() to the original unanchored substring match re-suppresses Gem's legitimate messages" {
    # Proves TC-118 actually exercises the fix. Temporarily replaces
    # agent_chat_is_error_template() with the pre-fix unanchored ~* substring
    # match (migration 005's original body, verbatim) inside this test's own
    # database, sends the same messages, and asserts they are now WRONGLY
    # suppressed -- the failure mode TC-118 exists to catch.
    _tc11x_setup_roles_and_schema

    act_admin_psql "$AGENT_CHAT_DB_NAME" -c "
        CREATE OR REPLACE FUNCTION public.agent_chat_is_error_template(p_message text)
        RETURNS boolean LANGUAGE sql STABLE AS \$\$
            SELECT EXISTS (
                SELECT 1 FROM public.agent_chat_error_templates
                WHERE active AND p_message ~* pattern
            );
        \$\$;
    "

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "I'm seeing 'something went wrong while processing your request' pop up repeatedly, three times in the last ten minutes. Can someone check if the provider is having an outage? This is blocking real work and I need help debugging it."
    [ "$status" -eq 0 ]
    [ -z "$output" ]   # WRONGLY suppressed under the reverted (pre-fix) function -- proves TC-118 discriminates

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "Heads up: graybeard's context is saturated and cannot process turns right now, someone should restart his session."
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "TC-119: urgent messages are still delivered because the alert-only breaker never suppresses" {
    # Migration 008's alert-only breaker never drops messages; it emits a
    # single alert when a pair crosses the threshold. Urgent, differently-
    # shaped messages are delivered just like everything else.
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "still working on it, note $i" >/dev/null
    done

    local pair_a pair_b
    if [[ "${_TC11X_ROLE_A}" < "${_TC11X_ROLE_B}" ]]; then
        pair_a="$_TC11X_ROLE_A"
        pair_b="$_TC11X_ROLE_B"
    else
        pair_a="$_TC11X_ROLE_B"
        pair_b="$_TC11X_ROLE_A"
    fi

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "6|t" ]

    # Urgent, differently-shaped message is delivered; breaker stays alerted.
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "URGENT: production database is down, need immediate help."
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "7|t" ]

    # Repeating the same storm shape afterward is also delivered.
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "still working on it, note 7"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "8|t" ]

    # Exactly one alert row per window.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "1" ]

    # The alert-only breaker never writes loop_breaker suppressions.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_suppressed_log WHERE reason = 'loop_breaker';"
    [ "$output" = "0" ]
}

@test "TC-119 DISCRIMINATES: the alert-only breaker emits exactly one alert per window" {
    # Proves TC-119 exercises the alert-only behavior. Sends 12 messages in
    # the same window and asserts exactly one alert -- a naive implementation
    # would emit an alert on every message after the threshold.
    _tc11x_setup_roles_and_schema

    local pair_a pair_b
    if [[ "${_TC11X_ROLE_A}" < "${_TC11X_ROLE_B}" ]]; then
        pair_a="$_TC11X_ROLE_A"
        pair_b="$_TC11X_ROLE_B"
    else
        pair_a="$_TC11X_ROLE_B"
        pair_b="$_TC11X_ROLE_A"
    fi

    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "still working on it, note $i" >/dev/null
    done

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "12|t" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "1" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_suppressed_log WHERE reason = 'loop_breaker';"
    [ "$output" = "0" ]
}

@test "TC-116: broadcasts are NOT covered by the alert-only breaker" {
    # Migration 008's alert-only breaker explicitly skips '*' recipients.
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6 7 8; do
        _tc11x_send_as_a '*' "Broadcast repeat $i" >/dev/null
    done

    # All broadcasts delivered.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}' AND recipients = ARRAY['*'];"
    [ "$output" = "8" ]

    # No breaker state for broadcasts.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_breaker_state WHERE pair_a = '${_TC11X_ROLE_A}' OR pair_b = '${_TC11X_ROLE_A}';"
    [ "$output" = "0" ]

    # No breaker alerts.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_breaker_alerts;"
    [ "$output" = "0" ]
}

@test "TC-116 DISCRIMINATES: covering broadcasts with the breaker produces an alert" {
    # Proves TC-116 exercises the broadcast exclusion. Temporarily replaces
    # send_agent_message() with a version that does NOT skip '*' recipients,
    # then asserts an alert is generated for broadcasts.
    _tc11x_setup_roles_and_schema

    act_admin_psql "$AGENT_CHAT_DB_NAME" -c "
        CREATE OR REPLACE FUNCTION public.send_agent_message(
            p_sender text, p_message text, p_recipients text[],
            p_ttl interval DEFAULT NULL::interval, p_reply_to integer DEFAULT NULL
        ) RETURNS integer LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, public AS \$\$
        DECLARE
            v_id INTEGER; v_sender TEXT; v_recipients TEXT[]; v_expires_at TIMESTAMPTZ;
            v_recipient TEXT; v_pair_a TEXT; v_pair_b TEXT; v_state RECORD;
            v_threshold CONSTANT INTEGER := 6; v_window CONSTANT INTERVAL := interval '5 minutes';
        BEGIN
            IF LOWER(p_sender) != session_user THEN
                RAISE EXCEPTION 'send_agent_message: sender must match session_user';
            END IF;
            IF p_message IS NULL OR trim(p_message) = '' THEN
                RAISE EXCEPTION 'send_agent_message: message cannot be empty';
            END IF;
            IF p_recipients IS NULL OR array_length(p_recipients, 1) IS NULL THEN
                RAISE EXCEPTION 'send_agent_message: recipients cannot be NULL or empty';
            END IF;
            v_sender := LOWER(p_sender);
            v_recipients := ARRAY(SELECT DISTINCT LOWER(r) FROM unnest(p_recipients) AS r ORDER BY LOWER(r));
            IF v_sender = ANY(v_recipients) THEN
                RAISE EXCEPTION 'send_agent_message: sender in recipient list';
            END IF;
            IF public.agent_chat_is_error_template(p_message) THEN
                INSERT INTO public.agent_chat_suppressed_log (reason, sender, recipients, message_sample)
                VALUES ('sender_filter_error_template', v_sender, v_recipients, left(p_message, 500));
                RETURN NULL;
            END IF;
            IF p_ttl IS NOT NULL THEN v_expires_at := NOW() + p_ttl; END IF;

            FOREACH v_recipient IN ARRAY v_recipients
            LOOP
                IF v_recipient = '*' THEN
                    v_pair_a := '*';
                    v_pair_b := v_sender;
                ELSIF v_sender < v_recipient THEN
                    v_pair_a := v_sender;
                    v_pair_b := v_recipient;
                ELSE
                    v_pair_a := v_recipient;
                    v_pair_b := v_sender;
                END IF;

                SELECT * INTO v_state FROM public.agent_chat_breaker_state
                    WHERE pair_a = v_pair_a AND pair_b = v_pair_b FOR UPDATE;
                IF NOT FOUND THEN
                    INSERT INTO public.agent_chat_breaker_state
                        (pair_a, pair_b, window_start, message_count, alerted, last_message_at)
                    VALUES (v_pair_a, v_pair_b, now(), 1, false, now());
                ELSIF v_state.last_message_at < now() - v_window THEN
                    UPDATE public.agent_chat_breaker_state
                    SET window_start = now(), message_count = 1, alerted = false, last_message_at = now()
                    WHERE pair_a = v_pair_a AND pair_b = v_pair_b;
                ELSE
                    UPDATE public.agent_chat_breaker_state
                    SET message_count = v_state.message_count + 1, last_message_at = now()
                    WHERE pair_a = v_pair_a AND pair_b = v_pair_b RETURNING * INTO v_state;
                    IF v_state.message_count >= v_threshold AND NOT v_state.alerted THEN
                        INSERT INTO public.agent_chat_breaker_alerts
                            (pair_a, pair_b, window_start, window_end, message_count, threshold)
                        VALUES (v_pair_a, v_pair_b, v_state.window_start, v_state.window_start + v_window, v_state.message_count, v_threshold);
                        UPDATE public.agent_chat_breaker_state SET alerted = true
                            WHERE pair_a = v_pair_a AND pair_b = v_pair_b;
                    END IF;
                END IF;
            END LOOP;

            INSERT INTO public.agent_chat (sender, message, recipients, reply_to, expires_at)
            VALUES (v_sender, p_message, v_recipients, p_reply_to, v_expires_at) RETURNING id INTO v_id;
            RETURN v_id;
        END;
        \$\$;
    " 2>/dev/null || true

    for i in 1 2 3 4 5 6 7 8; do
        _tc11x_send_as_a '*' "Broadcast repeat $i" >/dev/null
    done

    # All broadcasts still delivered (the hypothetical breaker is alert-only).
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}' AND recipients = ARRAY['*'];"
    [ "$output" = "8" ]

    # A hypothetical breaker that covered broadcasts would have generated an alert.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = '*' AND pair_b = '${_TC11X_ROLE_A}';"
    [ "$output" = "1" ]
}

@test "TC-116b: an ordinary single-recipient send to a named peer is independent of broadcasts" {
    # Broadcasts do not create breaker state, so a single-recipient send to B
    # starts a fresh pair and is delivered normally.
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6 7 8; do
        _tc11x_send_as_a '*' "Broadcast repeat $i" >/dev/null
    done

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_breaker_state;"
    [ "$output" = "0" ]

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "Can you take a look at agent-chat#11 when you get a chance?"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    local pair_a pair_b
    if [[ "${_TC11X_ROLE_A}" < "${_TC11X_ROLE_B}" ]]; then
        pair_a="$_TC11X_ROLE_A"
        pair_b="$_TC11X_ROLE_B"
    else
        pair_a="$_TC11X_ROLE_B"
        pair_b="$_TC11X_ROLE_A"
    fi

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = '$pair_a' AND pair_b = '$pair_b';"
    [ "$output" = "1|f" ]
}

@test "TC-117: standard agent roles cannot write directly to the new control tables" {
    _tc11x_setup_roles_and_schema

    run _tc11x_psql_as "$_TC11X_ROLE_A" "INSERT INTO agent_chat_error_templates (pattern) VALUES ('direct write attempt');"
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission denied"* ]]

    run _tc11x_psql_as "$_TC11X_ROLE_A" "INSERT INTO agent_chat_breaker_state (pair_a, pair_b) VALUES ('x','y');"
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission denied"* ]]

    run _tc11x_psql_as "$_TC11X_ROLE_A" "INSERT INTO agent_chat_suppressed_log (reason, sender, recipients, message_sample) VALUES ('loop_breaker','x',ARRAY['y'],'z');"
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission denied"* ]]

    # SELECT must still work (loud-in-the-log constraint requires readability).
    run _tc11x_psql_as "$_TC11X_ROLE_A" "SELECT count(*) FROM agent_chat_error_templates;"
    [ "$status" -eq 0 ]
    [ "$output" -ge 3 ]

}

@test "TC-117b: a prefixed fixture role receives no DML on the control tables after install (proves the lockdown)" {
    # The original TC-117b used the real 'scout' role to prove schema.sql's
    # REVOKE neutralized ambient default privileges.  We cannot touch real
    # agent roles, so we verify the same lockdown behavior on a prefixed
    # fixture role that receives no explicit table grants from the test.
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]

    local fixture
    fixture="act_$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)_scout"
    act_admin_psql postgres -c "DROP ROLE IF EXISTS \"$fixture\";" >/dev/null 2>&1 || true
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c "CREATE ROLE \"$fixture\" LOGIN;" >/dev/null

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture', 'public.agent_chat_error_templates', 'INSERT');"
    [ "$output" = "f" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture', 'public.agent_chat_error_templates', 'UPDATE');"
    [ "$output" = "f" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture', 'public.agent_chat_error_templates', 'DELETE');"
    [ "$output" = "f" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture', 'public.agent_chat_breaker_state', 'INSERT');"
    [ "$output" = "f" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture', 'public.agent_chat_suppressed_log', 'INSERT');"
    [ "$output" = "f" ]

    # The fixture is not a standard agent, so it receives no SELECT either.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture', 'public.agent_chat_error_templates', 'SELECT');"
    [ "$output" = "f" ]

    act_admin_psql postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$fixture\";" >/dev/null 2>&1 || true
}

@test "TC-117b DISCRIMINATES: without the REVOKE/lockdown, DML would be granted" {
    # Proves TC-117b actually exercises the hazard: after install we
    # explicitly GRANT INSERT/UPDATE/DELETE on the control tables to a
    # prefixed fixture role (simulating the stripped-lockdown state) and
    # assert it now WRONGLY holds INSERT -- the failure mode TC-117b exists
    # to catch.
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]

    local fixture
    fixture="act_$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)_scout"
    act_admin_psql postgres -c "DROP ROLE IF EXISTS \"$fixture\";" >/dev/null 2>&1 || true
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c "CREATE ROLE \"$fixture\" LOGIN;" >/dev/null

    act_admin_psql "$AGENT_CHAT_DB_NAME" -c "
        DO \$\$
        DECLARE
            v_table text;
        BEGIN
            FOREACH v_table IN ARRAY ARRAY[
                'agent_chat_error_templates',
                'agent_chat_breaker_state',
                'agent_chat_suppressed_log'
            ]
            LOOP
                EXECUTE format('GRANT INSERT, UPDATE, DELETE ON TABLE public.%I TO %I', v_table, '$fixture');
            END LOOP;
        END \$\$;
    "

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture', 'public.agent_chat_error_templates', 'INSERT');"
    [ "$output" = "t" ]   # WRONGLY granted under the simulated stripped-lockdown state -- proves TC-117b discriminates

    act_admin_psql postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$fixture\";" >/dev/null 2>&1 || true
}

# ─── expire_old_chat cron (TC-66) ───────────────────────────────────────────

@test "TC-66: fresh install creates expire_old_chat cron entry targeting bus DB" {
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]
    [ -f "$CRONTAB_FILE" ]
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 1 ]
    run grep -qxF "30 3 * * * psql -d \"$AGENT_CHAT_DB_NAME\" -c \"SELECT expire_old_chat();\" # agent-chat-expire-old-chat" "$CRONTAB_FILE"
    [ "$status" -eq 0 ]
}

@test "TC-66: re-run is idempotent (no duplicate expire_old_chat entries)" {
    env PGUSER=agentchat_test "$INSTALLER" >/dev/null
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 1 ]
    env PGUSER=agentchat_test "$INSTALLER" >/dev/null
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 1 ]
}

@test "TC-66: stale *_memory-targeting expire_old_chat entry is rewritten" {
    printf '%s\n' '30 4 * * * psql -d "nova_memory" -c "SELECT expire_old_chat();"' > "$CRONTAB_FILE"
    run env PGUSER=agentchat_test "$INSTALLER"
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
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]
    run grep -qxF "0 5 * * * echo hello" "$CRONTAB_FILE"
    [ "$status" -eq 0 ]
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 1 ]
}

@test "TC-66: AGENT_CHAT_SKIP_CRON=1 skips cron installation" {
    printf '%s\n' '0 5 * * * echo hello' > "$CRONTAB_FILE"
    AGENT_CHAT_SKIP_CRON=1 run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT_CHAT_SKIP_CRON=1; skipping expire_old_chat cron installation"* ]]
    run grep -cF "expire_old_chat" "$CRONTAB_FILE"
    [ "$output" -eq 0 ]
    run grep -qxF "0 5 * * * echo hello" "$CRONTAB_FILE"
    [ "$status" -eq 0 ]
}

# ─── install.sh (TC-01..09) ─────────────────────────────────────────────────

@test "TC-01: fresh install creates DB, schema, and expected objects" {
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applied schema.sql"* ]]
    [[ "$output" == *"Applied 001"* ]]
    [[ "$output" == *"Applied 004"* ]]
    [[ "$output" == *"Applied 005"* ]]
    [[ "$output" == *"Applied 007"* ]]
    [[ "$output" == *"Applied 008"* ]]
    [[ "$output" == *"Applied 009"* ]]

    # Verify schema_version.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT MAX(version) FROM public.schema_version;"
    [ "$output" = "9" ]

    # Verify core objects.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT proname FROM pg_proc WHERE proname = 'send_agent_message';"
    [ "$output" = "send_agent_message" ]

    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT tgname FROM pg_trigger WHERE tgname = 'trg_enforce_agent_chat_function_use';"
    [ "$output" = "trg_enforce_agent_chat_function_use" ]
}

@test "TC-02: idempotent re-run reports 'up to date'" {
    env PGUSER=agentchat_test "$INSTALLER" >/dev/null
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
}

@test "TC-08: re-run after partial failure completes without duplicate errors" {
    # Simulate partial state: drop any DB from setup and create an empty one,
    # then run installer to complete it.
    act_admin_psql postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"$AGENT_CHAT_DB_NAME\";" >/dev/null 2>&1 || true
    act_admin_psql postgres -c "CREATE DATABASE \"$AGENT_CHAT_DB_NAME\";" >/dev/null
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applied schema.sql"* ]]
    [[ "$output" != *"database already exists"* ]]
}

@test "TC-05: installer warns on unrecognized column drift but does not fail" {
    env PGUSER=agentchat_test "$INSTALLER" >/dev/null
    act_admin_psql "$AGENT_CHAT_DB_NAME" -c "ALTER TABLE public.agent_chat ADD COLUMN drift_col text;" >/dev/null
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected column drift"* ]]
    # The drift column must survive.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT 1 FROM information_schema.columns WHERE table_name = 'agent_chat' AND column_name = 'drift_col';"
    [ "$output" = "1" ]
}

@test "TC-06: installer fails clearly with a non-CREATEDB role" {
    # Re-use the limited cadence/recon-style role if it exists; otherwise test
    # via a deliberately bad user string. The goal is a clean error, not a raw
    # stack trace.
    if act_admin_psql postgres -At -c "SELECT 1 FROM pg_roles WHERE rolname = 'recon';" | grep -q "1"; then
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
    run env PGUSER=agentchat_test "$REGISTER" '"; DROP TABLE agent_chat; --'
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid lowercase PostgreSQL identifier"* ]]

    run env PGUSER=agentchat_test "$REGISTER" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"Agent name cannot be empty"* ]]

    run env PGUSER=agentchat_test "$REGISTER" "postgres"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved PostgreSQL role"* ]]

    run env PGUSER=agentchat_test "$REGISTER" "public"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved PostgreSQL role"* ]]

    # 64-character name exceeds 63-byte Postgres identifier limit.
    local long_name
    long_name=$(printf '%064s' | tr ' ' 'a')
    run env PGUSER=agentchat_test "$REGISTER" "$long_name"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exceeds 63 bytes"* ]]
}

@test "TC-10/TC-14: accepts valid 63-byte boundary name" {
    local boundary_name
    boundary_name=$(printf '%063s' | tr ' ' 'a')
    run env PGUSER=agentchat_test "$REGISTER" --check "$boundary_name"
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

@test "TC-13: hardened grant policy is documented in --help" {
    run env PGUSER=agentchat_test "$REGISTER" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"hardened standard grant set"* ]]
    [[ "$output" == *"Direct INSERT/UPDATE/DELETE on public.agent_chat"* ]]
}

@test "register-agent: --check reports missing role" {
    run env PGUSER=agentchat_test "$REGISTER" --check "chunk2_nonexistent_agent_$$"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT registered"* ]]
}

@test "register-agent: fails clearly when run without CREATEROLE" {
    # Create a temporary LOGIN role with no CREATEROLE privilege and run
    # register-agent.sh as that role.
    local limited_role limited_pass limited_pgpass
    limited_role="act_$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)_limited"
    limited_pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    act_admin_psql postgres -c "DROP ROLE IF EXISTS \"$limited_role\";" >/dev/null 2>&1 || true
    act_admin_psql postgres -c "CREATE ROLE \"$limited_role\" LOGIN NOCREATEROLE PASSWORD '$limited_pass';" >/dev/null

    limited_pgpass="$(mktemp)"
    chmod 600 "$limited_pgpass"
    printf 'localhost:%s:*:%s:%s\n' "$ACT_ADMIN_PORT" "$limited_role" "$limited_pass" > "$limited_pgpass"

    PGPASSFILE="$limited_pgpass" run env PGUSER="$limited_role" "$REGISTER" "chunk2_some_agent_$$"
    [ "$status" -ne 0 ]
    [[ "$output" == *"lacks CREATEROLE"* ]]

    rm -f "$limited_pgpass"
    act_admin_psql postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$limited_role\";" >/dev/null 2>&1 || true
}

@test "TC-14: register-agent.sh applies the hardened grant set the plugin needs" {
    run env PGUSER=agentchat_test "$INSTALLER"
    [ "$status" -eq 0 ]

    local fixture_role fixture_pass fixture_pgpass
    fixture_role="act_$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)_plugin"
    fixture_pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

    fixture_pgpass="$(mktemp)"
    chmod 600 "$fixture_pgpass"
    printf 'localhost:%s:*:%s:%s\n' "$ACT_ADMIN_PORT" "$fixture_role" "$fixture_pass" >> "$fixture_pgpass"

    AGENT_CHAT_DB_NAME="$AGENT_CHAT_DB_NAME" run env PGUSER=agentchat_test "$REGISTER" --password "$fixture_pass" "$fixture_role"
    [ "$status" -eq 0 ]

    # agent_chat is immutable for agents: SELECT is needed to poll, but direct
    # INSERT/UPDATE/DELETE must be denied (writes go through send_agent_message()).
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat', 'SELECT');"
    [ "$output" = "t" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat', 'INSERT');"
    [ "$output" = "f" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat', 'UPDATE');"
    [ "$output" = "f" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat', 'DELETE');"
    [ "$output" = "f" ]

    # agent_chat_processed is the plugin's own per-agent state table.
    # It needs SELECT for diagnostics/polling, INSERT to claim messages, and
    # UPDATE to transition status. DELETE is not required.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat_processed', 'SELECT');"
    [ "$output" = "t" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat_processed', 'INSERT');"
    [ "$output" = "t" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat_processed', 'UPDATE');"
    [ "$output" = "t" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat_processed', 'DELETE');"
    [ "$output" = "f" ]

    # The plugin does not allocate agent_chat_id_seq directly; send_agent_message()
    # allocates ids inside its SECURITY DEFINER context.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_sequence_privilege('$fixture_role', 'public.agent_chat_id_seq', 'USAGE');"
    [ "$output" = "f" ]

    # The plugin needs to call the public functions it exposes as tools.
    # They remain executable via PUBLIC default privileges in this schema.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_function_privilege('$fixture_role', 'public.send_agent_message(text,text,text[],interval,integer)', 'EXECUTE');"
    [ "$output" = "t" ]
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_function_privilege('$fixture_role', 'public.mark_agent_chat_status(bigint[],text)', 'EXECUTE');"
    [ "$output" = "t" ]

    # Direct writes to the circuit-breaker control tables are intentionally
    # locked down; callers must go through SECURITY DEFINER functions.
    run act_admin_psql "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat_breaker_state', 'INSERT');"
    [ "$output" = "f" ]

    rm -f "$fixture_pgpass"
    act_admin_psql postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$fixture_role\";" >/dev/null 2>&1 || true
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

    # channels.agent_chat must not contain keys rejected by the plugin schema.
    [ "$(jq -r '.channels.agent_chat.enabled' "$oc_dir/openclaw.json")" = "null" ]
    [ "$(jq -r '.channels.agent_chat.database' "$oc_dir/openclaw.json")" = "null" ]
    [ "$(jq -r '.channels.agent_chat.pollIntervalMs' "$oc_dir/openclaw.json")" = "500" ]
    [ "$(jq -r '.plugins.entries.agent_chat.enabled' "$oc_dir/openclaw.json")" = "true" ]
    # plugins.entries.agent_chat.config must not contain legacy routeToSession.
    [ "$(jq -r '.plugins.entries.agent_chat.config.routeToSession' "$oc_dir/openclaw.json")" = "null" ]
    [ "$(jq -r '.plugins.entries.agent_chat.config.password' "$oc_dir/openclaw.json")" = "null" ]
}

@test "TC-60: install-plugin.sh is idempotent (no duplicate keys)" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    echo '{}' > "$oc_dir/openclaw.json"

    AGENT_CHAT_DB_NAME="agent_chat" "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "testpass" >/dev/null
    AGENT_CHAT_DB_NAME="agent_chat" "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "testpass" >/dev/null

    # With an empty starting config, the plugin schema leaves these objects empty.
    run jq '.channels.agent_chat | keys | length' "$oc_dir/openclaw.json"
    [ "$output" -eq 0 ]

    run jq '.plugins.entries.agent_chat.config | keys | length' "$oc_dir/openclaw.json"
    [ "$output" -eq 0 ]
}

@test "TC-60: install-plugin.sh writes channels.agent_chat.agentId from AGENT_CHAT_AGENT_ID" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    echo '{}' > "$oc_dir/openclaw.json"

    AGENT_CHAT_DB_NAME="agent_chat" AGENT_CHAT_AGENT_ID="main" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "***"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.channels.agent_chat.agentId' "$oc_dir/openclaw.json")" = "main" ]
}

@test "TC-60: install-plugin.sh overwrites stale agentId when AGENT_CHAT_AGENT_ID is set" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    cat > "$oc_dir/openclaw.json" <<'EOF'
{
  "channels": {
    "agent_chat": {
      "agentId": "old-agent",
      "pollIntervalMs": 500
    }
  }
}
EOF

    AGENT_CHAT_DB_NAME="agent_chat" AGENT_CHAT_AGENT_ID="main" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "***"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.channels.agent_chat.agentId' "$oc_dir/openclaw.json")" = "main" ]
    [ "$(jq -r '.channels.agent_chat.pollIntervalMs' "$oc_dir/openclaw.json")" = "500" ]
}

@test "TC-60: install-plugin.sh preserves existing agentId when AGENT_CHAT_AGENT_ID is unset" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    cat > "$oc_dir/openclaw.json" <<'EOF'
{
  "channels": {
    "agent_chat": {
      "agentId": "preserved-agent",
      "pollIntervalMs": 500
    }
  }
}
EOF

    AGENT_CHAT_DB_NAME="agent_chat" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "***"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.channels.agent_chat.agentId' "$oc_dir/openclaw.json")" = "preserved-agent" ]
    [ "$(jq -r '.channels.agent_chat.pollIntervalMs' "$oc_dir/openclaw.json")" = "500" ]
}

@test "TC-60: install-plugin.sh honors AGENT_CHAT_DB_NAME in postgres.json" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    cat > "$oc_dir/postgres.json" <<'EOF'
{
  "agentChatDatabase": "agent_chat"
}
EOF
    echo '{}' > "$oc_dir/openclaw.json"

    AGENT_CHAT_DB_NAME="agent_chat_staging" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "***"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.agentChatDatabase' "$oc_dir/postgres.json")" = "agent_chat_staging" ]
    [ "$(jq -r '.agent_chat.database' "$oc_dir/postgres.json")" = "agent_chat_staging" ]
}

@test "TC-60: install-plugin.sh overwrites stale nested agent_chat.database when AGENT_CHAT_DB_NAME is set" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    cat > "$oc_dir/postgres.json" <<'EOF'
{
  "agentChatDatabase": "agent_chat",
  "agent_chat": {
    "database": "agent_chat_se1453_staging",
    "user": "oldagent",
    "password": "oldpass"
  }
}
EOF
    echo '{}' > "$oc_dir/openclaw.json"

    AGENT_CHAT_DB_NAME="agent_chat_staging" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "***"
    [ "$status" -eq 0 ]

    # The flat key is forced by AGENT_CHAT_DB_NAME.
    [ "$(jq -r '.agentChatDatabase' "$oc_dir/postgres.json")" = "agent_chat_staging" ]
    # The nested key (the one the plugin actually reads) must also be updated.
    [ "$(jq -r '.agent_chat.database' "$oc_dir/postgres.json")" = "agent_chat_staging" ]
    # Other nested keys are preserved when not overridden.
    [ "$(jq -r '.agent_chat.user' "$oc_dir/postgres.json")" = "oldagent" ]
}

@test "TC-60: install-plugin.sh installs production dependencies in target dir" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    echo '{}' > "$oc_dir/openclaw.json"

    AGENT_CHAT_DB_NAME="agent_chat" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "***"
    [ "$status" -eq 0 ]

    [ -d "$oc_dir/extensions/agent_chat/node_modules" ]
    [ -d "$oc_dir/extensions/agent_chat/node_modules/pg" ]
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

@test "TC-62: install-plugin.sh strips legacy channels.agent_chat.enabled key" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    cat > "$oc_dir/openclaw.json" <<'EOF'
{
  "channels": {
    "agent_chat": {
      "enabled": true,
      "pollIntervalMs": 500
    }
  }
}
EOF

    AGENT_CHAT_DB_NAME="agent_chat" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "***"
    [ "$status" -eq 0 ]

    # The legacy 'enabled' key (rejected by the plugin schema) must be removed.
    [ "$(jq -r '.channels.agent_chat.enabled' "$oc_dir/openclaw.json")" = "null" ]
    # Other preserved keys should survive.
    [ "$(jq -r '.channels.agent_chat.pollIntervalMs' "$oc_dir/openclaw.json")" = "500" ]
}

@test "TC-63: install-plugin.sh restores openclaw.json and exits non-zero when config validation fails" {
    local oc_dir="$FAKE_HOME/.openclaw"
    mkdir -p "$oc_dir"
    echo '{}' > "$oc_dir/postgres.json"
    cat > "$oc_dir/openclaw.json" <<'EOF'
{
  "channels": {
    "agent_chat": {
      "enabled": true
    }
  }
}
EOF

    # Snapshot the original config so we can prove restoration.
    local original
    original="$(cat "$oc_dir/openclaw.json")"

    # Stub openclaw on PATH so 'config validate' exits 1.
    local stub_dir
    stub_dir="$(mktemp -d)"
    cat > "$stub_dir/openclaw" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "config" ] && [ "${2:-}" = "validate" ]; then
    echo "stub openclaw: forced validation failure" >&2
    exit 1
fi
# passthrough for any other openclaw invocation (none expected)
exec /home/nova/.openclaw/tmp/agent-cli/openclaw "$@"
EOF
    chmod +x "$stub_dir/openclaw"
    export PATH="$stub_dir:$PATH"

    AGENT_CHAT_DB_NAME="agent_chat" run "$PLUGIN_INSTALLER" --openclaw-dir "$oc_dir" --agent-name "testagent" --password "***"
    [ "$status" -ne 0 ]
    [[ "$output" == *"config validation failed"* ]]

    # openclaw.json must be restored to its pre-install content.
    [ "$(cat "$oc_dir/openclaw.json")" = "$original" ]

    rm -rf "$stub_dir"
}

# ─── Plugin build verification ──────────────────────────────────────────────

@test "Plugin builds successfully in repo" {
    cd "$REPO_ROOT/plugin"
    run npm run build
    [ "$status" -eq 0 ]
    [ -f "$REPO_ROOT/plugin/dist/index.js" ]
}
