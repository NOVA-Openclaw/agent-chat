#!/usr/bin/env bash
# Shared fixture-role helpers for agent-chat BATS suites.
#
# Tests run admin/setup work as the agentchat_test LOGIN role (CREATEDB,
# CREATEROLE).  Fixture roles impersonated by tests are unique per-test LOGIN
# roles with a random "act_<random6>_<basename>" prefix and a random password.
# A per-test temp PGPASSFILE (mktemp, umask 077) holds both the admin and the
# fixture credentials; it is removed by the test teardown.
#
# Consuming files must set:
#   ACT_PGPASSFILE  path to the temp PGPASSFILE
#
# Optional overrides:
#   ACT_ADMIN_USER  defaults to agentchat_test
#   ACT_ADMIN_HOST  defaults to localhost
#   ACT_ADMIN_PORT  defaults to 5432

ACT_ADMIN_USER="${ACT_ADMIN_USER:-agentchat_test}"
ACT_ADMIN_HOST="${ACT_ADMIN_HOST:-localhost}"
ACT_ADMIN_PORT="${ACT_ADMIN_PORT:-5432}"

# Generate a 6-character lowercase alphanumeric random suffix.
act_random_suffix() {
    tr -dc 'a-z0-9' </dev/urandom | head -c 6
}

# Generate a 24-character alphanumeric password.
act_random_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

# Create a temp PGPASSFILE seeded with the admin user's credentials from the
# host ~/.pgpass.  Echoes the path; caller should assign to ACT_PGPASSFILE.
act_init_pgpass() {
    local pgpass
    pgpass="$(mktemp)"
    chmod 600 "$pgpass"
    # Make the admin entry broad enough to reach any test DB on localhost.
    sed -E "s/^(${ACT_ADMIN_HOST}|127\.0\.0\.1):([0-9]+):([^:]*):${ACT_ADMIN_USER}:(.*)$/\1:\2:*:${ACT_ADMIN_USER}:\4/" /home/nova/.pgpass > "$pgpass" 2>/dev/null || true
    printf '%s' "$pgpass"
}

# Run psql as the admin user (agentchat_test).
act_admin_psql() {
    local db="$1"
    shift
    PGPASSFILE="$ACT_PGPASSFILE" psql -h "$ACT_ADMIN_HOST" -p "$ACT_ADMIN_PORT" -U "$ACT_ADMIN_USER" -d "$db" -v ON_ERROR_STOP=1 "$@"
}

# Apply a schema/migration SQL file as the admin user with the devtest gate
# enabled, so insufficient_privilege handlers in schema.sql and migrations log
# a notice instead of raising.  Production applies (e.g. install.sh) must NOT
# set this flag so privilege errors fail loudly.
act_apply_sql_file() {
    local db="$1"
    local sql_file="$2"
    PGOPTIONS='-c agent_chat.devtest=on' act_admin_psql "$db" -f "$sql_file"
}

# Run psql as a fixture role.
act_fixture_psql() {
    local role="$1"
    local db="$2"
    shift 2
    PGPASSFILE="$ACT_PGPASSFILE" psql -h "$ACT_ADMIN_HOST" -p "$ACT_ADMIN_PORT" -U "$role" -d "$db" -v ON_ERROR_STOP=1 "$@"
}

# Create a LOGIN fixture role with a random password, grant it the standard
# agent send/receive privileges on db_name, and append its credentials to
# ACT_PGPASSFILE.  Echoes the role name.
act_create_fixture_role() {
    local prefix="$1"
    local suffix="$2"
    local db_name="$3"
    local role_name="${prefix}_${suffix}"
    local pass
    pass="$(act_random_password)"

    act_admin_psql postgres -c "CREATE ROLE \"$role_name\" LOGIN PASSWORD '$pass';" >/dev/null

    # Apply the same hardened standard grant set that register-agent.sh uses.
    # agent-chat#39: no named grants, no direct DML on agent_chat, and no
    # EXECUTE grants (bus functions remain PUBLIC EXECUTE).
    act_admin_psql "$db_name" -c "
        GRANT USAGE ON SCHEMA public TO \"$role_name\";
        GRANT SELECT ON TABLE public.agent_chat TO \"$role_name\";
        GRANT SELECT, INSERT, UPDATE ON TABLE public.agent_chat_processed TO \"$role_name\";
    " >/dev/null

    printf 'localhost:%s:%s:%s:%s\n' "$ACT_ADMIN_PORT" "$db_name" "$role_name" "$pass" >> "$ACT_PGPASSFILE"
    printf '%s' "$role_name"
}

# Terminate backends owned by role and drop it.  Tolerant of failures.
act_drop_fixture_role() {
    local role="$1"
    [ -n "$role" ] || return 0
    act_admin_psql postgres -v ON_ERROR_STOP=0 -At -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '$role' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
    act_admin_psql postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$role\";" >/dev/null 2>&1 || true
}
