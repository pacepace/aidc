"""Bearer-token authentication middleware for the streamable-HTTP MCP server.

The token lives in a file (mounted into the container from the host's
~/.config/aidc/mcp-token). The middleware reads it once at module-load
time, then accepts requests bearing exactly that token.

`aidc mcp token rotate` writes a new token file and restarts the
container, which makes this module re-read the file on startup.
"""

from __future__ import annotations

import hmac
import os
from pathlib import Path

from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from aidc_mcp.audit import log_event

_TOKEN_PATH = Path(os.environ.get("AIDC_MCP_TOKEN_FILE", "/aidc-config/mcp-token"))


def _load_token() -> str:
    if not _TOKEN_PATH.exists():
        raise RuntimeError(
            f"bearer token file not found at {_TOKEN_PATH}; "
            "run `aidc mcp start` on the host (it auto-generates one)"
        )
    token = _TOKEN_PATH.read_text(encoding="utf-8").strip()
    if not token:
        raise RuntimeError(f"bearer token file {_TOKEN_PATH} is empty")
    return token


class BearerAuthMiddleware:
    """ASGI middleware. Lets through anything with the matching Bearer
    token; everything else gets 401. Every request (pass or fail) is
    logged to the audit log.

    Note: we read the token once at startup. Rotation is a "restart the
    container" workflow, not a hot-reload, because (a) it's simpler and
    (b) restart is cheap.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app
        self._token = _load_token()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request = Request(scope, receive=receive)
        peer = request.client.host if request.client else "unknown"
        path = request.url.path
        method = request.method
        auth_header = request.headers.get("authorization", "")

        if not auth_header.startswith("Bearer "):
            log_event("auth_reject", peer=peer, method=method, path=path, reason="no_bearer")
            response = JSONResponse(
                {"error": "missing or malformed Authorization header"}, status_code=401
            )
            await response(scope, receive, send)
            return

        presented = auth_header[len("Bearer "):].strip()
        if not hmac.compare_digest(presented, self._token):
            log_event("auth_reject", peer=peer, method=method, path=path, reason="bad_token")
            response = JSONResponse({"error": "invalid bearer token"}, status_code=401)
            await response(scope, receive, send)
            return

        log_event("auth_ok", peer=peer, method=method, path=path)
        await self.app(scope, receive, send)
