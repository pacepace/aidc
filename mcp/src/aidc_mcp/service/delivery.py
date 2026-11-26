"""Transcript-sourced delivery (design-09, MCP-15..19): the per-session watchers, the
drain that turns transcript lines into exactly-once callbacks, resend, and resume.

No MCP types here (test_service_boundary): the tools in tearstools/ adapt it.
"""

from __future__ import annotations

import asyncio
import dataclasses
import time
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from aidc_mcp import audit, backend, scope
from aidc_mcp import screen as scr
from aidc_mcp import transcript as ts
from aidc_mcp.service import callbacks as cbk
from aidc_mcp.service import common as com
from aidc_mcp.service import config as orc
from aidc_mcp.service import state as ss
from aidc_mcp.service import tmux as tmx
from aidc_mcp.service import turns as tn


def _terminal_prompts(session: str, prompts: tuple[str, ...],
                      state_dir: Path) -> tuple[list[str], str, dict | None]:
    """The subset of a turn's opening prompts that a PERSON typed at the terminal:
    every prompt that does not match one the MCP itself injected (each match
    consumes its record entry); who the injected ones were sent for, the
    last one's ``sent_by`` that names anyone ("" when every one was the caller's
    own); and the batch they carried (``{"pasted_at", "prompts"}``: the latest
    paste's time and every batched prompt in paste order, or None when no match
    carried one). A record that cannot be updated counts the prompt as the MCP's
    own — an orchestrator prompt mislabelled as the person's is the confusion this
    exists to remove, so it is the side never to err on."""
    typed: list[str] = []
    sent_by = ""
    batch: dict | None = None
    for prompt in prompts:
        try:
            entry = ts.take_sent_entry(state_dir, session, prompt)
        except OSError as exc:
            audit.log_event("transcript_sent_record_failed", session=session,
                      error_type=type(exc).__name__, error=repr(exc))
            continue
        if entry is None:
            typed.append(prompt)
            continue
        if entry["by"]:
            sent_by = entry["by"]
        if entry.get("batch"):
            batch = {"pasted_at": entry["batch"]["pasted_at"],
                     "prompts": (batch["prompts"] if batch else []) + entry["batch"]["prompts"]}
    return typed, sent_by, batch


def _dirs(transcripts_base: Path | None, state_dir: Path | None) -> tuple[Path, Path]:
    """The transcripts base and watcher-state dirs a delivery entry point works in: the ones
    given, else ss.TRANSCRIPTS_BASE and ss.WATCHER_STATE_DIR as they are NOW. Every entry point
    takes them as None-defaulted parameters and resolves them here, at call time, never as
    def-time defaults (which would freeze the value seen at import, so patching ss would miss
    that path)."""
    return (ss.TRANSCRIPTS_BASE if transcripts_base is None else transcripts_base,
            ss.WATCHER_STATE_DIR if state_dir is None else state_dir)


def _with_joined(session: str, batch: dict | None, state_dir: Path) -> dict | None:
    """`batch` with every prompt joined into the turn since (deliver="join") after its
    own, each once; they are answered in this reply. The turn's continuations then name
    them too. pasted_at stays the turn's own paste, or the first join's without one."""
    try:
        joined = ts.take_joined_batches(state_dir, session)
    except OSError as exc:
        audit.log_event("transcript_joined_record_failed", session=session,
                  error_type=type(exc).__name__, error=repr(exc))
        return batch
    if not joined:
        return batch
    merged = {"pasted_at": batch["pasted_at"] if batch else joined[0]["pasted_at"],
              "prompts": list(batch["prompts"]) if batch else []}
    seen = {p["prompt_id"] for p in merged["prompts"]}
    for b in joined:
        for p in b["prompts"]:
            if p["prompt_id"] not in seen:
                seen.add(p["prompt_id"])
                merged["prompts"].append(p)
    origin, sent_by = ts.last_prompt_origin(state_dir, session)
    try:
        ts.record_prompt_origin(state_dir, session, origin, sent_by=sent_by, batch=merged)
    except OSError as exc:
        audit.log_event("transcript_origin_record_failed", session=session,
                  error_type=type(exc).__name__, error=repr(exc))
    return merged


def _carry_prompt_origin(session: str, turn: ts.Turn, origin: str, sent_by: str,
                         batch: dict | None,
                         state_dir: Path) -> tuple[str, str, dict | None]:
    """Whose prompt a turn answers, and who sent it when a person did, carried
    across the turn's continuations.

    A prompted turn's origin is recorded for its session. A turn with no prompt
    of its own -- a continuation past the read window, a task notification, an
    auto-continue -- is the same piece of work, so it answers the same party and
    takes the recorded origin, and the pasted batch it answers. Delivered as "", a
    night of continuations of turns a person typed (2026-10-08) read to the
    orchestrator as replies to its own prompts. A record that cannot be written
    leaves the origin as computed."""
    if turn.prompts:
        try:
            ts.record_prompt_origin(state_dir, session, origin, sent_by=sent_by, batch=batch)
        except OSError as exc:
            audit.log_event("transcript_origin_record_failed", session=session,
                      error_type=type(exc).__name__, error=repr(exc))
        return origin, sent_by, batch
    return (*ts.last_prompt_origin(state_dir, session),
            ts.last_prompt_batch(state_dir, session))


def watched_conversation(name: str) -> str:
    """The conversation `name`'s open webhook delivers to, or "" without one."""
    if name not in ss.session_watchers:
        return ""
    watches, _ = ts.load_watches(ss.WATCHER_STATE_DIR)
    return next((w["conversation_id"] for w in watches if w["session"] == name), "")


async def resume_watches(on_resumed: Callable[[], None]) -> None:
    """Re-open every persisted webhook in scope whose session still exists, WITHOUT
    re-baselining: delivery continues from the saved watermark, and the delivery
    ledger keeps it exactly once. A reply produced while the MCP was down, such as
    one to a prompt resumed from the queue, is delivered once rather than skipped.
    `on_resumed` runs once when any webhook was re-opened (the MCP adapter refreshes
    the tool descriptions that list them)."""
    watches, unreadable = ts.load_watches(ss.WATCHER_STATE_DIR)
    for path in unreadable:
        audit.log_event("session_watch_unreadable", path=str(path))
    resumed = False
    for w in watches:
        name = w["session"]
        if scope.refusal(name) is not None or name in ss.session_watchers:
            continue
        state, current = await tn.session_instance(name)
        gone = state == tn.SESSION_GONE
        recreated = bool(w["session_instance"] and current
                         and current != w["session_instance"])
        if gone or recreated:
            # The conversation was watching a session that no longer exists; a new
            # session under the same name has not been asked to report to it.
            ts.remove_watch(ss.WATCHER_STATE_DIR, name)
            ss.forget_session_send_state(name)
            audit.log_event("session_watch_dropped", session=name,
                      reason="session_killed" if gone else "session_recreated")
            continue
        _register_watcher(name, w["conversation_id"], w["callback_base"])
        audit.log_event("session_watch_resumed", session=name, conversation_id=w["conversation_id"])
        resumed = True
    if resumed:
        # No client is connected this early, so there is nobody to notify: each one
        # reads the refreshed descriptions when it lists tools.
        on_resumed()


