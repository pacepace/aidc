"""Observability on 3tears-observe (TRS-14): a correlation id on every log line of one tool
call, one span per call, and nothing exported (no network) unless configured."""
import logging
import socket

import pytest
from starlette.testclient import TestClient
from threetears.observe import get_context

from aidc_mcp import audit, auth, observability, server
from aidc_mcp.service import common as com
from aidc_mcp.service import sessions as ses
from tests import toolcall


class _Lines(logging.Handler):
    """Every log record with the observe context it was logged in."""

    def __init__(self):
        super().__init__()
        self.lines = []

    def emit(self, record):
        self.lines.append((record.getMessage(), get_context()))


@pytest.fixture
def lines():
    handler = _Lines()
    logger = logging.getLogger("aidc_mcp")
    logger.addHandler(handler)
    old = logger.level
    logger.setLevel(logging.INFO)
    yield handler.lines
    logger.removeHandler(handler)
    logger.setLevel(old)


async def test_every_log_line_of_one_call_carries_its_correlation_id(lines, monkeypatch):
    async def status(name):
        audit.log_event("tool_call", tool="session_status", session=name)
        audit.log_event("status_read", session=name)
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "status", status)
    await toolcall.call("session_status", name="a")
    await toolcall.call("session_status", name="b")
    first, second = lines[:2], lines[2:4]
    assert [m for m, _ in first] == ["tool_call", "status_read"]
    cids = {ctx["cid"] for _, ctx in first}
    assert len(cids) == 1 and all(ctx["tool"] == "session_status" for _, ctx in first)
    assert {ctx["cid"] for _, ctx in second} != cids      # a call of its own, an id of its own
    assert "cid" not in get_context()                     # nothing left behind after a call


async def test_each_call_is_one_span_named_for_tool_calls(monkeypatch):
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    monkeypatch.setattr(trace, "get_tracer", lambda *a, **k: provider.get_tracer("t"))

    async def status(name):
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "status", status)
    await toolcall.call("session_status", name="a")
    [span] = exporter.get_finished_spans()
    assert span.name == observability.TOOL_SPAN
    assert span.attributes["aidc.tool"] == "session_status"
    assert len(span.attributes["ctx.cid"]) == 32 and span.attributes["ctx.tool"] == "session_status"


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    token_file = tmp_path / "mcp-token"
    token_file.write_text("t\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", token_file)

    async def no_resume(self):
        return None
    monkeypatch.setattr(server.Face, "resume", no_resume)

    def make():
        return TestClient(server.build_app(), base_url="http://10.0.0.5:7878")
    return make


H = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json",
     "Authorization": "Bearer t"}


def _one_call(client):
    r = client.post("/mcp", headers=H, json={
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                   "clientInfo": {"name": "obs", "version": "0"}}})
    h = {**H, "Mcp-Session-Id": r.headers["mcp-session-id"], "Mcp-Protocol-Version": "2025-11-25"}
    client.post("/mcp", headers=h, json={"jsonrpc": "2.0", "method": "notifications/initialized"})
    return client.post("/mcp", headers=h, json={
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": "session_status", "arguments": {"name": "proj"}}})


def test_with_export_off_a_tool_call_opens_no_network_connection(app_client, monkeypatch):
    for env in (observability.OTEL_ENDPOINT_ENV, observability.METRICS_ENV):
        monkeypatch.delenv(env, raising=False)
    # an exporter would connect later, from its batch thread: off, none is ever set up
    import threetears.observe.setup as setup
    monkeypatch.setattr(setup, "init_telemetry",
                        lambda config: (_ for _ in ()).throw(AssertionError("export set up")))
    observability.configure()

    async def status(name):
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "status", status)
    opened = []
    real_connect = socket.socket.connect

    def connect(self, address):
        opened.append(address)
        return real_connect(self, address)
    monkeypatch.setattr(socket.socket, "connect", connect)
    monkeypatch.setattr(socket.socket, "connect_ex",
                        lambda self, address: opened.append(address) or 111)
    with app_client() as c:
        assert _one_call(c).status_code == 200
    assert opened == []


def test_an_otel_endpoint_turns_on_export_to_it_and_nothing_else(monkeypatch):
    seen = []
    import threetears.observe.setup as setup
    monkeypatch.setattr(setup, "init_telemetry", lambda config: seen.append(config) or True)
    monkeypatch.setenv(observability.OTEL_ENDPOINT_ENV, "http://collector.example:4318")
    monkeypatch.delenv(observability.METRICS_ENV, raising=False)
    observability.configure()
    [config] = seen
    assert config.enabled and config.endpoint == "http://collector.example:4318"
    assert config.protocol == "http/protobuf" and config.service_name == "aidc-mcp"


def test_metrics_count_each_tools_calls_and_are_off_by_default(app_client, monkeypatch):
    async def status(name):
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "status", status)
    monkeypatch.delenv(observability.OTEL_ENDPOINT_ENV, raising=False)
    monkeypatch.delenv(observability.METRICS_ENV, raising=False)
    monkeypatch.setattr(observability, "_metrics", None)
    monkeypatch.setattr(observability, "_registry", None)
    observability.configure()
    with app_client() as c:
        assert c.get("/metrics", headers=H).status_code == 404
    monkeypatch.setenv(observability.METRICS_ENV, "true")
    observability.configure()
    with app_client() as c:
        _one_call(c)
        assert c.get("/metrics").status_code == 401          # behind the bearer
        text = c.get("/metrics", headers=H).text
    assert 'aidc_mcp_tools_calls_total{outcome="ok",tool="session_status"} 1.0' in text
    assert "aidc_mcp_tools_call_duration_seconds_bucket" in text
