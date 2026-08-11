"""Behavioral tests for the tool surface in aidc_mcp.tools.

Every tool shells out (docker exec / the aidc CLI). We mock exactly that layer —
`_run_cli`, `subprocess.run`, and `asyncio.create_subprocess_exec` — and assert on
the returned {"ok", "error"?, "data"?} envelopes and the main error branches, so
the tool bodies are pinned without a real Docker session.

session_send has its own file (test_session_send.py); this covers the rest.
"""
import asyncio
import base64
import subprocess

import pytest
from mcp.server.fastmcp import FastMCP

from aidc_mcp import tools


def _tool(name):
    app = FastMCP("t")
    tools.register(app)
    return app._tool_manager._tools[name].fn


# --- fakes for the subprocess layer ------------------------------------------

class _FakeStream:
    def __init__(self, data: bytes):
        self._chunks = [data] if data else []

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self._chunks:
            raise StopAsyncIteration
        return self._chunks.pop(0)

    async def read(self):
        d = b"".join(self._chunks)
        self._chunks = []
        return d


class FakeProc:
    """Stand-in for an asyncio subprocess (stdout/stderr streams + returncode)."""

    def __init__(self, stdout=b"", stderr=b"", returncode=0):
        self.stdout = _FakeStream(stdout)
        self.stderr = _FakeStream(stderr)
        self.returncode = returncode

    async def wait(self):
        return self.returncode

    async def communicate(self, input=None):
        return await self.stdout.read(), await self.stderr.read()