async def _baseline_watermark(session: str, conversation_id: str, *,
                              transcripts_base: Path | None = None,
                              state_dir: Path | None = None) -> None:
    """Forward-only anchor on EVERY watcher (re)start (MCP-17, forward-only-on-connect).

    Re-anchor ``last_delivered_uuid`` to the current LAST completed turn of the
    active transcript, so a (re)connecting orchestrator conversation is NEVER caught up with
    a backlog — only turns that complete AFTER the (re)connect are delivered.

    Previously this no-op'd when a mark already existed ("resume"), which meant a
    reconnect / MCP-restart / a mark left stale from a prior life replayed the whole
    gap from the old position to now — the connect-catch-up runaway (prod
    2026-07-09, conv 019f4220).

    Runs at watcher (RE)START, not on every send: ``session_send`` calls
    ``start_watcher`` only when no live watcher is registered (a first send after
    an MCP restart, where the in-memory registry is empty), and ``session_watch``
    calls it explicitly. A send with a watcher already live does NOT re-register, so
    it does not re-anchor. On a (re)start the anchor is set BEFORE the prompt is
    injected, so the response — a strictly-later turn — is still delivered; only
    pre-existing history is skipped. Forward-only.

    The loop-guard runs (``consecutive_deliveries``, ``deliveries_since_idle``,
    ``last_delivery_at``) are PRESERVED across the re-anchor (loaded from the
    existing mark), so the ongoing-runaway backstop keeps accumulating: a re-anchor
    never resets it.

    Called synchronously at watch registration so the anchor is set before any
    prompt is injected; _drain_transcript_once also self-baselines defensively."""
    transcripts_base, state_dir = _dirs(transcripts_base, state_dir)
    # Preserve the durable loop-guard run across the re-anchor — load the existing
    # mark rather than minting a fresh (zeroed) one.
    mark = (
        ts.load_watermark(state_dir, session, conversation_id)
        if ts.watermark_exists(state_dir, session, conversation_id)
        else ts.Watermark(session=session, conversation_id=conversation_id)
    )
    mark.baselined_at = ts.now_iso()
    # Resolve the active transcript PREFERRING the pinned session_id (as the drain
    # does) — on reconnect a frozen sibling transcript can carry a NEWER mtime (the
    # copy-forward mirror re-touches it), and a prefer-less resolve would mis-pin to
    # it and anchor past the real session's response. Genuine rotation-while-down is
    # still handled by the drain's stale-pin recovery.
    active = ts.resolve_active_transcript(
        Path(transcripts_base) / session,
        prefer_session_id=mark.session_id or None,
    )
    if active is not None:
        try:
            data = active.read_text(encoding="utf-8", errors="replace")
        except OSError:
            data = ""
        objs = ts.parse_jsonl(data)
        same_file = mark.session_id == active.stem
        if same_file and mark.last_delivered_uuid:
            # Re-anchoring the SAME pinned file (the common reconnect case) must
            # never move last_delivered_uuid BACKWARD. The copy-forward mirror
            # rewrites whole files non-atomically, so a reconnect read can land
            # mid-rewrite and see a torn/partial copy — one that is missing the
            # tail this watcher already delivered past. Blindly taking that read's
            # last turn as the new anchor rewound it to an earlier line, and the
            # next drain replayed everything after it, INCLUDING turns already
            # confirmed delivered (prod 2026-07-18, conv 019f6cf5: a reconnect
            # baseline landed on a torn read and re-delivered 3 already-delivered
            # turns to the orchestrator in one burst). Reuse the same anchor
            # lookup the resume path uses: if the existing anchor doesn't resolve
            # in this read, treat it as torn and leave the mark untouched — a
            # later, complete read will re-anchor correctly.
            if ts.objs_after_uuid(objs, mark.last_delivered_uuid) is None:
                audit.log_event("transcript_baseline_torn_read_skipped", session=session,
                          conversation_id=conversation_id, session_id=active.stem,
                          last_delivered_uuid=mark.last_delivered_uuid)
                ts.save_watermark(state_dir, mark)
                return
        turns = ts.extract_completed_turns(objs)
        mark.session_id = active.stem
        mark.byte_offset = len(data.encode("utf-8"))
        mark.last_delivered_uuid = turns[-1].terminal_uuid if turns else ""
    ts.save_watermark(state_dir, mark)
    audit.log_event("transcript_baseline", session=session, conversation_id=conversation_id,
              session_id=mark.session_id, last_delivered_uuid=mark.last_delivered_uuid,
              consecutive_deliveries=mark.consecutive_deliveries)


# Loop guard for the delivery watcher. When the orchestrator's session_send drives
# every turn, a runaway where the orchestrator and this session answer each other
# forever (prod incident
# 2026-07-03, orchestrator conv 019f1fde) has no natural terminator. TIMING is NOT the
# signal: the earlier rate-based guard reset its run on any >45 s gap, but the
# runaway's turns grew slow as context ballooned (observed gaps up to ~250 s), so
# it never tripped while it flooded the orchestrator. The signal is an unbroken RUN
# of deliveries. Count consecutive deliveries and trip past
# _LOOP_GUARD_MAX_CONSECUTIVE. A slow turn never resets the run; a genuinely IDLE gap
# does — the orchestrator stopped driving, far longer than any single turn
# (_LOOP_GUARD_IDLE_RESET_S) — so a session that goes quiet and later resumes is not
# latched, while a slow runaway cannot use its slow turns to dodge. The run + last-delivery time are
# persisted in the durable watermark, so an MCP restart cannot silently resume the
# loop. This is the coarse backstop; the orchestrator's own guard (which resets on
# a human turn) is the precise layer, so this cap sits ABOVE it. On trip a turn is
# DROPPED (dead-lettered + watermark advanced, no POST) so the orchestrator stops
# receiving callbacks and the session idles out — self-healing once a long idle
# resets the run.
#
# The run counts only replies to the orchestrator's prompts: a prompt typed at the
# terminal, or sent for a person, puts a human in the loop, which a runaway never has,
# and ends it. A turn no one prompted carries the origin of the prompt before it
# (_carry_prompt_origin) and counts with that. Origin rests on matching each prompt to
# the MCP's send record, and that match can fail (a record write that failed, an
# expired entry, Claude Code writing a paste differently), which would make a runaway's
# prompts read as typed and never trip the cap. _LOOP_GUARD_BACKSTOP is the cap for
# that case: an unbroken run of deliveries of any origin, set far above what a person
# working at the terminal reaches without a long pause.
_LOOP_GUARD_MAX_CONSECUTIVE = 20


