#!/usr/bin/env bats
# PG-layer tests for agent-chat#23 Chunk B (Requirement 7 one-time cleanup).
#
# Coverage: TC-23-090..101
#
# Every test runs against its own disposable scratch database. Fixture roles
# are created NOLOGIN and impersonated via SET SESSION AUTHORIZATION so no
# passwords are needed and no LOGIN roles leak. The live agent_chat database
# is never touched.

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Agent names used as fixtures (suffix with test number + pid to avoid leaks).
_issue23_agent_name() {
    printf '%s_%s_%s' "$1" "$BATS_TEST_NUMBER" "$$"
}

_issue23_track_role() {
    printf '%s\n' "$1" >> "$BATS_FILE_TMPDIR/issue23_cleanup_roles.txt"
}

_issue23_setup_db() {
    local db_name="$1"
    psql -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$db_name\";" >/dev/null 2>&1
    createdb "$db_name" >/dev/null
    psql -d "$db_name" -f "$REPO_ROOT/schema.sql" >/dev/null 2>&1
    for f in "$REPO_ROOT"/migrations/*.sql; do
        psql -d "$db_name" -f "$f" >/dev/null 2>&1 || {
            echo "FAILED to apply $(basename "$f")" >&2
            return 1
        }
    done
}

_issue23_setup_roles() {
    local db_name="$1"
    shift
    local role
    for role in "$@"; do
        psql -d postgres -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS \"$role\"; CREATE ROLE \"$role\" NOLOGIN;" >/dev/null
        psql -d "$db_name" -v ON_ERROR_STOP=1 -c "GRANT USAGE ON SCHEMA public TO \"$role\"; GRANT INSERT, SELECT ON public.agent_chat TO \"$role\"; GRANT INSERT, SELECT, UPDATE ON public.agent_chat_processed TO \"$role\"; GRANT SELECT ON public.agent_chat_error_templates, public.agent_chat_breaker_state, public.agent_chat_suppressed_log TO \"$role\";" >/dev/null
        _issue23_track_role "$role"
    done
}

_issue23_psql_as() {
    local db_name="$1"
    local role="$2"
    local sql="$3"
    psql -d "$db_name" -At -v ON_ERROR_STOP=1 -c "SET SESSION AUTHORIZATION \"$role\"; $sql"
}

_issue23_run_cleanup() {
    local db_name="$1"
    psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/migrations/007-agent-chat-23-one-time-cleanup.sql" >/dev/null 2>&1
}

setup_file() {
    : > "$BATS_FILE_TMPDIR/issue23_cleanup_roles.txt"
}

setup() {
    FAKE_HOME="$(mktemp -d)"
    AGENT_CHAT_DB_NAME="agent_chat_issue23_cleanup_${BATS_TEST_NUMBER}_$$"
    _ISSUE23_ROLES=()
    _issue23_setup_db "$AGENT_CHAT_DB_NAME"
}

teardown() {
    if [ -n "${AGENT_CHAT_DB_NAME:-}" ]; then
        psql -d postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"$AGENT_CHAT_DB_NAME\";" >/dev/null 2>&1 || true
    fi
    if [ ${#_ISSUE23_ROLES[@]} -gt 0 ]; then
        for role in "${_ISSUE23_ROLES[@]}"; do
            psql -d postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$role\";" >/dev/null 2>&1 || true
        done
    fi
    rm -rf "$FAKE_HOME"
}

teardown_file() {
    if [ -s "$BATS_FILE_TMPDIR/issue23_cleanup_roles.txt" ]; then
        while IFS= read -r role; do
            [ -n "$role" ] && psql -d postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$role\";" >/dev/null 2>&1 || true
        done < "$BATS_FILE_TMPDIR/issue23_cleanup_roles.txt"
    fi
}

# ─── Requirement 7 cleanup cases ────────────────────────────────────────────

@test "TC-23-090: cleanup updates existing unresolved old row to expired" {
    local coder
    coder="$(_issue23_agent_name coder)"
    _ISSUE23_ROLES=("$coder")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$coder"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\")
            VALUES (500, 'nova', 'old msg', ARRAY['$coder'], NOW() - interval '10 days');
        INSERT INTO public.agent_chat_processed (chat_id, agent, status)
            VALUES (500, '$coder', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status || '|' || CASE WHEN expired_at IS NOT NULL THEN 'yes' ELSE 'no' END FROM public.agent_chat_processed WHERE chat_id = 500 AND agent = '$coder';"
    [ "$status" -eq 0 ]
    [ "$output" = "expired|yes" ]
}

@test "TC-23-091: boundary exactly 7 days is NOT expired" {
    local coder
    coder="$(_issue23_agent_name coder)"
    _ISSUE23_ROLES=("$coder")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$coder"

    # Implementation uses `agent_chat.timestamp < now() - interval '7 days'`
    # (strictly older). Because NOW() moves between INSERT and cleanup, an
    # "exactly 7 days" row cannot be tested reliably; instead we use a row one
    # second inside the 7-day window to document the exclusive boundary.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\")
            VALUES (501, 'nova', 'just inside 7d window', ARRAY['$coder'], NOW() - interval '7 days' + interval '1 second');
        INSERT INTO public.agent_chat_processed (chat_id, agent, status)
            VALUES (501, '$coder', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status FROM public.agent_chat_processed WHERE chat_id = 501 AND agent = '$coder';"
    [ "$status" -eq 0 ]
    [ "$output" = "routed" ]
}

@test "TC-23-092: boundary 7d-1s untouched, 7d+1s expired" {
    local coder
    coder="$(_issue23_agent_name coder)"
    _ISSUE23_ROLES=("$coder")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$coder"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\") VALUES
            (5021, 'nova', 'just under', ARRAY['$coder'], NOW() - (interval '7 days' - interval '1 second')),
            (5022, 'nova', 'just over',  ARRAY['$coder'], NOW() - (interval '7 days' + interval '1 second'));
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES
            (5021, '$coder', 'routed'),
            (5022, '$coder', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT chat_id, status FROM public.agent_chat_processed WHERE chat_id IN (5021, 5022) ORDER BY chat_id;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"5021|routed"* ]]
    [[ "$output" == *"5022|expired"* ]]
}

@test "TC-23-093: cleanup inserts expired for never-picked-up old message" {
    local coder
    coder="$(_issue23_agent_name coder)"
    _ISSUE23_ROLES=("$coder")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$coder"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\")
            VALUES (502, 'nova', 'never picked up', ARRAY['$coder'], NOW() - interval '10 days');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status || '|' || CASE WHEN expired_at IS NOT NULL THEN 'yes' ELSE 'no' END FROM public.agent_chat_processed WHERE chat_id = 502 AND agent = '$coder';"
    [ "$status" -eq 0 ]
    [ "$output" = "expired|yes" ]
}

@test "TC-23-094: multi-recipient partial pickup updates one and inserts other" {
    local coder scribe
    coder="$(_issue23_agent_name coder)"
    scribe="$(_issue23_agent_name scribe)"
    _ISSUE23_ROLES=("$coder" "$scribe")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$coder" "$scribe"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\")
            VALUES (503, 'nova', 'partial pickup', ARRAY['$coder', '$scribe'], NOW() - interval '10 days');
        INSERT INTO public.agent_chat_processed (chat_id, agent, status)
            VALUES (503, '$coder', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT agent || '|' || status FROM public.agent_chat_processed WHERE chat_id = 503 ORDER BY agent;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$coder|expired"* ]]
    [[ "$output" == *"$scribe|expired"* ]]
}

@test "TC-23-095: broadcast '*' recipient excluded entirely" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\")
            VALUES (504, 'nova', 'broadcast old', ARRAY['*'], NOW() - interval '10 days');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_processed WHERE chat_id = 504;"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_processed WHERE chat_id = 504;"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "TC-23-096: agent='main' rows stay exactly as they are" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\") VALUES
            (600, 'nova', 'main old routed', ARRAY['nova'], NOW() - interval '10 days'),
            (601, 'nova', 'main old received', ARRAY['nova'], NOW() - interval '10 days'),
            (602, 'nova', 'main recent routed', ARRAY['nova'], NOW() - interval '3 days');
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES
            (600, 'main', 'routed'),
            (601, 'main', 'received'),
            (602, 'main', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT chat_id, status FROM public.agent_chat_processed WHERE agent = 'main' ORDER BY chat_id;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"600|routed"* ]]
    [[ "$output" == *"601|received"* ]]
    [[ "$output" == *"602|routed"* ]]
}

@test "TC-23-097: cleanup is idempotent on re-run" {
    local coder scribe
    coder="$(_issue23_agent_name coder)"
    scribe="$(_issue23_agent_name scribe)"
    _ISSUE23_ROLES=("$coder" "$scribe")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$coder" "$scribe"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\")
            VALUES (700, 'nova', 'idempotent test', ARRAY['$coder', '$scribe'], NOW() - interval '10 days');
        INSERT INTO public.agent_chat_processed (chat_id, agent, status)
            VALUES (700, '$coder', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_processed WHERE chat_id = 700;"
    [ "$status" -eq 0 ]
    local after_first="$output"

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_processed WHERE chat_id = 700;"
    [ "$status" -eq 0 ]
    [ "$output" = "$after_first" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT agent || '|' || status FROM public.agent_chat_processed WHERE chat_id = 700 ORDER BY agent;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$coder|expired"* ]]
    [[ "$output" == *"$scribe|expired"* ]]
}

@test "TC-23-098: empty-list boundary is clean no-op" {
    local coder
    coder="$(_issue23_agent_name coder)"
    _ISSUE23_ROLES=("$coder")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$coder"

    # Only a recent, unresolved row and an already-terminal old row.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\") VALUES
            (800, 'nova', 'recent', ARRAY['$coder'], NOW() - interval '1 hour'),
            (801, 'nova', 'old responded', ARRAY['$coder'], NOW() - interval '10 days');
        INSERT INTO public.agent_chat_processed (chat_id, agent, status, responded_at) VALUES
            (801, '$coder', 'responded', NOW() - interval '10 days');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT chat_id, status FROM public.agent_chat_processed WHERE chat_id IN (800, 801) ORDER BY chat_id;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"801|responded"* ]]
    [ "$(printf '%s' "$output" | grep -c '^800|')" -eq 0 ]
}

@test "TC-23-099: cleanup is a clearly documented one-time migration with version handshake" {
    local mig
    mig=$(find "$REPO_ROOT/migrations" -maxdepth 1 -name '007-*-cleanup.sql' -o -name '007-*-one-time*.sql' | head -n1)
    [ -n "$mig" ]

    run grep -qi 'one-time' "$mig"
    [ "$status" -eq 0 ]

    run grep -q 'schema_version' "$mig"
    [ "$status" -eq 0 ]

    run grep -q 'VALUES (7,' "$mig"
    [ "$status" -eq 0 ]

    # Data-only / additive: no destructive DDL.
    run grep -qiE 'DROP TABLE|DROP COLUMN|ALTER TYPE.*DROP' "$mig"
    [ "$status" -ne 0 ]
}

@test "TC-23-100: non-identity, non-uniform fixture expires only unresolved >7d" {
    local athena conductor erato
    athena="$(_issue23_agent_name athena)"
    conductor="$(_issue23_agent_name conductor)"
    erato="$(_issue23_agent_name erato)"
    _ISSUE23_ROLES=("$athena" "$conductor" "$erato")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$athena" "$conductor" "$erato"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\") VALUES
            (900, 'nova', '1h received',     ARRAY['$athena'],     NOW() - interval '1 hour'),
            (901, 'nova', '3d routed',       ARRAY['$conductor'],  NOW() - interval '3 days'),
            (902, 'nova', '7d minus 1s routed', ARRAY['$erato'],   NOW() - interval '7 days' + interval '1 second'),
            (903, 'nova', '7d1s received',   ARRAY['$athena'],     NOW() - (interval '7 days' + interval '1 second')),
            (904, 'nova', '40d routed',      ARRAY['$conductor'],  NOW() - interval '40 days'),
            (905, 'nova', '40d responded',   ARRAY['$erato'],      NOW() - interval '40 days'),
            (906, 'nova', '40d expired',     ARRAY['$athena'],     NOW() - interval '40 days'),
            (907, 'nova', '40d failed',      ARRAY['$conductor'],  NOW() - interval '40 days');
        INSERT INTO public.agent_chat_processed (chat_id, agent, status, responded_at) VALUES
            (900, '$athena',    'received',  NULL),
            (901, '$conductor', 'routed',    NULL),
            (902, '$erato',     'routed',    NULL),
            (903, '$athena',    'received',  NULL),
            (904, '$conductor', 'routed',    NULL),
            (905, '$erato',     'responded', NOW() - interval '40 days'),
            (906, '$athena',    'expired',   NOW() - interval '40 days'),
            (907, '$conductor', 'failed',    NULL);
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT chat_id || '|' || agent || '|' || status FROM public.agent_chat_processed WHERE chat_id BETWEEN 900 AND 907 ORDER BY chat_id;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"900|$athena|received"* ]]
    [[ "$output" == *"901|$conductor|routed"* ]]
    [[ "$output" == *"902|$erato|routed"* ]]
    [[ "$output" == *"903|$athena|expired"* ]]
    [[ "$output" == *"904|$conductor|expired"* ]]
    [[ "$output" == *"905|$erato|responded"* ]]
    [[ "$output" == *"906|$athena|expired"* ]]
    [[ "$output" == *"907|$conductor|failed"* ]]
}

@test "TC-23-101: broadcasts untouched amid mixed non-broadcast backlog" {
    local athena conductor
    athena="$(_issue23_agent_name athena)"
    conductor="$(_issue23_agent_name conductor)"
    _ISSUE23_ROLES=("$athena" "$conductor")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$athena" "$conductor"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\") VALUES
            (1000, 'nova', 'broadcast 40d', ARRAY['*'], NOW() - interval '40 days'),
            (1001, 'nova', 'broadcast 10d', ARRAY['*'], NOW() - interval '10 days'),
            (1002, 'nova', 'normal 40d',    ARRAY['$athena'], NOW() - interval '40 days'),
            (1003, 'nova', 'normal 10d',    ARRAY['$conductor'], NOW() - interval '10 days');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _issue23_run_cleanup "$AGENT_CHAT_DB_NAME"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_processed WHERE chat_id IN (1000, 1001);"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT chat_id, agent, status FROM public.agent_chat_processed WHERE chat_id IN (1002, 1003) ORDER BY chat_id;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1002|$athena|expired"* ]]
    [[ "$output" == *"1003|$conductor|expired"* ]]
}
