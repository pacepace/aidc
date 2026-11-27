"""Turn state (design-10 S1, S9): whether Claude is running, whether it is working on a
turn (from the session's Claude Code hook events, MCP-47), the marker that survives a
restart, and whether a pasted prompt arrived. The screen is read only for what the paste
needs (the input box, a dialog), never to decide whether Claude is working.

No MCP types here (test_service_boundary): the tools in tearstools/ adapt it.
"""

from __future__ import annotations

import asyncio
import dataclasses
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from aidc_mcp import audit, backend
from aidc_mcp import hook_events as he
from aidc_mcp import screen as scr
from aidc_mcp import store as state_store
from aidc_mcp import transcript as ts
from aidc_mcp.service import state as ss
from aidc_mcp.service import tmux as tmx

# The transcript is copied to the MCP about every 2 s. A turn it shows still being written
# (a reply a Stop hook pushed back on, or one a hook event has not caught up with) counts as
# running until the transcript has been quiet for longer than that copy lag.
LOG_QUIET_S = 6.0


# After a paste, the session counts as busy until the transcript shows the prompt
# arrived, for at most this long. A prompt that never shows is logged, not re-sent:
# a paste that returned success almost always landed, and a second copy is worse.
_ECHO_WAIT_S = 30.0


# Poll interval for the free check. Two consecutive free readings are required, so a
# turn that starts the moment another ends (a background task's notification) is not
# mistaken for a free session; the readings are spaced past the mirror's copy interval
# so they cannot both come from the same stale copy.
FREE_POLL_S = 2.5


_ECHO_POLL_S = 2.0


TURN_RUNNING = "running"


TURN_IDLE = "idle"


# A session with no hook events at all: created before aidc 2.0, so its Claude reports
# nothing aidc can read. It is not guessed at from the screen (owner ruling 2026-11-26).
TURN_UNKNOWN = "unknown"

PREDATES_HOOK_EVENTS = "session_predates_hook_events"

# The `why` and paste reason of a session whose Claude shows a dialog instead of its input
# box; for a first-launch screen (screen.FIRST_LAUNCH_DIALOGS) the screen's `dialog` names
# which. Not screen.NOT_AT_PROMPT, which is an input_box value.
WHY_NOT_AT_PROMPT = "claude_not_at_prompt"


# The idle verdicts of a turn the transcript may still show open: Claude reported idle, or
# said its turn was over. The send path and the watcher both treat exactly these, with an
# unanswered prompt at the transcript's tail, as "Claude stopped with that prompt
# unanswered" (an Esc before it wrote anything, which Claude Code reports with no Stop).
STOPPED_BY_HOOKS = frozenset({"idle_prompt", "turn_stopped"})


@dataclasses.dataclass(frozen=True)
class SessionState:
    """What the MCP knows about a session right now (design-10 S1/S2).

    `turn` is Claude's turn state alone (TURN_RUNNING, TURN_IDLE, or TURN_UNKNOWN for a
    session from before hook events), with `why` naming the evidence. The input box is a
    separate matter, in `screen`: whether a prompt may
    be pasted combines both (paste_reason), while "is Claude still working?" reads
    only `turn`.
    """
    claude_running: bool
    screen: scr.ScreenState | None
    turn: str
    why: str


def _interrupt_reported(name: str, prompt_uuid: str) -> bool:
    return ss.reported_interrupts.get(name) == prompt_uuid


def _write_marker(name: str, kind: str, **fields: str) -> None:
    try:
        state_store.for_dir(ss.WATCHER_STATE_DIR).put(
            "markers", state_store.key_of(name, kind),
            {"session_instance": ss.session_instances.get(name, ""), **fields},
            session=name, kind=kind)
    except Exception as exc:  # prawduct:allow prawduct/broad-except -- a marker only
        audit.log_event("session_marker_persist_failed", session=name, marker=kind,
                  error_type=type(exc).__name__)