_LOOP_GUARD_BACKSTOP = 100


_LOOP_GUARD_IDLE_RESET_S = 900.0


# Consecutive torn-read polls before the watcher concludes the pinned session is
# dead (not a transient partial read) and rotates onto the newest transcript. At
# the 2 s poll interval this is ~30 s — far beyond any transient torn read, but
# bounded so a wedged watcher self-heals instead of stalling forever (prod
# 019f1fde: the demo watcher was stuck for 40+ min).
_TORN_READ_RECOVER_POLLS = 15


# Consecutive "pinned session fully consumed AND a strictly-newer session exists"
# polls before the watcher concludes the session genuinely rotated (Claude never
# deletes the old transcript, so the pin never releases on its own) and follows
# forward onto the new session. Content-timestamp based (flap-proof), so short.
_STALE_PIN_RECOVER_POLLS = 5


def _resume_fields(mark: ts.Watermark, seen: float | None) -> dict[str, Any]:
    """Where delivery resumed on a new transcript, and from what, for the log: the
    anchor line, the moment it resumed after (None when nothing was known, and it then
    anchored at the file's end), so a lost or replayed reply after Claude restarts
    can be traced."""
    return {"anchor_uuid": mark.last_delivered_uuid,
            "seen_until": (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seen))
                           if seen is not None else None),
            "anchored_at_end": seen is None}


def _newest_of_siblings(d: Path, sid: str) -> list[tuple[Path, str]]:
    """Each transcript in `d` other than `sid`, with its newest message timestamp.
    Blocking (it may read every earlier transcript): run it in a worker thread."""
    found = []
    for p in ts.conversation_files(d):
        if p.stem == sid:
            continue
        # Every sibling, every poll: read once per version of the file, never again
        # while it is unchanged (ts.newest_message_ts_of). Parsing them all each time
        # was nearly all of the server's CPU while a large session was watched.
        try:
            found.append((p, ts.newest_message_ts_of(p)))
        except OSError:
            continue
    return found


async def _rotate_if_stale_pin(session: str, conversation_id: str,
                               key: tuple[str, str], sid: str, pinned_objs: list,
                               transcripts_base: Path, state_dir: Path) -> bool:
    """Follow a session rotation the pin can't see on its own.

    The session pin selects the pinned transcript as long as it EXISTS, and
    Claude never deletes a rotated-away transcript — so once the user's Claude
    starts a new session (a new sessionId file), the watcher stays welded to the
    old, fully-consumed file and delivers nothing forever (prod 019f1fde: pinned
    to 1b968f61 while demo moved on). This runs only when the pinned session is
    fully consumed (no undelivered turns). It picks the transcript with the
    globally-newest message CONTENT timestamp; if that is a different, strictly
    newer session, it forward-baselines onto it (anchor at its end — never
    replays history). Content timestamps (not mtime) make this immune to the
    copy-forward mirror's mtime churn: a frozen sibling can never out-timestamp
    the session active after it. Gated by a sustained poll count so a transient
    partial read that momentarily makes a sibling look newer cannot trip it.

    :returns: True when it rotated the watermark forward; False otherwise.
    """
    d = Path(transcripts_base) / session
    best, best_ts = None, ts.newest_message_ts(pinned_objs)
    # Off the event loop: the first scan after a restart reads every earlier
    # transcript, seconds of work for a long-lived session, and every tool call and
    # watcher would wait behind it.
    for p, cand_ts in await asyncio.to_thread(_newest_of_siblings, d, sid):
        if cand_ts and cand_ts > best_ts:
            best, best_ts = p, cand_ts

    if best is None:
        ss.consumed_idle_counts.pop(key, None)   # no newer session — keep waiting
        return False

    n = ss.consumed_idle_counts.get(key, 0) + 1
    ss.consumed_idle_counts[key] = n
    if n < _STALE_PIN_RECOVER_POLLS:
        return False

    try:
        best_data = best.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    best_stem = best.stem
    mark = ts.load_watermark(state_dir, session, conversation_id)
    seen = ts.seen_until(pinned_objs, mark)
    mark.session_id = best_stem
    mark.byte_offset = len(best_data.encode("utf-8"))
    mark.last_delivered_uuid = ts.resume_anchor_on_new_transcript(
        ts.parse_jsonl(best_data), seen)
    # The loop-guard run is NOT reset here. Watermark documents it as reset only by a
    # genuinely idle gap, and a runaway that restarts Claude (or rotates its transcript)
    # would otherwise clear its own backstop.
    ts.save_watermark(state_dir, mark)
    ss.settle_state.pop(key, None)
    ss.consumed_idle_counts.pop(key, None)
    audit.log_event("transcript_stale_pin_recovered", session=session,
              conversation_id=conversation_id, dead_session_id=sid,
              new_session_id=best_stem, reason="fully_consumed_idle",
              **_resume_fields(mark, seen))
    return True


async def _interrupted_before_output(session: str, conversation_id: str, suffix: list[dict],
                                     active: Path, screen_fn, wall_now: float) -> ts.Turn | None:
    """The prompt at the transcript's tail, as an interrupted turn, when Claude was
    stopped before writing anything; otherwise None.

    Claude Code writes no marker for an Esc pressed that early, so the transcript alone
    shows only a prompt with no reply. It is reported when the shared turn rule
    (tn.turn_verdict) says Claude is not working on two consecutive polls, with Claude
    running at its input box. `screen_fn(session)` returns the session's ScreenState,
    or None when Claude is not running.
    """
    key = (session, conversation_id)
    turn = ts.unanswered_prompt_turn(suffix)
    if turn is None:
        ss.unanswered_polls.pop(key, None)
        return None
    try:
        quiet = wall_now - active.stat().st_mtime
    except OSError:
        return None
    if quiet < tn.LOG_QUIET_S:
        ss.unanswered_polls.pop(key, None)
        return None
    state = await screen_fn(session)
    if state is None or state.input_box not in (scr.EMPTY, scr.HAS_TEXT):
        ss.unanswered_polls.pop(key, None)
        return None
    verdict, why = tn.turn_verdict(session, suffix, quiet, state)
    if verdict != tn.TURN_IDLE or why not in tn.STOPPED_BY_SCREEN:
        if why != "status_row_unproven":
            ss.unanswered_polls.pop(key, None)
        return None
    polls = ss.unanswered_polls.get(key, 0) + 1
    if polls < 2:
        ss.unanswered_polls[key] = polls
        return None
    ss.unanswered_polls.pop(key, None)
    tn.record_reported_interrupt(session, turn.terminal_uuid)
    audit.log_event("transcript_interrupted_before_output", session=session,
              conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
              quiet_s=round(quiet, 1), why=why)
    return turn


