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


def working_on(objs: list[dict], cap: int = 300) -> str:
    """The newest prompt in the transcript, cut to `cap`: what an open turn is working on."""
    for obj in reversed(objs):
        if obj.get("type") != "user":
            continue
        text = ts.human_prompt_text(obj)
        if text.strip():
            return redact(text.strip())[:cap]
    return ""


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
