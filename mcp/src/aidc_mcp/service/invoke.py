"""Headless runs (session_invoke, session_invoke_async): one per session, stopped when
their caller goes away.

No MCP types here (test_service_boundary): the tools in tools.py adapt it.
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable
from typing import Any, NamedTuple

import httpx

from aidc_mcp import auth, backend, headless
from aidc_mcp.audit import log_event
from aidc_mcp.service import common as com
from aidc_mcp.service import config as orc
from aidc_mcp.service import repos as rps
from aidc_mcp.service import state as ss

# A session_invoke longer than this gets a warning in its result: long work belongs to
# session_send (owner ruling, 2026-10-22: "the agent shouldn't be using session invoke for
# things that run for a long time").
INVOKE_LONG_S = 60.0


# session_invoke_async's limit: past it the run is stopped and the failure delivered.
ASYNC_INVOKE_TIMEOUT_S = 1800.0


INVOKE_LONG_WARNING = (
    "This session_invoke ran {secs:.0f} s. session_invoke is for short, single-shot "
    "questions; anything long, anything that edits files or runs builds or tests, goes "
    "to the session's agent with session_send.")


async def claim_headless(name: str, tool: str, prompt: str
                          ) -> tuple[headless.Run | None, dict[str, Any] | None]:
    """Claim the session's one headless slot for a new run: (the run, None), or
    (None, the run already going). A run this server started counts, and so does any
    `claude --print` found in the container: one left from before an aidc-mcp restart,
    or started some other way."""
    lock = ss.invoke_locks.setdefault(name, asyncio.Lock())
    async with lock:
        running = headless.tracked(name)
        # Read the container either way: when one of this server's runs holds the slot,
        # it is what gives the refusal that run's pid.
        found = await headless.container_runs(backend.target(name))
        if found is None and not running:
            # The run's own docker exec fails the same way if the container is down;
            # if it is only slow to answer, an orphan may go uncounted.
            log_event("headless_claim_without_listing", session=name, tool=tool)
        running = headless.merge(name, found)
        if running:
            return None, running[0]
        return headless.new_run(name, tool, prompt), None


def invoke_busy(name: str, tool: str, running: dict[str, Any]) -> dict[str, Any]:
    log_event("tool_call", tool=f"{tool}_refused", session=name, reason="invoke_busy",
              running_tool=running.get("tool"), running_since=running.get("started_at"),
              orphan=running.get("orphan"))
    return com.envelope_err(
        f"A headless run is already going in session '{name}' (one at a time per session): "
        f"{running.get('tool') or 'claude --print'} since {running.get('started_at')}, "
        f"prompt: {running.get('prompt')!r} (run {running.get('run_id')}, pid "
        f"{running.get('pid')}). Wait for it to finish (session_status shows it under "
        "headless_runs); if nobody needs it any more, stop it with session_interrupt and "
        'target "headless"; and give long work to the session\'s agent with session_send.',
        {"running": running}, code="invoke_busy")


class InFlight(NamedTuple):
    """A session_invoke call waiting on its run."""

    container: str
    run: headless.Run
    proc: Any


# The session_invoke calls in flight, by (MCP session id, JSON-RPC request id), so the
# transport layer can stop one whose client dropped the connection (disconnect.py).
invokes_in_flight: dict[tuple[str, str], InFlight] = {}


def stop_invoke_of_gone_client(session_id: str, request_id: str) -> None:
    """disconnect.StopInvokeOnDisconnect's callback: the client of that call is gone."""
    entry = invokes_in_flight.pop((session_id, request_id), None)
    if entry is None:
        return
    log_event("session_invoke_client_disconnected", session=entry.run.session,
              run_id=entry.run.run_id)
    com.fire(stop_headless(entry.container, entry.run, entry.proc,
                            "session_invoke_stopped_client_gone"))


def _kill_host_exec(proc: Any) -> None:
    if proc is not None and proc.returncode is None:
        try:
            proc.kill()
        except ProcessLookupError:
            pass


# session_interrupt's `target`.
INTERRUPT_AGENT = "agent"


INTERRUPT_HEADLESS = "headless"


