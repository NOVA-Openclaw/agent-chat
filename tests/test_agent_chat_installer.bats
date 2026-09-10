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
    # Drop any test database created by this test FIRST. TC-11x helper roles
    # (below) hold GRANTs inside this database; PostgreSQL refuses DROP ROLE
    # while a role still has privileges granted on live objects, so the
    # database must go before the roles that were granted access to it.
    if [ -n "${AGENT_CHAT_DB_NAME:-}" ]; then
        psql -d postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"$AGENT_CHAT_DB_NAME\";" >/dev/null 2>&1 || true
    fi

    # TC-11x helper roles: drop unconditionally in the global teardown (not
    # inline at the end of each test body) so a failed assertion mid-test
    # still cleans up the roles instead of leaking them.
    if [ -n "${_TC11X_ROLE_A:-}" ]; then
        psql -d postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$_TC11X_ROLE_A\";" >/dev/null 2>&1 || true
    fi
    if [ -n "${_TC11X_ROLE_B:-}" ]; then
        psql -d postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$_TC11X_ROLE_B\";" >/dev/null 2>&1 || true
    fi
    # agent-chat#18: role C is used by the multi-recipient breaker tests.
    if [ -n "${_TC11X_ROLE_C:-}" ]; then
        psql -d postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$_TC11X_ROLE_C\";" >/dev/null 2>&1 || true
    fi
    if [ -n "${_TC11X_PGPASSFILE:-}" ]; then
        rm -f "$_TC11X_PGPASSFILE"
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

# ─── courtesy-reply storm circuit breaker (TC-11x / agent-chat#11) ─────────
#
# These tests exercise the live send_agent_message() function directly
# (rather than through install.sh) against a per-test database, using two
# ephemeral login roles so that p_sender/session_user validation reflects
# real distinct agents exchanging messages, the same way nova/graybeard do in
# production.

_TC11X_ROLE_A=""
_TC11X_ROLE_B=""
# agent-chat#18: a third role is required to test mixed recipient arrays --
# a tripped pair alongside an untripped one in the same send.
_TC11X_ROLE_C=""
_TC11X_PGPASSFILE=""

_tc11x_setup_roles_and_schema() {
    run "$INSTALLER"
    [ "$status" -eq 0 ]

    _TC11X_ROLE_A="zz11a_${BATS_TEST_NUMBER}_$$"
    _TC11X_ROLE_B="zz11b_${BATS_TEST_NUMBER}_$$"
    _TC11X_ROLE_C="zz11c_${BATS_TEST_NUMBER}_$$"
    psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$_TC11X_ROLE_A\" LOGIN PASSWORD 'tc11xpw';"
    psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$_TC11X_ROLE_B\" LOGIN PASSWORD 'tc11xpw';"
    psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$_TC11X_ROLE_C\" LOGIN PASSWORD 'tc11xpw';"
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "GRANT INSERT, SELECT ON public.agent_chat TO \"$_TC11X_ROLE_A\", \"$_TC11X_ROLE_B\", \"$_TC11X_ROLE_C\";"
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "GRANT SELECT ON public.agent_chat_error_templates, public.agent_chat_breaker_state, public.agent_chat_suppressed_log TO \"$_TC11X_ROLE_A\", \"$_TC11X_ROLE_B\", \"$_TC11X_ROLE_C\";"

    _TC11X_PGPASSFILE="$(mktemp)"
    chmod 600 "$_TC11X_PGPASSFILE"
    {
        echo "localhost:5432:${AGENT_CHAT_DB_NAME}:${_TC11X_ROLE_A}:tc11xpw"
        echo "localhost:5432:${AGENT_CHAT_DB_NAME}:${_TC11X_ROLE_B}:tc11xpw"
        echo "localhost:5432:${AGENT_CHAT_DB_NAME}:${_TC11X_ROLE_C}:tc11xpw"
    } > "$_TC11X_PGPASSFILE"
}

# Role/pgpass cleanup happens unconditionally in the global teardown() above
# (not here) so a failed assertion mid-test still cleans up.

# Send as role A (session_user == p_sender == role A) to the given recipient.
_tc11x_send_as_a() {
    local recipient="$1" message="$2"
    PGPASSFILE="$_TC11X_PGPASSFILE" psql -h localhost -U "$_TC11X_ROLE_A" -d "$AGENT_CHAT_DB_NAME" -At \
        -c "SELECT send_agent_message('${_TC11X_ROLE_A}', '$(printf '%s' "$message" | sed "s/'/''/g")', ARRAY['${recipient}']);"
}