class FakeCompleted:
    def __init__(self, returncode=0, stdout=b"", stderr=b""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def _patch_async_proc(monkeypatch, proc, record=None):
    async def _create(*args, **kwargs):
        if record is not None:
            record.append(list(args))
        return proc
    monkeypatch.setattr(tools.asyncio, "create_subprocess_exec", _create)


def _patch_sync_run(monkeypatch, result, record=None):
    def _run(argv, **kwargs):
        if record is not None:
            record.append((argv, kwargs))
        if isinstance(result, BaseException):
            raise result
        return result
    monkeypatch.setattr(tools.subprocess, "run", _run)


def _patch_cli(monkeypatch, result, record=None):
    def _cli(args, timeout=60.0):
        if record is not None:
            record.append((args, timeout))
        return result(args) if callable(result) else result
    monkeypatch.setattr(tools, "_run_cli", _cli)


# --- session_create ----------------------------------------------------------

class TestSessionCreate:
    async def test_requires_repo(self):
        res = await _tool("session_create")(name="proj")
        assert res["ok"] is False and "repo" in res["error"]

    async def test_happy_path(self, monkeypatch):
        _patch_cli(monkeypatch, {"exit": 0, "stdout": "created", "stderr": ""})
        res = await _tool("session_create")(name="proj", repo="/host/repo", ctx=None)
        assert res["ok"] is True
        assert res["data"] == {"name": "proj", "log": "created"}

    async def test_failure_surfaces_stderr(self, monkeypatch):
        _patch_cli(monkeypatch, {"exit": 1, "stdout": "", "stderr": "boom"})
        res = await _tool("session_create")(name="proj", repo="/r", ctx=None)
        assert res["ok"] is False and res["error"] == "boom"


# --- session_list / status / kill (thin _run_cli wrappers) -------------------

class TestSimpleCliTools:
    def test_list_happy(self, monkeypatch):
        _patch_cli(monkeypatch, {"exit": 0, "stdout": "proj running", "stderr": ""})
        res = _tool("session_list")()
        assert res["ok"] is True and res["data"]["raw"] == "proj running"

    def test_list_failure(self, monkeypatch):
        _patch_cli(monkeypatch, {"exit": 2, "stdout": "", "stderr": "docker down"})
        res = _tool("session_list")()
        assert res["ok"] is False and res["error"] == "docker down"

    def test_status_happy(self, monkeypatch):
        _patch_cli(monkeypatch, {"exit": 0, "stdout": "health=ok", "stderr": ""})
        res = _tool("session_status")(name="proj")
        assert res["ok"] is True and "health=ok" in res["data"]["raw"]

    def test_status_failure(self, monkeypatch):
        _patch_cli(monkeypatch, {"exit": 1, "stdout": "", "stderr": "no such session"})
        res = _tool("session_status")(name="ghost")
        assert res["ok"] is False and res["error"] == "no such session"

    def test_kill_not_advertised(self):
        """session_kill must NOT be exposed as an MCP tool.

        A weak metallm client agent called it and killed a live session
        (prod audit 2026-07-04 17:53). Killing is operator-only via the
        ``aidc kill`` CLI; MCP clients must not be able to discover or call it.
        """
        app = FastMCP("t")
        tools.register(app)
        assert "session_kill" not in app._tool_manager._tools


# --- session_exec ------------------------------------------------------------

class TestSessionExec:
    def test_happy(self, monkeypatch):
        rec = []
        _patch_sync_run(monkeypatch, FakeCompleted(0, stdout="hi", stderr=""), record=rec)
        res = _tool("session_exec")(name="proj", cmd="echo hi")
        assert res["ok"] is True
        assert res["data"] == {"stdout": "hi", "stderr": "", "exit": 0}
        # Runs inside the session's dev container as vscode.
        argv = rec[0][0]
        assert argv[:5] == ["docker", "exec", "-u", "vscode", "aidc-proj-dev"]

    def test_nonzero_exit_is_still_ok_envelope(self, monkeypatch):
        # A failing command is a successful tool call that reports exit!=0.
        _patch_sync_run(monkeypatch, FakeCompleted(3, stdout="", stderr="nope"))
        res = _tool("session_exec")(name="proj", cmd="false")
        assert res["ok"] is True and res["data"]["exit"] == 3

    def test_timeout(self, monkeypatch):
        _patch_sync_run(monkeypatch, subprocess.TimeoutExpired(cmd="x", timeout=60))
        res = _tool("session_exec")(name="proj", cmd="sleep 999", timeout_seconds=60)
        assert res["ok"] is False and "timeout" in res["error"]


# --- session_invoke ----------------------------------------------------------

class TestSessionInvoke:
    async def test_happy(self, monkeypatch):
        rec = []
        _patch_async_proc(monkeypatch, FakeProc(stdout=b"the answer", returncode=0), record=rec)
        res = await _tool("session_invoke")(name="proj", prompt="q", ctx=None)
        assert res["ok"] is True and res["data"]["response"] == "the answer"
        # Uses the in-container aidc-claude wrapper in --print mode.
        assert "aidc-claude" in rec[0] and "--print" in rec[0]

    async def test_failure_returns_stderr(self, monkeypatch):
        _patch_async_proc(monkeypatch, FakeProc(stdout=b"partial", stderr=b"kaboom", returncode=1))
        res = await _tool("session_invoke")(name="proj", prompt="q", ctx=None)
        assert res["ok"] is False and res["error"] == "kaboom"
        assert res["data"]["stdout"] == "partial"

    async def test_failure_without_stderr_has_fallback(self, monkeypatch):
        _patch_async_proc(monkeypatch, FakeProc(stdout=b"", stderr=b"", returncode=1))
        res = await _tool("session_invoke")(name="proj", prompt="q", ctx=None)
        assert res["ok"] is False and res["error"] == "claude failed"


# --- session_invoke_async ----------------------------------------------------

class TestSessionInvokeAsync:
    async def test_requires_callback_url(self, monkeypatch):
        monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "")
        res = await _tool("session_invoke_async")(name="proj", prompt="q", conversation_id="c1")
        assert res["ok"] is False and "callback_url" in res["error"]

    async def test_returns_running_immediately(self, monkeypatch):
        monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "http://cb")
        fired = []

        def fake_fire(coro):
            fired.append(coro)
            coro.close()  # don't actually run the background job

        monkeypatch.setattr(tools, "_fire", fake_fire)
        res = await _tool("session_invoke_async")(name="proj", prompt="q", conversation_id="c1")
        assert res["ok"] is True
        assert res["data"] == {"status": "running", "session": "proj", "conversation_id": "c1"}
        assert len(fired) == 1  # a background job was scheduled


# --- session_run -------------------------------------------------------------

class TestSessionRun:
    def test_run_not_advertised(self):
        """session_run must NOT be exposed as an MCP tool.

        Its synchronous, multi-turn round-trip regularly outlasts the metallm
        request window and times out the whole session (see the comment in
        tools.register). The wrapper is retained for easy re-advertisement, but
        MCP clients must not be able to discover or call it; multi-turn work is
        driven as repeated session_send calls instead.
        """
        app = FastMCP("t")
        tools.register(app)
        assert "session_run" not in app._tool_manager._tools


