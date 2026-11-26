"""A tainted session on Kubernetes: told by its policy sidecar, frozen by this server.

On Docker a session's policy sidecar pauses its dev container itself (SEC-05). On Kubernetes
the sidecar has no API token, so it pokes this server's taint webhook (W-M4, K8S-13's one
exception) and the server acts (plan-aidc-2.0 Q-K3): it reads the taint flag itself (a poke is
never trusted: it only says where to look), and when the session's response is `freeze` it
cuts every egress rule of the session's NetworkPolicies, so none of its pods reaches anything,
and marks it frozen beside the flag. A tainted session is never cleaned (SEC-06): a policy put
back by a later apply is cut again.

The poke can be lost (the server down, the network), so the server also looks at every
session's flag on its own, at start and every RECONCILE_S.

No MCP types here (test_service_boundary).
"""

from __future__ import annotations

import asyncio
import re
import time
from typing import Any

from aidc_mcp import audit, backend
from aidc_mcp import session_facts as sf
from aidc_mcp.service import common as com
from aidc_mcp.service import state as ss
from aidc_mcp.service import turns as tn

#: How often every session's flag is looked at, for a poke that never came.
RECONCILE_S = 60.0

#: A session name as aidc makes them (validate_session_name; DNS-label shaped on Kubernetes).
_SESSION = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")



def valid_session(name: Any) -> bool:
    return isinstance(name, str) and bool(_SESSION.match(name)) and not backend.is_git_session(name)


async def check(name: str) -> str:
    """Look at session `name`'s taint and act on it. Returns what was found: "clean",
    "tainted" (its response is not freeze), "frozen" (cut now or before), "freeze_failed",
    or "unknown" (the flag could not be read)."""
    lock = ss.taint_locks.setdefault(name, asyncio.Lock())
    async with lock:
        try:
            taint = await sf.read_taint(name)
        except sf.TaintUnknown as exc:
            await _trouble(name, "read_flag", str(exc), mark=False)
            return "unknown"
        if taint is None:
            ss.taint_reported.pop(name, None)
            ss.freeze_trouble.pop(name, None)
            return "clean"
        # Reported once per instance of the session: one killed and created again under
        # the name, and tainted again, is a new taint (state.LIFETIMES).
        _, instance = await tn.session_instance(name)
        if ss.taint_reported.get(name) != instance:
            ss.taint_reported[name] = instance
            audit.log_event("session_tainted", session=name, trigger=taint["trigger"],
                            domain=taint["domain"], at=taint["at"])
            com.session_changed(name)
        if not backend.server_freezes():
            return "tainted"
        response, why = await sf.taint_response(name)
        if response is None:
            await _trouble(name, "read_response", why)
            return "unknown"
        if response != "freeze":
            return "tainted"
        return await _freeze(name, taint)


async def _trouble(name: str, step: str, why: str, *, mark: bool = True) -> None:
    """A freeze that cannot go on: logged once until what stops it changes (the reconcile
    tries every minute), and left beside the flag for `aidc status` (when the sidecar can be
    reached at all)."""
    said = f"{step}: {why[:300]}"
    if ss.freeze_trouble.get(name) == said:
        return
    ss.freeze_trouble[name] = said
    audit.log_event("session_freeze_stalled", session=name, step=step, error=why[:300])
    if mark:
        await sf.mark_freeze_trouble(name, {
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "step": step,
            "error": why[:300]})


async def _freeze(name: str, taint: dict[str, str]) -> str:
    """Cut every egress rule the session's policies still have, then mark it frozen (once).
    Idempotent: a session already cut is left as it is; one a later apply opened again is
    cut again."""
    res = await sf.run_backend(*backend.session_policies_args(name))
    open_ = backend.egress_to_cut(res.stdout) if res.returncode == 0 else None
    if open_ is None:
        await _trouble(name, "read_policies", res.err.strip() or "unreadable listing")
        return "freeze_failed"
    failed = []
    for policy in open_:
        cut = await sf.run_backend(*backend.cut_egress_args(policy))
        if cut.returncode != 0:
            failed.append(f"{policy}: {cut.err.strip()[:200]}")
    if failed:
        await _trouble(name, "cut_egress", "; ".join(failed))
        return "freeze_failed"
    try:
        marked = await sf.read_frozen(name)
    except sf.TaintUnknown:
        marked = None
    if marked is None:
        mark = {"frozen_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "by": "aidc-mcp", "egress_cut": open_, "trigger": taint["trigger"],
                "domain": taint["domain"]}
        if not await sf.mark_frozen(name, mark):
            await _trouble(name, "mark", "the policy sidecar did not take the frozen mark")
            return "freeze_failed"
        audit.log_event("session_frozen", session=name, egress_cut=open_)
        com.session_changed(name)
        # Frozen now: a trouble left from before (by this process or one before a restart)
        # is stale.
        await sf.mark_freeze_trouble(name, None)
        ss.freeze_trouble.pop(name, None)
    else:
        if open_:
            audit.log_event("session_refrozen", session=name, egress_cut=open_)
        if ss.freeze_trouble.pop(name, None) is not None:
            await sf.mark_freeze_trouble(name, None)
    return "frozen"


def poked(name: str) -> None:
    """The taint webhook's work: look at the session soon (in the background, so the sidecar
    is answered at once)."""
    com.fire(check(name))


async def reconcile_once() -> None:
    """Look at every session's flag (the git agent has none)."""
    rows = await sf.dev_containers()
    if rows is None:
        audit.log_event("taint_reconcile_failed", reason="sessions_unlisted")
        return
    for row in rows:
        if valid_session(row.get("name")):
            await check(row["name"])


async def watch(interval: float = RECONCILE_S) -> None:
    """Reconcile now and every `interval` seconds, for the server's life."""
    while True:
        try:
            await reconcile_once()
        except Exception as exc:  # prawduct:allow prawduct/broad-except -- keep watching
            audit.log_event("taint_reconcile_failed", error_type=type(exc).__name__,
                            error=repr(exc)[:300])
        await asyncio.sleep(interval)