_tc11x_send_as_b() {
    local recipient="$1" message="$2"
    PGPASSFILE="$_TC11X_PGPASSFILE" psql -h localhost -U "$_TC11X_ROLE_B" -d "$AGENT_CHAT_DB_NAME" -At \
        -c "SELECT send_agent_message('${_TC11X_ROLE_B}', '$(printf '%s' "$message" | sed "s/'/''/g")', ARRAY['${recipient}']);"
}

# agent-chat#18: send as role A to an ARBITRARY LIST of recipients, so the
# multi-recipient breaker path can be exercised. Recipients are passed as
# separate arguments and assembled into a SQL array literal.
_tc11x_send_as_a_multi() {
    local message="$1"; shift
    local quoted="" r
    for r in "$@"; do
        [ -n "$quoted" ] && quoted="${quoted},"
        quoted="${quoted}'${r}'"
    done
    PGPASSFILE="$_TC11X_PGPASSFILE" psql -h localhost -U "$_TC11X_ROLE_A" -d "$AGENT_CHAT_DB_NAME" -At \
        -c "SELECT send_agent_message('${_TC11X_ROLE_A}', '$(printf '%s' "$message" | sed "s/'/''/g")', ARRAY[${quoted}]);"
}

# agent-chat#18: read back the recipients array of the most recent delivered row.
_tc11x_last_recipients() {
    psql -d "$AGENT_CHAT_DB_NAME" -At \
        -c "SELECT array_to_string(recipients, ',') FROM agent_chat ORDER BY id DESC LIMIT 1;"
}

@test "TC-110: sender-side filter quarantines the occurrence 2/3 runtime-error template" {
    _tc11x_setup_roles_and_schema

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "⚠️ Something went wrong while processing your request. Please try again, or use /compact."
    [ "$status" -eq 0 ]
    [ -z "$output" ]   # NULL id: silent on the bus

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}';"
    [ "$output" = "0" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT reason FROM agent_chat_suppressed_log WHERE sender = '${_TC11X_ROLE_A}';"
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

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat;"
    [ "$output" = "0" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log WHERE reason = 'sender_filter_error_template';"
    [ "$output" = "2" ]

}

@test "TC-112: ordinary non-template messages are unaffected by the sender-side filter" {
    _tc11x_setup_roles_and_schema

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "Can you take a look at agent-chat#11 when you get a chance?"
    [ "$status" -eq 0 ]
    [ -n "$output" ]   # got a real id back

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}';"
    [ "$output" = "1" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log;"
    [ "$output" = "0" ]

}

@test "TC-113: A->B->A->B non-substantive exchange trips the loop breaker and damps the storm" {
    _tc11x_setup_roles_and_schema

    # Reproduce the loop condition: 12 alternating, non-substantive messages
    # with no artifact reference (mirrors the occurrence-4 mutual-saturation
    # ladder — neither body references an issue/PR/task/file).
    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "No reply. Note $i concludes nothing needs action." >/dev/null
        _tc11x_send_as_b "$_TC11X_ROLE_A" "A runtime status notice, no content to act on ($i)." >/dev/null
    done

    # Both directions must have stopped growing at the threshold (5 delivered,
    # 6th+ suppressed) rather than reaching all 6 sent attempts.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}' AND recipients = ARRAY['${_TC11X_ROLE_B}'];"
    [ "$output" -lt 6 ]
    [ "$output" -ge 1 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_B}' AND recipients = ARRAY['${_TC11X_ROLE_A}'];"
    [ "$output" -lt 6 ]
    [ "$output" -ge 1 ]

    # Both ordered pairs must show tripped = true with at least one suppression.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "t" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_B}' AND recipient = '${_TC11X_ROLE_A}';"
    [ "$output" = "t" ]

    # Exactly one loop_breaker audit row per direction (loud once, not per
    # suppressed message — a live storm cannot flood this table).
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log WHERE reason = 'loop_breaker';"
    [ "$output" = "2" ]

}

@test "TC-114: a message referencing a new artifact resets the breaker and is delivered" {
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "No reply. Note $i concludes nothing needs action." >/dev/null
    done
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "t" ]

    # A message referencing a real artifact must reset the pair and be delivered.
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "See agent-chat#11 for the current fix status."
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "1|f" ]

}