async def _screen_for_watcher(session: str) -> scr.ScreenState | None:
    container = backend.target(session)
    if not await tmx.is_claude_running(container):
        return None
    return await tn.read_screen(container, session)


async def _drain_transcript_once(session: str, conversation_id: str, callback_base: str, *,
                                 transcripts_base: Path | None = None,
                                 state_dir: Path | None = None,
                                 post_fn=None, sleep_fn=asyncio.sleep,
                                 settle_seconds: float = 0.0,
                                 now_fn=time.monotonic,
                                 wall_now_fn=time.time,
                                 screen_fn=None) -> None:
    """One delivery pass, serialized per (session, conversation).

    The exactly-once guarantee lives in the durable watermark, but advancing it
    is a read-modify-write that straddles the await-heavy POST. Two overlapping
    passes for the same key would both load the pre-delivery mark and POST the
    same turn (delivering every turn twice), so the whole load->deliver->advance
    body runs under a per-key mutex — the second pass then sees the advanced mark
    and dedups. See _drain_locks."""
    transcripts_base, state_dir = _dirs(transcripts_base, state_dir)
    async with ss.drain_lock((session, conversation_id)):
        await _drain_once_body(
            session, conversation_id, callback_base,
            transcripts_base=transcripts_base, state_dir=state_dir,
            post_fn=post_fn, sleep_fn=sleep_fn, settle_seconds=settle_seconds,
            now_fn=now_fn, wall_now_fn=wall_now_fn, screen_fn=screen_fn,
        )