def _read_marker(name: str, kind: str, instance: str) -> dict[str, Any] | None:
    """The marker's fields when it belongs to `instance`; otherwise None, and a marker
    that exists but belongs to another instance (or cannot be read) is removed."""
    store = state_store.for_dir(ss.WATCHER_STATE_DIR)
    key = state_store.key_of(name, kind)
    data = store.get("markers", key)
    if data is None:
        return None
    if isinstance(data, dict) and data.get("session_instance") == instance:
        return data
    store.delete("markers", key)
    return None


def record_reported_interrupt(name: str, prompt_uuid: str) -> None:
    # Only the latest unanswered prompt can be waiting on this report, so one per
    # session is all that is kept.
    ss.reported_interrupts[name] = prompt_uuid
    _write_marker(name, ss.REPORTED_INTERRUPT_MARKER, prompt_uuid=prompt_uuid)


async def _sync_session_markers(name: str) -> None:
    """Tie the session's markers to the session instance that exists now. The first
    time in this process, load the ones on disk that belong to it. When the instance has
    changed since (killed and created again), forget everything about the old one. When
    docker cannot say, change nothing and try again next time."""
    state, current = await session_instance(name)
    if state != SESSION_EXISTS or not current:
        return
    known = ss.session_instances.get(name)
    if known == current:
        return
    if known is not None:
        ss.forget_session_send_state(name)
    ss.session_instances[name] = current
    if known is None:
        try:
            reported = _read_marker(name, ss.REPORTED_INTERRUPT_MARKER, current)
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- markers only
            audit.log_event("session_marker_read_failed", session=name,
                      error_type=type(exc).__name__)
            return
        if reported is not None and isinstance(reported.get("prompt_uuid"), str):
            ss.reported_interrupts[name] = reported["prompt_uuid"]


async def read_screen(container: str, name: str) -> scr.ScreenState:
    await _sync_session_markers(name)
    raw = await tmx.capture_screen(container, tmx.SESSION_WINDOW)
    ss.last_screen_raw[name] = raw
    return scr.classify(raw)


def session_transcript(name: str) -> tuple[list[dict], float, str]:
    """The session's active mirrored transcript, its last-modified time, and whether
    it could be read: "ok", "none" (nobody has prompted the session yet) or
    "unreadable"."""
    active = ts.resolve_active_transcript(Path(ss.TRANSCRIPTS_BASE) / name)
    if active is None:
        return [], 0.0, "none"
    try:
        objs, _ = ts.read_transcript(active)
        mtime = active.stat().st_mtime
    except OSError:
        return [], 0.0, "unreadable"
    return objs, mtime, "ok"


def _relevant(event: he.HookEvent) -> bool:
    """Whether an event says something about the turn: every hook aidc installs does,
    except a notification of a type that is not about waiting (auth, elicitation, ...)."""
    if event.event == he.NOTIFICATION:
        return event.notification_type in (he.PERMISSION_PROMPT, he.IDLE_PROMPT)
    return event.event in (he.SESSION_START, he.USER_PROMPT_SUBMIT, he.STOP)


def latest_hook_event(name: str, mirror_base: Path | None = None
                      ) -> tuple[bool, he.HookEvent | None]:
    """Whether session `name` has any hook events, and its latest one about the turn.

    Read on from the last event this process read, so a poll reads only what is new; after
    an MCP restart every file is read once. Nothing here removes one: the session's hook
    writer keeps its dir small (.devcontainer/hook-event.sh), and in the cluster this
    server's mount of the mirror is read-only."""
    mirror = Path(ss.TRANSCRIPTS_BASE if mirror_base is None else mirror_base) / name
    new = he.read_events(mirror, after=ss.hook_events_read.get(name, ""))
    for event in new:
        if _relevant(event):
            ss.hook_turn_event[name] = event
    if new:
        ss.hook_events_read[name] = new[-1].name
    return name in ss.hook_events_read, ss.hook_turn_event.get(name)