@test "TC-115: an idle gap longer than the breaker window resets the pair" {
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "Non substantive repeat $i." >/dev/null
    done
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "t" ]

    # Simulate the window having elapsed (breaker window is 15 minutes).
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "UPDATE agent_chat_breaker_state SET last_message_at = now() - interval '20 minutes' WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "Non substantive repeat after cooldown."
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "1|f" ]

}

# ─── agent-chat#18 regression tests: multi-recipient breaker coverage ─────────

@test "TC-120: repeated multi-recipient sends to the same set trip the breaker per pair (agent-chat#18)" {
    _tc11x_setup_roles_and_schema

    # Under 005 this array shape bypassed the breaker entirely: array_length != 1.
    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a_multi "No reply needed here at all, repeat $i." "$_TC11X_ROLE_B" "$_TC11X_ROLE_C" >/dev/null
    done

    # BOTH pairs must have tripped.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "t" ]
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_C}';"
    [ "$output" = "t" ]

    # 6th send had every pair suppressed => NULL, no row inserted. 5 delivered.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}';"
    [ "$output" = "5" ]
}

@test "TC-121 DISCRIMINATES: a tripped pair cannot be bypassed by adding a second recipient (agent-chat#18 core defect)" {
    _tc11x_setup_roles_and_schema

    # Trip A->B only, using single-recipient sends (the 005-covered path).
    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "Non substantive single repeat $i." >/dev/null
    done
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "t" ]

    # THE BYPASS: same storm body, now addressed to the tripped pair PLUS an
    # untripped third party. Under 005 this delivered to B anyway.
    run _tc11x_send_as_a_multi "Non substantive single repeat 7." "$_TC11X_ROLE_B" "$_TC11X_ROLE_C"
    [ "$status" -eq 0 ]
    [ -n "$output" ]   # still delivered -- but only to C

    # B must be ABSENT from the delivered recipients; C must be present.
    run _tc11x_last_recipients
    [ "$output" = "${_TC11X_ROLE_C}" ]
}

@test "TC-122: an untripped recipient in a mixed array still receives the message (agent-chat#18)" {
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "Filler repeat $i." >/dev/null
    done

    # C has never been messaged, so it must receive normally.
    run _tc11x_send_as_a_multi "Filler repeat 7." "$_TC11X_ROLE_B" "$_TC11X_ROLE_C"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}' AND '${_TC11X_ROLE_C}' = ANY(recipients);"
    [ "$output" = "1" ]
}

@test "TC-123: artifact reference resets every pair in a multi-recipient send (agent-chat#18)" {
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a_multi "Nothing actionable, repeat $i." "$_TC11X_ROLE_B" "$_TC11X_ROLE_C" >/dev/null
    done

    run _tc11x_send_as_a_multi "See agent-chat#18 for the fix." "$_TC11X_ROLE_B" "$_TC11X_ROLE_C"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # NOTE: use the two-column `SELECT a, b` form with -At (as every other
    # TC-11x test does), NOT `a || '|' || b`. psql renders a boolean as `f`
    # when it is its own column but as `false` inside a string concatenation,
    # so the concat form silently compares against the wrong literal.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "1|f" ]
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count, tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_C}';"
    [ "$output" = "1|f" ]
}

@test "TC-124: duplicate recipients in one array are de-duplicated to a single pair (agent-chat#18)" {
    _tc11x_setup_roles_and_schema

    run _tc11x_send_as_a_multi "Checking dedupe behaviour." "$_TC11X_ROLE_B" "$_TC11X_ROLE_B"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # One pair row, counted once -- not twice.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT message_count FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "1" ]

    run _tc11x_last_recipients
    [ "$output" = "${_TC11X_ROLE_B}" ]
}

@test "TC-125: single-recipient and broadcast behaviour unchanged from 005 (agent-chat#18 no-regression)" {
    _tc11x_setup_roles_and_schema

    # Single recipient still trips on the 6th.
    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "Single path repeat $i." >/dev/null
    done
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "t" ]

    # Broadcast still keyed on (sender, '*').
    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a_multi "Broadcast repeat $i." "*" >/dev/null
    done
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '*';"
    [ "$output" = "t" ]
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

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}';"
    [ "$output" = "4" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log WHERE reason = 'sender_filter_error_template';"
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

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log WHERE reason = 'sender_filter_error_template';"
    [ "$output" = "3" ]
}

