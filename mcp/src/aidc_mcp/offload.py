"""Run a blocking tool or resource body off the server's event loop.

FastMCP calls a synchronous tool or resource function inline, on the one event
loop that also runs every transcript watcher, reply callback and other tool
call. A body that waits on a subprocess (the aidc CLI, `docker exec`) therefore
froze all of them for as long as it ran: 60s and more while `aidc list` was slow.
`off_loop` turns such a function into a coroutine function that runs the
original body in a worker thread.

Only for bodies that touch no state the event loop also mutates: a worker
thread reading `_pending_sends` while the loop edits it is a race. A tool that
needs both awaits its blocking part with `asyncio.to_thread` and reads that
state on the loop instead (see session_status).
"""

from __future__ import annotations

import asyncio
import functools
from collections.abc import Callable
from typing import Any


def off_loop(fn: Callable[..., Any]) -> Callable[..., Any]:
    """Wrap a synchronous function so awaiting it runs the body in a thread.

    Keeps the signature and docstring (functools.wraps), which FastMCP reads
    for the tool's schema and a resource template's parameters."""
    @functools.wraps(fn)
    async def wrapper(*args: Any, **kwargs: Any) -> Any:
        return await asyncio.to_thread(fn, *args, **kwargs)
    return wrapper
