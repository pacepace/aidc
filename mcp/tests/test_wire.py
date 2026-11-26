"""What an MCP client sees on the wire, through the real streamable-HTTP app.

server.build_app is what main() hands to uvicorn: 3tears-mcp's server behind the bearer
gate, with the startup resume in its lifespan. These tests speak JSON-RPC to it the way an
orchestrator does, so an SDK upgrade that changes the handshake, the tool list, the
auth gate or the Host check fails here rather than in a client.
"""
import json
import subprocess

import pytest
from starlette.testclient import TestClient

from aidc_mcp import auth, publish, resources, server, session_facts
from aidc_mcp.service import common as com
from aidc_mcp.tearstools import descriptions

TOKEN = "wire-test-token"
# A private-interface bind (ZeroTier/Tailscale): the Host a real client sends. The
# SDK's localhost-only allow-list would answer it with 421.
HOST = "10.0.0.5:7878"
ACCEPT = "application/json, text/event-stream"
LEGACY_VERSION = "2025-11-25"


@pytest.fixture
def client(tmp_path, monkeypatch):
    token_file = tmp_path / "mcp-token"
    token_file.write_text(TOKEN + "\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", token_file)

    async def no_resume(self):
        return None

    monkeypatch.setattr(server.Face, "resume", no_resume)
    with TestClient(server.build_app(), base_url=f"http://{HOST}") as c:
        yield c


def _headers(session_id=None, token=TOKEN):
    h = {"Accept": ACCEPT, "Content-Type": "application/json", "Host": HOST}
    if token is not None:
        h["Authorization"] = f"Bearer {token}"
    if session_id:
        h["Mcp-Session-Id"] = session_id
        h["Mcp-Protocol-Version"] = LEGACY_VERSION
    return h


def _rpc_result(resp):
    """The JSON-RPC message in a response, whether sent as JSON or as one SSE event."""
    assert resp.status_code == 200, (resp.status_code, resp.text)
    if resp.headers.get("content-type", "").startswith("application/json"):
        return resp.json()
    data = [ln[len("data:"):].strip() for ln in resp.text.splitlines() if ln.startswith("data:")]
    assert data, resp.text
    return json.loads(data[-1])


def _initialize(client):
    resp = client.post("/mcp", headers=_headers(), json={
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": LEGACY_VERSION, "capabilities": {},
                   "clientInfo": {"name": "wire-test", "version": "0"}},
    })
    msg = _rpc_result(resp)
    sid = resp.headers.get("mcp-session-id")
    assert sid, "a stateful server names the session"
    note = client.post("/mcp", headers=_headers(sid),
                       json={"jsonrpc": "2.0", "method": "notifications/initialized"})
    assert note.status_code in (200, 202), note.text
    return msg["result"], sid


def test_no_token_is_refused(client):
    resp = client.post("/mcp", headers=_headers(token=None), json={
        "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    assert resp.status_code == 401


def test_a_wrong_token_is_refused(client):
    resp = client.post("/mcp", headers=_headers(token="nope"), json={
        "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    assert resp.status_code == 401


def test_a_private_interface_host_is_served_and_the_handshake_names_aidc(client):
    result, _ = _initialize(client)
    assert result["protocolVersion"] == LEGACY_VERSION
    assert result["serverInfo"]["name"] == "aidc"
    assert result["instructions"].startswith("Control plane for the aidc sandbox.")
    assert "tools" in result["capabilities"]
    assert "resources" in result["capabilities"]


def test_tools_list_on_the_wire_is_the_published_list(client):
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}))
    wire = {t["name"]: t for t in msg["result"]["tools"]}
    published = {t["name"]: t for t in json.loads(publish.PUBLISHED.read_text(encoding="utf-8"))
                 # session_create is offered only when the operator turns it on
                 if t["name"] in wire}
    assert set(wire) == set(published)
    for name, pub in published.items():
        assert wire[name]["inputSchema"] == pub["input_schema"], name
        # Exact: an orchestrator's model reads all of it, the open-webhook suffix included.
        assert wire[name]["description"] == pub["description"], name
    for name in ("session_send", "session_invoke", "session_invoke_async"):
        assert wire[name]["description"].endswith(descriptions.watching_suffix()), name


def test_a_tool_call_answers_with_the_envelope(client, monkeypatch):
    monkeypatch.setattr(com, "run_cli",
                        lambda args, **kw: {"exit": 0, "stdout": "SESSION\n", "stderr": ""})
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "session_list", "arguments": {}}}))
    result = msg["result"]
    assert result.get("isError") is not True
    body = json.loads(result["content"][0]["text"])
    assert body["ok"] is True
    # design-10 D6: the envelope is sent twice, as text and as structured content
    assert result["structuredContent"] == body