async def _drain_once_body(session: str, conversation_id: str, callback_base: str, *,
                           transcripts_base: Path | None = None,
                           state_dir: Path | None = None,
                           post_fn=None, sleep_fn=asyncio.sleep,
                           settle_seconds: float = 0.0,
                           now_fn=time.monotonic,
                           wall_now_fn=time.time,
                           screen_fn=None) -> None:
    """The delivery-pass body (run under the per-key lock by _drain_transcript_once):
    resolve active transcript, extract new completed turns, deliver each
    exactly-once with retry, advance the durable high-water mark.

    Forward-only: if no mark exists yet (first encounter), baseline to the
    current end and deliver nothing — never replay pre-existing history. The
    mark advances past a turn only after it is confirmed delivered, empty, or
    dead-lettered — never while a delivery is still being retried (MCP-17/18)."""
    transcripts_base, state_dir = _dirs(transcripts_base, state_dir)
    if not ts.watermark_exists(state_dir, session, conversation_id):
        await _baseline_watermark(session, conversation_id,
                                  transcripts_base=transcripts_base, state_dir=state_dir)
        return
    mark = ts.load_watermark(state_dir, session, conversation_id)
    # Pin to the session we're already tracking. The copy-forward mirror rewrites
    # whole files and bumps their mtimes, so a plain newest-mtime resolution flaps
    # between transcript files — and each flap looked like a rotation that reset the
    # watermark and replayed the whole file (the incident that hammered the webhook).
    active = ts.resolve_active_transcript(Path(transcripts_base) / session,
                                          prefer_session_id=mark.session_id or None)
    if active is None:
        return
    sid = active.stem
    try:
        objs, end_offset = ts.read_transcript(active)
    except OSError:
        return
    key = (session, conversation_id)

    if mark.session_id != sid and mark.session_id:
        # GENUINE rotation: the file we were pinned to is gone, so resolution fell
        # back to a different active file. Resume on it from when the watcher last
        # saw activity (its last watermark save): what came after is delivered, its
        # older history is not — never reset last_delivered_uuid to "" and replay
        # the whole file, which was the replay bug.
        seen = ts.seen_until([], mark)
        mark.session_id = sid
        mark.byte_offset = end_offset
        mark.last_delivered_uuid = ts.resume_anchor_on_new_transcript(objs, seen)
        ts.save_watermark(state_dir, mark)
        ss.settle_state.pop(key, None)
        audit.log_event("transcript_rotated", session=session, conversation_id=conversation_id,
                  session_id=sid, **_resume_fields(mark, seen))
        return

    if not mark.session_id:
        # FIRST transcript for a session that baselined before ANY file existed —
        # a fresh aidc session: session_send starts the watcher and anchors BEFORE
        # the prompt is injected, so the transcript dir is empty at baseline time
        # (session_id left ""). This is NOT a rotation, and there is NO pre-existing
        # history to skip — everything in this first file happened AFTER we
        # connected. Pin to it and fall through to the normal resume/deliver path so
        # its turns are delivered. Forward-baselining here (the old bug) swallowed
        # the session's very first reply — the "reply never comes back" symptom.
        # An empty session_id is set ONLY by the fresh-baseline no-file case; any
        # later pin (baseline-with-history, rotation, stale-pin recovery) writes a
        # real stem — so this can never fire on a session that actually had history.
        mark.session_id = sid
        ts.save_watermark(state_dir, mark)
        audit.log_event("transcript_first_pin", session=session, conversation_id=conversation_id,
                  session_id=sid)

    # Resume anchored on the last-delivered LINE (stable under coalescing).
    suffix = ts.objs_after_uuid(objs, mark.last_delivered_uuid or None)
    if suffix is None:
        # The resume anchor is absent from the pinned transcript. A transient
        # torn/partial copy-forward read drops it for a poll or two, then recovers
        # — so we must NOT act on a single miss (that would re-introduce the
        # mtime-flap replay bug: a sibling file re-touched newer, read while the
        # active file is momentarily partial). Only a SUSTAINED absence means the
        # pinned session is DEAD: its transcript lingers on disk (so the session
        # pin keeps selecting it) but the anchor is gone for good — a torn final
        # line from a session killed mid-write, or a compaction. After
        # _TORN_READ_RECOVER_POLLS consecutive misses, if a strictly-newer
        # transcript exists for this session, the pin is stale — rotate onto the
        # newest (forward-baseline), exactly like a genuine rotation, instead of
        # wedging forever (prod 019f1fde: the demo watcher stuck in
        # torn_read_skip for 40+ min after the runaway session was killed
        # mid-write and the container was rebuilt onto a fresh session).
        torn = ss.torn_read_counts.get(key, 0) + 1
        ss.torn_read_counts[key] = torn
        if torn >= _TORN_READ_RECOVER_POLLS:
            # The pinned file has lost the line this conversation resumes from, for
            # good: a torn final line from a session killed mid-write, or a compaction.
            # Look for replies in it that were never delivered: anchored at the point
            # this conversation last connected or last delivered, and checked against
            # the ledger, so neither history from before the connect nor anything
            # already delivered counts. If any are left, re-anchor INSIDE this file and
            # let the ordinary pass deliver them. This runs whether or not another
            # transcript exists: a compaction can lose the anchor with no new session at
            # all, and gating it on a newer file (as first built) wedged the watcher
            # silently in exactly that case, replies sitting on disk undelivered.
            seen = ts.seen_until([], mark)
            anchor = ts.resume_anchor_on_new_transcript(objs, seen)
            left = ts.objs_after_uuid(objs, anchor or None) or []
            delivered_before = ts.load_delivered(state_dir, session, conversation_id)
            undelivered = [t for t in ts.extract_completed_turns(left)
                           if (t.interrupted or not t.is_empty)
                           and ts.delivery_fingerprint(t) not in delivered_before]
            newest = ts.resolve_active_transcript(Path(transcripts_base) / session)
            if undelivered:
                mark.last_delivered_uuid = anchor
                ts.save_watermark(state_dir, mark)
                ss.settle_state.pop(key, None)
                ss.torn_read_counts.pop(key, None)
                audit.log_event("transcript_torn_read_reanchored", session=session,
                          conversation_id=conversation_id, session_id=sid,
                          newer_session_id=newest.stem if newest is not None else "",
                          torn_read_polls=torn, undelivered_turns=len(undelivered),
                          **_resume_fields(mark, seen))
                return
            if newest is not None and newest.stem != sid:
                try:
                    newest_data = newest.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    return
                mark.session_id = newest.stem
                mark.byte_offset = len(newest_data.encode("utf-8"))
                mark.last_delivered_uuid = ts.resume_anchor_on_new_transcript(
                    ts.parse_jsonl(newest_data), ts.seen_until(objs, mark))
                ts.save_watermark(state_dir, mark)   # loop-guard run kept, as above
                ss.settle_state.pop(key, None)
                ss.torn_read_counts.pop(key, None)
                audit.log_event("transcript_stale_pin_recovered", session=session,
                          conversation_id=conversation_id, dead_session_id=sid,
                          new_session_id=newest.stem, torn_read_polls=torn,
                          **_resume_fields(mark, ts.seen_until(objs, mark)))
                return
        audit.log_event("transcript_torn_read_skip", session=session,
                  conversation_id=conversation_id,
                  last_delivered_uuid=mark.last_delivered_uuid, torn_read_count=torn)
        return
    ss.torn_read_counts.pop(key, None)  # anchor resolved — reset the torn-read run

    # Settle gate: only deliver once the transcript has held steady for
    # settle_seconds. Claude can emit an empty end_turn and then continue with the
    # real answer; waiting for quiet lets extract_completed_turns coalesce that
    # burst into one delivery instead of signalling "ready" mid-stream. If the wait
    # fires early anyway, the line-anchored resume still recovers: the continuation
    # is delivered as a follow-up turn rather than wedging or replaying.
    # Claude Code's end-of-turn record says the same thing directly (every Stop hook
    # allowed the stop), so when the transcript ends on it there is nothing to wait
    # for. Its absence falls back to the window: the record is not guaranteed.
    # A reply whose Stop hooks have not reported yet waits longer (see
    # tn.STOP_HOOK_WAIT_S): a slow blocking hook would otherwise reopen a turn that
    # was already delivered as finished.
    if settle_seconds > 0 and ts.ends_on_turn_end(suffix):
        ss.settle_state.pop(key, None)
    elif settle_seconds > 0:
        quiet_needed = (max(settle_seconds, tn.STOP_HOOK_WAIT_S)
                        if ts.awaiting_stop_hooks(suffix, objs) else settle_seconds)
        now = now_fn()
        last = ss.settle_state.get(key)
        if last is None or last[0] != end_offset:
            ss.settle_state[key] = (end_offset, now)
            return  # grew (or first observation this cycle) — wait for quiet
        if now - last[1] < quiet_needed:
            return  # not quiet long enough yet

    dropped: list[str] = []
    new = ts.extract_completed_turns(suffix, dropped)
    if screen_fn is not None:
        if not tn.working_indicator_known(session) and ts.log_shows_turn_in_progress(suffix):
            # Learn this session's working text while a turn is running, so an Esc
            # before Claude writes anything can be recognized without waiting out
            # _LOG_STALL_S. Stops once seen; a person-only session never touches
            # the send path's own screen reads.
            await screen_fn(session)
        cut_off = await _interrupted_before_output(session, conversation_id, suffix, active,
                                                   screen_fn, wall_now_fn())
        if cut_off is not None:
            new = [*new, cut_off]
    for uid in dropped:
        # A Stop hook pushed Claude back and Claude never produced another reply
        # before the next prompt: nothing is left to deliver for that request.
        drop_key = (session, conversation_id, uid)
        if drop_key not in ss.logged_withdrawn_drops:
            ss.logged_withdrawn_drops.add(drop_key)
            audit.log_event("transcript_withdrawn_reply_dropped", session=session,
                      conversation_id=conversation_id, turn_uuid=uid)
    if not new:
        # No deliverable turns remain in the pinned session (its tail may hold
        # trailing non-turn objects — a bare user/system line that never became a
        # turn — so `suffix` can be non-empty while `new` is empty). The user's
        # Claude may have rotated to a new session whose old transcript still
        # lingers on disk, which the pin can't see on its own. Follow the rotation
        # forward. Content-timestamp gated, so an active pinned session that is
        # merely mid-turn is never abandoned — no sibling can out-timestamp it.
        await _rotate_if_stale_pin(session, conversation_id, key, sid, objs,
                                   transcripts_base, state_dir)
        return
    ss.consumed_idle_counts.pop(key, None)   # delivering — not a stale pin
    if post_fn is None:
        async def post_fn(turn, attempt):  # noqa: E306
            return await cbk.post_turn(callback_base, conversation_id, turn,
                                       attempt=attempt, session=session)
    # The durable delivery ledger is the STRUCTURAL exactly-once guarantee: a
    # content fingerprint in it was already confirmed delivered to this
    # conversation, so it must never be POSTed again — no matter how it re-surfaced
    # (a watermark rewind, a torn-read replay, a rotation flap, a reconnect
    # catch-up). It is independent of the watermark on purpose: the watermark is a
    # best-effort resume hint and has many ways to be wrong; the ledger is the
    # backstop that turns every such bug into a wasted disk read instead of a
    # duplicate that poisons the orchestrated agent's context. Loaded once per
    # pass (under the per-key drain lock) and updated in place so multiple new
    # turns in the same pass also dedup against each other.
    delivered_fps = ts.load_delivered(state_dir, session, conversation_id)
    for turn in new:
        # Whose prompt does this turn answer? A person at the session's tmux pane
        # can type straight into Claude, and that reply comes over this same
        # webhook — but the orchestrator never saw the prompt, so it read the
        # reply as an answer to whatever IT last sent. Prompts that match the
        # MCP's own send record are the orchestrator's; the rest were typed at the
        # terminal and are prepended to the delivered content so the reply reads
        # in context. Resolved for EVERY turn (empty ones too) so each injected
        # prompt consumes its record entry exactly once. The ledger fingerprint
        # stays on the bare reply (turn.text): a re-surfaced turn must dedup even
        # though its record entry is gone by then and its framing would differ —
        # and a re-surfaced turn is NOT attributed at all, or its (already consumed)
        # prompt would eat a fresh record entry meant for the next identical send.
        # An interrupt is delivered even with no text: the orchestrator must hear
        # that its task was cut off.
        deliverable = turn.interrupted or not turn.is_empty
        fingerprint = ts.delivery_fingerprint(turn) if deliverable else ""
        already_delivered = bool(fingerprint) and fingerprint in delivered_fps
        terminal_prompts, sent_by, batch = (
            ([], "", None) if already_delivered
            else _terminal_prompts(session, turn.prompts, state_dir)
        )
        # A prompt typed at the terminal outranks one sent for a person: the content
        # then quotes it, and only one origin goes with the reply.
        origin = ("terminal" if terminal_prompts else "person" if sent_by
                  else "orchestrator" if turn.prompts else "")
        sent_by = sent_by if origin == "person" else ""
        if not already_delivered:
            origin, sent_by, batch = _carry_prompt_origin(session, turn, origin, sent_by,
                                                          batch, state_dir)
            if deliverable:
                batch = _with_joined(session, batch, state_dir)
        outgoing = dataclasses.replace(
            turn,
            text=ts.render_delivery(turn.text, terminal_prompts, interrupted=turn.interrupted),
            prompt_origin=origin,
            sent_by=sent_by,
            pasted_at=batch["pasted_at"] if batch else "",
            batch=tuple(batch["prompts"]) if batch else (),
            speaker=("human" if turn.prompts and len(terminal_prompts) == len(turn.prompts)
                     else "agent"),
        )
        if terminal_prompts:
            # record_remaining is the health signal: entries that keep piling up
            # while replies arrive mean matching has drifted (every reply would then
            # carry the note), which a real typed prompt never causes.
            audit.log_event("transcript_terminal_prompt", session=session,
                      conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
                      prompts=len(terminal_prompts),
                      prompt_len=sum(len(p) for p in terminal_prompts),
                      record_remaining=ts.sent_prompts_remaining(state_dir, session))
        if turn.superseded and not already_delivered:
            # A reply followed by more assistant work with no Stop-hook pushback or
            # prompt between them. A block that leaves no trace looks like this,
            # and its first half may have been delivered as the finished reply.
            audit.log_event("transcript_terminal_superseded", session=session,
                      conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
                      superseded=turn.superseded)
        if turn.late_pushback and not already_delivered:
            # The reply before this pushback already went out as finished: its Stop
            # hook ran longer than the watcher held it. This delivery is the rest.
            audit.log_event("transcript_late_pushback", session=session,
                      conversation_id=conversation_id, turn_uuid=turn.terminal_uuid)
        if not deliverable:
            audit.log_event("transcript_empty_turn", session=session,
                      conversation_id=conversation_id, turn_uuid=turn.terminal_uuid)
        else:
            if already_delivered:
                # Already delivered this exact content to this conversation. A
                # watermark bug re-surfaced it; drop it at the door. This is NOT a
                # loop-guard event (it is a re-read, not a fresh echo) and is never
                # re-POSTed — only the watermark advances past it below.
                audit.log_event("transcript_delivery_deduped", session=session,
                          conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
                          fingerprint=fingerprint)
            else:
                # Loop guard: cap the run of CONSECUTIVE deliveries, or an
                # orchestrator<->session runaway would deliver forever. Timing is not the
                # signal — the runaway can be slow (context-bloated turns), which is
                # what defeated the old rate-based reset. A genuinely IDLE gap
                # (_LOOP_GUARD_IDLE_RESET_S — far longer than any single turn) resets
                # the run, and a slow turn does not, so a session that truly goes quiet
                # is not latched while a slow runaway still trips. State is durable so an
                # MCP restart stays latched. On trip: DROP (dead-letter + advance, no POST) so the
                # orchestrator stops receiving and the session idles out.
                # Only replies to the orchestrator's prompts count toward the cap;
                # every delivery counts toward the backstop (see the constants).
                wall_now = wall_now_fn()
                human = origin in ("terminal", "person")
                if wall_now - mark.last_delivery_at > _LOOP_GUARD_IDLE_RESET_S:
                    mark.consecutive_deliveries = 0
                    mark.deliveries_since_idle = 0
                if human:
                    mark.consecutive_deliveries = 0
                else:
                    mark.consecutive_deliveries += 1
                mark.deliveries_since_idle += 1
                mark.last_delivery_at = wall_now
                if (mark.consecutive_deliveries > _LOOP_GUARD_MAX_CONSECUTIVE
                        or mark.deliveries_since_idle > _LOOP_GUARD_BACKSTOP):
                    cbk.write_dead_letter(state_dir, session, conversation_id, outgoing)
                    audit.log_event("transcript_delivery_loop_guard_tripped", session=session,
                              conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
                              consecutive_deliveries=mark.consecutive_deliveries,
                              deliveries_since_idle=mark.deliveries_since_idle,
                              cap=(_LOOP_GUARD_MAX_CONSECUTIVE
                                   if mark.consecutive_deliveries > _LOOP_GUARD_MAX_CONSECUTIVE
                                   else _LOOP_GUARD_BACKSTOP))
                elif await cbk.deliver_with_retry(outgoing, post_fn=post_fn, sleep_fn=sleep_fn):
                    # Record ONLY a confirmed delivery, so a dead-lettered or
                    # dropped turn stays eligible for a later resend.
                    delivered_fps.add(fingerprint)
                    ts.record_delivered(state_dir, session, conversation_id, fingerprint)
                else:
                    cbk.write_dead_letter(state_dir, session, conversation_id, outgoing)
                    audit.log_event("transcript_delivery_abandoned", session=session,
                              conversation_id=conversation_id, turn_uuid=turn.terminal_uuid)
        mark.last_delivered_uuid = turn.terminal_uuid
        mark.byte_offset = end_offset
        ts.save_watermark(state_dir, mark)


