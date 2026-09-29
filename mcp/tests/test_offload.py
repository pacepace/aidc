"""Blocking tool and resource bodies run off the event loop.

FastMCP calls a synchronous tool or resource inline on the one event loop that
also runs transcript watchers and reply callbacks, so a body waiting on the aidc
CLI or `docker exec` froze all of them (60s and more while `aidc list` was slow).
"""

import asyncio
import inspect
import threading
import time

from mcp.server.fastmcp import FastMCP

from aidc_mcp import resources, tools

# Long enough that a stalled loop is unmistakable, short enough to keep a
# failing run quick.
STALL = 3.0


def _app():
    app = FastMCP("t")
    tools.register(app)
    resources.register(app)
    return app


def _blocking(release: threading.Event, result):
    """A stand-in for a CLI call that returns only once the loop sets `release`."""
    def run(*_args, **_kwargs):
        release.wait(STALL)
        return result
    return run


async def _call_while_loop_releases(call):
    """Await `call` while a coroutine on the loop releases it; return the elapsed time.
    If the call blocks the loop, the releasing coroutine cannot run until the
    blocking wait gives up."""
    release = threading.Event()

    async def release_from_loop():
        await asyncio.sleep(0.05)
        release.set()

    start = time.monotonic()
    result, _ = await asyncio.gather(call(release), release_from_loop())
    return result, time.monotonic() - start


async def test_session_list_does_not_stall_the_loop(monkeypatch):
    app = _app()

    async def call(release):
        monkeypatch.setattr(tools, "_run_cli", _blocking(
            release, {"exit": 0, "stdout": "SESSION\n", "stderr": ""}))
        return await app.call_tool("session_list", {})

    _, elapsed = await _call_while_loop_releases(call)
    assert elapsed < STALL / 2


async def test_session_status_does_not_stall_the_loop(monkeypatch):
    app = _app()

    async def call(release):
        monkeypatch.setattr(tools, "_run_cli", _blocking(
            release, {"exit": 0, "stdout": "ok", "stderr": ""}))
        return await app.call_tool("session_status", {"name": "proj"})

    _, elapsed = await _call_while_loop_releases(call)
    assert elapsed < STALL / 2


async def test_session_exec_does_not_stall_the_loop(monkeypatch):
    app = _app()

    class Done:
        returncode, stdout, stderr = 0, "hi", ""

    async def call(release):
        monkeypatch.setattr(tools.subprocess, "run", _blocking(release, Done()))
        return await app.call_tool("session_exec", {"name": "proj", "cmd": "echo hi"})

    _, elapsed = await _call_while_loop_releases(call)
    assert elapsed < STALL / 2


async def test_a_resource_does_not_stall_the_loop(monkeypatch):
    app = _app()

    async def call(release):
        monkeypatch.setattr(resources, "_run", _blocking(release, "SESSION\n"))
        return await app.read_resource("aidc://sessions")

    _, elapsed = await _call_while_loop_releases(call)
    assert elapsed < STALL / 2


def test_every_tool_and_resource_is_a_coroutine_function():
    """Derived from the registry: a synchronous tool or resource added later
    would run on the loop, and fails here."""
    app = _app()
    fns = {f"tool {n}": t.fn for n, t in app._tool_manager._tools.items()}
    fns.update({f"resource {r.uri}": r.fn for r in app._resource_manager._resources.values()})
    fns.update({f"resource {t.uri_template}": t.fn
                for t in app._resource_manager._templates.values()})
    sync = sorted(k for k, fn in fns.items() if not inspect.iscoroutinefunction(fn))
    assert sync == []
