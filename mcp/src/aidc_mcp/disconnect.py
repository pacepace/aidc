"""Stop a session_invoke whose client dropped the connection.

On the 2025-era streamable-HTTP wire (the one metallm speaks) the MCP SDK cancels a
tool call on `notifications/cancelled` and when the session is closed, but not when
the client simply drops the connection: the handler runs on with nobody to answer
(measured on SDK 2.3, tests/test_invoke_cancel_wire.py). A blocking session_invoke
would then keep its claude run editing files in the container. This ASGI layer
watches each `tools/call` of session_invoke for the connection going away and calls
back with that call's (MCP session id, JSON-RPC request id).
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Callable

from starlette.types import ASGIApp, Message, Receive, Scope, Send

_WATCHED_TOOLS = frozenset({"session_invoke"})


def watched_call(scope: Scope, body: bytes) -> tuple[str, str] | None:
    """(session id, request id) when the request is a tools/call of a watched tool."""
    try:
        msg = json.loads(body)
    except ValueError:
        return None
    if not isinstance(msg, dict) or msg.get("method") != "tools/call":
        return None
    params = msg.get("params")
    if not isinstance(params, dict) or params.get("name") not in _WATCHED_TOOLS:
        return None
    if "id" not in msg:
        return None
    headers = {k.decode("latin-1").lower(): v.decode("latin-1")
               for k, v in scope.get("headers", [])}
    return headers.get("mcp-session-id", ""), str(msg["id"])


def _replaying(body: bytes, rest: Receive) -> Receive:
    """A receive that hands out the already-read body first, then defers to `rest`."""
    replayed = False

    async def again() -> Message:
        nonlocal replayed
        if not replayed:
            replayed = True
            return {"type": "http.request", "body": body, "more_body": False}
        return await rest()
    return again


class StopInvokeOnDisconnect:
    def __init__(self, app: ASGIApp, on_disconnect: Callable[[str, str], None]) -> None:
        self.app = app
        self.on_disconnect = on_disconnect

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope.get("type") != "http" or scope.get("method") != "POST":
            await self.app(scope, receive, send)
            return
        chunks: list[bytes] = []
        while True:
            message = await receive()
            if message.get("type") != "http.request":
                return   # gone before the request was even read
            chunks.append(message.get("body", b""))
            if not message.get("more_body"):
                break
        body = b"".join(chunks)
        key = watched_call(scope, body)
        if key is None:
            await self.app(scope, _replaying(body, receive), send)
            return
        # This layer now owns `receive`: it reads it for the disconnect, and the app
        # hears of the disconnect through `gone`.
        gone = asyncio.Event()

        async def disconnected() -> Message:
            await gone.wait()
            return {"type": "http.disconnect"}

        async def watch() -> None:
            while (await receive()).get("type") != "http.disconnect":
                pass
            gone.set()
            self.on_disconnect(*key)

        watcher = asyncio.create_task(watch())
        try:
            await self.app(scope, _replaying(body, disconnected), send)
        finally:
            watcher.cancel()
