"""What aidc-mcp picks up when it starts.

No MCP types here (test_service_boundary): the tools in tools.py adapt it.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable

from aidc_mcp.audit import log_event
from aidc_mcp.service import sending as snd


async def resume(resume_watchers: Callable[[], Awaitable[None]]) -> None:
    """Everything aidc-mcp must pick up after a restart: saved send queues first, then
    the webhooks that deliver their replies (`resume_watchers`, which the MCP adapter
    binds to its app)."""
    steps = (("queues", snd.resume_send_queues), ("watchers", resume_watchers))
    for step, run in steps:
        try:
            await run()
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- keep resuming
            # One failing step must not keep the other from running.
            log_event("startup_resume_failed", step=step,
                      error_type=type(exc).__name__, error=repr(exc))
