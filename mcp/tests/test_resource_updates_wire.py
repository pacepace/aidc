"""A live resource's subscribers hear when it changes (MCP-09, TRS-06), through the real
transport: uvicorn serving server.build_app(), a real HTTP client subscribing on its
stateful session and listening on the session's standalone stream, as a client does."""
import json
import socket
import threading
import time

import httpx
import pytest
import uvicorn

from aidc_mcp import auth, resources, server
from aidc_mcp.service import common as com
from aidc_mcp.service import sessions as ses
from aidc_mcp.service import state as ss

TOKEN = "updates-wire-token"


@pytest.fixture
def served(tmp_path, monkeypatch):
    token_file = tmp_path / "mcp-token"
    token_file.write_text(TOKEN + "\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", token_file)
    monkeypatch.setattr(resources, "_run", lambda args: "status ok")

    async def no_resume(self):
        return None
    monkeypatch.setattr(server.Face, "resume", no_resume)
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    srv = uvicorn.Server(uvicorn.Config(server.build_app(), host="127.0.0.1", port=port,
                                        log_level="error", lifespan="on"))
    thread = threading.Thread(target=srv.run, daemon=True)
    thread.start()
    for _ in range(100):
        if srv.started:
            break
        time.sleep(0.05)
    yield f"http://127.0.0.1:{port}/mcp"
    srv.should_exit = True
    thread.join(timeout=10)


def _rpc(resp):
    if "event-stream" in resp.headers.get("content-type", ""):
        return json.loads([ln[5:] for ln in resp.text.splitlines() if ln.startswith("data:")][-1])
    return resp.json()


def _session(url):
    h = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json",
         "Authorization": f"Bearer {TOKEN}"}
    with httpx.Client(timeout=10) as c:
        r = c.post(url, headers=h, json={
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                       "clientInfo": {"name": "updates-test", "version": "0"}}})
        h = {**h, "Mcp-Session-Id": r.headers["mcp-session-id"],
             "Mcp-Protocol-Version": "2025-11-25"}
        c.post(url, headers=h, json={"jsonrpc": "2.0", "method": "notifications/initialized"})
    return h


def _listen_once(url, h, uri, monkeypatch, changed="proj"):
    """Subscribe to `uri`, then make the service report `changed`; the first message the
    session's standalone stream carries, or None when nothing came."""
    with httpx.Client(timeout=10) as c:
        sub = _rpc(c.post(url, headers=h, json={
            "jsonrpc": "2.0", "id": 2, "method": "resources/subscribe", "params": {"uri": uri}}))
    assert sub.get("result") == {}, sub
    got, listening = [], threading.Event()

    def listen():
        with httpx.Client(timeout=10) as c2:
            with c2.stream("GET", url, headers={**h, "Accept": "text/event-stream"}) as r:
                listening.set()
                for line in r.iter_lines():
                    if line.startswith("data:"):
                        got.append(json.loads(line[5:]))
                        return
    threading.Thread(target=listen, daemon=True).start()
    assert listening.wait(5)
    time.sleep(0.2)

    async def status(name):
        com.session_changed(changed)
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "status", status)
    with httpx.Client(timeout=10) as c:
        c.post(url, headers=h, json={"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                     "params": {"name": "session_status",
                                                "arguments": {"name": "proj"}}})
    for _ in range(30):
        if got:
            break
        time.sleep(0.05)
    return got[0] if got else None


def test_a_subscriber_to_the_session_list_is_told_when_any_session_changes(served, monkeypatch):
    msg = _listen_once(served, _session(served), "aidc://sessions", monkeypatch)
    assert msg == {"jsonrpc": "2.0", "method": "notifications/resources/updated",
                   "params": {"uri": "aidc://sessions"}}


def test_a_scoped_server_says_nothing_of_a_session_outside_its_scope(served, monkeypatch):
    # its clients may list only the scope's sessions, so they do not hear when others change
    from aidc_mcp import scope
    monkeypatch.setenv(scope.ENV, "proj")
    assert _listen_once(served, _session(served), "aidc://sessions", monkeypatch,
                        changed="other") is None
    assert _listen_once(served, _session(served), "aidc://sessions", monkeypatch,
                        changed="proj") is not None


def test_a_subscriber_is_told_when_a_sessions_status_changes(served, monkeypatch):
    """When the service says a session changed (a prompt pasted, a turn delivered, the
    session created or interrupted: com.session_changed), a client subscribed to its
    status is sent `notifications/resources/updated` with the URI."""
    h = _session(served)
    with httpx.Client(timeout=10) as c:
        sub = _rpc(c.post(served, headers=h, json={
            "jsonrpc": "2.0", "id": 2, "method": "resources/subscribe",
            "params": {"uri": "aidc://sessions/proj/status"}}))
    assert sub.get("result") == {}, sub
    got, listening = [], threading.Event()

    def listen():
        with httpx.Client(timeout=10) as c2:
            with c2.stream("GET", served, headers={**h, "Accept": "text/event-stream"}) as r:
                listening.set()
                for line in r.iter_lines():
                    if line.startswith("data:"):
                        got.append(json.loads(line[5:]))
                        return
    threading.Thread(target=listen, daemon=True).start()
    assert listening.wait(5)
    time.sleep(0.2)

    # a tool call whose service work reports a change, run on the server's own loop
    async def status(name):
        com.session_changed(name)
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "status", status)
    with httpx.Client(timeout=10) as c:
        c.post(served, headers=h, json={"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                        "params": {"name": "session_status",
                                                   "arguments": {"name": "proj"}}})
    for _ in range(50):
        if got:
            break
        time.sleep(0.05)
    assert got == [{"jsonrpc": "2.0", "method": "notifications/resources/updated",
                    "params": {"uri": "aidc://sessions/proj/status"}}]


def test_the_listener_is_registered_only_while_the_server_runs(tmp_path, monkeypatch):
    from starlette.testclient import TestClient
    token_file = tmp_path / "mcp-token"
    token_file.write_text(TOKEN + "\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", token_file)
    monkeypatch.setattr(ss, "session_change_listeners", [])

    async def no_resume(self):
        return None
    monkeypatch.setattr(server.Face, "resume", no_resume)
    face = server.Face()
    with TestClient(server.build_app(face)):
        assert ss.session_change_listeners == [face.session_changed]
    assert ss.session_change_listeners == []


def test_a_failing_listener_is_logged_and_the_work_goes_on(monkeypatch):
    from aidc_mcp import audit

    def broken(name):
        raise RuntimeError("gone")
    monkeypatch.setattr(ss, "session_change_listeners", [broken])
    com.session_changed("proj")
    assert "session_change_notify_failed" in audit._AUDIT_PATH.read_text()
