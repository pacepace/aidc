"""MCP tool implementations.

Each tool is a thin wrapper that shells out to the `aidc` CLI (mounted
at /aidc/scripts/aidc inside the container). Tools return a structured
envelope: {"ok": bool, "error"?: str, "data"?: any}.

Long-running tools (session_create, session_invoke) accept a `Context`
parameter and emit progress notifications during execution.
"""

from __future__ import annotations

import asyncio
import base64
import dataclasses
import functools
import hashlib
import inspect
import json
import os
import shlex
import subprocess
import time
from pathlib import Path
from typing import Annotated, Any

import httpx
from mcp.server.fastmcp import Context
from pydantic import Field

from aidc_mcp import scope
from aidc_mcp import screen as scr
from aidc_mcp import transcript as ts
from aidc_mcp.audit import log_event
from aidc_mcp.auth import _load_token
from aidc_mcp.resources import parse_audit_dir

AIDC = os.environ.get("AIDC_CLI", "/aidc/scripts/aidc")

# Reused param descriptions (surfaced in the MCP tool schema). Trigger-/usage-oriented
# so smaller models supply them correctly — especially: never invent conversation_id.
_NAME_DESC = (
    "The aidc session to use. Pick a running session (call session_list) or one of the "
    "open-webhook sessions named in this tool's description."
)
_CONV_ID_DESC = (
    "Injected automatically by the orchestrator. Leave this unset — do NOT supply, invent, or "
    "reason about it."
)
_PROMPT_DESC = "The prompt / message text to send to the session."
# Config file lives in the same directory as the token file (both on the
# aidc-config volume, mounted at /aidc-config/ in the container).
# Override AIDC_MCP_TOKEN_FILE to relocate both simultaneously.
_CONFIG_PATH = (
    Path(os.environ.get("AIDC_MCP_TOKEN_FILE", "/aidc-config/mcp-token")).parent / "config.yaml"
)


def _yaml_scalar(raw: str) -> str:
    """Parse the value half of a `key: value` config line into a plain string.

    Strips an inline `# comment` and surrounding quotes. The comment strip is
    NOT optional politeness: the config template shipped in the README (and by
    `aidc config default`) documents every key with a trailing comment —

        callback_url: ""    # base URL of the orchestrator's callback endpoint (e.g. https://...)

    — so filling it in the obvious way (replace the `""`, keep the comment) used
    to yield a URL with the whole comment glued onto it, and every callback POST
    went to an unresolvable host. The shell config parser (lib/config.sh) has
    always stripped these; this parser did not, so the two disagreed about the
    same file.

    Follows the YAML rule that `#` opens a comment only at line start or after
    whitespace, so a `#` inside an unquoted value (a URL fragment) survives. A
    quoted value is taken up to its closing quote, so a `# ` inside quotes is
    content, not a comment.
    """
    value = raw.strip()
    if value[:1] in ("'", '"'):
        quote = value[0]
        end = value.find(quote, 1)
        if end != -1:
            return value[1:end]
        return value[1:]
    cut = len(value)
    for i, ch in enumerate(value):
        if ch == "#" and (i == 0 or value[i - 1].isspace()):
            cut = i
            break
    return value[:cut].strip()


def _metallm_callback_url() -> str:
    """Read metallm.callback_url from the aidc config file.

    Inside the container the config lives at /aidc-config/config.yaml
    (mounted from ~/.config/aidc/config.yaml on the host).
    """
    if not _CONFIG_PATH.exists():
        return ""
    in_metallm_section = False
    for line in _CONFIG_PATH.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped == "metallm:":
            in_metallm_section = True
            continue
        if in_metallm_section:
            if stripped.startswith("callback_url:"):
                return _yaml_scalar(stripped.split(":", 1)[1]).rstrip("/")
            # A non-empty, non-comment line at column 0 is a new top-level key.
            if stripped and not stripped.startswith("#") and not line[0:1].isspace():
                break
    return ""


def _metallm_turn_settle_seconds(default: float = 4.0) -> float:
    """Read metallm.turn_settle_seconds from the aidc config file.

    How long the transcript must stay quiet (no new bytes) after an end_turn before
    the turn is delivered. This coalesces a multi-segment response — Claude emitting
    an empty end_turn and then continuing with the real answer — into one delivery,
    so the watcher signals "ready" once per exchange instead of mid-stream. <= 0
    disables the wait. Default 4s.
    """
    if not _CONFIG_PATH.exists():
        return default
    in_metallm_section = False
    for line in _CONFIG_PATH.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped == "metallm:":
            in_metallm_section = True
            continue
        if in_metallm_section:
            if stripped.startswith("turn_settle_seconds:"):
                value = _yaml_scalar(stripped.split(":", 1)[1])
                try:
                    return float(value)
                except ValueError:
                    return default
            if stripped and not stripped.startswith("#") and not line[0:1].isspace():
                break
    return default

# Holds references to background tasks so they aren't GC'd before completion.
_background_tasks: set[asyncio.Task[None]] = set()


def _fire(coro: Any) -> None:
    task = asyncio.create_task(coro)
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)


# ---- shared claude session helpers -----------------------------------------

_SESSION_WINDOW = "claude"

# Foreground pane commands that mean Claude is NOT running (a bare shell / idle).
_SHELL_COMMANDS = frozenset({"bash", "sh", "zsh", "fish", "dash", ""})

# Whether Claude is busy comes from its transcript (design-10 S1), which the dev
# container mirrors for the MCP about every 2 s. A turn the transcript shows in
# progress is only checked against the screen once the transcript has been quiet for
# longer than that copy lag.
_LOG_QUIET_S = 6.0
# An Esc pressed before Claude writes anything leaves the transcript showing a turn in
# progress forever; the status row's `esc to interrupt` settles it. That wording is
# trusted only once this process has seen it on the session's screen. Until then, a
# transcript quiet for this long with no working text on screen counts as stopped.
_LOG_STALL_S = 600.0
# After a paste, the session counts as busy until the transcript shows the prompt
# arrived, for at most this long. A prompt that never shows is logged, not re-sent:
# a paste that returned success almost always landed, and a second copy is worse.
_ECHO_WAIT_S = 30.0
# Poll interval for the free check. Two consecutive free readings are required, so a
# turn that starts the moment another ends (a background task's notification) is not
# mistaken for a free session; the readings are spaced past the mirror's copy interval
# so they cannot both come from the same stale copy.
_FREE_POLL_S = 2.5
_ECHO_POLL_S = 2.0

TURN_RUNNING = "running"
TURN_IDLE = "idle"

# Per-session asyncio locks: serialize concurrent session_send calls.
_session_send_locks: dict[str, asyncio.Lock] = {}

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
_pending_sends: dict[str, list[ts.QueuedPrompt]] = {}

# Per-session drainer tasks: one long-lived injector per session with a non-empty
# queue. Keyed by session name (like the send lock) rather than per conversation.
_pending_drainers: dict[str, asyncio.Task[None]] = {}

# How long session_send itself waits for the session to be free before queueing.
# Short on purpose: anything longer is the drainer's job, and a busy send should
# return "queued" promptly.
_SEND_FREE_WAIT_S = 5.0

# How long each drainer free-wait runs before the drainer re-checks that the session
# still exists and records the latest waiting reason. Not a deadline: it loops.
_QUEUE_POLL_S = 60.0

# Backoff between failed pastes of the same prompt: 2, 4, 8 … seconds, capped. There
# is no attempt limit; each failure is logged and shown as the waiting reason.
_PASTE_RETRY_MAX_S = 60.0

# Hard cap on queue depth per session. A runaway orchestrator that keeps sending
# into a wedged session must not grow this without bound; past the cap a NEW prompt
# is refused (audibly). A prompt already accepted is never dropped by it.
_PENDING_MAX_DEPTH = 25

# What a person attached to the session sees on the tmux status line while a queued
# prompt waits on their unsent text. tmux-start.sh shows the @aidc_waiting option.
_WAITING_ON_INPUT_TEXT = (
    "aidc: orchestrator message waiting — press Enter or clear your input to let it through"
)

# Per-session background watcher tasks. The KEYS are the sessions with an open
# webhook (responses stream back to the orchestrator). We surface that set in the
# session-tool descriptions so the LLM knows which session to talk to without
# having to remember or rediscover it.
_session_watchers: dict[str, asyncio.Task[None]] = {}

# Tools that talk to a session by `name` and therefore advertise which sessions
# currently have an open webhook.
_SESSION_AWARE_TOOLS = ("session_send", "session_invoke", "session_invoke_async")
# Base (static) description captured at registration, before any live suffix.
_tool_base_desc: dict[str, str] = {}


def _watching_suffix() -> str:
    """The live tail appended to session-tool descriptions: which sessions have
    an open webhook right now."""
    names = sorted(_session_watchers.keys())
    if names:
        return (
            "\n\nOPEN WEBHOOKS — these sessions stream their responses back to this "
            "conversation automatically; pass one of these as `name`: "
            + ", ".join(names)
            + "."
        )
    return (
        "\n\nNo session is being watched yet. session_send auto-starts a "
        "webhook for the `name` you pass (session_watch starts one explicitly)."
    )


def _refresh_session_tool_descriptions(app: Any) -> None:
    """Rewrite the session-aware tools' descriptions to reflect the current set
    of open-webhook sessions. Idempotent; safe to call on every change."""
    tools = getattr(getattr(app, "_tool_manager", None), "_tools", {})
    suffix = _watching_suffix()
    for tname in _SESSION_AWARE_TOOLS:
        tool = tools.get(tname)
        if tool is None:
            continue
        base = _tool_base_desc.get(tname)
        if base is None:  # first touch: capture the static base
            base = tool.description or ""
            _tool_base_desc[tname] = base
        tool.description = base + suffix


async def _announce_watchers(app: Any) -> None:
    """Refresh descriptions and notify connected clients to refetch tools/list.

    Best-effort: if no request context/session is active (e.g. a background
    caller), the description is still updated and the next tools/list reflects it.
    """
    _refresh_session_tool_descriptions(app)
    try:
        await app.get_context().session.send_tool_list_changed()
    except Exception as exc:  # prawduct:allow prawduct/broad-except -- best-effort notify
        log_event("tool_list_changed_notify_failed",
                  error_type=type(exc).__name__, error=repr(exc))


