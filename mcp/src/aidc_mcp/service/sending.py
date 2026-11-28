"""Sending prompts (design-10 S3/S4, MCP-28..30): the per-session queue, its drainer, the
paste, joining a running turn, and the notes a waiting or dropped prompt gets.

No MCP types here (test_service_boundary): the tools in tearstools/ adapt it.
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import time
from collections.abc import Awaitable, Callable, Sequence
from pathlib import Path
from typing import Any

from aidc_mcp import audit, backend, headless, scope
from aidc_mcp import hook_events as he
from aidc_mcp import screen as scr
from aidc_mcp import session_facts as sf
from aidc_mcp import store as state_store
from aidc_mcp import transcript as ts
from aidc_mcp import turns_view as tv
from aidc_mcp.service import callbacks as cbk
from aidc_mcp.service import common as com
from aidc_mcp.service import config as orc
from aidc_mcp.service import delivery as dlv
from aidc_mcp.service import gitapprove
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
        audit.log_event("session_screen_save_failed", session=name, error_type=type(exc).__name__)


async def _check_free(container: str, name: str) -> str:
    """Whether a prompt can be pasted into the session now: "" or a reason (see
    tn.paste_reason). Every change of verdict is logged with its evidence, so a "free"
    reached without transcript evidence (no transcript, a stalled one, the status
    row) is on record."""
    state = await tn.session_state(container, name)
    reason = tn.paste_reason(state)
    if reason == "input_has_text" and _own_unsent_text(name, state.screen):
        reason = ""
    if not reason and held_elsewhere(name) is not None:
        reason = HELD_ELSEWHERE
    verdict = (reason, state.why)
    if ss.last_free_verdict.get(name) != verdict:
        ss.last_free_verdict[name] = verdict
        audit.log_event("session_free_check", session=name, reason=reason, turn=state.turn,
                  why=state.why)
        if reason == "screen_unrecognized":
            _save_unrecognized_screen(name)
    return reason


def _join_refusal(name: str, state: tn.SessionState) -> str:
    """Why a prompt may not be pasted into the turn running now (session_send's
    deliver="join"), or "". The screen rules of tn.paste_reason all hold: the turn
    being busy is the one they skip. And an Esc the watcher has not reported yet: a
    prompt pasted on top of it would bury the report (design 10 S1)."""
    if not state.claude_running or state.screen is None:
        return "claude_not_running"
    if state.screen.input_box == scr.NOT_AT_PROMPT:
        return tn.not_at_prompt_reason(state.screen)
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

    Returns "joined" once it went in; "idle" when an ordinary send applies (no turn is
    running and Claude is not at a first-launch screen), so the caller sends as usual;
    else why it may not go in now (a waiting reason, or "interrupt_not_reported_yet"),
    and the caller queues it.

    Claude Code holds a prompt pasted mid-turn as a queue-operation and hands it to the
    turn at its next tool boundary (or runs it next, if the turn ends first);
    _prompt_arrived recognizes that arrival."""
    state = await tn.session_state(container, name)
    # A first-launch screen is no turn, but not a prompt an ordinary send can go into either.
    if state.claude_running and state.turn != tn.TURN_RUNNING and state.why != tn.WHY_NOT_AT_PROMPT:
        return "idle"
    refusal = _join_refusal(name, state)
    if not refusal and await sf.taint_or_none(name) is not None:
        refusal = "session_tainted"
    if refusal:
        audit.log_event("session_send_join_declined", session=name, reason=refusal, why=state.why)
        return refusal
    if not await inject(container, prompt.paste(), tmx.SESSION_WINDOW, session=name,
                         sent_by=prompt.sent_by, prompts=[prompt]):
        audit.log_event("session_send_join_declined", session=name, reason="paste_failing",
                  why=state.why)
        return "paste_failing"
    audit.log_event("session_send_joined_turn", session=name, prompt_len=len(prompt.paste()),
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
    is recorded, not lost. Sibling of cbk.write_dead_letter (an undelivered REPLY)."""
    try:
        state_store.for_dir(ss.WATCHER_STATE_DIR).add_dead_letter(
            "send", session, queued.conversation_id, reason,
            {"session": session, "prompt": queued.text, "reason": reason,
             "prompt_id": queued.prompt_id,
             "enqueued_at": queued.enqueued_at,
             "paste_attempts": queued.paste_attempts,
             "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    except Exception as exc:  # prawduct:allow prawduct/broad-except -- logged, never lost silently
        audit.log_event("session_send_dead_letter_failed", session=session, reason=reason,
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
        audit.log_event("session_send_record_failed", session=name, prompt_len=len(text),
                  error_type=type(exc).__name__, error=repr(exc))
    if not batch:
        return
    try:
        # Only what lets session_queue_cancel say "too late" instead of "unknown".
        ts.record_pasted_ids(ss.WATCHER_STATE_DIR, name,
                             [p["prompt_id"] for p in batch["prompts"]], batch["pasted_at"])
    except OSError as exc:
        audit.log_event("session_send_pasted_ids_failed", session=name,
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
        audit.log_event("session_send_late_paste_submitted", session=session,
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
            audit.log_event("session_send_paste_not_in_box", session=session,
                      prompt_len=len(text), input_box=box,
                      waited_s=_PASTE_CONFIRM_POLLS * _PASTE_CONFIRM_POLL_S)
            return False
    ss.unsubmitted_paste.pop(session, None)
    watermark = (he.newest_event_name(Path(ss.TRANSCRIPTS_BASE) / session)
                 if backend.kind() == backend.KUBERNETES else "")
    await tmx.tmux_exec(container, ["send-keys", "-t", f"main:{window}", "Enter"])
    if await _refused_by_lease(session, watermark):
        # Claude Code erased the prompt: no turn, nothing recorded. The caller keeps it
        # queued, and the free check holds it a while before asking again.
        audit.log_event("session_send_refused_held_elsewhere", session=session,
                  prompt_len=len(text), holder=_holder(session))
        return False
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
    com.session_changed(session)
    return True


#: A cluster session's conversation is synced with the user's machines, and one machine at a
#: time works on it (its lease, .devcontainer/claude-lease.sh). The lease's prompt hook, refusing
#: a prompt because another machine holds the conversation, writes a PromptRefused hook event
#: naming the holder, in the session's own event sequence; a prompt that goes through writes its
#: UserPromptSubmit there. Both are read in that sequence (the session pod's clock), never
#: against this server's clock.
HELD_ELSEWHERE = "conversation_held_elsewhere"
#: How long after Enter the prompt's own event is waited for.
_REFUSAL_WAIT_S = 5.0
_REFUSAL_POLL_S = 0.2
#: After a refusal, how long the queue waits before it tries again (this server's clock): the
#: other machine letting go of the conversation is not seen here, so the next paste asks.
HELD_RETRY_S = 60.0


def held_elsewhere(name: str, now: float | None = None) -> dict[str, Any] | None:
    """Who holds session `name`'s conversation, while its queue waits on that ({holder}), or
    None: the newest prompt event is not a refusal, or the wait after it (HELD_RETRY_S, from
    when this server saw it) is over, so the next paste asks again."""
    held = ss.lease_held.get(name)
    if held is None:
        return None
    if held.retry_at <= (time.time() if now is None else now):
        ss.lease_held.pop(name, None)
        return None
    return {"holder": held.holder}


def _holder(name: str) -> str:
    held = ss.lease_held.get(name)
    return held.holder if held is not None else ""


async def _refused_by_lease(session: str, watermark: str) -> bool:
    """Whether the prompt just entered into a cluster session was refused by its lease
    (another machine holds the conversation): the first prompt event written after
    `watermark` (the session's newest event before Enter) is a PromptRefused. Its
    UserPromptSubmit ends the wait at once; with neither in time, the paste stands. Never on
    Docker, whose sessions run no lease."""
    if backend.kind() != backend.KUBERNETES:
        return False
    mirror = Path(ss.TRANSCRIPTS_BASE) / session
    for _ in range(max(1, int(_REFUSAL_WAIT_S / _REFUSAL_POLL_S))):
        for event in he.read_events(mirror, after=watermark):
            if event.event == he.PROMPT_REFUSED:
                holder = event.data.get("holder")
                ss.lease_held[session] = ss.Held(time.time() + HELD_RETRY_S,
                                                     holder if isinstance(holder, str) else "")
                return True
            if event.event == he.USER_PROMPT_SUBMIT:
                ss.lease_held.pop(session, None)
                return False
        await asyncio.sleep(_REFUSAL_POLL_S)
    audit.log_event("session_send_prompt_event_not_seen", session=session,
              waited_s=_REFUSAL_WAIT_S)
    return False


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
        audit.log_event("session_send_queue_session_unknown", session=name)
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
        audit.log_event("session_send_queue_persist_failed", session=name,
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
    audit.log_event("session_send_queue_waiting", session=name, reason=reason, depth=len(queue))


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
                    # (which keeps the queue as send dead letters and tells its
                    # conversation). Checked here, under the lock, right before the paste.
                    await _set_waiting_reason(container, name, "session_tainted")
                    audit.log_event("session_send_queue_held_tainted", session=name,
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
                    audit.log_event("session_send_queued_injected", session=name,
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
                    audit.log_event("session_send_queued_paste_retry", session=name,
                              attempts=head.paste_attempts, retry_in_s=retry_in)
            await asyncio.sleep(retry_in)
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # prawduct:allow prawduct/broad-except -- drainer must survive
        failed = True
        audit.log_event("session_send_queue_error", session=name,
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

    task = com.background_task(run(), session=name, task="send_queue_drainer")
    ss.pending_drainers[name] = task
    ss.background_tasks.add(task)
    task.add_done_callback(ss.background_tasks.discard)


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
    """The session these prompts were accepted for is gone. Keep each as a send dead
    letter, tell each prompt's conversation it was not delivered (never
    silence: the orchestrator was promised it would go in), and forget the session's
    send-path state."""
    for q in prompts:
        write_send_dead_letter(name, q, "session_killed")
    com.fire(_notify_prompts(name, [(q, _DROPPED_NOTE.format(session=name)) for q in prompts],
                          "prompt_dropped"))
    ss.forget_session_send_state(name)
    audit.log_event("session_send_queue_abandoned", session=name, dropped=len(prompts),
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
            audit.log_event(event, session=name, delivered=False,
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
            audit.log_event(f"session_send_{error_code}_notify_error", session=name,
                      error_type=type(exc).__name__, error=repr(exc))
            delivered = False
        if not delivered:
            cbk.write_dead_letter(Path(ss.WATCHER_STATE_DIR), name, q.conversation_id, turn)
        audit.log_event(event, session=name, conversation_id=q.conversation_id,
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
        audit.log_event("session_send_prompt_waiting", session=name, waited_s=waited,
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
    if not ts.has_send_queue(ss.WATCHER_STATE_DIR, name):
        return
    queues, unreadable = ts.load_send_queues(ss.WATCHER_STATE_DIR)
    if name in unreadable:
        # Kept for a person as a dead letter, so saving this session's queue from now on
        # does not overwrite it.
        store = state_store.for_dir(ss.WATCHER_STATE_DIR)
        store.add_dead_letter("send", name, "", "queue_unreadable",
                              store.get("send_queues", name))
        store.delete("send_queues", name)
        audit.log_event("session_send_queue_unreadable", session=name, kept_as="dead_letter")
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
    audit.log_event("session_send_queue_resumed", session=name, depth=len(saved))


async def resume_send_queues() -> None:
    """Pick up every persisted queue in scope after an aidc-mcp start. A stored queue
    that cannot be read is logged and left for a person."""
    queues, unreadable = ts.load_send_queues(ss.WATCHER_STATE_DIR)
    for name in unreadable:
        audit.log_event("session_send_queue_unreadable", session=name)
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
    tn.WHY_NOT_AT_PROMPT: ("Claude is showing a dialog instead of its prompt: a first-launch "
                           "screen (session_status names it in `dialog`) or a permission "
                           "prompt (session_status says why \"waiting_on_permission\"), which "
                           "a person at the session answers"),
    tn.WAIT_ON_QUESTION: ("Claude is asking a question (its question menu is open, "
                          "session_status says why \"waiting_on_question\"), and text typed "
                          "now would not answer it; the prompt goes in once the question is "
                          "answered"),
    HELD_ELSEWHERE: ("the conversation is open on another of the person's machines (it is "
                     "synced with them); the paste is tried again each minute, and goes in "
                     "once that machine has let it go"),
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


async def send(
    name: str,
    prompt: str,
    conversation_id: str | None = None,
    sent_by: str | None = None,
    sender_label: str | None = None,
    deliver: str = DELIVER_QUEUE,
    *,
    announce: Callable[[], Awaitable[None]],
) -> dict[str, Any]:
    """The session_send tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    # Who the prompt is for: the reply comes back with prompt_origin "person"
    # and this, so the orchestrator answers it as that person's and not as a
    # report on its own prompt.
    sent_by = (sent_by or "").strip()
    deliver = (deliver or DELIVER_QUEUE).strip()
    audit.log_event("tool_call", tool="session_send", session=name, prompt_len=len(prompt),
              sent_by=sent_by, sender_label=ts.clean_sender_label(sender_label),
              deliver=deliver)
    if deliver not in (DELIVER_QUEUE, DELIVER_JOIN):
        return com.envelope_err(
            f'deliver must be "{DELIVER_QUEUE}" or "{DELIVER_JOIN}", '
            f"not {deliver!r}", code="invalid_argument")
    container = backend.target(name)
    if (await tn.session_instance(name))[0] == tn.SESSION_GONE:
        # Checked before anything else, so a send to a session that does not exist
        # neither opens a webhook nor leaves one persisted. Audit every refusal:
        # these paths used to return silently, so the ONLY trace of a dropped send
        # was the ABSENCE of the session_send_sent line below — which is how prod
        # 2026-08-22 conv 01a01cf6 lost a prompt with nothing in the log naming it.
        audit.log_event("tool_call", tool="session_send_failed", session=name,
                  prompt_len=len(prompt), reason="no_such_session")
        ss.forget_session_send_state(name)
        return com.envelope_err(
            f"There is no session named '{name}'. "
            "Check session_list.", code="no_such_session"
        )
    if await tn.session_outdated(container, name):
        # Its Claude reports no hook events (it predates aidc 2.0), so whether it is free
        # cannot be told; refused at the door rather than queued behind a guess (MCP-47).
        audit.log_event("tool_call", tool="session_send_failed", session=name,
                  prompt_len=len(prompt), reason="session_outdated")
        return com.envelope_err(
            f"Session '{name}' predates aidc 2.0's hook events, so aidc cannot tell when it "
            f"is free. {tn.outdated_remedy(name)}",
            code="session_outdated")

    # An answer to the git agent's question about a waiting git request is carried out
    # here, as the request holder, before it goes into the question (gitapprove.py).
    answer = await gitapprove.answer_in(name, prompt, container)
    if answer.refusal is not None:
        return answer.refusal
    # A decided answer is never queued: it goes into the question menu, not the input box,
    # so a full queue (which fills while that menu is open: every prompt waits behind it) does
    # not hold it back.
    if answer.decision is not None:
        decided = await gitapprove.carry_out(answer.decision)
        return await _answer_git_question(name, conversation_id, container, answer.decision,
                                          decided, announce)
    return await _send_accepted(name, prompt, conversation_id, sent_by, sender_label,
                                deliver, container, announce)


async def _ensure_watcher(name: str, conversation_id: str | None,
                          announce: Callable[[], Awaitable[None]]) -> str:
    """Start the session's transcript watcher when none runs; "" or why none could be."""
    if name in ss.session_watchers:
        return ""
    base_url = orc.orchestrator_callback_url() if conversation_id else ""
    if not conversation_id:
        return ("no conversation_id was supplied — the orchestrator injects it automatically, "
                "so this call did not come from an orchestrated conversation")
    if not base_url:
        return f"{orc.callback_url_unset()}; replies have nowhere to be POSTed"
    await dlv.start_watcher(name, conversation_id, base_url, announce)
    audit.log_event("tool_call", tool="session_send_auto_watch", session=name,
              conversation_id=conversation_id)
    return ""


#: Answering Claude's question menu (AskUserQuestion): how many times the screen is read,
#: and how far apart, while Claude Code redraws it after a key.
_MENU_POLLS = 10
_MENU_POLL_S = 0.3

#: why answer_question_menu did not answer, for session_send's result
QUESTION_NOT_ANSWERED = {
    "request_not_decided": "the git request was not decided, so its question is left open: "
                           "send the answer again, or decide with aidc git approve|deny <id>",
    "no_question_on_screen": "Claude's question menu is not on the session's screen",
    "another_question": "the question on the screen does not name this git request",
    "several_questions": "the question menu holds more than one question",
    "no_such_option": "the question menu offers no such option",
    "pointer_not_moved": "the menu's pointer did not reach the option, so nothing was chosen",
    "keys_not_sent": "the keys could not be sent to the session's window",
    "menu_still_open": "Enter was pressed on the option, and the menu is still on the screen",
    "screen_unread": "Enter was pressed on the option, and the screen could not be read "
                     "since (empty, or not a screen aidc knows), so whether the question was "
                     "answered cannot be told",
    "another_dialog": "Enter was pressed on the option, and the screen now shows another "
                      "dialog instead of this question (the agent's next step waits on it)",
}

#: the dialog a screen shows (screen.ScreenState.dialog), as the result names it
_DIALOG_NAMES = {scr.TRUST_PROMPT: "the folder-trust prompt",
                 scr.ADD_DIR_PROMPT: "the prompt to add a folder",
                 scr.QUESTION_MENU: "another question"}


def dialog_name(screen: scr.ScreenState) -> str:
    """What a NOT_AT_PROMPT screen shows, in words."""
    return _DIALOG_NAMES.get(screen.dialog,
                             "a dialog aidc does not name (a permission prompt, for example)")


async def _read_question(container: str, name: str
                         ) -> tuple[scr.ScreenState, tn.QuestionState]:
    """The screen, and the question open on it (turns.open_question, the screen alone: the
    menu is answered only where it is seen, so a screen that cannot be read or classified
    is UNKNOWN)."""
    raw = await tmx.capture_screen(container, tmx.SESSION_WINDOW)
    ss.last_screen_raw[name] = raw
    screen = scr.classify(raw)
    return screen, tn.open_question(None, screen)


def _names(asked: tn.QuestionState, must_name: str) -> bool:
    return isinstance(asked, tn.OpenQuestion) and must_name in asked.request_ids


async def answer_question_menu(container: str, name: str, choice: str, must_name: str
                               ) -> tuple[str, str]:
    """Choose the option whose label starts with `choice` in the question menu open in the
    session, the one question it holds naming `must_name`. "" when it was answered, else why
    not (a QUESTION_NOT_ANSWERED key).

    The pointer is moved with the arrow keys and read back before Enter: a number key may
    choose its option at once, with no chance to check what was chosen, and Enter on the
    wrong option would answer the question wrongly. A menu that cannot be read, or whose
    pointer does not land on the option, gets no Enter. After Enter the question counts as
    answered only once a read shows a screen aidc knows without it: the input box (Claude at
    its prompt, or working), or a question about another request. Another dialog in its
    place (a permission prompt for the agent's next command) is "another_dialog", named in
    `dialog` (the second of the pair returned), never "screen_unread": the screen was read.
    A failed or empty read, or one aidc cannot classify, is not taken for the menu gone.
    Called under the session's send lock, so no paste goes in meanwhile.

    Returns (why not, or "", the dialog's name when why not is another_dialog)."""
    _, asked = await _read_question(container, name)
    if not isinstance(asked, tn.OpenQuestion) or asked.menu is None:
        return "no_question_on_screen", ""
    if not _names(asked, must_name):
        return "another_question", ""
    menu = asked.menu
    if menu.several:
        return "several_questions", ""
    matches = [n for n, label in menu.options if label.lower().startswith(choice.lower())]
    if len(matches) != 1:
        return "no_such_option", ""
    target = matches[0]
    target_window = f"main:{tmx.SESSION_WINDOW}"
    if menu.pointer != target:
        if not menu.pointer:
            return "pointer_not_moved", ""
        # One move, from where the pointer was read; then only read until it shows there.
        # Keys sent again on a screen not redrawn yet would overshoot.
        key = "Down" if target > menu.pointer else "Up"
        if await tmx.tmux_exec(container, ["send-keys", "-t", target_window,
                                           *[key] * abs(target - menu.pointer)]) != 0:
            return "keys_not_sent", ""
        for _ in range(_MENU_POLLS):
            await asyncio.sleep(_MENU_POLL_S)
            _, asked = await _read_question(container, name)
            if (not isinstance(asked, tn.OpenQuestion) or asked.menu is None
                    or not _names(asked, must_name)):
                return "pointer_not_moved", ""
            if asked.menu.pointer == target:
                break
        else:
            return "pointer_not_moved", ""
    if await tmx.tmux_exec(container, ["send-keys", "-t", target_window, "Enter"]) != 0:
        return "keys_not_sent", ""
    why_not, dialog = "screen_unread", ""
    for _ in range(_MENU_POLLS):
        await asyncio.sleep(_MENU_POLL_S)
        screen, asked = await _read_question(container, name)
        if asked is tn.UNKNOWN:
            continue
        if _names(asked, must_name):
            why_not, dialog = "menu_still_open", ""
        elif asked is not None or screen.input_box != scr.NOT_AT_PROMPT:
            com.session_changed(name)
            return "", ""
        else:
            why_not, dialog = "another_dialog", dialog_name(screen)
    return why_not, dialog


async def _answer_git_question(name: str, conversation_id: str | None, container: str,
                               decision: gitapprove.Decision, decided: dict[str, Any],
                               announce: Callable[[], Awaitable[None]]) -> dict[str, Any]:
    """session_send's end for an answer to the git agent's question about a git request,
    once the holder has carried it out: the same option is chosen in the agent's question
    menu, so its turn goes on (the menu takes no typed text). The holder's decision is what
    counts; the menu only lets the agent go on, so a menu that could not be answered is
    reported, never a failed send. Nothing is queued: typed text never reaches the menu,
    and pasted after it, it would be a second, stray prompt."""
    no_watch_reason = await _ensure_watcher(name, conversation_id, announce)
    dialog = ""
    # Decided, or no longer waiting: the option is chosen so the agent goes on and reports
    # the request's state (a failed one too). Only a request still waiting keeps its
    # question open, so the answer can be sent again.
    if decided.get("done") or decided.get("already_decided") or decided.get("failed"):
        lock = ss.session_send_locks.setdefault(name, asyncio.Lock())
        async with lock:
            why_not, dialog = await answer_question_menu(container, name, decision.verb,
                                                         decision.request_id)
    else:
        why_not = "request_not_decided"
    answered = not why_not
    audit.log_event("git_question_answered" if answered else "git_question_not_answered",
                    session=name, request_id=decision.request_id, option=decision.verb,
                    reason=why_not)
    watching = name in ss.session_watchers
    watched = dlv.watched_conversation(name) if watching else ""
    elsewhere = bool(conversation_id and watched and watched != conversation_id)
    reply_goes = "nowhere" if not watching else "elsewhere" if elsewhere else "here"
    where = (f"to conversation {watched} (one webhook per session), not this one" if elsewhere
             else "over the webhook" if watching
             else "nowhere: no webhook is open for this session"
             + (f" ({no_watch_reason})" if no_watch_reason else ""))
    option = decision.verb.capitalize()
    failed = bool(decided.get("failed"))
    holder_said = " ".join(str(decided.get("message", "")).split())[-500:]
    if failed:
        # The holder ran it and it failed: the request is failed now, so sending the same
        # answer again decides nothing.
        menu = (f"{option} was chosen in the git agent's question, so it goes on and reports "
                f"the failed request; its reply comes {where}." if answered
                else f"The git agent's question was not answered: "
                     f"{QUESTION_NOT_ANSWERED[why_not]}"
                     + (f" ({dialog})" if dialog else "") + ".")
        delivery = (f"The {option} was carried out and FAILED (git_request.code "
                    f"git_request_not_decided, git_request.failed): the git container says "
                    f"\"{holder_said}\". Git request {decision.request_id} is failed now. "
                    f"{menu} Nothing was typed into the session. Do NOT re-send the answer: it "
                    "would decide nothing. Tell the user why it failed; once that is fixed "
                    "(for example aidc git login), the session asks again.")
    elif decided.get("already_decided") and why_not == "no_question_on_screen":
        # Decided before this answer (another answer won the race, or it was decided
        # outside): the question is gone with it, and nothing is left to send.
        delivery = (f"git request {decision.request_id} was already decided "
                    "(git_request.already_decided), and the git agent has no question about "
                    "it on screen: this answer approved or denied nothing, and nothing was "
                    "sent. Do NOT re-send; git-requests show, or aidc git requests, says how "
                    "it was decided.")
    elif answered:
        settled = (" The request was already decided (git_request.already_decided), so this "
                   "answer approved or denied nothing." if decided.get("already_decided") else "")
        delivery = (f"Answered: {option} was chosen in the git agent's question, so its turn "
                    f"goes on; its reply comes {where}.{settled} Nothing else was sent. "
                    "Do NOT re-send.")
    elif why_not == "request_not_decided":
        delivery = (f"The {option} was NOT carried out (git_request.code "
                    f"git_request_not_decided): the git container says \"{holder_said}\". "
                    f"Git request {decision.request_id} still waits, and the git agent's "
                    "question is left open. Nothing was typed into the session. Send the "
                    f"answer again, or decide with aidc git {decision.verb} "
                    f"{decision.request_id}.")
    elif why_not == "another_dialog":
        delivery = (f"The git request's decision stands (git_request). {option} was chosen "
                    f"in the git agent's question, and its screen now shows {dialog} instead, "
                    "waiting for a person. Nothing was typed into the session. Tell the user "
                    "to look at the git agent's terminal.")
    else:
        delivery = (f"The git request's decision stands (git_request), but the git agent's "
                    f"question was not answered: {QUESTION_NOT_ANSWERED[why_not]}. Nothing "
                    "was typed into the session. Tell the user the question is still open in "
                    f"the git agent's terminal ({option} there lets it go on).")
    return com.envelope_ok({
        "status": "answered_question" if answered else "question_open",
        "session": name, "prompt_id": ts.new_prompt_id(), "reply_goes": reply_goes,
        "question_answered": answered,
        **({"question_not_answered": why_not} if why_not else {}),
        **({"dialog": dialog} if dialog else {}),
        "git_request": decided,
        **({"watched_conversation_id": watched} if watched else {}),
        "window": tmx.SESSION_WINDOW, "delivery": delivery})


async def _send_accepted(name: str, prompt: str, conversation_id: str | None, sent_by: str,
                         sender_label: str | None, deliver: str, container: str,
                         announce: Callable[[], Awaitable[None]]) -> dict[str, Any]:
    """session_send past its door checks: open the webhook, then paste or queue."""
    # Auto-register the transcript watcher if one isn't already running.
    # Capture WHY when we can't: both gates fail silently, and a send with no
    # watcher still injects the prompt and reports ok — so the reply is
    # produced and then dropped on the floor with nothing in the audit log
    # saying which gate closed (prod 2026-07-26: `orchestrator.callback_url` was
    # simply absent from config.yaml; every session_send logged
    # `watching:false` and no further clue, and diagnosis meant reading the
    # source). `no_watch_reason` names the gate so the log answers it.
    no_watch_reason = await _ensure_watcher(name, conversation_id, announce)

    lock = ss.session_send_locks.setdefault(name, asyncio.Lock())

    queued_depth = 0
    sanitized = prompt.replace("\n", " ").strip()
    # The prompt as one queue entry, whether it goes in now or waits (then this
    # object is what is queued): its id is what this call returns, what
    # session_queue_cancel takes and what the reply's `prompts` names.
    prompt_conversation = conversation_id or dlv.watched_conversation(name)
    # Framed here, once, so every path that pastes it (now, joined into a running
    # turn, or later from the queue) and everything that matches the paste against
    # the transcript afterwards (the send record, the echo hold, an unsubmitted
    # paste) sees the same text (paste()); `text` stays the prompt, for previews.
    # The header names the call's own conversation, never the webhook's: that is
    # where the reply goes, not who sent it.
    label = ts.clean_sender_label(sender_label)
    this_prompt = ts.QueuedPrompt(
        text=sanitized, enqueued_at=ts.now_iso(), conversation_id=prompt_conversation,
        sent_by=sent_by, sender_label=label,
        paste_text=ts.frame_prompt(sanitized, sender_label=label, sent_by=sent_by,
                                   conversation_id=conversation_id or ""))
    wait_reason = ""
    attempts = 0
    async with lock:
        # A queue saved before a restart goes first, even if this send arrives
        # before startup has resumed it.
        await load_persisted_queue(container, name)

        # Inject only when free so we never paste into a turn already in flight
        # or on top of a person's unsent text. A busy session does not cost the
        # prompt: it goes on the per-session
        # queue and the drainer injects it the moment the turn ends. Anything
        # already queued means this one MUST queue behind it, or a send would
        # overtake an earlier one that is still waiting.
        # deliver="join" pastes into a running turn instead, on one reading: the
        # two-reading wait exists to keep a prompt OUT of a turn just starting, which
        # is what joining asks for. It never overtakes a queued prompt either.
        joined = False
        join_declined = ""

        async def try_join() -> str:
            nonlocal joined, join_declined, wait_reason, attempts
            outcome = await join_running_turn(container, name, this_prompt)
            if outcome == "joined":
                joined, wait_reason = True, ""
            elif outcome == "paste_failing":
                join_declined, wait_reason, attempts = outcome, outcome, 1
            elif outcome != "idle":
                join_declined = outcome
            return outcome

        if ss.pending_sends.get(name):
            wait_reason = "queued_behind"
            if deliver == DELIVER_JOIN:
                join_declined = "queued_behind"
        else:
            first = await try_join() if deliver == DELIVER_JOIN else "idle"
            if not joined and not wait_reason:
                wait_reason = await wait_until_free(container, name,
                                                    timeout=SEND_FREE_WAIT_S)
            if deliver == DELIVER_JOIN and first == "idle" and wait_reason == "claude_busy":
                # Idle at the first reading, and a turn started during the wait.
                await try_join()
        if (not joined and not wait_reason
                and not await inject(container, this_prompt.paste(), tmx.SESSION_WINDOW,
                                     session=name, sent_by=sent_by,
                                     prompts=[this_prompt])):
            # A paste that did not land is a fact about one attempt, not about the
            # session: queue it, and the drainer retries with backoff.
            wait_reason = "paste_failing"
            attempts = 1
            audit.log_event("tool_call", tool="session_send_paste_failed", session=name,
                      prompt_len=len(prompt))
        if wait_reason:
            this_prompt.paste_attempts = attempts
            queued_depth = await enqueue_send(name, container, this_prompt, wait_reason)
            if queued_depth == 0:
                audit.log_event("tool_call", tool="session_send_failed", session=name,
                          prompt_len=len(prompt), reason="queue_full",
                          depth=PENDING_MAX_DEPTH)
                return com.envelope_err(
                    f"{PENDING_MAX_DEPTH} prompts are already queued for this "
                    "session and none has been injected yet — the session is "
                    "wedged or the agent is not consuming them. Stop sending and "
                    "tell the user to check the session.", code="queue_full"
                )
            audit.log_event("tool_call", tool="session_send_queued", session=name,
                      prompt_len=len(prompt), depth=queued_depth, reason=wait_reason)

    # Non-blocking: the reply is delivered by the transcript watcher, not returned
    # here. If no watcher is open, the reply has nowhere to go — say so plainly.
    watching = name in ss.session_watchers
    audit.log_event("tool_call", tool="session_send_sent", session=name, watching=watching,
              no_watch_reason=no_watch_reason, queued_depth=queued_depth)
    waiting_why = WAITING_EXPLAINED.get(wait_reason, wait_reason)
    # One webhook per session: a caller that did not open it does not get the
    # reply. Saying "delivered to this conversation" then is false, and the
    # caller waits for a reply that goes elsewhere (live 2026-10-08: a project's
    # brief and every reply to it went to the conversation that sent a stray
    # task first).
    watched = dlv.watched_conversation(name) if watching else ""
    elsewhere = bool(conversation_id and watched and watched != conversation_id)
    not_joined = (f"Not joined to the running turn: "
                  f"{WAITING_EXPLAINED.get(join_declined, join_declined)}. "
                  if join_declined else "")
    if joined:
        delivery = (
            "Joined — pasted into the turn the agent is already working on; it takes "
            "the prompt in at its next step (or runs it next, if the turn ends first). "
            "The reply is not separate: it comes in that turn's final answer"
            + (f", to conversation {watched} (one webhook per session), not this one"
               if elsewhere else ", over the webhook" if watching
               else ", but no webhook is open for this session, so it will NOT be "
               "auto-delivered")
            + ". Do NOT re-send it."
        )
    elif elsewhere:
        delivery = not_joined + (
            (f"Queued — held because {waiting_why}. It will be pasted automatically "
             f"as soon as the session is free ({queued_depth} waiting, this one "
             "last). Do NOT re-send it. " if queued_depth else "Sent. ")
            + "Claude's reply will NOT come to this conversation: it goes to "
            f"conversation {watched}, which opened this session's webhook first "
            "(one webhook per session). To move the replies here, call "
            "session_unwatch and then session_watch for this session."
        )
    elif watching and queued_depth:
        delivery = not_joined + (
            f"Queued — held because {waiting_why}. It will be pasted automatically "
            f"as soon as the session is free ({queued_depth} "
            "waiting, this one last). Nothing is lost and there is nothing to "
            "retry: do NOT re-send it, and do NOT call session_resend — the reply "
            "to THIS prompt arrives over the webhook like any other. Keep talking "
            "to the user meanwhile."
        )
    elif watching:
        delivery = (
            "Sent. Claude's reply will be delivered to this conversation via "
            "webhook when the turn finishes — keep talking to the user meanwhile."
        )
    else:
        # Deliberately still ok=True: the prompt was injected (or is queued for
        # injection) and the session will work on it. Returning an error would
        # invite the caller to retry, putting a second copy of the prompt into
        # the same tmux window.
        delivery = not_joined + (
            (f"Queued (held because {waiting_why}), but " if queued_depth
             else "Sent, but ")
            + "no webhook is open for this session, so the reply will NOT "
            "be auto-delivered"
            + (f" ({no_watch_reason})" if no_watch_reason else "")
            + ". Do NOT re-send — the prompt was accepted and the session will "
            "work on it. Use session_invoke to block for the answer "
            "instead, or tell the user to fix the cause above."
        )
    # Where the reply goes, as a field a caller branches on rather than a sentence
    # it parses: here, to another conversation, or nowhere.
    # The same rule the delivery sentence above follows.
    reply_goes = "nowhere" if not watching else "elsewhere" if elsewhere else "here"
    status = "joined_turn" if joined else "queued" if queued_depth else "sent"
    # What the agent is busy with, so a caller whose prompt waits (or joined) can
    # decide what to do next without another call: the fields session_status gives,
    # under its rule: only while the agent is working on a turn (the prompt joined
    # it, or waits because of it). A prompt held for any other reason, or sent to an
    # idle session, has no turn to describe.
    busy = joined or (queued_depth and wait_reason == "claude_busy")
    turn = (tv.turn_info(tn.session_transcript(name)[0]) if busy
            else tv.NO_TURN if status != "sent" else {})
    return com.envelope_ok(
        {"status": status, "session": name, "prompt_id": this_prompt.prompt_id,
         "reply_goes": reply_goes,
         "queued_behind": max(0, queued_depth - 1),
         **({"waiting_reason": wait_reason} if queued_depth else {}),
         **({"join_declined": join_declined} if join_declined else {}),
         **turn,
         # Headless runs (session_invoke) this server has going in the session:
         # they work in the same tree as the agent.
         **({"headless_runs": runs} if status != "sent" and (
             runs := headless.tracked(name)) else {}),
         **({"watched_conversation_id": watched} if watched else {}),
         "window": tmx.SESSION_WINDOW, "delivery": delivery}
    )


async def queue_cancel(
    name: str,
    position: int | None = None,
    prompt_id: str | None = None,
) -> dict[str, Any]:
    """The session_queue_cancel tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    container = backend.target(name)
    prompt_id = (prompt_id or "").strip()
    if prompt_id and position is not None:
        return com.envelope_err("give position or prompt_id, not both",
                                code="invalid_argument")
    lock = ss.session_send_locks.setdefault(name, asyncio.Lock())
    pasted_at = ""
    async with lock:
        # Under the send lock, the one the drainer chooses and pastes its batch
        # under, so a prompt cannot be pasted and taken back at once.
        await load_persisted_queue(container, name)
        queue = ss.pending_sends.get(name, [])
        listed = [(i + 1, q) for i, q in enumerate(queue)]
        # A batch pasted into the input box and waiting for its Enter is the
        # session's already: the drainer submits it as it is.
        in_box = set(batch_in_box(name))
        if prompt_id:
            taken = [(i, q) for i, q in listed if q.prompt_id == prompt_id]
            if taken and prompt_id in in_box:
                taken, outcome = [], "already_pasted"
            elif taken:
                outcome = "cancelled"
            else:
                pasted_at = ts.pasted_at_of(ss.WATCHER_STATE_DIR, name, prompt_id)
                outcome = "already_pasted" if pasted_at else "unknown"
        elif position is None:
            taken = [(i, q) for i, q in listed if q.prompt_id not in in_box]
            outcome = ("cancelled" if taken else "already_pasted" if listed
                       else "nothing_waiting")
        elif 1 <= position <= len(queue):
            taken = [listed[position - 1]]
            if taken[0][1].prompt_id in in_box:
                taken, outcome = [], "already_pasted"
            else:
                outcome = "cancelled"
        else:
            waiting = "; ".join(f"{i}: {q.text[:60]}" for i, q in listed) or "none"
            return com.envelope_err(
                f"there is no waiting prompt {position}; waiting: {waiting}",
                code="not_found")
        gone = {id(q) for _, q in taken}
        queue[:] = [q for q in queue if id(q) not in gone]
        if taken:
            if not queue:
                ss.pending_sends.pop(name, None)
                await show_waiting_on_input(container, name, False)
            persist_queue(name)
            for _, q in taken:
                write_send_dead_letter(name, q, "cancelled")
    state = await tn.session_state(container, name)
    working = state.claude_running and state.turn == tn.TURN_RUNNING
    objs, _, _ = tn.session_transcript(name)
    cancelled = [{"prompt_id": q.prompt_id, "position": i, "prompt_preview": q.text[:120],
                  "enqueued_at": q.enqueued_at, "conversation_id": q.conversation_id}
                 for i, q in taken]
    audit.log_event("tool_call", tool="session_queue_cancel", session=name, outcome=outcome,
              prompt_id=prompt_id, cancelled=len(cancelled), left=len(queue))
    data: dict[str, Any] = {
        "session": name, "outcome": outcome, "cancelled": cancelled, "left": len(queue),
        "running": {"working": working,
                    **(tv.turn_info(objs) if working else tv.NO_TURN)}}
    if prompt_id:
        data["prompt_id"] = prompt_id
    if outcome == "already_pasted":
        data["pasted_at"] = pasted_at or None
        data["note"] = (f"too late: the prompt was pasted at {pasted_at}" if pasted_at
                        else "too late: the prompt is in the input box being submitted")
    elif outcome == "unknown":
        data["note"] = f"no prompt {prompt_id} was sent to this session"
    elif not cancelled:
        data["note"] = "no prompt was waiting"
    return com.envelope_ok(data)