async def interrupt_headless(name: str, container: str) -> dict[str, Any]:
    """session_interrupt(target="headless"): stop the session's headless runs, whoever
    started them. One this server is waiting on is stopped through its own call, which
    then returns; one left from before a restart is found in the container. A stop
    docker could not carry out is reported as not interrupted, with why."""
    tree = await rps.tree(name)
    found = await headless.container_runs(container)
    running = headless.merge(name, found)
    base = {"session": name, "target": "headless", "tree": tree}
    if not running:
        note = ("no headless run was going" if found is not None else
                "the container's processes could not be read (is the session running?), "
                "so no headless run could be found")
        log_event("tool_call", tool="session_interrupt", session=name, target="headless",
                  interrupted=False, listed=found is not None)
        return com.envelope_ok({**base, "interrupted": False, "stopped": [], "pids": [],
                             "note": note})
    pids: list[int] = []
    failed: list[str] = []
    for rec in running:
        mine = next((r for r in headless.runs_of(name) if r.run_id == rec["run_id"]), None)
        try:
            if mine is not None:
                pids += await headless.stop(container, mine)
                _kill_host_exec(next((e.proc for e in invokes_in_flight.values()
                                      if e.run is mine), None))
            elif rec["run_id"]:
                pids += await headless.stop_tagged(container, rec["run_id"])
            elif rec["pid"] is not None:
                pids += await headless.stop_tree(container, rec["pid"])
        except headless.DockerFailed as exc:
            failed.append(str(exc))
            log_event("headless_stop_failed", session=name, run_id=rec["run_id"],
                      pid=rec["pid"], error=str(exc))
    log_event("tool_call", tool="session_interrupt", session=name, target="headless",
              interrupted=not failed, runs=[r["run_id"] for r in running], pids=pids)
    data = {**base, "interrupted": not failed, "stopped": running, "pids": pids}
    if failed:
        data["note"] = "the stop could not be carried out: " + "; ".join(failed)
    return com.envelope_ok(data)


async def stop_headless(container: str, run: headless.Run, proc: Any, event: str) -> None:
    """Stop a headless run whose caller is gone: its whole process tree in the
    container (the docker exec's own exit leaves claude running there), then the host's
    docker exec. Logged as `event` with the pids stopped, or as headless_stop_failed
    with docker's error; the run then shows in session_status as an orphan."""
    ran_s = round(time.time() - run.started_at, 1)
    try:
        pids = await headless.stop(container, run)
    except headless.DockerFailed as exc:
        log_event("headless_stop_failed", session=run.session, run_id=run.run_id,
                  reason=event, ran_s=ran_s, error=str(exc))
        return
    finally:
        _kill_host_exec(proc)
        headless.forget(run)
    log_event(event, session=run.session, run_id=run.run_id, pids=pids, ran_s=ran_s)


