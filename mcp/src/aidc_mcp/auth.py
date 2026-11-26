"""The bearer token: the HTTP gate in front of the MCP endpoint, and the caller's identity.

The token lives in a file (mounted into the container from the host's
~/.config/aidc/mcp-token). Every request is checked against the file as it is now: a
token rotated while the server runs (`aidc mcp token rotate` writes a new file) refuses
the old one on the next request, an MCP session already open included (TRS-08).

Two checks use it. `BearerAuthMiddleware` answers 401 to any HTTP request without the
token, before the MCP server sees it, and logs every request to the access log (MCP-14):
nothing, not even the tool list, is served to a caller without it. The MCP server's own
resolver (authz.resolve_identity), which 3tears-mcp asks for every tool call and resource
request, checks it again. The service imports this module for the token it sends with
callbacks, so it holds no MCP or 3tears type.
"""

from __future__ import annotations

import hmac
import os
from pathlib import Path

from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from aidc_mcp import audit

_TOKEN_PATH = Path(os.environ.get("AIDC_MCP_TOKEN_FILE", "/aidc-config/mcp-token"))

def load_token() -> str:
    """The token as the file holds it now. Raises RuntimeError when it is missing or empty.

    Read on every check: the file is a few bytes, and a cache keyed on its modification
    time can miss a rotation written within one tick of the clock."""
    try:
        token = _TOKEN_PATH.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        raise RuntimeError(
            f"bearer token file not found at {_TOKEN_PATH}; "
            "run `aidc mcp start` on the host (it auto-generates one)"
        ) from None
    if not token:
        raise RuntimeError(f"bearer token file {_TOKEN_PATH} is empty")
    return token


def token_matches(presented: str) -> bool:
    """Whether `presented` is the token the file holds now (constant-time compare)."""
    return hmac.compare_digest(presented.encode("utf-8"), load_token().encode("utf-8"))


class BearerAuthMiddleware:
    """ASGI middleware. Lets through anything with the current Bearer token; everything
    else gets 401. Every request (pass or fail) is logged to the access log."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app
        load_token()  # a missing or empty token file stops the server at startup

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
            audit.log_event("auth_reject", peer=peer, method=method, path=path, reason="no_bearer")
            response = JSONResponse(
                {"error": "missing or malformed Authorization header"}, status_code=401
            )
            await response(scope, receive, send)
            return

        presented = auth_header[len("Bearer "):].strip()
        try:
            matches = token_matches(presented)
        except RuntimeError as exc:
            # the token file is missing or empty for a moment (a rotation rewriting it):
            # nothing is served without a token to check against, and the refusal is logged
            audit.log_event("auth_reject", peer=peer, method=method, path=path,
                            reason="token_unreadable", error=str(exc)[:200])
            response = JSONResponse({"error": "the server's token cannot be read; retry"},
                                    status_code=401)
            await response(scope, receive, send)
            return
        if not matches:
            audit.log_event("auth_reject", peer=peer, method=method, path=path, reason="bad_token")
            response = JSONResponse({"error": "invalid bearer token"}, status_code=401)
            await response(scope, receive, send)
            return

        audit.log_event("auth_ok", peer=peer, method=method, path=path)
        await self.app(scope, receive, send)