async def resend_reply(session: str, conversation_id: str, callback_base: str, *,
                        turn_uuid: str | None = None,
                        force: bool = False,
                        transcripts_base: Path | None = None,
                        state_dir: Path | None = None,
                        post_fn=None,
                        sleep_fn=asyncio.sleep) -> tuple[str, ts.Turn | None]:
    """Re-deliver ONE already-produced reply to the orchestrator, out-of-band.

    Recovers a reply that was lost or never arrived (a dropped callback, a watcher
    gap, an MCP restart at the wrong moment) WITHOUT replaying the backlog: it
    posts exactly one completed turn and DELIBERATELY does not touch the delivery
    watermark. The forward-only watcher keeps its own anchor, so a resend can never
    cause the connect-catch-up flood — that separation is the whole point.

    NEVER re-POSTs a turn the delivery ledger already holds, unless ``force``.
    The ledger records only fingerprints CONFIRMED delivered (a 2xx ack), so
    "in the ledger" means the orchestrator demonstrably received this exact content — and
    POSTing it again injects a verbatim duplicate into the conversation, which is
    strictly harmful: it re-answers a question that was already answered and
    corrupts the history the next turn reads. Returning the content to the CALLER
    instead gives the model everything it needs with none of that damage.

    This distinction is why the gate is the ledger and not the watermark. The
    watermark advances past a turn even when delivery was abandoned to the
    dead-letter dir, so a genuinely-lost reply is absent from the ledger and stays
    resendable — exactly the case this tool exists for (prod 2026-08-22 conv
    01a01cf6: a no-uuid resend of an already-acked turn put a verbatim 4851-char
    duplicate of the previous answer into the conversation).

    Picks the turn matching ``turn_uuid``; when unset, the LAST completed
    (non-empty) turn — the session's most recent reply, the usual "it never came
    back, send it again" case. Resolves the transcript preferring the watermark's
    pinned session_id so it targets the same file the watcher tracks.

    Returns ``(status, turn)`` where status is one of:
      - ``"resent"``            — POSTed and acked;
      - ``"already_delivered"`` — in the ledger, NOT posted (pass force to override);
      - ``"no_reply"``          — nothing resendable (``turn`` is None);
      - ``"failed"``            — POSTed but never acked.

    The base dirs resolve at call time (_dirs) — the session_resend tool passes neither.
    """
    transcripts_base, state_dir = _dirs(transcripts_base, state_dir)
    mark = (
        ts.load_watermark(state_dir, session, conversation_id)
        if ts.watermark_exists(state_dir, session, conversation_id)
        else None
    )
    prefer = mark.session_id if (mark and mark.session_id) else None
    # The file the watcher tracks first, then the session's earlier files (newest
    # first): Claude starts a new transcript on every restart, and the reply this tool
    # is being asked for may be in the one before — which is exactly the case where a
    # reply went missing (joint test scenario 10, 2026-09-17).
    target = None
    source = ""
    for path in ts.session_transcripts(Path(transcripts_base) / session,
                                       prefer_session_id=prefer):
        try:
            data = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            audit.log_event("transcript_resend_unreadable", session=session,
                      conversation_id=conversation_id, session_id=path.stem,
                      error_type=type(exc).__name__)
            continue
        # Only non-empty (deliverable) turns can be resent — an empty tool-only turn
        # was never a reply to the orchestrator in the first place.
        deliverable = [t for t in ts.extract_completed_turns(ts.parse_jsonl(data))
                       if t.interrupted or not t.is_empty]
        if not deliverable:
            continue
        if turn_uuid:
            target = next((t for t in deliverable if t.terminal_uuid == turn_uuid), None)
        else:
            target = deliverable[-1]
        if target is not None:
            source = path.stem
            break
    if target is None:
        return ("no_reply", None)

    # The ledger holds fingerprints CONFIRMED delivered (2xx). A hit means the orchestrator
    # already has this exact content, so re-POSTing can only duplicate it. Refuse
    # by default and let the caller read the content from the tool result instead.
    fingerprint = ts.delivery_fingerprint(target)
    if not force and fingerprint in ts.load_delivered(state_dir, session, conversation_id):
        audit.log_event("transcript_resend_suppressed", session=session,
                  conversation_id=conversation_id, turn_uuid=target.terminal_uuid,
                  content_len=len(target.text), fingerprint=fingerprint)
        return ("already_delivered", target)

    if post_fn is None:
        async def post_fn(turn, attempt):  # noqa: E306
            return await cbk.post_turn(callback_base, conversation_id, turn,
                                       attempt=attempt, session=session)
    # The bare reply, as the resend contract says -- except that an interrupt keeps
    # its note: without it an interrupt with nothing written would post as empty.
    outgoing = dataclasses.replace(
        target, text=ts.render_delivery(target.text, [], interrupted=target.interrupted))
    ok = await cbk.deliver_with_retry(outgoing, post_fn=post_fn, sleep_fn=sleep_fn)
    if ok:
        # Record the resent turn in the delivery ledger so the watcher never ALSO
        # delivers it (a double-send). Once it lands, the exactly-once invariant
        # must hold for every other delivery path too.
        ts.record_delivered(state_dir, session, conversation_id, fingerprint)
    audit.log_event("transcript_resend", session=session, conversation_id=conversation_id,
              turn_uuid=target.terminal_uuid, content_len=len(target.text), ok=ok,
              forced=force, session_id=source,
              from_earlier_transcript=bool(prefer) and source != prefer)
    return ("resent" if ok else "failed", target)


