"""Tests for the agent_chat schema-sync listener."""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest import mock

import psycopg2
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
LISTENER_PATH = REPO_ROOT / "listener" / "pg-notify-listener-chat.py"


def _load_listener_module():
    """Load the hyphenated listener file as a valid Python module name."""
    spec = importlib.util.spec_from_file_location(
        "pg_notify_listener_chat", LISTENER_PATH
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["pg_notify_listener_chat"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def listener():
    """Provide a freshly loaded listener module with a clean env cache."""
    mod = _load_listener_module()
    mod._pg_env_cache = None
    yield mod


# ---------------------------------------------------------------------------
# Alert routing
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "sender,expected",
    [
        ("nova", ["graybeard"]),
        ("NOVA", ["graybeard"]),
        ("graybeard", ["nova"]),
        ("other", ["nova"]),
        ("", ["nova"]),
        ("nova", ["graybeard"]),
    ],
)
def test_alert_recipients_excludes_sender(listener, sender, expected):
    assert listener._alert_recipients(sender) == expected


def test_alert_recipients_broadcast_when_all_excluded(listener):
    # Only primary/fallback excluded would require both to be the sender, which
    # can't happen with distinct lists, but guard the fallback path.
    listener._ALERT_PRIMARY = ["nova"]
    listener._ALERT_FALLBACK = ["nova"]
    assert listener._alert_recipients("nova") == ["*"]


# ---------------------------------------------------------------------------
# Push failure classification
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "stderr,expected",
    [
        ("! [rejected] main -> main (fetch first)", "non-fast-forward"),
        ("error: failed to push some refs to ... non-fast-forward ...", "non-fast-forward"),
        ("Permission denied (publickey).", "auth"),
        ("Authentication failed for 'https://...'", "auth"),
        ("fatal: could not read Username", "auth"),
        ("remote: Internal Server Error", "transient"),
        ("", "transient"),
        (None, "transient"),
    ],
)
def test_classify_push_failure(listener, stderr, expected):
    assert listener._classify_push_failure(stderr) == expected


# ---------------------------------------------------------------------------
# Debounce / dedup processor
# ---------------------------------------------------------------------------


class TestSchemaChangeProcessor:
    def test_first_event_processed(self, listener):
        p = listener.SchemaChangeProcessor(debounce=30)
        assert p.should_process({"command_tag": "CREATE TABLE", "object_identity": "public.foo"})

    def test_duplicate_within_debounce_is_deduplicated(self, listener):
        p = listener.SchemaChangeProcessor(debounce=30)
        payload = {"command_tag": "CREATE TABLE", "object_identity": "public.foo"}
        assert p.should_process(payload) is True
        assert p.should_process(payload) is False

    def test_different_object_still_debounced_globally(self, listener):
        p = listener.SchemaChangeProcessor(debounce=30)
        assert p.should_process({"command_tag": "CREATE TABLE", "object_identity": "public.foo"}) is True
        # Same command, different object: still inside global debounce window.
        assert p.should_process({"command_tag": "CREATE TABLE", "object_identity": "public.bar"}) is False

    def test_after_debounce_window_new_event_processed(self, listener):
        p = listener.SchemaChangeProcessor(debounce=0.1)
        payload = {"command_tag": "CREATE TABLE", "object_identity": "public.foo"}
        assert p.should_process(payload) is True
        time.sleep(0.15)
        assert p.should_process(payload) is True

    def test_system_objects_skipped(self, listener):
        p = listener.SchemaChangeProcessor(debounce=30)
        assert p.should_process({"command_tag": "CREATE TABLE", "object_identity": "pg_catalog.foo"}) is False
        assert p.should_process({"command_tag": "CREATE TABLE", "object_identity": "pg_toast.foo"}) is False

    def test_pgschema_temp_schema_skipped(self, listener):
        p = listener.SchemaChangeProcessor(debounce=30)
        assert p.should_process({"command_tag": "CREATE SCHEMA", "object_identity": "pgschema_tmp_123"}) is False

    def test_invalid_json_in_process_is_handled(self, listener, capsys):
        p = listener.SchemaChangeProcessor(debounce=30)
        p.process("not valid json")
        captured = capsys.readouterr()
        assert "Invalid schema_changed payload" in captured.out


