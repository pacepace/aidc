"""Headless `claude --print` runs in a session: session_invoke and session_invoke_async.

2026-10-22, metallm: two such runs were still going 23 and 9 minutes after their
callers gave up, both editing the same spec file, and nothing the orchestrator could
call showed them. So every run the MCP starts is tagged, inside the container, with an
environment variable naming it (RUN_ENV). Every process the run starts inherits it,
which is what lets the MCP find and stop the whole process tree in the container,
not only its own `docker exec`. The MCP also lists the runs it started, and reads the
container for `claude --print` processes, so a run left over from before an MCP
restart (or started by anything else) is shown as well.

A headless run never resumes the session's conversation: the MCP passes
AIDC_CLAUDE_RESUME=false, which every image's aidc-claude wrapper honours, and the
wrapper itself no longer adds --continue to a --print run.
"""

from __future__ import annotations

import asyncio
import secrets
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from aidc_mcp import turns_view as tv

RUN_ENV = "AIDC_HEADLESS_RUN"
PROMPT_PREVIEW = 120
# How long a stopped run's processes get to exit on SIGTERM before SIGKILL.
_TERM_GRACE_S = 3


@dataclass
class Run:
    """A headless run this MCP process started."""

    run_id: str
    session: str
    tool: str
    prompt: str
    started_at: float = field(default_factory=time.time)


# In memory only: a run's own task is what reports it, and that task does not survive
# a restart either. The container is the durable record (container_runs).
_runs: dict[str, Run] = {}


def new_run(session: str, tool: str, prompt: str) -> Run:
    run = Run(run_id=f"{tool}-{secrets.token_hex(6)}", session=session, tool=tool,
              prompt=prompt)
    _runs[run.run_id] = run
    return run


def forget(run: Run) -> None:
    _runs.pop(run.run_id, None)


def runs_of(session: str) -> list[Run]:
    return [r for r in _runs.values() if r.session == session]


def exec_argv(container: str, run: Run) -> list[str]:
    """The docker exec that starts `run`: fresh (no --continue), and tagged."""
    return ["docker", "exec", "-u", "vscode", "-e", "AIDC_CLAUDE_RESUME=false",
            "-e", f"{RUN_ENV}={run.run_id}", container, "aidc-claude", "--print", run.prompt]


def _iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, UTC).isoformat(timespec="seconds").replace(
        "+00:00", "Z")


def _preview(prompt: str) -> str:
    return tv.redact(" ".join(prompt.split()))[:PROMPT_PREVIEW]


def tracked(session: str) -> list[dict[str, Any]]:
    """The runs this MCP started in `session` and has not seen end, for a caller."""
    return [_record(r) for r in sorted(runs_of(session), key=lambda r: r.started_at)]


def _record(run: Run, pid: int | None = None) -> dict[str, Any]:
    return {"run_id": run.run_id, "started_at": _iso(run.started_at), "tool": run.tool,
            "prompt": _preview(run.prompt), "pid": pid, "orphan": False}


# Lists every `claude --print` (or `-p`) process in the container as NUL-separated
# records: pid, seconds running, the RUN_ENV value ("" when untagged), the prompt.
# Read from /proc so the prompt is the exact argument, not ps's lossy rendering.
_LIST_SCRIPT = r'''
for d in /proc/[0-9]*; do
  mapfile -d '' -t a < "$d/cmdline" 2>/dev/null || continue
  [ "${#a[@]}" -gt 1 ] && [ "${a[0]##*/}" = claude ] || continue
  p="" found=0
  for ((i = 1; i < ${#a[@]}; i++)); do
    if [ "${a[i]}" = --print ] || [ "${a[i]}" = -p ]; then found=1; p="${a[i+1]:-}"; break; fi
  done
  [ "$found" = 1 ] || continue
  run=""
  if mapfile -d '' -t e < "$d/environ" 2>/dev/null; then
    for v in "${e[@]}"; do
      case "$v" in "$RUN_ENV="*) run="${v#"$RUN_ENV="}" ;; esac
    done
  fi
  pid="${d#/proc/}"
  et="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
  printf '%s\0%s\0%s\0%s\0' "$pid" "${et:-0}" "$run" "$p"
done
'''

# Stops every process carrying RUN_ENV=$1: SIGTERM, then SIGKILL for any left after
# the grace. Prints the pids it signalled, one per line.
_KILL_SCRIPT = r'''
want="$RUN_ENV=$1"
pids=()
for d in /proc/[0-9]*; do
  mapfile -d '' -t e < "$d/environ" 2>/dev/null || continue
  for v in "${e[@]}"; do
    if [ "$v" = "$want" ]; then pids+=("${d#/proc/}"); break; fi
  done
done
[ "${#pids[@]}" -eq 0 ] && exit 0
kill -TERM "${pids[@]}" 2>/dev/null
alive=("${pids[@]}")
for _ in $(seq "$2"); do
  sleep 1
  left=()
  for p in "${alive[@]}"; do kill -0 "$p" 2>/dev/null && left+=("$p"); done
  alive=("${left[@]}")
  [ "${#alive[@]}" -eq 0 ] && break
done
[ "${#alive[@]}" -gt 0 ] && kill -KILL "${alive[@]}" 2>/dev/null
printf '%s\n' "${pids[@]}"
'''


