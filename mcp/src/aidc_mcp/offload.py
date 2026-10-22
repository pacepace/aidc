"""Run a blocking tool or resource body off the server's event loop.

The one event loop runs every transcript watcher, reply callback and tool call,
so a body that waits on a subprocess (the aidc CLI, `docker exec`) must not run
on it: run inline, it freezes all of them for as long as it runs (60s and more
while `aidc list` is slow). `off_loop` turns such a function into a coroutine
function that runs the original body in a worker thread, and marks it so the
tests can find every body that runs off the loop. Every registered function is a
coroutine function, so where a body runs is decided here and checked by
test_offload, not by how a given SDK release treats a synchronous handler.

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

    Keeps the signature and docstring (functools.wraps), which MCPServer reads
    for the tool's schema and a resource template's parameters."""
    @functools.wraps(fn)
    async def wrapper(*args: Any, **kwargs: Any) -> Any:
        return await asyncio.to_thread(fn, *args, **kwargs)
    wrapper.runs_off_loop = True  # type: ignore[attr-defined]  # read by test_offload
    return wrapper