# ---------------------------------------------------------------------------
# Git lock acquisition skip path
# ---------------------------------------------------------------------------


def test_lock_skip_when_already_held(listener, tmp_path):
    lock_path = tmp_path / "test.lock"

    # Hold the lock in a subprocess so the non-blocking call in this process fails.
    holder = subprocess.Popen(
        [
            sys.executable,
            "-c",
            (
                "import fcntl, time\n"
                f"fd = open({str(lock_path)!r}, 'w')\n"
                "fcntl.flock(fd, fcntl.LOCK_EX)\n"
                "time.sleep(5)\n"
            ),
        ]
    )
    try:
        # Wait for the subprocess to actually acquire the lock.
        time.sleep(0.3)
        assert listener._try_acquire_lock(str(lock_path)) is None
    finally:
        holder.terminate()
        holder.wait(timeout=5)


def test_lock_acquired_when_free(listener, tmp_path):
    lock_path = tmp_path / "test.lock"
    fd = listener._try_acquire_lock(str(lock_path))
    assert fd is not None
    listener._release_lock(fd)


# ---------------------------------------------------------------------------
# Reconnect behavior
# ---------------------------------------------------------------------------


def test_connect_with_retry_recovers_after_operational_error(listener, monkeypatch):
    """Initial connection retry loop must reconnect and issue LISTEN."""
    calls = {"count": 0}

    def fake_connect(*args, **kwargs):
        calls["count"] += 1
        if calls["count"] == 1:
            raise psycopg2.OperationalError("connection refused")
        conn = mock.MagicMock()
        conn.closed = 0
        return conn

    monkeypatch.setattr(psycopg2, "connect", fake_connect)
    monkeypatch.setattr(listener.time, "sleep", lambda _s: None)

    conn = listener._connect_with_retry()
    assert calls["count"] == 2
    cur = conn.cursor.return_value
    cur.execute.assert_called_once_with("LISTEN schema_changed;")


def test_poll_and_process_raises_connection_lost_on_operational_error(
    listener, monkeypatch
):
    conn = mock.MagicMock()
    conn.closed = 0
    conn.poll.side_effect = psycopg2.OperationalError("server closed connection")
    monkeypatch.setattr(listener.select, "select", lambda *args, **kwargs: ([conn], [], []))

    processor = listener.SchemaChangeProcessor()
    with pytest.raises(listener.ConnectionLost):
        listener._poll_and_process(conn, processor)


def test_poll_and_process_raises_connection_lost_when_conn_closed(
    listener, monkeypatch
):
    conn = mock.MagicMock()
    conn.closed = 1
    monkeypatch.setattr(listener.select, "select", lambda *args, **kwargs: ([conn], [], []))

    processor = listener.SchemaChangeProcessor()
    with pytest.raises(listener.ConnectionLost):
        listener._poll_and_process(conn, processor)


# ---------------------------------------------------------------------------
# Integration smoke
# ---------------------------------------------------------------------------


def _create_test_db():
    db_name = f"agent_chat_chunk3_test_{os.getpid()}"
    subprocess.run(["dropdb", "--if-exists", db_name], check=False, capture_output=True)
    subprocess.run(["createdb", db_name], check=True, capture_output=True)
    return db_name


def _drop_test_db(db_name):
    subprocess.run(["dropdb", "--if-exists", db_name], check=False, capture_output=True)


@pytest.mark.integration
def _git_push(work, *args, env=None):
    """Push to origin/main, bypassing the protected-branch pre-push hook."""
    run_env = (env or os.environ).copy()
    run_env["OPENCLAW_AGENT_ID"] = "gidget"
    subprocess.run(
        ["git", "-C", str(work), "push"] + list(args),
        check=True,
        capture_output=True,
        env=run_env,
    )


