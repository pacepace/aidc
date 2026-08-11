"""Tests for the shared-session helpers that survive the design-09 cutover.

The old tmux-scraping delivery watcher (_run_watcher) and its callback
instrumentation were removed when delivery moved to the JSONL transcript
(see test_transcript.py / test_transcript_delivery.py). What remains here:
  _extract_delta   — still used for claude_session_send/run's synchronous
                     "response returned directly" convenience value.
  _session_watchers — watcher task registry lifecycle.
"""
import asyncio

from aidc_mcp.tools import (
    _extract_delta,
    _session_watchers,
)

# ---------------------------------------------------------------------------
# _extract_delta (synchronous convenience return for claude_session_send/run)
# ---------------------------------------------------------------------------

class TestExtractDelta:
    def test_returns_content_after_anchor(self):
        baseline = "line1\nline2\nline3"
        final = "line1\nline2\nline3\nnew content"
        assert _extract_delta(baseline, final) == "new content"

    def test_empty_baseline_returns_full_final(self):
        assert _extract_delta("", "result here") == "result here"

    def test_blank_only_baseline_returns_full_final(self):
        assert _extract_delta("   \n\n  ", "answer") == "answer"

    def test_same_content_returns_empty(self):
        content = "Claude> ready\nline1\nline2"
        assert _extract_delta(content, content) == ""

    def test_anchor_not_found_returns_full_final(self):
        assert _extract_delta("completely different", "new stuff only") == "new stuff only"

    def test_strips_ansi_from_both(self):
        baseline = "\x1b[1mline1\x1b[0m\nline2"
        final = "\x1b[1mline1\x1b[0m\nline2\nnew line"
        assert _extract_delta(baseline, final) == "new line"

    def test_uses_last_anchor_occurrence(self):
        baseline = "prompt>"
        final = "prompt>\necho\nprompt>\nreal answer"
        assert _extract_delta(baseline, final) == "real answer"

    def test_multi_line_anchor(self):
        baseline = "header\nbody\nfooter"
        final = "header\nbody\nfooter\nnew paragraph"
        assert _extract_delta(baseline, final) == "new paragraph"


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