@test "TC-118 DISCRIMINATES: reverting agent_chat_is_error_template() to the original unanchored substring match re-suppresses Gem's legitimate messages" {
    # Proves TC-118 actually exercises the fix. Temporarily replaces
    # agent_chat_is_error_template() with the pre-fix unanchored ~* substring
    # match (migration 005's original body, verbatim) inside this test's own
    # database, sends the same messages, and asserts they are now WRONGLY
    # suppressed -- the failure mode TC-118 exists to catch.
    _tc11x_setup_roles_and_schema

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
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

@test "TC-119: a genuinely urgent message escapes a tripped breaker via the content-novelty check (agent-chat#11 BLOCKING #2 fix)" {
    # Gem's live repro: tripped the breaker with 6 plausible "still working on
    # it" pings, then sent an urgent, unrelated message to the same pair --
    # it was silently dropped with zero escape hatch. Fixed: a message whose
    # normalized "shape" (agent_chat_message_shape(): lowercase, digits
    # stripped, non-letters collapsed) differs from the shape currently
    # driving the trip is let through once, bounded by a per-trip escape
    # budget (3) so varying the wording indefinitely cannot become an
    # unbounded bypass.
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "still working on it, note $i" >/dev/null
    done
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "t" ]

    # Gem's exact urgent repro message must be delivered despite the trip.
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "URGENT: production database is down, need immediate help."
    [ "$status" -eq 0 ]
    [ -n "$output" ]   # must deliver -- this is the defect: it was silently dropped pre-fix

    # The pair must still show tripped=true (the OLD storm shape is still
    # capped; only the differently-shaped urgent message escaped).
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped, escape_count FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "t|1" ]

    # Repeating the SAME old storm shape afterward must remain suppressed --
    # the escape is not a full reset.
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "still working on it, note 7"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # The escape budget (3 total per trip epoch) is bounded: the urgent
    # message above already consumed slot 1. CRITICAL and ALERT below consume
    # slots 2 and 3, exhausting the budget -- FAILURE (a 4th distinct-shaped
    # message) and NOTICE (a 5th) must both be suppressed like ordinary
    # tripped traffic once the budget runs out, even though their shapes
    # differ from the original storm shape and from each other.
    run _tc11x_send_as_a "$_TC11X_ROLE_B" "CRITICAL: disk is full on the primary node."
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "ALERT: memory usage exceeded threshold on host X."
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "FAILURE: replication lag detected on secondary."
    [ "$status" -eq 0 ]
    [ -z "$output" ]   # escape budget (3) exhausted -- suppressed like ordinary tripped traffic

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "NOTICE: yet another distinct thing happened here today."
    [ "$status" -eq 0 ]
    [ -z "$output" ]   # still exhausted

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT escape_count FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '${_TC11X_ROLE_B}';"
    [ "$output" = "3" ]
}

