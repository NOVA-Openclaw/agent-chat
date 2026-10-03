#!/usr/bin/env bats
# PG-layer tests for agent-chat#23 Chunk A (schema + Requirement 6).
#
# Coverage:
#   TC-23-030..032: Requirement 4 schema changes (handled enum value).
#   TC-23-032a:    search_path is pinned on security functions.
#   TC-23-070..089: Requirement 6 (mark_agent_chat_status + reply-to auth).
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
    printf '%s\n' "$1" >> "$BATS_FILE_TMPDIR/issue23_roles.txt"
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

# Run SQL as the given fixture role by impersonating it in a superuser session.
# This avoids creating LOGIN roles and leaking passwords.
_issue23_psql_as() {
    local db_name="$1"
    local role="$2"
    local sql="$3"
    psql -d "$db_name" -At -v ON_ERROR_STOP=1 -c "SET SESSION AUTHORIZATION \"$role\"; $sql"
}

# Count rows the startup digest would surface for an agent.
_issue23_digest_unresolved_count() {
    local db_name="$1"
    local agent="$2"
    psql -d "$db_name" -At -v ON_ERROR_STOP=1 -c "
        SELECT count(*)
        FROM agent_chat ac
        LEFT JOIN agent_chat_processed acp
          ON ac.id = acp.chat_id AND LOWER(acp.agent) = LOWER('$agent')
        WHERE (
            LOWER('$agent') = ANY(SELECT LOWER(unnest(ac.recipients)))
            OR '*' = ANY(ac.recipients)
          )
          AND (
            acp.chat_id IS NULL
            OR acp.status IN ('received', 'routed')
          )
    "
}

# Print the exact paging SQL the digest embeds for an agent.
_issue23_digest_paging_query() {
    local agent="$1"
    local saved_cwd="$(pwd)"
    cd "$REPO_ROOT/plugin" || return 1
    ./node_modules/.bin/tsx tests/helpers/digest-paging-query.ts "$agent"
    local rc=$?
    cd "$saved_cwd" || true
    return $rc
}

setup_file() {
    : > "$BATS_FILE_TMPDIR/issue23_roles.txt"
}

setup() {
    FAKE_HOME="$(mktemp -d)"
    AGENT_CHAT_DB_NAME="agent_chat_issue23_${BATS_TEST_NUMBER}_$$"
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
    if [ -s "$BATS_FILE_TMPDIR/issue23_roles.txt" ]; then
        while IFS= read -r role; do
            [ -n "$role" ] && psql -d postgres -v ON_ERROR_STOP=0 -c "DROP ROLE IF EXISTS \"$role\";" >/dev/null 2>&1 || true
        done < "$BATS_FILE_TMPDIR/issue23_roles.txt"
    fi
}

# ─── Requirement 4 schema cases ─────────────────────────────────────────────

@test "TC-23-030: migration adds 'handled' to agent_chat_status enum" {
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT enum_range(NULL::public.agent_chat_status);"
    [ "$status" -eq 0 ]
    [[ "$output" == *"handled"* ]]
}

@test "TC-23-031: new enum value cannot be used inside the same transaction that adds it" {
    # Demonstrate the PostgreSQL behavior that requires the enum value to be
    # added in its own migration file.
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

@test "TC-23-032a: security functions pin search_path to pg_catalog, public" {
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM pg_proc WHERE proname IN ('send_agent_message','mark_agent_chat_status') AND proconfig @> ARRAY['search_path=pg_catalog, public'];"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

# ─── Requirement 6 cases ────────────────────────────────────────────────────

@test "TC-23-070: mark_agent_chat_status happy path — own row to handled" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES=("$flint" "$quill")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    # Setup parent message and processed row as superuser.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (100, '$quill', 'test', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (100, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[100], 'handled'); SELECT status || '|' || (handled_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 100 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"handled|t"* ]]
}

@test "TC-23-071: mark_agent_chat_status happy path — own row to expired" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES=("$flint" "$quill")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (101, '$quill', 'test', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (101, '$flint', 'received'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[101], 'expired'); SELECT status || '|' || (expired_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 101 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"expired|t"* ]]
}

