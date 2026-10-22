"""aidc-mcp entry point.

Boots an MCPServer with our tools + resources + bearer auth
middleware, then runs the streamable-HTTP transport bound to the
container's 0.0.0.0:${AIDC_MCP_PORT}. Docker's -p flag on the host
restricts which host interface the listener is reachable from.
"""

from __future__ import annotations

import os
import sys
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

from aidc_mcp import __version__, audit, resources, tools


class ResumeOnStartup:
    """ASGI wrapper that resumes persisted send queues and webhooks when the server starts.

    A prompt queued before an aidc-mcp restart must be pasted without waiting for some
    later tool call, and its reply must still reach the conversation: the orchestrator
    is waiting for that reply and will not make another call to ask for it. The
    lifespan scope is the first thing uvicorn runs inside the event loop."""

    def __init__(self, app: Any, mcp_app: Any) -> None:
        self.app = app
        self.mcp_app = mcp_app
        self.started = False

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope.get("type") == "lifespan" and not self.started:
            self.started = True
            tools.fire(tools.resume_on_startup(self.mcp_app))
        await self.app(scope, receive, send)


def build_app() -> Any:
    """The ASGI app main() serves: the SDK's streamable-HTTP app behind bearer auth,
    wrapped so startup resumes persisted queues and webhooks."""
    # DNS rebinding protection is designed for browser-facing services where
    # JS can spoof Host headers. Our server is bearer-auth gated and bound
    # to a private interface (ZeroTier / Tailscale / localhost) via Docker
    # `-p`. The Host header the client sends matches the user's bind choice;
    # we don't know that bind choice from inside the container, so the SDK's
    # auto-enabled localhost-only allow-list rejects everything else. Turning
    # the check off here is safe given our auth + network model.
    app = MCPServer(
        name="aidc",
        version=__version__,
        instructions=(
            "Control plane for the aidc sandbox. Tools manage sessions "
            "(create / list / status / kill / exec), invoke the in-container "
            "Claude, read/write files inside sessions, and surface audit data."
        ),
    )

    tools.register(app)
    resources.register(app)

    # We import the bearer-auth middleware lazily so a missing token file
    # produces a clean error message on startup rather than during import.
    from aidc_mcp.auth import BearerAuthMiddleware

    http_app = app.streamable_http_app(
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
    return ResumeOnStartup(BearerAuthMiddleware(http_app), app)


def main() -> int:
    port = int(os.environ.get("AIDC_MCP_PORT", "7878"))
    audit.log_event("server_start", port=port)
    wrapped = build_app()

    import uvicorn

    uvicorn.run(wrapped, host="0.0.0.0", port=port, log_level="info")
    return 0


if __name__ == "__main__":
    sys.exit(main())
