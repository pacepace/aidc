"""Typed facts about one session, read from its containers rather than parsed out of CLI text.

`aidc status` prints text for a person. An orchestrator that parsed it broke the
moment the wording moved: `audit_get` looked for an `audit:` line the CLI never
printed and failed every call. Each fact here comes from the container that holds
it: the taint flag from the policy sidecar, the audit dir from the audit sidecar's
mount, the repository from the dev container's environment.

Every call goes through :func:`run_backend`, the one seam tests replace; the commands come
from :mod:`aidc_mcp.backend`.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any

from aidc_mcp import audit, backend

# Where proxy/policy/policy.sh writes the flag, inside the policy sidecar.
TAINT_FILE = "/var/state/tainted"
# Where the user's server marks a session it froze (Kubernetes), beside the taint flag.
FROZEN_FILE = "/var/state/frozen"
# What last stopped the server from freezing it, while it is not frozen.
FREEZE_TROUBLE_FILE = "/var/state/freeze-trouble"
# Where the policy sidecar appends one JSON event per line.
POLICY_EVENTS_FILE = "/var/log/aidc/policy-events.log"
# Where the audit sidecar has the session's audit dir mounted.
AUDIT_MOUNT = "/var/aidc/audit"

_BACKEND_TIMEOUT_S = 20.0


@dataclass(frozen=True)
class BackendResult:
    returncode: int
    stdout: bytes
    stderr: bytes

    @property
    def err(self) -> str:
        return self.stderr.decode("utf-8", errors="replace")


async def run_backend(*args: str, timeout: float = _BACKEND_TIMEOUT_S) -> BackendResult:
    """Run the backend's program (`docker` or `kubectl`) with `args` and return its exit,
    stdout and stderr. One that cannot be started, or does not answer in time, is a failed call
    (exit -1), never a raise."""
    try:
        proc = await asyncio.create_subprocess_exec(
            backend.program(), *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as exc:
        return BackendResult(-1, b"", str(exc).encode())
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        said = f"{backend.program()} {args[0]} timed out after {timeout}s"
        return BackendResult(-1, b"", said.encode())
    return BackendResult(proc.returncode if proc.returncode is not None else -1, out, err)


def _missing_file(err: str) -> bool:
    """cat's own "No such file", as opposed to the container being missing."""
    return "no such file" in err.lower() and not backend.container_missing(err)


class TaintUnknown(Exception):
    """The taint flag could not be read: the policy sidecar did not answer."""


async def read_taint(name: str) -> dict[str, str] | None:
    """The session's taint as {at, trigger, domain}, or None when it is clean.

    :raises TaintUnknown: when the policy sidecar could not be asked
    """
    if backend.is_git_session(name):
        # The git agent has no sandbox to taint: no proxy sidecar, no policy (it is trusted).
        return None
    res = await run_backend(*backend.exec_args(backend.target(name, backend.ROLE_POLICY),
                                              ["cat", TAINT_FILE]))
    if res.returncode != 0:
        if _missing_file(res.err):
            return None
        raise TaintUnknown(res.err.strip() or f"{backend.program()} exec exited {res.returncode}")
    try:
        data = json.loads(res.stdout.decode("utf-8", errors="replace"))
    except ValueError:
        data = {}
    if not isinstance(data, dict):
        data = {}
    # A flag that exists is a taint whatever it holds: an unreadable payload still
    # means the policy sidecar marked the session.
    return {
        "at": str(data.get("tainted_at") or ""),
        "trigger": str(data.get("trigger") or "unknown"),
        "domain": str(data.get("domain") or ""),
    }


async def read_frozen(name: str) -> dict[str, Any] | None:
    """The mark the user's server left when it froze the session ({frozen_at, ...}), or None
    when it is not frozen.

    :raises TaintUnknown: when the policy sidecar could not be asked
    """
    res = await run_backend(*backend.exec_args(backend.target(name, backend.ROLE_POLICY),
                                              ["cat", FROZEN_FILE]))
    if res.returncode != 0:
        if _missing_file(res.err):
            return None
        raise TaintUnknown(res.err.strip() or f"{backend.program()} exec exited {res.returncode}")
    try:
        data = json.loads(res.stdout.decode("utf-8", errors="replace"))
    except ValueError:
        data = {}
    return data if isinstance(data, dict) else {}