@test "TC-23-072: mark_agent_chat_status rejects disallowed status values" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES=("$flint")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (102, 'nova', 'test', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (102, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    local status
    for status in responded received routed failed foo ''; do
        run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[102], '${status//\'/\'\'}');"
        [ "$status" -ne 0 ]
    done

    # NULL is a syntax error when inlined, so test it separately.
    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[102], NULL);"
    [ "$status" -ne 0 ]

    # Row must remain untouched.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status FROM public.agent_chat_processed WHERE chat_id = 102 AND agent = '$flint';"
    [ "$output" = "routed" ]
}

@test "TC-23-073: mark_agent_chat_status silently ignores another agent's row" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES=("$flint" "$quill")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (103, 'nova', 'test', ARRAY['$quill']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (103, '$quill', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[103], 'handled');"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status FROM public.agent_chat_processed WHERE chat_id = 103 AND agent = '$quill';"
    [ "$output" = "routed" ]
}

@test "TC-23-074: mark_agent_chat_status rejects NULL chat_ids" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES=("$flint")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(NULL, 'handled');"
    [ "$status" -ne 0 ]
    [[ "$output" == *"p_chat_ids cannot be NULL"* ]]
}

@test "TC-23-075: mark_agent_chat_status accepts empty array cleanly" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES=("$flint")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[]::bigint[], 'handled');"
    [ "$status" -eq 0 ]
}

@test "TC-23-076: mark_agent_chat_status mixed ownership and terminal idempotency" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES=("$flint" "$quill")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

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

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[200,201,202,999999], 'expired');"
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
    _ISSUE23_ROLES=("$flint")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (100, 'nova', 'test', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (100, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    # The row updates only because the function compares agent to session_user
    # (flint), not current_user (postgres inside SECURITY DEFINER).
    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[100], 'handled'); SELECT status FROM public.agent_chat_processed WHERE chat_id = 100 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"handled"* ]]
}

@test "TC-23-078/079: non-superuser scoped, superuser also scoped by session_user" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES=("$flint" "$quill")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (103, 'nova', 'test', ARRAY['$quill']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (103, '$quill', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    # Non-superuser flint targeting quill's row: succeeds silently, no change.
    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[103], 'handled');"
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
    _ISSUE23_ROLES=("$iris")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$iris"

    # 3-arg-equivalent via named/omitted defaults.
    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$iris" "SELECT send_agent_message('$iris', 'plain', ARRAY['nova']);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # Full 5-arg shape.
    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$iris" "SELECT send_agent_message('$iris', 'with ttl', ARRAY['nova'], interval '1 hour', NULL);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "TC-23-081: send_agent_message auto-marks own processed row responded (recipient replies)" {
    local iris flint
    iris="$(_issue23_agent_name iris)"
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES=("$iris" "$flint")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$iris" "$flint"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (400, '$flint', 'hello', ARRAY['$iris']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (400, '$iris', 'routed'), (400, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$iris" "SELECT send_agent_message('$iris', 'here is my answer', ARRAY['$flint'], NULL, 400); SELECT agent || '|' || status || '|' || (responded_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 400 ORDER BY agent;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$flint|routed|f"* ]]
    [[ "$output" == *"$iris|responded|t"* ]]
}

@test "TC-23-082: send_agent_message auto-mark UPSERT inserts row when none exists" {
    local scout iris
    scout="$(_issue23_agent_name scout)"
    iris="$(_issue23_agent_name iris)"
    _ISSUE23_ROLES=("$scout" "$iris")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$scout" "$iris"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (401, '$iris', 'hello', ARRAY['$scout']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$scout" "SELECT send_agent_message('$scout', 'reply text', ARRAY['$iris'], NULL, 401); SELECT agent || '|' || status || '|' || (responded_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 401;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$scout|responded|t"* ]]
}