def _epoch(at: str) -> float:
    """An event's `at` (UTC ISO, milliseconds) as epoch seconds; 0.0 when unreadable."""
    try:
        return datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _written_after(mtime: float, event: he.HookEvent) -> bool:
    """Whether the transcript was last written after `event`. Its `at` is cut to the
    millisecond, so a write within that millisecond is not after it."""
    return mtime >= _epoch(event.at) + 0.001


def turn_from_hooks(name: str, objs: list[dict], mtime: float,
                    now: float | None = None, *,
                    installed: bool | None = False,
                    mirror_base: Path | None = None) -> tuple[str, str]:
    """Is Claude working on a turn? (TURN_RUNNING | TURN_IDLE | TURN_UNKNOWN, why). The one
    rule the send path and the watcher use (design 10 S9, MCP-47).

    The session's latest hook event about the turn decides: a session start, Claude's
    idle notice or a Stop is idle; a prompt submitted or a permission prompt is running.
    The transcript, the record, adds what the hooks cannot say. Claude Code opens or
    continues a turn with no UserPromptSubmit of its own after each idle event (a blocking
    Stop hook sends Claude back; an auto-compact fires SessionStart mid-turn; a background
    task's notice starts a turn after the idle notice): a turn the transcript shows open,
    written after the idle event, is running however quiet it is. A turn it shows still
    being written (the event ahead of the copied transcript) is running until it has been
    quiet for LOG_QUIET_S, and a reply whose Stop hooks have not reported is held for
    STOP_HOOK_WAIT_S. A turn the transcript shows over (an Esc after Claude had written,
    which fires no Stop) since the prompt was submitted is idle.

    A session with no event yet is from before 2.0 (TURN_UNKNOWN) when `installed` says its
    Claude does not run the hooks; when it does, Claude is starting and has not reported
    yet, until HOOK_EVENTS_DUE_S has passed with none (a writer that cannot write: logged
    once, `hook_events_missing`); when it could not be read (None), the session waits
    rather than being refused.
    """
    now = time.time() if now is None else now
    any_events, event = latest_hook_event(name, mirror_base)
    if not any_events:
        if installed:
            return TURN_RUNNING, _starting(name, now)
        if installed is None:
            return TURN_RUNNING, "hooks_unread"
        return TURN_UNKNOWN, PREDATES_HOOK_EVENTS
    ss.hooks_silent_since.pop(name, None)
    quiet = now - mtime if mtime else float("inf")
    in_progress = ts.log_shows_turn_in_progress(objs)
    if event is not None and event.event == he.USER_PROMPT_SUBMIT:
        if (objs and not in_progress and quiet >= LOG_QUIET_S
                and _written_after(mtime, event)):
            return TURN_IDLE, "log_finished"
        return TURN_RUNNING, "prompt_submitted"
    if event is not None and event.notification_type == he.PERMISSION_PROMPT:
        return TURN_RUNNING, "waiting_on_permission"
    # Every event left says idle, and after each Claude Code can open or continue a turn
    # with no event of its own: a turn the record shows open, written after the event, is
    # that turn, however quiet it is (a tool call). A SessionStart other than a compact's
    # leaves Claude at its prompt, so a resumed record that ended mid-turn is not a turn
    after_idle = event is None or event.event != he.SESSION_START \
        or event.source == SESSION_START_MID_TURN
    if after_idle and in_progress and (event is None or _written_after(mtime, event)):
        if event is not None and event.event == he.STOP:
            return TURN_RUNNING, "stop_pushed_back"
        return TURN_RUNNING, "turn_open_after_idle"
    if in_progress and quiet < LOG_QUIET_S:
        return TURN_RUNNING, "log_growing"
    if event is None or event.event == he.SESSION_START:
        return TURN_IDLE, "session_started"
    if event.event == he.STOP and ts.awaiting_stop_hooks(objs, objs) \
            and quiet < STOP_HOOK_WAIT_S:
        return TURN_RUNNING, "stop_hooks_running"
    if event.event == he.STOP:
        return TURN_IDLE, "turn_stopped"
    return TURN_IDLE, "idle_prompt"


