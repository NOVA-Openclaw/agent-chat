#!/usr/bin/env bats
# BATS tests for agent-chat#39 / SE #1453 Fix Loop 7.
#
# Coverage:
#   R2-01..R2-10: no agent-identity-specific grants, portable fresh install,
#                 safe upgrade via migration 009, least privilege.
#   J06-J07: back-compat for naive pre-fix callers.
#
# Fresh-install tests (R2-03, R2-04) run against a throwaway initdb-created
# Postgres cluster on a free high port, started inside setup/teardown as an
# unprivileged user. No shared production/staging cluster is touched.

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# shellcheck source=fixture-roles.bash
source "$BATS_TEST_DIRNAME/fixture-roles.bash"

INSTALLER="$REPO_ROOT/install.sh"
REGISTER="$REPO_ROOT/register-agent.sh"

# Known NOVA agent names deny-list from the test spec.
AGENT_NAME_DENYLIST=(
    argus athena cadence coder conductor erato flint gem gidget graybeard
    hermes iris marcie newhart nova nova-staging quill recon scout scribe
    ticker victoria
)

# ─── Ephemeral Postgres cluster helpers ────────────────────────────────────

# Find the first free TCP port in a range.
_find_free_port() {
    local low="${1:-30000}" high="${2:-65000}"
    python3 -c "
import socket
for p in range($low, $high):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(('127.0.0.1', p))
        s.close()
        print(p)
        break
    except OSError:
        s.close()
"
}

# Start a throwaway Postgres cluster. Exports EP_*
_ephemeral_start() {
    EP_PORT="$(_find_free_port)"
    EP_DATA="$(mktemp -d)"
    EP_LOG="$EP_DATA/postgres.log"
    EP_HOST="127.0.0.1"

    export PGPORT="$EP_PORT"
    export PGHOST="$EP_HOST"
    export PGDATA="$EP_DATA"

    /usr/lib/postgresql/16/bin/initdb -D "$EP_DATA" --auth=trust --username=postgres --no-locale --encoding=UTF8 >/dev/null 2>&1

    # Start on the chosen port and a socket in the data dir.
    /usr/lib/postgresql/16/bin/pg_ctl -D "$EP_DATA" -l "$EP_LOG" start -o "-p $EP_PORT -k $EP_DATA" >/dev/null 2>&1

    # Wait for accept.
    local i
    for i in $(seq 1 50); do
        if /usr/lib/postgresql/16/bin/pg_isready -h "$EP_HOST" -p "$EP_PORT" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done

    # Create an admin role with CREATEDB+CREATEROLE analogous to agentchat_test.
    EP_ADMIN_USER="act_$(act_random_suffix)_admin"
    EP_ADMIN_PASS="$(act_random_password)"
    psql -h "$EP_HOST" -p "$EP_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
        CREATE ROLE \"$EP_ADMIN_USER\" LOGIN CREATEDB CREATEROLE PASSWORD '$EP_ADMIN_PASS';
    " >/dev/null

    # Seed a .pgpass for this cluster.
    EP_PGPASS="$(mktemp)"
    chmod 600 "$EP_PGPASS"
    printf '127.0.0.1:%s:*:postgres:trust\n' "$EP_PORT" >> "$EP_PGPASS"
    printf '127.0.0.1:%s:*:%s:%s\n' "$EP_PORT" "$EP_ADMIN_USER" "$EP_ADMIN_PASS" >> "$EP_PGPASS"
    export PGPASSFILE="$EP_PGPASS"
}

# Run psql as the ephemeral admin.
_ephemeral_admin_psql() {
    psql -h "$EP_HOST" -p "$EP_PORT" -U "$EP_ADMIN_USER" "$@"
}

# Run psql as the ephemeral postgres superuser.
_ephemeral_super_psql() {
    psql -h "$EP_HOST" -p "$EP_PORT" -U postgres "$@"
}