async def invoke(
    name: str,
    prompt: str,
    *,
    call_key: tuple[str, str] | None = None,
    progress: Callable[[str], Awaitable[Any]] | None = None,
) -> dict[str, Any]:
    """The session_invoke tool's work. tools.py holds the tool: its schema and description,
    and the guards around it."""
    log_event("tool_call", tool="session_invoke", session=name, prompt_len=len(prompt))
    container = backend.target(name)
    run, running = await claim_headless(name, "session_invoke", prompt)
    if run is None:
        return invoke_busy(name, "session_invoke", running or {})
    # `aidc-claude` is the in-container wrapper that respects AIDC_CLAUDE_MODE; the
    # run is tagged and never resumes the session's conversation (headless.py).
    try:
        proc = await asyncio.create_subprocess_exec(
            *headless.exec_argv(container, run),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
    except BaseException:
        headless.forget(run)
        raise
    key = call_key
    if key is not None:
        invokes_in_flight[key] = InFlight(container, run, proc)
    try:
        return await _finish_invoke(container, run, proc, progress)
    except BaseException as exc:
        # The caller is gone (it cancelled the request, or its session closed), or
        # reading the answer failed. There is no timeout (owner ruling, 2026-10-22), so
        # this is the one way a run nobody waits for ends early: stopped in the
        # container, in a task of its own, since this one may be being cancelled.
        com.fire(stop_headless(container, run, proc,
                               "session_invoke_cancelled"
                               if isinstance(exc, asyncio.CancelledError)
                               else "session_invoke_failed_stopped"))
        raise
    finally:
        if key is not None:
            invokes_in_flight.pop(key, None)


async def _finish_invoke(container: str, run: headless.Run, proc: Any,
                         progress: Callable[[str], Awaitable[Any]] | None
                         ) -> dict[str, Any]:
    """Stream a started session_invoke's answer and build its result."""
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
            if progress is not None:
                try:
                    await progress(chunk)
                except Exception:  # prawduct:allow prawduct/broad-except -- cosmetic
                    pass
        await stderr_task
    finally:
        # If the stdout loop errored, don't orphan the stderr drain.
        if not stderr_task.done():
            stderr_task.cancel()
    await proc.wait()
    headless.forget(run)
    elapsed = time.time() - run.started_at
    about: dict[str, Any] = {"elapsed_s": round(elapsed, 1)}
    if elapsed > INVOKE_LONG_S:
        about["warning"] = INVOKE_LONG_WARNING.format(secs=elapsed)
    stderr_data = b"".join(stderr_buf)
    if proc.returncode != 0:
        said = stderr_data.decode("utf-8", errors="replace")
        if run.stopped:
            said = ("the run was stopped (session_interrupt with target \"headless\") "
                    "before it answered" + (f": {said}" if said else ""))
        return com.envelope_err(said or "claude failed",
                                {"stdout": "".join(chunks), **about}, code="command_failed")
    return com.envelope_ok({"response": "".join(chunks), **about})


async def invoke_async(name: str, prompt: str, conversation_id: str) -> dict[str, Any]:
    """The session_invoke_async tool's work. tools.py holds the tool: its schema and description,
    and the guards around it."""
    base_url = orc.orchestrator_callback_url()
    if not base_url:
        return com.envelope_err(
            orc.callback_url_unset(),
            code="not_configured",
        )

    callback_url = f"{base_url}/api/v1/internal/callback/{conversation_id}"
    log_event(
        "tool_call",
        tool="session_invoke_async",
        session=name,
        conversation_id=conversation_id,
        prompt_len=len(prompt),
    )

    container = backend.target(name)
    # Claimed here, before the call returns, so a second call is refused at once.
    run, running = await claim_headless(name, "session_invoke_async", prompt)
    if run is None:
        return invoke_busy(name, "session_invoke_async", running or {})

    async def _run_and_notify() -> None:
        started: list[Any] = []
        try:
            async def _exec() -> tuple[str, bool]:
                if run.stopped:   # session_interrupt(target="headless") came first
                    return "session_invoke_async was stopped before it started", False
                proc = await asyncio.create_subprocess_exec(
                    *headless.exec_argv(container, run),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                started.append(proc)
                # communicate() drains stdout+stderr concurrently, so a child that
                # fills the stderr pipe buffer before exiting can't deadlock us.
                stdout_data, stderr_data = await proc.communicate()
                if proc.returncode != 0:
                    return (
                        stderr_data.decode("utf-8", errors="replace") or "claude failed",
                        False,
                    )
                return stdout_data.decode("utf-8", errors="replace"), True

            content, ok = await asyncio.wait_for(_exec(), timeout=ASYNC_INVOKE_TIMEOUT_S)
        except TimeoutError:
            content = f"session_invoke_async timed out after {ASYNC_INVOKE_TIMEOUT_S:.0f}s"
            ok = False
            # The docker exec ending leaves claude running in the container: stop
            # it there, or it goes on editing with nobody to report to.
            await stop_headless(container, run, started[0] if started else None,
                                "session_invoke_async_timed_out")
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- captured as failure
            content = f"session_invoke_async error: {exc}"
            ok = False
            await stop_headless(container, run, started[0] if started else None,
                                "session_invoke_async_failed_stopped")
        finally:
            headless.forget(run)

        log_event("tool_call", tool="session_invoke_async_complete", session=name, ok=ok)
        # Same delivery path, same instrumentation rationale as the watcher:
        # log the HTTP outcome (non-2xx included), timing, and the exception
        # type + repr so a failed callback says *why*, not just that it failed.
        content_len = len(content)
        start = time.monotonic()
        try:
            bearer = auth.load_token()
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

    com.fire(_run_and_notify())
    return com.envelope_ok(
        {"status": "running", "session": name, "conversation_id": conversation_id}
    )