def test_resources_and_templates_are_listed(client):
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 4, "method": "resources/list", "params": {}}))
    assert {r["uri"] for r in msg["result"]["resources"]} == {"aidc://sessions", "aidc://config"}
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 5, "method": "resources/templates/list", "params": {}}))
    assert {t["uriTemplate"] for t in msg["result"]["resourceTemplates"]} == {
        "aidc://sessions/{name}/status",
        "aidc://sessions/{name}/audit",
        "aidc://sessions/{name}/audit/{filename}",
    }


def test_an_audit_file_outside_the_audit_dir_is_never_read(client, monkeypatch, tmp_path):
    """`..` as the filename: the SDK refuses it as an unknown resource before aidc's
    own traversal check runs. Either refusal will do; reading the parent will not."""
    audit_dir = tmp_path / "audit"
    audit_dir.mkdir()
    (tmp_path / "secret").write_text("TOPSECRET", encoding="utf-8")

    def sidecar(argv):
        # The audit sidecar, played here: its script runs against audit_dir in place of
        # its mount (tests/test_resources.py has the same stand-in).
        inner = argv[argv.index("sh"):] if "sh" in argv else ["true"]
        inner = [str(audit_dir) if a == session_facts.AUDIT_MOUNT else a for a in inner]
        return subprocess.run(inner, capture_output=True, check=False)
    monkeypatch.setattr(resources, "_backend_run", sidecar)
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 6, "method": "resources/read",
        "params": {"uri": "aidc://sessions/proj/audit/.."}}))
    if "error" in msg:
        assert msg["error"]["code"] == -32602, msg
    else:
        text = msg["result"]["contents"][0]["text"]
        assert json.loads(text) == {"error": "path traversal denied"}, text
        assert "TOPSECRET" not in text


def test_session_send_offers_deliver_with_queue_as_the_default(client):
    """deliver is optional and additive: a client that never sends it gets today's
    queueing, and a schema-validating client sees the two values it may send."""
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": {}}))
    send = next(t for t in msg["result"]["tools"] if t["name"] == "session_send")
    schema = send["inputSchema"]
    assert schema["properties"]["deliver"]["enum"] == ["queue", "join"]
    assert schema["properties"]["deliver"]["default"] == "queue"
    assert "deliver" not in schema.get("required", [])
    assert set(schema["required"]) == {"name", "prompt"}


def test_session_interrupt_offers_target_with_the_agent_as_the_default(client):
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 8, "method": "tools/list", "params": {}}))
    tool = next(t for t in msg["result"]["tools"] if t["name"] == "session_interrupt")
    target = tool["inputSchema"]["properties"]["target"]
    assert target["enum"] == ["agent", "headless"] and target["default"] == "agent"
    assert tool["inputSchema"]["required"] == ["name"]


def test_the_handshake_steers_long_work_to_session_send(client):
    result, _ = _initialize(client)
    assert "session_send" in result["instructions"]
    assert "session_invoke is only for short, single-shot questions" in result["instructions"]


# --- the error model on the wire (TRS-05) ------------------------------------------

ERROR_META = "threetears.mcp/error"


def _call(client, sid, name, arguments, rid=20, token=TOKEN):
    return client.post("/mcp", headers=_headers(sid, token=token), json={
        "jsonrpc": "2.0", "id": rid, "method": "tools/call",
        "params": {"name": name, "arguments": arguments}})


