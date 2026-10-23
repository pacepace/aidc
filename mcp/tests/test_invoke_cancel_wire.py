"""What stops a session_invoke whose caller has gone, through the real transport.

2026-10-22 23:04Z, metallm: Pace pressed stop on a session_invoke in metallm's UI;
aidc-mcp logged nothing, and the host's docker exec and the claude run inside the
container both went on. These tests serve server.build_app() with uvicorn on a local
port and speak to it with a real HTTP client, the way an orchestrator does, then end
the call each way a client can: a `notifications/cancelled`, closing the session
(DELETE), and dropping the connection. Docker is faked: the run is a process that
never ends by itself, and stopping it in the container is recorded.

Measured on MCP SDK 2.3 with the 2025-11-25 protocol: the SDK cancels the handler on a
cancel notification and on DELETE, but not on a dropped connection; the handler then
runs on with nobody to answer. disconnect.StopInvokeOnDisconnect covers that case. A
client that abandons a call without any of the three (metallm's stop button, on the
evidence of 23:04Z) cannot be seen; the one-run-per-session guard and session_status's
headless_runs are what is left for it.
"""
import asyncio
import socket
import threading
import time

import httpx
import pytest
import uvicorn

from aidc_mcp import auth, headless, server, tools

TOKEN = "cancel-wire-token"
HOST = "10.147.17.5:7878"
VERSION = "2025-11-25"


class _Endless:
    """A docker exec whose claude never answers until it is killed."""

    def __init__(self, started: threading.Event):
        self.returncode = None
        self.killed = threading.Event()
        started.set()
        self.stdout = self._lines()
        self.stderr = self._lines()

    async def _lines(self):
        while not self.killed.is_set():
            await asyncio.sleep(0.05)
        if False:
            yield b""

    def kill(self):
        self.returncode = -9
        self.killed.set()

    async def wait(self):
        while not self.killed.is_set():
            await asyncio.sleep(0.05)
        return self.returncode


@pytest.fixture
def served(tmp_path, monkeypatch):
    token_file = tmp_path / "mcp-token"
    token_file.write_text(TOKEN + "\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", token_file)

    async def no_resume(app):
        return None

    monkeypatch.setattr(tools, "resume_on_startup", no_resume)
    state = {"started": threading.Event(), "stopped": threading.Event(), "procs": [],
             "events": []}

    async def create(*args, **kwargs):
        proc = _Endless(state["started"])
        state["procs"].append(proc)
        return proc

    async def no_runs(container):
        return []

    async def stop(container, run):
        state["stopped"].set()
        return [4242]

    real_log = tools.log_event

    def log(kind, **fields):
        state["events"].append((kind, fields))
        real_log(kind, **fields)

    monkeypatch.setattr(tools.asyncio, "create_subprocess_exec", create)
    monkeypatch.setattr(headless, "container_runs", no_runs)
    monkeypatch.setattr(headless, "stop", stop)
    monkeypatch.setattr(tools, "log_event", log)

    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    config = uvicorn.Config(server.build_app(), host="127.0.0.1", port=port, log_level="error",
                            lifespan="on")
    srv = uvicorn.Server(config)
    thread = threading.Thread(target=srv.run, daemon=True)
    thread.start()
    for _ in range(100):
        if srv.started:
            break
        time.sleep(0.05)
    state["url"] = f"http://127.0.0.1:{port}/mcp"
    yield state
    for proc in state["procs"]:
        proc.kill()
    srv.should_exit = True
    thread.join(timeout=10)
    headless._runs.clear()


def _headers(sid=None):
    h = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json",
         "Host": HOST, "Authorization": f"Bearer {TOKEN}"}
    if sid:
        h["Mcp-Session-Id"] = sid
        h["Mcp-Protocol-Version"] = VERSION
    return h


def _open_session(url):
    with httpx.Client(timeout=10) as c:
        r = c.post(url, headers=_headers(), json={
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": VERSION, "capabilities": {},
                       "clientInfo": {"name": "cancel-test", "version": "0"}}})
        sid = r.headers["mcp-session-id"]
        c.post(url, headers=_headers(sid),
               json={"jsonrpc": "2.0", "method": "notifications/initialized"})
    return sid


def _start_invoke(url, sid, result, *, drop=None):
    """Call session_invoke on its own connection; `drop` (an Event) closes that
    connection from the client side without a word."""
    def call():
        with httpx.Client(timeout=30) as c:
            with c.stream("POST", url, headers=_headers(sid), json={
                    "jsonrpc": "2.0", "id": 7, "method": "tools/call",
                    "params": {"name": "session_invoke",
                               "arguments": {"name": "proj", "prompt": "edit the spec"}}}) as r:
                if drop is not None:
                    drop.wait(10)
                    return
                result.append(r.read())
    t = threading.Thread(target=call, daemon=True)
    t.start()
    return t


def test_a_cancel_notification_stops_the_run_in_the_container(served):
    sid = _open_session(served["url"])
    _start_invoke(served["url"], sid, [])
    assert served["started"].wait(10)
    with httpx.Client(timeout=10) as c:
        c.post(served["url"], headers=_headers(sid), json={
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": {"requestId": 7, "reason": "user pressed stop"}})
    assert served["stopped"].wait(10), "the in-container run was not stopped"
    kinds = [k for k, _ in served["events"]]
    assert "session_invoke_cancelled" in kinds
    assert served["procs"][0].killed.wait(5)   # and the host's docker exec


def test_closing_the_session_stops_the_run_in_the_container(served):
    sid = _open_session(served["url"])
    _start_invoke(served["url"], sid, [])
    assert served["started"].wait(10)
    with httpx.Client(timeout=10) as c:
        c.delete(served["url"], headers=_headers(sid))
    assert served["stopped"].wait(10), "the in-container run was not stopped"


def test_a_dropped_connection_stops_the_run_in_the_container(served):
    sid = _open_session(served["url"])
    drop = threading.Event()
    _start_invoke(served["url"], sid, [], drop=drop)
    assert served["started"].wait(10)
    drop.set()
    assert served["stopped"].wait(10), "the in-container run was not stopped"