@test "TC-119 DISCRIMINATES: without the content-novelty escape hatch, the urgent message stays suppressed" {
    # Proves TC-119 exercises the fix. Reverts send_agent_message() breaker
    # branch to the pre-fix behavior (no escape hatch: once tripped, every
    # subsequent message for the pair is suppressed unconditionally) inside
    # this test's own database, and asserts the urgent message is now WRONGLY
    # dropped -- the failure mode TC-119 exists to catch.
    _tc11x_setup_roles_and_schema

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        CREATE OR REPLACE FUNCTION public.send_agent_message(
            p_sender text, p_message text, p_recipients text[],
            p_ttl interval DEFAULT NULL::interval, p_reply_to integer DEFAULT NULL
        ) RETURNS integer LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS \$\$
        DECLARE
            v_id INTEGER; v_sender TEXT; v_recipients TEXT[]; v_expires_at TIMESTAMPTZ;
            v_has_artifact BOOLEAN; v_recipient TEXT; v_state RECORD;
            v_window CONSTANT INTERVAL := interval '15 minutes';
            v_threshold CONSTANT INTEGER := 5;
        BEGIN
            IF LOWER(p_sender) != session_user THEN
                RAISE EXCEPTION 'send_agent_message: sender must match session_user (got % but connected as %)', p_sender, session_user;
            END IF;
            IF p_message IS NULL OR trim(p_message) = '' THEN
                RAISE EXCEPTION 'send_agent_message: message cannot be empty';
            END IF;
            IF p_recipients IS NULL OR array_length(p_recipients, 1) IS NULL THEN
                RAISE EXCEPTION 'send_agent_message: recipients cannot be NULL or empty';
            END IF;
            v_sender := LOWER(p_sender);
            v_recipients := ARRAY(SELECT LOWER(unnest(p_recipients)));
            IF v_sender = ANY(v_recipients) THEN
                RAISE EXCEPTION 'send_agent_message: sender in recipient list';
            END IF;
            IF public.agent_chat_is_error_template(p_message) THEN
                INSERT INTO public.agent_chat_suppressed_log (reason, sender, recipients, message_sample)
                VALUES ('sender_filter_error_template', v_sender, v_recipients, left(p_message, 500));
                RETURN NULL;
            END IF;
            IF p_ttl IS NOT NULL THEN v_expires_at := NOW() + p_ttl; END IF;
            IF array_length(v_recipients, 1) = 1 AND v_recipients[1] != '*' THEN
                v_recipient := v_recipients[1];
                v_has_artifact := public.agent_chat_has_artifact_ref(p_message);
                SELECT * INTO v_state FROM public.agent_chat_breaker_state
                    WHERE sender = v_sender AND recipient = v_recipient FOR UPDATE;
                IF NOT FOUND THEN
                    INSERT INTO public.agent_chat_breaker_state
                        (sender, recipient, window_start, message_count, tripped, suppressed_count, last_message_at)
                    VALUES (v_sender, v_recipient, now(), 1, false, 0, now());
                ELSIF v_has_artifact OR v_state.last_message_at < now() - v_window THEN
                    UPDATE public.agent_chat_breaker_state
                    SET window_start = now(), message_count = 1, tripped = false, suppressed_count = 0, last_message_at = now()
                    WHERE sender = v_sender AND recipient = v_recipient;
                ELSE
                    UPDATE public.agent_chat_breaker_state
                    SET message_count = v_state.message_count + 1, last_message_at = now()
                    WHERE sender = v_sender AND recipient = v_recipient RETURNING * INTO v_state;
                    IF v_state.message_count > v_threshold THEN
                        IF NOT v_state.tripped THEN
                            INSERT INTO public.agent_chat_suppressed_log
                                (reason, sender, recipients, message_sample, window_message_count)
                            VALUES ('loop_breaker', v_sender, v_recipients, left(p_message, 500), v_state.message_count);
                            UPDATE public.agent_chat_breaker_state SET tripped = true, suppressed_count = 1
                                WHERE sender = v_sender AND recipient = v_recipient;
                        ELSE
                            UPDATE public.agent_chat_breaker_state SET suppressed_count = suppressed_count + 1
                                WHERE sender = v_sender AND recipient = v_recipient;
                        END IF;
                        RETURN NULL;
                    END IF;
                END IF;
            END IF;
            INSERT INTO public.agent_chat (sender, message, recipients, reply_to, expires_at)
            VALUES (v_sender, p_message, v_recipients, p_reply_to, v_expires_at) RETURNING id INTO v_id;
            RETURN v_id;
        END;
        \$\$;
    " 2>/dev/null || true

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a "$_TC11X_ROLE_B" "still working on it, note $i" >/dev/null
    done

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "URGENT: production database is down, need immediate help."
    [ "$status" -eq 0 ]
    [ -z "$output" ]   # WRONGLY dropped under the reverted (pre-fix, no-escape-hatch) function -- proves TC-119 discriminates
}