#: the SessionStart source Claude Code fires inside a running turn (an auto-compact)
SESSION_START_MID_TURN = "compact"


#: how long a session whose Claude runs aidc's hooks may report no event before that is
#: called a fault (Claude Code fires SessionStart as it starts, within a few seconds)
HOOK_EVENTS_DUE_S = 120.0


def _starting(name: str, now: float) -> str:
    """Why a session whose Claude runs the hooks, with no event yet, is not idle: starting,
    or past HOOK_EVENTS_DUE_S `hook_events_missing` (its writer cannot write; logged once,
    since the writer itself says nothing to Claude)."""
    since = ss.hooks_silent_since.setdefault(name, now)
    if now - since < HOOK_EVENTS_DUE_S:
        return "starting"
    if name not in ss.hooks_silence_logged:
        ss.hooks_silence_logged.add(name)
        audit.log_event("hook_events_missing", session=name,
                        silent_s=int(now - since),
                        hint="the session's Claude runs aidc's hooks but none has written "
                             "an event: is its transcript mirror dir there and writable?")
    return "hook_events_missing"


async def _hooks_installed(container: str, name: str) -> bool | None:
    """Whether the session's Claude runs aidc's hooks, read once per session instance."""
    installed = ss.hooks_installed.get(name)
    if installed is None:
        installed = await tmx.hooks_installed(container)
        if installed is not None:
            ss.hooks_installed[name] = installed
    return installed


def outdated_remedy(name: str) -> str:
    """What makes an outdated session report hook events: a session is created again; the
    git agent, which `aidc kill` refuses, runs a rebuilt image (its hooks are in it)."""
    if backend.is_git_session(name):
        return ("It is the git agent: rebuild its image and set it up again "
                "(aidc rebuild, then aidc git setup).")
    return "Kill it and create it again (aidc kill, then aidc create)."


async def session_outdated(container: str, name: str) -> bool:
    """Whether the session predates aidc 2.0's hook events: no event from it, and its
    Claude's managed settings without aidc's hook (MCP-47). A session whose settings could
    not be read is not called outdated."""
    await _sync_session_markers(name)
    any_events, _ = latest_hook_event(name)
    return not any_events and await _hooks_installed(container, name) is False


async def session_state(container: str, name: str) -> SessionState:
    if not await tmx.is_claude_running(container):
        return SessionState(False, None, TURN_IDLE, "claude_not_running")
    await _sync_session_markers(name)
    objs, mtime, status = session_transcript(name)
    installed = await _hooks_installed(container, name)
    any_events, _ = latest_hook_event(name)
    if not any_events and installed is False:
        # outdated (MCP-47): its result carries no screen, so none is read
        return SessionState(True, None, TURN_UNKNOWN, PREDATES_HOOK_EVENTS)
    # the screen, for what a paste needs: the input box, a dialog (S2)
    screen = await read_screen(container, name)
    first_launch = screen.input_box == scr.NOT_AT_PROMPT \
        and screen.dialog in scr.FIRST_LAUNCH_DIALOGS
    if first_launch and not any_events:
        # A first-launch screen (folder trust) before any hook event: Claude waits there for
        # a person, before any turn and before it runs a hook, so it is not working and not
        # "starting" either. Named, so an orchestrator sees why it is stuck (screen.dialog).
        # The silence clock starts again once it is past it.
        ss.hooks_silent_since.pop(name, None)
        return SessionState(True, screen, TURN_IDLE, WHY_NOT_AT_PROMPT)
    turn, why = turn_from_hooks(name, objs if status == "ok" else [], mtime,
                                installed=installed)
    if first_launch and turn != TURN_RUNNING:
        # Claude restarted to the screen after earlier turns. A hook that says a turn is
        # running outranks the screen: the screen never decides a turn is over.
        return SessionState(True, screen, TURN_IDLE, WHY_NOT_AT_PROMPT)
    if turn == TURN_UNKNOWN:
        return SessionState(True, None, turn, why)
    awaiting = ss.sent_awaiting_echo.get(name)
    if awaiting is not None:
        if _prompt_arrived(name, awaiting[0], awaiting[1], objs):
            ss.sent_awaiting_echo.pop(name, None)
        else:
            return SessionState(True, screen, TURN_RUNNING, "sent_prompt_not_in_log")
    if status != "ok":
        return SessionState(True, screen, turn, why)
    cut_off = ts.unanswered_prompt_turn(objs)
    if (cut_off is not None and turn == TURN_IDLE
            and _interrupt_reported(name, cut_off.terminal_uuid)):
        # Already reported to the orchestrator as stopped before Claude wrote anything:
        # that turn is over. Anything Claude does next writes to the transcript, and a
        # new prompt changes the tail, so neither is mistaken for this.
        return SessionState(True, screen, TURN_IDLE, "interrupt_reported")
    if (turn == TURN_IDLE and why in STOPPED_BY_HOOKS and cut_off is not None
            and name in ss.session_watchers):
        return SessionState(True, screen, TURN_RUNNING, "interrupt_not_reported_yet")
    return SessionState(True, screen, turn, why)


