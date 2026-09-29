"""Blocking tool and resource bodies run off the event loop.

FastMCP calls a synchronous tool or resource inline on the one event loop that
also runs transcript watchers and reply callbacks, so a body waiting on the aidc
CLI or `docker exec` froze all of them (60s and more while `aidc list` was slow).
"""

import ast
import asyncio
import inspect
import textwrap
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
    # Fix a failure here with @off_loop only if the body touches none of the state the
    # event loop owns (the next test); otherwise make the tool async and await its
    # blocking part with asyncio.to_thread, as session_status does.
    assert sync == []


def _loop_owned_state():
    """Every module-level dict, list or set in tools: the per-session state the
    event loop's watchers, drainers and senders mutate."""
    return {n for n, v in vars(tools).items()
            if n.startswith("_") and isinstance(v, (dict, list, set))}


def _names_reached(fn, module_funcs, seen):
    """Global names a function's body uses, following calls into other module-level
    functions of tools, so state reached through a helper counts too."""
    tree = ast.parse(textwrap.dedent(inspect.getsource(fn)))
    out = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            out.add(node.id)
            if node.id in module_funcs and node.id not in seen:
                seen.add(node.id)
                out |= _names_reached(module_funcs[node.id], module_funcs, seen)
    return out


def test_off_loop_bodies_touch_no_state_the_loop_owns():
    """off_loop runs a body in a worker thread. A body reading or changing state the
    loop also changes (the send queues, watcher tables) would race it."""
    app = _app()
    module_funcs = {n: f for n, f in vars(tools).items()
                    if inspect.isfunction(f) and f.__module__ == tools.__name__}
    owned = _loop_owned_state()
    assert "_pending_sends" in owned  # the derivation still finds the state it guards
    fns = [t.fn for t in app._tool_manager._tools.values()]
    fns += [r.fn for r in app._resource_manager._resources.values()]
    fns += [t.fn for t in app._resource_manager._templates.values()]
    offloaded = [f for f in fns if getattr(f, "runs_off_loop", False)]
    assert offloaded, "no off_loop tool found; the check would pass vacuously"
    touching = {f.__name__: sorted(_names_reached(inspect.unwrap(f), module_funcs, set()) & owned)
                for f in offloaded}
    assert {k: v for k, v in touching.items() if v} == {}