@test "TC-116: broadcasts are throttled by a sender-scoped breaker (agent-chat#11 BLOCKING #3 fix, 2026-09-03)" {
    # 2026-09-03 QA remediation: Gem's adversarial review found the ORIGINAL
    # scoping condition (array_length = 1 AND recipients[1] != '*') left
    # broadcasts with zero bus-side defense -- 10 consecutive non-substantive
    # broadcasts all delivered, zero throttling. Fixed by extending the
    # breaker to cover recipient = '*', keyed on (sender, '*') since a
    # broadcast has no well-defined single counterparty. This test replaces
    # the old (now-incorrect) "broadcasts bypass entirely" assertion.
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6 7 8; do
        _tc11x_send_as_a '*' "Broadcast repeat $i" >/dev/null
    done

    # Same shape ("Broadcast repeat N") for all 8 -- must cap at the N=5
    # threshold: 5 delivered, 6th+ suppressed. Discriminates against a revert
    # of the array_length(...)=1 AND recipients[1]!='*' scoping condition,
    # which would deliver all 8 with zero breaker_state rows for recipient='*'.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}' AND recipients = ARRAY['*'];"
    [ "$output" -lt 8 ]
    [ "$output" -ge 1 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '*';"
    [ "$output" = "t" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_suppressed_log WHERE reason = 'loop_breaker' AND sender = '${_TC11X_ROLE_A}';"
    [ "$output" = "1" ]
}

@test "TC-116 DISCRIMINATES: reverting the broadcast scoping condition re-exempts broadcasts from the breaker entirely" {
    # Proves TC-116 exercises the fix. Temporarily reverts send_agent_message()
    # to the pre-fix scoping condition (array_length(v_recipients,1) = 1 AND
    # v_recipients[1] != '*' -- i.e. broadcasts excluded) inside this test's
    # own database, and asserts all 8 broadcasts are now WRONGLY delivered
    # with zero breaker_state rows for recipient='*' -- the failure mode
    # TC-116 exists to catch.
    _tc11x_setup_roles_and_schema

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        CREATE OR REPLACE FUNCTION public.send_agent_message(
            p_sender text, p_message text, p_recipients text[],
            p_ttl interval DEFAULT NULL::interval, p_reply_to integer DEFAULT NULL
        ) RETURNS integer LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS \$\$
        DECLARE
            v_id INTEGER; v_sender TEXT; v_recipients TEXT[]; v_expires_at TIMESTAMPTZ;
            v_has_artifact BOOLEAN; v_recipient TEXT; v_state RECORD;
            v_window CONSTANT INTERVAL := interval '15 minutes';
            v_threshold CONSTANT INTEGER := 5;
        BEGIN
            IF LOWER(p_sender) != session_user THEN
                RAISE EXCEPTION 'send_agent_message: sender must match session_user (got % but connected as %)', p_sender, session_user;
            END IF;
            IF p_message IS NULL OR trim(p_message) = '' THEN
                RAISE EXCEPTION 'send_agent_message: message cannot be empty';
            END IF;
            IF p_recipients IS NULL OR array_length(p_recipients, 1) IS NULL THEN
                RAISE EXCEPTION 'send_agent_message: recipients cannot be NULL or empty';
            END IF;
            v_sender := LOWER(p_sender);
            v_recipients := ARRAY(SELECT LOWER(unnest(p_recipients)));
            IF v_sender = ANY(v_recipients) THEN
                RAISE EXCEPTION 'send_agent_message: sender in recipient list';
            END IF;
            IF public.agent_chat_is_error_template(p_message) THEN
                INSERT INTO public.agent_chat_suppressed_log (reason, sender, recipients, message_sample)
                VALUES ('sender_filter_error_template', v_sender, v_recipients, left(p_message, 500));
                RETURN NULL;
            END IF;
            IF p_ttl IS NOT NULL THEN v_expires_at := NOW() + p_ttl; END IF;
            IF array_length(v_recipients, 1) = 1 AND v_recipients[1] != '*' THEN
                v_recipient := v_recipients[1];
                v_has_artifact := public.agent_chat_has_artifact_ref(p_message);
                SELECT * INTO v_state FROM public.agent_chat_breaker_state
                    WHERE sender = v_sender AND recipient = v_recipient FOR UPDATE;
                IF NOT FOUND THEN
                    INSERT INTO public.agent_chat_breaker_state
                        (sender, recipient, window_start, message_count, tripped, suppressed_count, last_message_at)
                    VALUES (v_sender, v_recipient, now(), 1, false, 0, now());
                ELSIF v_has_artifact OR v_state.last_message_at < now() - v_window THEN
                    UPDATE public.agent_chat_breaker_state
                    SET window_start = now(), message_count = 1, tripped = false, suppressed_count = 0, last_message_at = now()
                    WHERE sender = v_sender AND recipient = v_recipient;
                ELSE
                    UPDATE public.agent_chat_breaker_state
                    SET message_count = v_state.message_count + 1, last_message_at = now()
                    WHERE sender = v_sender AND recipient = v_recipient RETURNING * INTO v_state;
                    IF v_state.message_count > v_threshold THEN
                        IF NOT v_state.tripped THEN
                            INSERT INTO public.agent_chat_suppressed_log
                                (reason, sender, recipients, message_sample, window_message_count)
                            VALUES ('loop_breaker', v_sender, v_recipients, left(p_message, 500), v_state.message_count);
                            UPDATE public.agent_chat_breaker_state SET tripped = true, suppressed_count = 1
                                WHERE sender = v_sender AND recipient = v_recipient;
                        ELSE
                            UPDATE public.agent_chat_breaker_state SET suppressed_count = suppressed_count + 1
                                WHERE sender = v_sender AND recipient = v_recipient;
                        END IF;
                        RETURN NULL;
                    END IF;
                END IF;
            END IF;
            INSERT INTO public.agent_chat (sender, message, recipients, reply_to, expires_at)
            VALUES (v_sender, p_message, v_recipients, p_reply_to, v_expires_at) RETURNING id INTO v_id;
            RETURN v_id;
        END;
        \$\$;
    " 2>/dev/null || true

    for i in 1 2 3 4 5 6 7 8; do
        _tc11x_send_as_a '*' "Broadcast repeat $i" >/dev/null
    done

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat WHERE sender = '${_TC11X_ROLE_A}' AND recipients = ARRAY['*'];"
    [ "$output" = "8" ]   # WRONGLY all delivered under the reverted (pre-fix) scoping condition -- proves TC-116 discriminates

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_breaker_state WHERE recipient = '*';"
    [ "$output" = "0" ]
}

@test "TC-116b: an ordinary single-recipient send to a different, named peer is unaffected by another pair's tripped broadcast breaker" {
    # Sanity check that the sender-scoped (sender, '*') breaker key does not
    # bleed into the sender's normal 1:1 breaker state for a real recipient.
    _tc11x_setup_roles_and_schema

    for i in 1 2 3 4 5 6; do
        _tc11x_send_as_a '*' "Broadcast repeat $i" >/dev/null
    done
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT tripped FROM agent_chat_breaker_state WHERE sender = '${_TC11X_ROLE_A}' AND recipient = '*';"
    [ "$output" = "t" ]

    run _tc11x_send_as_a "$_TC11X_ROLE_B" "Can you take a look at agent-chat#11 when you get a chance?"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "TC-117: standard agent roles cannot write directly to the new control tables" {
    _tc11x_setup_roles_and_schema

    run env PGPASSFILE="$_TC11X_PGPASSFILE" psql -h localhost -U "$_TC11X_ROLE_A" -d "$AGENT_CHAT_DB_NAME" -c "INSERT INTO agent_chat_error_templates (pattern) VALUES ('direct write attempt');"
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission denied"* ]]

    run env PGPASSFILE="$_TC11X_PGPASSFILE" psql -h localhost -U "$_TC11X_ROLE_A" -d "$AGENT_CHAT_DB_NAME" -c "INSERT INTO agent_chat_breaker_state (sender, recipient) VALUES ('x','y');"
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission denied"* ]]

    run env PGPASSFILE="$_TC11X_PGPASSFILE" psql -h localhost -U "$_TC11X_ROLE_A" -d "$AGENT_CHAT_DB_NAME" -c "INSERT INTO agent_chat_suppressed_log (reason, sender, recipients, message_sample) VALUES ('loop_breaker','x',ARRAY['y'],'z');"
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission denied"* ]]

    # SELECT must still work (loud-in-the-log constraint requires readability).
    run env PGPASSFILE="$_TC11X_PGPASSFILE" psql -h localhost -U "$_TC11X_ROLE_A" -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat_error_templates;"
    [ "$status" -eq 0 ]
    [ "$output" -ge 3 ]

}

@test "TC-117b: a role in the ambient default-privilege grantee list, with NO explicit grant on the control tables, still gets no DML (proves the REVOKE, not the test's own setup grants)" {
    # Gem's QA review: TC-117 is circular -- its own _tc11x_setup_roles_and_schema
    # helper explicitly GRANT SELECTs on the three control tables, so stripping
    # the migration/schema REVOKE wouldn't change TC-117's outcome (the ambient
    # ALTER DEFAULT PRIVILEGES FOR ROLE postgres grant would still be masked by
    # the same explicit SELECT grant the test issues either way, and the
    # INSERT/UPDATE/DELETE assertions never depended on whether the REVOKE ran).
    #
    # This test targets a role that is actually a member of schema.sql's
    # `ALTER DEFAULT PRIVILEGES FOR ROLE postgres ... GRANT DELETE, INSERT,
    # SELECT, UPDATE ON TABLES TO (...)` grantee list -- i.e. a role for which
    # the ambient auto-grant hazard is real -- and issues ZERO explicit
    # grants of its own on the three control tables. It checks the resulting
    # privileges directly via has_table_privilege() rather than creating a
    # brand-new, unlisted role name (which would never receive the ambient
    # grant regardless of whether the REVOKE ran, and so would not
    # discriminate at all -- an earlier draft of this test made exactly that
    # mistake and was corrected before landing).
    #
    # If the migration/schema REVOKE is stripped, this role auto-receives
    # full DELETE/INSERT/SELECT/UPDATE via the ambient default-privilege
    # mechanism and this test fails.
    run "$INSTALLER"
    [ "$status" -eq 0 ]

    # 'scout' is a real entry in both the ALTER DEFAULT PRIVILEGES grantee list
    # (schema.sql) and the REVOKE's v_roles list (schema.sql + migration 005) --
    # it receives no table-specific GRANT anywhere in this test file, so any
    # privilege it holds on the three control tables comes solely from the
    # ambient mechanism and whatever the REVOKE did (or didn't) neutralize.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('scout', 'public.agent_chat_error_templates', 'INSERT');"
    [ "$output" = "f" ]
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('scout', 'public.agent_chat_error_templates', 'UPDATE');"
    [ "$output" = "f" ]
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('scout', 'public.agent_chat_error_templates', 'DELETE');"
    [ "$output" = "f" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('scout', 'public.agent_chat_breaker_state', 'INSERT');"
    [ "$output" = "f" ]
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('scout', 'public.agent_chat_suppressed_log', 'INSERT');"
    [ "$output" = "f" ]

    # SELECT must still be granted (loud-in-the-log constraint).
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('scout', 'public.agent_chat_error_templates', 'SELECT');"
    [ "$output" = "t" ]
}

@test "TC-117b DISCRIMINATES: stripping the REVOKE lets the ambient default-privilege grant through for an unmodified role" {
    # Proves TC-117b actually exercises the hazard: applies schema.sql, then
    # simulates a stripped REVOKE by re-granting INSERT/UPDATE/DELETE on the
    # three control tables to the exact same v_roles list the REVOKE targets
    # (equivalent to schema.sql never having run the REVOKE block), and
    # asserts 'scout' now WRONGLY holds INSERT -- the failure mode TC-117b
    # exists to catch.
    run "$INSTALLER"
    [ "$status" -eq 0 ]

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        DO \$\$
        DECLARE
            v_roles CONSTANT text[] := ARRAY[
                'argus','athena','coder','conductor','erato','flint','gem','gidget',
                'graybeard','hermes','iris','marcie','nova','quill','scout','scribe',
                'ticker','victoria'
            ];
            v_role text;
            v_table text;
        BEGIN
            FOREACH v_table IN ARRAY ARRAY[
                'agent_chat_error_templates',
                'agent_chat_breaker_state',
                'agent_chat_suppressed_log'
            ]
            LOOP
                FOREACH v_role IN ARRAY v_roles
                LOOP
                    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
                        EXECUTE format('GRANT INSERT, UPDATE, DELETE ON TABLE public.%I TO %I', v_table, v_role);
                    END IF;
                END LOOP;
            END LOOP;
        END \$\$;
    "

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT has_table_privilege('scout', 'public.agent_chat_error_templates', 'INSERT');"
    [ "$output" = "t" ]   # WRONGLY granted under the simulated stripped-REVOKE state -- proves TC-117b discriminates
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
    [[ "$output" == *"Applied 005"* ]]

    # Verify schema_version. Derived from migrations/ rather than hardcoded, for
    # the same reason install.sh derives it (agent-chat#6): a hardcoded literal
    # here turns every new migration into a spurious TC-01 failure, which trains
    # readers to treat this assertion as noise. Caught when migration 006
    # (agent-chat#18) made the previous hardcoded "5" stale.
    local expected_version=1 base num
    for f in "$REPO_ROOT"/migrations/*.sql; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        num="${base%%-*}"
        case "$num" in
            ''|*[!0-9]*) continue ;;
        esac
        num=$((10#$num))
        [ "$num" -gt "$expected_version" ] && expected_version="$num"
    done

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT MAX(version) FROM public.schema_version;"
    [ "$output" = "$expected_version" ]

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
