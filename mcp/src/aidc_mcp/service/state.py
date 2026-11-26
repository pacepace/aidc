"""The service's in-memory state: every per-session table the event loop owns, and
the directories its persisted state lives in.

One module, so a restart's losses and a test's reset are one list, and every reader
reads the one binding (`ss.<name>` at call time, never a copied import).

No MCP types here (test_service_boundary): the tools in tearstools/ adapt it.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, Any, NamedTuple

from aidc_mcp import audit
from aidc_mcp import store as state_store
from aidc_mcp import transcript as ts

if TYPE_CHECKING:
    from aidc_mcp import headless


# Holds references to background tasks (common.fire) so they aren't GC'd before
# completion.
background_tasks: set[asyncio.Task[None]] = set()


# Who to tell when what a session's status shows may have changed (MCP-09). The MCP face
# registers one while it serves, to send its clients `notifications/resources/updated`;
# the service names the session and knows nothing of who listens.
session_change_listeners: list[Callable[[str], None]] = []


class InFlight(NamedTuple):
    """A session_invoke call waiting on its run."""

    container: str
    run: headless.Run
    proc: Any


# The session_invoke calls in flight, by run id, so session_interrupt(target="headless")
# can stop the host's docker exec of a run a call still waits on.
invokes_in_flight: dict[str, InFlight] = {}

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
# Claude is not running, survives an aidc-mcp restart (a row of the state store), and
# leaves only by being pasted or by its session being killed (then it is kept as a send
# dead letter). session_send returns
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


# Each session's Claude Code hook events (MCP-47), as this process has read them: the name
# of the newest event file read (a session absent here has had none read yet), and its
# latest event about the turn. In memory: after a restart the files are read again.
hook_events_read: dict[str, str] = {}
hook_turn_event: dict[str, Any] = {}
# Whether each session's Claude runs aidc's hooks (read from its managed settings once per
# session instance); a session whose Claude does not is from before 2.0.
hooks_installed: dict[str, bool] = {}
# When this process first found a session whose Claude runs the hooks with no event yet
# (epoch seconds): past HOOK_EVENTS_DUE_S that is a writer that cannot write, logged once.
hooks_silent_since: dict[str, float] = {}
hooks_silence_logged: set[str] = set()


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


#: the session marker kept in the state store (store.py's `markers`), by kind
REPORTED_INTERRUPT_MARKER = "interrupt-reported"
#: a 1.x marker no longer written (the screen no longer decides the turn); removed with a
#: session's state
WORKING_SEEN_MARKER = "working-text-seen"


# Consecutive unexpected drainer failures per session, for the restart backoff.
drainer_failures: dict[str, int] = {}


# Sessions whose tmux status line currently shows the waiting-on-input notice.
waiting_notice_shown: set[str] = set()


def forget_session_send_state(name: str) -> None:
    """Send-path state lives as long as the session, not as long as a watcher: a
    session_unwatch must not drop a paste's busy hold. Every table whose lifetime is
    SESSION (LIFETIMES) is cleared here, when the session is gone or replaced."""
    for table in _tables(SESSION):
        if isinstance(table, dict):
            table.pop(name, None)
        else:
            table.discard(name)
    for locks in (invoke_locks, taint_locks):
        lock = locks.get(name)
        if lock is not None and not lock.locked():
            del locks[name]
    for kind in (WORKING_SEEN_MARKER, REPORTED_INTERRUPT_MARKER):
        try:
            state_store.for_dir(WATCHER_STATE_DIR).delete("markers",
                                                          state_store.key_of(name, kind))
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- a marker only
            audit.log_event("session_state_forget_failed", session=name, marker=kind,
                      error_type=type(exc).__name__)


# A tainted session's report (service/taint.py): the instance id its taint was reported for,
# so a session created again under the name is reported anew (a fact about one instance is
# never the next one's).
taint_reported: dict[str, str] = {}
# What last stopped a session's freeze, logged once until it changes.
freeze_trouble: dict[str, str] = {}
# One taint check per session at a time: a poke during a reconcile waits for it.
taint_locks: dict[str, asyncio.Lock] = {}


# Sessions whose persisted queue has been read into pending_sends by this
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
    for table in _tables(WATCH):
        for key in [k for k in table if k[0] == name]:
            if isinstance(table, dict):
                table.pop(key, None)
            else:
                table.discard(key)
    ts.forget_transcripts(Path(TRANSCRIPTS_BASE) / name)


# --- how long each table's entries live ------------------------------------------------
#
# Every module-level table above holds facts about sessions, and a fact outlives its session
# only by mistake (a session killed and created again under the same name must not inherit
# it). So each table declares its lifetime here, and test_state_lifetimes fails for a table
# that does not:
#
#   SESSION  keyed by session name; cleared by forget_session_send_state when the session is
#            gone or replaced (a new instance). Bounded by the live sessions.
#   WATCH    keyed by (session, conversation, ...); cleared by evict_session_state when the
#            session's watcher ends. Bounded by the conversations watched.
#   TASK     an entry is removed by the task or call that added it, when it ends (a drainer,
#            a watcher, a headless run). Bounded by what is running.
#   KEPT     kept for the process, deliberately, for the reason given. Bounded by the session
#            names this process has seen.
#   PROCESS  not about one session (the server's listeners).
SESSION, WATCH, TASK, KEPT, PROCESS = "session", "watch", "task", "kept", "process"

LIFETIMES: dict[str, tuple[str, str]] = {
    "hook_events_read": (SESSION, ""),
    "hook_turn_event": (SESSION, ""),
    "hooks_installed": (SESSION, ""),
    "hooks_silent_since": (SESSION, ""),
    "hooks_silence_logged": (SESSION, ""),
    "sent_awaiting_echo": (SESSION, ""),
    "unsubmitted_paste": (SESSION, ""),
    "last_free_verdict": (SESSION, ""),
    "last_screen_raw": (SESSION, ""),
    "waiting_notice_shown": (SESSION, ""),
    "reported_interrupts": (SESSION, ""),
    "session_instances": (SESSION, ""),
    "drainer_failures": (SESSION, ""),
    "taint_reported": (SESSION, ""),
    "freeze_trouble": (SESSION, ""),
    "settle_state": (WATCH, ""),
    "logged_withdrawn_drops": (WATCH, ""),
    "unanswered_polls": (WATCH, ""),
    "torn_read_counts": (WATCH, ""),
    "consumed_idle_counts": (WATCH, ""),
    "_drain_locks": (WATCH, ""),
    "background_tasks": (TASK, "each task removes itself when done (common.fire)"),
    "pending_drainers": (TASK, "the drainer removes itself when it ends"),
    "session_watchers": (TASK, "the watcher's done callback, or session_unwatch"),
    "invokes_in_flight": (TASK, "keyed by run id; the call removes it when its run ends"),
    "pending_sends": (TASK, "the drainer removes a session's queue once it is empty, and "
                            "a gone session's queue is dead-lettered and removed (MCP-30)"),
    "session_send_locks": (KEPT, "may be held by a send in flight: dropping it would let a "
                                 "second send paste into the same window at once"),
    "invoke_locks": (KEPT, "dropped by forget_session_send_state only when no run holds it"),
    "taint_locks": (KEPT, "dropped by forget_session_send_state only when no check holds it"),
    "queue_loaded": (KEPT, "a saved queue is read once per process; a session created again "
                           "has its old queue dropped (MCP-33) and its new one saved from "
                           "memory, never read back over it"),
    "session_change_listeners": (PROCESS, "the MCP face's, while it serves"),
}


#: The per-session (or per-run, per-file) tables kept by other modules, each with how long
#: its entries live: the service's in-memory state is state.py's, and anything else is named
#: here (tests/test_state_lifetimes.py scans every module of the package).
ELSEWHERE: dict[str, tuple[str, str]] = {
    "aidc_mcp.headless._runs": (TASK, "keyed by run id; a run's own task removes it when the "
                                      "run ends"),
    "aidc_mcp.store._stores": (PROCESS, "one store per state dir, opened once per process"),
    "aidc_mcp.transcript._parsed": (PROCESS, "a parse cache keyed by transcript file and its "
                                             "stamp: a new session writes new files"),
    "aidc_mcp.transcript._newest_ts": (PROCESS, "keyed by transcript file and its stamp, as "
                                                "_parsed"),
    "aidc_mcp.transcript._kind_cache": (PROCESS, "keyed by transcript file and its stamp, as "
                                                 "_parsed"),
}


def _tables(lifetime: str) -> list[Any]:
    return [globals()[name] for name, (kind, _) in LIFETIMES.items() if kind == lifetime]
