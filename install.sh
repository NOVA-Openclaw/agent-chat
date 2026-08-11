#!/usr/bin/env bash
# install.sh — once-per-host installer for the agent_chat message bus.
#
# Creates the agent_chat database (name configurable via AGENT_CHAT_DB_NAME),
# applies schema.sql + sorted migrations, and optionally installs the systemd
# listener unit when present. Idempotent and crash-recoverable.

set -euo pipefail

VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Status symbols
CHECK_MARK="✅"
CROSS_MARK="❌"
WARNING="⚠️"
INFO="ℹ️"

# Temp file cleanup
TMPFILES=()
cleanup_tmp() { rm -f "${TMPFILES[@]}"; }
trap cleanup_tmp EXIT

# Load shared config helper
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/pg-env.sh"

# Resolve agent_chat database name.
# Precedence: AGENT_CHAT_DB_NAME env → agentChatDatabase in postgres.json → default agent_chat
_resolve_db_name() {
  local pg_config="${HOME}/.openclaw/postgres.json"
  local configured=""
  if [ -f "$pg_config" ] && command -v jq &>/dev/null; then
    configured=$(jq -r '.agentChatDatabase // ""' "$pg_config" 2>/dev/null || true)
  fi
  printf '%s' "${AGENT_CHAT_DB_NAME:-${configured:-agent_chat}}"
}

DB_NAME="$(_resolve_db_name)"

# Connection helpers ----------------------------------------------------------

_psql() {
  # Run psql against the agent_chat database. Uses current PG* env.
  psql -v ON_ERROR_STOP=1 "$@"
}

_psql_db() {
  # Run psql against a specific database.
  local db="$1"
  shift
  psql -d "$db" -v ON_ERROR_STOP=1 "$@"
}

_psql_list_dbs() {
  # List databases; tolerates connection errors so callers can report cleanly.
  psql -d postgres -v ON_ERROR_STOP=0 -At -c "SELECT datname FROM pg_database;" 2>/dev/null || true
}

_check_connectivity() {
  # Confirm we can reach postgres before creating any artifacts.
  if ! psql -d postgres -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null 2>&1; then
    echo -e "  ${CROSS_MARK} Cannot connect to PostgreSQL at ${PGHOST:-localhost}:${PGPORT:-5432} as ${PGUSER:-$(whoami)}" >&2
    echo "      Verify host/port and ensure the role can connect to the postgres database." >&2
    return 1
  fi
}

_check_privileges() {
  # Confirm the connecting role has CREATEDB (needed to create DB) and DDL privs.
  local can_createdb
  can_createdb=$(psql -d postgres -v ON_ERROR_STOP=1 -At -c "SELECT usesuper OR usecreatedb FROM pg_user WHERE usename = current_user;" 2>/dev/null || echo "f")
  if [ "$can_createdb" != "t" ]; then
    echo -e "  ${CROSS_MARK} Role '${PGUSER:-$(whoami)}' lacks CREATEDB privilege" >&2
    echo "      The bus installer must run as a PostgreSQL superuser or a role with CREATEDB." >&2
    return 1
  fi
}

# Database creation -----------------------------------------------------------

_create_database() {
  local db_name="$1"
  echo "  Creating database '$db_name'..."

  # Attempt to create owned by postgres. This succeeds only when run as a
  # superuser; in non-superuser test/dev environments we fall back to owner
  # current_user and warn instead of failing.
  if createdb -O postgres "$db_name" >/dev/null 2>&1; then
    echo -e "  ${CHECK_MARK} Created database '$db_name' (owner postgres)"
    return 0
  fi

  if createdb "$db_name" >/dev/null 2>&1; then
    echo -e "  ${WARNING} Created database '$db_name' with owner $(whoami) (run as superuser to set owner postgres)"
    return 0
  fi

  echo -e "  ${CROSS_MARK} Failed to create database '$db_name'" >&2
  return 1
}

_ensure_database() {
  local db_name="$1"
  if _psql_list_dbs | grep -qxF "$db_name"; then
    echo -e "  ${INFO} Database '$db_name' already exists"
    return 1
  fi
  _create_database "$db_name"
}

# Schema / migrations ---------------------------------------------------------

