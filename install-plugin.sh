#!/usr/bin/env bash
# install-plugin.sh — Build, sync, and configure the agent_chat OpenClaw plugin.
#
# Usage: install-plugin.sh [OPTIONS]
# Options:
#   --openclaw-dir <dir>    Target OpenClaw config directory (default: ~/.openclaw).
#   --agent-name <name>     Agent name to register in postgres.json (default: current user).
#   --password <password>   Password for the agent_chat DB role (default: auto-generated).
#   --help                  Show this help message.
#
# Idempotent. Safe to run multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Status symbols
CHECK_MARK="✅"
CROSS_MARK="❌"
WARNING="⚠️"
INFO="ℹ️"

OPENCLAW_DIR="${HOME}/.openclaw"
AGENT_NAME="${AGENT_NAME:-$(whoami)}"
PASSWORD=""

usage() {
  cat <<EOF
Usage: install-plugin.sh [OPTIONS]

Build the agent_chat OpenClaw channel plugin, sync it into
\$OPENCLAW_DIR/extensions/agent_chat, and inject the required OpenClaw config
keys (without credentials).

Options:
  --openclaw-dir <dir>    OpenClaw directory (default: ~/.openclaw).
  --agent-name <name>     Agent name for the postgres.json agent_chat section
                          (default: current unix user).
  --password <password>   Password for that agent role (default: auto-generated).
  --help                  Show this help message.

Environment:
  AGENT_CHAT_DB_NAME      Target database name (default: agent_chat).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --openclaw-dir)
      shift
      if [ $# -eq 0 ]; then
        echo -e "${CROSS_MARK} --openclaw-dir requires a value" >&2
        exit 2
      fi
      OPENCLAW_DIR="$1"
      ;;
    --agent-name)
      shift
      if [ $# -eq 0 ]; then
        echo -e "${CROSS_MARK} --agent-name requires a value" >&2
        exit 2
      fi
      AGENT_NAME="$1"
      ;;
    --password)
      shift
      if [ $# -eq 0 ]; then
        echo -e "${CROSS_MARK} --password requires a value" >&2
        exit 2
      fi
      PASSWORD="$1"
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
      echo -e "${CROSS_MARK} Unexpected argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

EXTENSIONS_DIR="$OPENCLAW_DIR/extensions"
OPENCLAW_CONFIG="$OPENCLAW_DIR/openclaw.json"
PG_CONFIG="$OPENCLAW_DIR/postgres.json"

PLUGIN_SOURCE="$SCRIPT_DIR/plugin"
PLUGIN_TARGET="$EXTENSIONS_DIR/agent_chat"

# Resolve agent_chat database name.
_resolve_db_name() {
  local pg_config="$PG_CONFIG"
  local configured=""
  if [ -f "$pg_config" ] && command -v jq &>/dev/null; then
    configured=$(jq -r '.agentChatDatabase // ""' "$pg_config" 2>/dev/null || true)
  fi
  printf '%s' "${AGENT_CHAT_DB_NAME:-${configured:-agent_chat}}"
}

DB_NAME="$(_resolve_db_name)"

# Password generation ---------------------------------------------------------

_generate_password() {
  openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

# Safe JSON update helpers ----------------------------------------------------

_backup_file() {
  local file="$1"
  if [ -f "$file" ]; then
    install -m 600 "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

_restore_file() {
  local file="$1"
  local newest
  newest=$(find "$(dirname "$file")" -maxdepth 1 -type f -name "$(basename "$file").bak.*" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)
  if [ -n "$newest" ]; then
    cp "$newest" "$file"
  fi
}

_validate_json() {
  local file="$1"
  jq empty "$file" 2>/dev/null
}

# Ensure the agent_chat section in postgres.json has database/user/password.
# Host/port are intentionally omitted — they fall back to flat keys at runtime.
_ensure_agent_chat_postgres_json() {
  local pg_config="$1"
  local database="$2"
  local user="$3"
  local password="$4"

  if [ ! -f "$pg_config" ]; then
    echo "{}" > "$pg_config"
    chmod 600 "$pg_config"
  fi

  if ! command -v jq &>/dev/null; then
    echo -e "  ${WARNING} jq not found; cannot update $pg_config" >&2
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

  # Only write if something changed.
  if [ "$(printf '%s\n' "$new_json" | jq -Sc .)" = "$(jq -Sc . < "$pg_config")" ]; then
    return 1
  fi

  printf '%s\n' "$new_json" >"${pg_config}.tmp" && \
    mv "${pg_config}.tmp" "$pg_config" && \
    chmod 600 "$pg_config"
}

# Inject channels.agent_chat and plugins.entries.agent_chat without credentials.
_ensure_openclaw_config() {
  local config="$1"

  if ! command -v jq &>/dev/null; then
    echo -e "  ${WARNING} jq not found; cannot update $config" >&2
    return 1
  fi

  if [ ! -f "$config" ]; then
    echo "{}" > "$config"
  fi

  local new_json

  # channels.agent_chat: strip dead connection keys, ensure enabled true.
  new_json=$(jq '.channels.agent_chat |= ((. // {}) | del(.database, .host, .port, .user, .password) + {"enabled": true})' "$config") || return 1
  # plugins.entries.agent_chat: enabled + routeToSession main, strip dead keys.
  new_json=$(jq '.plugins.entries.agent_chat |= (. + {"enabled": true} | .config |= ((. // {}) | del(.database, .host, .port, .user, .password) + {"routeToSession": "main"}))' <<< "$new_json") || return 1

  printf '%s\n' "$new_json" >"${config}.tmp" && mv "${config}.tmp" "$config"
}

# Build plugin ----------------------------------------------------------------

_build_plugin() {
  echo "Building agent_chat plugin..."
  cd "$PLUGIN_SOURCE"

  if [ ! -f "package.json" ]; then
    echo -e "  ${CROSS_MARK} package.json not found in $PLUGIN_SOURCE" >&2
    return 1
  fi

  if [ -d "node_modules" ] && [ -d "dist" ]; then
    echo -e "  ${INFO} node_modules and dist exist; skipping npm install"
  else
    if npm install >/dev/null 2>&1; then
      echo -e "  ${CHECK_MARK} npm install completed"
    else
      echo -e "  ${CROSS_MARK} npm install failed" >&2
      return 1
    fi
  fi

  if npm run build >/dev/null 2>&1; then
    echo -e "  ${CHECK_MARK} npm run build completed"
  else
    echo -e "  ${CROSS_MARK} npm run build failed" >&2
    return 1
  fi

  if [ ! -f "dist/index.js" ]; then
    echo -e "  ${CROSS_MARK} Build output dist/index.js not found" >&2
    return 1
  fi

  cd "$SCRIPT_DIR"
}

# Sync to extensions dir ------------------------------------------------------

_sync_plugin() {
  echo "Syncing plugin to $PLUGIN_TARGET..."
  mkdir -p "$EXTENSIONS_DIR"

  if [ ! -d "$PLUGIN_TARGET" ]; then
    mkdir -p "$PLUGIN_TARGET"
  fi

  # rsync --delete semantics: remove stale files, preserve build outputs.
  rsync -a --delete \
    --exclude='node_modules' \
    --exclude='.git' \
    "$PLUGIN_SOURCE/" "$PLUGIN_TARGET/"

  echo -e "  ${CHECK_MARK} Synced plugin to $PLUGIN_TARGET"
}

# Fix openclaw.plugin.json main field ----------------------------------------

_fix_plugin_main() {
  local plugin_json="$PLUGIN_TARGET/openclaw.plugin.json"
  if [ ! -f "$plugin_json" ]; then
    echo -e "  ${WARNING} openclaw.plugin.json not found; skipping main-field fixup" >&2
    return 0
  fi

  if ! command -v jq &>/dev/null; then
    echo -e "  ${WARNING} jq not found; skipping main-field fixup" >&2
    return 0
  fi

  local new_json
  new_json=$(jq '.main = "./dist/index.js"' "$plugin_json" 2>/dev/null) || return 1

  # Only write if something changed.
  if [ "$(printf '%s\n' "$new_json" | jq -Sc .)" = "$(jq -Sc . < "$plugin_json")" ]; then
    echo -e "  ${CHECK_MARK} Verified openclaw.plugin.json main field"
    return 0
  fi

  printf '%s\n' "$new_json" >"${plugin_json}.tmp" && mv "${plugin_json}.tmp" "$plugin_json"
  echo -e "  ${CHECK_MARK} Fixed openclaw.plugin.json main field"
}

# Read password from .pgpass for the target agent -----------------------------

_read_password_from_pgpass() {
  local host="${PGHOST:-localhost}"
  local port="${PGPORT:-5432}"
  local database="$1"
  local user="$2"
  local pgpass="${HOME}/.pgpass"
  local prefix="${host}:${port}:${database}:${user}:"

  if [ ! -f "$pgpass" ]; then
    return 0
  fi

  grep "^${prefix}" "$pgpass" 2>/dev/null | tail -n1 | cut -d: -f5-
  return 0
}

# Main ------------------------------------------------------------------------

main() {
  echo "agent-chat plugin installer"
  echo "Target database: ${DB_NAME}"
  echo "Agent name:      ${AGENT_NAME}"
  echo ""

  # Resolve host/port from postgres.json for .pgpass lookup.
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/pg-env.sh"
  load_pg_env

  if [ -z "$PASSWORD" ]; then
    PASSWORD="$(_read_password_from_pgpass "$DB_NAME" "$AGENT_NAME")"
    if [ -z "$PASSWORD" ]; then
      PASSWORD="$(_generate_password)"
      echo -e "  ${WARNING} No .pgpass entry found for ${AGENT_NAME}@$DB_NAME; generated password"
      echo "      Run register-agent.sh ${AGENT_NAME} first to keep credentials in sync."
    else
      echo -e "  ${CHECK_MARK} Read password for ${AGENT_NAME} from .pgpass"
    fi
  fi

  _build_plugin
  _sync_plugin
  _fix_plugin_main

  # Update postgres.json with safe backup/restore.
  echo "Updating ${PG_CONFIG}..."
  _backup_file "$PG_CONFIG"
  if _ensure_agent_chat_postgres_json "$PG_CONFIG" "$DB_NAME" "$AGENT_NAME" "$PASSWORD"; then
    if _validate_json "$PG_CONFIG"; then
      echo -e "  ${CHECK_MARK} Updated agent_chat section in ${PG_CONFIG}"
    else
      echo -e "  ${CROSS_MARK} ${PG_CONFIG} is invalid JSON after update; restoring backup" >&2
      _restore_file "$PG_CONFIG"
      exit 1
    fi
  else
    echo -e "  ${INFO} ${PG_CONFIG} agent_chat section already up to date"
  fi

  # Update openclaw.json with safe backup/restore.
  echo "Updating ${OPENCLAW_CONFIG}..."
  _backup_file "$OPENCLAW_CONFIG"
  if _ensure_openclaw_config "$OPENCLAW_CONFIG"; then
    if _validate_json "$OPENCLAW_CONFIG"; then
      echo -e "  ${CHECK_MARK} Updated channels.agent_chat / plugins.entries.agent_chat in ${OPENCLAW_CONFIG}"
    else
      echo -e "  ${CROSS_MARK} ${OPENCLAW_CONFIG} is invalid JSON after update; restoring backup" >&2
      _restore_file "$OPENCLAW_CONFIG"
      exit 1
    fi
  else
    echo -e "  ${CROSS_MARK} Failed to update ${OPENCLAW_CONFIG}" >&2
    _restore_file "$OPENCLAW_CONFIG"
    exit 1
  fi

  echo ""
  echo -e "${CHECK_MARK} agent_chat plugin installed successfully"
}

main "$@"
