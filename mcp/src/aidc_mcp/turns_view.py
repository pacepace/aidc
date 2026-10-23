"""What a session said: its completed turns as prompt and reply text, for session_transcript.

A Claude Code transcript holds far more than the conversation: every tool call's
input and every tool result, which carry file contents, command output, the
environment, and whatever a command printed (tokens included). Only two things are
read here, the same two the watcher delivers: the prompts that opened each turn and
the text Claude wrote in reply (``extract_completed_turns``). Tool use, tool results
and thinking never reach the caller. Well-known secret shapes left in that text are
redacted, and each part is capped, as is the whole.
"""

from __future__ import annotations

import re
from datetime import UTC, datetime
from typing import Any

from aidc_mcp import transcript as ts

PROMPT_CAP = 2_000
REPLY_CAP = 6_000
TOTAL_CAP = 30_000
MAX_TURNS = 20

REDACTED = "[redacted]"
# Secret shapes with a known prefix. Each needs a run of token characters after it,
# so prose that merely names the prefix ("an sk- key") is left as written.
_SECRET_PATTERNS = (
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{16,}"),
    re.compile(r"\bsk-[A-Za-z0-9_\-]{20,}"),
    re.compile(r"\bxox[abpr]-[A-Za-z0-9\-]{10,}"),
    re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
)
# A bearer token, or a long value after token=/password= (and the like): the
# label stays so the reader knows what was there.
_LABELLED = (
    re.compile(r"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=\-]{20,}"),
    re.compile(r"(?i)(\b(?:token|password|passwd|secret|api_key|apikey)\s*[=:]\s*[\"']?)"
               r"[A-Za-z0-9._~+/=\-]{16,}"),
)


def redact(text: str) -> str:
    """`text` with every well-known secret shape replaced by REDACTED."""
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub(REDACTED, text)
    for pattern in _LABELLED:
        text = pattern.sub(lambda m: m.group(1) + REDACTED, text)
    return text


def _cut(text: str, cap: int) -> tuple[str, bool]:
    if len(text) <= cap:
        return text, False
    return text[:cap], True


def _iso(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, UTC).isoformat().replace("+00:00", "Z")


def line_times(objs: list[dict]) -> dict[str, float]:
    """Each transcript line's time, by its uuid."""
    out: dict[str, float] = {}
    for obj in objs:
        uuid = obj.get("uuid")
        when = ts.wall_time(obj)
        if isinstance(uuid, str) and when is not None:
            out[uuid] = when
    return out


def last_reply_at(objs: list[dict]) -> str | None:
    """When the newest completed turn ended (its terminal line's time), ISO UTC."""
    turns = ts.extract_completed_turns(objs)
    if not turns:
        return None
    return _iso(line_times(objs).get(turns[-1].terminal_uuid))


# What opened a turn (started_by):
#   prompt           a person's prompt, or one the MCP pasted (the two look the same);
#   background_task  a background task's <task-notification>;
#   session_message  another Claude session's message (a peer agent, the coordinator);
#   system           anything else Claude Code started itself (an auto-continue, a
#                    scheduled wake-up), or a turn whose opening line is not in the
#                    transcript.
STARTED_BY = ("prompt", "background_task", "session_message", "system")

# What a caller reads when no turn is open.
NO_TURN: dict[str, Any] = {"working_on": "", "started_by": None, "turn_started_at": None,
                           "last_activity": None}

# promptSource values a person's (or the MCP's) words arrive under, besides "typed":
# a prompt Claude Code held while it worked and then ran ("queued"), a suggestion the
# person accepted, and one sent through Claude Code's remote control ("sdk"). Measured
# over every transcript on the build host, 2026-10-22: each comes with origin.kind
# "human" or no origin at all.
_PERSON_SOURCES = frozenset({"typed", "queued", "suggestion_accepted", "sdk"})
_NOTIFICATION_KIND = "task-notification"
_NOTIFICATION_TAG = "<task-notification>"
_TAG_RE = {name: re.compile(rf"<{name}>(.*?)</{name}>", re.DOTALL)
           for name in ("task-id", "status", "summary")}


def _origin_kind(obj: dict) -> str:
    origin = obj.get("origin")
    kind = origin.get("kind") if isinstance(origin, dict) else None
    return kind if isinstance(kind, str) else ""


def _person_words(obj: dict) -> str:
    """What a person (or the MCP) wrote on this prompt line, or "" when nobody did.
    human_prompt_text's rules, with the other promptSource values a person's words
    arrive under; a line opening with a wrapper tag still yields nothing."""
    words = ts.human_prompt_text(obj)
    if words:
        return words
    source = obj.get("promptSource")
    if (obj.get("isMeta") or source not in _PERSON_SOURCES
            or _origin_kind(obj) not in ("", "human")):
        return ""
    return ts.human_prompt_text({**obj, "promptSource": "typed"})


def _tag(text: str, name: str) -> str:
    m = _TAG_RE[name].search(text)
    return " ".join(m.group(1).split()) if m else ""


