"""aidc-mcp's local face: the tools and resources served by 3tears-mcp over Streamable HTTP.

`McpServer` serves the TearsTools (aidc_mcp/tearstools) through 3tears' bridge, in
stateful mode (TRS-08) answering on SSE streams, so a call's progress and log lines
reach the caller before its result and a change of the watched sessions reaches every
connected client as `notifications/tools/list_changed` (MCP-21). In front of it, the
bearer gate answers 401 to any request without the token and logs every request
(auth.py). The authorizer (authz.py) refuses out-of-scope and tainted calls before a
tool runs; aidc's error codes are registered as protocol codes (TRS-05).

Bound to the container's 0.0.0.0:${AIDC_MCP_PORT}; Docker's -p flag on the host decides
which host interface reaches it. The transport's Host-header check (DNS-rebinding
protection, meant for browser-facing services) is off: the server is bearer-gated, and the
Host a client sends is the user's bind choice, which this container cannot know.
"""

from __future__ import annotations

import contextlib
import os
import sys
from collections.abc import AsyncIterator
from typing import Any

from starlette.applications import Starlette
from starlette.routing import Route
from starlette.types import Receive, Scope, Send
from threetears.mcp import (
    BearerTokenIdentityProvider,
    ErrorCode,
    ErrorCodes,
    McpHttpTransport,
    McpServer,
    McpTool,
    ResourceRegistry,
    current_bearer_token,
)
from threetears.tool_contract.mcp_face import mcp_tool

from aidc_mcp import __version__, audit, auth, authz, resources, scope
from aidc_mcp.authz import PERMISSION, AidcAuthorizer
from aidc_mcp.service import common as com
from aidc_mcp.service import delivery as dlv
from aidc_mcp.service import startup as sup
from aidc_mcp.service import state as ss
from aidc_mcp.tearstools import AidcTool, ToolHooks, build_tools

INSTRUCTIONS = (
    "Control plane for the aidc sandbox. Tools manage sessions "
    "(create / list / status / kill / exec), invoke the in-container "
    "Claude, read/write files inside sessions, and surface audit data. "
    "Give a session's agent any task or anything long (edits, builds, tests, "
    "multi-step work) with session_send; session_invoke is only for short, "
    "single-shot questions."
)

MCP_PATH = "/mcp"


def error_codes() -> ErrorCodes:
    """aidc's error codes as protocol codes: every code an envelope can carry (TRS-05)."""
    return ErrorCodes(
        ErrorCode(code, description, retryable=code in com.RETRYABLE_ERROR_CODES)
        for code, description in com.ERROR_CODE_DESCRIPTIONS.items())


class Face:
    """One local MCP face: the server, the tools it serves and their MCP listing.

    The listing is rebuilt from the tools on every `tools/list` and `tools/call`, so the
    session tools' descriptions name the sessions watched right now. Each tool's MCP form
    is kept while its description stays the same, and rebuilt when it changes.
    """

    def __init__(self, *, include_create: bool | None = None) -> None:
        if include_create is None:
            # session_create is registered only where the operator turned it on (MCP-38)
            include_create = scope.session_create_enabled()
        self.tools: list[AidcTool] = build_tools(ToolHooks(announce=self.announce),
                                                 include_create=include_create)
        self._listed: dict[str, McpTool] = {}
        self.server = McpServer(
            name="aidc",
            version=__version__,
            instructions=INSTRUCTIONS,
            identity_provider=BearerTokenIdentityProvider(
                resolver=authz.resolve_identity, token_source=current_bearer_token),
            authorizer=AidcAuthorizer(),
            tool_provider=self.listing,
            error_codes=error_codes(),
            resources=_resource_registry(),
        )

    def listing(self) -> list[McpTool]:
        """The tools as MCP lists them now: each under its local name (TRS-15)."""
        out = []
        for tool in self.tools:
            held = self._listed.get(tool.local_name)
            if held is None or held.description != tool.description():
                held = mcp_tool(tool, required_permission=PERMISSION, name=tool.local_name,
                                prepare_arguments=tool.prepare_arguments)
                self._listed[tool.local_name] = held
            out.append(held)
        return out

    async def announce(self) -> None:
        """Tell every connected client the tool list changed (the watched sessions did)."""
        try:
            await self.server.notify_tools_changed()
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- best-effort notify
            audit.log_event("tool_list_changed_notify_failed",
                            error_type=type(exc).__name__, error=repr(exc))

    def session_changed(self, name: str) -> None:
        """The service's notice that session `name`'s status may have changed: clients that
        subscribed to its status resource, or to the session list, are told to read it
        again (MCP-09). Only the URIs go out; a read is a request of its own. A scoped
        server says nothing of a session outside its scope, not even that it changed."""
        if scope.refusal(name) is not None:
            return
        com.fire(self.server.notify_resource_updated(f"aidc://sessions/{name}/status"))
        com.fire(self.server.notify_resource_updated("aidc://sessions"))

    async def resume(self) -> None:
        """Startup resume (service/startup.py): saved send queues, then the webhooks. When
        a webhook reopens, the clients hear that the tool list changed."""
        def resumed() -> None:
            com.fire(self.announce())
        await sup.resume(lambda: dlv.resume_watches(resumed))


def _resource_registry() -> ResourceRegistry:
    registry = ResourceRegistry()
    for entry in resources.all_resources():
        registry.register(entry)
    return registry


class _LazyEndpoint:
    """The MCP endpoint, bound to the transport the lifespan builds.

    3tears-mcp builds a transport only once its server has started, which is async; the
    app's routes are fixed before that. So the route points here, and the lifespan sets
    the transport before the first request can arrive."""

    def __init__(self) -> None:
        self.transport: McpHttpTransport | None = None

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if self.transport is None:
            raise RuntimeError("the MCP transport is not running (the app's lifespan was not run)")
        await self.transport.endpoint(scope, receive, send)


def build_app(face: Face | None = None) -> Any:
    """The ASGI app main() serves: the MCP endpoint behind the bearer gate. Its lifespan
    starts the server and the transport, then resumes persisted queues and webhooks: a
    prompt queued before a restart is pasted without waiting for a later tool call, and
    its reply still reaches the conversation."""
    face = face if face is not None else Face()
    endpoint = _LazyEndpoint()

    @contextlib.asynccontextmanager
    async def lifespan(_app: Starlette) -> AsyncIterator[None]:
        await face.server.start()
        endpoint.transport = face.server.build_http_transport(
            path=MCP_PATH, stateless=False, json_response=False)
        ss.session_change_listeners.append(face.session_changed)
        try:
            async with endpoint.transport.lifespan():
                com.fire(face.resume())
                yield
        finally:
            ss.session_change_listeners.remove(face.session_changed)
            await face.server.stop()

    app = Starlette(routes=[Route(MCP_PATH, endpoint=endpoint)], lifespan=lifespan)
    return auth.BearerAuthMiddleware(app)


def main() -> int:
    port = int(os.environ.get("AIDC_MCP_PORT", "7878"))
    audit.log_event("server_start", port=port)
    wrapped = build_app()

    import uvicorn

    uvicorn.run(wrapped, host="0.0.0.0", port=port, log_level="info")
    return 0


if __name__ == "__main__":
    sys.exit(main())
