"""Tests for the watcher task registry (_session_watchers) lifecycle.

Delivery reads the JSONL transcript (test_transcript.py, test_transcript_delivery.py),
and so does session_run's synchronous reply; nothing scrapes reply text off the
pane any more (design-10 S1).
"""
import asyncio

from aidc_mcp.tools import _session_watchers

# ---------------------------------------------------------------------------
# _session_watchers lifecycle (claude_session_watch/unwatch)
# ---------------------------------------------------------------------------

class TestSessionWatchersLifecycle:
    async def test_task_added_to_session_watchers(self):
        sentinel = asyncio.Event()

        async def dummy():
            await sentinel.wait()

        task = asyncio.create_task(dummy())
        _session_watchers["myses"] = task
        try:
            assert "myses" in _session_watchers
            assert _session_watchers["myses"] is task
        finally:
            sentinel.set()
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            _session_watchers.pop("myses", None)

    async def test_cancelling_task_removes_it_via_done_callback(self):
        started = asyncio.Event()

        async def dummy():
            started.set()
            await asyncio.sleep(100)

        task = asyncio.create_task(dummy())
        _session_watchers["ses2"] = task
        task.add_done_callback(lambda t: _session_watchers.pop("ses2", None))

        await started.wait()
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

        assert "ses2" not in _session_watchers

    async def test_replacing_watcher_cancels_previous(self):
        first_cancelled = asyncio.Event()

        async def first_watcher():
            try:
                await asyncio.sleep(100)
            except asyncio.CancelledError:
                first_cancelled.set()
                raise

        task1 = asyncio.create_task(first_watcher())
        _session_watchers["ses3"] = task1

        await asyncio.sleep(0)

        old_task = _session_watchers.get("ses3")
        if old_task:
            old_task.cancel()
            _session_watchers.pop("ses3", None)

        await asyncio.gather(task1, return_exceptions=True)

        assert first_cancelled.is_set()
        assert "ses3" not in _session_watchers