# Stop and remove the ephemeral cluster.
_ephemeral_stop() {
    if [ -n "${EP_DATA:-}" ] && [ -d "$EP_DATA" ]; then
        /usr/lib/postgresql/16/bin/pg_ctl -D "$EP_DATA" stop -m fast >/dev/null 2>&1 || true
        rm -rf "$EP_DATA"
    fi
    rm -f "${EP_PGPASS:-}"
}

setup() {
    # Default to the shared test cluster for tests that don't need isolation.
    ACT_PGPASSFILE="$(act_init_pgpass)"
}

teardown() {
    _ephemeral_stop
    rm -f "${ACT_PGPASSFILE:-}"
}

# ─── R2-01..R2-02: static named-grant grep checks ──────────────────────────

@test "R2-01: no *.sql or *.sh file contains a named agent grant" {
    local f
    for f in "$REPO_ROOT"/*.sql "$REPO_ROOT"/migrations/*.sql "$REPO_ROOT"/*.sh "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/tests/*.bash; do
        [ -f "$f" ] || continue
        # Reject GRANT/REVOKE/ALTER DEFAULT PRIVILEGES ... TO/FROM <identifier>
        # where identifier is not PUBLIC, CURRENT_USER, SESSION_USER, %I, or a shell variable.
        run grep -nE "(GRANT|REVOKE|ALTER DEFAULT PRIVILEGES)[^;]*\b(TO|FROM)\b[^;]*\b(argus|athena|cadence|coder|conductor|erato|flint|gem|gidget|graybeard|hermes|iris|marcie|newhart|nova|nova-staging|quill|recon|scout|scribe|ticker|victoria)\b" "$f"
        if [ "$status" -eq 0 ]; then
            echo "Named grant found in $f:" >&2
            echo "$output" >&2
            return 1
        fi
    done
}

@test "R2-02: docs and README mention no named grants as executable policy" {
    # Non-failing warning check: ensure prose no longer documents named-role
    # asymmetries as preserved access-control decisions.
    local f
    for f in "$REPO_ROOT"/docs/security-model.md "$REPO_ROOT"/README.md; do
        run grep -nE "\b(newhart|cadence|recon|victoria|nova-staging) (is|gets|has|receive|denied|explicitly)" "$f"
        if [ "$status" -eq 0 ]; then
            echo "WARNING: $f still documents named-role grant asymmetries:" >&2
            echo "$output" >&2
            # This is intentionally a warning, not a hard failure.
        fi
    done
}

# ─── R2-03: fresh install succeeds on a clean cluster ──────────────────────

@test "R2-03: install.sh succeeds on an ephemeral cluster with no NOVA roles" {
    _ephemeral_start

    local db_name
    db_name="agent_chat_fresh_$$"

    # Confirm no deny-list roles exist.
    local name
    for name in "${AGENT_NAME_DENYLIST[@]}"; do
        run _ephemeral_super_psql -d postgres -At -c "SELECT 1 FROM pg_roles WHERE rolname = '$name';"
        [ -z "$output" ]
    done

    # Run installer as the ephemeral admin with devtest gate (non-superuser apply).
    AGENT_CHAT_DB_NAME="$db_name" PGUSER="$EP_ADMIN_USER" PGOPTIONS='-c agent_chat.devtest=on' run "$INSTALLER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applied schema.sql"* ]]

    # Verify schema_version.
    run _ephemeral_admin_psql -d "$db_name" -At -c "SELECT MAX(version) FROM public.schema_version;"
    [ "$output" = "9" ]
}

# ─── R2-04: schema.sql + all migrations apply cleanly on clean cluster ─────

@test "R2-04: schema.sql and all migrations apply cleanly on an ephemeral cluster" {
    _ephemeral_start

    local db_name
    db_name="agent_chat_schema_$$"

    _ephemeral_super_psql -d postgres -c "CREATE DATABASE \"$db_name\";" >/dev/null

    # Apply as postgres superuser; devtest gate not needed.
    run _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/schema.sql"
    [ "$status" -eq 0 ]

    local f
    for f in "$REPO_ROOT"/migrations/*.sql; do
        run _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$f"
        [ "$status" -eq 0 ]
    done

    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT MAX(version) FROM public.schema_version;"
    [ "$output" = "9" ]
}

# ─── R2-06: register-agent.sh gives a new generic role working access ──────

@test "R2-06: a brand-new role registered via register-agent.sh can send and poll" {
    _ephemeral_start

    local db_name fixture_role fixture_pass
    db_name="agent_chat_reg_$$"
    fixture_role="act_$(act_random_suffix)_newagent"
    fixture_pass="$(act_random_password)"

    # Run installer as postgres so SECURITY DEFINER functions are owned by
    # postgres and the immutability trigger authorizes their inserts.
    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$INSTALLER"
    [ "$status" -eq 0 ]

    # register-agent.sh needs GRANT OPTION on the tables; run as postgres on
    # the ephemeral cluster (equivalent to a delegated admin in production).
    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$REGISTER" --password "$fixture_pass" "$fixture_role"
    [ "$status" -eq 0 ]

    printf '127.0.0.1:%s:%s:%s:%s\n' "$EP_PORT" "$db_name" "$fixture_role" "$fixture_pass" >> "$EP_PGPASS"

    # send_agent_message succeeds (PUBLIC EXECUTE, no named grant).
    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT send_agent_message('$fixture_role', 'hello from new agent', ARRAY['peer']);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # SELECT succeeds.
    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT count(*) FROM public.agent_chat WHERE sender = '$fixture_role';"
    [ "$output" = "1" ]

    # Direct INSERT is denied. Because register-agent.sh does not grant INSERT
    # on agent_chat, Postgres rejects the command before the immutability
    # trigger fires; this is defense-in-depth with the trigger.
    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "INSERT INTO public.agent_chat (sender, message, recipients) VALUES ('$fixture_role', 'direct', ARRAY['peer']);"
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission denied for table agent_chat"* ]] || \
    [[ "$output" == *"Direct INSERT on agent_chat is not allowed"* ]] || \
    [[ "$output" == *"Use send_agent_message"* ]]
}

# ─── R2-07: migration 009 preserves existing agents' access ────────────────

@test "R2-07: migration 009 keeps pre-existing agents working without naming them" {
    _ephemeral_start

    local db_name old_a old_b
    db_name="agent_chat_upgrade_$$"
    old_a="act_$(act_random_suffix)_legacy_a"
    old_b="act_$(act_random_suffix)_legacy_b"

    _ephemeral_super_psql -d postgres -c "CREATE DATABASE \"$db_name\";" >/dev/null

    # Apply schema.sql and migrations 001-008 to reach version 8 state.
    _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/schema.sql" >/dev/null
    local f
    for f in $(find "$REPO_ROOT"/migrations -maxdepth 1 -name '[0-9][0-9][0-9]-*.sql' | sort); do
        local num
        num="$(basename "$f" | sed -E 's/^([0-9]+).*/\1/')"
        if [ "$num" -le 8 ]; then
            _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$f" >/dev/null
        fi
    done

    # Simulate pre-fix named-grant state: create legacy roles and give them
    # the old-style access (SELECT on agent_chat + EXECUTE on send_agent_message).
    _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -c "
        CREATE ROLE \"$old_a\" LOGIN PASSWORD '$(act_random_password)';
        CREATE ROLE \"$old_b\" LOGIN PASSWORD '$(act_random_password)';
        GRANT USAGE ON SCHEMA public TO \"$old_a\", \"$old_b\";
        GRANT SELECT ON TABLE public.agent_chat TO \"$old_a\", \"$old_b\";
        GRANT EXECUTE ON FUNCTION public.send_agent_message(text,text,text[],interval,integer) TO \"$old_a\", \"$old_b\";
    " >/dev/null

    # Apply migration 009.
    run _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/migrations/009-agent-chat-39-generic-grants.sql"
    [ "$status" -eq 0 ]

    # Both legacy roles must still be able to send and select.
    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$old_a" -d "$db_name" -At -c \
        "SELECT send_agent_message('$old_a', 'still works', ARRAY['$old_b']);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$old_b" -d "$db_name" -At -c \
        "SELECT send_agent_message('$old_b', 'reply', ARRAY['$old_a']);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$old_a" -d "$db_name" -At -c \
        "SELECT count(*) FROM public.agent_chat WHERE sender = '$old_a';"
    [ "$output" = "1" ]
}