async def _tmux_exec(container: str, args: list[str]) -> int:
    """Run a tmux command inside the container as vscode user. Returns exit code."""
    proc = await asyncio.create_subprocess_exec(
        "docker", "exec", "-u", "vscode", container, "tmux", *args,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    return await proc.wait()


async def _capture_screen(container: str, window: str) -> str:
    """The visible pane with its escape sequences (-e), wrapped lines joined (-J)."""
    proc = await asyncio.create_subprocess_exec(
        "docker", "exec", "-u", "vscode", container,
        "tmux", "capture-pane", "-t", f"main:{window}", "-p", "-e", "-J",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    return stdout.decode("utf-8", errors="replace")


async def _pane_current_command(container: str, window: str) -> str:
    """Return the current foreground command name running in a tmux pane."""
    proc = await asyncio.create_subprocess_exec(
        "docker", "exec", "-u", "vscode", container,
        "tmux", "display-message", "-t", f"main:{window}", "-p", "#{pane_current_command}",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    return stdout.decode().strip().lower()


async def _window_exists(container: str, window: str) -> bool:
    """Return True if a tmux window with the given name exists in the main session."""
    proc = await asyncio.create_subprocess_exec(
        "docker", "exec", "-u", "vscode", container,
        "tmux", "list-windows", "-t", "main", "-F", "#{window_name}",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    return window in stdout.decode().splitlines()


async def _is_claude_running(container: str) -> bool:
    """Return True if Claude is the foreground process in the claude tmux window."""
    if not await _window_exists(container, _SESSION_WINDOW):
        return False
    cmd = await _pane_current_command(container, _SESSION_WINDOW)
    return cmd not in _SHELL_COMMANDS


# Prompts pasted into a session whose arrival the transcript has not shown yet:
# name -> (prompt as pasted, wall-clock time of the paste). _watch_for_echo owns the
# expiry, so a prompt that never shows is logged even if nothing checks again.
_sent_awaiting_echo: dict[str, tuple[str, float]] = {}
# Sessions whose status row this process has seen show `esc to interrupt`, so its
# absence can be trusted (see _LOG_STALL_S).
_working_indicator_seen: set[str] = set()
# (session, prompt uuid) the watcher has reported as interrupted before Claude wrote
# anything. The send path waits for that report before treating such a session as
# free, so the orchestrator hears about the interrupt before its next prompt lands.
_reported_interrupts: set[tuple[str, str]] = set()
# Last (reason, why) the free check logged per session: it logs on change only.
_last_free_verdict: dict[str, tuple[str, str]] = {}
# Last raw screen capture per session, kept for the unrecognized-screen excerpt.
_last_screen_raw: dict[str, str] = {}


@dataclasses.dataclass(frozen=True)
class SessionState:
    """What the MCP knows about a session right now (design-10 S1/S2).

    `turn` is Claude's turn state alone (TURN_RUNNING or TURN_IDLE), with `why` naming
    the evidence. The input box is a separate matter, in `screen`: whether a prompt may
    be pasted combines both (_paste_reason), while "is Claude still working?" reads
    only `turn`.
    """
    claude_running: bool
    screen: scr.ScreenState | None
    turn: str
    why: str


async def _read_screen(container: str, name: str) -> scr.ScreenState:
    raw = await _capture_screen(container, _SESSION_WINDOW)
    _last_screen_raw[name] = raw
    state = scr.classify(raw)
    if state.working:
        _working_indicator_seen.add(name)
    return state


def _session_transcript(name: str) -> tuple[list[dict], float, str]:
    """The session's active mirrored transcript, its last-modified time, and whether
    it could be read: "ok", "none" (nobody has prompted the session yet) or
    "unreadable"."""
    active = ts.resolve_active_transcript(Path(_TRANSCRIPTS_BASE) / name)
    if active is None:
        return [], 0.0, "none"
    try:
        data = active.read_text(encoding="utf-8", errors="replace")
        mtime = active.stat().st_mtime
    except OSError:
        return [], 0.0, "unreadable"
    return ts.parse_jsonl(data), mtime, "ok"


def _turn_verdict(name: str, objs: list[dict], quiet: float,
                  screen: scr.ScreenState | None) -> tuple[str, str]:
    """Is Claude working on a turn? (TURN_RUNNING | TURN_IDLE, why). The one rule both
    the send path and the watcher use.

    The transcript decides. When it shows a turn in progress that has gone quiet, a
    reply still waiting on its Stop hooks is held for _STOP_HOOK_WAIT_S whatever the
    screen shows. Past that hold, and for every other quiet open turn, the status row's
    working text settles it: shown means working; absent means stopped, trusted once
    this process has seen the text on the session, else only after _LOG_STALL_S.
    """
    if not ts.log_shows_turn_in_progress(objs):
        return TURN_IDLE, "log_finished"
    if quiet < _LOG_QUIET_S:
        return TURN_RUNNING, "log_growing"
    if ts.awaiting_stop_hooks(objs, objs) and quiet < _STOP_HOOK_WAIT_S:
        return TURN_RUNNING, "stop_hooks_running"
    if screen is None:
        return TURN_RUNNING, "screen_unread"
    if screen.working:
        return TURN_RUNNING, "status_row_working"
    if name in _working_indicator_seen:
        return TURN_IDLE, "status_row_idle"
    if quiet >= _LOG_STALL_S:
        return TURN_IDLE, "log_stalled"
    return TURN_RUNNING, "status_row_unproven"


async def _session_state(container: str, name: str) -> SessionState:
    if not await _is_claude_running(container):
        return SessionState(False, None, TURN_IDLE, "claude_not_running")
    screen = await _read_screen(container, name)
    objs, mtime, status = _session_transcript(name)
    awaiting = _sent_awaiting_echo.get(name)
    if awaiting is not None:
        if ts.prompt_seen_since(objs, *awaiting):
            _sent_awaiting_echo.pop(name, None)
        else:
            return SessionState(True, screen, TURN_RUNNING, "sent_prompt_not_in_log")
    if status != "ok":
        return SessionState(True, screen, TURN_IDLE, f"transcript_{status}")
    turn, why = _turn_verdict(name, objs, time.time() - mtime, screen)
    if turn == TURN_IDLE and why in ("status_row_idle", "log_stalled"):
        cut_off = ts.unanswered_prompt_turn(objs)
        if (cut_off is not None and name in _session_watchers
                and (name, cut_off.terminal_uuid) not in _reported_interrupts):
            return SessionState(True, screen, TURN_RUNNING, "interrupt_not_reported_yet")
    return SessionState(True, screen, turn, why)


def _paste_reason(state: SessionState) -> str:
    """"" when a prompt may be pasted now, else why not:

      claude_not_running    the claude window is at a shell
      claude_not_at_prompt  a dialog (e.g. folder trust, login) instead of the input box
      screen_unrecognized   neither the input box nor a known dialog: a layout aidc
                            does not recognize (a screen excerpt is saved)
      claude_busy           Claude is working on a turn, or a prompt just pasted has
                            not shown up in the transcript yet
      input_has_text        a person has unsent text in the input box
    """
    if not state.claude_running or state.screen is None:
        return "claude_not_running"
    if state.screen.input_box == scr.NOT_AT_PROMPT:
        return "claude_not_at_prompt"
    if state.screen.input_box == scr.UNRECOGNIZED:
        return "screen_unrecognized"
    if state.turn == TURN_RUNNING:
        return "claude_busy"
    if state.screen.input_box == scr.HAS_TEXT:
        return "input_has_text"
    return ""


def _save_unrecognized_screen(name: str) -> None:
    """Keep the capture that did not match, for whoever updates screen.py."""
    raw = _last_screen_raw.get(name)
    if raw is None:
        return
    try:
        d = Path(_WATCHER_STATE_DIR) / "screens"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{ts._slug(name)}-unrecognized.ansi").write_text(raw, encoding="utf-8")
    except OSError as exc:
        log_event("session_screen_save_failed", session=name, error_type=type(exc).__name__)


async def _check_free(container: str, name: str) -> str:
    """Whether a prompt can be pasted into the session now: "" or a reason (see
    _paste_reason). Every change of verdict is logged with its evidence, so a "free"
    reached without transcript evidence (no transcript, a stalled one, the status
    row) is on record."""
    state = await _session_state(container, name)
    reason = _paste_reason(state)
    verdict = (reason, state.why)
    if _last_free_verdict.get(name) != verdict:
        _last_free_verdict[name] = verdict
        log_event("session_free_check", session=name, reason=reason, turn=state.turn,
                  why=state.why)
        if reason == "screen_unrecognized":
            _save_unrecognized_screen(name)
    return reason


async def _wait_until_free(container: str, name: str, timeout: float) -> str:
    """Poll _check_free until two consecutive readings are free (""), or the timeout's
    worth of polls runs out (the last reason). Counted in polls rather than wall-clock
    so the loop terminates deterministically under a patched clock."""
    polls = max(2, int(timeout / _FREE_POLL_S))
    streak = 0
    reason = ""
    for i in range(polls):
        reason = await _check_free(container, name)
        streak = 0 if reason else streak + 1
        if streak >= 2:
            return ""
        if i < polls - 1:
            await asyncio.sleep(_FREE_POLL_S)
    return reason or "claude_busy"


async def _wait_for_turn_end(container: str, name: str, timeout: float) -> str:
    """Poll until Claude's turn is over on two consecutive readings (""), ignoring the
    input box: a person's unsent text, or a prompt Esc put back there, does not keep a
    turn running. Returns "claude_not_running" or "claude_busy" when it does not end."""
    polls = max(2, int(timeout / _FREE_POLL_S))
    streak = 0
    for i in range(polls):
        state = await _session_state(container, name)
        if not state.claude_running:
            return "claude_not_running"
        streak = 0 if state.turn == TURN_RUNNING else streak + 1
        if streak >= 2:
            return ""
        if i < polls - 1:
            await asyncio.sleep(_FREE_POLL_S)
    return "claude_busy"


async def _watch_for_echo(session: str, text: str, sent_at: float) -> None:
    """Clear the busy hold a paste set once the transcript shows the prompt, or after
    _ECHO_WAIT_S, logging a prompt that never showed. Runs on its own so the log line
    does not depend on something else checking the session again."""
    entry = (text, sent_at)
    for _ in range(max(1, int(_ECHO_WAIT_S / _ECHO_POLL_S))):
        if _sent_awaiting_echo.get(session) != entry:
            return   # seen by a free check, or superseded by a later paste
        objs, _, _ = _session_transcript(session)
        if ts.prompt_seen_since(objs, text, sent_at):
            if _sent_awaiting_echo.get(session) == entry:
                _sent_awaiting_echo.pop(session, None)
            return
        await asyncio.sleep(_ECHO_POLL_S)
    if _sent_awaiting_echo.get(session) == entry:
        _sent_awaiting_echo.pop(session, None)
        log_event("session_send_not_seen_in_transcript", session=session,
                  prompt_len=len(text), waited_s=_ECHO_WAIT_S)


def _reply_from_transcript(name: str, prompt: str, sent_at: float) -> str:
    """The reply text to `prompt`, sent at `sent_at`, from the session's transcript:
    every completed turn after the prompt's line, interrupted ones with their note.
    "" when the prompt or its reply is not there (interrupted before Claude wrote
    anything, or folded into a turn that was already running)."""
    objs, _, _ = _session_transcript(name)
    start = ts.prompt_index_since(objs, prompt, sent_at)
    if start is None:
        return ""
    turns = ts.extract_completed_turns(objs[start:])
    return "\n\n".join(ts.render_delivery(t.text, [], interrupted=t.interrupted)
                       for t in turns if t.text or t.interrupted)


async def _load_and_paste(container: str, text: str, window: str) -> bool:
    """Load text into a tmux paste buffer and paste it into the window. Returns True on success."""
    proc = await asyncio.create_subprocess_exec(
        "docker", "exec", "-i", "-u", "vscode", container,
        "tmux", "load-buffer", "-b", "aidc-send", "-",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    await proc.communicate(text.encode("utf-8"))
    if proc.returncode != 0:
        return False
    rc = await _tmux_exec(container, ["paste-buffer", "-b", "aidc-send", "-t", f"main:{window}"])
    return rc == 0


def _write_send_dead_letter(session: str, queued: ts.QueuedPrompt, reason: str) -> None:
    """Persist a prompt that will never be pasted because its session is gone, so it
    is recorded, not lost. Sibling of _write_dead_letter (an undelivered REPLY)."""
    dl = Path(_WATCHER_STATE_DIR) / "dead-letter"
    try:
        dl.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(
            f"{queued.enqueued_at}\n{queued.text}".encode()).hexdigest()[:16]
        (dl / f"send__{ts._slug(session)}__{digest}.json").write_text(
            json.dumps({"session": session, "prompt": queued.text, "reason": reason,
                        "enqueued_at": queued.enqueued_at,
                        "paste_attempts": queued.paste_attempts,
                        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}),
            encoding="utf-8",
        )
    except OSError as exc:
        log_event("session_send_dead_letter_failed", session=session, reason=reason,
                  error_type=type(exc).__name__)


def _record_sent(name: str, text: str) -> None:
    """Remember a prompt the MCP just injected into `name`'s pane, so the drain can
    tell it apart from one a person typed at the terminal (see
    ts.record_sent_prompt). Best-effort: a failure to persist must not fail the
    send that already landed — it degrades to that one reply carrying a
    terminal-typed note it should not have, which the audit line explains."""
    try:
        ts.record_sent_prompt(_WATCHER_STATE_DIR, name, text)
    except OSError as exc:
        log_event("session_send_record_failed", session=name, prompt_len=len(text),
                  error_type=type(exc).__name__, error=repr(exc))


def _terminal_prompts(session: str, prompts: tuple[str, ...], state_dir: Path) -> list[str]:
    """The subset of a turn's opening prompts that a PERSON typed at the terminal:
    every prompt that does not match one the MCP itself injected (each match
    consumes its record entry). A record that cannot be updated counts the prompt
    as the MCP's own — an orchestrator prompt mislabelled as the person's is the
    confusion this exists to remove, so it is the side never to err on."""
    typed: list[str] = []
    for prompt in prompts:
        try:
            if not ts.consume_sent_prompt(state_dir, session, prompt):
                typed.append(prompt)
        except OSError as exc:
            log_event("transcript_sent_record_failed", session=session,
                      error_type=type(exc).__name__, error=repr(exc))
    return typed


async def _inject(container: str, text: str, window: str, *, session: str) -> bool:
    """Paste one prompt into the window and press Enter. True when it went in.

    The ONLY way a prompt reaches the pane, so it is also the only place the send
    record is written: a paste that landed is recorded here, on success, for
    `session` — the drain tells the orchestrator's prompts from a person's by that
    record alone, so a paste path that skipped it would ship a reply falsely
    framed as answering something the person typed."""
    if not await _load_and_paste(container, text, window):
        return False
    await _tmux_exec(container, ["send-keys", "-t", f"main:{window}", "Enter"])
    _record_sent(session, text)
    # Until the transcript shows this prompt, a follow-up's free check must read the
    # session as busy: the mirrored transcript lags the paste by a couple of seconds,
    # and in that gap it still shows the previous, finished turn.
    sent_at = time.time()
    _sent_awaiting_echo[session] = (text, sent_at)
    _fire(_watch_for_echo(session, text, sent_at))
    return True


CONTAINER_EXISTS = "exists"
CONTAINER_GONE = "gone"
CONTAINER_UNKNOWN = "unknown"

# Consecutive unexpected drainer failures per session, for the restart backoff.
_drainer_failures: dict[str, int] = {}
# Sessions whose tmux status line currently shows the waiting-on-input notice.
_waiting_notice_shown: set[str] = set()


async def _container_state(container: str) -> str:
    """Whether the session's dev container exists (running or not). `aidc kill`
    removes it, and that is the only thing that ends a session's queue, so only a
    definite "no such container" answer counts as gone. Any other docker failure (a
    daemon restart, a socket error) is CONTAINER_UNKNOWN, and queues keep holding."""
    proc = await asyncio.create_subprocess_exec(
        "docker", "inspect", "--format", "{{.Id}}", container,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    if proc.returncode == 0:
        return CONTAINER_EXISTS
    # Measured on Docker 29.8: "Error: no such object: <name>". Older daemons word it
    # "Error response from daemon: No such container: <name>".
    err = stderr.decode("utf-8", errors="replace").lower()
    if "no such object" in err or "no such container" in err:
        return CONTAINER_GONE
    return CONTAINER_UNKNOWN


def _persist_queue(name: str) -> None:
    try:
        ts.save_send_queue(_WATCHER_STATE_DIR, name, _pending_sends.get(name, []))
    except OSError as exc:
        log_event("session_send_queue_persist_failed", session=name,
                  error_type=type(exc).__name__, error=repr(exc))


async def _set_waiting_reason(container: str, name: str, reason: str) -> None:
    """Record why the queue's head is waiting (the rest wait behind it), persist on a
    change, and show or clear the tmux status-line notice for unsent input."""
    queue = _pending_sends.get(name)
    if not queue:
        return
    await _show_waiting_on_input(container, name, reason == "input_has_text")
    wanted = [reason] + ["queued_behind"] * (len(queue) - 1)
    if [q.waiting_reason for q in queue] == wanted:
        return
    for q, r in zip(queue, wanted, strict=True):
        q.waiting_reason = r
    _persist_queue(name)
    log_event("session_send_queue_waiting", session=name, reason=reason, depth=len(queue))


async def _show_waiting_on_input(container: str, name: str, show: bool) -> None:
    """Set or clear the status-line notice, tracking whether it is showing on its own
    (not from a prompt's reason, which other paths overwrite)."""
    if show == (name in _waiting_notice_shown):
        return
    args = (["set-option", "-t", "main", "@aidc_waiting", _WAITING_ON_INPUT_TEXT] if show
            else ["set-option", "-t", "main", "-u", "@aidc_waiting"])
    await _tmux_exec(container, args)
    if show:
        _waiting_notice_shown.add(name)
    else:
        _waiting_notice_shown.discard(name)


async def _drain_pending_sends(container: str, name: str) -> None:
    """Paste queued prompts into `name`'s pane, one at a time, as it becomes free.

    Runs until the queue empties or the session's container is gone, and never gives
    up on a prompt otherwise: a busy Claude, unsent text in the input box, a stopped
    Claude or a failing paste all just keep it waiting, with the reason recorded.

    The long free-wait happens WITHOUT the send lock held — holding it across a
    22-minute turn would block every concurrent session_send for the duration. The
    lock is taken only around the paste itself, which is what actually needs
    serializing against a direct send. Order is preserved because session_send
    enqueues rather than pasting whenever the queue is non-empty."""
    lock = _session_send_locks.setdefault(name, asyncio.Lock())
    failed = False
    try:
        while _pending_sends.get(name):
            state = await _container_state(container)
            if state == CONTAINER_GONE:
                queued = _pending_sends.pop(name, [])
                for q in queued:
                    _write_send_dead_letter(name, q, "session_killed")
                _persist_queue(name)
                _waiting_notice_shown.discard(name)
                log_event("session_send_queue_abandoned", session=name,
                          dropped=len(queued), reason="session_killed")
                return
            if state == CONTAINER_UNKNOWN:
                log_event("session_send_queue_container_unknown", session=name)
            reason = await _wait_until_free(container, name, timeout=_QUEUE_POLL_S)
            if reason:
                await _set_waiting_reason(container, name, reason)
                continue
            retry_in = 0.0
            async with lock:
                queue = _pending_sends.get(name)
                if not queue:
                    return
                # Re-verify under the lock: the session may have picked up work
                # between the wait above and acquiring it.
                reason = await _check_free(container, name)
                if reason:
                    await _set_waiting_reason(container, name, reason)
                    continue
                head = queue[0]
                if await _inject(container, head.text, _SESSION_WINDOW, session=name):
                    queue.pop(0)
                    _drainer_failures.pop(name, None)
                    await _show_waiting_on_input(container, name, False)
                    if not queue:
                        _pending_sends.pop(name, None)
                    else:
                        queue[0].waiting_reason = ""
                    _persist_queue(name)
                    log_event("session_send_queued_injected", session=name,
                              prompt_len=len(head.text), remaining=len(queue),
                              paste_attempts=head.paste_attempts)
                    continue
                head.paste_attempts += 1
                _persist_queue(name)
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
        if _pending_drainers.get(name) is asyncio.current_task():
            _pending_drainers.pop(name, None)
            # A send that queued while this drainer was winding down would
            # otherwise be orphaned: _enqueue_send saw a live (not-yet-done)
            # drainer and declined to start one, and then that drainer exited. The
            # same applies when the drainer stopped on an unexpected error: the
            # prompts are still accepted, so hand them to a fresh drainer, after a
            # backoff so an error that recurs every cycle does not spin.
            if _pending_sends.get(name):
                delay = 0.0
                if failed:
                    n = _drainer_failures.get(name, 0) + 1
                    _drainer_failures[name] = n
                    delay = min(_PASTE_RETRY_MAX_S, 2.0 ** min(n, 6))
                _spawn_drainer(container, name, delay=delay)


def _spawn_drainer(container: str, name: str, *, delay: float = 0.0) -> None:
    """Start the per-session drainer unless a live one is already registered."""
    drainer = _pending_drainers.get(name)
    if drainer is not None and not drainer.done():
        return

    async def run() -> None:
        if delay:
            await asyncio.sleep(delay)
        await _drain_pending_sends(container, name)

    task = asyncio.create_task(run())
    _pending_drainers[name] = task
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)


async def _enqueue_send(name: str, container: str, prompt: str, reason: str) -> int:
    """Queue a prompt for pasting when the session frees up; returns queue depth.

    Returns 0 when the queue is at _PENDING_MAX_DEPTH and the prompt was refused.
    Records why it waits (showing the status-line notice if that is unsent input),
    persists the queue, and starts the per-session drainer if one is not running."""
    queue = _pending_sends.setdefault(name, [])
    if len(queue) >= _PENDING_MAX_DEPTH:
        return 0
    queue.append(ts.QueuedPrompt(text=prompt, enqueued_at=ts._now_iso()))
    await _set_waiting_reason(container, name, queue[0].waiting_reason or reason)
    _spawn_drainer(container, name)
    return len(queue)


async def resume_send_queues() -> None:
    """Pick up every persisted queue after an aidc-mcp start: prompts for a session
    whose container still exists get a drainer; prompts for a session that is gone are
    dead-lettered. Unreadable queue files are logged and left for a person."""
    queues, unreadable = ts.load_send_queues(_WATCHER_STATE_DIR)
    for path in unreadable:
        log_event("session_send_queue_unreadable", path=str(path))
    for name, prompts in queues.items():
        if scope.refusal(name) is not None:
            continue   # another server's session: leave its queue file alone
        container = f"aidc-{name}-dev"
        if await _container_state(container) == CONTAINER_GONE:
            for q in prompts:
                _write_send_dead_letter(name, q, "session_killed")
            ts.save_send_queue(_WATCHER_STATE_DIR, name, [])
            log_event("session_send_queue_abandoned", session=name, dropped=len(prompts),
                      reason="session_killed")
            continue
        _pending_sends[name] = prompts
        if prompts[0].waiting_reason == "input_has_text":
            # The tmux option outlives the MCP; remember it is showing, so the drainer
            # clears it when the prompt goes in.
            _waiting_notice_shown.add(name)
        _spawn_drainer(container, name)
        log_event("session_send_queue_resumed", session=name, depth=len(prompts))


_WAITING_EXPLAINED = {
    "claude_busy": "Claude is working on a turn",
    "input_has_text": "someone has unsent text in Claude's input box in the session "
                      "(the session's status line tells them)",
    "claude_not_running": "Claude is not running in the session",
    "claude_not_at_prompt": "Claude is showing a dialog (e.g. login) instead of its prompt",
    "screen_unrecognized": "aidc does not recognize Claude's screen",
    "paste_failing": "pasting into the session is failing and being retried",
    "queued_behind": "an earlier prompt is still waiting",
}


# ---- transcript-sourced delivery (design-09, MCP-15..19) --------------------
#
# Reads completed assistant turns from the session's surfaced JSONL transcript
# (under the MCP audit volume) instead of scraping the tmux pane, and delivers
# them exactly-once with a durable high-water mark and bounded retry. Added
# alongside the tmux watcher (above); cutover happens once `aidc create`
# surfaces transcripts into _TRANSCRIPTS_BASE (design-09 rollout).

_TRANSCRIPTS_BASE = Path(os.environ.get("AIDC_MCP_TRANSCRIPTS", "/var/log/aidc-mcp/transcripts"))
_WATCHER_STATE_DIR = Path(
    os.environ.get("AIDC_MCP_WATCHER_STATE", "/var/log/aidc-mcp/watcher-state")
)
_DELIVERY_BUDGET_S = 1800.0

# How long a reply whose Stop hooks have not reported yet is held back. A blocking
# hook's pushback is written only when the hook finishes, so a reply delivered
# before then can be the first half of a turn the hook is about to reopen. Claude
# Code writes a stop record after every reply once hooks finish, so this only
# lapses when a hook runs longer than this, or a record goes missing; either way
# the reply is then delivered rather than held forever.
_STOP_HOOK_WAIT_S = 120.0

# Consecutive watcher polls that found an unanswered prompt, a quiet transcript and no
# working text on screen, per (session, conversation_id). Two are required before
# the prompt is reported as interrupted, so one odd screen reading cannot report it.
_unanswered_polls: dict[tuple[str, str], int] = {}

# (session, conversation_id, withdrawn terminal uuid) already logged as dropped, so
# a transcript re-read every poll logs each drop once per process.
_logged_withdrawn_drops: set[tuple[str, str, str]] = set()

# Per-(session, conversation) transcript settle tracking: maps the key to the
# (last-seen file size in bytes, monotonic time that size was first observed).
# A turn is delivered only once the size has held steady for turn_settle_seconds,
# so a burst of end_turn segments under one prompt coalesces into one delivery.
_settle_state: dict[tuple[str, str], tuple[int, float]] = {}

# Per-(session, conversation) consecutive torn-read count (see the resume block in
# _drain_transcript_once). A transient torn/partial read drops the resume anchor
# for a poll or two; a sustained run of misses means the pinned session is dead and
# the watcher rotates off it. Reset on any successful resume; evicted with the rest
# of the per-session state when the watcher ends.
_torn_read_counts: dict[tuple[str, str], int] = {}

# Per-(session, conversation) consecutive "pinned session fully consumed AND a
# strictly-newer session exists" count. Claude never deletes a rotated-away
# transcript, so the session pin never releases on its own; a sustained run of
# this condition means the session genuinely rotated and the watcher must follow
# forward (see _rotate_if_stale_pin). Reset on delivery / when no newer session
# exists; evicted with the rest of the per-session state.
_consumed_idle_counts: dict[tuple[str, str], int] = {}

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


def _drain_lock(key: tuple[str, str]) -> asyncio.Lock:
    """Get-or-create the per-(session, conversation) delivery mutex.

    Created lazily inside the running loop (an asyncio.Lock binds to the loop it
    is first awaited on), so it must not be constructed at import time."""
    lock = _drain_locks.get(key)
    if lock is None:
        lock = asyncio.Lock()
        _drain_locks[key] = lock
    return lock


def _evict_session_state(name: str) -> None:
    """Drop per-session settle-tracking entries when a watcher ends/is unwatched,
    so `_settle_state` (keyed per conversation_id — the real unbounded-growth risk)
    doesn't accumulate as conversations come and go.

    The send lock is deliberately NOT evicted: it's keyed by session *name* (bounded
    by session count, not conversations) and may be held by an in-flight
    `session_send`/`session_run` right now — popping it would let a concurrent send
    create a fresh lock and paste into the same tmux window simultaneously."""
    for key in [k for k in _settle_state if k[0] == name]:
        _settle_state.pop(key, None)
    for drop in [d for d in _logged_withdrawn_drops if d[0] == name]:
        _logged_withdrawn_drops.discard(drop)
    for key in [k for k in _unanswered_polls if k[0] == name]:
        _unanswered_polls.pop(key, None)
    for reported in [r for r in _reported_interrupts if r[0] == name]:
        _reported_interrupts.discard(reported)
    _working_indicator_seen.discard(name)
    _sent_awaiting_echo.pop(name, None)
    _last_free_verdict.pop(name, None)
    _last_screen_raw.pop(name, None)
    for key in [k for k in _torn_read_counts if k[0] == name]:
        _torn_read_counts.pop(key, None)
    for key in [k for k in _consumed_idle_counts if k[0] == name]:
        _consumed_idle_counts.pop(key, None)
    for key in [k for k in _drain_locks if k[0] == name]:
        _drain_locks.pop(key, None)


# Non-2xx statuses worth retrying: transient server-side or rate-limit
# conditions that a later identical POST can plausibly succeed on. Every OTHER
# 4xx is PERMANENT — the request itself is unacceptable to the endpoint, so
# retrying the identical payload can only flood it. 404 in particular means the
# conversation is gone on the orchestrator's side (prod 2026-07-21, conv 019f6cf5: a
# discarded conversation returned 404 to all 34 retries of one turn over the full
# 30-minute budget — the "same message repeated" meltdown).
_RETRYABLE_STATUSES = frozenset({408, 429})


def _is_retryable_status(status: int) -> bool:
    """True for a transient HTTP status (5xx / 408 / 429); False for a permanent
    client error (other 4xx) that retrying the identical POST cannot fix."""
    return status >= 500 or status in _RETRYABLE_STATUSES


class _PermanentDeliveryError(Exception):
    """A callback failed with a permanent (non-retryable) HTTP status. Signals
    _deliver_with_retry to stop immediately and dead-letter instead of retrying
    the identical payload for the whole budget. Carries the status for logging."""

    def __init__(self, status: int) -> None:
        super().__init__(f"permanent delivery failure: HTTP {status}")
        self.status = status


async def _post_turn(
    callback_base: str, conversation_id: str, turn: ts.Turn, *, attempt: int, session: str
) -> bool:
    """One POST attempt for a turn. Returns True on 2xx, False on a TRANSIENT
    failure (retryable), and raises _PermanentDeliveryError on a permanent 4xx
    (non-retryable). Fully instrumented (MCP-19): logs attempt, ok/non-2xx/
    exception with status, timing, type+repr."""
    full_url = f"{callback_base}/api/v1/internal/callback/{conversation_id}"
    log_event("transcript_callback_attempt", conversation_id=conversation_id, url=full_url,
              turn_uuid=turn.terminal_uuid, content_len=len(turn.text), attempt=attempt)
    start = time.monotonic()
    try:
        bearer = _load_token()
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(
                full_url,
                # ``session`` names WHICH aidc session finished this turn. The
                # orchestrator gates ``session_send`` on a per-session BUSY marker
                # (set when its own send is accepted) and needs this to know which
                # session just became READY -- without it a multi-session
                # conversation cannot tell whose reply arrived.
                # ``prompt_origin`` says whose prompt this turn answers: "terminal"
                # (a person typed it at the session's pane — the content then opens
                # with that prompt), "orchestrator" (a prompt this MCP injected),
                # or "" (unknown: a continuation, or a prompt Claude Code
                # synthesized). Informational; the content already reads right.
                # ``interrupted`` is true when the person pressed Esc and cut the turn
                # off. It is not a failure, so ``ok`` stays true; the content opens
                # with a note saying so, which is all a receiver that ignores the
                # field needs. The whole body is pinned in design-10 D5 and agreed
                # with the orchestrator's side before any field changes.
                json={"content": turn.text, "ok": turn.ok, "source": "agent_watch",
                      "session": session, "prompt_origin": turn.prompt_origin,
                      "interrupted": turn.interrupted},
                headers={"Authorization": f"Bearer {bearer}"},
            )
        elapsed_s = round(time.monotonic() - start, 3)
        if resp.is_success:
            log_event("transcript_callback_ok", conversation_id=conversation_id,
                      turn_uuid=turn.terminal_uuid, status=resp.status_code,
                      elapsed_s=elapsed_s, attempt=attempt)
            return True
        retryable = _is_retryable_status(resp.status_code)
        log_event("transcript_callback_http_error", conversation_id=conversation_id,
                  turn_uuid=turn.terminal_uuid, status=resp.status_code, elapsed_s=elapsed_s,
                  body=resp.text[:500], attempt=attempt, retryable=retryable)
        if not retryable:
            # Permanent (e.g. 404 conversation-gone): retrying the identical POST
            # can never succeed and only floods the endpoint. Stop now.
            raise _PermanentDeliveryError(resp.status_code)
        return False
    except _PermanentDeliveryError:
        raise
    except Exception as exc:  # prawduct:allow prawduct/broad-except -- log why + retry
        log_event("transcript_callback_failed", conversation_id=conversation_id,
                  turn_uuid=turn.terminal_uuid, elapsed_s=round(time.monotonic() - start, 3),
                  error_type=type(exc).__name__, error=repr(exc), attempt=attempt)
        return False


async def _deliver_with_retry(turn: ts.Turn, *, post_fn, sleep_fn=asyncio.sleep,
                              budget: float = _DELIVERY_BUDGET_S) -> bool:
    """Retry a turn on bounded backoff until confirmed (True), the budget is
    exhausted, or a PERMANENT failure is hit (False -> caller dead-letters).
    MCP-18: never silently drops. A permanent HTTP status (e.g. 404
    conversation-gone) stops retries immediately — hammering the identical POST
    for the whole budget only floods a dead endpoint."""
    elapsed = 0.0
    attempt = 0
    while True:
        delay = ts.delay_for_attempt(attempt)
        if delay:
            await sleep_fn(delay)
            elapsed += delay
        try:
            if await post_fn(turn, attempt):
                return True
        except _PermanentDeliveryError:
            return False  # non-retryable — dead-letter now, don't flood
        attempt += 1
        if elapsed + ts.delay_for_attempt(attempt) > budget:
            return False


def _write_dead_letter(state_dir: Path, session: str, conversation_id: str, turn: ts.Turn) -> None:
    """Persist an undelivered turn so it is recorded, not silently lost (MCP-18)."""
    dl = Path(state_dir) / "dead-letter"
    dl.mkdir(parents=True, exist_ok=True)
    name = f"{ts._slug(session)}__{ts._slug(conversation_id)}__{ts._slug(turn.terminal_uuid)}.json"
    (dl / name).write_text(
        json.dumps({"session": session, "conversation_id": conversation_id,
                    "turn_uuid": turn.terminal_uuid, "content": turn.text, "ok": turn.ok,
                    "interrupted": turn.interrupted}),
        encoding="utf-8",
    )


async def _baseline_watermark(session: str, conversation_id: str, *,
                              transcripts_base: Path = _TRANSCRIPTS_BASE,
                              state_dir: Path = _WATCHER_STATE_DIR) -> None:
    """Forward-only anchor on EVERY watcher (re)start (MCP-17, forward-only-on-connect).

    Re-anchor ``last_delivered_uuid`` to the current LAST completed turn of the
    active transcript, so a (re)connecting orchestrator conversation is NEVER caught up with
    a backlog — only turns that complete AFTER the (re)connect are delivered.

    Previously this no-op'd when a mark already existed ("resume"), which meant a
    reconnect / MCP-restart / a mark left stale from a prior life replayed the whole
    gap from the old position to now — the connect-catch-up runaway (prod
    2026-07-09, conv 019f4220).

    Runs at watcher (RE)START, not on every send: ``session_send`` calls
    ``_start_watcher`` only when no live watcher is registered (a first send after
    an MCP restart, where the in-memory registry is empty), and ``session_watch``
    calls it explicitly. A send with a watcher already live does NOT re-register, so
    it does not re-anchor. On a (re)start the anchor is set BEFORE the prompt is
    injected, so the response — a strictly-later turn — is still delivered; only
    pre-existing history is skipped. Forward-only.

    The loop-guard run (``consecutive_deliveries`` / ``last_delivery_at``) is
    PRESERVED across the re-anchor (loaded from the existing mark), so the
    ongoing-runaway backstop keeps accumulating — only an idle gap resets it, never
    a re-anchor.

    Called synchronously at watch registration so the anchor is set before any
    prompt is injected; _drain_transcript_once also self-baselines defensively."""
    # Preserve the durable loop-guard run across the re-anchor — load the existing
    # mark rather than minting a fresh (zeroed) one.
    mark = (
        ts.load_watermark(state_dir, session, conversation_id)
        if ts.watermark_exists(state_dir, session, conversation_id)
        else ts.Watermark(session=session, conversation_id=conversation_id)
    )
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
                log_event("transcript_baseline_torn_read_skipped", session=session,
                          conversation_id=conversation_id, session_id=active.stem,
                          last_delivered_uuid=mark.last_delivered_uuid)
                ts.save_watermark(state_dir, mark)
                return
        turns = ts.extract_completed_turns(objs)
        mark.session_id = active.stem
        mark.byte_offset = len(data.encode("utf-8"))
        mark.last_delivered_uuid = turns[-1].terminal_uuid if turns else ""
    ts.save_watermark(state_dir, mark)
    log_event("transcript_baseline", session=session, conversation_id=conversation_id,
              session_id=mark.session_id, last_delivered_uuid=mark.last_delivered_uuid,
              consecutive_deliveries=mark.consecutive_deliveries)


# Loop guard for the delivery watcher. An aidc session has no human at the pane:
# every turn is driven by the orchestrator's session_send, so a runaway where the
# orchestrator and this session answer each other forever (prod incident
# 2026-07-03, orchestrator conv 019f1fde) has no natural terminator. TIMING is NOT the
# signal: the earlier rate-based guard reset its run on any >45 s gap, but the
# runaway's turns grew slow as context ballooned (observed gaps up to ~250 s), so
# it never tripped while it flooded the orchestrator. The signal is an unbroken RUN
# of deliveries. Count consecutive deliveries and trip past
# _LOOP_GUARD_MAX_CONSECUTIVE. Only a genuinely IDLE gap — the orchestrator stopped
# driving, far longer than any single turn (_LOOP_GUARD_IDLE_RESET_S) — resets the
# run, so a session that goes quiet and later resumes is not latched, while a slow
# runaway cannot use its slow turns to dodge. The run + last-delivery time are
# persisted in the durable watermark, so an MCP restart cannot silently resume the
# loop. This is the coarse backstop; the orchestrator's own guard (which resets on
# a human turn) is the precise layer, so this cap sits ABOVE it. On trip a turn is
# DROPPED (dead-lettered + watermark advanced, no POST) so the orchestrator stops
# receiving callbacks and the session idles out — self-healing once a long idle
# resets the run.
_LOOP_GUARD_MAX_CONSECUTIVE = 20
_LOOP_GUARD_IDLE_RESET_S = 900.0

# Consecutive torn-read polls before the watcher concludes the pinned session is
# dead (not a transient partial read) and rotates onto the newest transcript. At
# the 2 s poll interval this is ~30 s — far beyond any transient torn read, but
# bounded so a wedged watcher self-heals instead of stalling forever (prod
# 019f1fde: the faidh watcher was stuck for 40+ min).
_TORN_READ_RECOVER_POLLS = 15

# Consecutive "pinned session fully consumed AND a strictly-newer session exists"
# polls before the watcher concludes the session genuinely rotated (Claude never
# deletes the old transcript, so the pin never releases on its own) and follows
# forward onto the new session. Content-timestamp based (flap-proof), so short.
_STALE_PIN_RECOVER_POLLS = 5


def _rotate_if_stale_pin(session: str, conversation_id: str,
                         key: tuple[str, str], sid: str, pinned_objs: list,
                         transcripts_base: Path, state_dir: Path) -> bool:
    """Follow a session rotation the pin can't see on its own.

    The session pin selects the pinned transcript as long as it EXISTS, and
    Claude never deletes a rotated-away transcript — so once the user's Claude
    starts a new session (a new sessionId file), the watcher stays welded to the
    old, fully-consumed file and delivers nothing forever (prod 019f1fde: pinned
    to 1b968f61 while faidh moved on). This runs only when the pinned session is
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
    best_stem, best_ts, best_data = sid, ts.newest_message_ts(pinned_objs), None
    try:
        candidates = [p for p in d.glob("*.jsonl") if p.is_file() and not p.is_symlink()]
    except OSError:
        candidates = []
    for p in candidates:
        if p.stem == sid:
            continue
        try:
            data = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        cand_ts = ts.newest_message_ts(ts.parse_jsonl(data))
        if cand_ts and cand_ts > best_ts:
            best_stem, best_ts, best_data = p.stem, cand_ts, data

    if best_stem == sid or best_data is None:
        _consumed_idle_counts.pop(key, None)   # no newer session — keep waiting
        return False

    n = _consumed_idle_counts.get(key, 0) + 1
    _consumed_idle_counts[key] = n
    if n < _STALE_PIN_RECOVER_POLLS:
        return False

    all_turns = ts.extract_completed_turns(ts.parse_jsonl(best_data))
    mark = ts.load_watermark(state_dir, session, conversation_id)
    mark.session_id = best_stem
    mark.byte_offset = len(best_data.encode("utf-8"))
    mark.last_delivered_uuid = all_turns[-1].terminal_uuid if all_turns else ""
    mark.consecutive_deliveries = 0
    mark.last_delivery_at = 0.0
    ts.save_watermark(state_dir, mark)
    _settle_state.pop(key, None)
    _consumed_idle_counts.pop(key, None)
    log_event("transcript_stale_pin_recovered", session=session,
              conversation_id=conversation_id, dead_session_id=sid,
              new_session_id=best_stem, reason="fully_consumed_idle")
    return True


async def _interrupted_before_output(session: str, conversation_id: str, suffix: list[dict],
                                     active: Path, screen_fn, wall_now: float) -> ts.Turn | None:
    """The prompt at the transcript's tail, as an interrupted turn, when Claude was
    stopped before writing anything; otherwise None.

    Claude Code writes no marker for an Esc pressed that early, so the transcript alone
    shows only a prompt with no reply. It is reported when the shared turn rule
    (_turn_verdict) says Claude is not working on two consecutive polls, with Claude
    running at its input box. `screen_fn(session)` returns the session's ScreenState,
    or None when Claude is not running.
    """
    key = (session, conversation_id)
    turn = ts.unanswered_prompt_turn(suffix)
    if turn is None:
        _unanswered_polls.pop(key, None)
        return None
    try:
        quiet = wall_now - active.stat().st_mtime
    except OSError:
        return None
    if quiet < _LOG_QUIET_S:
        _unanswered_polls.pop(key, None)
        return None
    state = await screen_fn(session)
    if state is None or state.input_box not in (scr.EMPTY, scr.HAS_TEXT):
        _unanswered_polls.pop(key, None)
        return None
    verdict, why = _turn_verdict(session, suffix, quiet, state)
    if verdict == TURN_RUNNING:
        if why != "status_row_unproven":
            _unanswered_polls.pop(key, None)
        return None
    polls = _unanswered_polls.get(key, 0) + 1
    if polls < 2:
        _unanswered_polls[key] = polls
        return None
    _unanswered_polls.pop(key, None)
    _reported_interrupts.add((session, turn.terminal_uuid))
    log_event("transcript_interrupted_before_output", session=session,
              conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
              quiet_s=round(quiet, 1), why=why)
    return turn


async def _screen_for_watcher(session: str) -> scr.ScreenState | None:
    container = f"aidc-{session}-dev"
    if not await _is_claude_running(container):
        return None
    return await _read_screen(container, session)


async def _drain_transcript_once(session: str, conversation_id: str, callback_base: str, *,
                                 transcripts_base: Path = _TRANSCRIPTS_BASE,
                                 state_dir: Path = _WATCHER_STATE_DIR,
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
    async with _drain_lock((session, conversation_id)):
        await _drain_once_body(
            session, conversation_id, callback_base,
            transcripts_base=transcripts_base, state_dir=state_dir,
            post_fn=post_fn, sleep_fn=sleep_fn, settle_seconds=settle_seconds,
            now_fn=now_fn, wall_now_fn=wall_now_fn, screen_fn=screen_fn,
        )


async def _drain_once_body(session: str, conversation_id: str, callback_base: str, *,
                           transcripts_base: Path = _TRANSCRIPTS_BASE,
                           state_dir: Path = _WATCHER_STATE_DIR,
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
        data = active.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    objs = ts.parse_jsonl(data)
    end_offset = len(data.encode("utf-8"))
    key = (session, conversation_id)

    if mark.session_id != sid and mark.session_id:
        # GENUINE rotation: the file we were pinned to is gone, so resolution fell
        # back to a different active file. Baseline FORWARD onto it (anchor at its
        # end, deliver nothing from its history) — never reset last_delivered_uuid
        # to "" and replay the whole file, which was the replay bug.
        all_turns = ts.extract_completed_turns(objs)
        mark.session_id = sid
        mark.byte_offset = end_offset
        mark.last_delivered_uuid = all_turns[-1].terminal_uuid if all_turns else ""
        ts.save_watermark(state_dir, mark)
        _settle_state.pop(key, None)
        log_event("transcript_rotated", session=session, conversation_id=conversation_id,
                  session_id=sid, forward_baselined=True)
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
        log_event("transcript_first_pin", session=session, conversation_id=conversation_id,
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
        # wedging forever (prod 019f1fde: the faidh watcher stuck in
        # torn_read_skip for 40+ min after the runaway session was killed
        # mid-write and the container was rebuilt onto a fresh session).
        torn = _torn_read_counts.get(key, 0) + 1
        _torn_read_counts[key] = torn
        if torn >= _TORN_READ_RECOVER_POLLS:
            newest = ts.resolve_active_transcript(Path(transcripts_base) / session)
            if newest is not None and newest.stem != sid:
                try:
                    newest_data = newest.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    return
                all_turns = ts.extract_completed_turns(ts.parse_jsonl(newest_data))
                mark.session_id = newest.stem
                mark.byte_offset = len(newest_data.encode("utf-8"))
                mark.last_delivered_uuid = (
                    all_turns[-1].terminal_uuid if all_turns else ""
                )
                mark.consecutive_deliveries = 0
                mark.last_delivery_at = 0.0
                ts.save_watermark(state_dir, mark)
                _settle_state.pop(key, None)
                _torn_read_counts.pop(key, None)
                log_event("transcript_stale_pin_recovered", session=session,
                          conversation_id=conversation_id, dead_session_id=sid,
                          new_session_id=newest.stem, torn_read_polls=torn)
                return
        log_event("transcript_torn_read_skip", session=session,
                  conversation_id=conversation_id,
                  last_delivered_uuid=mark.last_delivered_uuid, torn_read_count=torn)
        return
    _torn_read_counts.pop(key, None)  # anchor resolved — reset the torn-read run

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
    # _STOP_HOOK_WAIT_S): a slow blocking hook would otherwise reopen a turn that
    # was already delivered as finished.
    if settle_seconds > 0 and ts.ends_on_turn_end(suffix):
        _settle_state.pop(key, None)
    elif settle_seconds > 0:
        quiet_needed = (max(settle_seconds, _STOP_HOOK_WAIT_S)
                        if ts.awaiting_stop_hooks(suffix, objs) else settle_seconds)
        now = now_fn()
        last = _settle_state.get(key)
        if last is None or last[0] != end_offset:
            _settle_state[key] = (end_offset, now)
            return  # grew (or first observation this cycle) — wait for quiet
        if now - last[1] < quiet_needed:
            return  # not quiet long enough yet

    dropped: list[str] = []
    new = ts.extract_completed_turns(suffix, dropped)
    if screen_fn is not None:
        if session not in _working_indicator_seen and ts.log_shows_turn_in_progress(suffix):
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
        if drop_key not in _logged_withdrawn_drops:
            _logged_withdrawn_drops.add(drop_key)
            log_event("transcript_withdrawn_reply_dropped", session=session,
                      conversation_id=conversation_id, turn_uuid=uid)
    if not new:
        # No deliverable turns remain in the pinned session (its tail may hold
        # trailing non-turn objects — a bare user/system line that never became a
        # turn — so `suffix` can be non-empty while `new` is empty). The user's
        # Claude may have rotated to a new session whose old transcript still
        # lingers on disk, which the pin can't see on its own. Follow the rotation
        # forward. Content-timestamp gated, so an active pinned session that is
        # merely mid-turn is never abandoned — no sibling can out-timestamp it.
        _rotate_if_stale_pin(session, conversation_id, key, sid, objs,
                             transcripts_base, state_dir)
        return
    _consumed_idle_counts.pop(key, None)   # delivering — not a stale pin
    if post_fn is None:
        async def post_fn(turn, attempt):  # noqa: E306
            return await _post_turn(callback_base, conversation_id, turn,
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
        terminal_prompts = (
            [] if already_delivered else _terminal_prompts(session, turn.prompts, state_dir)
        )
        outgoing = dataclasses.replace(
            turn,
            text=ts.render_delivery(turn.text, terminal_prompts, interrupted=turn.interrupted),
            prompt_origin=("terminal" if terminal_prompts
                           else "orchestrator" if turn.prompts else ""),
        )
        if terminal_prompts:
            # record_remaining is the health signal: entries that keep piling up
            # while replies arrive mean matching has drifted (every reply would then
            # carry the note), which a real typed prompt never causes.
            log_event("transcript_terminal_prompt", session=session,
                      conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
                      prompts=len(terminal_prompts),
                      prompt_len=sum(len(p) for p in terminal_prompts),
                      record_remaining=ts.sent_prompts_remaining(state_dir, session))
        if turn.superseded and not already_delivered:
            # A reply followed by more assistant work with no Stop-hook pushback or
            # prompt between them. A block that leaves no trace looks like this,
            # and its first half may have been delivered as the finished reply.
            log_event("transcript_terminal_superseded", session=session,
                      conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
                      superseded=turn.superseded)
        if turn.late_pushback and not already_delivered:
            # The reply before this pushback already went out as finished: its Stop
            # hook ran longer than the watcher held it. This delivery is the rest.
            log_event("transcript_late_pushback", session=session,
                      conversation_id=conversation_id, turn_uuid=turn.terminal_uuid)
        if not deliverable:
            log_event("transcript_empty_turn", session=session,
                      conversation_id=conversation_id, turn_uuid=turn.terminal_uuid)
        else:
            if already_delivered:
                # Already delivered this exact content to this conversation. A
                # watermark bug re-surfaced it; drop it at the door. This is NOT a
                # loop-guard event (it is a re-read, not a fresh echo) and is never
                # re-POSTed — only the watermark advances past it below.
                log_event("transcript_delivery_deduped", session=session,
                          conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
                          fingerprint=fingerprint)
            else:
                # Loop guard: cap the run of CONSECUTIVE deliveries. There is no
                # human at the pane to end the exchange, so an orchestrator<->
                # session runaway would otherwise deliver forever. Timing is not the
                # signal — the runaway can be slow (context-bloated turns), which is
                # what defeated the old rate-based reset. Only a genuinely IDLE gap
                # (_LOOP_GUARD_IDLE_RESET_S — far longer than any single turn) resets
                # the run, so a session that truly goes quiet is not latched while a
                # slow runaway still trips. State is durable so an MCP restart stays
                # latched. On trip: DROP (dead-letter + advance, no POST) so the
                # orchestrator stops receiving and the session idles out.
                wall_now = wall_now_fn()
                if wall_now - mark.last_delivery_at > _LOOP_GUARD_IDLE_RESET_S:
                    mark.consecutive_deliveries = 0
                mark.consecutive_deliveries += 1
                mark.last_delivery_at = wall_now
                if mark.consecutive_deliveries > _LOOP_GUARD_MAX_CONSECUTIVE:
                    _write_dead_letter(state_dir, session, conversation_id, outgoing)
                    log_event("transcript_delivery_loop_guard_tripped", session=session,
                              conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
                              consecutive_deliveries=mark.consecutive_deliveries,
                              cap=_LOOP_GUARD_MAX_CONSECUTIVE)
                elif await _deliver_with_retry(outgoing, post_fn=post_fn, sleep_fn=sleep_fn):
                    # Record ONLY a confirmed delivery, so a dead-lettered or
                    # dropped turn stays eligible for a later resend.
                    delivered_fps.add(fingerprint)
                    ts.record_delivered(state_dir, session, conversation_id, fingerprint)
                else:
                    _write_dead_letter(state_dir, session, conversation_id, outgoing)
                    log_event("transcript_delivery_abandoned", session=session,
                              conversation_id=conversation_id, turn_uuid=turn.terminal_uuid)
        mark.last_delivered_uuid = turn.terminal_uuid
        mark.byte_offset = end_offset
        ts.save_watermark(state_dir, mark)


async def _resend_reply(session: str, conversation_id: str, callback_base: str, *,
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

    The base dirs resolve at CALL time (not as def-time defaults) so patching the
    module globals redirects this path too — the session_resend tool passes neither.
    """
    transcripts_base = _TRANSCRIPTS_BASE if transcripts_base is None else transcripts_base
    state_dir = _WATCHER_STATE_DIR if state_dir is None else state_dir
    mark = (
        ts.load_watermark(state_dir, session, conversation_id)
        if ts.watermark_exists(state_dir, session, conversation_id)
        else None
    )
    prefer = mark.session_id if (mark and mark.session_id) else None
    active = ts.resolve_active_transcript(
        Path(transcripts_base) / session, prefer_session_id=prefer
    )
    if active is None:
        return ("no_reply", None)
    try:
        data = active.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ("no_reply", None)
    # Only non-empty (deliverable) turns can be resent — an empty tool-only turn was
    # never a reply to the orchestrator in the first place.
    deliverable = [t for t in ts.extract_completed_turns(ts.parse_jsonl(data))
                   if t.interrupted or not t.is_empty]
    if not deliverable:
        return ("no_reply", None)
    if turn_uuid:
        target = next((t for t in deliverable if t.terminal_uuid == turn_uuid), None)
    else:
        target = deliverable[-1]
    if target is None:
        return ("no_reply", None)

    # The ledger holds fingerprints CONFIRMED delivered (2xx). A hit means the orchestrator
    # already has this exact content, so re-POSTing can only duplicate it. Refuse
    # by default and let the caller read the content from the tool result instead.
    fingerprint = ts.delivery_fingerprint(target)
    if not force and fingerprint in ts.load_delivered(state_dir, session, conversation_id):
        log_event("transcript_resend_suppressed", session=session,
                  conversation_id=conversation_id, turn_uuid=target.terminal_uuid,
                  content_len=len(target.text), fingerprint=fingerprint)
        return ("already_delivered", target)

    if post_fn is None:
        async def post_fn(turn, attempt):  # noqa: E306
            return await _post_turn(callback_base, conversation_id, turn,
                                    attempt=attempt, session=session)
    # The bare reply, as the resend contract says -- except that an interrupt keeps
    # its note: without it an interrupt with nothing written would post as empty.
    outgoing = dataclasses.replace(
        target, text=ts.render_delivery(target.text, [], interrupted=target.interrupted))
    ok = await _deliver_with_retry(outgoing, post_fn=post_fn, sleep_fn=sleep_fn)
    if ok:
        # Record the resent turn in the delivery ledger so the watcher never ALSO
        # delivers it (a double-send). Once it lands, the exactly-once invariant
        # must hold for every other delivery path too.
        ts.record_delivered(state_dir, session, conversation_id, fingerprint)
    log_event("transcript_resend", session=session, conversation_id=conversation_id,
              turn_uuid=target.terminal_uuid, content_len=len(target.text), ok=ok,
              forced=force)
    return ("resent" if ok else "failed", target)


async def _run_transcript_watcher(session: str, conversation_id: str, callback_base: str, *,
                                  poll_interval: float = 2.0,
                                  settle_seconds: float | None = None) -> None:
    """Polling loop around _drain_transcript_once. The live delivery path behind
    session_send / session_run / session_watch. The settle window (how long the
    transcript must be quiet before a turn is delivered) is read from config once
    per watcher; pass settle_seconds to override (tests)."""
    if settle_seconds is None:
        settle_seconds = _metallm_turn_settle_seconds()
    while True:
        await asyncio.sleep(poll_interval)
        try:
            await _drain_transcript_once(session, conversation_id, callback_base,
                                         settle_seconds=settle_seconds,
                                         screen_fn=_screen_for_watcher)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- watcher must survive
            log_event("transcript_watcher_error", session=session,
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
        if _session_watchers.get(name) is task:
            _session_watchers.pop(name, None)
            _evict_session_state(name)
    return _cb


async def _start_watcher(app: Any, name: str, conversation_id: str, base_url: str) -> None:
    """Baseline forward-only, spawn the transcript watcher, register it, and
    announce the change. Shared by session_send / session_watch.

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
    existing = _session_watchers.get(name)
    if existing is not None:
        existing.cancel()
    task = asyncio.create_task(_run_transcript_watcher(name, conversation_id, base_url))
    _session_watchers[name] = task
    task.add_done_callback(_make_watcher_done_callback(name))
    # Baseline forward-only AFTER registering. The watcher sleeps one poll interval
    # before its first drain and _drain_transcript_once self-baselines defensively,
    # and this await completes before the caller injects any prompt, so the anchor
    # is still established before the first delivery.
    await _baseline_watermark(name, conversation_id)
    await _announce_watchers(app)


# ---- low-level CLI runner ---------------------------------------------------

def _run_cli(args: list[str], timeout: float = 60.0) -> dict[str, Any]:
    """Run `aidc <args>` synchronously, capture stdout/stderr/exit."""
    cmd = [AIDC, *args]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {
            "exit": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        }
    except subprocess.TimeoutExpired as exc:
        return {"exit": -1, "stdout": exc.stdout or "", "stderr": f"timeout after {timeout}s"}
    except FileNotFoundError:
        return {"exit": -1, "stdout": "", "stderr": f"aidc CLI not found at {AIDC}"}


async def _run_cli_streaming(
    args: list[str], ctx: Context, phase_keywords: dict[str, str]
) -> dict[str, Any]:
    """Run aidc CLI with live progress notifications.

    `phase_keywords` maps substrings-in-output to MCP progress phase names.
    Whenever a stdout/stderr line contains a key, we emit a progress
    notification with the corresponding name.
    """
    cmd = [AIDC, *args]
    log_event("cli_exec_streaming", argv=cmd)
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,  # merge streams to keep order
    )
    out_chunks: list[str] = []
    assert proc.stdout is not None
    async for raw in proc.stdout:
        line = raw.decode("utf-8", errors="replace").rstrip("\n")
        out_chunks.append(line)
        for needle, phase in phase_keywords.items():
            if needle in line:
                try:
                    await ctx.info(f"{phase}: {line}")
                except Exception:  # prawduct:allow prawduct/broad-except -- progress is cosmetic
                    pass
                break
    rc = await proc.wait()
    return {"exit": rc, "stdout": "\n".join(out_chunks), "stderr": ""}


def _envelope_ok(data: Any = None) -> dict[str, Any]:
    out: dict[str, Any] = {"ok": True}
    if data is not None:
        out["data"] = data
    return out


# Machine-readable failure kinds, so a caller can decide "tell the person, no retry"
# from "try once more" without matching the prose in `error`. Every failure envelope
# carries one; adding a code is a contract change agreed with the orchestrator side.
ERROR_CODES = frozenset({
    "no_such_session",     # the session's container does not exist
    "queue_full",          # too many prompts already waiting; the session is wedged
    "out_of_scope",        # a scoped server refusing another session
    "create_not_allowed",  # session_create on a scoped server
    "invalid_argument",    # a required argument is missing or invalid
    "not_configured",      # the aidc config lacks what the call needs (callback_url)
    "cli_failed",          # an aidc CLI call exited non-zero
    "command_failed",      # a command inside the session failed (file_get, claude, ...)
    "timeout",             # a command inside the session ran out of time
    "claude_not_running",  # a synchronous path that needs Claude running
    "session_not_ready",   # session_run: the session did not become free in time
    "paste_failed",        # a paste into the session did not land
    "turn_not_finished",   # session_run: a turn did not finish in time
    "no_reply",            # session_resend: nothing completed to resend
    "callback_failed",     # session_resend: the POST to the orchestrator failed
    "not_found",           # a file or directory the call reads is missing
})


def _envelope_err(error: str, data: Any = None, *, code: str) -> dict[str, Any]:
    out: dict[str, Any] = {"ok": False, "error": error, "error_code": code}
    if data is not None:
        out["data"] = data
    return out


# ---- tool registration ------------------------------------------------------

def _scoped(fn: Any) -> Any:
    """Refuse a call whose `name` is outside this server's session scope (scope.py),
    before the tool does anything. Keeps the wrapped signature and docstring, which
    FastMCP reads for the tool schema."""
    def refused(name: str) -> dict[str, Any] | None:
        why = scope.refusal(name)
        if why is None:
            return None
        log_event("tool_call", tool=fn.__name__, session=name, refused="out_of_scope")
        return _envelope_err(why, code="out_of_scope")

    if inspect.iscoroutinefunction(fn):
        @functools.wraps(fn)
        async def async_wrapper(*args: Any, **kwargs: Any) -> Any:
            err = refused(kwargs.get("name", args[0] if args else ""))
            return err if err is not None else await fn(*args, **kwargs)
        return async_wrapper

    @functools.wraps(fn)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        err = refused(kwargs.get("name", args[0] if args else ""))
        return err if err is not None else fn(*args, **kwargs)
    return wrapper


def register(app: Any) -> None:
    """Attach every tool to the given FastMCP app."""

    # --- session_create -------------------------------------------------

    @app.tool()
    async def session_create(
        name: str,
        profile: str = "multi",
        repo: str = "",
        workspace: str | None = None,
        ctx: Context | None = None,
    ) -> dict[str, Any]:
        """Create and start an aidc session. ~30s. Streams progress.

        Sessions persist until killed. Name after the work ("fix-auth-flow").
        Resume later with session_invoke on the same name.

        Args:
            name: session name (must match `^[a-z0-9][a-z0-9-]{0,30}$`)
            profile: python|node|go|rust|multi (default: multi)
            repo: absolute host path to mount (required)
            workspace: optional parent dir for sibling-repo access
        """
        if (why := scope.create_refusal()) is not None:
            log_event("tool_call", tool="session_create", session=name, refused="out_of_scope")
            return _envelope_err(why, code="create_not_allowed")
        if not repo:
            return _envelope_err("repo argument is required (absolute host path)",
                                 code="invalid_argument")
        args = ["create", name, "--profile", profile, "--repo", repo]
        if workspace:
            args += ["--workspace", workspace]
        log_event("tool_call", tool="session_create", session=name, profile=profile, repo=repo)
        phases = {
            "Container aidc-": "container",
            "Waiting":         "waiting",
            "Healthy":         "healthy",
            "Started":         "started",
            "waiting for":     "wait",
        }
        if ctx is not None:
            result = await _run_cli_streaming(args, ctx, phases)
        else:
            result = _run_cli(args, timeout=300.0)
        if result["exit"] == 0:
            return _envelope_ok({"name": name, "log": result["stdout"]})
        return _envelope_err(result["stderr"] or result["stdout"] or "create failed", result,
                             code="cli_failed")

    # --- session_list ---------------------------------------------------

    @app.tool()
    def session_list() -> dict[str, Any]:
        """Return a list of running aidc sessions with status + taint."""
        log_event("tool_call", tool="session_list")
        result = _run_cli(["list"])
        if result["exit"] != 0:
            return _envelope_err(result["stderr"] or "list failed", result, code="cli_failed")
        return _envelope_ok({"raw": scope.filter_list(result["stdout"])})

    # --- session_status -------------------------------------------------

    @app.tool()
    @_scoped
    def session_status(name: str) -> dict[str, Any]:
        """Status for one session: health, taint, audit dir.

        Call before resuming a paused or idle session. Confirms alive and untainted.
        `send_queue` lists prompts sent with session_send that are still waiting to be
        pasted, and why each one waits.
        """
        log_event("tool_call", tool="session_status", session=name)
        result = _run_cli(["status", name])
        if result["exit"] != 0:
            return _envelope_err(result["stderr"] or "status failed", result, code="cli_failed")
        # Prompts sent to the session and not pasted yet, each with why it waits.
        queue = [{"prompt_preview": q.text[:120], "enqueued_at": q.enqueued_at,
                  "waiting_reason": q.waiting_reason,
                  "waiting_because": _WAITING_EXPLAINED.get(q.waiting_reason, ""),
                  "paste_attempts": q.paste_attempts}
                 for q in _pending_sends.get(name, [])]
        return _envelope_ok({"raw": result["stdout"], "send_queue": queue})

    # --- session_kill (intentionally NOT advertised as an MCP tool) -----
    #
    # The kill capability is KEPT — the ``aidc kill`` CLI is untouched and this
    # thin wrapper stays — but it is deliberately NOT registered via
    # ``@app.tool()``, so MCP clients can neither discover nor call it. A weak
    # orchestrator's client agent called ``session_kill`` and tore down a live
    # session (prod audit 2026-07-04 17:53). Tearing a session down is an
    # operator action via the CLI, not something an MCP client should drive.
    # Re-advertise by restoring the ``@app.tool()`` decorator below.
    @_scoped
    def session_kill(name: str) -> dict[str, Any]:
        """Tear down the session. Audit dir is preserved on host.

        NOT an MCP tool (see comment above) — invoked only by keeping the
        ``aidc kill`` CLI; this wrapper is retained for easy re-advertisement.
        """
        log_event("tool_call", tool="session_kill", session=name)
        result = _run_cli(["kill", name], timeout=120.0)
        if result["exit"] != 0:
            return _envelope_err(result["stderr"] or "kill failed", result, code="cli_failed")
        return _envelope_ok({"name": name})

    # --- session_exec ---------------------------------------------------

    @app.tool()
    @_scoped
    def session_exec(name: str, cmd: str, timeout_seconds: int = 60) -> dict[str, Any]:
        """Run a shell command in the session container YOURSELF. Returns stdout, stderr, exit code.

        For when you need to run git / npm / builds / file ops directly. To instead ASK
        the session's Claude agent a question or have it do the work — it has the project's
        context loaded — use session_send, don't reverse-engineer the repo by hand here.
        """
        log_event("tool_call", tool="session_exec", session=name, cmd_redacted=cmd[:50])
        container = f"aidc-{name}-dev"
        argv = ["docker", "exec", "-u", "vscode", container, "bash", "-lc", cmd]
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout_seconds)
        except subprocess.TimeoutExpired as exc:
            return _envelope_err(f"timeout after {timeout_seconds}s", {"stdout": exc.stdout or ""},
                                 code="timeout")
        return _envelope_ok({"stdout": proc.stdout, "stderr": proc.stderr, "exit": proc.returncode})

    # --- session_invoke --------------------------------------------------

    @app.tool()
    @_scoped
    async def session_invoke(
        name: Annotated[str, Field(description=_NAME_DESC)],
        prompt: Annotated[str, Field(description=_PROMPT_DESC)],
        ctx: Context | None = None,
    ) -> dict[str, Any]:
        """Run ONE prompt in a session and BLOCK until the answer comes back (headless, fast).

        WHEN TO USE: a quick one-off (under ~1 min) whose answer you need inline before
        you can continue — e.g. a single test or check that should hold up the
        conversation until it's done.
        WHEN NOT: you want to ASK the session's resident agent (the one with the project's
        context loaded) a question or task -> use session_send; this runs a FRESH Claude
        that knows nothing about the session's prior work. A long fire-and-forget job ->
        use session_invoke_async. Each call is a fresh headless run with no memory of
        prior turns. Returns the answer text; relay it verbatim, do not summarize.

        Args:
            name: the aidc session to run in (see session_list for running sessions).
            prompt: the single prompt to run.
        """
        log_event("tool_call", tool="session_invoke", session=name, prompt_len=len(prompt))
        container = f"aidc-{name}-dev"
        # `aidc-claude` is the in-container wrapper that respects AIDC_CLAUDE_MODE.
        argv = ["docker", "exec", "-u", "vscode", container, "aidc-claude", "--print", prompt]
        proc = await asyncio.create_subprocess_exec(
            *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        assert proc.stdout is not None
        assert proc.stderr is not None
        stdout_reader = proc.stdout
        stderr_reader = proc.stderr
        # Drain stderr concurrently. Reading stdout to EOF and only THEN reading
        # stderr deadlocks if the child fills the stderr pipe buffer before exiting:
        # it blocks writing stderr while we block waiting for more stdout.
        stderr_buf: list[bytes] = []

        async def _drain_stderr() -> None:
            async for raw in stderr_reader:
                stderr_buf.append(raw)

        stderr_task = asyncio.create_task(_drain_stderr())
        chunks: list[str] = []
        try:
            async for raw in stdout_reader:
                chunk = raw.decode("utf-8", errors="replace")
                chunks.append(chunk)
                if ctx is not None:
                    try:
                        await ctx.info(chunk)
                    except Exception:  # prawduct:allow prawduct/broad-except -- cosmetic
                        pass
            await stderr_task
        finally:
            # If the stdout loop errored, don't orphan the stderr drain.
            if not stderr_task.done():
                stderr_task.cancel()
        await proc.wait()
        stderr_data = b"".join(stderr_buf)
        if proc.returncode != 0:
            return _envelope_err(stderr_data.decode("utf-8", errors="replace") or "claude failed",
                                 {"stdout": "".join(chunks)}, code="command_failed")
        return _envelope_ok({"response": "".join(chunks)})

    # --- session_invoke_async --------------------------------------------

    @app.tool()
    @_scoped
    async def session_invoke_async(
        name: Annotated[str, Field(description=_NAME_DESC)],
        prompt: Annotated[str, Field(description=_PROMPT_DESC)],
        conversation_id: Annotated[str, Field(description=_CONV_ID_DESC)],
    ) -> dict[str, Any]:
        """Fire a headless one-shot into a session and return immediately; the result is
        delivered back to THIS conversation when done. No conversation memory — each call
        is independent.

        WHEN TO USE: a self-contained job you want to launch and forget — e.g. a
        scheduled or skill-driven task — where the reply just needs to land back here
        eventually and continuity across turns does not matter.
        WHEN NOT: a back-and-forth with the live session, where context must carry across
        turns -> use session_send (also non-blocking, but keeps the session's context);
        you need the answer inline right now -> use session_invoke.

        Args:
            name: the aidc session to run in.
            prompt: the prompt to run.
            conversation_id: this conversation's id (the orchestrator injects it) — where the
                result is delivered.
        """
        base_url = _metallm_callback_url()
        if not base_url:
            return _envelope_err(
                "metallm.callback_url not set in ~/.config/aidc/config.yaml", code="not_configured"
            )

        callback_url = f"{base_url}/api/v1/internal/callback/{conversation_id}"
        log_event(
            "tool_call",
            tool="session_invoke_async",
            session=name,
            conversation_id=conversation_id,
            prompt_len=len(prompt),
        )

        _ASYNC_TIMEOUT_SECONDS = 1800  # 30 minutes max

        async def _run_and_notify() -> None:
            container = f"aidc-{name}-dev"
            argv = ["docker", "exec", "-u", "vscode", container, "aidc-claude", "--print", prompt]
            try:
                async def _exec() -> tuple[str, bool]:
                    proc = await asyncio.create_subprocess_exec(
                        *argv,
                        stdout=asyncio.subprocess.PIPE,
                        stderr=asyncio.subprocess.PIPE,
                    )
                    # communicate() drains stdout+stderr concurrently, so a child that
                    # fills the stderr pipe buffer before exiting can't deadlock us.
                    stdout_data, stderr_data = await proc.communicate()
                    if proc.returncode != 0:
                        return (
                            stderr_data.decode("utf-8", errors="replace") or "claude failed",
                            False,
                        )
                    return stdout_data.decode("utf-8", errors="replace"), True

                content, ok = await asyncio.wait_for(_exec(), timeout=_ASYNC_TIMEOUT_SECONDS)
            except TimeoutError:
                content = f"session_invoke_async timed out after {_ASYNC_TIMEOUT_SECONDS}s"
                ok = False
            except Exception as exc:  # prawduct:allow prawduct/broad-except -- captured as failure
                content = f"session_invoke_async error: {exc}"
                ok = False

            log_event("tool_call", tool="session_invoke_async_complete", session=name, ok=ok)
            # Same delivery path, same instrumentation rationale as the watcher:
            # log the HTTP outcome (non-2xx included), timing, and the exception
            # type + repr so a failed callback says *why*, not just that it failed.
            content_len = len(content)
            start = time.monotonic()
            try:
                bearer = _load_token()
                async with httpx.AsyncClient(timeout=30) as client:
                    resp = await client.post(
                        callback_url,
                        json={"content": content, "ok": ok},
                        headers={"Authorization": f"Bearer {bearer}"},
                    )
                elapsed_s = round(time.monotonic() - start, 3)
                if resp.is_success:
                    log_event(
                        "tool_call",
                        tool="session_invoke_async_callback_ok",
                        session=name,
                        conversation_id=conversation_id,
                        status=resp.status_code,
                        elapsed_s=elapsed_s,
                        content_len=content_len,
                    )
                else:
                    log_event(
                        "tool_call",
                        tool="session_invoke_async_callback_http_error",
                        session=name,
                        conversation_id=conversation_id,
                        status=resp.status_code,
                        elapsed_s=elapsed_s,
                        content_len=content_len,
                        body=resp.text[:500],
                    )
            except Exception as exc:  # prawduct:allow prawduct/broad-except -- log why, don't crash
                log_event(
                    "tool_call",
                    tool="session_invoke_async_callback_failed",
                    session=name,
                    conversation_id=conversation_id,
                    elapsed_s=round(time.monotonic() - start, 3),
                    content_len=content_len,
                    error_type=type(exc).__name__,
                    error=repr(exc),
                )

        _fire(_run_and_notify())
        return _envelope_ok(
            {"status": "running", "session": name, "conversation_id": conversation_id}
        )

    # --- session_send --------------------------------------------

    @app.tool()
    @_scoped
    async def session_send(
        name: Annotated[str, Field(description=_NAME_DESC)],
        prompt: Annotated[str, Field(description=_PROMPT_DESC)],
        conversation_id: Annotated[str | None, Field(description=_CONV_ID_DESC)] = None,
    ) -> dict[str, Any]:
        """Ask the live Claude agent running in a session a question, or hand it a task —
        and get its reply back. The agent has the project loaded in its context, so to
        learn about or change the code in a session, ASK IT here rather than inspecting
        the repo yourself with session_exec / file_get. Returns immediately; the agent's
        reply is delivered back to THIS conversation when it finishes, so you can keep
        talking to the user while it works.

        WHEN TO USE: the default way to interact with a session — any question or task for
        the agent inside it ("what does X do?", "fix the failing test", an ongoing
        back-and-forth), especially when the turn may take a while.
        WHEN NOT: YOU want to run a shell command or read a file directly (git/npm/build,
        raw inspection) -> use session_exec / file_get; you need a one-off answer inline
        and the session's loaded context does NOT matter -> use session_invoke (headless,
        fresh context that knows nothing about the session's work). For a fixed list of
        prompts known up front, call this tool once per prompt in order.

        The reply arrives via webhook (auto-started here), NOT in this tool's return —
        this call returns only a send-confirmation. Newlines become spaces. One webhook
        per session: if a session is already being watched, the reply is delivered to the
        conversation that first opened the watcher.

        SENDING WHILE THE AGENT IS BUSY IS SAFE. A dev-agent turn can run for many
        minutes; if one is in flight (or someone is typing in the session, or Claude is
        restarting) the prompt is QUEUED and pasted automatically as soon as the session
        is free, and the return says status "queued" with a `waiting_reason`. A queued
        prompt is never lost, survives an aidc-mcp restart, and never needs re-sending —
        its reply comes over the webhook like any other. session_status shows what is
        still waiting and why. Never re-send a prompt to "make sure it arrived", and never reach
        for session_resend because a reply is slow: that delivers an OLDER reply and
        is how a conversation ends up answering the wrong question.

        Args:
            name: the aidc session to talk to (see the open-webhook list below).
            prompt: the message to send.
        """
        log_event("tool_call", tool="session_send", session=name, prompt_len=len(prompt))

        # Auto-register the transcript watcher if one isn't already running.
        # Capture WHY when we can't: both gates fail silently, and a send with no
        # watcher still injects the prompt and reports ok — so the reply is
        # produced and then dropped on the floor with nothing in the audit log
        # saying which gate closed (prod 2026-07-26: `metallm.callback_url` was
        # simply absent from config.yaml; every session_send logged
        # `watching:false` and no further clue, and diagnosis meant reading the
        # source). `no_watch_reason` names the gate so the log answers it.
        no_watch_reason = ""
        if name not in _session_watchers:
            base_url = _metallm_callback_url() if conversation_id else ""
            if not conversation_id:
                no_watch_reason = (
                    "no conversation_id was supplied — the orchestrator injects it automatically, "
                    "so this call did not come from an orchestrated conversation"
                )
            elif not base_url:
                no_watch_reason = (
                    "metallm.callback_url is not set in ~/.config/aidc/config.yaml, "
                    "so replies have nowhere to be POSTed"
                )
            else:
                await _start_watcher(app, name, conversation_id, base_url)
                log_event("tool_call", tool="session_send_auto_watch", session=name,
                          conversation_id=conversation_id)

        if name not in _session_send_locks:
            _session_send_locks[name] = asyncio.Lock()
        lock = _session_send_locks[name]

        container = f"aidc-{name}-dev"

        queued_depth = 0
        sanitized = prompt.replace("\n", " ").strip()
        wait_reason = ""
        async with lock:
            if await _container_state(container) == CONTAINER_GONE:
                # Audit every refusal. These paths used to return silently, so the
                # ONLY trace of a dropped send was the ABSENCE of the
                # session_send_sent line below — which is how prod 2026-08-22 conv
                # 01a01cf6 lost a prompt with nothing in the log naming the gate.
                log_event("tool_call", tool="session_send_failed", session=name,
                          prompt_len=len(prompt), reason="no_such_session")
                return _envelope_err(
                    f"There is no session named '{name}' (its container does not exist). "
                    "Check session_list.", code="no_such_session"
                )

            # Inject only when free so we never paste into a turn already in flight
            # or on top of a person's unsent text. A busy session does not cost the
            # prompt: it goes on the per-session
            # queue and the drainer injects it the moment the turn ends. Anything
            # already queued means this one MUST queue behind it, or a send would
            # overtake an earlier one that is still waiting.
            wait_reason = ("queued_behind" if _pending_sends.get(name)
                           else await _wait_until_free(container, name,
                                                       timeout=_SEND_FREE_WAIT_S))
            if wait_reason:
                queued_depth = await _enqueue_send(name, container, sanitized, wait_reason)
                if queued_depth == 0:
                    log_event("tool_call", tool="session_send_failed", session=name,
                              prompt_len=len(prompt), reason="queue_full",
                              depth=_PENDING_MAX_DEPTH)
                    return _envelope_err(
                        f"{_PENDING_MAX_DEPTH} prompts are already queued for this "
                        "session and none has been injected yet — the session is "
                        "wedged or the agent is not consuming them. Stop sending and "
                        "tell the user to check the session.", code="queue_full"
                    )
                log_event("tool_call", tool="session_send_queued", session=name,
                          prompt_len=len(prompt), depth=queued_depth, reason=wait_reason)
            elif not await _inject(container, sanitized, _SESSION_WINDOW, session=name):
                log_event("tool_call", tool="session_send_failed", session=name,
                          prompt_len=len(prompt), reason="paste_failed")
                return _envelope_err("failed to inject prompt into session window",
                                     code="paste_failed")

        # Non-blocking: the reply is delivered by the transcript watcher, not returned
        # here. If no watcher is open, the reply has nowhere to go — say so plainly.
        watching = name in _session_watchers
        log_event("tool_call", tool="session_send_sent", session=name, watching=watching,
                  no_watch_reason=no_watch_reason, queued_depth=queued_depth)
        waiting_why = _WAITING_EXPLAINED.get(wait_reason, wait_reason)
        if watching and queued_depth:
            delivery = (
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
            delivery = (
                (f"Queued (held because {waiting_why}), but " if queued_depth
                 else "Sent, but ")
                + "no webhook is open for this session, so the reply will NOT "
                "be auto-delivered"
                + (f" ({no_watch_reason})" if no_watch_reason else "")
                + ". Do NOT re-send — the prompt was accepted and the session will "
                "work on it. Use session_invoke to block for the answer "
                "instead, or tell the user to fix the cause above."
            )
        return _envelope_ok(
            {"status": "queued" if queued_depth else "sent", "session": name,
             "queued_behind": max(0, queued_depth - 1),
             **({"waiting_reason": wait_reason} if queued_depth else {}),
             "window": _SESSION_WINDOW, "delivery": delivery}
        )

    # --- session_run (intentionally NOT advertised as an MCP tool) -----
    #
    # The multi-turn capability is KEPT — this wrapper stays intact — but it is
    # deliberately NOT registered via ``@app.tool()``, so MCP clients can neither
    # discover nor call it. session_run blocks synchronously while it runs every
    # turn in sequence; on an orchestrator the round-trip regularly outlasts the request
    # window and times out the whole session. Multi-turn work should be driven as
    # repeated session_send calls instead.
    #
    # NOTE if this is ever re-advertised: it pastes directly and does NOT consult
    # the pending-send queue, so it would jump the line ahead of prompts already
    # waiting. It takes the same per-session lock, so it cannot interleave WITH a
    # queued paste — only precede one that was waiting first. Route it through
    # _enqueue_send before exposing it.
    # Re-advertise by restoring the ``@app.tool()`` decorator below.
    @_scoped
    async def session_run(
        name: Annotated[str, Field(description=_NAME_DESC)],
        turns: Annotated[
            list[str],
            Field(description="The ordered list of prompts to send, run one after another."),
        ],
        conversation_id: Annotated[str | None, Field(description=_CONV_ID_DESC)] = None,
    ) -> dict[str, Any]:
        """Send a FIXED list of prompts to a session in order; return the full transcript.

        WHEN TO USE: you already know every prompt up front and want them run in sequence.
        WHEN NOT: a single message -> use session_send; the next prompt depends on the
        previous reply -> use session_send repeatedly.

        Unlike session_send, this is the SYNCHRONOUS path: it blocks, reads each reply
        from the session's transcript, and returns them all inline. It deliberately does NOT
        open a webhook — doing so would deliver every turn twice (once inline here, once
        via the callback). Use session_watch first if you also want the replies streamed.

        Args:
            name: the aidc session to talk to (see the open-webhook list below).
            turns: the ordered list of prompts to send.
            conversation_id: this conversation's id (the orchestrator injects it).

        Injects each turn into the 'claude' tmux window and waits for Claude to finish before
        sending the next. Returns a JSON transcript of all turns and responses when complete.
        For adaptive runs where the next turn depends on the previous response, use
        session_send multiple times instead.
        Newlines in each prompt are replaced with spaces.
        """
        if not turns:
            return _envelope_err("turns must be a non-empty list of prompt strings",
                                 code="invalid_argument")

        log_event("tool_call", tool="session_run", session=name, num_turns=len(turns))

        # NB: session_run does NOT auto-start a transcript watcher (contrast
        # session_send). It delivers the transcript inline as its return value; a
        # watcher would POST each completed turn to the callback too, so the
        # orchestrator would receive every turn twice. See the docstring.

        _TURN_TIMEOUT_S = 1800
        _PRE_IDLE_TIMEOUT_S = 30.0

        if name not in _session_send_locks:
            _session_send_locks[name] = asyncio.Lock()
        lock = _session_send_locks[name]

        container = f"aidc-{name}-dev"
        transcript: list[dict[str, Any]] = []

        async with lock:
            if not await _is_claude_running(container):
                return _envelope_err(
                    "Claude is not running in the session. "
                    "The user needs to start it (run 'aidc-claude' in the tmux claude window).",
                        code="claude_not_running"
                )

            for i, turn_prompt in enumerate(turns):
                reason = await _wait_until_free(container, name, timeout=_PRE_IDLE_TIMEOUT_S)
                if reason:
                    err = f"session not ready before turn {i + 1} ({reason})"
                    return _envelope_err(err, {"completed_turns": transcript},
                                         code="session_not_ready")

                sanitized = turn_prompt.replace("\n", " ").strip()
                sent_at = time.time()
                if not await _inject(container, sanitized, _SESSION_WINDOW, session=name):
                    err = f"failed to inject turn {i + 1}"
                    return _envelope_err(err, {"completed_turns": transcript}, code="paste_failed")

                ended = await _wait_for_turn_end(container, name, timeout=_TURN_TIMEOUT_S)
                if ended:
                    err = f"turn {i + 1} did not finish ({ended})"
                    return _envelope_err(err, {"completed_turns": transcript},
                                         code="turn_not_finished")

                response = _reply_from_transcript(name, sanitized, sent_at)

                transcript.append({"turn": i + 1, "prompt": turn_prompt, "response": response})

        log_event("tool_call", tool="session_run_complete", session=name, turns=len(transcript))
        return _envelope_ok({"transcript": transcript, "session": name, "window": _SESSION_WINDOW})

    # --- session_watch -------------------------------------------

    @app.tool()
    @_scoped
    async def session_watch(
        name: Annotated[str, Field(description=_NAME_DESC)],
        conversation_id: Annotated[str | None, Field(description=_CONV_ID_DESC)] = None,
    ) -> dict[str, Any]:
        """CALL THIS FIRST for any back-and-forth with a session.

        Starts a webhook so every reply from the session arrives here automatically —
        without it you are blind to replies unless you poll. Call once; re-calling is
        safe but re-anchors forward (it delivers only turns completing AFTER the call,
        never a backlog — see _baseline_watermark).
        session_send starts one automatically, so you only need this to
        watch a session you are not actively sending to yet.

        Args:
            name: the aidc session to watch (see the open-webhook list below).
        """
        base_url = _metallm_callback_url()
        if not base_url:
            return _envelope_err("metallm.callback_url not set in ~/.config/aidc/config.yaml",
                                 code="not_configured")
        if not conversation_id:
            return _envelope_err(
                "conversation_id is required (the orchestrator injects it automatically)",
                    code="invalid_argument"
            )
        # _start_watcher atomically cancels any existing watcher and installs the
        # new one, so a re-call (or a racing auto-watch) never leaves two watchers.
        await _start_watcher(app, name, conversation_id, base_url)
        log_event("tool_call", tool="session_watch", session=name, conversation_id=conversation_id)
        return _envelope_ok(
            {"status": "watching", "session": name, "conversation_id": conversation_id}
        )

    # --- session_resend ------------------------------------------

    @app.tool()
    @_scoped
    async def session_resend(
        name: Annotated[str, Field(description=_NAME_DESC)],
        conversation_id: Annotated[str | None, Field(description=_CONV_ID_DESC)] = None,
        turn_uuid: Annotated[
            str | None,
            Field(description="Optional: target a specific reply by its turn uuid. "
                              "Omit to target the session's most recent reply."),
        ] = None,
        force: Annotated[
            bool,
            Field(description="Re-POST even if this reply was already confirmed "
                              "delivered here. Almost never correct — the content "
                              "comes back in this tool's result either way. Use ONLY "
                              "when the orchestrator acknowledged the callback but genuinely "
                              "lost the message downstream."),
        ] = False,
    ) -> dict[str, Any]:
        """Fetch a session reply again when it did not land in this conversation.

        WHEN TO USE: a reply from session_send is genuinely absent here — a dropped
        callback, a watcher gap, an MCP restart at the wrong moment.
        WHEN NOT: a reply is merely SLOW. A session mid-turn has not answered yet,
        and the newest COMPLETED reply answers an EARLIER prompt — reading it as the
        pending answer makes the conversation respond to the wrong question. Wait for
        the webhook instead; it always arrives.

        This never duplicates. If the reply was already confirmed delivered here, it
        is NOT re-posted — the content is returned in this result instead, so you can
        read it without a second copy landing in the conversation. `status` says which
        happened:

          resent            - the reply was re-posted and will arrive over the webhook
          already_delivered - NOT re-posted; it is in `content` below, and it is
                              already somewhere above in this conversation

        Args:
            name: the aidc session whose reply to fetch.
            turn_uuid: a specific reply's uuid; omit for the latest reply.
            force: re-POST a reply already delivered here (almost never correct).
        """
        if not conversation_id:
            return _envelope_err(
                "conversation_id is required (the orchestrator injects it automatically)",
                    code="invalid_argument"
            )
        base_url = _metallm_callback_url()
        if not base_url:
            return _envelope_err("metallm.callback_url not set in ~/.config/aidc/config.yaml",
                                 code="not_configured")
        log_event("tool_call", tool="session_resend", session=name,
                  conversation_id=conversation_id, turn_uuid=turn_uuid or "", force=force)
        # Is the agent mid-turn right now? If so, the newest COMPLETED turn cannot
        # be the answer to the prompt still in flight — the caller must be told, or
        # it reads a stale reply as the response to its last question (prod
        # 2026-08-22 conv 01a01cf6: a no-uuid resend returned the previous prompt's
        # answer while the real turn had 16 minutes left to run).
        state = await _session_state(f"aidc-{name}-dev", name)
        busy = state.claude_running and state.turn == TURN_RUNNING
        status, turn = await _resend_reply(name, conversation_id, base_url,
                                           turn_uuid=turn_uuid, force=force)
        if turn is None:
            return _envelope_err(
                "no completed reply found to resend for this session "
                "(the session may not have produced a reply yet)", code="no_reply"
            )
        if status == "failed":
            return _envelope_err(
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
        log_event("transcript_resend_result", session=name,
                  conversation_id=conversation_id, turn_uuid=turn.terminal_uuid,
                  status=status, session_busy=busy, forced=force)
        return _envelope_ok(
            {"status": status, "session": name, "turn_uuid": turn.terminal_uuid,
             "content": turn.text, "session_busy": busy,
             "already_delivered": status == "already_delivered",
             **({"note": " ".join(notes)} if notes else {})}
        )

    # --- session_unwatch -----------------------------------------

    @app.tool()
    @_scoped
    async def session_unwatch(name: str) -> dict[str, Any]:
        """Stop watching the agent window for the named session.

        Cancels the background watcher started by session_watch.
        No-op if no watcher is active for the session.
        """
        task = _session_watchers.pop(name, None)
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        # Evict the per-session send lock + settle entries too, or they leak as
        # sessions come and go (the done-callback also does this on natural exit).
        _evict_session_state(name)
        await _announce_watchers(app)
        log_event("tool_call", tool="session_unwatch", session=name)
        return _envelope_ok({"status": "stopped", "session": name})

    # --- file_get -------------------------------------------------------

    @app.tool()
    @_scoped
    def file_get(name: str, path: str) -> dict[str, Any]:
        """Read a raw file from the session's mounted repo YOURSELF. Path must be
        absolute and inside the session's REPO_PATH (enforced by the in-container
        shell). To ask the session's Claude agent ABOUT the code (what it does, where
        something lives) instead of reading it raw, use session_send."""
        log_event("tool_call", tool="file_get", session=name, path=path)
        container = f"aidc-{name}-dev"
        # cat the file inside the container as vscode; non-zero on missing/perm.
        proc = subprocess.run(
            ["docker", "exec", "-u", "vscode", container, "cat", "--", path],
            capture_output=True, timeout=30,
        )
        if proc.returncode != 0:
            return _envelope_err(proc.stderr.decode("utf-8", errors="replace") or "file not found",
                                 code="command_failed")
        raw = proc.stdout
        try:
            return _envelope_ok({"path": path, "encoding": "utf-8", "content": raw.decode("utf-8")})
        except UnicodeDecodeError:
            return _envelope_ok({
                "path": path, "encoding": "base64",
                "content": base64.b64encode(raw).decode("ascii"),
            })

    # --- file_put -------------------------------------------------------

    @app.tool()
    @_scoped
    def file_put(name: str, path: str, content: str, mode: str = "0644") -> dict[str, Any]:
        """Write content to a file inside the session. Subject to the
        session's git-push prohibition + proxy filtering downstream.
        """
        log_event("tool_call", tool="file_put", session=name, path=path,
                  bytes=len(content), mode=mode)
        container = f"aidc-{name}-dev"
        # Stream content via stdin to a `tee` inside the container.
        proc = subprocess.run(
            ["docker", "exec", "-i", "-u", "vscode", container, "bash", "-c",
             f"install -m {shlex.quote(mode)} /dev/stdin {shlex.quote(path)}"],
            input=content.encode("utf-8"), capture_output=True, timeout=30,
        )
        if proc.returncode != 0:
            return _envelope_err(proc.stderr.decode("utf-8", errors="replace") or "write failed",
                                 code="command_failed")
        return _envelope_ok({"path": path, "bytes": len(content)})

    # --- audit_get ------------------------------------------------------

    @app.tool()
    @_scoped
    def audit_get(name: str, since: str | None = None, kind: str | None = None) -> dict[str, Any]:
        """Read audit events for a session. since: ISO8601 lower bound;
        kind: optional filter (e.g., 'taint', 'auth_reject').
        """
        # NB: log_event's first positional param is itself named `kind`; pass the
        # audit filter as `filter_kind` so it doesn't collide (a TypeError before).
        log_event("tool_call", tool="audit_get", session=name, since=since, filter_kind=kind)
        # Find the session's audit dir via aidc status (it prints the path).
        result = _run_cli(["status", name])
        if result["exit"] != 0:
            return _envelope_err("session not found", code="cli_failed")
        audit_dir = parse_audit_dir(result["stdout"])
        if audit_dir is None or not audit_dir.exists():
            return _envelope_err("audit dir not found", {"status": result["stdout"]},
                                 code="not_found")
        events: list[Any] = []
        # policy-events.log is one JSON object per line.
        events_file = audit_dir / "policy-events.log"
        if events_file.exists():
            for line in events_file.read_text(encoding="utf-8", errors="replace").splitlines():
                try:
                    e = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if since and e.get("at", "") < since:
                    continue
                if kind and kind not in str(e.get("trigger", "") + e.get("outcome", "")):
                    continue
                events.append(e)
        return _envelope_ok({"audit_dir": str(audit_dir), "events": events})

    # --- taint_mark -----------------------------------------------------

    @app.tool()
    @_scoped
    def taint_mark(name: str, reason: str) -> dict[str, Any]:
        """Policy signal — do not call this. Set by the system when a container
        visits an unsafe site, indicating possible infection. kill+recreate only.
        """
        log_event("tool_call", tool="taint_mark", session=name, reason=reason)
        container = f"aidc-{name}-policy"
        # Write the taint flag via the policy container's volume.
        payload = json.dumps({
            "tainted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "trigger": "manual",
            "domain": reason,
            "squid_log_line": f"manual taint via MCP: {reason}",
        })
        proc = subprocess.run(
            ["docker", "exec", container, "bash", "-c",
             f"printf {shlex.quote(payload)} > /var/state/tainted.new "
             "&& mv /var/state/tainted.new /var/state/tainted"],
            capture_output=True, text=True, timeout=10,
        )
        if proc.returncode != 0:
            return _envelope_err(proc.stderr or "taint write failed", code="command_failed")
        return _envelope_ok({"name": name, "reason": reason})

    # Seed the live "open webhooks" tail into the session-aware tool descriptions
    # (captures each tool's static base on first touch; no sessions watched yet).
    _refresh_session_tool_descriptions(app)