@test "TC-23-083: send_agent_message rejects nonexistent reply_to before FK" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES=("$flint")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT send_agent_message('$flint', 'reply', ARRAY['nova'], NULL, 999999);"
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
    _ISSUE23_ROLES=("$nova" "$marcie" "$ticker")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$nova" "$marcie" "$ticker"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (402, '$nova', 'hello', ARRAY['$marcie']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (402, '$marcie', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$ticker" "SELECT send_agent_message('$ticker', 'butting in', ARRAY['$nova'], NULL, 402);"
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
    _ISSUE23_ROLES=("$nova" "$gidget")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$nova" "$gidget"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (403, '$nova', 'broadcast', ARRAY['*']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$gidget" "SELECT send_agent_message('$gidget', 'replying to broadcast', ARRAY['$nova'], NULL, 403); SELECT agent || '|' || status || '|' || (responded_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 403;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$gidget|responded|t"* ]]
}

@test "TC-23-089: send_agent_message accepts reply_to by original sender" {
    local coder flint
    coder="$(_issue23_agent_name coder)"
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES=("$coder" "$flint")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$coder" "$flint"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (404, '$coder', 'hello', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (404, '$flint', 'routed'); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$coder" "SELECT send_agent_message('$coder', 'following up', ARRAY['$flint'], NULL, 404); SELECT agent || '|' || status FROM public.agent_chat_processed WHERE chat_id = 404 ORDER BY agent;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$coder|responded"* ]]
    [[ "$output" == *"$flint|routed"* ]]
}

# ─── Requirement 4 dispatch-side cases ──────────────────────────────────────

