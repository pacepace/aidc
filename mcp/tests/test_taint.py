"""A tainted session takes no more work, whichever client asks (decision: one place).

The policy sidecar writes /var/state/tainted when the session reached somewhere it
must not. Every tool that puts work into a session refuses it from then on, with
error_code `tainted`; the tools that read, stop work or take a queued prompt back
stay open.
"""
import asyncio
import subprocess

import pytest

from aidc_mcp import authz, scope
from aidc_mcp import session_facts as sf
from aidc_mcp.service import common as com
from aidc_mcp.service import config as orc
from aidc_mcp.tearstools import AidcTool, build_tools, envelope_result
from tests import toolcall

TAINT = (b'{"tainted_at":"2026-10-14T09:00:00Z","trigger":"blocklist",'
         b'"domain":"evil.example","squid_log_line":"CONNECT evil.example:443"}\n')

ALL_TOOLS = sorted(t.local_name for t in build_tools())


def _args(tool):
    """The tool's required arguments other than `name`, with a value of each one's type."""
    schema = toolcall.instance(tool).mcp_schema().input_schema
    out = {}
    for pname in schema.get("required", []):
        if pname == "name":
            continue
        kind = schema["properties"][pname].get("type")
        out[pname] = 1 if kind == "integer" else False if kind == "boolean" else "x"
    return out


@pytest.fixture
def reached(monkeypatch):
    """Every tool, stubbed past the authorizer: records which tool the call reached."""
    seen = []

    async def execute(self, ctx=None, **arguments):
        seen.append(self.local_name)
        return envelope_result(com.envelope_ok({"reached": self.local_name}))
    monkeypatch.setattr(AidcTool, "execute", execute)
    return seen


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
    monkeypatch.setattr(com, "run_cli", boom)
    monkeypatch.setattr(subprocess, "run", boom)
    monkeypatch.setattr(asyncio, "create_subprocess_exec", aboom)


async def test_exactly_the_tools_that_put_work_in_are_guarded(tainted, reached):
    """Every offered tool called on a tainted session: the ones refused are the six that
    send a prompt, run a command or write a file, and nothing that reads, stops or cancels
    (TRS-12 pins the set)."""
    refused = set()
    for tool in ALL_TOOLS:
        res = await toolcall.call(tool, name="proj", **_args(tool))
        if res.get("error_code") == "tainted":
            refused.add(tool)
    assert refused == set(authz.TAINT_GUARDED)
    assert {"session_send", "session_resend", "session_invoke", "session_invoke_async",
            "session_exec", "file_put"} == refused
    assert "taint_mark" not in ALL_TOOLS


@pytest.mark.parametrize("tool", sorted(authz.TAINT_GUARDED))
async def test_a_guarded_tool_refuses_a_tainted_session(tool, tainted, nothing_runs, monkeypatch):
    monkeypatch.setattr(orc, "orchestrator_callback_url", lambda: "http://cb")
    res = await toolcall.call(tool, name="proj", **_args(tool))
    assert res["ok"] is False
    assert res["error_code"] == "tainted"
    assert res["data"]["tainted"] == {"at": "2026-10-14T09:00:00Z", "trigger": "blocklist",
                                      "domain": "evil.example"}
    assert "Nothing was sent" in res["error"] and "evil.example" in res["error"]


@pytest.mark.parametrize("tool", sorted(authz.TAINT_GUARDED))
async def test_a_guarded_tool_lets_a_clean_session_through(tool, nothing_runs, reached):
    """Good traffic: no taint flag, and the call reaches the tool itself."""
    res = await toolcall.call(tool, name="proj", **_args(tool))
    assert res == {"ok": True, "data": {"reached": tool}} and reached == [tool]


async def test_an_unreadable_flag_lets_the_call_through(monkeypatch, nothing_runs, reached):
    """Fail open: a policy sidecar docker cannot reach is logged, and does not stop
    every send."""
    async def run(*args, timeout=20.0):
        return sf.DockerResult(-1, b"", b"Cannot connect to the Docker daemon")
    monkeypatch.setattr(sf, "run_docker", run)
    res = await toolcall.call("session_exec", name="proj", cmd="id")
    assert res["data"] == {"reached": "session_exec"}


async def test_an_out_of_scope_tainted_call_is_refused_as_out_of_scope_without_asking(
        monkeypatch, nothing_runs):
    """The scope is decided first: a session this server does not serve is not asked
    about at all."""
    monkeypatch.setenv(scope.ENV, "other")

    async def must_not_run(*args, timeout=20.0):
        raise AssertionError(f"docker asked about an out-of-scope session: {args}")
    monkeypatch.setattr(sf, "run_docker", must_not_run)
    res = await toolcall.call("session_exec", name="proj", cmd="id")
    assert res["error_code"] == "out_of_scope"


@pytest.mark.parametrize("tool", ["session_interrupt", "session_queue_cancel", "session_status",
                                  "session_transcript", "repo_status", "file_get"])
async def test_reading_stopping_and_cancelling_are_not_guarded(tool, tainted, reached):
    res = await toolcall.call(tool, name="proj", **_args(tool))
    assert res["ok"] is True and reached == [tool]


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


async def test_the_git_agent_has_no_sandbox_to_taint(monkeypatch):
    """The git agent has no policy sidecar (it is trusted): it is never tainted, and no
    docker call is made to ask (one would fail and be logged on every list)."""
    async def must_not_run(*args, timeout=20.0):
        raise AssertionError(f"docker called: {args}")
    monkeypatch.setattr(sf, "run_docker", must_not_run)
    assert await sf.read_taint("git") is None
    assert await sf.policy_events("git") == []
