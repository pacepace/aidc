"""What an MCP client sees on the wire, through the real streamable-HTTP app.

server.build_app is what main() hands to uvicorn: the SDK's app behind the bearer
middleware and the startup hook. These tests speak JSON-RPC to it the way an
orchestrator does, so an SDK upgrade that changes the handshake, the tool list, the
auth gate or the Host check fails here rather than in a client.
"""
import json

import pytest
from starlette.testclient import TestClient

from aidc_mcp import auth, publish, resources, server, tools

TOKEN = "wire-test-token"
# A private-interface bind (ZeroTier/Tailscale): the Host a real client sends. The
# SDK's localhost-only allow-list would answer it with 421.
HOST = "10.147.17.5:7878"
ACCEPT = "application/json, text/event-stream"
LEGACY_VERSION = "2025-11-25"


@pytest.fixture
def client(tmp_path, monkeypatch):
    token_file = tmp_path / "mcp-token"
    token_file.write_text(TOKEN + "\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", token_file)

    async def no_resume(app):
        return None

    monkeypatch.setattr(tools, "resume_on_startup", no_resume)
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
    for name in tools._SESSION_AWARE_TOOLS:
        assert wire[name]["description"].endswith(tools._watching_suffix()), name


def test_a_tool_call_answers_with_the_envelope(client, monkeypatch):
    monkeypatch.setattr(tools, "_run_cli",
                        lambda args, **kw: {"exit": 0, "stdout": "SESSION\n", "stderr": ""})
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "session_list", "arguments": {}}}))
    result = msg["result"]
    assert result.get("isError") is not True
    body = json.loads(result["content"][0]["text"])
    assert body["ok"] is True


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
    monkeypatch.setattr(resources, "parse_audit_dir", lambda out: audit_dir)
    monkeypatch.setattr(resources, "_run", lambda args: "")
    _, sid = _initialize(client)
    msg = _rpc_result(client.post("/mcp", headers=_headers(sid), json={
        "jsonrpc": "2.0", "id": 6, "method": "resources/read",
        "params": {"uri": "aidc://sessions/proj/audit/.."}}))
    if "error" in msg:
        assert msg["error"]["code"] == -32602, msg
    else:
        text = msg["result"]["contents"][0]["text"]
        assert json.loads(text) == {"error": "path traversal denied"}, text