@pytest.mark.parametrize("code", sorted(com.ERROR_CODES))
def test_every_aidc_code_is_the_protocol_code_of_its_failed_call(client, monkeypatch, code):
    """The envelope stays the content, unchanged; the same code rides the protocol result,
    with whether the same call can succeed later."""
    from aidc_mcp.service import sessions as ses

    async def status(name):
        return com.envelope_err(f"failed with {code}", code=code)
    monkeypatch.setattr(ses, "status", status)
    _, sid = _initialize(client)
    result = _rpc_result(_call(client, sid, "session_status", {"name": "proj"}))["result"]
    assert result["isError"] is True
    envelope = {"ok": False, "error": f"failed with {code}", "error_code": code}
    assert json.loads(result["content"][0]["text"]) == envelope
    # design-10 D6: the envelope is sent twice, failures included
    assert result["structuredContent"] == envelope
    detail = result["_meta"][ERROR_META]
    assert detail["code"] == code
    assert detail["retryable"] is (code in com.RETRYABLE_ERROR_CODES)


def test_an_out_of_scope_call_is_refused_before_the_tool_with_the_envelope(client, monkeypatch):
    from aidc_mcp import scope
    from aidc_mcp.service import sessions as ses

    async def status(name):
        raise AssertionError("an out-of-scope call reached the tool")
    monkeypatch.setattr(ses, "status", status)
    monkeypatch.setenv(scope.ENV, "jointtest")
    _, sid = _initialize(client)
    result = _rpc_result(_call(client, sid, "session_status", {"name": "other"}))["result"]
    body = json.loads(result["content"][0]["text"])
    assert result["isError"] is True and body["error_code"] == "out_of_scope"
    assert body["ok"] is False and "outside this MCP server's scope" in body["error"]
    assert result["_meta"][ERROR_META]["code"] == "out_of_scope"
    assert result["_meta"][ERROR_META]["argument"] == "name"


def test_a_tainted_session_is_refused_with_the_taint_in_the_envelope(client, monkeypatch):
    from aidc_mcp import session_facts as sf

    async def tainted(name):
        return {"at": "2026-10-14T09:00:00Z", "trigger": "blocklist", "domain": "evil.example"}
    monkeypatch.setattr(sf, "read_taint", tainted)
    _, sid = _initialize(client)
    result = _rpc_result(_call(client, sid, "session_exec", {"name": "proj", "cmd": "id"}))
    result = result["result"]
    body = json.loads(result["content"][0]["text"])
    assert body["error_code"] == "tainted" and body["data"]["tainted"]["domain"] == "evil.example"
    assert result["_meta"][ERROR_META]["code"] == "tainted"


def test_arguments_the_schema_refuses_answer_invalid_arguments_naming_the_argument(client):
    _, sid = _initialize(client)
    result = _rpc_result(_call(client, sid, "session_status", {}))["result"]
    assert result["isError"] is True
    assert result["_meta"][ERROR_META]["code"] == "INVALID_ARGUMENTS"
    assert result["_meta"][ERROR_META]["argument"] == "name"


# --- the bearer on an open session (TRS-08, MCP-06) ---------------------------------

def test_a_rotated_token_refuses_the_open_session_on_its_next_message(client, tmp_path,
                                                                      monkeypatch):
    """`aidc mcp token rotate` writes a new token: the session opened with the old one is
    refused on its next message, and no tool runs."""
    ran = []
    monkeypatch.setattr(com, "run_cli", lambda args, **kw: ran.append(args) or {
        "exit": 0, "stdout": "SESSION\n", "stderr": ""})
    _, sid = _initialize(client)
    assert _rpc_result(_call(client, sid, "session_list", {}))["result"].get("isError") is not True
    assert ran
    ran.clear()
    (tmp_path / "mcp-token").write_text("rotated-token\n", encoding="utf-8")

    refused = _call(client, sid, "session_list", {}, rid=21)
    assert refused.status_code == 401
    assert ran == []
    # the new token is served at once, without a restart
    served = _call(client, sid, "session_list", {}, rid=22, token="rotated-token")
    assert served.status_code in (200, 404), served.text  # 404: the transport's own session