@test "TC-23-039: orphaned received rows are skipped by fetch path, not re-dispatched" {
    local scout
    scout="$(_issue23_agent_name scout)"
    _ISSUE23_ROLES=("$scout")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$scout"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (390, 'nova', 'stuck message', ARRAY['$scout']); INSERT INTO public.agent_chat_processed (chat_id, agent, status, received_at) VALUES (390, '$scout', 'received', NOW()); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    # The fetch path excludes any row already present in agent_chat_processed,
    # regardless of status. A received-only row is therefore never re-selected
    # and never re-dispatched.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat ac LEFT JOIN agent_chat_processed acp ON ac.id = acp.chat_id AND LOWER(acp.agent) = LOWER('$scout') WHERE ac.id = 390 AND LOWER('$scout') = ANY(SELECT LOWER(unnest(ac.recipients))) AND acp.chat_id IS NULL;"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    # Row is untouched.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status FROM public.agent_chat_processed WHERE chat_id = 390 AND agent = '$scout';"
    [ "$output" = "received" ]

    # The startup digest (Requirement 5) surfaces received-only rows as unresolved.
    run _issue23_digest_unresolved_count "$AGENT_CHAT_DB_NAME" "$scout"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "TC-23-040: multi-agent received rows are isolated per agent" {
    local scout marcie
    scout="$(_issue23_agent_name scout)"
    marcie="$(_issue23_agent_name marcie)"
    _ISSUE23_ROLES=("$scout" "$marcie")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$scout" "$marcie"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (400, 'nova', 'group message', ARRAY['$scout','$marcie']); INSERT INTO public.agent_chat_processed (chat_id, agent, status, received_at) VALUES (400, '$scout', 'received', NOW()), (400, '$marcie', 'received', NOW()); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    for agent in "$scout" "$marcie"; do
        run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat ac LEFT JOIN agent_chat_processed acp ON ac.id = acp.chat_id AND LOWER(acp.agent) = LOWER('$agent') WHERE ac.id = 400 AND LOWER('$agent') = ANY(SELECT LOWER(unnest(ac.recipients))) AND acp.chat_id IS NULL;"
        [ "$status" -eq 0 ]
        [ "$output" = "0" ]
    done

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT agent, status FROM public.agent_chat_processed WHERE chat_id = 400 ORDER BY agent;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$scout|received"* ]]
    [[ "$output" == *"$marcie|received"* ]]

    # Digest isolation: each agent sees only its own received row.
    run _issue23_digest_unresolved_count "$AGENT_CHAT_DB_NAME" "$scout"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run _issue23_digest_unresolved_count "$AGENT_CHAT_DB_NAME" "$marcie"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

# ─── Requirement 5 startup digest PG-layer cases ────────────────────────────

@test "TC-23-061: paging query self-consistency" {
    local flint
    flint="$(_issue23_agent_name flint)"
    _ISSUE23_ROLES=("$flint")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint"

    # Seed 25 unresolved messages with stable, oldest-first timestamps.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients, \"timestamp\")
            SELECT g, 'nova', 'msg ' || g, ARRAY['$flint'], '2026-09-01T00:00:00Z'::timestamptz + (g || ' seconds')::interval
            FROM generate_series(1, 25) AS g;
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    # Extract the literal paging SQL embedded by the digest.
    run _issue23_digest_paging_query "$flint"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    local paging_sql="$output"

    # The query must return exactly the 5 rows beyond the 20-message cap.
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "$paging_sql"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^')" -eq 5 ]

    # And those 5 rows must be ids 21-25 (the newest beyond the cap).
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT string_agg(id::text, ',' ORDER BY id) FROM (${paging_sql%;}) q;"
    [ "$status" -eq 0 ]
    [ "$output" = "21,22,23,24,25" ]
}

@test "TC-23-041: responded rows are never re-selected for dispatch" {
    local newhart
    newhart="$(_issue23_agent_name newhart)"
    _ISSUE23_ROLES=("$newhart")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$newhart"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (410, 'nova', 'already answered', ARRAY['$newhart']); INSERT INTO public.agent_chat_processed (chat_id, agent, status, responded_at) VALUES (410, '$newhart', 'responded', NOW()); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM agent_chat ac LEFT JOIN agent_chat_processed acp ON ac.id = acp.chat_id AND LOWER(acp.agent) = LOWER('$newhart') WHERE ac.id = 410 AND LOWER('$newhart') = ANY(SELECT LOWER(unnest(ac.recipients))) AND acp.chat_id IS NULL;"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ─── Requirement 8 duplicate-dispatch race cases ────────────────────────────

@test "TC-23-110: pre-fix UPSERT lets both callers proceed (race baseline)" {
    local hermes
    hermes="$(_issue23_agent_name hermes)"
    _ISSUE23_ROLES=("$hermes")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$hermes"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (600, 'nova', 'race message', ARRAY['$hermes']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    # Pre-fix SQL shape: ON CONFLICT DO UPDATE. Both calls succeed.
    local upsert_sql="INSERT INTO public.agent_chat_processed (chat_id, agent, status, received_at) VALUES (600, LOWER('$hermes'), 'received', NOW()) ON CONFLICT (chat_id, agent) DO UPDATE SET received_at = COALESCE(agent_chat_processed.received_at, NOW())"

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "$upsert_sql;"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "$upsert_sql;"
    [ "$status" -eq 0 ]
}

@test "TC-23-111: fixed claim pattern returns exactly one winner" {
    local hermes
    hermes="$(_issue23_agent_name hermes)"
    _ISSUE23_ROLES=("$hermes")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$hermes"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (601, 'nova', 'race message', ARRAY['$hermes']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    local claim_sql="INSERT INTO public.agent_chat_processed (chat_id, agent, status, received_at) VALUES (601, LOWER('$hermes'), 'received', NOW()) ON CONFLICT (chat_id, agent) DO NOTHING RETURNING chat_id, agent, status"

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "$claim_sql;"
    [ "$status" -eq 0 ]
    # First caller wins: output contains the returned row (e.g. "601|hermes|received").
    [[ "$output" == *"|received"* ]]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "$claim_sql;"
    [ "$status" -eq 0 ]
    # Second caller loses: only the command tag (INSERT 0 0) is printed, no row
    # data with a pipe separator.
    [[ "$output" != *"|"* ]]
}

# ─── Requirement 6 follow-up: Option A (mark_agent_chat_status creates row) ─

@test "TC-23-090a: named recipient with no processed row gets one created" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES=("$flint" "$quill")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (700, '$quill', 'to flint', ARRAY['$flint']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[700], 'handled'); SELECT status || '|' || (handled_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 700 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"handled|t"* ]]
}

@test "TC-23-090b: broadcast with no processed row gets one created" {
    local flint nova
    flint="$(_issue23_agent_name flint)"
    nova="$(_issue23_agent_name nova)"
    _ISSUE23_ROLES=("$flint" "$nova")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$nova"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (701, '$nova', 'broadcast', ARRAY['*']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[701], 'expired'); SELECT status || '|' || (expired_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 701 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"expired|t"* ]]
}

@test "TC-23-090c: non-recipient non-broadcast message is silently ignored" {
    local flint quill ticker
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    ticker="$(_issue23_agent_name ticker)"
    _ISSUE23_ROLES=("$flint" "$quill" "$ticker")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill" "$ticker"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (702, '$quill', 'to flint', ARRAY['$flint']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$ticker" "SELECT mark_agent_chat_status(ARRAY[702], 'handled');"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_processed WHERE chat_id = 702;"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "TC-23-090d: existing terminal row is unchanged" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES=("$flint" "$quill")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (703, '$quill', 'to flint', ARRAY['$flint']); INSERT INTO public.agent_chat_processed (chat_id, agent, status, handled_at) VALUES (703, '$flint', 'handled', NOW()); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[703], 'expired'); SELECT status || '|' || (expired_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 703 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"handled|f"* ]]
}

@test "TC-23-090e: mixed array applies only to authorized, non-terminal rows" {
    local flint quill ticker
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    ticker="$(_issue23_agent_name ticker)"
    _ISSUE23_ROLES=("$flint" "$quill" "$ticker")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill" "$ticker"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES
            (704, '$quill', 'to flint', ARRAY['$flint']),
            (705, '$quill', 'to ticker', ARRAY['$ticker']),
            (706, '$quill', 'broadcast', ARRAY['*']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status, handled_at) VALUES
            (706, '$flint', 'handled', NOW());
        SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[704,705,706,999999], 'expired');"
    [ "$status" -eq 0 ]

    # 704: authorized, no row -> created expired
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status || '|' || (expired_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 704 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"expired|t"* ]]

    # 705: not authorized -> no row for flint
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_processed WHERE chat_id = 705 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    # 706: authorized broadcast but already terminal -> unchanged
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT status || '|' || (expired_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 706 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"handled|f"* ]]

    # 999999: nonexistent -> no row
    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_processed WHERE chat_id = 999999;"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "TC-23-090f: running twice on no-row message is idempotent" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES=("$flint" "$quill")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (707, '$quill', 'to flint', ARRAY['$flint']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[707], 'handled');"
    [ "$status" -eq 0 ]

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[707], 'handled');"
    [ "$status" -eq 0 ]

    run psql -d "$AGENT_CHAT_DB_NAME" -At -c "SELECT count(*) FROM public.agent_chat_processed WHERE chat_id = 707 AND agent = '$flint';"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "TC-23-090g: marking removes a never-picked-up message from fetchUnresolvedMessages" {
    local flint quill
    flint="$(_issue23_agent_name flint)"
    quill="$(_issue23_agent_name quill)"
    _ISSUE23_ROLES=("$flint" "$quill")
    _issue23_setup_roles "$AGENT_CHAT_DB_NAME" "$flint" "$quill"

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use; INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (708, '$quill', 'to flint', ARRAY['$flint']); SELECT setval('public.agent_chat_id_seq', 1000);" >/dev/null

    run _issue23_digest_unresolved_count "$AGENT_CHAT_DB_NAME" "$flint"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run _issue23_psql_as "$AGENT_CHAT_DB_NAME" "$flint" "SELECT mark_agent_chat_status(ARRAY[708], 'handled');"
    [ "$status" -eq 0 ]

    run _issue23_digest_unresolved_count "$AGENT_CHAT_DB_NAME" "$flint"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}
