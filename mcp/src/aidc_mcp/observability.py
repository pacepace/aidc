"""aidc-mcp's observability on 3tears-observe (TRS-14): logs, a correlation id and a span per
tool call, and tracing and metrics export only when configured.

- **Logs.** The server's log lines go through 3tears-observe's structured logging to stderr
  (`docker logs`, `aidc mcp logs`). Every access-log event (audit.py) is also one such line.
- **Correlation.** Each tool call gets a correlation id (`cid`) and the tool's name in the log
  context, so every line logged while it runs carries them, and one span (`aidc.tool_call`).
- **Export, off unless configured.** With `AIDC_MCP_OTEL_ENDPOINT` set (an OTLP/HTTP
  collector's base URL), spans are exported there; it needs the aidc-mcp `otel` extra. With
  `AIDC_MCP_METRICS=true`, per-tool call counts and durations are served at `/metrics` behind
  the bearer; it needs the `prometheus` extra. Neither is set by default, and then nothing opens
  a network connection: spans go to OpenTelemetry's no-op provider and metrics are not kept.

The access log stays aidc's file sink (audit.py), the record of tool calls; it is not an
observability stream and its fields do not change.
"""

from __future__ import annotations

import contextlib
import contextvars
import os
import time
import uuid
from collections.abc import Iterator
from typing import Any

from threetears.observe import (
    CallMetrics,
    configure_logging,
    get_context,
    get_logger,
    set_context,
)

from aidc_mcp import __version__

OTEL_ENDPOINT_ENV = "AIDC_MCP_OTEL_ENDPOINT"
METRICS_ENV = "AIDC_MCP_METRICS"
LOG_LEVEL_ENV = "AIDC_MCP_LOG_LEVEL"

#: the span every tool call runs in
TOOL_SPAN = "aidc.tool_call"

log = get_logger("aidc_mcp")

#: set by configure() when metrics are switched on; per-tool calls and durations
_metrics: CallMetrics | None = None
_registry: Any = None


def metrics_enabled() -> bool:
    return os.environ.get(METRICS_ENV, "").strip().lower() == "true"


def configure() -> None:
    """Set up logging, and export only where the environment asks for it. main() calls it
    once, before serving."""
    global _metrics, _registry
    configure_logging(os.environ.get(LOG_LEVEL_ENV, "INFO"), color=False)
    endpoint = os.environ.get(OTEL_ENDPOINT_ENV, "").strip()
    if endpoint:
        try:
            from threetears.observe.setup import TelemetryConfig, init_telemetry
            init_telemetry(TelemetryConfig(
                enabled=True, endpoint=endpoint, protocol="http/protobuf",
                service_name="aidc-mcp", service_version=__version__))
        except ImportError as exc:
            log.warning("%s is set, but tracing export needs the aidc-mcp otel extra; spans "
                        "are not exported", OTEL_ENDPOINT_ENV,
                        extra={"extra_data": {"error": str(exc)}})
    if metrics_enabled():
        try:
            from prometheus_client import CollectorRegistry
        except ImportError:
            log.warning("%s=true, but metrics need the aidc-mcp prometheus extra; none are "
                        "kept", METRICS_ENV)
        else:
            _registry = CollectorRegistry()
            _metrics = CallMetrics("aidc_mcp_tools", registry=_registry)


def metrics_text() -> tuple[bytes, str] | None:
    """The metrics in Prometheus' text format and its media type, or None when metrics are
    off."""
    if _registry is None:
        return None
    from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
    return generate_latest(_registry), CONTENT_TYPE_LATEST


def background_context(**fields: str) -> contextvars.Context:
    """A context for work that outlives the call that starts it (a session's transcript
    watcher, its send-queue drainer): empty, so it carries no tool call's correlation id,
    tool name or span, with `fields` (the session it works for) in its log context.
    asyncio copies the starting task's context into a new task otherwise, and a watcher
    would log for hours as the call that started it."""
    ctx = contextvars.Context()
    ctx.run(set_context, **fields)
    return ctx


@contextlib.contextmanager
def tool_call(tool: str) -> Iterator[dict[str, Any]]:
    """The scope of one tool call: a fresh correlation id and the tool's name in the log
    context while it runs (restored after), and its duration and outcome counted when
    metrics are on. The caller sets `outcome` in the yielded dict ("ok" or "failed")."""
    before = get_context()
    cid = uuid.uuid4().hex
    set_context(cid=cid, tool=tool)
    call: dict[str, Any] = {"cid": cid, "outcome": "error"}
    start = time.monotonic()
    try:
        yield call
    finally:
        if _metrics is not None:
            _metrics.observe(name=tool, outcome=call["outcome"],
                             seconds=time.monotonic() - start)
        restore = {k: None for k in get_context() if k not in before}
        set_context(**restore, **before)