_apply_sql_file() {
  local db_name="$1"
  local sql_file="$2"
  local label="${3:-$(basename "$sql_file")}"

  if ! _psql_db "$db_name" -f "$sql_file" >/dev/null 2>&1; then
    echo -e "  ${CROSS_MARK} Failed to apply $label" >&2
    return 1
  fi
  echo -e "  ${CHECK_MARK} Applied $label"
}

_apply_schema() {
  local db_name="$1"
  local schema_file="$SCRIPT_DIR/schema.sql"
  if [ ! -f "$schema_file" ]; then
    echo -e "  ${CROSS_MARK} schema.sql not found: $schema_file" >&2
    return 1
  fi
  _apply_sql_file "$db_name" "$schema_file" "schema.sql"
}

_apply_migrations() {
  local db_name="$1"
  local migrations_dir="$SCRIPT_DIR/migrations"

  if [ ! -d "$migrations_dir" ]; then
    return 0
  fi

  local mig_files=()
  while IFS= read -r -d '' f; do
    mig_files+=("$f")
  done < <(find "$migrations_dir" -maxdepth 1 -name "*.sql" -print0 | sort -z)

  if [ ${#mig_files[@]} -eq 0 ]; then
    return 0
  fi

  echo "  Applying migrations..."
  for sql_file in "${mig_files[@]}"; do
    _apply_sql_file "$db_name" "$sql_file" "$(basename "$sql_file")"
  done
}

# Drift detection -------------------------------------------------------------

_detect_drift() {
  local db_name="$1"
  # Expected columns in public.agent_chat (the canonical set from schema.sql).
  local expected="id,sender,message,recipients,reply_to,timestamp,expires_at"
  local actual
  actual=$(psql -d "$db_name" -v ON_ERROR_STOP=1 -At -c "SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute WHERE attrelid = 'public.agent_chat'::regclass AND attnum > 0 AND NOT attisdropped;" 2>/dev/null || true)

  if [ -z "$actual" ]; then
    return 0
  fi

  if [ "$actual" != "$expected" ]; then
    echo -e "  ${WARNING} Detected column drift in public.agent_chat" >&2
    echo "      Expected: $expected" >&2
    echo "      Actual:   $actual" >&2
    echo "      Unrecognized columns are left untouched; only canonical objects are managed." >&2
  fi
}

# Nightly expire_old_chat cron -----------------------------------------------

_EXPIRE_OLD_CHAT_MARKER="# agent-chat-expire-old-chat"
_EXPIRE_OLD_CHAT_DEFAULT_SCHEDULE="30 3 * * *"

_pick_expire_old_chat_schedule() {
  # Preserve the schedule of an existing expire_old_chat entry if one exists;
  # otherwise fall back to the default 03:30 nightly schedule.
  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || true)
  local schedule
  schedule=$(echo "$current_crontab" | awk '/expire_old_chat/{print $1" "$2" "$3" "$4" "$5; exit}')
  printf '%s' "${schedule:-$_EXPIRE_OLD_CHAT_DEFAULT_SCHEDULE}"
}

_install_expire_old_chat_cron() {
  if [ "${AGENT_CHAT_SKIP_CRON:-}" = "1" ]; then
    echo -e "  ${INFO} AGENT_CHAT_SKIP_CRON=1; skipping expire_old_chat cron installation"
    return 0
  fi

  local schedule
  schedule=$(_pick_expire_old_chat_schedule)
  local new_entry="$schedule psql -d \"$DB_NAME\" -c \"SELECT expire_old_chat();\" $_EXPIRE_OLD_CHAT_MARKER"

  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || true)

  # Idempotent up-to-date check.
  if echo "$current_crontab" | grep -qxF "$new_entry"; then
    echo -e "  ${CHECK_MARK} expire_old_chat cron entry already up to date"
    return 0
  fi

  # Drop any existing expire_old_chat line(s), including stale ones that target
  # a different database (e.g. *_memory), then append the canonical entry.
  local new_crontab
  new_crontab=$(echo "$current_crontab" | grep -vF "expire_old_chat" || true)
  if [ -n "$new_crontab" ]; then
    new_crontab="${new_crontab}"$'\n'"$new_entry"
  else
    new_crontab="$new_entry"
  fi

  printf '%s\n' "$new_crontab" | crontab -
  echo -e "  ${CHECK_MARK} Installed expire_old_chat cron entry ($schedule)"
}