# --- file_get ----------------------------------------------------------------

class TestFileGet:
    def test_happy_utf8(self, monkeypatch):
        _patch_sync_run(monkeypatch, FakeCompleted(0, stdout=b"hello world"))
        res = _tool("file_get")(name="proj", path="/repo/a.txt")
        assert res["ok"] is True
        assert res["data"] == {"path": "/repo/a.txt", "encoding": "utf-8", "content": "hello world"}

    def test_missing_file(self, monkeypatch):
        _patch_sync_run(monkeypatch, FakeCompleted(1, stdout=b"", stderr=b"No such file"))
        res = _tool("file_get")(name="proj", path="/repo/nope")
        assert res["ok"] is False and "No such file" in res["error"]

    def test_binary_falls_back_to_base64(self, monkeypatch):
        blob = b"\xff\xfe\x00\x01"
        _patch_sync_run(monkeypatch, FakeCompleted(0, stdout=blob))
        res = _tool("file_get")(name="proj", path="/repo/x.bin")
        assert res["ok"] is True and res["data"]["encoding"] == "base64"
        assert base64.b64decode(res["data"]["content"]) == blob


# --- file_put ----------------------------------------------------------------

class TestFilePut:
    def test_happy(self, monkeypatch):
        rec = []
        _patch_sync_run(monkeypatch, FakeCompleted(0), record=rec)
        res = _tool("file_put")(name="proj", path="/repo/a.txt", content="data")
        assert res["ok"] is True and res["data"] == {"path": "/repo/a.txt", "bytes": 4}
        assert rec[0][1]["input"] == b"data"  # content streamed via stdin

    def test_failure(self, monkeypatch):
        _patch_sync_run(monkeypatch, FakeCompleted(1, stderr=b"permission denied"))
        res = _tool("file_put")(name="proj", path="/repo/a.txt", content="x")
        assert res["ok"] is False and "permission denied" in res["error"]


# --- audit_get ---------------------------------------------------------------

class TestAuditGet:
    def _events_file(self, tmp_path):
        d = tmp_path / "audit"
        d.mkdir()
        (d / "policy-events.log").write_text(
            '{"at":"2026-01-01T00:00:00Z","trigger":"taint","outcome":"block"}\n'
            "not-json-garbage\n"
            '{"at":"2026-02-01T00:00:00Z","trigger":"auth","outcome":"reject"}\n',
            encoding="utf-8",
        )
        return d

    def test_session_not_found(self, monkeypatch):
        _patch_cli(monkeypatch, {"exit": 1, "stdout": "", "stderr": "x"})
        res = _tool("audit_get")(name="ghost")
        assert res["ok"] is False and res["error"] == "session not found"

    def test_audit_dir_not_found(self, monkeypatch):
        _patch_cli(monkeypatch, {"exit": 0, "stdout": "health=ok\n", "stderr": ""})
        res = _tool("audit_get")(name="proj")
        assert res["ok"] is False and res["error"] == "audit dir not found"

    def test_happy_parses_and_skips_garbage(self, monkeypatch, tmp_path):
        d = self._events_file(tmp_path)
        _patch_cli(monkeypatch, {"exit": 0, "stdout": f"audit: {d}\n", "stderr": ""})
        res = _tool("audit_get")(name="proj")
        assert res["ok"] is True
        assert [e["trigger"] for e in res["data"]["events"]] == ["taint", "auth"]

    def test_since_filter(self, monkeypatch, tmp_path):
        d = self._events_file(tmp_path)
        _patch_cli(monkeypatch, {"exit": 0, "stdout": f"audit: {d}\n", "stderr": ""})
        res = _tool("audit_get")(name="proj", since="2026-01-15T00:00:00Z")
        assert [e["trigger"] for e in res["data"]["events"]] == ["auth"]

    def test_kind_filter(self, monkeypatch, tmp_path):
        d = self._events_file(tmp_path)
        _patch_cli(monkeypatch, {"exit": 0, "stdout": f"audit: {d}\n", "stderr": ""})
        res = _tool("audit_get")(name="proj", kind="taint")
        assert [e["trigger"] for e in res["data"]["events"]] == ["taint"]


# --- taint_mark --------------------------------------------------------------

