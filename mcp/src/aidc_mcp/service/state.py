"""The service's in-memory state: every per-session table the event loop owns, and
the directories its persisted state lives in.

One module, so a restart's losses and a test's reset are one list, and every reader
reads the one binding (`ss.<name>` at call time, never a copied import).

No MCP types here (test_service_boundary): the tools in tools.py adapt it.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import TYPE_CHECKING, Any, NamedTuple

from aidc_mcp import transcript as ts
from aidc_mcp.audit import log_event

if TYPE_CHECKING:
    from aidc_mcp import headless


# Holds references to background tasks (common.fire) so they aren't GC'd before
# completion.
background_tasks: set[asyncio.Task[None]] = set()


class InFlight(NamedTuple):
    """A session_invoke call waiting on its run."""

    container: str
    run: headless.Run
    proc: Any


# The session_invoke calls in flight, by (MCP session id, JSON-RPC request id), so the
# transport layer can stop one whose client dropped the connection (disconnect.py).
invokes_in_flight: dict[tuple[str, str], InFlight] = {}

# One headless run per session container at a time (owner ruling, 2026-10-22: "only allow one
# session invoke at a time per dev container"). The lock makes the check and the
# claim one step, so two calls arriving together cannot both find the session free.
invoke_locks: dict[str, asyncio.Lock] = {}


# Per-session asyncio locks: serialize concurrent session_send calls.
session_send_locks: dict[str, asyncio.Lock] = {}


# Per-session FIFO of prompts accepted but not yet pasted (design-10 S4, MCP-30). A
# dev-agent turn routinely outlives any sane inline wait — prod 2026-08-22 conv
# 01a01cf6 ran ONE turn for 22 minutes after an auto-compaction — and the old
# behaviour was to wait 30s and then return an error, DISCARDING the prompt. Nothing
# on either side retried it: the orchestrator's busy marker
# (services/agent_session_busy) deliberately does not arm on an `ok: false` envelope,
# so the message simply evaporated.
#
# A prompt accepted here is never dropped: it waits with no deadline, is held while
# Claude is not running, survives an aidc-mcp restart (persisted beside the other
# watcher state), and leaves only by being pasted or by its session being killed
# (then it is written to the send dead-letter dir). session_send returns
# ok=True/"queued", which the orchestrator's busy marker arms on.
pending_sends: dict[str, list[ts.QueuedPrompt]] = {}


# Per-session drainer tasks: one long-lived injector per session with a non-empty
# queue. Keyed by session name (like the send lock) rather than per conversation.
pending_drainers: dict[str, asyncio.Task[None]] = {}


# Per-session background watcher tasks. The KEYS are the sessions with an open
# webhook (responses stream back to the orchestrator). We surface that set in the
# session-tool descriptions so the LLM knows which session to talk to without
# having to remember or rediscover it.
session_watchers: dict[str, asyncio.Task[None]] = {}


# Prompts pasted into a session whose arrival the transcript has not shown yet:
# name -> (prompt as pasted, wall-clock time of the paste). watch_for_echo owns the
# expiry, so a prompt that never shows is logged even if nothing checks again.
sent_awaiting_echo: dict[str, tuple[str, float]] = {}


# Sessions whose status row the MCP has seen show `esc to interrupt`, so its absence
# can be trusted (see _LOG_STALL_S). Mirrored by a marker file per session in the
# watcher-state dir; read it through working_indicator_known.
working_indicator_seen: set[str] = set()


# session -> uuid of the latest prompt the watcher reported as interrupted before Claude
# wrote anything. The send path waits for that report before treating such a session
# as free, so the orchestrator hears about the interrupt before its next prompt lands,
# and afterwards treats that prompt's turn as over. Mirrored on disk, because the
# watcher's watermark is past the prompt once it is reported: after a restart nothing
# would report it again, and the session would read busy for good. Use
# _interrupt_reported / record_reported_interrupt.
reported_interrupts: dict[str, str] = {}


# Last (reason, why) the free check logged per session: it logs on change only.
last_free_verdict: dict[str, tuple[str, str]] = {}


# Last raw screen capture per session: the unrecognized-screen excerpt, and the
# screen inject judges the paste against (the one the free check just read).
last_screen_raw: dict[str, str] = {}


# session -> (text, prompt ids) of a paste inject made but did not submit because it
# had not shown in the input box in time. If it shows there later, it is ours, not a
# person's unsent text: the next free check lets it through and inject presses Enter
# on it. Its prompts count as pasted from then on: the drainer submits exactly that
# batch, and session_queue_cancel answers "too late" for them.
unsubmitted_paste: dict[str, tuple[str, tuple[str, ...]]] = {}


# The session instance (see session_instance) the in-memory markers above belong to.
# A marker on disk records its instance too, and one from another instance (a session
# killed and created again under the same name) is ignored and removed, so it cannot
# vouch for a session the MCP has never watched. _sync_session_markers is the one place
# markers are loaded and checked.
session_instances: dict[str, str] = {}


def working_seen_path(name: str) -> Path:
    return Path(WATCHER_STATE_DIR) / f"{ts.slug(name)}.working-text-seen"


def reported_interrupt_path(name: str) -> Path:
    return Path(WATCHER_STATE_DIR) / f"{ts.slug(name)}.interrupt-reported"


# Consecutive unexpected drainer failures per session, for the restart backoff.
drainer_failures: dict[str, int] = {}


# Sessions whose tmux status line currently shows the waiting-on-input notice.
waiting_notice_shown: set[str] = set()


def forget_session_send_state(name: str) -> None:
    """Send-path state lives as long as the session, not as long as a watcher: a
    session_unwatch must not drop a paste's busy hold. It is cleared here, when the
    session is gone."""
    working_indicator_seen.discard(name)
    sent_awaiting_echo.pop(name, None)
    unsubmitted_paste.pop(name, None)
    last_free_verdict.pop(name, None)
    last_screen_raw.pop(name, None)
    waiting_notice_shown.discard(name)
    reported_interrupts.pop(name, None)
    session_instances.pop(name, None)
    lock = invoke_locks.get(name)
    if lock is not None and not lock.locked():
        del invoke_locks[name]
    for path in (working_seen_path(name), reported_interrupt_path(name)):
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:
            log_event("session_state_forget_failed", session=name, path=str(path),
                      error_type=type(exc).__name__)


# Sessions whose persisted queue file has been read into pending_sends by this
# process (by startup resume or by the first send to arrive before it).
queue_loaded: set[str] = set()


TRANSCRIPTS_BASE = Path(os.environ.get("AIDC_MCP_TRANSCRIPTS", "/var/log/aidc-mcp/transcripts"))


WATCHER_STATE_DIR = Path(
    os.environ.get("AIDC_MCP_WATCHER_STATE", "/var/log/aidc-mcp/watcher-state")
)


# Consecutive watcher polls that found an unanswered prompt, a quiet transcript and no
# working text on screen, per (session, conversation_id). Two are required before
# the prompt is reported as interrupted, so one odd screen reading cannot report it.
unanswered_polls: dict[tuple[str, str], int] = {}


# (session, conversation_id, withdrawn terminal uuid) already logged as dropped, so
# a transcript re-read every poll logs each drop once per process.
logged_withdrawn_drops: set[tuple[str, str, str]] = set()


# Per-(session, conversation) transcript settle tracking: maps the key to the
# (last-seen file size in bytes, monotonic time that size was first observed).
# A turn is delivered only once the size has held steady for turn_settle_seconds,
# so a burst of end_turn segments under one prompt coalesces into one delivery.
settle_state: dict[tuple[str, str], tuple[int, float]] = {}


# Per-(session, conversation) consecutive torn-read count (see the resume block in
# _drain_transcript_once). A transient torn/partial read drops the resume anchor
# for a poll or two; a sustained run of misses means the pinned session is dead and
# the watcher rotates off it. Reset on any successful resume; evicted with the rest
# of the per-session state when the watcher ends.
torn_read_counts: dict[tuple[str, str], int] = {}


# Per-(session, conversation) consecutive "pinned session fully consumed AND a
# strictly-newer session exists" count. Claude never deletes a rotated-away
# transcript, so the session pin never releases on its own; a sustained run of
# this condition means the session genuinely rotated and the watcher must follow
# forward (see _rotate_if_stale_pin). Reset on delivery / when no newer session
# exists; evicted with the rest of the per-session state.
consumed_idle_counts: dict[tuple[str, str], int] = {}


# Per-(session, conversation) delivery-pass mutex. Delivery is exactly-once via a
# durable watermark, but advancing it is a read-modify-write straddling an
# await-heavy POST (retry/backoff): load the mark, extract undelivered turns,
# POST each, THEN save the advanced mark. If two delivery passes for the same
# (session, conversation) overlap, both load the SAME pre-delivery mark, both see
# the turn as new, and both POST it — every turn delivered twice. Overlap is
# reachable in the single-process streamable-HTTP server: a session_watch
# replacement cancels the old watcher without awaiting it, so its in-flight drain
# can still be mid-POST when the fresh watcher's first drain begins (and any
# duplicate watcher slipped past registration would overlap on every poll). This
# lock makes the whole load->deliver->advance critical section atomic per key, so
# the second pass observes the advanced mark and dedups. In-process is sufficient:
# there is exactly one MCP server process (one uvicorn/event loop).
_drain_locks: dict[tuple[str, str], asyncio.Lock] = {}


def drain_lock(key: tuple[str, str]) -> asyncio.Lock:
    """Get-or-create the per-(session, conversation) delivery mutex.

    Created lazily inside the running loop (an asyncio.Lock binds to the loop it
    is first awaited on), so it must not be constructed at import time."""
    lock = _drain_locks.get(key)
    if lock is None:
        lock = asyncio.Lock()
        _drain_locks[key] = lock
    return lock


def evict_session_state(name: str) -> None:
    """Drop per-session settle-tracking entries when a watcher ends/is unwatched,
    so `settle_state` (keyed per conversation_id — the real unbounded-growth risk)
    doesn't accumulate as conversations come and go.

    The send lock is deliberately NOT evicted: it's keyed by session *name* (bounded
    by session count, not conversations) and may be held by an in-flight
    `session_send`/`session_run` right now — popping it would let a concurrent send
    create a fresh lock and paste into the same tmux window simultaneously."""
    for key in [k for k in settle_state if k[0] == name]:
        settle_state.pop(key, None)
    for drop in [d for d in logged_withdrawn_drops if d[0] == name]:
        logged_withdrawn_drops.discard(drop)
    for key in [k for k in unanswered_polls if k[0] == name]:
        unanswered_polls.pop(key, None)
    for key in [k for k in torn_read_counts if k[0] == name]:
        torn_read_counts.pop(key, None)
    for key in [k for k in consumed_idle_counts if k[0] == name]:
        consumed_idle_counts.pop(key, None)
    for key in [k for k in _drain_locks if k[0] == name]:
        _drain_locks.pop(key, None)
    ts.forget_transcripts(Path(TRANSCRIPTS_BASE) / name)
