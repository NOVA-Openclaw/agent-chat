#!/usr/bin/env bats
# PG-layer tests for agent-chat#23 Chunk A (schema + Requirement 6).
#
# Coverage:
#   TC-23-030..032: Requirement 4 schema changes (handled enum value).
#   TC-23-070..089: Requirement 6 (mark_agent_chat_status + reply-to auth).
#
# Every test runs against its own disposable scratch database. The live
# agent_chat database is never touched.

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Agent names used as fixtures (suffix with test number + pid to avoid leaks).
_issue23_agent_name() {
    printf '%s_%s_%s' "$1" "$BATS_TEST_NUMBER" "$$"
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
        psql -d postgres -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS \"$role\"; CREATE ROLE \"$role\" LOGIN PASSWORD 'issue23pw';" >/dev/null
        psql -d "$db_name" -v ON_ERROR_STOP=1 -c "GRANT INSERT, SELECT ON public.agent_chat TO \"$role\"; GRANT INSERT, SELECT, UPDATE ON public.agent_chat_processed TO \"$role\"; GRANT SELECT ON public.agent_chat_error_templates, public.agent_chat_breaker_state, public.agent_chat_suppressed_log TO \"$role\";" >/dev/null
    done
}

_issue23_pgpass() {
    local pgpass="$1"
    local db_name="$2"
    shift 2
    (umask 077; rm -f "$pgpass")
    local role
    for role in "$@"; do
        printf 'localhost:5432:%s:%s:issue23pw\n' "$db_name" "$role" >> "$pgpass"
    done
    chmod 600 "$pgpass"
}

_issue23_psql_as() {
    local pgpass="$1"
    local db_name="$2"
    local role="$3"
    shift 3
    env PGPASSFILE="$pgpass" psql -h localhost -U "$role" -d "$db_name" -v ON_ERROR_STOP=1 "$@"
}

setup() {
    FAKE_HOME="$(mktemp -d)"
    AGENT_CHAT_DB_NAME="agent_chat_issue23_${BATS_TEST_NUMBER}_$$"
    PGPASS_FILE="$FAKE_HOME/.pgpass_issue23"
    _issue23_setup_db "$AGENT_CHAT_DB_NAME"
}

teardown() {
    if [ -n "${AGENT_CHAT_DB_NAME:-}" ]; then
        psql -d postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"$AGENT_CHAT_DB_NAME\";" >/dev/null 2>&1 || true
    fi
    for role in "${_ISSUE23_ROLES:-}"; do
        [ -n "$role" ] && psql -d postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$role\";" >/dev/null 2>&1 || true
    done
    rm -rf "$FAKE_HOME"
}

# ─── Requirement 4 schema cases ─────────────────────────────────────────────

@test "TC-23-030: migration adds 'handled' to agent_chat_status enum" {
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT enum_range(NULL::public.agent_chat_status);"
    [ "$status" -eq 0 ]
    [[ "$output" == *"handled"* ]]
}

@test "TC-23-031: new enum value cannot be used inside the same transaction that adds it" {
    # Demonstrate the PostgreSQL behavior that requires the enum value to be
    # added in its own migration file: in a fresh DB, create a minimal enum
    # and table, then try to add and use the value in one transaction.
    local baseline_db="agent_chat_issue23_031_$$"
    psql -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$baseline_db\";" >/dev/null 2>&1
    createdb "$baseline_db" >/dev/null
    psql -d "$baseline_db" -v ON_ERROR_STOP=1 -c "CREATE TYPE public.test_status AS ENUM ('received','routed','responded','failed','expired','skipped'); CREATE TABLE public.test_processed (id int PRIMARY KEY, status public.test_status);" >/dev/null

    run psql -d "$baseline_db" -v ON_ERROR_STOP=0 -c "BEGIN; ALTER TYPE public.test_status ADD VALUE 'handled'; INSERT INTO public.test_processed (id, status) VALUES (1, 'handled'); COMMIT;"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe use of new value"* ]]

    psql -d postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"$baseline_db\";" >/dev/null 2>&1 || true
}

@test "TC-23-032: exactly one migration file adds the 'handled' enum value" {
    run grep -Rl "ADD VALUE.*handled" "$REPO_ROOT/migrations/"
    [ "$status" -eq 0 ]
    local count
    count=$(printf '%s\n' "$output" | wc -l)
    [ "$count" -eq 1 ]
    [[ "$output" == *"006-agent-chat-23-handled-status-and-reply-auth.sql"* ]]
}

# ─── Requirement 6 cases ────────────────────────────────────────────────────

