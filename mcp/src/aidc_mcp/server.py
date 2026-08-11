"""aidc-mcp entry point.

Boots a FastMCP server with our tools + resources + bearer auth
middleware, then runs the streamable-HTTP transport bound to the
container's 0.0.0.0:${AIDC_MCP_PORT}. Docker's -p flag on the host
restricts which host interface the listener is reachable from.
"""

from __future__ import annotations

import os
import sys
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from aidc_mcp import audit, resources, tools


def main() -> int:
    port = int(os.environ.get("AIDC_MCP_PORT", "7878"))

    # DNS rebinding protection is designed for browser-facing services where
    # JS can spoof Host headers. Our server is bearer-auth gated and bound
    # to a private interface (ZeroTier / Tailscale / localhost) via Docker
    # `-p`. The Host header the client sends matches the user's bind choice;
    # we don't know that bind choice from inside the container, so the SDK's
    # auto-enabled localhost-only allow-list rejects everything else. Turning
    # the check off here is safe given our auth + network model.
    app = FastMCP(
        name="aidc",
        instructions=(
            "Control plane for the aidc sandbox. Tools manage sessions "
            "(create / list / status / kill / exec), invoke the in-container "
            "Claude, read/write files inside sessions, and surface audit data."
        ),
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )

    tools.register(app)
    resources.register(app)

    audit.log_event("server_start", port=port)

    # We import the bearer-auth middleware lazily so a missing token file
    # produces a clean error message on startup rather than during import.
    from aidc_mcp.auth import BearerAuthMiddleware

    # FastMCP exposes a Starlette ASGI app for the streamable-HTTP
    # transport. We wrap it in our middleware and run it with uvicorn.
    starlette_app: Any
    try:
        starlette_app = app.streamable_http_app()
    except AttributeError:
        # Some SDK versions expose the ASGI app via a different name.
        starlette_app = app.sse_app() if hasattr(app, "sse_app") else None
        if starlette_app is None:
            audit.log_event("server_error", reason="no_asgi_app")
            print("ERROR: this MCP SDK version doesn't expose a streamable-HTTP ASGI app",
                  file=sys.stderr)
            return 2

    wrapped = BearerAuthMiddleware(starlette_app)

    import uvicorn

    uvicorn.run(wrapped, host="0.0.0.0", port=port, log_level="info")
    return 0


if __name__ == "__main__":
    sys.exit(main())