# Listener systemd unit -------------------------------------------------------

_install_listener_unit() {
  local listener_script="$SCRIPT_DIR/listener/pg-notify-listener-chat.py"
  local service_file="$SCRIPT_DIR/listener/pg-notify-listener-chat.service"

  if [ ! -f "$listener_script" ] || [ ! -f "$service_file" ]; then
    echo -e "  ${INFO} Listener unit source not present; skipping"
    return 0
  fi

  if [ "${AGENT_CHAT_SKIP_LISTENER_UNIT:-}" = "1" ]; then
    echo -e "  ${INFO} AGENT_CHAT_SKIP_LISTENER_UNIT=1; skipping listener unit installation"
    return 0
  fi

  local target_dir="${HOME}/.openclaw/scripts"
  local service_dir="${HOME}/.config/systemd/user"
  local logs_dir="${HOME}/.openclaw/logs"
  mkdir -p "$target_dir" "$service_dir" "$logs_dir"

  cp "$listener_script" "$target_dir/pg-notify-listener-chat.py"
  chmod +x "$target_dir/pg-notify-listener-chat.py"
  echo -e "  ${CHECK_MARK} Installed pg-notify-listener-chat.py → $target_dir"

  cp "$service_file" "$service_dir/pg-notify-listener-chat.service"
  echo -e "  ${CHECK_MARK} Installed pg-notify-listener-chat.service → $service_dir"

  if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload
    if systemctl --user is-active pg-notify-listener-chat.service &>/dev/null; then
      if systemctl --user restart pg-notify-listener-chat.service; then
        echo -e "  ${CHECK_MARK} Restarted pg-notify-listener-chat.service"
      else
        echo -e "  ${WARNING} pg-notify-listener-chat.service restart failed"
      fi
    else
      if systemctl --user enable pg-notify-listener-chat.service &>/dev/null && \
         systemctl --user start pg-notify-listener-chat.service; then
        echo -e "  ${CHECK_MARK} Enabled and started pg-notify-listener-chat.service"
      else
        echo -e "  ${WARNING} pg-notify-listener-chat.service enable/start failed"
      fi
    fi
  else
    echo -e "  ${WARNING} systemctl not available — listener service not started"
  fi
}

# Schema-version / idempotency checks -----------------------------------------

_get_installed_version() {
  local db_name="$1"
  psql -d "$db_name" -v ON_ERROR_STOP=0 -At -c "SELECT COALESCE(MAX(version), 0) FROM public.schema_version;" 2>/dev/null || echo "0"
}

_is_up_to_date() {
  local db_name="$1"
  local version
  version="$(_get_installed_version "$db_name")"
  # schema_version is seeded to 1 by schema.sql and advanced to 3 by migrations.
  [ "$version" = "3" ]
}

# Main ------------------------------------------------------------------------

main() {
  echo "agent-chat bus installer v${VERSION}"
  echo "Target database: ${DB_NAME}"
  echo ""

  # Load PG* env from postgres.json (never touches live DB).
  load_pg_env

  # Validate connection before any side effects.
  _check_connectivity
  _check_privileges

  local db_existed=0
  if _ensure_database "$DB_NAME"; then
    echo ""
  else
    db_existed=1
  fi

  if [ "$db_existed" -eq 1 ] && _is_up_to_date "$DB_NAME"; then
    echo -e "  ${INFO} agent_chat bus is up to date (schema_version 3, all expected objects present)"
    _detect_drift "$DB_NAME"
    _install_listener_unit
    _install_expire_old_chat_cron
    echo ""
    echo -e "${CHECK_MARK} agent_chat bus installer complete (no changes needed)"
    exit 0
  fi

  _apply_schema "$DB_NAME"
  _apply_migrations "$DB_NAME"
  _detect_drift "$DB_NAME"
  _install_listener_unit
  _install_expire_old_chat_cron

  echo ""
  echo -e "${CHECK_MARK} agent_chat bus installer complete"
}

main "$@"