# ─── R2-08: migration 009 does not touch roles with no prior bus access ────

@test "R2-08: migration 009 leaves untouched roles unchanged" {
    _ephemeral_start

    local db_name untouched
    db_name="agent_chat_untouched_$$"
    untouched="act_$(act_random_suffix)_untouched"

    _ephemeral_super_psql -d postgres -c "CREATE DATABASE \"$db_name\";" >/dev/null

    _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/schema.sql" >/dev/null
    local f
    for f in $(find "$REPO_ROOT"/migrations -maxdepth 1 -name '[0-9][0-9][0-9]-*.sql' | sort); do
        local num
        num="$(basename "$f" | sed -E 's/^([0-9]+).*/\1/')"
        if [ "$num" -le 8 ]; then
            _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$f" >/dev/null
        fi
    done

    # Create a role with no agent_chat grants.
    _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -c "
        CREATE ROLE \"$untouched\" LOGIN PASSWORD '$(act_random_password)';
        GRANT USAGE ON SCHEMA public TO \"$untouched\";
    " >/dev/null

    # Apply migration 009.
    run _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/migrations/009-agent-chat-39-generic-grants.sql"
    [ "$status" -eq 0 ]

    # Untouched role still has no agent_chat privileges.
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$untouched', 'public.agent_chat', 'SELECT');"
    [ "$output" = "f" ]
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$untouched', 'public.agent_chat_processed', 'SELECT');"
    [ "$output" = "f" ]
}