class TestTaintMark:
    def test_happy(self, monkeypatch):
        rec = []
        _patch_sync_run(monkeypatch, FakeCompleted(0, stdout="", stderr=""), record=rec)
        res = _tool("taint_mark")(name="proj", reason="evil.example")
        assert res["ok"] is True and res["data"] == {"name": "proj", "reason": "evil.example"}
        # Writes into the session's POLICY container, and the payload carries the reason.
        argv = rec[0][0]
        assert "aidc-proj-policy" in argv
        assert any("evil.example" in a for a in argv)

    def test_failure(self, monkeypatch):
        _patch_sync_run(monkeypatch, FakeCompleted(1, stdout="", stderr="write failed"))
        res = _tool("taint_mark")(name="proj", reason="x")
        assert res["ok"] is False and res["error"] == "write failed"


# --- session_watch / session_unwatch -----------------------------------------

@pytest.fixture
def watch_stubs(monkeypatch):
    async def baseline(name, conversation_id):
        return None

    async def fake_watcher(*a, **k):
        await asyncio.Event().wait()  # live until the cleanup fixture cancels it

    async def announce(app_):
        return None

    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "http://cb")
    monkeypatch.setattr(tools, "_baseline_watermark", baseline)
    monkeypatch.setattr(tools, "_run_transcript_watcher", fake_watcher)
    monkeypatch.setattr(tools, "_announce_watchers", announce)


class TestSessionWatch:
    async def test_requires_callback_url(self, monkeypatch):
        monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "")
        res = await _tool("session_watch")(name="proj", conversation_id="c1")
        assert res["ok"] is False and "callback_url" in res["error"]

    async def test_requires_conversation_id(self, watch_stubs):
        res = await _tool("session_watch")(name="proj", conversation_id=None)
        assert res["ok"] is False and "conversation_id" in res["error"]

    async def test_happy_registers_watcher(self, watch_stubs):
        res = await _tool("session_watch")(name="proj", conversation_id="c1")
        assert res["ok"] is True and res["data"]["status"] == "watching"
        assert "proj" in tools._session_watchers

    async def test_rewatch_keeps_the_new_watcher(self, watch_stubs):
        # Re-watching cancels the old task; its (identity-guarded) done-callback
        # must NOT then evict the replacement that now holds the slot.
        watch = _tool("session_watch")
        await watch(name="proj", conversation_id="c1")
        first = tools._session_watchers["proj"]
        await watch(name="proj", conversation_id="c1")
        second = tools._session_watchers["proj"]
        assert first is not second
        for _ in range(5):  # let the cancelled first task's callback run
            await asyncio.sleep(0)
        assert tools._session_watchers.get("proj") is second


class TestSessionUnwatch:
    async def test_stops_and_evicts_state(self, monkeypatch):
        async def announce(app_):
            return None
        monkeypatch.setattr(tools, "_announce_watchers", announce)

        async def _sleeper():
            await asyncio.sleep(100)

        task = asyncio.create_task(_sleeper())
        tools._session_watchers["proj"] = task
        tools._session_send_locks["proj"] = asyncio.Lock()
        tools._settle_state[("proj", "c1")] = (10, 1.0)
        tools._settle_state[("other", "c1")] = (20, 2.0)

        res = await _tool("session_unwatch")(name="proj")

        assert res["ok"] is True and res["data"]["status"] == "stopped"
        assert task.cancelled()
        assert "proj" not in tools._session_watchers
        assert "proj" in tools._session_send_locks  # lock PRESERVED (may be held live)
        assert ("proj", "c1") not in tools._settle_state
        assert ("other", "c1") in tools._settle_state  # only the named session evicted

    async def test_noop_when_not_watching(self, monkeypatch):
        async def announce(app_):
            return None
        monkeypatch.setattr(tools, "_announce_watchers", announce)
        res = await _tool("session_unwatch")(name="never-watched")
        assert res["ok"] is True and res["data"]["status"] == "stopped"


# --- _evict_session_state (unit) ---------------------------------------------

def test_evict_session_state_evicts_settle_scoped_and_keeps_locks():
    tools._session_send_locks["a"] = asyncio.Lock()
    tools._session_send_locks["b"] = asyncio.Lock()
    tools._settle_state[("a", "c1")] = (1, 1.0)
    tools._settle_state[("a", "c2")] = (2, 2.0)
    tools._settle_state[("b", "c1")] = (3, 3.0)

    tools._evict_session_state("a")

    # settle-state for session "a" is dropped (both conversations); "b" untouched.
    assert not any(k[0] == "a" for k in tools._settle_state)
    assert ("b", "c1") in tools._settle_state
    # send locks are NOT evicted (a live send may hold one) — both remain.
    assert "a" in tools._session_send_locks and "b" in tools._session_send_locks


