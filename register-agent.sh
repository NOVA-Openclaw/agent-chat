#!/usr/bin/env bash
# register-agent.sh — Register a NOVA agent role for the agent_chat bus.
#
# Usage: register-agent.sh [OPTIONS] <agent_name>
# Options:
#   --password <password>   Set a specific password (otherwise auto-generated).
#   --pgpass-file <path>    Write the .pgpass entry to this file (default: ~/.pgpass).
#   --check                 Report registration state without making changes.
#   --help                  Show this help message.
#
# Idempotent. On every run (except --check) the script re-applies the standard
# grant set: SELECT/INSERT/UPDATE/DELETE on agent_chat and agent_chat_processed,
# and USAGE on agent_chat_id_seq. This is deliberate policy; if you have
# manually hardened an agent's bus permissions, do not re-run this script for that
# agent unless you intend to restore the standard grant set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Status symbols
CHECK_MARK="✅"
CROSS_MARK="❌"
WARNING="⚠️"
INFO="ℹ️"

# Load shared config helper
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/pg-env.sh"

# Resolve agent_chat database name.
_resolve_db_name() {
  local pg_config="${HOME}/.openclaw/postgres.json"
  local configured=""
  if [ -f "$pg_config" ] && command -v jq &>/dev/null; then
    configured=$(jq -r '.agentChatDatabase // ""' "$pg_config" 2>/dev/null || true)
  fi
  printf '%s' "${AGENT_CHAT_DB_NAME:-${configured:-agent_chat}}"
}

DB_NAME="$(_resolve_db_name)"

# CLI parsing
AGENT_NAME=""
PASSWORD=""
PGPASS_FILE="${HOME}/.pgpass"
CHECK_ONLY=0

usage() {
  cat <<EOF
Usage: register-agent.sh [OPTIONS] <agent_name>

Register (or re-register) an agent role for the agent_chat message bus.

Options:
  --password <password>   Set a specific password (otherwise auto-generated).
  --pgpass-file <path>    Write the .pgpass entry to this file (default: ~/.pgpass).
  --check                 Report whether the agent is registered; make no changes.
  --help                  Show this help message.

Environment:
  AGENT_CHAT_DB_NAME      Target database name (default: agent_chat).

Notes:
  * Re-running for an already-registered agent is idempotent: grants are
    re-asserted and the .pgpass entry is replaced (never duplicated).
  * This script always applies the standard grant set. If you have manually
    restricted an agent's bus permissions, re-running will widen them back
    to the standard set unless you avoid this script for that agent.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --password)
      shift
      if [ $# -eq 0 ]; then
        echo -e "${CROSS_MARK} --password requires a value" >&2
        exit 2
      fi
      PASSWORD="$1"
      ;;
    --pgpass-file)
      shift
      if [ $# -eq 0 ]; then
        echo -e "${CROSS_MARK} --pgpass-file requires a value" >&2
        exit 2
      fi
      PGPASS_FILE="$1"
      ;;
    --check)
      CHECK_ONLY=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo -e "${CROSS_MARK} Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$AGENT_NAME" ]; then
        echo -e "${CROSS_MARK} Only one agent name may be specified" >&2
        exit 2
      fi
      AGENT_NAME="$1"
      ;;
  esac
  shift
done

# Name validation --------------------------------------------------------------
# Postgres identifiers: <= 63 bytes, start with a-z, then a-z0-9_.
# Reserved roles are rejected.
_validate_agent_name() {
  local name="$1"
  local len
  len=$(printf '%s' "$name" | wc -c)

  if [ "$len" -eq 0 ]; then
    echo -e "${CROSS_MARK} Agent name cannot be empty" >&2
    return 1
  fi

  if [ "$len" -gt 63 ]; then
    echo -e "${CROSS_MARK} Agent name '$name' exceeds 63 bytes (length: $len)" >&2
    return 1
  fi

  if ! printf '%s' "$name" | grep -qxE '^[a-z][a-z0-9_]*$'; then
    echo -e "${CROSS_MARK} Agent name '$name' is not a valid lowercase PostgreSQL identifier" >&2
    echo "      Allowed: lowercase letters, digits, underscores; must start with a letter." >&2
    return 1
  fi

  case "$name" in
    postgres|public)
      echo -e "${CROSS_MARK} Agent name '$name' is a reserved PostgreSQL role/name" >&2
      return 1
      ;;
  esac
}

if ! _validate_agent_name "$AGENT_NAME"; then
  exit 1
fi

# Connection helpers ----------------------------------------------------------