async def mark_frozen(name: str, mark: dict[str, Any]) -> bool:
    """Write the frozen mark into the session's policy sidecar (whole, by rename)."""
    script = 'printf "%s\\n" "$1" > "$2.new" && mv -f "$2.new" "$2"'
    res = await run_backend(*backend.exec_args(
        backend.target(name, backend.ROLE_POLICY),
        ["sh", "-c", script, "aidc-freeze", json.dumps(mark, separators=(",", ":")),
         FROZEN_FILE]))
    return res.returncode == 0


async def taint_response(name: str) -> tuple[str | None, str]:
    """The session's taint response (log, notify or freeze; SEC-05) as its policy sidecar runs
    with it, and "" ; or None and why it could not be read."""
    tgt = backend.target(name, backend.ROLE_POLICY)
    res = await run_backend(*backend.env_workdir_args(tgt))
    if res.returncode != 0:
        return None, res.err.strip()[:300] or f"{backend.program()} exited {res.returncode}"
    env, _ = backend.env_and_workdir(res.stdout, tgt)
    return env.get("AIDC_TAINT_RESPONSE", "").strip() or "notify", ""


async def mark_freeze_trouble(name: str, trouble: dict[str, Any] | None) -> bool:
    """Leave what stops the session's freeze beside its taint flag, where `aidc status` reads
    it (FREEZE_TROUBLE_FILE), or remove it (None) once frozen."""
    if trouble is None:
        argv = ["rm", "-f", FREEZE_TROUBLE_FILE]
    else:
        argv = ["sh", "-c", 'printf "%s\\n" "$1" > "$2.new" && mv -f "$2.new" "$2"',
                "aidc-freeze-trouble", json.dumps(trouble, separators=(",", ":")),
                FREEZE_TROUBLE_FILE]
    res = await run_backend(*backend.exec_args(backend.target(name, backend.ROLE_POLICY), argv))
    return res.returncode == 0


async def taint_or_none(name: str) -> dict[str, str] | None:
    """read_taint for a report: an unreadable flag is logged and reported as None."""
    try:
        return await read_taint(name)
    except TaintUnknown as exc:
        audit.log_event("session_taint_unreadable", session=name, error=str(exc)[:300])
        return None


async def audit_dir(name: str) -> str | None:
    """Where the session's audit trail is: on Docker the host folder the audit sidecar mounts;
    on Kubernetes `pvc:<namespace>/<claim>`, the volume claim it mounts."""
    tgt = backend.target(name, backend.ROLE_AUDIT)
    res = await run_backend(*backend.mount_source_args(tgt, AUDIT_MOUNT))
    return backend.mount_source(res.stdout, tgt, AUDIT_MOUNT) if res.returncode == 0 else None


async def repo_path(name: str) -> str | None:
    """The repository the session's dev container works in: AIDC_REPO_PATH, else its
    working dir (compose sets both to the mounted repo)."""
    tgt = backend.target(name)
    res = await run_backend(*backend.env_workdir_args(tgt))
    if res.returncode != 0:
        return None
    env, workdir = backend.env_and_workdir(res.stdout, tgt)
    return env.get("AIDC_REPO_PATH", "").strip() or workdir or None


async def policy_events(name: str) -> list[dict[str, Any]]:
    """Every event the policy sidecar logged, oldest first; none when it logged none.

    :raises TaintUnknown: when the policy sidecar could not be asked
    """
    if backend.is_git_session(name):
        return []
    res = await run_backend(*backend.exec_args(backend.target(name, backend.ROLE_POLICY),
                                              ["cat", POLICY_EVENTS_FILE]))
    if res.returncode != 0:
        if _missing_file(res.err):
            return []
        raise TaintUnknown(res.err.strip() or f"{backend.program()} exec exited {res.returncode}")
    events: list[dict[str, Any]] = []
    for line in res.stdout.decode("utf-8", errors="replace").splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict):
            events.append(e)
    return events


async def dev_containers() -> list[dict[str, str]] | None:
    """Every session by its dev container: name, status, profile, started. None when
    docker did not answer."""
    res = await run_backend(*backend.dev_list_args())
    if res.returncode != 0:
        return None
    rows = backend.dev_rows(res.stdout)
    if not rows and backend.dev_list_args(by_name=True) != backend.dev_list_args():
        # Sessions made before the labels (Docker): their names say what they are.
        res = await run_backend(*backend.dev_list_args(by_name=True))
        if res.returncode != 0:
            return None
        rows = backend.dev_rows(res.stdout)
    return rows