def paste_reason(state: SessionState) -> str:
    """"" when a prompt may be pasted now, else why not:

      session_outdated      the session predates hook events: recreate it (MCP-47)
      claude_not_running    the claude window is at a shell
      claude_not_at_prompt  a dialog (e.g. folder trust, login) instead of the input box
      screen_unrecognized   neither the input box nor a known dialog: a layout aidc
                            does not recognize (a screen excerpt is saved)
      claude_busy           Claude is working on a turn, or a prompt just pasted has
                            not shown up in the transcript yet
      agent_list_selected   the background-agent list has the keyboard (a person is
                            in it), where typed keys are list commands
      input_has_text        a person has unsent text in the input box
    """
    if state.turn == TURN_UNKNOWN:
        return "session_outdated"
    if not state.claude_running or state.screen is None:
        return "claude_not_running"
    if state.screen.input_box == scr.NOT_AT_PROMPT:
        return WHY_NOT_AT_PROMPT
    if state.screen.input_box == scr.UNRECOGNIZED:
        return "screen_unrecognized"
    if state.turn == TURN_RUNNING:
        return "claude_busy"
    if state.screen.list_focused:
        return "agent_list_selected"
    if state.screen.input_box == scr.HAS_TEXT:
        return "input_has_text"
    return ""


def _prompt_arrived(session: str, text: str, sent_at: float, objs: list[dict]) -> bool:
    """Whether the transcript shows a pasted prompt arrived — and, when no turn will
    ever claim it, give its send record back.

    Claude Code records a prompt pasted while it is working only as a `queue-operation`
    and answers it inside the running turn, so it never becomes a prompt line; if the
    turn ends first, it runs it next as a prompt line marked `promptSource: "queued"`,
    which no turn attributes (human_prompt_text). A local slash command (/clear,
    /model) arrives as a prompt line, but Claude Code runs it itself and no turn opens
    for it. In each case no turn can claim the prompt, and its
    record would wait out its 24 h, where the same words typed by a person would match
    it and be delivered as the orchestrator's own prompt. Both watchers of a pasted
    prompt (the free check and watch_for_echo) come through here, because either can
    be the one that sees it first.
    """
    index = ts.prompt_index_since(objs, text, sent_at)
    if index is None:
        return False
    line = objs[index]
    if line.get("type") == "queue-operation" or (
            line.get("type") == "user" and not ts.human_prompt_text(line)
            and not ts.is_local_command(objs, index)):
        # Taken into a running turn, or held while one ran and then run as a prompt
        # line no turn attributes to anyone (promptSource "queued").
        event = "session_send_queued_by_claude"
    elif ts.is_local_command(objs, index):
        event = "session_send_ran_as_local_command"
    else:
        return True
    try:
        entry = ts.take_sent_entry(ss.WATCHER_STATE_DIR, session, text)
        by = None if entry is None else entry["by"]
        if entry is not None and by is not None and event == "session_send_queued_by_claude":
            # The answer comes in a turn with no prompt of its own (the running one, or
            # the next one Claude Code runs it in), which takes the session's recorded
            # origin: make that this prompt's, not the earlier turn's. Taken into the
            # running turn, that turn keeps the batch it opened with, and the reply it
            # ends with names the joined prompt after its own (_with_joined); run next
            # on its own, the next turn answers this prompt alone.
            joined = line.get("type") == "queue-operation"
            ts.record_prompt_origin(
                ss.WATCHER_STATE_DIR, session, "person" if by else "orchestrator", sent_by=by,
                batch=(ts.last_prompt_batch(ss.WATCHER_STATE_DIR, session) if joined
                       else entry.get("batch")))
            if joined and entry.get("batch"):
                ts.record_joined_batch(ss.WATCHER_STATE_DIR, session, entry["batch"])
    except OSError as exc:
        audit.log_event("session_send_record_release_failed", session=session,
                  error_type=type(exc).__name__, error=repr(exc))
    else:
        if by is not None:
            audit.log_event(event, session=session, prompt_len=len(text))
    return True