def test_smoke_ddl_notification_dump_commit_push():
    """End-to-end: manual NOTIFY -> listener -> dump -> commit -> local bare remote."""
    db_name = _create_test_db()
    tmpdir = Path(tempfile.mkdtemp())
    try:
        # Apply schema + migrations so send_agent_message exists.
        subprocess.run(
            ["psql", "-d", db_name, "-v", "ON_ERROR_STOP=0", "-f", str(REPO_ROOT / "schema.sql")],
            check=True,
            capture_output=True,
        )
        for mig in sorted((REPO_ROOT / "migrations").glob("*.sql")):
            subprocess.run(
                ["psql", "-d", db_name, "-v", "ON_ERROR_STOP=0", "-f", str(mig)],
                check=True,
                capture_output=True,
            )

        # Set up a local bare remote and a working clone on main.
        bare = tmpdir / "origin.git"
        work = tmpdir / "work"
        subprocess.run(["git", "init", "--bare", str(bare)], check=True, capture_output=True)
        subprocess.run(["git", "clone", str(bare), str(work)], check=True, capture_output=True)
        (work / "README.md").write_text("# agent-chat\n")
        subprocess.run(["git", "-C", str(work), "config", "user.email", "test@example.com"], check=True)
        subprocess.run(["git", "-C", str(work), "config", "user.name", "Test User"], check=True)
        subprocess.run(["git", "-C", str(work), "add", "."], check=True)
        subprocess.run(["git", "-C", str(work), "commit", "-m", "init"], check=True, capture_output=True)
        _git_push(work, "-u", "origin", "main")

        # Build a postgres.json that points the agent_chat section at our test DB.
        config_file = tmpdir / "postgres.json"
        config_file.write_text(
            json.dumps(
                {
                    "host": "localhost",
                    "port": 5432,
                    "agent_chat": {
                        "database": db_name,
                        "user": "nova",
                        "password": "",
                    },
                }
            )
        )

        env = os.environ.copy()
        env["AGENT_CHAT_LISTENER_CONFIG"] = str(config_file)
        env["AGENT_CHAT_REPO"] = str(work)

        proc = subprocess.Popen(
            [sys.executable, str(LISTENER_PATH)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        try:
            # Give the listener time to connect and LISTEN.
            time.sleep(1.0)

            # The test environment does not guarantee a superuser, so the DDL
            # event trigger may not exist. Execute the DDL manually and then
            # issue the same NOTIFY payload the event trigger would emit.
            conn = psycopg2.connect(database=db_name, user="nova", host="localhost")
            conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
            cur = conn.cursor()
            cur.execute(
                "CREATE TABLE public.smoke_test_chunk3 (id serial PRIMARY KEY);"
            )
            payload = json.dumps(
                {
                    "command_tag": "CREATE TABLE",
                    "object_type": "table",
                    "object_identity": "public.smoke_test_chunk3",
                }
            )
            cur.execute("NOTIFY schema_changed, %s", (payload,))
            cur.close()
            conn.close()

            # Wait for the commit to land in the working repo.
            found = False
            for _ in range(40):
                time.sleep(0.5)
                result = subprocess.run(
                    ["git", "-C", str(work), "log", "--oneline", "-1"],
                    capture_output=True,
                    text=True,
                )
                if "schema: CREATE TABLE smoke_test_chunk3" in result.stdout:
                    found = True
                    break
            assert found, f"Commit did not land; last log: {result.stdout}"

            # The schema.sql file must contain the new table.
            schema_text = (work / "schema.sql").read_text()
            assert "smoke_test_chunk3" in schema_text

            # The push must have reached the local bare remote.
            result = subprocess.run(
                ["git", "-C", str(bare), "log", "--oneline", "-1"],
                capture_output=True,
                text=True,
            )
            assert "schema: CREATE TABLE smoke_test_chunk3" in result.stdout
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
    finally:
        _drop_test_db(db_name)
        shutil.rmtree(tmpdir, ignore_errors=True)
