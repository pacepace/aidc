"""Hook events a test session fires, written as the session's aidc-hook-event writes them
(MCP-46): one JSON file per event in hook-events/ of the session's mirror dir, named so
the names sort in the order fired."""
import itertools
import json
import time
from pathlib import Path

from aidc_mcp import hook_events as he

_seq = itertools.count()


def fire(mirror_base: Path, session: str, event: str, *, at_epoch: float | None = None,
         **fields) -> str:
    """Write one event for `session` under `mirror_base` (the MCP's transcripts dir), at
    `at_epoch` (now when not given); returns its file name. Names sort in the order fired."""
    d = he.events_dir(Path(mirror_base) / session)
    d.mkdir(parents=True, exist_ok=True)
    name = f"{1_700_000_000_000_000_000 + next(_seq):019d}-1.json"
    when = time.time() if at_epoch is None else at_epoch
    at = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(when)) + f".{int(when * 1000) % 1000:03d}Z"
    (d / name).write_text(json.dumps({"event": event, "at": at, "session_id": "sid",
                                      "hook_event_name": event, **fields}),
                          encoding="utf-8")
    return name


def started(mirror_base: Path, session: str, **kw) -> str:
    return fire(mirror_base, session, he.SESSION_START, source="startup", **kw)


def stopped(mirror_base: Path, session: str, reply: str = "", **kw) -> str:
    return fire(mirror_base, session, he.STOP, last_assistant_message=reply, **kw)


def prompted(mirror_base: Path, session: str, prompt: str = "", **kw) -> str:
    return fire(mirror_base, session, he.USER_PROMPT_SUBMIT, prompt=prompt, **kw)


def notified(mirror_base: Path, session: str, kind: str, **kw) -> str:
    return fire(mirror_base, session, he.NOTIFICATION, notification_type=kind, **kw)