async def watch_for_echo(session: str, text: str, sent_at: float) -> None:
    """Clear the busy hold a paste set once the transcript shows the prompt, or after
    _ECHO_WAIT_S, logging a prompt that never showed. Runs on its own so the log line
    does not depend on something else checking the session again."""
    entry = (text, sent_at)
    for _ in range(max(1, int(_ECHO_WAIT_S / _ECHO_POLL_S))):
        if ss.sent_awaiting_echo.get(session) != entry:
            return   # seen by a free check, or superseded by a later paste
        objs, _, _ = session_transcript(session)
        if _prompt_arrived(session, text, sent_at, objs):
            if ss.sent_awaiting_echo.get(session) == entry:
                ss.sent_awaiting_echo.pop(session, None)
            return
        await asyncio.sleep(_ECHO_POLL_S)
    if ss.sent_awaiting_echo.get(session) == entry:
        ss.sent_awaiting_echo.pop(session, None)
        audit.log_event("session_send_not_seen_in_transcript", session=session,
                  prompt_len=len(text), waited_s=_ECHO_WAIT_S)


SESSION_EXISTS = "exists"


SESSION_GONE = "gone"


SESSION_UNKNOWN = "unknown"


async def session_instance(name: str) -> tuple[str, str]:
    """Whether session `name` exists (SESSION_EXISTS, SESSION_GONE or SESSION_UNKNOWN),
    and its instance id ("" unless it exists).

    A session is identified by its network, aidc-<name>-net: `aidc create` makes it,
    `aidc kill` removes it, and `aidc upgrade` / `aidc restart` keep it while they
    replace or restart the dev container. So the id tells a session killed and created
    again under the same name from the same session upgraded, and a dev container
    briefly missing in the middle of an upgrade is not a gone session. `aidc kill`
    makes sure the network is removed even when something outside the session is
    attached to it. Only docker saying that network does not exist is gone; any other
    failure (a daemon restart, a socket error, a missing docker context) is unknown,
    and queues keep holding.
    """
    try:
        proc = await asyncio.create_subprocess_exec(
            *backend.instance_argv(name),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError:
        return SESSION_UNKNOWN, ""
    stdout, stderr = await proc.communicate()
    if proc.returncode == 0:
        return SESSION_EXISTS, stdout.decode("utf-8", errors="replace").strip()
    if backend.instance_gone(name, stderr.decode("utf-8", errors="replace")):
        return SESSION_GONE, ""
    return SESSION_UNKNOWN, ""


# How long a reply whose Stop hooks have not reported yet is held back. A blocking
# hook's pushback is written only when the hook finishes, so a reply delivered
# before then can be the first half of a turn the hook is about to reopen. Claude
# Code writes a stop record after every reply once hooks finish, so this only
# lapses when a hook runs longer than this, or a record goes missing; either way
# the reply is then delivered rather than held forever.
STOP_HOOK_WAIT_S = 120.0
