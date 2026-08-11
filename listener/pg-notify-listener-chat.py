#!/usr/bin/env python3
"""
Schema-sync listener for the agent_chat PostgreSQL database.

Listens for pg_notify('schema_changed') events, dumps the current schema with
pgschema, commits the updated schema.sql to the agent-chat repo, and pushes to
origin/main.

This daemon is intentionally lean: it handles ONLY schema_changed notifications
for agent_chat. It does not handle gambling_changed, daily-log, heartbeat, or
other channels that the nova-mind reference listener may process.

Configuration:
  * PostgreSQL credentials resolve from ~/.openclaw/postgres.json.
    Per-field precedence is: agent_chat section (when present) → ENV vars →
    top-level flat keys → defaults. Host/port fall back to flat keys when the
    agent_chat section omits them.
  * AGENT_CHAT_REPO overrides the checkout path (default: $HOME/agent-chat).
  * AGENT_CHAT_LISTENER_CONFIG overrides the postgres.json path.
"""

import fcntl
import json
import os
import select
import subprocess
import sys
import time
from datetime import datetime, timezone

import psycopg2
import psycopg2.extensions

# Stable import path for the shared pg_env helper.
_PG_ENV_DIR = os.path.expanduser("~/.openclaw/lib")
if os.path.isdir(_PG_ENV_DIR) and _PG_ENV_DIR not in sys.path:
    sys.path.insert(0, _PG_ENV_DIR)

from pg_env import load_pg_env  # type: ignore

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONFIG_PATH = os.environ.get(
    "AGENT_CHAT_LISTENER_CONFIG", os.path.expanduser("~/.openclaw/postgres.json")
)
AGENT_CHAT_REPO = os.environ.get(
    "AGENT_CHAT_REPO", os.path.join(os.path.expanduser("~"), "agent-chat")
)
SCHEMA_FILE = os.path.join(AGENT_CHAT_REPO, "schema.sql")
GIT_LOCK_PATH = os.path.expanduser(
    "~/.openclaw/workspace/scripts/.pg-notify-git-chat.lock"
)

DEBOUNCE_SECONDS = 30
MAX_PUSH_ATTEMPTS = 3
PUSH_BACKOFF_DELAYS = [2, 4]
PUSH_TIMEOUT = 60

_ALERT_PRIMARY = ["nova"]
_ALERT_FALLBACK = ["graybeard"]

_pg_env_cache = None


# ---------------------------------------------------------------------------
# Logging / utilities
# ---------------------------------------------------------------------------


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc).isoformat()}] {msg}", flush=True)


def _get_pg_env() -> dict:
    """Load and cache agent_chat connection parameters."""
    global _pg_env_cache
    if _pg_env_cache is None:
        _pg_env_cache = load_pg_env(config_path=CONFIG_PATH, section="agent_chat")
    return _pg_env_cache


def reload_config() -> dict:
    """Reload configuration from disk and return the new env dict."""
    global _pg_env_cache
    _pg_env_cache = load_pg_env(config_path=CONFIG_PATH, section="agent_chat")
    return _pg_env_cache


# ---------------------------------------------------------------------------
# Alert routing
# ---------------------------------------------------------------------------


def _alert_recipients(sender: str) -> list[str]:
    """Resolve agent_chat alert recipients, excluding the sending user.

    send_agent_message enforces two guards that motivate this helper:
      1. LOWER(p_sender) == session_user: the sender must match the connecting
         PGUSER (so we bind the real connecting user, not a fake role).
      2. The sender must NOT appear in the recipient list (self-address guard).

    Primary routing is to nova. When the listener itself is nova, that would
    violate guard #2, so we fall back to graybeard. The final resort is a
    broadcast so the alert is not dropped.
    """
    sender_l = (sender or "").lower()
    primary = [r for r in _ALERT_PRIMARY if r.lower() != sender_l]
    if primary:
        return primary
    fallback = [r for r in _ALERT_FALLBACK if r.lower() != sender_l]
    return fallback or ["*"]


def _classify_push_failure(stderr: str | None) -> str:
    """Classify git push stderr into failure types for retry policy."""
    if not stderr:
        return "transient"
    stderr_lower = stderr.lower()
    if (
        "! [rejected]" in stderr
        or "(fetch first)" in stderr
        or "non-fast-forward" in stderr_lower
    ):
        return "non-fast-forward"
    if (
        "permission denied" in stderr_lower
        or "authentication failed" in stderr_lower
        or "fatal: could not read" in stderr_lower
    ):
        return "auth"
    return "transient"