async def test_the_servers_own_resolver_refuses_a_token_that_is_not_current(tmp_path,
                                                                           monkeypatch):
    # the gate in front answers 401 first; the server's resolver holds the same line, so a
    # request that reached it with an old token would still run nothing
    from aidc_mcp import authz
    token_file = tmp_path / "mcp-token"
    token_file.write_text("old\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", token_file)
    assert (await authz.resolve_identity("old")).is_admin
    token_file.write_text("new\n", encoding="utf-8")
    with pytest.raises(RuntimeError):
        await authz.resolve_identity("old")
    assert (await authz.resolve_identity("new")).is_admin


# --- local mode needs nothing of the platform (TRS-01) -------------------------------

_FRESH = r"""
import json, os, sys, pathlib, socket, tempfile
# every connection the process opens, from the first import on (the in-process test client
# opens none)
connections = []
_connect = socket.socket.connect
def _recording_connect(self, address):
    connections.append(repr(address))
    return _connect(self, address)
socket.socket.connect = _recording_connect
tmp = tempfile.mkdtemp()
pathlib.Path(tmp, "token").write_text("t\n")
os.environ["AIDC_MCP_TOKEN_FILE"] = str(pathlib.Path(tmp, "token"))
os.environ["AIDC_MCP_AUDIT_LOG"] = str(pathlib.Path(tmp, "access.log"))
os.environ["AIDC_MCP_SESSION_CREATE"] = "true"
# the state store in a dir of its own; startup resumes from it (empty: nothing to resume)
os.environ["AIDC_MCP_WATCHER_STATE"] = str(pathlib.Path(tmp, "watcher-state"))
from starlette.testclient import TestClient
from aidc_mcp import server
H = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json",
     "Authorization": "Bearer t"}
def rpc(resp):
    if resp.headers.get("content-type", "").startswith("application/json"):
        return resp.json()
    return json.loads([l[5:] for l in resp.text.splitlines() if l.startswith("data:")][-1])
with TestClient(server.build_app()) as c:
    r = c.post("/mcp", headers=H, json={"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                   "clientInfo": {"name": "fresh", "version": "0"}}})
    h = {**H, "Mcp-Session-Id": r.headers["mcp-session-id"], "Mcp-Protocol-Version": "2025-11-25"}
    c.post("/mcp", headers=h, json={"jsonrpc": "2.0", "method": "notifications/initialized"})
    tools = rpc(c.post("/mcp", headers=h, json={"jsonrpc": "2.0", "id": 2,
                                                 "method": "tools/list"}))["result"]["tools"]
    answered = 0
    for i, t in enumerate(tools):
        # every tool is called; with no arguments most are refused by their schema, which
        # still runs the whole call path (identity, authorizer, dispatch)
        out = rpc(c.post("/mcp", headers=h, json={"jsonrpc": "2.0", "id": 10 + i,
                  "method": "tools/call", "params": {"name": t["name"], "arguments": {}}}))
        answered += "result" in out
import importlib.metadata
try:
    importlib.metadata.distribution("nats-py")
    nats_installed = True
except importlib.metadata.PackageNotFoundError:
    nats_installed = False
print(json.dumps({"tools": len(tools), "answered": answered, "modules": sorted(sys.modules),
                  "nats_installed": nats_installed, "connections": connections}))
"""


