"""A tainted session takes no more work, whichever client asks (decision: one place).

The policy sidecar writes /var/state/tainted when the session reached somewhere it
must not. Every tool that puts work into a session refuses it from then on, with
error_code `tainted`; the tools that read, stop work or take a queued prompt back
stay open.
"""
import inspect

import pytest
from mcp.server.mcpserver import MCPServer

from aidc_mcp import scope, tools
from aidc_mcp import session_facts as sf

TAINT = (b'{"tainted_at":"2026-10-14T09:00:00Z","trigger":"blocklist",'
         b'"domain":"evil.example","squid_log_line":"CONNECT evil.example:443"}\n')


def _app():
    app = MCPServer("t")
    tools.register(app)
    return app


def _args(fn):
    out = {}
    for pname, param in inspect.signature(fn).parameters.items():
        if pname in ("name", "ctx") or param.default is not inspect.Parameter.empty:
            continue
        ann = str(param.annotation)
        out[pname] = 1 if "int" in ann else False if "bool" in ann else "x"
    return out


@pytest.fixture
def tainted(monkeypatch):
    async def run(*args, timeout=20.0):
        if args[:2] == ("exec", "aidc-proj-policy") and sf.TAINT_FILE in args:
            return sf.DockerResult(0, TAINT, b"")
        return sf.DockerResult(1, b"", b"No such file or directory")
    monkeypatch.setattr(sf, "run_docker", run)


@pytest.fixture
def nothing_runs(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("a refused call reached the session")

    async def aboom(*a, **k):
        raise AssertionError("a refused call reached the session")
    monkeypatch.setattr(tools, "_run_cli", boom)
    monkeypatch.setattr(tools.subprocess, "run", boom)
    monkeypatch.setattr(tools.asyncio, "create_subprocess_exec", aboom)


def test_exactly_the_tools_that_put_work_in_are_guarded():
    """Derived from the registry: the guarded set is the six that send a prompt, run a
    command or write a file, and nothing that reads, stops or cancels."""
    guarded = {n for n, t in _app()._tool_manager._tools.items()
               if getattr(t.fn, "refuses_when_tainted", False)}
    assert guarded == set(tools.TAINT_GUARDED)
    assert {"session_send", "session_resend", "session_invoke", "session_invoke_async",
            "session_exec", "file_put"} == guarded
    assert "taint_mark" not in _app()._tool_manager._tools


@pytest.mark.parametrize("tool", sorted(tools.TAINT_GUARDED))
async def test_a_guarded_tool_refuses_a_tainted_session(tool, tainted, nothing_runs, monkeypatch):
    fn = _app()._tool_manager._tools[tool].fn
    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "http://cb")
    res = await fn(name="proj", **_args(fn))
    assert res["ok"] is False
    assert res["error_code"] == "tainted"
    assert res["data"]["tainted"] == {"at": "2026-10-14T09:00:00Z", "trigger": "blocklist",
                                      "domain": "evil.example"}
    assert "Nothing was sent" in res["error"] and "evil.example" in res["error"]


@pytest.mark.parametrize("tool", sorted(tools.TAINT_GUARDED))
async def test_a_guarded_tool_lets_a_clean_session_through(tool, nothing_runs, monkeypatch):
    """Good traffic: no taint flag, and the call reaches the tool itself. The scope check
    inside the tool (_scoped, under the guard) is the first thing past the guard; it is
    made to answer, so the test sees the call arrive without touching a session."""
    calls = []

    def refusal(name):
        calls.append(name)
        return None if len(calls) == 1 else "reached the tool"
    monkeypatch.setattr(scope, "refusal", refusal)
    fn = _app()._tool_manager._tools[tool].fn
    res = await fn(name="proj", **_args(fn))
    assert res["error_code"] == "out_of_scope" and res["error"] == "reached the tool"


async def test_an_unreadable_flag_lets_the_call_through(monkeypatch, nothing_runs):
    """Fail open: a policy sidecar docker cannot reach is logged, and does not stop
    every send."""
    async def run(*args, timeout=20.0):
        return sf.DockerResult(-1, b"", b"Cannot connect to the Docker daemon")
    monkeypatch.setattr(sf, "run_docker", run)
    calls = []

    def refusal(name):
        calls.append(name)
        return None if len(calls) == 1 else "reached the tool"
    monkeypatch.setattr(scope, "refusal", refusal)
    res = await _app()._tool_manager._tools["session_exec"].fn(name="proj", cmd="id")
    assert res["error"] == "reached the tool"


@pytest.mark.parametrize("tool", ["session_interrupt", "session_queue_cancel", "session_status",
                                  "session_transcript", "repo_status", "file_get"])
def test_reading_stopping_and_cancelling_are_not_guarded(tool):
    fn = _app()._tool_manager._tools[tool].fn
    assert not getattr(fn, "refuses_when_tainted", False)


async def test_read_taint_tells_clean_from_unknown(monkeypatch):
    async def missing(*args, timeout=20.0):
        return sf.DockerResult(1, b"", b"cat: /var/state/tainted: No such file or directory")
    monkeypatch.setattr(sf, "run_docker", missing)
    assert await sf.read_taint("proj") is None

    async def gone(*args, timeout=20.0):
        return sf.DockerResult(1, b"", b"Error: No such container: aidc-proj-policy")
    monkeypatch.setattr(sf, "run_docker", gone)
    with pytest.raises(sf.TaintUnknown):
        await sf.read_taint("proj")

    async def garbled(*args, timeout=20.0):
        return sf.DockerResult(0, b"not json", b"")
    monkeypatch.setattr(sf, "run_docker", garbled)
    assert (await sf.read_taint("proj"))["trigger"] == "unknown"  # a flag is a taint
