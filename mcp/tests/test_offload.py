"""Blocking tool and resource bodies run off the event loop.

A body waiting on the aidc CLI or `docker exec`, run inline on the one event loop
that also runs transcript watchers and reply callbacks, freezes all of them (60s
and more while `aidc list` is slow).
"""

import ast
import asyncio
import importlib
import inspect
import pkgutil
import textwrap
import threading
import time

from mcp.server.mcpserver import MCPServer

from aidc_mcp import resources, tools
from aidc_mcp.service import common as com

# Long enough that a stalled loop is unmistakable, short enough to keep a
# failing run quick.
STALL = 3.0


def _app():
    app = MCPServer("t")
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
        monkeypatch.setattr(com, "run_cli", _blocking(
            release, {"exit": 0, "stdout": "SESSION\n", "stderr": ""}))
        return await app.call_tool("session_list", {})

    _, elapsed = await _call_while_loop_releases(call)
    assert elapsed < STALL / 2


async def test_session_status_does_not_stall_the_loop(monkeypatch, idle_session):
    app = _app()

    async def call(release):
        monkeypatch.setattr(com, "run_cli", _blocking(
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


def _modules():
    """tools and every service module: where the tools' bodies and their helpers live."""
    import aidc_mcp.service as service
    return [tools] + [importlib.import_module(f"aidc_mcp.service.{m.name}")
                      for m in pkgutil.iter_modules(service.__path__)]


def _loop_owned_state():
    """Every module-level dict, list or set in tools and the service, as (module, name):
    the per-session state the event loop's watchers, drainers and senders mutate."""
    return {(m.__name__, n) for m in _modules() for n, v in vars(m).items()
            if not n.startswith("__") and isinstance(v, (dict, list, set))}


def _names_reached(fn, seen):
    """Module-level names (module, name) a function's body uses, following calls into
    other module-level functions of tools and the service, whether called bare
    (`helper()`) or through a module alias (`ss.helper()`), so state reached through a
    helper in another module counts too."""
    module = inspect.getmodule(fn)
    known = {m.__name__ for m in _modules()}
    tree = ast.parse(textwrap.dedent(inspect.getsource(fn)))
    out = set()

    def reach(owner, name):
        out.add((owner.__name__, name))
        target = vars(owner).get(name)
        if inspect.isfunction(target) and target.__module__ == owner.__name__ \
                and (owner.__name__, name) not in seen:
            seen.add((owner.__name__, name))
            out.update(_names_reached(target, seen))

    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            reach(module, node.id)
        elif isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
            other = vars(module).get(node.value.id)
            if inspect.ismodule(other) and other.__name__ in known:
                reach(other, node.attr)
    return out


def test_off_loop_bodies_touch_no_state_the_loop_owns():
    """off_loop runs a body in a worker thread. A body reading or changing state the
    loop also changes (the send queues, watcher tables) would race it."""
    app = _app()
    owned = _loop_owned_state()
    # the derivation still finds the state it guards
    assert ("aidc_mcp.service.state", "pending_sends") in owned
    fns = [t.fn for t in app._tool_manager._tools.values()]
    fns += [r.fn for r in app._resource_manager._resources.values()]
    fns += [t.fn for t in app._resource_manager._templates.values()]
    offloaded = [f for f in fns if getattr(f, "runs_off_loop", False)]
    assert offloaded, "no off_loop tool found; the check would pass vacuously"
    touching = {f.__name__: sorted(_names_reached(inspect.unwrap(f), set()) & owned)
                for f in offloaded}
    assert {k: v for k, v in touching.items() if v} == {}
