"""Typed facts about one session, read from docker rather than parsed out of CLI text.

`aidc status` prints text for a person. An orchestrator that parsed it broke the
moment the wording moved: `audit_get` looked for an `audit:` line the CLI never
printed and failed every call. Each fact here comes from the container that holds
it: the taint flag from the policy sidecar, the audit dir from the audit sidecar's
mount, the repository from the dev container's environment.

Every docker call goes through :func:`run_docker`, the one seam tests replace.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any

from aidc_mcp.audit import log_event

# Where proxy/policy/policy.sh writes the flag, inside the policy sidecar.
TAINT_FILE = "/var/state/tainted"
# Where the policy sidecar appends one JSON event per line.
POLICY_EVENTS_FILE = "/var/log/aidc/policy-events.log"
# Where the audit sidecar has the session's audit dir mounted.
AUDIT_MOUNT = "/var/aidc/audit"

_DOCKER_TIMEOUT_S = 20.0


@dataclass(frozen=True)
class DockerResult:
    returncode: int
    stdout: bytes
    stderr: bytes

    @property
    def err(self) -> str:
        return self.stderr.decode("utf-8", errors="replace")


async def run_docker(*args: str, timeout: float = _DOCKER_TIMEOUT_S) -> DockerResult:
    """Run `docker <args>` and return its exit, stdout and stderr. A docker that cannot
    be started, or does not answer in time, is a failed call (exit -1), never a raise."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "docker", *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as exc:
        return DockerResult(-1, b"", str(exc).encode())
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        return DockerResult(-1, b"", f"docker {args[0]} timed out after {timeout}s".encode())
    return DockerResult(proc.returncode if proc.returncode is not None else -1, out, err)


def _missing_file(err: str) -> bool:
    """cat's own "No such file", as opposed to docker's "No such container"."""
    low = err.lower()
    return "no such file" in low and "no such container" not in low


class TaintUnknown(Exception):
    """The taint flag could not be read: the policy sidecar did not answer."""


async def read_taint(name: str) -> dict[str, str] | None:
    """The session's taint as {at, trigger, domain}, or None when it is clean.

    :raises TaintUnknown: when the policy sidecar could not be asked
    """
    res = await run_docker("exec", f"aidc-{name}-policy", "cat", TAINT_FILE)
    if res.returncode != 0:
        if _missing_file(res.err):
            return None
        raise TaintUnknown(res.err.strip() or f"docker exec exited {res.returncode}")
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


async def taint_or_none(name: str) -> dict[str, str] | None:
    """read_taint for a report: an unreadable flag is logged and reported as None."""
    try:
        return await read_taint(name)
    except TaintUnknown as exc:
        log_event("session_taint_unreadable", session=name, error=str(exc)[:300])
        return None


async def audit_dir(name: str) -> str | None:
    """The session's audit dir on the HOST: the source of the audit sidecar's mount."""
    res = await run_docker(
        "inspect", f"aidc-{name}-audit", "--format",
        "{{range .Mounts}}{{if eq .Destination \"" + AUDIT_MOUNT + "\"}}{{.Source}}{{end}}{{end}}")
    path = res.stdout.decode("utf-8", errors="replace").strip()
    return path if res.returncode == 0 and path else None


async def repo_path(name: str) -> str | None:
    """The repository the session's dev container works in: AIDC_REPO_PATH, else its
    working dir (compose sets both to the mounted repo)."""
    res = await run_docker(
        "inspect", f"aidc-{name}-dev", "--format",
        "{{range .Config.Env}}{{println .}}{{end}}\x1f{{.Config.WorkingDir}}")
    if res.returncode != 0:
        return None
    env, _, workdir = res.stdout.decode("utf-8", errors="replace").partition("\x1f")
    for line in env.splitlines():
        if line.startswith("AIDC_REPO_PATH="):
            value = line.split("=", 1)[1].strip()
            if value:
                return value
    return workdir.strip() or None


async def policy_events(name: str) -> list[dict[str, Any]]:
    """Every event the policy sidecar logged, oldest first; none when it logged none.

    :raises TaintUnknown: when the policy sidecar could not be asked
    """
    res = await run_docker("exec", f"aidc-{name}-policy", "cat", POLICY_EVENTS_FILE)
    if res.returncode != 0:
        if _missing_file(res.err):
            return []
        raise TaintUnknown(res.err.strip() or f"docker exec exited {res.returncode}")
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
    fmt = "{{.Names}}\t{{.Status}}\t{{.Label \"aidc.profile\"}}\t{{.CreatedAt}}"
    res = await run_docker("ps", "-a", "--filter", "label=aidc.role=dev", "--format", fmt)
    if res.returncode != 0:
        return None
    text = res.stdout.decode("utf-8", errors="replace")
    if not text.strip():
        # Sessions made before the labels: their names say what they are.
        res = await run_docker("ps", "-a", "--filter", "name=^aidc-.*-dev$", "--format", fmt)
        if res.returncode != 0:
            return None
        text = res.stdout.decode("utf-8", errors="replace")
    rows = []
    for line in text.splitlines():
        parts = line.split("\t")
        if not parts or not parts[0].startswith("aidc-") or not parts[0].endswith("-dev"):
            continue
        parts += [""] * (4 - len(parts))
        rows.append({"name": parts[0][len("aidc-"):-len("-dev")], "status": parts[1],
                     "profile": parts[2] or "?", "started": parts[3]})
    return rows