def _send_alert(message: str) -> None:
    """Send an agent_chat alert. Never propagates exceptions."""
    try:
        env = _get_pg_env()
        sender = env.get("PGUSER")
        if not sender:
            log("PGUSER not configured; cannot send alert")
            return

        recipients = _alert_recipients(sender)
        conn = psycopg2.connect(
            host=env.get("PGHOST", "localhost"),
            database=env["PGDATABASE"],
            user=sender,
            password=env.get("PGPASSWORD", ""),
        )
        try:
            cur = conn.cursor()
            cur.execute(
                "SELECT send_agent_message(%s, %s, %s)",
                (sender, message, recipients),
            )
            conn.commit()
            cur.close()
            log(f"Alerted {recipients} via agent_chat")
        finally:
            conn.close()
    except Exception as alert_err:
        log(f"Failed to send agent_chat alert: {alert_err}")


def _send_push_alert(
    commit_hash: str | None,
    command: str,
    table_name: str,
    failure_class: str,
    stderr: str | None,
) -> None:
    lines = [
        "[schema-sync]",
        f"Schema sync push failed ({failure_class}):",
        f"  repo: agent-chat",
        f"  path: {AGENT_CHAT_REPO}",
        f"  commit: {commit_hash or '(unknown)'}",
        f"  message: schema: {command} {table_name}",
    ]
    if failure_class == "non-fast-forward":
        lines.append(
            f"  reason: origin/main has diverged. Reconcile manually: "
            f"cd {AGENT_CHAT_REPO} && git fetch origin && "
            f"git rebase origin/main && git push origin main"
        )
    elif failure_class == "auth":
        lines.append(
            f"  reason: authentication failed. Check SSH keys / credentials "
            f"for origin, then run: cd {AGENT_CHAT_REPO} && git push origin main"
        )
    else:
        lines.append(
            f"  reason: push failed after {MAX_PUSH_ATTEMPTS} attempts. "
            f"Investigate network/remote health, then run: "
            f"cd {AGENT_CHAT_REPO} && git push origin main"
        )
    if stderr:
        lines.append(f"  git stderr: {stderr.strip()[:500]}")
    _send_alert("\n".join(lines))


def _send_branch_alert(
    found_branch: str,
    command: str,
    table_name: str,
    reason: str,
    stderr: str | None = None,
) -> None:
    lines = [
        "[schema-sync]",
        f"Schema sync aborted ({reason}):",
        f"  repo: agent-chat",
        f"  path: {AGENT_CHAT_REPO}",
        f"  expected branch: main",
        f"  found branch: {found_branch}",
        f"  message: schema: {command} {table_name}",
    ]
    if reason == "diverged":
        lines.append(
            f"  reason: main has diverged from origin/main. Reconcile manually: "
            f"cd {AGENT_CHAT_REPO} && git fetch origin && "
            f"git rebase origin/main && git push origin main"
        )
    elif reason == "fetch failed":
        lines.append(
            f"  reason: unable to fetch origin. Investigate remote connectivity, "
            f"then run: cd {AGENT_CHAT_REPO} && git checkout main && "
            f"git fetch origin && git merge --ff-only origin/main"
        )
    elif reason == "checkout failed":
        lines.append(
            f"  reason: unable to checkout main. Reconcile manually: "
            f"cd {AGENT_CHAT_REPO} && git stash && git checkout main && "
            f"git fetch origin && git merge --ff-only origin/main"
        )
    elif reason == "stash failed":
        lines.append(
            f"  reason: unable to stash working-tree changes before branch "
            f"remediation. Reconcile manually: cd {AGENT_CHAT_REPO} && git stash && "
            f"git checkout main && git fetch origin && git merge --ff-only origin/main"
        )
    else:
        lines.append(
            f"  reason: branch-safety check failed ({reason}). Reconcile manually: "
            f"cd {AGENT_CHAT_REPO} && git checkout main && git fetch origin && "
            f"git merge --ff-only origin/main"
        )
    if stderr:
        lines.append(f"  git stderr: {stderr.strip()[:500]}")
    _send_alert("\n".join(lines))


# ---------------------------------------------------------------------------
# Git lock
# ---------------------------------------------------------------------------