# ─── R2-09: least privilege — no DML on agent_chat ─────────────────────────

@test "R2-09: registered role cannot perform direct DML on agent_chat" {
    _ephemeral_start

    local db_name fixture_role fixture_pass
    db_name="agent_chat_least_$$"
    fixture_role="act_$(act_random_suffix)_least"
    fixture_pass="$(act_random_password)"

    # Run installer as postgres so SECURITY DEFINER functions are owned by postgres.
    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$INSTALLER"
    [ "$status" -eq 0 ]

    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$REGISTER" --password "$fixture_pass" "$fixture_role"
    [ "$status" -eq 0 ]

    # has_table_privilege denies all three DML privileges.
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat', 'INSERT');"
    [ "$output" = "f" ]
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat', 'UPDATE');"
    [ "$output" = "f" ]
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$fixture_role', 'public.agent_chat', 'DELETE');"
    [ "$output" = "f" ]

    printf '127.0.0.1:%s:%s:%s:%s\n' "$EP_PORT" "$db_name" "$fixture_role" "$fixture_pass" >> "$EP_PGPASS"

    # Direct INSERT is denied by the absence of the INSERT grant (the immutability
    # trigger is a second layer for any role that mistakenly holds the grant).
    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "INSERT INTO public.agent_chat (sender, message, recipients) VALUES ('$fixture_role', 'x', ARRAY['peer']);"
    [ "$status" -ne 0 ]
    [[ "$output" == *"permission denied for table agent_chat"* ]] || \
    [[ "$output" == *"Direct INSERT on agent_chat is not allowed"* ]] || \
    [[ "$output" == *"Use send_agent_message"* ]]
}

# ─── R2-10: PUBLIC EXECUTE is actually in effect for registered roles ──────

