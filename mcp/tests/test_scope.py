"""A session-scoped MCP server (AIDC_MCP_ALLOWED_SESSIONS): its token must not reach any
session but the named ones."""
import asyncio
import json
import subprocess
from types import MappingProxyType

import pytest
from threetears.mcp import Refusal, ResourceRequest

from aidc_mcp import authz, resources, scope, server
from aidc_mcp.service import common as com
from aidc_mcp.service import sending as snd
from aidc_mcp.service import state as ss
from aidc_mcp.service import turns as tn
from aidc_mcp.tearstools import build_tools
from tests import toolcall

NAMED_TOOLS = ["session_status", "session_exec", "session_invoke", "session_invoke_async",
               "session_send", "session_watch", "session_resend", "session_unwatch",
               "file_get", "file_put", "audit_get", "session_mcp_set", "session_transcript",
               "session_interrupt", "session_queue_cancel", "file_list", "file_search",
               "repo_status", "repo_diff", "repo_log", "repo_branches"]

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
    "session_mcp_set": {"server": "project", "path": "/mcp", "bearer": "t"},
    "session_transcript": {},
    "session_interrupt": {},
    "session_queue_cancel": {},
    "file_list": {},
    "file_search": {"pattern": "x"},
    "repo_status": {},
    "repo_diff": {},
    "repo_log": {},
    "repo_branches": {},
}


@pytest.fixture
def forbid_side_effects(monkeypatch):
    """Anything that would touch docker or the CLI fails the test."""
    def boom(*a, **k):
        raise AssertionError("an out-of-scope call reached the session")

    async def aboom(*a, **k):
        raise AssertionError("an out-of-scope call reached the session")

    monkeypatch.setattr(com, "run_cli", boom)
    monkeypatch.setattr(subprocess, "run", boom)
    monkeypatch.setattr(asyncio, "create_subprocess_exec", aboom)


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
        tool, monkeypatch, forbid_side_effects):
    monkeypatch.setenv(scope.ENV, "jointtest")
    result = await toolcall.call(tool, name="orchestrator", **CALLS[tool])
    assert result["ok"] is False
    assert "outside this MCP server's scope" in result["error"]


def _dummy_args(tool):
    """Values for a tool's required arguments other than `name`, by schema type."""
    schema = tool.mcp_schema().input_schema
    out = {}
    for pname in schema.get("required", []):
        if pname == "name":
            continue
        kind = schema["properties"][pname].get("type")
        out[pname] = (1 if kind == "integer" else ["x"] if kind == "array"
                      else False if kind == "boolean" else "x")
    return out


async def test_every_tool_that_takes_a_session_name_refuses_out_of_scope(
        monkeypatch, forbid_side_effects):
    """Derived from the tools, not a list: a tool added later with a `name` argument
    that the authorizer does not scope fails here."""
    monkeypatch.setenv(scope.ENV, "jointtest")
    checked = 0
    for tool in build_tools():
        props = tool.mcp_schema().input_schema["properties"]
        if tool.local_name == "session_create" or "name" not in props:
            continue
        result = await toolcall.call(tool.local_name, name="orchestrator", **_dummy_args(tool))
        assert result["ok"] is False, tool.local_name
        assert "outside this MCP server's scope" in result["error"], tool.local_name
        assert result["error_code"] == "out_of_scope", tool.local_name
        checked += 1
    assert checked >= len(NAMED_TOOLS)


async def test_the_authorizer_refuses_with_the_envelope_as_the_results_content(monkeypatch):
    # TRS-05: the refusal reads as 1.x's did; its code also rides the protocol result
    monkeypatch.setenv(scope.ENV, "jointtest")
    from threetears.mcp import ToolCall
    decision = await authz.AidcAuthorizer().authorize_call(authz.ADMIN, ToolCall(
        tool_name="session_status", arguments=MappingProxyType({"name": "orchestrator"}),
        required_permission=authz.PERMISSION))
    assert isinstance(decision, Refusal)
    assert decision.code == "out_of_scope" and decision.argument == "name"
    assert decision.content == {"ok": False, "error": decision.message,
                                "error_code": "out_of_scope"}