def test_local_mode_starts_lists_and_calls_every_tool_with_nothing_of_the_platform():
    import subprocess
    import sys
    out = subprocess.run([sys.executable, "-c", _FRESH], capture_output=True, text=True,
                         timeout=120)
    assert out.returncode == 0, out.stderr[-2000:]
    report = json.loads(out.stdout.strip().splitlines()[-1])
    assert report["tools"] == len(json.loads(publish.PUBLISHED.read_text(encoding="utf-8")))
    assert report["answered"] == report["tools"]
    # TRS-01 (amended 2026-11-26): 3tears core's SQLite L3 (aidc's state store) is loaded,
    # with asyncpg for its error types; no NATS client (`nats`), no Postgres driver besides
    # it, no LangGraph or LangChain, no 3tears registry. 3tears core imports its own
    # threetears.nats modules (error types, subject names), which hold no client (TRS-01's
    # amendment allows them, as long as the client is neither installed nor imported)
    forbidden = [m for m in report["modules"]
                 if m.split(".")[0] in {"nats", "psycopg", "psycopg2", "langgraph",
                                        "langchain", "langchain_core", "fastmcp"}
                 or m.startswith("threetears.registry")]
    assert forbidden == []
    assert "threetears.core.backends.sqlite_file" in report["modules"]
    assert report["nats_installed"] is False      # the NATS client is not even installed
    assert report["connections"] == []            # nothing connects anywhere


def test_aidc_uses_neither_fastmcp_nor_the_sdks_high_level_server():
    # The SDK's own package imports its high-level server, so the module is loaded either
    # way; what TRS-01 rules out is aidc serving through it.
    import pathlib
    src = pathlib.Path(server.__file__).parent
    users = [str(p.relative_to(src)) for p in src.rglob("*.py")
             if any(n in p.read_text(encoding="utf-8")
                    for n in ("mcpserver", "MCPServer", "FastMCP", "fastmcp"))]
    assert users == []


# --- resources through the server: the scope is the authorizer's (MCP-31, TRS-06) ----

def _resource_read(client, sid, uri, rid=40):
    return _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": rid, "method": "resources/read", "params": {"uri": uri}}))


def test_a_scoped_server_refuses_another_sessions_resource_before_reading_it(client, monkeypatch):
    from aidc_mcp import scope
    monkeypatch.setenv(scope.ENV, "jointtest")
    monkeypatch.setattr(resources, "_run",
                        lambda args: (_ for _ in ()).throw(AssertionError("read it")))
    _, sid = _initialize(client)
    msg = _resource_read(client, sid, "aidc://sessions/other/status")
    assert msg["error"]["data"]["code"] == "out_of_scope"
    assert "outside" in msg["error"]["message"]


def test_a_scoped_server_serves_its_own_sessions_resource(client, monkeypatch):
    from aidc_mcp import scope
    monkeypatch.setenv(scope.ENV, "jointtest")
    monkeypatch.setattr(resources, "_run", lambda args: "status ok")
    _, sid = _initialize(client)
    msg = _resource_read(client, sid, "aidc://sessions/jointtest/status")
    assert json.loads(msg["result"]["contents"][0]["text"]) == {"raw": "status ok"}


def test_a_scoped_server_neither_lists_nor_serves_the_config(client, monkeypatch):
    from aidc_mcp import scope
    monkeypatch.setenv(scope.ENV, "jointtest")
    _, sid = _initialize(client)
    listed = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 41, "method": "resources/list", "params": {}}))
    assert {r["uri"] for r in listed["result"]["resources"]} == {"aidc://sessions"}
    assert _resource_read(client, sid, "aidc://config", rid=42)["error"]["data"]["code"] == \
        "out_of_scope"


def test_a_scoped_server_refuses_a_subscription_to_another_session(client, monkeypatch):
    from aidc_mcp import scope
    monkeypatch.setenv(scope.ENV, "jointtest")
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 43, "method": "resources/subscribe",
        "params": {"uri": "aidc://sessions/other/status"}}))
    assert msg["error"]["data"]["code"] == "out_of_scope"


# --- what 1.x accepted, 2.0 still accepts ---------------------------------------------

def test_a_null_optional_argument_is_accepted_as_not_given(client, monkeypatch):
    """1.x took null for an optional argument as "not given". The schema 3tears checks
    every call against keeps null legal there, so such a call is not refused."""
    from aidc_mcp.service import sessions as ses
    seen = {}

    async def audit_get(name, since=None, kind=None):
        seen.update(since=since, kind=kind)
        return com.envelope_ok({"events": []})
    monkeypatch.setattr(ses, "audit_get", audit_get)
    _, sid = _initialize(client)
    result = _rpc_result(_call(client, sid, "audit_get",
                               {"name": "proj", "since": None, "kind": None}))["result"]
    assert result.get("isError") is not True, result
    assert seen == {"since": None, "kind": None}