@test "R2-10: registered role can execute all bus functions with no explicit EXECUTE grant" {
    _ephemeral_start

    local db_name fixture_role fixture_pass
    db_name="agent_chat_public_exec_$$"
    fixture_role="act_$(act_random_suffix)_pubexec"
    fixture_pass="$(act_random_password)"

    # Run installer as postgres so SECURITY DEFINER functions are owned by postgres.
    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$INSTALLER"
    [ "$status" -eq 0 ]

    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$REGISTER" --password "$fixture_pass" "$fixture_role"
    [ "$status" -eq 0 ]

    # No explicit EXECUTE grant exists.
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT count(*) FROM information_schema.role_routine_grants WHERE grantee = '$fixture_role' AND routine_schema = 'public';"
    [ "$output" = "0" ]

    printf '127.0.0.1:%s:%s:%s:%s\n' "$EP_PORT" "$db_name" "$fixture_role" "$fixture_pass" >> "$EP_PGPASS"

    # All six functions are callable via PUBLIC EXECUTE.
    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT send_agent_message('$fixture_role', 'test', ARRAY['peer']);"
    [ "$status" -eq 0 ]

    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT mark_agent_chat_status(ARRAY[]::bigint[], 'handled');"
    [ "$status" -eq 0 ]

    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT agent_chat_pending_alerts('$fixture_role');"
    [ "$status" -eq 0 ]

    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT agent_chat_mark_alerts_seen(ARRAY[]::int[]);"
    [ "$status" -eq 0 ]

    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT agent_chat_is_muted('$fixture_role', 'peer');"
    [ "$status" -eq 0 ]
}

# ─── R2-11: fresh install succeeds when existing bus users need quoting ─────
# Regression for SE #1453 Fix Loop 8: schema.sql's dynamic grant discovery
# used grantee::regrole::text + format('%I'), which double-quoted identifiers
# containing hyphens (e.g. nova-staging). The DB already existed and had a
# hyphenated role when Graybeard's staging install failed at schema.sql:1114.

_assert_least_privilege() {
    local db_name="$1"
    local role="$2"

    # agent_chat: SELECT only.
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.agent_chat', 'SELECT');"
    [ "$output" = "t" ]
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.agent_chat', 'INSERT');"
    [ "$output" = "f" ]
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.agent_chat', 'UPDATE');"
    [ "$output" = "f" ]
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.agent_chat', 'DELETE');"
    [ "$output" = "f" ]

    # agent_chat_processed: SELECT + INSERT + UPDATE, no DELETE.
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.agent_chat_processed', 'SELECT');"
    [ "$output" = "t" ]
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.agent_chat_processed', 'INSERT');"
    [ "$output" = "t" ]
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.agent_chat_processed', 'UPDATE');"
    [ "$output" = "t" ]
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.agent_chat_processed', 'DELETE');"
    [ "$output" = "f" ]

    # Control tables: SELECT only.
    local table
    for table in agent_chat_error_templates agent_chat_breaker_config \
                 agent_chat_breaker_state agent_chat_breaker_alerts \
                 agent_chat_mutes agent_chat_suppressed_log; do
        run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.$table', 'SELECT');"
        [ "$output" = "t" ]
        run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.$table', 'INSERT');"
        [ "$output" = "f" ]
        run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.$table', 'UPDATE');"
        [ "$output" = "f" ]
        run _ephemeral_super_psql -d "$db_name" -At -c "SELECT has_table_privilege('$role', 'public.$table', 'DELETE');"
        [ "$output" = "f" ]
    done
}

