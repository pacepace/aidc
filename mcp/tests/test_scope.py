"""A session-scoped MCP server (AIDC_MCP_ALLOWED_SESSIONS): its token must not reach any
session but the named ones."""
import inspect
import json

import pytest
from mcp.server.fastmcp import FastMCP

from aidc_mcp import resources, scope, tools

NAMED_TOOLS = ["session_status", "session_exec", "session_invoke", "session_invoke_async",
               "session_send", "session_watch", "session_resend", "session_unwatch",
               "file_get", "file_put", "audit_get", "taint_mark"]

CALLS = {
    "session_status": {},
    "session_exec": {"cmd": "id"},
    "session_invoke": {"prompt": "hi"},
    "session_invoke_async": {"prompt": "hi"},
    "session_send": {"prompt": "hi"},
    "session_watch": {"conversation_id": "c"},
    "session_resend": {"conversation_id": "c"},
    "session_unwatch": {},
    "file_get": {"path": "/etc/hostname"},
    "file_put": {"path": "/tmp/x", "content": "x"},
    "audit_get": {},
    "taint_mark": {"reason": "r"},
}


@pytest.fixture
def app():
    a = FastMCP("t")
    tools.register(a)
    resources.register(a)
    return a


@pytest.fixture
def forbid_side_effects(monkeypatch):
    """Anything that would touch docker or the CLI fails the test."""
    def boom(*a, **k):
        raise AssertionError("an out-of-scope call reached the session")

    async def aboom(*a, **k):
        raise AssertionError("an out-of-scope call reached the session")

    monkeypatch.setattr(tools, "_run_cli", boom)
    monkeypatch.setattr(tools.subprocess, "run", boom)
    monkeypatch.setattr(tools.asyncio, "create_subprocess_exec", aboom)


def test_unset_or_empty_means_unrestricted(monkeypatch):
    monkeypatch.delenv(scope.ENV, raising=False)
    assert scope.allowed_sessions() is None and scope.refusal("anything") is None
    monkeypatch.setenv(scope.ENV, " , ")
    assert scope.allowed_sessions() is None


def test_names_split_on_commas_and_spaces(monkeypatch):
    monkeypatch.setenv(scope.ENV, "jointtest, other  third")
    assert scope.allowed_sessions() == {"jointtest", "other", "third"}


@pytest.mark.parametrize("tool", NAMED_TOOLS)
async def test_every_named_tool_refuses_a_session_outside_the_scope(
        tool, app, monkeypatch, forbid_side_effects):
    monkeypatch.setenv(scope.ENV, "jointtest")
    fn = app._tool_manager._tools[tool].fn
    result = fn(name="metallm", **CALLS[tool])
    if inspect.isawaitable(result):
        result = await result
    assert result["ok"] is False
    assert "outside this MCP server's scope" in result["error"]


def _dummy_args(fn):
    """Values for a tool's required parameters other than `name`, by annotation."""
    out = {}
    for pname, param in inspect.signature(fn).parameters.items():
        if pname in ("name", "ctx") or param.default is not inspect.Parameter.empty:
            continue
        ann = str(param.annotation)
        out[pname] = (1 if "int" in ann else ["x"] if "list" in ann
                      else False if "bool" in ann else "x")
    return out


async def test_every_tool_that_takes_a_session_name_refuses_out_of_scope(
        app, monkeypatch, forbid_side_effects):
    """Derived from the registry, not a list: a tool added later with a `name`
    parameter and no scope check fails here."""
    monkeypatch.setenv(scope.ENV, "jointtest")
    checked = 0
    for tool_name, tool in app._tool_manager._tools.items():
        if tool_name == "session_create" or "name" not in inspect.signature(tool.fn).parameters:
            continue
        result = tool.fn(name="metallm", **_dummy_args(tool.fn))
        if inspect.isawaitable(result):
            result = await result
        assert result["ok"] is False, tool_name
        assert "outside this MCP server's scope" in result["error"], tool_name
        assert result["error_code"] == "out_of_scope", tool_name
        checked += 1
    assert checked >= len(NAMED_TOOLS)


def test_scoping_keeps_the_tool_schemas_and_context_injection(app):
    """The wrapper must not change what FastMCP sees: session_invoke still gets its
    Context injected, and `ctx` is not advertised as an argument."""
    invoke = app._tool_manager._tools["session_invoke"]
    assert invoke.context_kwarg == "ctx"
    assert "ctx" not in invoke.parameters["properties"]
    assert set(invoke.parameters["properties"]) == {"name", "prompt"}


async def test_session_create_is_refused_when_scoped(app, monkeypatch, forbid_side_effects):
    monkeypatch.setenv(scope.ENV, "jointtest")
    result = await app._tool_manager._tools["session_create"].fn(
        name="jointtest", repo="/tmp")
    assert result["ok"] is False and "cannot create sessions" in result["error"]
    assert result["error_code"] == "create_not_allowed"


def test_session_list_shows_only_allowed_sessions(app, monkeypatch):
    monkeypatch.setenv(scope.ENV, "jointtest")
    raw = ("SESSION   STATUS   PROFILE\n"
           "jointtest Up 1 min multi\n"
           "metallm   Up 2 days multi\n")
    monkeypatch.setattr(tools, "_run_cli", lambda args, timeout=60.0: {
        "exit": 0, "stdout": raw, "stderr": ""})
    out = app._tool_manager._tools["session_list"].fn()["data"]["raw"]
    assert out == "SESSION   STATUS   PROFILE\njointtest Up 1 min multi\n"


def test_in_scope_calls_go_through(app, monkeypatch):
    monkeypatch.setenv(scope.ENV, "jointtest")
    monkeypatch.setattr(tools, "_run_cli", lambda args, timeout=60.0: {
        "exit": 0, "stdout": "status ok", "stderr": ""})
    res = app._tool_manager._tools["session_status"].fn(name="jointtest")
    assert res["ok"] is True


def test_resources_refuse_outside_the_scope_and_hide_config(monkeypatch):
    monkeypatch.setenv(scope.ENV, "jointtest")
    monkeypatch.setattr(resources, "_run", lambda args: "SESSION X\nmetallm Up\njointtest Up\n")
    a = FastMCP("r")
    resources.register(a)
    fns = {str(t.uri_template): t.fn for t in a._resource_manager._templates.values()}
    fns.update({str(r.uri): r.fn for r in a._resource_manager._resources.values()})
    assert "outside" in json.loads(fns["aidc://sessions/{name}/status"](name="metallm"))["error"]
    assert "outside" in json.loads(fns["aidc://sessions/{name}/audit"](name="metallm"))["error"]
    assert "outside" in json.loads(
        fns["aidc://sessions/{name}/audit/{filename}"](name="metallm", filename="a"))["error"]
    assert "error" in json.loads(fns["aidc://config"]())
    assert json.loads(fns["aidc://sessions"]())["raw"] == "SESSION X\njointtest Up\n"


async def test_resume_leaves_other_sessions_queues_alone(monkeypatch, tmp_path):
    from aidc_mcp import transcript as ts
    monkeypatch.setenv(scope.ENV, "jointtest")
    ts.save_send_queue(tools._WATCHER_STATE_DIR, "metallm", [ts.QueuedPrompt("x", "t")])

    async def never(name):
        raise AssertionError("checked a session outside the scope")

    monkeypatch.setattr(tools, "_session_instance", never)
    await tools.resume_send_queues()
    assert "metallm" not in tools._pending_sends
    assert ts.send_queue_path(tools._WATCHER_STATE_DIR, "metallm").exists()