def test_an_integer_sent_as_text_is_taken_as_the_number(client, monkeypatch):
    """1.x read "3" for an integer argument as 3; the listed schema stays `integer`."""
    from aidc_mcp.service import sessions as ses
    seen = {}

    async def transcript(name, last_n=5, since_uuid=""):
        seen.update(last_n=last_n)
        return com.envelope_ok({"turns": []})
    monkeypatch.setattr(ses, "transcript", transcript)
    _, sid = _initialize(client)
    result = _rpc_result(_call(client, sid, "session_transcript",
                               {"name": "proj", "last_n": "3"}))["result"]
    assert result.get("isError") is not True, result
    assert seen == {"last_n": 3}


def test_text_that_is_not_a_whole_number_is_still_refused_by_the_schema(client):
    _, sid = _initialize(client)
    for bad in ("3.5", "three", " 3", ""):
        result = _rpc_result(_call(client, sid, "session_transcript",
                                   {"name": "proj", "last_n": bad}))["result"]
        assert result["_meta"][ERROR_META]["code"] == "INVALID_ARGUMENTS", bad
        assert result["_meta"][ERROR_META]["argument"] == "last_n", bad


def test_the_listed_schema_still_says_integer(client):
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 50, "method": "tools/list", "params": {}}))
    tool = next(t for t in msg["result"]["tools"] if t["name"] == "session_transcript")
    assert tool["inputSchema"]["properties"]["last_n"]["type"] == "integer"


# --- progress and log lines before the result (TRS-04, MCP-07) ------------------------

def _messages(resp):
    """Every JSON-RPC message in an SSE response, in order."""
    assert resp.status_code == 200, resp.text
    return [json.loads(ln[len("data:"):].strip()) for ln in resp.text.splitlines()
            if ln.startswith("data:") and ln[len("data:"):].strip()]


@pytest.mark.parametrize("tool,arguments", [
    ("session_create", {"name": "proj", "repo": "/r"}),
    ("session_invoke", {"name": "proj", "prompt": "q"}),
])
def test_each_phase_reaches_the_caller_as_progress_and_a_log_line_before_the_result(
        tmp_path, monkeypatch, tool, arguments):
    from aidc_mcp import scope
    from aidc_mcp.service import invoke as inv
    from aidc_mcp.service import sessions as ses
    monkeypatch.setenv(scope.ENABLE_CREATE_ENV, "true")
    token_file = tmp_path / "mcp-token"
    token_file.write_text(TOKEN + "\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", token_file)

    async def no_resume(self):
        return None
    monkeypatch.setattr(server.Face, "resume", no_resume)

    async def phases(*, progress, **kwargs):
        await progress("container: Container aidc-proj-dev Started")
        await progress("healthy: Healthy")
        return com.envelope_ok({"done": True})
    monkeypatch.setattr(ses, "create", phases)

    async def invoke(*, name, prompt, progress):
        return await phases(progress=progress)
    monkeypatch.setattr(inv, "invoke", invoke)

    with TestClient(server.build_app(), base_url=f"http://{HOST}") as c:
        _, sid = _initialize(c)
        resp = c.post("/mcp", headers=_headers(sid), json={
            "jsonrpc": "2.0", "id": 60, "method": "tools/call",
            "params": {"name": tool, "arguments": arguments, "_meta": {"progressToken": "p-1"}}})
    msgs = _messages(resp)
    kinds = [m.get("method") or ("result" if "result" in m else "other") for m in msgs]
    assert kinds[-1] == "result", kinds
    progress = [m["params"] for m in msgs if m.get("method") == "notifications/progress"]
    logged = [m["params"]["data"] for m in msgs if m.get("method") == "notifications/message"]
    assert [p["progress"] for p in progress] == [1, 2]
    assert all(p["progressToken"] == "p-1" for p in progress)
    assert progress[0]["message"].startswith("container:")
    assert logged == ["container: Container aidc-proj-dev Started", "healthy: Healthy"]
