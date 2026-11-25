"""Delivery to the orchestrator: the callback POST, its retry budget and dead letters.

No MCP types here (test_service_boundary): the tools in tools.py adapt it.
"""

from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path

import httpx

from aidc_mcp import auth
from aidc_mcp import transcript as ts
from aidc_mcp.audit import log_event
from aidc_mcp.service import config as orc

_DELIVERY_BUDGET_S = 1800.0


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
    deliver_with_retry to stop immediately and dead-letter instead of retrying
    the identical payload for the whole budget. Carries the status for logging."""

    def __init__(self, status: int) -> None:
        super().__init__(f"permanent delivery failure: HTTP {status}")
        self.status = status


async def post_turn(
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
        bearer = auth.load_token()
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
                # with that prompt), "person" (this MCP injected it for the person
                # session_send's ``sent_by`` named, which comes back as
                # ``sent_by``), "orchestrator" (a prompt this MCP injected for the
                # caller), or "" (unknown: a prompt Claude Code synthesized with no
                # prompted turn before it). Informational; the content already
                # reads right.
                # ``interrupted`` is true when the person pressed Esc and cut the turn
                # off. It is not a failure, so ``ok`` stays true; the content opens
                # with a note saying so, which is all a receiver that ignores the
                # field needs. ``speaker`` ("human" | "agent") only when
                # orchestrator.send_speaker is on. The whole body is pinned in design-10
                # D5 and agreed with the orchestrator's side before any field changes.
                json={"content": turn.text, "ok": turn.ok, "source": "agent_watch",
                      "session": session, "prompt_origin": turn.prompt_origin,
                      "interrupted": turn.interrupted,
                      **({"sent_by": turn.sent_by} if turn.sent_by else {}),
                      **({"error_code": turn.error_code} if turn.error_code else {}),
                      **({"pasted_at": turn.pasted_at} if turn.pasted_at else {}),
                      **({"prompts": list(turn.batch)} if turn.batch else {}),
                      **({"speaker": turn.speaker}
                         if turn.speaker and orc.orchestrator_send_speaker() else {})},
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


async def deliver_with_retry(turn: ts.Turn, *, post_fn, sleep_fn=asyncio.sleep,
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


def write_dead_letter(state_dir: Path, session: str, conversation_id: str, turn: ts.Turn) -> None:
    """Persist an undelivered turn so it is recorded, not silently lost (MCP-18)."""
    dl = Path(state_dir) / "dead-letter"
    dl.mkdir(parents=True, exist_ok=True)
    name = f"{ts.slug(session)}__{ts.slug(conversation_id)}__{ts.slug(turn.terminal_uuid)}.json"
    (dl / name).write_text(
        json.dumps({"session": session, "conversation_id": conversation_id,
                    "turn_uuid": turn.terminal_uuid, "content": turn.text, "ok": turn.ok,
                    "interrupted": turn.interrupted}),
        encoding="utf-8",
    )