def test_the_context_is_passed_and_not_advertised_as_an_argument():
    """session_invoke is handed the call's context by the face, and `ctx` is not one of
    the arguments a client sees."""
    invoke = next(t for t in server.Face().listing() if t.name == "session_invoke")
    assert invoke.context_parameter is not None
    assert set(invoke.input_schema["properties"]) == {"name", "prompt"}


async def test_session_create_is_refused_when_scoped(monkeypatch, forbid_side_effects):
    """Even with the operator's opt-in, a scoped server refuses to create sessions."""
    monkeypatch.setenv(scope.ENABLE_CREATE_ENV, "true")
    monkeypatch.setenv(scope.ENV, "jointtest")
    result = await toolcall.call("session_create", name="jointtest", repo="/tmp")
    assert result["ok"] is False and "cannot create sessions" in result["error"]
    assert result["error_code"] == "create_not_allowed"


async def test_session_list_shows_only_allowed_sessions(monkeypatch):
    monkeypatch.setenv(scope.ENV, "jointtest")
    raw = ("SESSION   STATUS   PROFILE\n"
           "jointtest Up 1 min multi\n"
           "other     Up 2 days multi\n")
    monkeypatch.setattr(com, "run_cli", lambda args, timeout=60.0: {
        "exit": 0, "stdout": raw, "stderr": ""})
    out = (await toolcall.call("session_list"))["data"]["raw"]
    assert out == "SESSION   STATUS   PROFILE\njointtest Up 1 min multi\n"


async def test_in_scope_calls_go_through(monkeypatch, idle_session):
    monkeypatch.setenv(scope.ENV, "jointtest")
    monkeypatch.setattr(com, "run_cli", lambda args, timeout=60.0: {
        "exit": 0, "stdout": "status ok", "stderr": ""})
    res = await toolcall.call("session_status", name="jointtest")
    assert res["ok"] is True


def _request(uri, action="read", **variables):
    return ResourceRequest(uri=uri, variables=MappingProxyType(variables),
                           required_permission=authz.PERMISSION, action=action)


async def test_resources_refuse_outside_the_scope_and_hide_config(monkeypatch):
    monkeypatch.setenv(scope.ENV, "jointtest")
    monkeypatch.setattr(resources, "_run", lambda args: "SESSION X\norchestrator Up\njointtest Up\n")
    authorizer = authz.AidcAuthorizer()

    async def decide(uri, **variables):
        return await authorizer.authorize_resource(authz.ADMIN, _request(uri, **variables))
    for uri, variables in (("aidc://sessions/orchestrator/status", {"name": "orchestrator"}),
                           ("aidc://sessions/orchestrator/audit", {"name": "orchestrator"}),
                           ("aidc://sessions/orchestrator/audit/a",
                            {"name": "orchestrator", "filename": "a"})):
        decision = await decide(uri, **variables)
        assert isinstance(decision, Refusal) and "outside" in decision.message, uri
        assert decision.code == "out_of_scope"
    assert await decide("aidc://sessions/jointtest/status", name="jointtest") is True
    config = await decide("aidc://config")
    assert isinstance(config, Refusal) and config.code == "out_of_scope"
    # the session list is served, holding only the scope's sessions
    assert await decide("aidc://sessions") is True
    assert json.loads(await resources.list_all_sessions())["raw"] == "SESSION X\njointtest Up\n"


async def test_resume_leaves_other_sessions_queues_alone(monkeypatch, tmp_path):
    from aidc_mcp import transcript as ts
    monkeypatch.setenv(scope.ENV, "jointtest")
    ts.save_send_queue(ss.WATCHER_STATE_DIR, "orchestrator", [ts.QueuedPrompt("x", "t")])

    async def never(name):
        raise AssertionError("checked a session outside the scope")

    monkeypatch.setattr(tn, "session_instance", never)
    await snd.resume_send_queues()
    assert "orchestrator" not in ss.pending_sends
    assert ts.send_queue_path(ss.WATCHER_STATE_DIR, "orchestrator").exists()