def _try_acquire_lock(lock_path: str) -> object | None:
    """Acquire an exclusive non-blocking file lock. Returns the open fd or None."""
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    fd = open(lock_path, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (IOError, OSError):
        fd.close()
        return None


def _release_lock(fd: object | None) -> None:
    if fd is None:
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except Exception:
        pass
    try:
        fd.close()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Branch safety
# ---------------------------------------------------------------------------


def _is_working_tree_dirty(repo: str) -> bool:
    res = subprocess.run(
        ["git", "-C", repo, "status", "--porcelain"],
        capture_output=True,
        text=True,
    )
    return res.returncode == 0 and bool(res.stdout.strip())


def _ensure_on_main(command: str, table_name: str) -> bool:
    """Ensure the working clone is on main and fast-forwarded with origin.

    Runs inside the git lock critical section. Returns True if the clone is on
    main and up-to-date, False if remediation is not possible. Stashes dirty
    working trees before switching branches and pops the stash on success.
    """
    repo = AGENT_CHAT_REPO

    branch_res = subprocess.run(
        ["git", "-C", repo, "branch", "--show-current"],
        capture_output=True,
        text=True,
    )
    if branch_res.returncode != 0:
        current_branch = None
        detached = True
    else:
        current_branch = branch_res.stdout.strip()
        detached = current_branch == ""

    dirty = _is_working_tree_dirty(repo)
    stashed = False

    def _stash() -> bool:
        nonlocal stashed
        stash_res = subprocess.run(
            ["git", "-C", repo, "stash", "push", "-m", "schema-sync auto-stash"],
            capture_output=True,
            text=True,
        )
        if stash_res.returncode != 0:
            _send_branch_alert(
                current_branch or "DETACHED",
                command,
                table_name,
                "stash failed",
                stash_res.stderr,
            )
            return False
        stashed = True
        return True

    def _pop_stash() -> None:
        if not stashed:
            return
        pop_res = subprocess.run(
            ["git", "-C", repo, "stash", "pop"],
            capture_output=True,
            text=True,
        )
        if pop_res.returncode != 0:
            _send_branch_alert(
                "main", command, table_name, "stash pop failed", pop_res.stderr
            )

    def _fetch_and_ff(found_label: str) -> bool:
        fetch_res = subprocess.run(
            ["git", "-C", repo, "fetch", "origin"],
            capture_output=True,
            text=True,
        )
        if fetch_res.returncode != 0:
            _send_branch_alert(
                found_label, command, table_name, "fetch failed", fetch_res.stderr
            )
            return False
        ff_res = subprocess.run(
            ["git", "-C", repo, "merge", "--ff-only", "origin/main"],
            capture_output=True,
            text=True,
        )
        if ff_res.returncode != 0:
            _send_branch_alert(
                found_label, command, table_name, "diverged", ff_res.stderr
            )
            return False
        return True

    if current_branch == "main" and not detached:
        log("Already on main; fetching origin...")
        if dirty and not _stash():
            return False
        if not _fetch_and_ff("main"):
            _pop_stash()
            return False
        _pop_stash()
        log("Branch check complete; on main and up-to-date")
        return True

    # Wrong branch or detached HEAD: safe remediation.
    found_label = current_branch if current_branch else "DETACHED"
    log(f"Branch check failed (found: {found_label}); attempting remediation...")
    if dirty and not _stash():
        return False

    checkout_res = subprocess.run(
        ["git", "-C", repo, "checkout", "main"],
        capture_output=True,
        text=True,
    )
    if checkout_res.returncode != 0:
        _send_branch_alert(
            found_label, command, table_name, "checkout failed", checkout_res.stderr
        )
        _pop_stash()
        return False

    if not _fetch_and_ff(found_label):
        _pop_stash()
        return False

    _pop_stash()
    log("Branch remediation complete; now on main and fast-forwarded")
    return True


# ---------------------------------------------------------------------------
# Schema sync
# ---------------------------------------------------------------------------


def _dump_schema() -> bool:
    """Dump agent_chat schema to SCHEMA_FILE using pgschema."""
    env = _get_pg_env()
    log(f"Dumping schema to {SCHEMA_FILE}...")
    cmd = [
        "pgschema",
        "dump",
        "--host",
        env.get("PGHOST", "localhost"),
        "--port",
        str(env.get("PGPORT", "5432")),
        "--db",
        env["PGDATABASE"],
        "--user",
        env["PGUSER"],
        "--schema",
        "public",
    ]
    if env.get("PGPASSWORD"):
        cmd.extend(["--password", env["PGPASSWORD"]])

    os.makedirs(os.path.dirname(SCHEMA_FILE), exist_ok=True)
    with open(SCHEMA_FILE, "w") as schema_out:
        result = subprocess.run(
            cmd,
            stdout=schema_out,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120,
            cwd=AGENT_CHAT_REPO,
        )
    if result.returncode != 0:
        log(f"pgschema dump failed: {result.stderr}")
        return False
    return True


def sync_schema_to_github(
    command: str, obj_type: str, obj_identity: str
) -> tuple[bool, str | None]:
    """Dump schema and push to origin/main. Serialized by a file lock."""
    lock_fd = _try_acquire_lock(GIT_LOCK_PATH)
    if lock_fd is None:
        log("Git lock held by another sync - skipping")
        return False, None

    try:
        table_name = obj_identity.split(".")[-1] if "." in obj_identity else obj_identity

        if not _ensure_on_main(command, table_name):
            return False, None

        if not _dump_schema():
            return False, None

        status = subprocess.run(
            ["git", "-C", AGENT_CHAT_REPO, "status", "--porcelain"],
            capture_output=True,
            text=True,
        )
        if not status.stdout.strip():
            log("No schema changes to commit (file unchanged)")
            return True, None

        subprocess.run(
            ["git", "-C", AGENT_CHAT_REPO, "add", "schema.sql"],
            check=True,
        )

        commit_msg = f"schema: {command} {table_name}"
        subprocess.run(
            ["git", "-C", AGENT_CHAT_REPO, "commit", "-m", commit_msg],
            capture_output=True,
            check=True,
        )
        log(f"Committed: {commit_msg}")

        hash_result = subprocess.run(
            ["git", "-C", AGENT_CHAT_REPO, "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
        )
        commit_hash = (
            hash_result.stdout.strip() if hash_result.returncode == 0 else None
        )

        last_stderr = ""
        failure_class = "transient"
        for attempt in range(1, MAX_PUSH_ATTEMPTS + 1):
            try:
                log(
                    f"Pushing commit {commit_hash} to origin (attempt "
                    f"{attempt}/{MAX_PUSH_ATTEMPTS})..."
                )
                push_env = os.environ.copy()
                push_env["OPENCLAW_AGENT_ID"] = "gidget"
                push_result = subprocess.run(
                    ["git", "-C", AGENT_CHAT_REPO, "push", "origin", "main"],
                    capture_output=True,
                    text=True,
                    timeout=PUSH_TIMEOUT,
                    env=push_env,
                )
                if push_result.returncode == 0:
                    log(f"Pushed commit {commit_hash} to origin")
                    return True, commit_hash
                last_stderr = push_result.stderr
                failure_class = _classify_push_failure(last_stderr)
                log(
                    f"Push attempt {attempt}/{MAX_PUSH_ATTEMPTS} failed "
                    f"({failure_class}): {last_stderr.strip()}"
                )
                if failure_class in ("auth", "non-fast-forward"):
                    break
                if attempt < MAX_PUSH_ATTEMPTS:
                    delay = PUSH_BACKOFF_DELAYS[attempt - 1]
                    log(f"Retrying push in {delay}s...")
                    time.sleep(delay)
            except subprocess.TimeoutExpired as e:
                failure_class = "transient"
                last_stderr = e.stderr if e.stderr else f"push timed out after {PUSH_TIMEOUT}s"
                log(f"Push attempt {attempt}/{MAX_PUSH_ATTEMPTS} timed out")
                if attempt < MAX_PUSH_ATTEMPTS:
                    delay = PUSH_BACKOFF_DELAYS[attempt - 1]
                    log(f"Retrying push in {delay}s...")
                    time.sleep(delay)

        log(f"Failed to push commit {commit_hash} to origin after exhausting retries")
        _send_push_alert(commit_hash, command, table_name, failure_class, last_stderr)
        return False, commit_hash

    except subprocess.CalledProcessError as e:
        log(f"Schema sync failed: {e}")
        return False, None
    except subprocess.TimeoutExpired:
        log("Schema sync timed out")
        return False, None
    except Exception as e:
        log(f"Error syncing schema: {e}")
        return False, None
    finally:
        _release_lock(lock_fd)


# ---------------------------------------------------------------------------
# Notification debounce / dedup processor
# ---------------------------------------------------------------------------


class SchemaChangeProcessor:
    """Debounces and deduplicates schema_changed notifications."""

    def __init__(self, debounce: int = DEBOUNCE_SECONDS):
        self.debounce = debounce
        self.last_sync_time = 0.0
        self.dedup_cache: dict[tuple[str, str], float] = {}

    def should_process(self, payload: dict) -> bool:
        """Return True if this payload should trigger a full schema sync."""
        command = payload.get("command_tag", "UNKNOWN")
        obj_identity = payload.get("object_identity", "unknown")

        # Skip internal/system objects and pgschema temp schemas.
        if obj_identity.startswith("pg_") or "pg_toast" in obj_identity:
            log(f"Skipping system object: {obj_identity}")
            return False
        if "pgschema_tmp_" in obj_identity:
            log(f"Skipping pgschema temp schema: {obj_identity}")
            return False

        now = time.time()
        dedup_key = (command, obj_identity)

        # Deduplicate identical (command, object) pairs within the debounce window.
        if dedup_key in self.dedup_cache:
            if now - self.dedup_cache[dedup_key] < self.debounce:
                log(
                    f"Deduplicated schema notification: {command} {obj_identity} "
                    f"(within {self.debounce}s)"
                )
                return False

        self.dedup_cache[dedup_key] = now
        # Prune stale entries (older than 2x debounce).
        self.dedup_cache = {
            k: v for k, v in self.dedup_cache.items() if now - v < self.debounce * 2
        }

        # Debounce the expensive dump/commit/push sequence globally.
        if now - self.last_sync_time < self.debounce:
            log(
                f"Debounced schema sync (last sync {now - self.last_sync_time:.1f}s ago)"
            )
            return False

        self.last_sync_time = now
        return True

    def process(self, payload_str: str) -> None:
        try:
            payload = json.loads(payload_str)
        except json.JSONDecodeError as e:
            log(f"Invalid schema_changed payload: {e}")
            return

        command = payload.get("command_tag", "UNKNOWN")
        obj_type = payload.get("object_type", "unknown")
        obj_identity = payload.get("object_identity", "unknown")

        log(f"Schema change detected: {command} {obj_type} {obj_identity}")

        if not self.should_process(payload):
            return

        sync_schema_to_github(command, obj_type, obj_identity)


# ---------------------------------------------------------------------------
# Connection handling
# ---------------------------------------------------------------------------


class ConnectionLost(Exception):
    """Raised when the database connection is no longer usable."""

    pass


def _connect() -> psycopg2.extensions.connection:
    """Open a connection to the agent_chat database."""
    env = _get_pg_env()
    kwargs: dict = {
        "host": env.get("PGHOST", "localhost"),
        "database": env["PGDATABASE"],
        "user": env["PGUSER"],
    }
    if env.get("PGPASSWORD"):
        kwargs["password"] = env["PGPASSWORD"]
    return psycopg2.connect(**kwargs)


def _connect_and_listen() -> psycopg2.extensions.connection:
    """Connect to agent_chat and issue LISTEN schema_changed."""
    conn = _connect()
    conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()
    cur.execute("LISTEN schema_changed;")
    cur.close()
    return conn


def _close_connection(conn: psycopg2.extensions.connection | None) -> None:
    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass


def _poll_and_process(
    conn: psycopg2.extensions.connection, processor: SchemaChangeProcessor
) -> None:
    """Wait for and process one batch of notifications."""
    try:
        if conn.closed:
            raise ConnectionLost("connection is closed")

        ready = select.select([conn], [], [], 60)
        if ready == ([], [], []):
            return

        if conn.closed:
            raise ConnectionLost("connection is closed after select")

        conn.poll()
        while conn.notifies:
            notify = conn.notifies.pop(0)
            if notify.channel == "schema_changed":
                processor.process(notify.payload)
    except (psycopg2.OperationalError, psycopg2.InterfaceError, OSError) as e:
        raise ConnectionLost(f"poll/select failed: {e}") from e


def _connect_with_retry(
    max_backoff: int = 60,
) -> psycopg2.extensions.connection:
    """Connect and LISTEN with exponential backoff. Never gives up."""
    backoff = 1
    while True:
        try:
            return _connect_and_listen()
        except (psycopg2.OperationalError, psycopg2.InterfaceError, OSError) as e:
            log(f"Failed to connect to agent_chat: {e}; retrying in {backoff}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, max_backoff)


def main() -> None:
    log("Starting agent_chat schema-sync listener...")
    reload_config()
    conn = None
    backoff = 1
    while True:
        try:
            conn = _connect_with_retry()
            log("Connected and listening on agent_chat")
            backoff = 1
            processor = SchemaChangeProcessor()
            while True:
                _poll_and_process(conn, processor)
        except ConnectionLost as e:
            log(f"Connection lost: {e}")
        except Exception as e:
            log(f"Error in main loop: {e}")
        finally:
            _close_connection(conn)
            conn = None
        log(f"Reconnecting in {backoff}s...")
        time.sleep(backoff)
        backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    main()
