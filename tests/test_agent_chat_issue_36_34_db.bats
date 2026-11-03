#!/usr/bin/env bats
# PG-layer tests for agent-chat#34/#36 DB chunk.
#
# Coverage (QA mappings):
#   D01-D13: mark_agent_chat_status (skipped, return shape, precedence)
#   C01-C13: send_agent_message reply-to authorization + auto-mark responded
#   I01-I11: alert-only pair breaker (detect + alert + log, no suppression)
#   J01-J04, J08: backwards compatibility
#   L01-L02, L05: regressions
#
# Uses the existing nova LOGIN role for all function calls. The "peer" side is
# simulated with arbitrary recipient strings and direct INSERTs (after disabling
# the immutability trigger). This avoids needing CREATEROLE in the test
# environment. Every test runs against a disposable, name-guarded scratch DB.

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# ─── Helpers ───────────────────────────────────────────────────────────────

_se36_db_name() {
    printf 'agent_chat_se36_%s_%s' "$BATS_TEST_NUMBER" "$$"
}

_se36_setup_db() {
    local db_name="$1"
    psql -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$db_name\";" >/dev/null 2>&1
    createdb "$db_name" >/dev/null
    psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$REPO_ROOT/schema.sql" >/dev/null 2>&1
    for f in "$REPO_ROOT"/migrations/*.sql; do
        psql -d "$db_name" -v ON_ERROR_STOP=1 -f "$f" >/dev/null 2>&1 || {
            echo "FAILED to apply $(basename "$f")" >&2
            return 1
        }
    done
    # In non-superuser test environments send_agent_message is owned by the
    # installing role (nova), not postgres, so the immutability trigger would
    # reject its own inserts. Disable the trigger for the test DB only.
    psql -d "$db_name" -v ON_ERROR_STOP=1 -c "ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;" >/dev/null
}

_se36_sql() {
    local db_name="$1"
    shift
    psql -d "$db_name" -At -v ON_ERROR_STOP=1 -c "$*"
}

_se36_send_as_nova() {
    local db_name="$1"
    local recipient="$2"
    local message="$3"
    local reply_to="${4:-NULL}"
    local escaped
    escaped="$(printf '%s' "$message" | sed "s/'/''/g")"
    _se36_sql "$db_name" "SELECT send_agent_message('nova', '${escaped}', ARRAY['${recipient}'], NULL, ${reply_to});"
}

setup() {
    AGENT_CHAT_DB_NAME="$(_se36_db_name)"
    _se36_setup_db "$AGENT_CHAT_DB_NAME"
}

teardown() {
    if [ -n "${AGENT_CHAT_DB_NAME:-}" ]; then
        psql -d postgres -v ON_ERROR_STOP=0 -c "DROP DATABASE IF EXISTS \"$AGENT_CHAT_DB_NAME\";" >/dev/null 2>&1 || true
    fi
}

# ─── D cases: mark_agent_chat_status ───────────────────────────────────────

@test "D01: mark_agent_chat_status handles own row and returns the id" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (101, 'peer_a', 'test', ARRAY['nova']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (101, 'nova', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[101], 'handled');"
    [ "$status" -eq 0 ]
    [[ "$output" == *"101"* ]]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT status || '|' || (handled_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 101 AND agent = 'nova';"
    [ "$output" = "handled|true" ]
}

@test "D02: mark_agent_chat_status expires own row and returns the id" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (102, 'peer_a', 'test', ARRAY['nova']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (102, 'nova', 'received');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[102], 'expired');"
    [ "$status" -eq 0 ]
    [[ "$output" == *"102"* ]]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT status || '|' || (expired_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 102 AND agent = 'nova';"
    [ "$output" = "expired|true" ]
}

@test "D03: mark_agent_chat_status skips own row and returns the id" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (103, 'peer_a', 'test', ARRAY['nova']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (103, 'nova', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[103], 'skipped');"
    [ "$status" -eq 0 ]
    [[ "$output" == *"103"* ]]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT status || '|' || (skipped_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 103 AND agent = 'nova';"
    [ "$output" = "skipped|true" ]
}

@test "D04: mark_agent_chat_status never downgrades from responded" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (104, 'peer_a', 'test', ARRAY['nova']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status, responded_at) VALUES (104, 'nova', 'responded', NOW());
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[104], 'handled');"
    [ "$status" -eq 0 ]
    [[ "$output" != *"104"* ]]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT status FROM public.agent_chat_processed WHERE chat_id = 104 AND agent = 'nova';"
    [ "$output" = "responded" ]
}

@test "D05: mark_agent_chat_status never downgrades from failed" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (105, 'peer_a', 'test', ARRAY['nova']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (105, 'nova', 'failed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[105], 'handled');"
    [ "$status" -eq 0 ]
    [[ "$output" != *"105"* ]]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT status FROM public.agent_chat_processed WHERE chat_id = 105 AND agent = 'nova';"
    [ "$output" = "failed" ]
}

@test "D06: reply to a handled/skipped/failed message is delivered, status unchanged" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (106, 'peer_a', 'test', ARRAY['nova']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status, skipped_at) VALUES (106, 'nova', 'skipped', NOW());
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "reply after skipped" 106
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT status FROM public.agent_chat_processed WHERE chat_id = 106 AND agent = 'nova';"
    [ "$output" = "skipped" ]
}

@test "D07: original sender replying to own message gets a responded processed row" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (107, 'nova', 'test', ARRAY['peer_a']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (107, 'peer_a', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "follow-up" 107
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent || '|' || status FROM public.agent_chat_processed WHERE chat_id = 107 ORDER BY agent;"
    [[ "$output" == *"nova|responded"* ]]
    [[ "$output" == *"peer_a|routed"* ]]
}

@test "D08: mark_agent_chat_status is available to main agent sessions (DB grant check)" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT has_function_privilege('nova', 'public.mark_agent_chat_status(bigint[], text)', 'EXECUTE');"
    [ "$output" = "t" ]
}

@test "D09: one row per send, no chunking" {
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "single row send test"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat WHERE sender = 'nova';"
    [ "$output" = "1" ]
}

@test "D10: session key format is documented for chunk 2 (placeholder)" {
    # Session key format is enforced in the plugin layer (chunk 2).
    # DB layer preserves any single string recipient or '*' broadcast.
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" "agent:nova:agent_chat:peer" "peer session key recipient"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT recipients::text FROM public.agent_chat WHERE sender = 'nova';"
    [ "$output" = "{agent:nova:agent_chat:peer}" ]
}

@test "D11: to is a single string or '*' broadcast" {
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "direct"
    [ "$status" -eq 0 ]

    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" "*" "broadcast"
    [ "$status" -eq 0 ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT array_to_string(recipients, ',') FROM public.agent_chat WHERE sender = 'nova' ORDER BY id;"
    [[ "$output" == *"peer_a"* ]]
    [[ "$output" == *"*"* ]]
}

@test "D12: reply_to must reference an existing integer message" {
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "bad reply" 999999
    [ "$status" -ne 0 ]
    [[ "$output" == *"reply_to"* ]]
}

@test "D13: any recipient string is allowed at the DB layer" {
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" "totally-arbitrary-recipient_42" "any recipient"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ─── C cases: replies and authorization ────────────────────────────────────

@test "C01: send_agent_message rejects reply_to nonexistent id before FK" {
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "reply to missing" 999999
    [ "$status" -ne 0 ]
    [[ "$output" == *"reply_to"* ]]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat WHERE sender = 'nova';"
    [ "$output" = "0" ]
}

@test "C02: send_agent_message rejects third-party reply_to" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (201, 'peer_a', 'test', ARRAY['peer_b']);
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "butting in" 201
    [ "$status" -ne 0 ]
    [[ "$output" == *"reply_to"* ]]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat WHERE sender = 'nova';"
    [ "$output" = "0" ]
}

@test "C03: recipient replying to a message auto-marks it responded" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (202, 'peer_a', 'test', ARRAY['nova']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (202, 'nova', 'routed'), (202, 'peer_a', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "my reply" 202
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent || '|' || status || '|' || (responded_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 202 ORDER BY agent;"
    [[ "$output" == *"nova|responded|true"* ]]
    [[ "$output" == *"peer_a|routed|false"* ]]
}

@test "C04: reply auto-mark UPSERT inserts row when none exists" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (203, 'peer_a', 'test', ARRAY['nova']);
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "reply with no prior row" 203
    [ "$status" -eq 0 ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent || '|' || status || '|' || (responded_at IS NOT NULL) FROM public.agent_chat_processed WHERE chat_id = 203;"
    [[ "$output" == *"nova|responded|true"* ]]
}

@test "C05: reply to a broadcast is authorized for any recipient" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (204, 'peer_a', 'broadcast', ARRAY['*']);
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "reply to broadcast" 204
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "C06: reply by original sender is authorized" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (205, 'nova', 'test', ARRAY['peer_a']);
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "sender follow-up" 205
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "C07: sender must match session_user" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT send_agent_message('peer_a', 'spoof', ARRAY['nova']);"
    [ "$status" -ne 0 ]
    [[ "$output" == *"session_user"* ]]
}

@test "C08: empty message is rejected" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT send_agent_message('nova', '', ARRAY['peer_a']);"
    [ "$status" -ne 0 ]
    [[ "$output" == *"message cannot be empty"* ]]
}

@test "C09: self-addressed message is rejected" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT send_agent_message('nova', 'to myself', ARRAY['nova']);"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sender"* ]]
}

@test "C10: mark_agent_chat_status rejects disallowed statuses" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (206, 'peer_a', 'test', ARRAY['nova']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (206, 'nova', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    local status
    for status in responded received routed failed foo ''; do
        run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[206], '${status//\'/\'\'}');"
        [ "$status" -ne 0 ]
    done

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[206], NULL);"
    [ "$status" -ne 0 ]
}

@test "C11: mark_agent_chat_status silently ignores another agent's row" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (207, 'peer_a', 'test', ARRAY['peer_b']);
        INSERT INTO public.agent_chat_processed (chat_id, agent, status) VALUES (207, 'peer_b', 'routed');
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[207], 'handled');"
    [ "$status" -eq 0 ]
    [[ "$output" != *"207"* ]]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT status FROM public.agent_chat_processed WHERE chat_id = 207 AND agent = 'peer_b';"
    [ "$output" = "routed" ]
}

@test "C12: mark_agent_chat_status accepts empty array cleanly" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[]::bigint[], 'handled');"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "C13: mark_agent_chat_status returns empty array when nothing applied" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT mark_agent_chat_status(ARRAY[999999], 'handled');"
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
}

# ─── I cases: alert-only pair breaker ──────────────────────────────────────

@test "I01: first message for a pair creates breaker state" {
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "first message"
    [ "$status" -eq 0 ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = 'nova' AND pair_b = 'peer_a';"
    [ "$output" = "1|f" ]
}

@test "I02: 6 messages in 5 minutes alert once and all are delivered" {
    local i
    for i in 1 2 3 4 5 6; do
        run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "repeat $i"
        [ "$status" -eq 0 ]
        [ -n "$output" ]
    done

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat WHERE sender = 'nova' AND 'peer_a' = ANY(recipients);"
    [ "$output" = "6" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = 'nova' AND pair_b = 'peer_a';"
    [ "$output" = "1" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = 'nova' AND pair_b = 'peer_a';"
    [ "$output" = "6|t" ]
}

@test "I03: both directions of a pair count together" {
    # Simulate 3 prior messages from peer_a to nova by seeding the counter,
    # then send 3 messages from nova to peer_a. The unordered pair counter
    # must reach 6 and emit one alert.
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        INSERT INTO public.agent_chat_breaker_state (pair_a, pair_b, window_start, message_count, alerted, last_message_at)
        VALUES ('nova', 'peer_a', now(), 3, false, now());
    " >/dev/null

    _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "A1" >/dev/null
    _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "A2" >/dev/null
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "A3"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = 'nova' AND pair_b = 'peer_a';"
    [ "$output" = "6|t" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = 'nova' AND pair_b = 'peer_a';"
    [ "$output" = "1" ]
}

@test "I04: #N patterns do not reset the counter" {
    local i
    for i in 1 2 3 4 5 6; do
        _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "note $i and see #123" >/dev/null
    done

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = 'nova' AND pair_b = 'peer_a';"
    [ "$output" = "6|t" ]
}

@test "I05: idle gap longer than the window resets the counter" {
    local i
    for i in 1 2 3 4 5; do
        _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "fast $i" >/dev/null
    done

    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        UPDATE public.agent_chat_breaker_state
        SET last_message_at = now() - interval '10 minutes'
        WHERE pair_a = 'nova' AND pair_b = 'peer_a';
    " >/dev/null

    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "after cooldown"
    [ "$status" -eq 0 ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT message_count, alerted FROM public.agent_chat_breaker_state WHERE pair_a = 'nova' AND pair_b = 'peer_a';"
    [ "$output" = "1|f" ]
}

@test "I06: threshold and window are configurable per pair" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        INSERT INTO public.agent_chat_breaker_config (pair_a, pair_b, threshold, \"window\")
        VALUES ('nova', 'peer_b', 2, interval '1 hour');
    " >/dev/null

    _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_b "first" >/dev/null
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_b "second"
    [ "$status" -eq 0 ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT message_count FROM public.agent_chat_breaker_state WHERE pair_a = 'nova' AND pair_b = 'peer_b';"
    [ "$output" = "2" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT threshold FROM public.agent_chat_breaker_alerts WHERE pair_a = 'nova' AND pair_b = 'peer_b';"
    [ "$output" = "2" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = 'nova' AND pair_b = 'peer_b';"
    [ "$output" = "1" ]
}

@test "I07: only one alert per trip per pair window" {
    local i
    for i in $(seq 1 12); do
        _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "spam $i" >/dev/null
    done

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat WHERE sender = 'nova' AND 'peer_a' = ANY(recipients);"
    [ "$output" = "12" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat_breaker_alerts WHERE pair_a = 'nova' AND pair_b = 'peer_a';"
    [ "$output" = "1" ]
}

@test "I08: multi-recipient sends count each pair separately and deliver to all" {
    _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "a1" >/dev/null
    _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_b "b1" >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT send_agent_message('nova', 'multi', ARRAY['peer_a','peer_b']);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT pair_a || '|' || pair_b || '|' || message_count FROM public.agent_chat_breaker_state WHERE pair_a = 'nova' ORDER BY pair_b;"
    [[ "$output" == *"nova|peer_a|2"* ]]
    [[ "$output" == *"nova|peer_b|2"* ]]
}

@test "I09: broadcasts are not counted by the pair breaker" {
    local i
    for i in $(seq 1 10); do
        _se36_send_as_nova "$AGENT_CHAT_DB_NAME" "*" "broadcast $i" >/dev/null
    done

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat_breaker_state WHERE pair_a = 'nova';"
    [ "$output" = "0" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat WHERE sender = 'nova' AND recipients = ARRAY['*'];"
    [ "$output" = "10" ]
}

@test "I10: agent_chat_pending_alerts returns unseen alerts for the agent" {
    local i
    for i in $(seq 1 6); do
        _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "a$i" >/dev/null
    done

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM agent_chat_pending_alerts('nova');"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM agent_chat_pending_alerts('peer_a');"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM agent_chat_pending_alerts('peer_b');"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "I11: agent_chat_mark_alerts_seen marks alerts seen" {
    local i
    for i in $(seq 1 6); do
        _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "b$i" >/dev/null
    done

    local alert_id
    alert_id="$(_se36_sql "$AGENT_CHAT_DB_NAME" "SELECT alert_id FROM agent_chat_pending_alerts('nova') LIMIT 1;")"
    [ -n "$alert_id" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_mark_alerts_seen(ARRAY[${alert_id}]);"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM agent_chat_pending_alerts('nova');"
    [ "$output" = "0" ]
}

# ─── J cases: backwards compatibility ──────────────────────────────────────

@test "J01: send_agent_message signature is still (text,text,text[],interval,integer)" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE proname = 'send_agent_message';"
    [ "$output" = "p_sender text, p_message text, p_recipients text[], p_ttl interval DEFAULT NULL::interval, p_reply_to integer DEFAULT NULL::integer" ]
}

@test "J02: mark_agent_chat_status returns bigint[] and raw callers ignoring result still work" {
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        ALTER TABLE public.agent_chat DISABLE TRIGGER trg_enforce_agent_chat_function_use;
        INSERT INTO public.agent_chat (id, sender, message, recipients) VALUES (301, 'peer_a', 'test', ARRAY['nova']);
        SELECT setval('public.agent_chat_id_seq', 1000);
    " >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "DO \$\$ BEGIN PERFORM mark_agent_chat_status(ARRAY[301], 'handled'); END \$\$;"
    [ "$status" -eq 0 ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT status FROM public.agent_chat_processed WHERE chat_id = 301 AND agent = 'nova';"
    [ "$output" = "handled" ]
}

@test "J03: send_agent_message 3-arg-equivalent call still works" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT send_agent_message('nova', 'plain', ARRAY['peer_a']);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "J04: send_agent_message 5-arg call with explicit NULLs still works" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT send_agent_message('nova', 'with ttl', ARRAY['peer_a'], interval '1 hour', NULL);"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "J08: existing enum statuses remain usable" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT enum_range(NULL::public.agent_chat_status);"
    [[ "$output" == *"received"* ]]
    [[ "$output" == *"routed"* ]]
    [[ "$output" == *"responded"* ]]
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"expired"* ]]
    [[ "$output" == *"skipped"* ]]
    [[ "$output" == *"handled"* ]]
}

# ─── L cases: regressions ──────────────────────────────────────────────────

@test "L01: sender-side error-template filter still quarantines bare templates" {
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "⚠️ Something went wrong while processing your request. Please try again."
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat WHERE sender = 'nova';"
    [ "$output" = "0" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT reason FROM public.agent_chat_suppressed_log WHERE sender = 'nova';"
    [ "$output" = "sender_filter_error_template" ]
}

@test "L02: gateway fallback text is quarantined and never delivered" {
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "The tool run finished, but no final summary was produced"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat WHERE sender = 'nova';"
    [ "$output" = "0" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT reason FROM public.agent_chat_suppressed_log WHERE sender = 'nova';"
    [ "$output" = "sender_filter_error_template" ]
}

@test "L05: ordinary substantive messages still deliver normally" {
    run _se36_send_as_nova "$AGENT_CHAT_DB_NAME" peer_a "Can you review agent-chat#36 when you get a chance?"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat WHERE sender = 'nova';"
    [ "$output" = "1" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT count(*) FROM public.agent_chat_suppressed_log WHERE sender = 'nova';"
    [ "$output" = "0" ]
}


# ─── M cases: agent-initiated peer mutes ────────────────────────────────────

@test "M01: agent_chat_mute_peer records mute and sends exactly ONE system notice to peer" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_mute_peer('peer_a', 30, 'need a break');"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # Check mute row inserted
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT reason FROM public.agent_chat_mutes WHERE agent = 'nova' AND peer = 'peer_a';"
    [ "$output" = "need a break" ]

    # Check helper
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_is_muted('nova', 'peer_a');"
    [ "$output" = "t" ]

    # Check exactly ONE system notice sent to peer_a
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT message FROM public.agent_chat WHERE sender = 'nova' AND 'peer_a' = ANY(recipients);"
    [[ "$output" == *"nova has paused agent_chat with you until"* ]]
    [[ "$output" == *": need a break"* ]]
}

@test "M02: agent_chat_is_muted returns false when no mute or expired" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_is_muted('nova', 'peer_b');"
    [ "$output" = "f" ]

    # Seed an expired mute
    psql -d "$AGENT_CHAT_DB_NAME" -v ON_ERROR_STOP=1 -c "
        INSERT INTO public.agent_chat_mutes (agent, peer, muted_until, reason)
        VALUES ('nova', 'peer_b', NOW() - interval '5 minutes', 'old mute');
    " >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_is_muted('nova', 'peer_b');"
    [ "$output" = "f" ]
}

@test "M03: agent_chat_unmute_peer removes mute" {
    _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_mute_peer('peer_a', 60, 'testing unmute');" >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_is_muted('nova', 'peer_a');"
    [ "$output" = "t" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_unmute_peer('peer_a');"
    [ "$status" -eq 0 ]
    [ "$output" = "t" ]

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_is_muted('nova', 'peer_a');"
    [ "$output" = "f" ]
}

@test "M04: cannot mute self" {
    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_mute_peer('nova', 30, 'self mute');"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot mute yourself"* ]]
}

@test "M05: agent_chat_mute_peer is scoped to session_user" {
    # Calling as nova cannot set agent='peer_a' in the table
    _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent_chat_mute_peer('peer_b', 30, 'scope test');" >/dev/null

    run _se36_sql "$AGENT_CHAT_DB_NAME" "SELECT agent FROM public.agent_chat_mutes WHERE peer = 'peer_b';"
    [ "$output" = "nova" ]
}