# Stops the process $1 and every process below it: for a headless claude that carries
# no RUN_ENV (one started before this server tagged its runs). SIGTERM, the grace
# ($2 s), then SIGKILL. Prints the pids it signalled.
_KILL_TREE_SCRIPT = r'''
pids=("$1")
while :; do
  more=()
  while read -r pid ppid; do
    for p in "${pids[@]}"; do
      if [ "$ppid" = "$p" ]; then
        case " ${pids[*]} ${more[*]} " in *" $pid "*) ;; *) more+=("$pid") ;; esac
      fi
    done
  done < <(ps -eo pid=,ppid=)
  [ "${#more[@]}" -eq 0 ] && break
  pids+=("${more[@]}")
done
kill -0 "$1" 2>/dev/null || exit 0
kill -TERM "${pids[@]}" 2>/dev/null
alive=("${pids[@]}")
for _ in $(seq "$2"); do
  sleep 1
  left=()
  for p in "${alive[@]}"; do kill -0 "$p" 2>/dev/null && left+=("$p"); done
  alive=("${left[@]}")
  [ "${#alive[@]}" -eq 0 ] && break
done
[ "${#alive[@]}" -gt 0 ] && kill -KILL "${alive[@]}" 2>/dev/null
printf '%s\n' "${pids[@]}"
'''


async def _docker(*args: str, timeout: float = 20.0) -> tuple[int, bytes]:
    try:
        proc = await asyncio.create_subprocess_exec(
            "docker", *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    except OSError:
        return -1, b""
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        return -1, b""
    return proc.returncode or 0, out


def parse_listing(raw: bytes, now: float) -> list[dict[str, Any]]:
    """_LIST_SCRIPT's output as {pid, started_at, run_id, prompt} records."""
    fields = raw.decode("utf-8", errors="replace").split("\0")
    out: list[dict[str, Any]] = []
    for i in range(0, len(fields) - 3, 4):
        pid, secs, run_id, prompt = fields[i:i + 4]
        if not pid.isdigit():
            continue
        try:
            started = now - float(secs or 0)
        except ValueError:
            started = now
        out.append({"pid": int(pid), "started_at": started, "run_id": run_id,
                    "prompt": prompt})
    return out


async def container_runs(container: str) -> list[dict[str, Any]] | None:
    """Every headless claude process in the container, or None when docker could not
    say (the container is down, or docker did not answer)."""
    rc, out = await _docker("exec", "-u", "vscode", "-e", f"RUN_ENV={RUN_ENV}", container,
                            "bash", "-c", _LIST_SCRIPT)
    if rc != 0:
        return None
    return parse_listing(out, time.time())


def merge(session: str, found: list[dict[str, Any]] | None) -> list[dict[str, Any]]:
    """What session_status shows as headless_runs: each process found in the container,
    marked orphan when no request of this MCP is waiting on it, plus each run this MCP
    started that the container does not show (yet, or docker could not say)."""
    mine = {r.run_id: r for r in runs_of(session)}
    out: list[dict[str, Any]] = []
    for proc in found or []:
        run = mine.pop(proc["run_id"], None) if proc["run_id"] else None
        if run is not None:
            out.append(_record(run, proc["pid"]))
            continue
        tool = proc["run_id"].rsplit("-", 1)[0] if proc["run_id"] else None
        out.append({"run_id": proc["run_id"] or None, "started_at": _iso(proc["started_at"]),
                    "tool": tool, "prompt": _preview(proc["prompt"]), "pid": proc["pid"],
                    "orphan": True})
    out += [_record(r) for r in mine.values()]
    return sorted(out, key=lambda r: r["started_at"])


async def stop(container: str, run: Run) -> list[int]:
    """Stop every process of `run` in the container. The pids signalled; [] when none
    was found (it had ended) or docker could not be reached."""
    return await stop_tagged(container, run.run_id)


async def stop_tagged(container: str, run_id: str) -> list[int]:
    """Stop every process in the container carrying RUN_ENV=run_id."""
    rc, out = await _docker("exec", "-u", "vscode", "-e", f"RUN_ENV={RUN_ENV}", container,
                            "bash", "-c", _KILL_SCRIPT, "kill-run", run_id,
                            str(_TERM_GRACE_S), timeout=_TERM_GRACE_S + 20.0)
    return _pids(rc, out)


async def stop_tree(container: str, pid: int) -> list[int]:
    """Stop the process `pid` in the container and everything below it."""
    rc, out = await _docker("exec", "-u", "vscode", container, "bash", "-c",
                            _KILL_TREE_SCRIPT, "kill-tree", str(pid), str(_TERM_GRACE_S),
                            timeout=_TERM_GRACE_S + 20.0)
    return _pids(rc, out)


def _pids(rc: int, out: bytes) -> list[int]:
    if rc != 0:
        return []
    return [int(p) for p in out.decode().split() if p.isdigit()]
