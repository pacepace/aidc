"""Every per-session table of the service's in-memory state declares how long its entries
live, and the declared lifetimes are what the code does (service/state.py, LIFETIMES).

A session killed and created again under the same name must not inherit a fact about the
one before it: a table nobody clears is how that happens, so a new table that does not say
when it is cleared fails here."""
import asyncio
from collections.abc import MutableMapping, MutableSequence, MutableSet

import pytest

from aidc_mcp.service import state as ss


def _tables():
    return {name: value for name, value in vars(ss).items()
            if isinstance(value, (MutableMapping, MutableSet, MutableSequence))
            and not name.isupper()
            and not name.startswith("__")
            and name != "LIFETIMES"}


def test_no_module_keeps_a_table_the_lifetimes_do_not_name():
    """A table kept outside state.py is the one a session created again inherits without
    anyone noticing: every module of the package is read, and each of its tables must be
    state.py's or named in state.ELSEWHERE with its lifetime and why."""
    import importlib
    import pkgutil

    import aidc_mcp

    found = set()
    for info in pkgutil.walk_packages(aidc_mcp.__path__, "aidc_mcp."):
        if info.name in ("aidc_mcp.__main__", "aidc_mcp.service.state"):
            continue
        mod = importlib.import_module(info.name)
        for name, value in vars(mod).items():
            if (isinstance(value, (MutableMapping, MutableSet, MutableSequence))
                    and not name.isupper() and not name.startswith("__")
                    and getattr(value, "__module__", None) != "typing"):
                found.add(f"{info.name}.{name}")
    assert sorted(found - set(ss.ELSEWHERE)) == [], "declare these in state.ELSEWHERE"
    assert sorted(set(ss.ELSEWHERE) - found) == []
    for name, (kind, why) in ss.ELSEWHERE.items():
        assert kind in (ss.TASK, ss.KEPT, ss.PROCESS, ss.SESSION, ss.WATCH) and why, name


def test_every_table_declares_its_lifetime():
    undeclared = sorted(set(_tables()) - set(ss.LIFETIMES))
    assert undeclared == [], f"declare a lifetime in state.LIFETIMES for: {undeclared}"
    assert sorted(set(ss.LIFETIMES) - set(_tables())) == []


def test_kept_and_task_tables_say_why():
    for name, (kind, why) in ss.LIFETIMES.items():
        if kind in (ss.TASK, ss.KEPT, ss.PROCESS):
            assert why, f"{name}: say why it is {kind}, and what bounds it"


@pytest.mark.parametrize("name", [n for n, (k, _) in ss.LIFETIMES.items() if k == ss.SESSION])
def test_a_session_table_forgets_the_session_and_only_it(name, tmp_path, monkeypatch):
    monkeypatch.setattr(ss, "WATCHER_STATE_DIR", tmp_path)
    table = getattr(ss, name)
    for who in ("gone", "other"):
        if isinstance(table, dict):
            monkeypatch.setitem(table, who, object())
        else:
            table.add(who)
    try:
        ss.forget_session_send_state("gone")
        assert "gone" not in table and "other" in table
    finally:
        if isinstance(table, set):
            table.discard("other")


@pytest.mark.parametrize("name", [n for n, (k, _) in ss.LIFETIMES.items() if k == ss.WATCH])
def test_a_watch_table_drops_the_ended_watch_and_only_it(name, monkeypatch):
    table = getattr(ss, name)
    keys = [("gone", "c1"), ("gone", "c2", "x"), ("other", "c1")]
    for key in keys:
        if isinstance(table, dict):
            monkeypatch.setitem(table, key, object())
        else:
            table.add(key)
    try:
        ss.evict_session_state("gone")
        assert [k for k in keys if k in table] == [("other", "c1")]
    finally:
        if isinstance(table, set):
            table.discard(("other", "c1"))


def test_a_held_invoke_lock_survives_forget_and_a_free_one_goes(tmp_path, monkeypatch):
    monkeypatch.setattr(ss, "WATCHER_STATE_DIR", tmp_path)

    async def run():
        held, free = asyncio.Lock(), asyncio.Lock()
        await held.acquire()
        monkeypatch.setitem(ss.invoke_locks, "busy", held)
        monkeypatch.setitem(ss.invoke_locks, "idle", free)
        ss.forget_session_send_state("busy")
        ss.forget_session_send_state("idle")
        assert "busy" in ss.invoke_locks and "idle" not in ss.invoke_locks
        held.release()
    asyncio.run(run())
