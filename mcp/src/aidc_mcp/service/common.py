"""What every part of the service uses: background tasks, the aidc CLI runner, and the
result envelope with its closed set of error codes (design 10 D6).

No MCP types here (test_service_boundary): the tools in tearstools/ adapt it.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
from collections.abc import Awaitable, Callable
from typing import Any

from aidc_mcp import audit, observability
from aidc_mcp.service import state as ss

AIDC = os.environ.get("AIDC_CLI", "/aidc/scripts/aidc")



def background_task(coro: Any, **log_context: str) -> asyncio.Task[Any]:
    """Start a coroutine as a task of its own, in a fresh log context holding only
    `log_context`, never the context of the tool call that starts it (its correlation id,
    tool name and span end with the call). Every task the service starts goes through here."""
    return asyncio.create_task(coro, context=observability.background_context(**log_context))


def fire(coro: Any, **log_context: str) -> None:
    """Run a coroutine in the background (background_task), keeping a reference so it is
    not collected. server.py starts the resume task with it."""
    task = background_task(coro, **log_context)
    ss.background_tasks.add(task)
    task.add_done_callback(ss.background_tasks.discard)


def session_changed(name: str) -> None:
    """Tell the listeners that what session `name`'s status shows may have changed: a
    prompt went in, a turn was delivered, the session was created or interrupted. A
    listener that fails is logged; the service's work goes on."""
    for listener in list(ss.session_change_listeners):
        try:
            listener(name)
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- a notice only
            audit.log_event("session_change_notify_failed", session=name,
                            error_type=type(exc).__name__, error=repr(exc))


def run_cli(args: list[str], timeout: float = 60.0) -> dict[str, Any]:
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


async def run_cli_streaming(
    args: list[str], progress: Callable[[str], Awaitable[Any]], phase_keywords: dict[str, str]
) -> dict[str, Any]:
    """Run aidc CLI with live progress notifications.

    `phase_keywords` maps substrings-in-output to progress phase names.
    Whenever a stdout/stderr line contains a key, `progress` is called with
    the corresponding name and the line (the MCP tool passes its Context's info).
    """
    cmd = [AIDC, *args]
    audit.log_event("cli_exec_streaming", argv=cmd)
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
                    await progress(f"{phase}: {line}")
                except Exception:  # prawduct:allow prawduct/broad-except -- progress is cosmetic
                    pass
                break
    rc = await proc.wait()
    return {"exit": rc, "stdout": "\n".join(out_chunks), "stderr": ""}


def envelope_ok(data: Any = None) -> dict[str, Any]:
    out: dict[str, Any] = {"ok": True}
    if data is not None:
        out["data"] = data
    return out


# Machine-readable failure kinds, so a caller can decide "tell the person, no retry"
# from "try once more" without matching the prose in `error`. Every failure envelope
# carries one; adding a code is a contract change agreed with the orchestrator side.
# Each code's description is what the MCP face registers it with (TRS-05), so a
# client's documentation of the codes says the same as this table.
ERROR_CODE_DESCRIPTIONS: dict[str, str] = {
    "no_such_session": "the session's container does not exist",
    "queue_full": "too many prompts already waiting; the session is wedged",
    "out_of_scope": "a scoped server refusing another session",
    "create_not_allowed": "session_create on a scoped server",
    "invalid_argument": "a required argument is missing or invalid",
    "invoke_busy": "session_invoke(_async): a headless run is already going there",
    "not_configured": "the aidc config lacks what the call needs (callback_url)",
    "cli_failed": "an aidc CLI call exited non-zero",
    "command_failed": "a command inside the session failed (file_get, claude, ...)",
    "timeout": "a command inside the session ran out of time",
    "session_not_ready": "session_mcp_set: the session's first start has not finished",
    "no_reply": "session_resend: nothing completed to resend",
    "callback_failed": "session_resend: the POST to the orchestrator failed",
    "not_found": "a file or directory the call reads is missing",
    "path_not_allowed": "session_create: a path outside what the operator exposed",
    "tainted": "the session is tainted: nothing more is put into it",
    "outside_repo": "a path that leaves the session's repository",
    "session_outdated": ("the session predates aidc 2.0's hook events; kill it and create "
                         "it again (the git agent: rebuild its image and set it up again)"),
    "git_answer_unclear": ("session_send to the git agent asking about a git request: the "
                           "answer is not plainly Approve or Deny; nothing was sent"),
    "git_request_ambiguous": ("session_send to the git agent: its question names several git "
                              "requests; nothing was approved or sent"),
    "git_request_not_waiting": ("session_send to the git agent: the text is a git answer "
                                "(Approve or Deny) and no question of the agent's is open, so "
                                "no request waits for it; nothing was sent"),
    "git_requests_unreadable": ("session_send to the git agent: its waiting git requests "
                                "could not be read; nothing was approved or sent"),
}
ERROR_CODES = frozenset(ERROR_CODE_DESCRIPTIONS)

# The codes whose call, made again unchanged, can succeed later (design-10 D6's Retryable
# column): an aidc CLI call that failed is transient, a headless run that is busy ends, and
# the git container's request list read again can answer. Every other code meets the same
# refusal until something changes.
RETRYABLE_ERROR_CODES = frozenset({"cli_failed", "invoke_busy", "git_requests_unreadable"})


def envelope_err(error: str, data: Any = None, *, code: str) -> dict[str, Any]:
    out: dict[str, Any] = {"ok": False, "error": error, "error_code": code}
    if data is not None:
        out["data"] = data
    return out