@test "TC-23-070: mark_agent_chat_status happy path — own row to handled" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES="$flint $quill"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    # Setup parent message and processed row as superuser.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (100, '$quill', 'test', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (100, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(ARRAY[100], 'handled'); SELECT status || '|' || (handled_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 100 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"handled|t"* ]]
}

@test "TC-23-071: mark_agent_chat_status happy path — own row to expired" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES="$flint $quill"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (101, '$quill', 'test', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (101, '$flint', 'received'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(ARRAY[101], 'expired'); SELECT status || '|' || (expired_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 101 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"expired|t"* ]]
}

@test "TC-23-072: mark_agent_chat_status rejects disallowed status values" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES="$flint"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (102, 'nova', 'test', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (102, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    local status
    for status in responded received routed failed foo ''; do
        run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(ARRAY[102], '${status//\'/\'\'}');"
        [ "$status" -ne 0 ]
    done

    # NULL is a syntax error when inlined, so test it separately.
    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(ARRAY[102], NULL);"
    [ "$status" -ne 0 ]

    # Row must remain untouched.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status FROM public.agent_chat_processed WHERE chat_id = 102 AND agent = '$flint';"
    [ "$output" = "routed" ]
}

@test "TC-23-073: mark_agent_chat_status silently ignores another agent's row" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES="$flint $quill"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (103, 'nova', 'test', ARRAY['$quill']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (103, '$quill', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(ARRAY[103], 'handled');"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status FROM public.agent_chat_processed WHERE chat_id = 103 AND agent = '$quill';"
    [ "$output" = "routed" ]
}

@test "TC-23-074: mark_agent_chat_status rejects NULL chat_ids" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES="$flint"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint"

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(NULL, 'handled');"
    [ "$status" -ne 0 ]
    [[ "$output" == *"p_chat_ids cannot be NULL"* ]]
}

@test "TC-23-075: mark_agent_chat_status accepts empty array cleanly" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES="$flint"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint"

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(ARRAY[]::bigint[], 'handled');"
    [ "$status" -eq 0 ]
}

@test "TC-23-076: mark_agent_chat_status mixed ownership and terminal idempotency" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES="$flint $quill"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES
            (200, 'nova', 'test', ARRAY['$flint']),
            (201, 'nova', 'test', ARRAY['$quill']),
            (202, 'nova', 'test', ARRAY['$flint']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES
            (200, '$flint', 'routed'),
            (201, '$quill', 'routed'),
            (202, '$flint', 'handled');
        SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(ARRAY[200,201,202,999999], 'expired');"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT chat_id, status FROM public.agent_chat_processed WHERE chat_id IN (200,201,202) ORDER BY chat_id;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"200|expired"* ]]
    [[ "$output" == *"201|routed"* ]]
    [[ "$output" == *"202|handled"* ]]
}

@test "TC-23-077: mark_agent_chat_status scopes to session_user, not current_user" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES="$flint"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (100, 'nova', 'test', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (100, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    # The row updates only because the function compares agent to session_user
    # (flint), not current_user (postgres inside SECURITY DEFINER).
    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(ARRAY[100], 'handled'); SELECT status FROM public.agent_chat_processed WHERE chat_id = 100 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"handled"* ]]
}