async def _run_transcript_watcher(session: str, conversation_id: str, callback_base: str, *,
                                  poll_interval: float = 2.0,
                                  settle_seconds: float | None = None) -> None:
    """Polling loop around _drain_transcript_once. The live delivery path behind
    session_send / session_run / session_watch. The settle window (how long the
    transcript must be quiet before a turn is delivered) is read from config once
    per watcher; pass settle_seconds to override (tests)."""
    if settle_seconds is None:
        settle_seconds = orc.orchestrator_turn_settle_seconds()
    while True:
        await asyncio.sleep(poll_interval)
        try:
            await _drain_transcript_once(session, conversation_id, callback_base,
                                         settle_seconds=settle_seconds,
                                         screen_fn=_screen_for_watcher)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- watcher must survive
            audit.log_event("transcript_watcher_error", session=session,
                      conversation_id=conversation_id, error_type=type(exc).__name__,
                      error=repr(exc))


def _make_watcher_done_callback(name: str):
    """Done-callback for a watcher task: deregister it and evict the per-session
    state that would otherwise leak (send lock, settle entries).

    Identity-guarded: only cleans up if this task is still the registered watcher
    for `name`. On a session_watch replacement the old task's callback fires after
    a new task has taken the slot — without the guard it would evict the live
    replacement's state."""
    def _cb(task: asyncio.Task[None]) -> None:
        if ss.session_watchers.get(name) is task:
            ss.session_watchers.pop(name, None)
            ss.evict_session_state(name)
    return _cb


