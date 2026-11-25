"""Sending prompts (design-10 S3/S4, MCP-28..30): the per-session queue, its drainer, the
paste, joining a running turn, and the notes a waiting or dropped prompt gets.

No MCP types here (test_service_boundary): the tools in tools.py adapt it.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import time
from collections.abc import Sequence
from pathlib import Path

from aidc_mcp import backend, scope
from aidc_mcp import screen as scr
from aidc_mcp import session_facts as sf
from aidc_mcp import transcript as ts
from aidc_mcp.audit import log_event
from aidc_mcp.service import callbacks as cbk
from aidc_mcp.service import common as com
from aidc_mcp.service import config as orc
from aidc_mcp.service import state as ss
from aidc_mcp.service import tmux as tmx
from aidc_mcp.service import turns as tn

# session_send's `deliver`: what to do with a prompt sent while the agent is mid-turn.
DELIVER_QUEUE = "queue"


DELIVER_JOIN = "join"


# How often, and how far apart, the input box is read after a paste that has to be
# confirmed there before Enter (see inject): long enough for Claude Code to draw it.
_PASTE_CONFIRM_POLLS = 5


_PASTE_CONFIRM_POLL_S = 0.3


# What joins the prompts of one batch (every prompt queued while the session was busy,
# pasted as one message when it is next free). Not a newline: the paste goes in through
# tmux paste-buffer, where a newline is Enter and would submit the first prompt alone
# (it is why session_send flattens a prompt's own newlines). Each prompt opens with its
# own sender line, so the marker only has to say where one ends.
_BATCH_SEPARATOR = " [next message] "


# How long session_send itself waits for the session to be free before queueing.
# Short on purpose: anything longer is the drainer's job, and a busy send should
# return "queued" promptly.
SEND_FREE_WAIT_S = 5.0


# How long each drainer free-wait runs before the drainer re-checks that the session
# still exists and records the latest waiting reason. Not a deadline: it loops.
_QUEUE_POLL_S = 60.0


# Backoff between failed pastes of the same prompt: 2, 4, 8 … seconds, capped. There
# is no attempt limit; each failure is logged and shown as the waiting reason.
_PASTE_RETRY_MAX_S = 60.0


# Hard cap on queue depth per session. A runaway orchestrator that keeps sending
# into a wedged session must not grow this without bound; past the cap a NEW prompt
# is refused (audibly). A prompt already accepted is never dropped by it.
PENDING_MAX_DEPTH = 25


# What a person attached to the session sees on the tmux status line while a queued
# prompt waits on their unsent text. tmux-start.sh shows the @aidc_waiting option.
# Short enough to show whole on an 80-column terminal (tests/unit/test-tmux-status-line.sh).
_WAITING_ON_INPUT_TEXT = "aidc: orchestrator message waiting — press Enter or clear your input"


def _own_unsent_text(name: str, screen: scr.ScreenState | None) -> bool:
    """Whether the input box holds the batch inject pasted and left unsubmitted, and
    that batch's prompts still open the queue, so the drainer is the one that comes
    back for it and submits it as it is. A paste from a caller that does not queue (the
    unadvertised session_run) carries no prompt ids, and its text stays a person's
    unsent input, which nothing is pasted on top of. Claude Code shows a long paste
    as a placeholder (`[Pasted text …]`), so that counts as well: a person pasting
    into the box in the seconds before a late paste draws is the narrow window
    this accepts."""
    pending = ss.unsubmitted_paste.get(name)
    if pending is None or screen is None or screen.input_box != scr.HAS_TEXT:
        return False
    if not batch_in_box(name):
        return False
    return scr.same_text(screen.typed, pending[0]) or screen.typed.startswith("[Pasted text")


def _queue_ids(name: str) -> list[str]:
    return [q.prompt_id for q in ss.pending_sends.get(name) or []]


def batch_in_box(name: str) -> tuple[str, ...]:
    """The prompt ids of the batch inject pasted into the box and did not submit, while
    they still open the queue (the drainer's to submit as they are); () otherwise."""
    pending = ss.unsubmitted_paste.get(name)
    ids = pending[1] if pending else ()
    return ids if ids and tuple(_queue_ids(name)[:len(ids)]) == ids else ()


def _next_batch(name: str) -> list[ts.QueuedPrompt]:
    """The prompts the drainer pastes next, in queue order: every queued prompt, as one
    message, unless a batch already pasted into the box is waiting for its Enter (then
    exactly that batch, and what queued after it waits for the next free moment).

    This is the one place that chooses what goes in together, so a per-prompt delivery
    choice (a prompt pasted on its own, or mid-turn) would be decided here."""
    queue = ss.pending_sends.get(name) or []
    in_box = batch_in_box(name)
    return queue[:len(in_box)] if in_box else list(queue)


def _batch_sent_by(batch: Sequence[ts.QueuedPrompt]) -> str:
    """The one ``sent_by`` a batch's send record carries: the last prompt's that names
    a person, as for a turn answering several prompts (_terminal_prompts). Each prompt's
    own is in the batch record and the reply's ``prompts``."""
    return next((q.sent_by for q in reversed(batch) if q.sent_by), "")


def _save_unrecognized_screen(name: str) -> None:
    """Keep the capture that did not match, for whoever updates screen.py."""
    raw = ss.last_screen_raw.get(name)
    if raw is None:
        return
    try:
        d = Path(ss.WATCHER_STATE_DIR) / "screens"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{ts.slug(name)}-unrecognized.ansi").write_text(raw, encoding="utf-8")
    except OSError as exc:
        log_event("session_screen_save_failed", session=name, error_type=type(exc).__name__)


async def _check_free(container: str, name: str) -> str:
    """Whether a prompt can be pasted into the session now: "" or a reason (see
    _paste_reason). Every change of verdict is logged with its evidence, so a "free"
    reached without transcript evidence (no transcript, a stalled one, the status
    row) is on record."""
    state = await tn.session_state(container, name)
    reason = tn.paste_reason(state)
    if reason == "input_has_text" and _own_unsent_text(name, state.screen):
        reason = ""
    verdict = (reason, state.why)
    if ss.last_free_verdict.get(name) != verdict:
        ss.last_free_verdict[name] = verdict
        log_event("session_free_check", session=name, reason=reason, turn=state.turn,
                  why=state.why)
        if reason == "screen_unrecognized":
            _save_unrecognized_screen(name)
    return reason


def _join_refusal(name: str, state: tn.SessionState) -> str:
    """Why a prompt may not be pasted into the turn running now (session_send's
    deliver="join"), or "". The screen rules of _paste_reason all hold: the turn
    being busy is the one they skip. And an Esc the watcher has not reported yet: a
    prompt pasted on top of it would bury the report (design 10 S1)."""
    if not state.claude_running or state.screen is None:
        return "claude_not_running"
    if state.screen.input_box == scr.NOT_AT_PROMPT:
        return "claude_not_at_prompt"
    if state.screen.input_box == scr.UNRECOGNIZED:
        return "screen_unrecognized"
    if state.screen.list_focused:
        return "agent_list_selected"
    if state.screen.input_box == scr.HAS_TEXT and not _own_unsent_text(name, state.screen):
        return "input_has_text"
    if state.why == "interrupt_not_reported_yet":
        return "interrupt_not_reported_yet"
    return ""


async def join_running_turn(container: str, name: str, prompt: ts.QueuedPrompt) -> str:
    """Paste `prompt` into the turn running in `name` now, for session_send's
    deliver="join". Called under the session's send lock, with nothing queued.

    Returns "joined" once it went in; "idle" when no turn is running, so the caller
    sends as usual; else why it may not go in now (a waiting reason, or
    "interrupt_not_reported_yet"), and the caller queues it.

    Claude Code holds a prompt pasted mid-turn as a queue-operation and hands it to the
    turn at its next tool boundary (or runs it next, if the turn ends first);
    _prompt_arrived recognizes that arrival."""
    state = await tn.session_state(container, name)
    if state.claude_running and state.turn != tn.TURN_RUNNING:
        return "idle"
    refusal = _join_refusal(name, state)
    if not refusal and await sf.taint_or_none(name) is not None:
        refusal = "session_tainted"
    if refusal:
        log_event("session_send_join_declined", session=name, reason=refusal, why=state.why)
        return refusal
    if not await inject(container, prompt.paste(), tmx.SESSION_WINDOW, session=name,
                         sent_by=prompt.sent_by, prompts=[prompt]):
        log_event("session_send_join_declined", session=name, reason="paste_failing",
                  why=state.why)
        return "paste_failing"
    log_event("session_send_joined_turn", session=name, prompt_len=len(prompt.paste()),
              why=state.why)
    return "joined"


async def wait_until_free(container: str, name: str, timeout: float) -> str:
    """Poll _check_free until two consecutive readings are free (""), or the timeout
    runs out (the last reason). The timeout is held to on the clock: after a reading
    that was not free, no further reading starts that could not finish inside it, so
    slow readings (docker exec under load) cannot stretch the wait. A free reading is
    always confirmed by a second one, which may run past the timeout by one poll. The
    poll count still caps it, so the loop ends under a patched sleep too."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    polls = max(2, int(timeout / tn.FREE_POLL_S))
    streak = 0
    reason = ""
    for i in range(polls):
        started = loop.time()
        reason = await _check_free(container, name)
        streak = 0 if reason else streak + 1
        if streak >= 2:
            return ""
        took = loop.time() - started
        # A free reading always gets the second one it needs, even past the deadline:
        # stopping there would report a free session as busy.
        if i == polls - 1 or (streak == 0 and loop.time() + tn.FREE_POLL_S + took > deadline):
            break
        await asyncio.sleep(tn.FREE_POLL_S)
    return reason or "claude_busy"


def write_send_dead_letter(session: str, queued: ts.QueuedPrompt, reason: str) -> None:
    """Persist a prompt that will never be pasted because its session is gone, so it
    is recorded, not lost. Sibling of _write_dead_letter (an undelivered REPLY)."""
    dl = Path(ss.WATCHER_STATE_DIR) / "dead-letter"
    try:
        dl.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(
            f"{queued.enqueued_at}\n{queued.text}".encode()).hexdigest()[:16]
        (dl / f"send__{ts.slug(session)}__{digest}.json").write_text(
            json.dumps({"session": session, "prompt": queued.text, "reason": reason,
                        "prompt_id": queued.prompt_id,
                        "enqueued_at": queued.enqueued_at,
                        "paste_attempts": queued.paste_attempts,
                        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}),
            encoding="utf-8",
        )
    except OSError as exc:
        log_event("session_send_dead_letter_failed", session=session, reason=reason,
                  error_type=type(exc).__name__)


def _record_sent(name: str, text: str, sent_by: str = "",
                 batch: dict | None = None) -> None:
    """Remember a prompt the MCP just injected into `name`'s pane, and who it was
    sent for, so the drain can tell it apart from one a person typed at the
    terminal (see ts.record_sent_prompt). Best-effort: a failure to persist must
    not fail the send that already landed — it degrades to that one reply carrying
    a terminal-typed note it should not have, which the audit line explains."""
    try:
        ts.record_sent_prompt(ss.WATCHER_STATE_DIR, name, text, sent_by=sent_by, batch=batch)
    except OSError as exc:
        log_event("session_send_record_failed", session=name, prompt_len=len(text),
                  error_type=type(exc).__name__, error=repr(exc))
    if not batch:
        return
    try:
        # Only what lets session_queue_cancel say "too late" instead of "unknown".
        ts.record_pasted_ids(ss.WATCHER_STATE_DIR, name,
                             [p["prompt_id"] for p in batch["prompts"]], batch["pasted_at"])
    except OSError as exc:
        log_event("session_send_pasted_ids_failed", session=name,
                  error_type=type(exc).__name__, error=repr(exc))


async def inject(container: str, text: str, window: str, *, session: str,
                  sent_by: str = "", prompts: Sequence[ts.QueuedPrompt] = ()) -> bool:
    """Paste one message into the window and press Enter. True when it went in.

    The ONLY way a prompt reaches the pane, so it is also the only place the send
    record is written: a paste that landed is recorded here, on success, for
    `session`, with the person it was sent for (`sent_by`, "" for the caller's
    own) — the drain tells the orchestrator's prompts from a person's by that
    record alone, so a paste path that skipped it would ship a reply falsely
    framed as answering something the person typed. `prompts` are the session_send
    prompts `text` carries (one, or a batch joined by _BATCH_SEPARATOR); the record
    keeps each one's id, sender and conversation with the paste time, which the
    reply callback returns as `prompts` and `pasted_at`."""
    ids = tuple(q.prompt_id for q in prompts)
    # Judged against the screen the free check just read: every caller pastes only
    # after _check_free said "" for this session, which it says only having read the
    # screen (a session whose screen could not be read is never free). With the
    # background-agent list's pointer showing, the paste is confirmed in the input
    # box before Enter: Enter in the list opens an agent instead of sending.
    raw = ss.last_screen_raw.get(session)
    screen = scr.classify(raw) if raw is not None else None
    if ss.unsubmitted_paste.get(session) == (text, ids) and _own_unsent_text(session, screen):
        log_event("session_send_late_paste_submitted", session=session,
                  prompt_len=len(text))
    else:
        if not await tmx.load_and_paste(container, text, window):
            return False
        if screen is not None and screen.agent_pointed and not await _paste_in_box(
                container, window, session):
            # What the box showed last: still empty means the keys went elsewhere;
            # anything else means the screen changed under the paste.
            box = scr.classify(ss.last_screen_raw.get(session, "")).input_box
            ss.unsubmitted_paste[session] = (text, ids)
            log_event("session_send_paste_not_in_box", session=session,
                      prompt_len=len(text), input_box=box,
                      waited_s=_PASTE_CONFIRM_POLLS * _PASTE_CONFIRM_POLL_S)
            return False
    ss.unsubmitted_paste.pop(session, None)
    await tmx.tmux_exec(container, ["send-keys", "-t", f"main:{window}", "Enter"])
    batch = ({"pasted_at": ts.now_iso(),
              "prompts": [q.batch_entry() for q in prompts]}
             if prompts else None)
    _record_sent(session, text, sent_by, batch)
    # Until the transcript shows this prompt, a follow-up's free check must read the
    # session as busy: the mirrored transcript lags the paste by a couple of seconds,
    # and in that gap it still shows the previous, finished turn.
    sent_at = time.time()
    ss.sent_awaiting_echo[session] = (text, sent_at)
    com.fire(tn.watch_for_echo(session, text, sent_at))
    return True


async def _paste_in_box(container: str, window: str, session: str) -> bool:
    """Whether the input box shows text after a paste into an empty box, read a few
    times while Claude Code draws it. Any text counts: Claude Code shows a long paste
    as a placeholder (`[Pasted text #1]`), not as the words."""
    for i in range(_PASTE_CONFIRM_POLLS):
        raw = await tmx.capture_screen(container, window)
        ss.last_screen_raw[session] = raw
        if scr.classify(raw).input_box == scr.HAS_TEXT:
            return True
        if i < _PASTE_CONFIRM_POLLS - 1:
            await asyncio.sleep(_PASTE_CONFIRM_POLL_S)
    return False


async def _drop_prompts_of_removed_session(container: str, name: str) -> None:
    """Take out of `name`'s queue every prompt whose session no longer exists: all of
    them when the session is gone, and, when a session of the same name has a different
    instance (killed and created again), those accepted for the old one. Docker failing
    to answer removes nothing."""
    state, current = await tn.session_instance(name)
    if state == tn.SESSION_UNKNOWN:
        log_event("session_send_queue_session_unknown", session=name)
        return
    queue = ss.pending_sends.get(name, [])
    if state == tn.SESSION_GONE:
        dropped, kept = queue, []
    else:
        if not current:
            return
        dropped = [q for q in queue
                   if q.session_instance and q.session_instance != current]
        kept = [q for q in queue if q not in dropped]
    if not dropped:
        return
    if kept:
        ss.pending_sends[name] = kept
    else:
        ss.pending_sends.pop(name, None)
    _abandon_queue(name, dropped)
    persist_queue(name)


def persist_queue(name: str) -> None:
    # The batch in the box is saved with the queue, so a restart still knows it is the
    # session's (_load_persisted_queue_once restores it).
    in_box = set(batch_in_box(name))
    for q in ss.pending_sends.get(name, []):
        q.in_box = q.prompt_id in in_box
    try:
        ts.save_send_queue(ss.WATCHER_STATE_DIR, name, ss.pending_sends.get(name, []))
    except OSError as exc:
        log_event("session_send_queue_persist_failed", session=name,
                  error_type=type(exc).__name__, error=repr(exc))


async def _set_waiting_reason(container: str, name: str, reason: str) -> None:
    """Record why the queue's head is waiting (the rest wait behind it), persist on a
    change, and show or clear the tmux status-line notice for unsent input."""
    queue = ss.pending_sends.get(name)
    if not queue:
        return
    await show_waiting_on_input(container, name, reason == "input_has_text")
    wanted = [reason] + ["queued_behind"] * (len(queue) - 1)
    if [q.waiting_reason for q in queue] == wanted:
        return
    for q, r in zip(queue, wanted, strict=True):
        q.waiting_reason = r
    persist_queue(name)
    log_event("session_send_queue_waiting", session=name, reason=reason, depth=len(queue))


async def show_waiting_on_input(container: str, name: str, show: bool) -> None:
    """Set or clear the status-line notice, tracking whether it is showing on its own
    (not from a prompt's reason, which other paths overwrite)."""
    if show == (name in ss.waiting_notice_shown):
        return
    args = (["set-option", "-t", "main", "@aidc_waiting", _WAITING_ON_INPUT_TEXT] if show
            else ["set-option", "-t", "main", "-u", "@aidc_waiting"])
    await tmx.tmux_exec(container, args)
    if show:
        ss.waiting_notice_shown.add(name)
    else:
        ss.waiting_notice_shown.discard(name)


async def _drain_pending_sends(container: str, name: str) -> None:
    """Paste queued prompts into `name`'s pane as it becomes free: every prompt
    waiting at that moment goes in together, as one message in queue order joined by
    _BATCH_SEPARATOR (_next_batch), so a session that was busy gets its backlog in one
    turn rather than one turn per prompt.

    Runs until the queue empties or the session's container is gone, and never gives
    up on a prompt otherwise: a busy Claude, unsent text in the input box, a stopped
    Claude or a failing paste all just keep it waiting, with the reason recorded.

    The long free-wait happens WITHOUT the send lock held — holding it across a
    22-minute turn would block every concurrent session_send for the duration. The
    lock is taken only around the paste itself, which is what actually needs
    serializing against a direct send, and against session_queue_cancel: the batch is
    chosen and pasted under the lock, so a prompt is either in it or cancelled. Order
    is preserved because session_send enqueues rather than pasting whenever the queue
    is non-empty."""
    lock = ss.session_send_locks.setdefault(name, asyncio.Lock())
    failed = False
    try:
        while ss.pending_sends.get(name):
            await _drop_prompts_of_removed_session(container, name)
            if not ss.pending_sends.get(name):
                return
            _notify_long_waits(name)
            reason = await wait_until_free(container, name, timeout=_QUEUE_POLL_S)
            if reason:
                await _set_waiting_reason(container, name, reason)
                continue
            retry_in = 0.0
            async with lock:
                queue = ss.pending_sends.get(name)
                if not queue:
                    return
                # Re-verify under the lock: the session may have picked up work
                # between the wait above and acquiring it.
                reason = await _check_free(container, name)
                if reason:
                    await _set_waiting_reason(container, name, reason)
                    continue
                # And again that the prompt's session is still this one: the wait above
                # can be long enough for it to be killed and created again.
                await _drop_prompts_of_removed_session(container, name)
                queue = ss.pending_sends.get(name)
                if not queue:
                    return
                batch = _next_batch(name)
                head = batch[0]
                text = _BATCH_SEPARATOR.join(q.paste() for q in batch)
                if await sf.taint_or_none(name) is not None:
                    # A prompt accepted before the session was tainted is never pasted
                    # into it: it waits, saying why, until the person kills the session
                    # (which hands the queue to the dead-letter dir and tells its
                    # conversation). Checked here, under the lock, right before the paste.
                    await _set_waiting_reason(container, name, "session_tainted")
                    log_event("session_send_queue_held_tainted", session=name,
                              depth=len(queue))
                    retry_in = _QUEUE_POLL_S
                elif await inject(container, text, tmx.SESSION_WINDOW, session=name,
                                   sent_by=_batch_sent_by(batch), prompts=batch):
                    pasted = {id(q) for q in batch}
                    queue[:] = [q for q in queue if id(q) not in pasted]
                    ss.drainer_failures.pop(name, None)
                    await show_waiting_on_input(container, name, False)
                    if not queue:
                        ss.pending_sends.pop(name, None)
                    else:
                        queue[0].waiting_reason = ""
                    persist_queue(name)
                    log_event("session_send_queued_injected", session=name,
                              prompt_len=len(text), batch=len(batch),
                              prompt_ids=[q.prompt_id for q in batch],
                              remaining=len(queue), paste_attempts=head.paste_attempts)
                    continue
                else:
                    for q in batch:
                        q.paste_attempts += 1
                    persist_queue(name)
                    await _set_waiting_reason(container, name, "paste_failing")
                    retry_in = min(_PASTE_RETRY_MAX_S, 2.0 ** min(head.paste_attempts, 6))
                    log_event("session_send_queued_paste_retry", session=name,
                              attempts=head.paste_attempts, retry_in_s=retry_in)
            await asyncio.sleep(retry_in)
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # prawduct:allow prawduct/broad-except -- drainer must survive
        failed = True
        log_event("session_send_queue_error", session=name,
                  error_type=type(exc).__name__, error=repr(exc))
    finally:
        if ss.pending_drainers.get(name) is asyncio.current_task():
            ss.pending_drainers.pop(name, None)
            # A send that queued while this drainer was winding down would
            # otherwise be orphaned: enqueue_send saw a live (not-yet-done)
            # drainer and declined to start one, and then that drainer exited. The
            # same applies when the drainer stopped on an unexpected error: the
            # prompts are still accepted, so hand them to a fresh drainer, after a
            # backoff so an error that recurs every cycle does not spin.
            if ss.pending_sends.get(name):
                delay = 0.0
                if failed:
                    n = ss.drainer_failures.get(name, 0) + 1
                    ss.drainer_failures[name] = n
                    delay = min(_PASTE_RETRY_MAX_S, 2.0 ** min(n, 6))
                _spawn_drainer(container, name, delay=delay)


def _spawn_drainer(container: str, name: str, *, delay: float = 0.0) -> None:
    """Start the per-session drainer unless a live one is already registered."""
    drainer = ss.pending_drainers.get(name)
    if drainer is not None and not drainer.done():
        return

    async def run() -> None:
        if delay:
            await asyncio.sleep(delay)
        await _drain_pending_sends(container, name)

    task = asyncio.create_task(run())
    ss.pending_drainers[name] = task
    com.background_tasks.add(task)
    task.add_done_callback(com.background_tasks.discard)


async def enqueue_send(name: str, container: str, prompt: ts.QueuedPrompt,
                        reason: str) -> int:
    """Queue a prompt for pasting when the session frees up; returns queue depth.

    Returns 0 when the queue is at PENDING_MAX_DEPTH and the prompt was refused.
    Records why it waits (showing the status-line notice if that is unsent input),
    persists the queue, and starts the per-session drainer if one is not running."""
    # Read before touching the queue: nothing may await between taking the list and
    # appending to it, or the drainer can replace the list meanwhile and the prompt
    # would land in one nobody reads.
    _, instance = await tn.session_instance(name)
    queue = ss.pending_sends.setdefault(name, [])
    if len(queue) >= PENDING_MAX_DEPTH:
        return 0
    prompt.session_instance = instance
    queue.append(prompt)
    persist_queue(name)
    await _set_waiting_reason(container, name, queue[0].waiting_reason or reason)
    _spawn_drainer(container, name)
    return len(queue)


_DROPPED_NOTE = ("[Not delivered: the session '{session}' was removed before this prompt "
                 "could be pasted. It was never seen by the agent.]")


def _abandon_queue(name: str, prompts: list[ts.QueuedPrompt]) -> None:
    """The session these prompts were accepted for is gone. Record each in the send
    dead-letter dir, tell each prompt's conversation it was not delivered (never
    silence: the orchestrator was promised it would go in), and forget the session's
    send-path state."""
    for q in prompts:
        write_send_dead_letter(name, q, "session_killed")
    com.fire(_notify_prompts(name, [(q, _DROPPED_NOTE.format(session=name)) for q in prompts],
                          "prompt_dropped"))
    ss.forget_session_send_state(name)
    log_event("session_send_queue_abandoned", session=name, dropped=len(prompts),
              reason="session_killed")


async def _notify_prompts(name: str, notices: list[tuple[ts.QueuedPrompt, str]],
                         error_code: str) -> None:
    """Tell each queued prompt's conversation something about it that is not a reply:
    the note, a blank line, then the prompt, with `error_code` naming which (design 10
    D5). "prompt_dropped" is a failure, so ok is false; "prompt_waiting" is a status
    (nothing has failed, and a receiver that shows ok false as an error would invite a
    resend), so ok is true. Retried, and dead-lettered when it cannot be delivered,
    like a reply."""
    event = f"session_send_{error_code}_notified"
    base = orc.orchestrator_callback_url()
    for q, note in notices:
        if not q.conversation_id or not base:
            # Sent without a webhook: nobody to tell beyond the log.
            log_event(event, session=name, delivered=False,
                      reason="no_conversation" if base else "no_callback_url")
            continue
        digest = hashlib.sha256(f"{q.enqueued_at}\n{q.text}".encode()).hexdigest()[:16]
        turn = ts.Turn(terminal_uuid=f"{error_code}-{digest}", text=f"{note}\n\n{q.text}",
                       ok=error_code != "prompt_dropped", prompt_origin="orchestrator",
                       error_code=error_code,
                       batch=(q.batch_entry(),))

        async def post_fn(t: ts.Turn, attempt: int, cid: str = q.conversation_id) -> bool:
            return await cbk.post_turn(base, cid, t, attempt=attempt, session=name)

        try:
            delivered = await cbk.deliver_with_retry(turn, post_fn=post_fn)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- report, don't crash
            log_event(f"session_send_{error_code}_notify_error", session=name,
                      error_type=type(exc).__name__, error=repr(exc))
            delivered = False
        if not delivered:
            cbk.write_dead_letter(Path(ss.WATCHER_STATE_DIR), name, q.conversation_id, turn)
        log_event(event, session=name, conversation_id=q.conversation_id,
                  delivered=delivered)


# How long a queued prompt waits before its conversation is told, once, that it is
# still waiting (design 10 D5, MCP-36). A paste normally happens within seconds.
# AIDC_MCP_PROMPT_WAITING_S overrides it, for testing.
_PROMPT_WAITING_S = float(os.environ.get("AIDC_MCP_PROMPT_WAITING_S", "600"))


_WAITING_NOTE = ("[Still waiting: this prompt has been queued for the session '{session}' "
                 "for {minutes}, because {why}. It has not been seen by the agent yet. "
                 "It will still go in when the session is free.]")


def _notify_long_waits(name: str) -> None:
    """Tell each prompt that has waited _PROMPT_WAITING_S, once, that it is still
    waiting and why. Whatever keeps a queue from moving, a person's forgotten text, a
    dialog nobody answered, or a bug, the orchestrator was told the prompt would go in
    and would otherwise hear nothing."""
    queue = ss.pending_sends.get(name) or []
    now = time.time()
    due = []
    for q in queue:
        if q.waiting_notified:
            continue
        accepted = ts.wall_time({"timestamp": q.enqueued_at})
        if accepted is None or now - accepted < _PROMPT_WAITING_S:
            continue
        q.waiting_notified = True
        due.append((q, int(now - accepted)))
    if not due:
        return
    persist_queue(name)
    head_why = WAITING_EXPLAINED.get(queue[0].waiting_reason, "the session is not free")
    notices = []
    for q, waited in due:
        why = (head_why if q is queue[0]
               else f"{WAITING_EXPLAINED['queued_behind']} (held because {head_why})")
        minutes = waited // 60
        notices.append((q, _WAITING_NOTE.format(
            session=name, why=why,
            minutes=f"{minutes} minute{'s' if minutes != 1 else ''}" if minutes
            else f"{waited} seconds")))
        log_event("session_send_prompt_waiting", session=name, waited_s=waited,
                  reason=q.waiting_reason or "queued_behind")
    com.fire(_notify_prompts(name, notices, "prompt_waiting"))


async def load_persisted_queue(container: str, name: str) -> None:
    """Read `name`'s saved queue once per process, ahead of anything queued in memory,
    and start its drainer. Called under the session's send lock by both startup resume
    and session_send, so the two cannot race or reorder."""
    if name in ss.queue_loaded:
        return
    try:
        await _load_persisted_queue_once(container, name)
    except BaseException:
        # Not loaded after all: the next send or resume tries again, rather than
        # saving over prompts that were never read.
        ss.queue_loaded.discard(name)
        raise


async def _load_persisted_queue_once(container: str, name: str) -> None:
    ss.queue_loaded.add(name)
    path = ts.send_queue_path(ss.WATCHER_STATE_DIR, name)
    if not path.exists():
        return
    queues, unreadable = ts.load_send_queues(path.parent)
    if path in unreadable:
        # Kept for a person under another name, so saving this session's queue from
        # now on does not overwrite it.
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        aside = path.with_name(f"{path.name}.unreadable-{stamp}")
        try:
            path.rename(aside)
        except OSError as exc:
            log_event("session_send_queue_unreadable", path=str(path), kept_as="",
                      error_type=type(exc).__name__)
        else:
            log_event("session_send_queue_unreadable", path=str(path), kept_as=str(aside))
        return
    saved = queues.get(name, [])
    if not saved:
        return
    if (await tn.session_instance(name))[0] == tn.SESSION_GONE:
        _abandon_queue(name, saved)
        persist_queue(name)
        return
    ss.pending_sends[name] = saved + ss.pending_sends.get(name, [])
    in_box = []
    for q in saved:
        if not q.in_box:
            break
        in_box.append(q)
    if in_box and name not in ss.unsubmitted_paste:
        # A batch was pasted into the box and not submitted when the MCP stopped: it is
        # still the session's to submit as it is, and not a person's unsent text.
        ss.unsubmitted_paste[name] = (_BATCH_SEPARATOR.join(q.paste() for q in in_box),
                                    tuple(q.prompt_id for q in in_box))
    if saved[0].waiting_reason == "input_has_text":
        # The tmux option outlives the MCP; remember it is showing, so the drainer
        # clears it when the prompt goes in.
        ss.waiting_notice_shown.add(name)
    persist_queue(name)
    _spawn_drainer(container, name)
    log_event("session_send_queue_resumed", session=name, depth=len(saved))


async def resume_send_queues() -> None:
    """Pick up every persisted queue in scope after an aidc-mcp start. Unreadable
    queue files are logged and left for a person."""
    queues, unreadable = ts.load_send_queues(ss.WATCHER_STATE_DIR)
    for path in unreadable:
        log_event("session_send_queue_unreadable", path=str(path))
    for name in queues:
        if scope.refusal(name) is not None:
            continue   # another server's session: leave its queue file alone
        lock = ss.session_send_locks.setdefault(name, asyncio.Lock())
        async with lock:
            await load_persisted_queue(backend.target(name), name)


WAITING_EXPLAINED = {
    "claude_busy": "Claude is working on a turn",
    "input_has_text": "someone has unsent text in Claude's input box in the session "
                      "(the session's status line tells them)",
    "claude_not_running": "Claude is not running in the session",
    "claude_not_at_prompt": "Claude is showing a dialog (e.g. login) instead of its prompt",
    "screen_unrecognized": "aidc does not recognize Claude's screen",
    "paste_failing": "pasting into the session is failing and being retried",
    "queued_behind": "an earlier prompt is still waiting",
    "agent_list_selected": "someone in the session has the keyboard in Claude's background-"
                           "agent list, where typed keys are commands",
    "session_tainted": "the session is tainted, so nothing more is pasted into it; the person "
                       "has to kill and recreate it",
    # Only ever a join_declined: the prompt itself then waits as claude_busy.
    "interrupt_not_reported_yet": "the agent was just interrupted, and that has not been "
                                  "reported to its conversation yet",
}