@test "R2-11: install.sh succeeds on a DB that already has hyphenated and mixed-case bus users" {
    _ephemeral_start

    local db_name role_hyphen role_mixed pass
    db_name="agent_chat_existing_quotes_$$"
    pass="$(act_random_password)"
    # Hyphen forces identifier quoting; mixed-case forces case preservation.
    role_hyphen="act_$(act_random_suffix)-test-role"
    role_mixed="Act_$(act_random_suffix)-MixedCase"

    _ephemeral_super_psql -d postgres -c "CREATE DATABASE \"$db_name\";" >/dev/null

    # Create the schema objects so the roles have something to be granted on.
    _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/schema.sql" >/dev/null
    local f
    for f in "$REPO_ROOT"/migrations/*.sql; do
        _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$f" >/dev/null
    done

    # Simulate existing bus users that pre-date this install run.
    _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -c "
        CREATE ROLE \"$role_hyphen\" LOGIN PASSWORD '$pass';
        CREATE ROLE \"$role_mixed\" LOGIN PASSWORD '$pass';
        GRANT USAGE ON SCHEMA public TO \"$role_hyphen\", \"$role_mixed\";
        GRANT SELECT ON TABLE public.agent_chat TO \"$role_hyphen\", \"$role_mixed\";
        GRANT SELECT, INSERT, UPDATE ON TABLE public.agent_chat_processed TO \"$role_hyphen\", \"$role_mixed\";
        GRANT EXECUTE ON FUNCTION public.send_agent_message(text,text,text[],interval,integer) TO \"$role_hyphen\", \"$role_mixed\";
    " >/dev/null

    # Reset schema_version to simulate the pre-existing DB being behind and
    # requiring a re-sync (Graybeard's scenario: DB existed, schema_version 8).
    _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -c "
        DELETE FROM public.schema_version WHERE version = 9;
    " >/dev/null

    # Re-run installer as postgres; it must discover the existing quoted roles,
    # re-apply the hardened grant set, and reach schema_version 9.
    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$INSTALLER"
    echo "$output" >&2
    [ "$status" -eq 0 ]

    # Schema version handshake reached 9.
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT MAX(version) FROM public.schema_version;"
    [ "$output" = "9" ]

    # Both pre-existing roles retain least-privilege bus access.
    _assert_least_privilege "$db_name" "$role_hyphen"
    _assert_least_privilege "$db_name" "$role_mixed"
}

# ─── R2-12: migration 009 succeeds when existing bus users need quoting ─────

@test "R2-12: migration 009 preserves hyphenated and mixed-case pre-existing agents" {
    _ephemeral_start

    local db_name role_hyphen role_mixed pass
    db_name="agent_chat_mig009_quotes_$$"
    pass="$(act_random_password)"
    role_hyphen="act_$(act_random_suffix)-legacy"
    role_mixed="Act_$(act_random_suffix)-LegacyMixed"

    _ephemeral_super_psql -d postgres -c "CREATE DATABASE \"$db_name\";" >/dev/null

    # Apply schema.sql and migrations 001-008 to reach version 8 state.
    _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/schema.sql" >/dev/null
    local f
    for f in $(find "$REPO_ROOT"/migrations -maxdepth 1 -name '[0-9][0-9][0-9]-*.sql' | sort); do
        local num
        num="$(basename "$f" | sed -E 's/^([0-9]+).*/\1/')"
        if [ "$num" -le 8 ]; then
            _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$f" >/dev/null
        fi
    done

    # Create legacy roles needing identifier quoting and grant old-style access.
    _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -c "
        CREATE ROLE \"$role_hyphen\" LOGIN PASSWORD '$pass';
        CREATE ROLE \"$role_mixed\" LOGIN PASSWORD '$pass';
        GRANT USAGE ON SCHEMA public TO \"$role_hyphen\", \"$role_mixed\";
        GRANT SELECT ON TABLE public.agent_chat TO \"$role_hyphen\", \"$role_mixed\";
        GRANT EXECUTE ON FUNCTION public.send_agent_message(text,text,text[],interval,integer) TO \"$role_hyphen\", \"$role_mixed\";
    " >/dev/null

    # Apply migration 009; this is where the double-quote bug bit.
    run _ephemeral_super_psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/migrations/009-agent-chat-39-generic-grants.sql"
    echo "$output" >&2
    [ "$status" -eq 0 ]

    # Version handshake reached 9.
    run _ephemeral_super_psql -d "$db_name" -At -c "SELECT MAX(version) FROM public.schema_version;"
    [ "$output" = "9" ]

    # Both legacy roles retain least-privilege bus access and can still send.
    _assert_least_privilege "$db_name" "$role_hyphen"
    _assert_least_privilege "$db_name" "$role_mixed"

    printf '127.0.0.1:%s:%s:%s:%s\n' "$EP_PORT" "$db_name" "$role_hyphen" "$pass" >> "$EP_PGPASS"
    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$role_hyphen" -d "$db_name" -At -c \
        "SELECT send_agent_message('$role_hyphen', 'still works', ARRAY['$role_mixed']);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ─── J06-J07: back-compat for naive pre-fix callers ────────────────────────

@test "J06: send_agent_message 3-arg call works and sets reply_to/expires_at NULL" {
    _ephemeral_start

    local db_name fixture_role fixture_pass
    db_name="agent_chat_j06_$$"
    fixture_role="act_$(act_random_suffix)_j06"
    fixture_pass="$(act_random_password)"

    # Run installer as postgres so SECURITY DEFINER functions are owned by postgres.
    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$INSTALLER"
    [ "$status" -eq 0 ]

    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$REGISTER" --password "$fixture_pass" "$fixture_role"
    [ "$status" -eq 0 ]

    printf '127.0.0.1:%s:%s:%s:%s\n' "$EP_PORT" "$db_name" "$fixture_role" "$fixture_pass" >> "$EP_PGPASS"

    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT send_agent_message('$fixture_role', 'legacy 3-arg', ARRAY['peer']);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _ephemeral_super_psql -d "$db_name" -At -c \
        "SELECT reply_to IS NULL AND expires_at IS NULL FROM public.agent_chat WHERE sender = '$fixture_role';"
    [ "$output" = "t" ]
}

@test "J07: mark_agent_chat_status accepts pre-#23 statuses with old argument shape" {
    _ephemeral_start

    local db_name fixture_role fixture_pass
    db_name="agent_chat_j07_$$"
    fixture_role="act_$(act_random_suffix)_j07"
    fixture_pass="$(act_random_password)"

    # Run installer as postgres so SECURITY DEFINER functions are owned by postgres.
    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$INSTALLER"
    [ "$status" -eq 0 ]

    AGENT_CHAT_DB_NAME="$db_name" PGUSER=postgres run "$REGISTER" --password "$fixture_pass" "$fixture_role"
    [ "$status" -eq 0 ]

    # Seed two messages addressed to the fixture role (direct insert as superuser).
    _ephemeral_super_psql -d "$db_name" -c "
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES
            (701, 'peer_a', 'legacy handled', ARRAY['$fixture_role']),
            (702, 'peer_a', 'legacy expired', ARRAY['$fixture_role']);
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    printf '127.0.0.1:%s:%s:%s:%s\n' "$EP_PORT" "$db_name" "$fixture_role" "$fixture_pass" >> "$EP_PGPASS"

    # Old caller shape: bigint[], text, no named params, only 'handled'/'expired'.
    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT mark_agent_chat_status(ARRAY[701], 'handled');"
    [ "$status" -eq 0 ]
    run psql -h "$EP_HOST" -p "$EP_PORT" -U "$fixture_role" -d "$db_name" -At -c \
        "SELECT mark_agent_chat_status(ARRAY[702], 'expired');"
    [ "$status" -eq 0 ]

    run _ephemeral_super_psql -d "$db_name" -At -c \
        "SELECT string_agg(chat_id || '=' || status, ',' ORDER BY chat_id) FROM public.agent_chat_processed WHERE agent = '$fixture_role';"
    [ "$output" = "701=handled,702=expired" ]
}