def _register_watcher(name: str, conversation_id: str, base_url: str) -> None:
    existing = ss.session_watchers.get(name)
    if existing is not None:
        existing.cancel()
    task = asyncio.create_task(_run_transcript_watcher(name, conversation_id, base_url))
    ss.session_watchers[name] = task
    task.add_done_callback(_make_watcher_done_callback(name))


async def start_watcher(name: str, conversation_id: str, base_url: str,
                         announce: Callable[[], Awaitable[None]]) -> None:
    """Baseline forward-only, spawn the transcript watcher, register it, and
    announce the change (`announce`: the MCP adapter refreshes its tool descriptions
    and tells clients). Shared by session_send / session_watch.

    session_run deliberately does NOT use this: it is the synchronous inline path
    (it blocks and returns the transcript), so opening a webhook would deliver each
    turn twice — once inline, once via the callback (see session_run for the note)."""
    # Register the watcher SYNCHRONOUSLY — cancel any existing one and install the
    # new task with NO await in between — so this is the single point that enforces
    # one watcher per session. The streamable-HTTP server handles tool calls as
    # concurrent tasks, so session_watch ("call this first") racing session_send's
    # auto-watch (or two rapid sends) could otherwise both pass their check-then-act
    # guard while an `await` sat between the check and the registration, leaving TWO
    # watcher tasks polling the same session. Two watchers share one durable
    # watermark and each POST every turn -> every reply delivered twice.
    _register_watcher(name, conversation_id, base_url)
    _, instance = await tn.session_instance(name)
    try:
        ts.save_watch(ss.WATCHER_STATE_DIR, name, conversation_id, base_url,
                      session_instance=instance)
    except OSError as exc:
        audit.log_event("session_watch_persist_failed", session=name, error_type=type(exc).__name__)
    # Baseline forward-only AFTER registering. The watcher sleeps one poll interval
    # before its first drain and _drain_transcript_once self-baselines defensively,
    # and this await completes before the caller injects any prompt, so the anchor
    # is still established before the first delivery.
    await _baseline_watermark(name, conversation_id)
    await announce()


async def watch(
    name: str,
    conversation_id: str | None = None,
    *,
    announce: Callable[[], Awaitable[None]],
) -> dict[str, Any]:
    """The session_watch tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    base_url = orc.orchestrator_callback_url()
    if not base_url:
        return com.envelope_err(orc.callback_url_unset(),
                                code="not_configured")
    if not conversation_id:
        return com.envelope_err(
            "conversation_id is required (the orchestrator injects it automatically)",
                code="invalid_argument"
        )
    # start_watcher atomically cancels any existing watcher and installs the
    # new one, so a re-call (or a racing auto-watch) never leaves two watchers.
    await start_watcher(name, conversation_id, base_url, announce)
    audit.log_event("tool_call", tool="session_watch", session=name,
                    conversation_id=conversation_id)
    return com.envelope_ok(
        {"status": "watching", "session": name, "conversation_id": conversation_id}
    )


async def resend(
    name: str,
    conversation_id: str | None = None,
    turn_uuid: str | None = None,
    force: bool = False,
) -> dict[str, Any]:
    """The session_resend tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    if not conversation_id:
        return com.envelope_err(
            "conversation_id is required (the orchestrator injects it automatically)",
                code="invalid_argument"
        )
    base_url = orc.orchestrator_callback_url()
    if not base_url:
        return com.envelope_err(orc.callback_url_unset(),
                                code="not_configured")
    audit.log_event("tool_call", tool="session_resend", session=name,
              conversation_id=conversation_id, turn_uuid=turn_uuid or "", force=force)
    # Is the agent mid-turn right now? If so, the newest COMPLETED turn cannot
    # be the answer to the prompt still in flight — the caller must be told, or
    # it reads a stale reply as the response to its last question (prod
    # 2026-08-22 conv 01a01cf6: a no-uuid resend returned the previous prompt's
    # answer while the real turn had 16 minutes left to run).
    state = await tn.session_state(backend.target(name), name)
    busy = state.claude_running and state.turn == tn.TURN_RUNNING
    status, turn = await resend_reply(name, conversation_id, base_url,
                                      turn_uuid=turn_uuid, force=force)
    if turn is None:
        return com.envelope_err(
            "no completed reply found to resend for this session "
            "(the session may not have produced a reply yet)", code="no_reply"
        )
    if status == "failed":
        return com.envelope_err(
            "resend reached the transcript but the callback to the orchestrator failed "
            "(see logs); the reply was not delivered", code="callback_failed"
        )

    notes: list[str] = []
    if status == "already_delivered":
        notes.append(
            "This reply was ALREADY delivered to this conversation — it is "
            "somewhere above. It was NOT re-sent, deliberately: a second copy "
            "would answer the same question twice and corrupt the history. Its "
            "full text is in `content` here; read it from there."
        )
    if busy:
        notes.append(
            "The session is STILL WORKING on a later prompt. This is the most "
            "recent COMPLETED reply, so it answers an EARLIER prompt — not the "
            "one you are waiting for. Do not treat it as the pending answer, and "
            "do not call this tool again; that reply arrives over the webhook on "
            "its own."
        )
    if status == "already_delivered" and not busy:
        notes.append(
            "If a reply you expected is genuinely missing, the likeliest cause is "
            "that it was never requested: check that your session_send actually "
            "ran rather than assuming it did."
        )
    audit.log_event("transcript_resend_result", session=name,
              conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
              status=status, session_busy=busy, forced=force)
    return com.envelope_ok(
        {"status": status, "session": name, "turn_uuid": turn.terminal_uuid,
         "content": turn.text, "session_busy": busy,
         "already_delivered": status == "already_delivered",
         **({"note": " ".join(notes)} if notes else {})}
    )


async def unwatch(name: str, *, announce: Callable[[], Awaitable[None]]) -> dict[str, Any]:
    """The session_unwatch tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    ts.remove_watch(ss.WATCHER_STATE_DIR, name)
    task = ss.session_watchers.pop(name, None)
    if task is not None:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
    # Evict the per-session send lock + settle entries too, or they leak as
    # sessions come and go (the done-callback also does this on natural exit).
    ss.evict_session_state(name)
    await announce()
    audit.log_event("tool_call", tool="session_unwatch", session=name)
    return com.envelope_ok({"status": "stopped", "session": name})