def started_by(opener: dict | None) -> str:
    """What opened a turn, as one of STARTED_BY, from its opening line."""
    if opener is None:
        return "system"
    kind = _origin_kind(opener)
    if kind == _NOTIFICATION_KIND or ts.line_text(opener).lstrip().startswith(_NOTIFICATION_TAG):
        return "background_task"
    if kind in ts.SESSION_MESSAGE_KINDS:
        return "session_message"
    if _person_words(opener):
        return "prompt"
    return "system"


def _describe(opener: dict | None, by: str) -> str:
    """working_on for a turn: the prompt's words when a person or the MCP opened it;
    otherwise what started it, said as such. A system wrapper is never shown as if a
    person had written it."""
    if opener is None:
        return "a turn whose opening line is not in the transcript"
    if by == "prompt":
        return _person_words(opener).strip()
    if by == "background_task":
        text = ts.line_text(opener)
        status = _tag(text, "status") or "finished"
        summary = _tag(text, "summary")
        task = _tag(text, "task-id")
        said = summary or (f"task {task}" if task else "")
        if summary and task:
            said += f" (task {task})"
        return f"background task {status}: {said}" if said else f"background task {status}"
    if by == "session_message":
        origin = opener.get("origin")
        sender = origin.get("from") or origin.get("name") if isinstance(origin, dict) else ""
        if _origin_kind(opener) == "coordinator":
            return "a message from the coordinator session"
        return (f"a message from another Claude session ({sender})" if isinstance(sender, str)
                and sender else "a message from another Claude session")
    return "something Claude Code started itself, not a prompt"


def _activity(obj: dict | None) -> dict[str, Any] | None:
    """The newest step of an assistant line: the last tool_use, text or thinking block."""
    if obj is None:
        return None
    raw = obj.get("message")
    msg = raw if isinstance(raw, dict) else {}
    content = msg.get("content")
    blocks = content if isinstance(content, list) else []
    for block in reversed(blocks):
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind == "tool_use":
            name = block.get("name")
            return {"kind": "tool_use", "name": name if isinstance(name, str) else "",
                    "at": _iso(ts.wall_time(obj))}
        if kind in ("text", "thinking"):
            return {"kind": kind, "at": _iso(ts.wall_time(obj))}
    if obj.get("isApiErrorMessage") or isinstance(content, str):
        return {"kind": "text", "at": _iso(ts.wall_time(obj))}
    return None


def turn_info(objs: list[dict], cap: int = 300) -> dict[str, Any]:
    """What the open turn is doing: working_on (cut to `cap`, redacted), started_by,
    turn_started_at (ISO UTC) and last_activity ({kind, name for a tool_use, at}, or
    None before Claude has written anything). NO_TURN when no turn is open."""
    turn = ts.open_turn(objs)
    if turn is None:
        return dict(NO_TURN)
    by = started_by(turn.opener)
    return {"working_on": redact(_describe(turn.opener, by))[:cap], "started_by": by,
            "turn_started_at": _iso(turn.started_at),
            "last_activity": _activity(turn.newest_assistant)}


class UnknownTurn(ValueError):
    """since_uuid names no completed turn in the transcript."""


def view(objs: list[dict], *, last_n: int, since_uuid: str = "") -> dict[str, Any]:
    """The completed turns as {uuid, at, prompt, reply, interrupted, ok, cut}, with how
    many came before and after the ones returned.

    :raises UnknownTurn: when since_uuid is not a completed turn in the transcript
    """
    turns = [t for t in ts.extract_completed_turns(objs)
             if not t.error_code]  # a notice is not a turn
    times = line_times(objs)
    if since_uuid:
        index = next((i for i, t in enumerate(turns) if t.terminal_uuid == since_uuid), None)
        if index is None:
            raise UnknownTurn(since_uuid)
        start = index + 1
        picked = turns[start:start + last_n]
    else:
        start = max(0, len(turns) - last_n)
        picked = turns[start:]
    out: list[dict[str, Any]] = []
    total = 0
    cut_any = False
    for turn in picked:
        prompt, p_cut = _cut(redact("\n\n".join(p.strip() for p in turn.prompts if p.strip())),
                             PROMPT_CAP)
        reply, r_cut = _cut(redact(turn.text), REPLY_CAP)
        room = TOTAL_CAP - total
        if room <= 0:
            cut_any = True
            break
        if len(prompt) + len(reply) > room:
            # The last turn that fits is cut to the room left; the rest wait for the
            # next call (next_since_uuid).
            prompt = prompt[:room]
            reply = reply[: max(0, room - len(prompt))]
            p_cut = r_cut = True
        total += len(prompt) + len(reply)
        cut_any = cut_any or p_cut or r_cut
        out.append({"uuid": turn.terminal_uuid, "at": _iso(times.get(turn.terminal_uuid)),
                    "prompt": prompt, "reply": reply, "interrupted": turn.interrupted,
                    "ok": turn.ok, "cut": p_cut or r_cut})
    later = len(turns) - (start + len(out))
    return {"turns": out, "earlier": start, "later": later,
            "next_since_uuid": out[-1]["uuid"] if out and later > 0 else "",
            "cut": cut_any}
