#!/usr/bin/env bash
# pg-env.sh — PostgreSQL config loader for agent-chat shell scripts.
# Resolution order: ENV vars → ~/.openclaw/postgres.json (flat keys) → defaults.
# When an agent_chat section exists, its database/user/password values are
# preferred for the bus connection; host/port fall back to flat keys.
#
# NOTE: this loader intentionally does NOT export PGPASSWORD. Credentials for
# psql are resolved from ~/.pgpass by libpq. See GLOBAL/DATABASE_ACCESS.md.

load_pg_env() {
  local config="${HOME}/.openclaw/postgres.json"
  local json=""

  if [ -f "$config" ] && [ -r "$config" ]; then
    json=$(cat "$config" 2>/dev/null) || json=""
    if [ -n "$json" ] && ! echo "$json" | jq empty 2>/dev/null; then
      echo "WARNING: Malformed JSON in $config, ignoring config file" >&2
      json=""
    fi
  fi

  _pg_json_val() {
    local key="$1"
    if [ -n "$json" ]; then
      local val
      val=$(echo "$json" | jq -r ".$key // empty" 2>/dev/null || true)
      if [ -n "$val" ]; then
        echo "$val"
      fi
    fi
    return 0
  }

  _pg_json_section_val() {
    local section="$1"
    local key="$2"
    if [ -n "$json" ]; then
      local val
      val=$(echo "$json" | jq -r ".${section}.${key} // empty" 2>/dev/null || true)
      if [ -n "$val" ]; then
        echo "$val"
      fi
    fi
    return 0
  }

  local val

  # Host/port fall back to flat keys when the agent_chat section omits them.
  val="${PGHOST:-$(_pg_json_section_val agent_chat host)}"
  val="${val:-$(_pg_json_val host)}"
  export PGHOST="${val:-localhost}"

  val="${PGPORT:-$(_pg_json_section_val agent_chat port)}"
  val="${val:-$(_pg_json_val port)}"
  export PGPORT="${val:-5432}"

  # Database/user/password prefer the agent_chat section.
  val="${PGDATABASE:-$(_pg_json_section_val agent_chat database)}"
  val="${val:-$(_pg_json_val database)}"
  if [ -n "$val" ]; then
    export PGDATABASE="$val"
  fi

  val="${PGUSER:-$(_pg_json_section_val agent_chat user)}"
  val="${val:-$(_pg_json_val user)}"
  export PGUSER="${val:-$(whoami)}"
}