_psql_db() {
  psql -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

_check_connectivity() {
  if ! psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null 2>&1; then
    echo -e "${CROSS_MARK} Cannot connect to database '$DB_NAME' at ${PGHOST:-localhost}:${PGPORT:-5432}" >&2
    echo "      Verify the bus is installed and the role can connect." >&2
    return 1
  fi
}

# Privilege check -------------------------------------------------------------

_check_privileges() {
  local can_createrole
  can_createrole=$(psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -At -c "SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = current_user;" 2>/dev/null || echo "f")
  if [ "$can_createrole" != "t" ]; then
    echo -e "  ${CROSS_MARK} Role '${PGUSER:-$(whoami)}' lacks CREATEROLE privilege" >&2
    echo "      register-agent.sh must run as a PostgreSQL superuser or a role with CREATEROLE." >&2
    return 1
  fi
}

# Role existence --------------------------------------------------------------

_role_exists() {
  local role="$1"
  local result
  result=$(psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -At -c "SELECT 1 FROM pg_roles WHERE rolname = '$role';")
  [ "$result" = "1" ]
}

# Password generation ---------------------------------------------------------

_generate_password() {
  # 32 bytes base64 ≈ 43 chars; strip non-alphanumeric for safe psql quoting.
  openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

# .pgpass management ----------------------------------------------------------

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

  # Already correct? Nothing to do.
  if grep -qxF "$line" "$pgpass" 2>/dev/null; then
    return 1
  fi

  local tmpfile
  tmpfile=$(mktemp)
  chmod 600 "$tmpfile"
  # Drop any stale entry with the same prefix, then append the new one.
  if [ -s "$pgpass" ]; then
    grep -vF "$prefix" "$pgpass" >"$tmpfile" 2>/dev/null || true
  fi
  printf '%s\n' "$line" >>"$tmpfile"
  mv "$tmpfile" "$pgpass"
  chmod 600 "$pgpass"
  return 0
}

# Main ------------------------------------------------------------------------

main() {
  load_pg_env

  # Force PGDATABASE to the bus DB for this script.
  export PGDATABASE="$DB_NAME"

  echo "Registering agent '${AGENT_NAME}' on database '${DB_NAME}'..."

  if ! _check_connectivity; then
    exit 1
  fi

  # --check mode: report and exit without changes (no CREATEROLE required).
  if [ "$CHECK_ONLY" -eq 1 ]; then
    if _role_exists "$AGENT_NAME"; then
      echo -e "  ${CHECK_MARK} Agent '${AGENT_NAME}' is registered (role exists)"
      exit 0
    else
      echo -e "  ${INFO} Agent '${AGENT_NAME}' is NOT registered (role missing)"
      exit 1
    fi
  fi

  if ! _check_privileges; then
    exit 1
  fi

  if [ -z "$PASSWORD" ]; then
    PASSWORD="$(_generate_password)"
  fi

  # Create role if missing (no superuser, no createdb).
  if _role_exists "$AGENT_NAME"; then
    echo -e "  ${INFO} Role '${AGENT_NAME}' already exists"
  else
    psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$AGENT_NAME\" WITH LOGIN NOINHERIT NOCREATEDB NOSUPERUSER NOCREATEROLE;" >/dev/null
    echo -e "  ${CHECK_MARK} Created role '${AGENT_NAME}'"
  fi

  # Set password. Do not echo it.
  psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$AGENT_NAME\" WITH PASSWORD '$PASSWORD';" >/dev/null
  echo -e "  ${CHECK_MARK} Set password for role '${AGENT_NAME}'"

  # Apply standard grants.
  psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.agent_chat TO \"$AGENT_NAME\";" >/dev/null
  psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.agent_chat_processed TO \"$AGENT_NAME\";" >/dev/null
  psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "GRANT USAGE ON SEQUENCE public.agent_chat_id_seq TO \"$AGENT_NAME\";" >/dev/null
  echo -e "  ${CHECK_MARK} Applied standard grants to '${AGENT_NAME}'"

  # Update .pgpass.
  local host="${PGHOST:-localhost}"
  local port="${PGPORT:-5432}"
  if _ensure_pgpass_entry "$host" "$port" "$DB_NAME" "$AGENT_NAME" "$PASSWORD"; then
    echo -e "  ${CHECK_MARK} Updated .pgpass entry for ${host}:${port}:${DB_NAME}:${AGENT_NAME}"
  else
    echo -e "  ${INFO} .pgpass entry already correct"
  fi

  # Verify connectivity with the new credentials via .pgpass (no env pollution).
  if psql -h "$host" -p "$port" -U "$AGENT_NAME" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
    echo -e "  ${CHECK_MARK} Verified connection as '${AGENT_NAME}'"
  else
    echo -e "  ${WARNING} Connection test as '${AGENT_NAME}' failed (host=${host}, port=${port})" >&2
  fi

  echo ""
  echo -e "${CHECK_MARK} Agent '${AGENT_NAME}' registered successfully"
}

main "$@"