# --- config parsing (unit) ----------------------------------------------------
#
# These parsers had NO direct coverage — every test monkeypatched
# _metallm_callback_url wholesale — which is how the inline-comment bug survived
# to production (2026-07-26). Exercise them against real config text instead.

class TestYamlScalar:
    def test_plain_value(self):
        assert tools._yaml_scalar(" https://m.example.com ") == "https://m.example.com"

    def test_strips_inline_comment(self):
        # The shipped config template documents every key with a trailing
        # comment, so this is the shape a user actually edits.
        raw = ' https://m.example.com    # base URL of your MetaLLM instance'
        assert tools._yaml_scalar(raw) == "https://m.example.com"

    def test_strips_quotes(self):
        assert tools._yaml_scalar(' "https://m.example.com" ') == "https://m.example.com"

    def test_quoted_value_keeps_hash(self):
        # Inside quotes a "# " is content, not a comment.
        assert tools._yaml_scalar('"https://m.example.com/a#b c"') == "https://m.example.com/a#b c"

    def test_unquoted_hash_without_leading_space_is_not_a_comment(self):
        # YAML opens a comment only at line start or after whitespace.
        assert tools._yaml_scalar("https://m.example.com/a#b") == "https://m.example.com/a#b"

    def test_empty_placeholder(self):
        assert tools._yaml_scalar('""    # fill me in') == ""


def _write_cfg(monkeypatch, tmp_path, text):
    cfg = tmp_path / "config.yaml"
    cfg.write_text(text, encoding="utf-8")
    monkeypatch.setattr(tools, "_CONFIG_PATH", cfg)
    return cfg


class TestMetallmCallbackUrl:
    def test_absent_metallm_section(self, monkeypatch, tmp_path):
        """The prod failure: config has only an mcp: section, so session_send
        can never open a webhook and every reply is dropped."""
        _write_cfg(monkeypatch, tmp_path, "mcp:\n  bind_address: 10.0.0.1\n  port: 7878\n")
        assert tools._metallm_callback_url() == ""

    def test_reads_value(self, monkeypatch, tmp_path):
        _write_cfg(monkeypatch, tmp_path,
                   "mcp:\n  port: 7878\nmetallm:\n  callback_url: https://m.example.com/\n")
        assert tools._metallm_callback_url() == "https://m.example.com"

    def test_ignores_inline_comment(self, monkeypatch, tmp_path):
        _write_cfg(monkeypatch, tmp_path,
                   'metallm:\n  callback_url: https://m.example.com   # your instance\n')
        assert tools._metallm_callback_url() == "https://m.example.com"

    def test_stops_at_next_top_level_key(self, monkeypatch, tmp_path):
        """A callback_url under a DIFFERENT top-level key must not be picked up."""
        _write_cfg(monkeypatch, tmp_path,
                   "metallm:\n  turn_settle_seconds: 2\nother:\n  callback_url: https://nope\n")
        assert tools._metallm_callback_url() == ""

    def test_missing_file(self, monkeypatch, tmp_path):
        monkeypatch.setattr(tools, "_CONFIG_PATH", tmp_path / "nope.yaml")
        assert tools._metallm_callback_url() == ""


class TestTurnSettleSeconds:
    def test_default_when_absent(self, monkeypatch, tmp_path):
        _write_cfg(monkeypatch, tmp_path, "metallm:\n  callback_url: https://m\n")
        assert tools._metallm_turn_settle_seconds(default=4.0) == 4.0

    def test_reads_value_with_inline_comment(self, monkeypatch, tmp_path):
        # Pre-fix this parsed "2.5  # quiet window" -> ValueError -> silent
        # fallback to the default, so a configured value was ignored outright.
        _write_cfg(monkeypatch, tmp_path,
                   "metallm:\n  turn_settle_seconds: 2.5   # quiet window\n")
        assert tools._metallm_turn_settle_seconds(default=4.0) == 2.5

    def test_falls_back_on_garbage(self, monkeypatch, tmp_path):
        _write_cfg(monkeypatch, tmp_path, "metallm:\n  turn_settle_seconds: soon\n")
        assert tools._metallm_turn_settle_seconds(default=4.0) == 4.0
