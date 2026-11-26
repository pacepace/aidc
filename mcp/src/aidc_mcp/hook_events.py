"""A session's Claude Code hook events, as aidc-mcp reads them (MCP-46).

Inside the session, `aidc-hook-event` (.devcontainer/hook-event.sh) writes one file per
`SessionStart`, `Stop`, `Notification` and `UserPromptSubmit` hook into `hook-events/` of the
session's MCP-readable mirror dir (beside its transcript copies, `<transcripts>/<session>/`), named
`<epoch-ns>-<pid>.json` so the names sort in the order the events happened, each written
whole by rename. A file holds Claude Code's own hook input with two fields added:

    {"event": "Stop", "at": "2026-11-26T09:00:01.123Z",
     "session_id": "...", "transcript_path": "...", "cwd": "...",
     "last_assistant_message": "...", "stop_hook_active": false}

`Notification` carries `notification_type` (`permission_prompt`, `idle_prompt`, ...) and
`message`; `UserPromptSubmit` carries `prompt`. Fields a newer Claude Code adds are kept.

No I/O beyond reading the dir; what the service makes of the events is service/turns.py's.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

#: the dir under a session's mirror dir the hook writes into
EVENTS_DIR = "hook-events"

SESSION_START = "SessionStart"
STOP = "Stop"
NOTIFICATION = "Notification"
USER_PROMPT_SUBMIT = "UserPromptSubmit"

PERMISSION_PROMPT = "permission_prompt"
IDLE_PROMPT = "idle_prompt"

#: a written event's name: the writer's clock in nanoseconds, then its pid
_NAME = re.compile(r"(\d{19})-(\d+)\.json")


@dataclass(frozen=True)
class HookEvent:
    """One event: its file's name (its place in order), the hook, when, and its fields."""

    name: str
    event: str
    at: str
    session_id: str
    data: dict[str, Any] = field(default_factory=dict, compare=False)

    @property
    def notification_type(self) -> str:
        value = self.data.get("notification_type")
        return value if isinstance(value, str) else ""

    @property
    def source(self) -> str:
        """A SessionStart's cause: startup, resume, clear, or compact (mid-turn)."""
        value = self.data.get("source")
        return value if isinstance(value, str) else ""

    @property
    def last_assistant_message(self) -> str:
        value = self.data.get("last_assistant_message")
        return value if isinstance(value, str) else ""

    @property
    def prompt(self) -> str:
        value = self.data.get("prompt")
        return value if isinstance(value, str) else ""


def events_dir(session_mirror_dir: Path) -> Path:
    return Path(session_mirror_dir) / EVENTS_DIR


def parse_event(name: str, text: str) -> HookEvent | None:
    """An event file's content as a HookEvent, or None when it is not one (not a JSON
    object, or no `event`)."""
    try:
        data = json.loads(text)
    except ValueError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("event"), str) or not data["event"]:
        return None
    at = data.get("at")
    session_id = data.get("session_id")
    return HookEvent(name=name, event=data["event"], at=at if isinstance(at, str) else "",
                     session_id=session_id if isinstance(session_id, str) else "", data=data)


def read_events(session_mirror_dir: Path, after: str = "") -> list[HookEvent]:
    """The session's events written after the one named `after` ("" for all), oldest
    first. A file that is not an event (a temp name, a damaged file) is skipped; a missing
    dir is no events."""
    try:
        names = sorted(p.name for p in events_dir(session_mirror_dir).iterdir()
                       if _NAME.fullmatch(p.name) and p.name > after)
    except OSError:
        return []
    out: list[HookEvent] = []
    for name in names:
        try:
            text = (events_dir(session_mirror_dir) / name).read_text(encoding="utf-8")
        except OSError:
            continue
        parsed = parse_event(name, text)
        if parsed is not None:
            out.append(parsed)
    return out