@test "TC-23-078/079: non-superuser scoped, superuser also scoped by session_user" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES="$flint $quill"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (103, 'nova', 'test', ARRAY['$quill']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (103, '$quill', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    # Non-superuser flint targeting quill's row: succeeds silently, no change.
    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT mark_agent_chat_status(ARRAY[103], 'handled');"
    [ "$status" -eq 0 ]

    # Superuser (current OS user, nova) targeting quill's row: also scoped to
    # session_user, so quill's row remains unchanged.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT mark_agent_chat_status(ARRAY[103], 'handled'); SELECT status FROM public.agent_chat_processed WHERE chat_id = 103 AND agent = '$quill';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"routed"* ]]
}

@test "TC-23-080: send_agent_message existing caller shapes remain unchanged" {
    local iris
    iris="$(_issue23_agent_name iris)"
    _ISSUE23_ROLES="$iris"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$iris"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$iris"

    # 3-arg-equivalent via named/omitted defaults.
    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$iris" -At -c "SELECT send_agent_message('$iris', 'plain', ARRAY['nova']);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # Full 5-arg shape.
    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$iris" -At -c "SELECT send_agent_message('$iris', 'with ttl', ARRAY['nova'], interval '1 hour', NULL);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "TC-23-081: send_agent_message auto-marks own processed row responded (recipient replies)" {
    local iris flint
    iris="$(_issue23_agent_name iris)"
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES="$iris $flint"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$iris" "$flint"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$iris" "$flint"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (400, '$flint', 'hello', ARRAY['$iris']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (400, '$iris', 'routed'), (400, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$iris" -At -c "SELECT send_agent_message('$iris', 'here is my answer', ARRAY['$flint'], NULL, 400); SELECT agent || '|' || status || '|' || (responded_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 400 ORDER BY agent;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$flint|routed|f"* ]]
    [[ "$output" == *"$iris|responded|t"* ]]
}

@test "TC-23-082: send_agent_message auto-mark UPSERT inserts row when none exists" {
    local scout iris
    scout="$(_issue23_agent_name scout)"
    iris="$(_issue23_agent_name iris)"
    _ISSUE23_ROLES="$scout $iris"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$scout" "$iris"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$scout" "$iris"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (401, '$iris', 'hello', ARRAY['$scout']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$scout" -At -c "SELECT send_agent_message('$scout', 'reply text', ARRAY['$iris'], NULL, 401); SELECT agent || '|' || status || '|' || (responded_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 401;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$scout|responded|t"* ]]
}

@test "TC-23-083: send_agent_message rejects nonexistent reply_to before FK" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES="$flint"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint"

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$flint" -At -c "SELECT send_agent_message('$flint', 'reply', ARRAY['nova'], NULL, 999999);"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reply_to"* ]]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT COUNT(*) FROM public.agent_chat WHERE reply_to = 999999;"
    [ "$output" = "0" ]
}

@test "TC-23-084: send_agent_message rejects third-party reply_to" {
    local nova marcie ticker
    nova="$(_issue23_agent_name nova)"
    marcie="$(_issue23_agent_name marcie)"
    ticker="$(_issue23_agent_name ticker)"
    _ISSUE23_ROLES="$nova $marcie $ticker"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$nova" "$marcie" "$ticker"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$ticker"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (402, '$nova', 'hello', ARRAY['$marcie']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (402, '$marcie', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$ticker" -At -c "SELECT send_agent_message('$ticker', 'butting in', ARRAY['$nova'], NULL, 402);"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reply_to"* ]]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT COUNT(*) FROM public.agent_chat WHERE sender = '$ticker';"
    [ "$output" = "0" ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status FROM public.agent_chat_processed WHERE chat_id = 402 AND agent = '$marcie';"
    [ "$output" = "routed" ]
}

@test "TC-23-085: migration 006 is additive only (no DROP COLUMN/TABLE/ALTER TYPE)" {
    run grep -Ei "DROP (COLUMN|TABLE)|ALTER (COLUMN .* TYPE)" "$REPO_ROOT/migrations/006-agent-chat-23-handled-status-and-reply-auth.sql"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "TC-23-086: installer derives new expected schema_version and reports up to date" {
    run env AGENT_CHAT_DB_NAME="agent_chat_issue23_086_$$" "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Applied 006-agent-chat-23-handled-status-and-reply-auth.sql"* ]]

    run env AGENT_CHAT_DB_NAME="agent_chat_issue23_086_$$" "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]

    psql -d postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"agent_chat_issue23_086_$$\";" >/dev/null 2>&1 || true
}

@test "TC-23-087: send_agent_message has exactly one overload after migration" {
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM pg_proc WHERE proname = 'send_agent_message';"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "TC-23-088: send_agent_message accepts reply_to a broadcast" {
    local nova gidget
    nova="$(_issue23_agent_name nova)"
    gidget="$(_issue23_agent_name gidget)"
    _ISSUE23_ROLES="$nova $gidget"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$nova" "$gidget"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$gidget"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (403, '$nova', 'broadcast', ARRAY['*']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$gidget" -At -c "SELECT send_agent_message('$gidget', 'replying to broadcast', ARRAY['$nova'], NULL, 403); SELECT agent || '|' || status || '|' || (responded_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 403;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$gidget|responded|t"* ]]
}

@test "TC-23-089: send_agent_message accepts reply_to by original sender" {
    local coder flint
    coder="$(_issue23_agent_name coder)"
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES="$coder $flint"
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$coder" "$flint"
    _issue23_pgpass "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$coder" "$flint"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (404, '$coder', 'hello', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (404, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$PGPASS_FILE" "$AGENT_CHAT_DB_NAME" "$coder" -At -c "SELECT send_agent_message('$coder', 'following up', ARRAY['$flint'], NULL, 404); SELECT agent || '|' || status FROM public.agent_chat_processed WHERE chat_id = 404 ORDER BY agent;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$coder|responded"* ]]
    [[ "$output" == *"$flint|routed"* ]]
}
