"""Session operations behind the tools: create, MCP hand-over, list, status, exec, files,
audit, transcript and interrupt.

No MCP types here (test_service_boundary): the tools in tearstools/ adapt it.
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from aidc_mcp import audit, backend, headless, repo, scope, session_mcp
from aidc_mcp import session_facts as sf
from aidc_mcp import turns_view as tv
from aidc_mcp.service import common as com
from aidc_mcp.service import config as orc
from aidc_mcp.service import delivery as dlv
from aidc_mcp.service import invoke as inv
from aidc_mcp.service import repos as rps
from aidc_mcp.service import sending as snd
from aidc_mcp.service import state as ss
from aidc_mcp.service import tmux as tmx
from aidc_mcp.service import turns as tn


def under(parent: str, path: str) -> bool:
    """Whether `path` is `parent` or inside it, with no `..` left in either. Used to
    keep a caller's paths inside the one tree the operator exposed to this server."""
    try:
        root = Path(parent).resolve()
        candidate = Path(path).resolve()
    except (OSError, ValueError, RuntimeError):
        return False
    return candidate == root or root in candidate.parents


# Tools that talk to a session by `name` and therefore advertise which sessions
# currently have an open webhook.
# How many policy events audit_get returns at most (the newest).
AUDIT_EVENTS_MAX = 500


# What a session's Claude is told about the MCP server it was handed, by when it can
# use it. A running Claude Code loads its servers when it starts; a token is read again
# whenever a call is refused, so a new token for a server it already has needs nothing.
_MCP_LIVE = ("Claude in the session reads the new token when the server next refuses the old "
             "one, or when it next connects: no restart is needed.")


_MCP_ON_START = "Claude is not running in the session; it loads the server when it starts."


_MCP_NEEDS_RESTART = ("Claude was already running in the session, and it loads its MCP servers "
                      "when it starts: the server is there after Claude restarts in the session "
                      "('aidc restart {name}'). Later tokens for this server need no restart.")


def session_mcp_refusal(exc: session_mcp.SessionMcpError) -> dict[str, Any]:
    """The failure envelope for a server that was not handed over. Each code is written
    out: the set of codes is a contract (ERROR_CODES), checked from this file's source."""
    said = str(exc)
    if exc.code == "invalid_argument":
        return com.envelope_err(said, code="invalid_argument")
    if exc.code == "not_configured":
        # Its one cause is a missing callback URL; say where a misplaced one sits.
        return com.envelope_err(orc.callback_url_unset(), code="not_configured")
    if exc.code == "no_such_session":
        return com.envelope_err(said, code="no_such_session")
    if exc.code == "session_not_ready":
        return com.envelope_err(said, code="session_not_ready")
    if exc.code == "timeout":
        return com.envelope_err(said, code="timeout")
    return com.envelope_err(said, code="command_failed")


async def hand_session_mcp(name: str, server: str, path: str, bearer: str) -> dict[str, Any]:
    """Write the MCP server into the session's Claude state (session_mcp.hand) and say
    when its Claude can use it. An envelope; the token is in neither it nor the log."""
    try:
        handed = await asyncio.to_thread(
            session_mcp.hand, name, server=server, path=path, bearer=bearer,
            base_url=orc.orchestrator_callback_url())
    except session_mcp.SessionMcpError as exc:
        # Nothing the caller gave is logged on a refusal: an argument in the wrong
        # place could be the token.
        audit.log_event("tool_call", tool="session_mcp_set", session=name, ok=False,
                  error_code=exc.code)
        return session_mcp_refusal(exc)
    running = await tmx.is_claude_running(backend.target(name))
    needs_restart = handed.entry == session_mcp.ENTRY_ADDED and running
    applies = (_MCP_NEEDS_RESTART.format(name=name) if needs_restart
               else _MCP_LIVE if running else _MCP_ON_START)
    audit.log_event("tool_call", tool="session_mcp_set", session=name, server=handed.server,
              url=handed.url, entry=handed.entry, needs_claude_restart=needs_restart)
    return com.envelope_ok({"session": name, "server": handed.server, "url": handed.url,
                         "entry": handed.entry, "needs_claude_restart": needs_restart,
                         "applies": applies})


async def session_report(name: str) -> dict[str, Any]:
    """What the session is doing, beside what it is: taint, where its audit trail and
    repository are, its branch, and whether its coding agent is working on a turn.
    Container health is not activity; `working` is."""
    container = backend.target(name)
    state, taint, audit, repo_dir = await asyncio.gather(
        tn.session_state(container, name), sf.taint_or_none(name), sf.audit_dir(name),
        sf.repo_path(name))
    branch = head = None
    if repo_dir is not None:
        branch, head = await asyncio.gather(repo.current_branch(name, repo_dir),
                                            repo.head(name, repo_dir))
    objs, _, _ = tn.session_transcript(name)
    working = state.claude_running and state.turn == tn.TURN_RUNNING
    outdated = ({"note": "This session predates aidc 2.0's hook events, so whether its "
                         f"agent is working cannot be told. {tn.outdated_remedy(name)}"}
                if state.turn == tn.TURN_UNKNOWN else {})
    return {
        **outdated,
        "tainted": taint,
        "audit_dir": audit,
        "repo": repo_dir,
        "branch": branch,
        "head": head,
        "claude_running": state.claude_running,
        "working": working,
        "turn": state.turn,
        "why": state.why,
        # The first-launch screen Claude shows instead of its input box (trust_prompt), only
        # while it shows one: it waits for a person, and the bare why does not say which.
        **({"dialog": state.screen.dialog}
           if state.screen is not None and state.screen.dialog else {}),
        # What the open turn is: what opened it, since when, its newest step. Read
        # from the transcript only while the agent is working, so an idle session
        # names no work.
        **(tv.turn_info(objs) if working else tv.NO_TURN),
        "last_reply_at": tv.last_reply_at(objs),
        "watched_conversation_id": dlv.watched_conversation(name) or None,
        "claude_account": claude_account(name),
    }


#: The file a cluster session's status line leaves in its mirror folder for the MCP
#: (.devcontainer/claude-usage.sh): the account broker's account for it and its notice.
CLAUDE_ACCOUNT_FILE = "claude-account.json"


def claude_account(name: str) -> dict[str, Any] | None:
    """The session's Claude account as its account broker gave it ({account, notice, at}),
    from its mirror folder; None where no broker manages the session, or the file cannot be
    read. `notice` is what needs the user: a switch waiting, a failing renewal, no account
    that can be used."""
    try:
        doc = json.loads((Path(ss.TRANSCRIPTS_BASE) / name / CLAUDE_ACCOUNT_FILE)
                         .read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or not isinstance(doc.get("account"), str):
        return None
    notice, at = doc.get("notice"), doc.get("at")
    return {"account": doc["account"],
            "notice": notice if isinstance(notice, str) and notice else None,
            "at": at if isinstance(at, str) else None}


#: How long a create may take with no progress to report: a cluster create waits up to five
#: minutes for the session's proxy and ten for its dev pod (scripts/k8s/session-create.sh).
CREATE_TIMEOUT_S = {backend.DOCKER: 300.0, backend.KUBERNETES: 960.0}


def _create_backend_of(args: list[str]) -> str:
    """The backend a create's arguments name (session_create always passes --backend): a
    Docker-hosted server may create on the cluster when the config says so."""
    named = args[args.index("--backend") + 1] if "--backend" in args[:-1] else ""
    return backend.KUBERNETES if backend.is_kubernetes(named) else backend.DOCKER


async def create_session(
    name: str, args: list[str], progress: Callable[[str], Awaitable[Any]] | None,
    wants_mcp: bool, mcp_server: str,
    mcp_path: str, mcp_bearer: str,
) -> dict[str, Any]:
    """Run the CLI create session_create built, then hand the session its MCP server."""
    # The first that a line holds names its phase: Docker's compose lines, then the cluster's
    # create (scripts/k8s/session-create.sh), whose waits come before the generic one.
    phases = {
        "Container aidc-":             "container",
        "Waiting":                     "waiting",
        "Healthy":                     "healthy",
        "Started":                     "started",
        "creating session":            "creating",
        "waiting for the proxy":       "proxy",
        "waiting for the dev pod":     "dev pod",
        "is ready":                    "ready",
        "waiting for":                 "wait",
    }
    if progress is not None:
        result = await com.run_cli_streaming(args, progress, phases)
    else:
        result = com.run_cli(args, timeout=CREATE_TIMEOUT_S[_create_backend_of(args)])
    if result["exit"] != 0:
        return com.envelope_err(result["stderr"] or result["stdout"] or "create failed", result,
                                code="cli_failed")
    created: dict[str, Any] = {"name": name, "log": result["stdout"]}
    if wants_mcp:
        # After the create, never before: the session's first start installs its
        # Claude state from a seed with every mcpServers entry stripped, and the
        # server is written into the installed state.
        created["mcp"] = await hand_session_mcp(name, mcp_server, mcp_path, mcp_bearer)
    com.session_changed(name)
    return com.envelope_ok(created)


async def create(
    name: str,
    profile: str = "multi",
    repo: str = "",
    workspace: str | None = None,
    mcp_server: str = "",
    mcp_path: str = "",
    mcp_bearer: str = "",
    *,
    progress: Callable[[str], Awaitable[Any]] | None = None,
) -> dict[str, Any]:
    """The session_create tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    wants_mcp = bool(mcp_server or mcp_path or mcp_bearer)
    if wants_mcp:
        # Checked before anything is created: a session made and then refused its
        # server would be a session the caller has to find out about and remove.
        try:
            session_mcp.check(mcp_server, mcp_path, mcp_bearer, orc.orchestrator_callback_url())
        except session_mcp.SessionMcpError as exc:
            return session_mcp_refusal(exc)
    if (why := scope.create_refusal()) is not None:
        audit.log_event("tool_call", tool="session_create", session=name, refused="out_of_scope")
        return com.envelope_err(why, code="create_not_allowed")
    # The backend the CLI will create on, decided here and passed to it explicitly, so
    # the arguments built below are the ones that backend takes.
    create_backend = backend.create_backend()
    if backend.is_kubernetes(create_backend):
        if repo or workspace:
            audit.log_event("tool_call", tool="session_create", session=name,
                      refused="repo_on_kubernetes")
            return com.envelope_err(
                "the configured backend is kubernetes, where a session is not given a "
                "repo: it sees the user's whole disk. Add the repo with `aidc repo add "
                "<owner/name>` and have the session make its own worktree in it (git "
                "worktree add); call session_create again without repo and workspace",
                code="invalid_argument")
        args = ["create", name, "--profile", profile, "--backend", create_backend]
        audit.log_event("tool_call", tool="session_create", session=name, profile=profile,
                  backend=create_backend)
        return await create_session(name, args, progress, wants_mcp, mcp_server, mcp_path,
                                    mcp_bearer)
    if not repo:
        return com.envelope_err("repo argument is required (absolute host path)",
                                code="invalid_argument")
    # `repo` and `workspace` become HOST bind mounts in the new session, but this
    # server checks them against its own filesystem. Inside aidc-mcp those
    # namespaces differ: /mnt, /srv, /opt and /tmp exist in the image, so a caller
    # naming one would have had the HOST's directory mounted read-write into the
    # session it just created (on WSL2 /mnt is every Windows drive). The operator
    # exposed one tree — their home — so that is the only tree a caller may name.
    exposed = os.environ.get("AIDC_HOST_HOME", "")
    if exposed:
        for label, value in (("repo", repo), ("workspace", workspace or "")):
            if value and not under(exposed, value):
                audit.log_event("tool_call", tool="session_create", session=name,
                          refused="path_not_allowed", path=value)
                return com.envelope_err(
                    f"{label} must be inside {exposed} (the directory this server was "
                    f"given); '{value}' is outside it", code="path_not_allowed")
    args = ["create", name, "--profile", profile, "--repo", repo]
    if workspace:
        args += ["--workspace", workspace]
    args += ["--backend", create_backend]
    audit.log_event("tool_call", tool="session_create", session=name, profile=profile, repo=repo)
    return await create_session(name, args, progress, wants_mcp, mcp_server, mcp_path,
                                mcp_bearer)


async def list_sessions() -> dict[str, Any]:
    """The session_list tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    audit.log_event("tool_call", tool="session_list")
    # The CLI runs in a thread; the per-session facts below read state the event
    # loop owns (send queues, watchers), so they are gathered here on the loop.
    result, rows = await asyncio.gather(asyncio.to_thread(com.run_cli,
                                                          ["list", *backend.cli_backend_args()]),
                                        sf.dev_containers())
    if result["exit"] != 0:
        return com.envelope_err(result["stderr"] or "list failed", result, code="cli_failed")
    listed = [r for r in rows or [] if scope.refusal(r["name"]) is None]

    async def one(row: dict[str, str]) -> dict[str, Any]:
        name = row["name"]
        report = await session_report(name)
        return {**row, "tainted": report["tainted"], "repo": report["repo"],
                "branch": report["branch"], "claude_running": report["claude_running"],
                "working": report["working"],
                "watched_conversation_id": report["watched_conversation_id"],
                "claude_account": report["claude_account"],
                "queue_depth": len(ss.pending_sends.get(name, []))}

    sessions = list(await asyncio.gather(*(one(r) for r in listed)))
    return com.envelope_ok({"raw": scope.filter_list(result["stdout"]), "sessions": sessions})


async def status(name: str) -> dict[str, Any]:
    """The session_status tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    audit.log_event("tool_call", tool="session_status", session=name)
    # The CLI call runs in a thread; the send queue below is read back here on
    # the event loop, the only thread that changes it.
    result = await asyncio.to_thread(com.run_cli, ["status", name, *backend.cli_backend_args()])
    if result["exit"] != 0:
        return com.envelope_err(result["stderr"] or "status failed", result, code="cli_failed")
    report, found = await asyncio.gather(
        session_report(name), headless.container_runs(backend.target(name)))
    # Prompts sent to the session and not pasted yet, each with why it waits.
    queue = [{"prompt_id": q.prompt_id, "prompt_preview": q.text[:120],
              "enqueued_at": q.enqueued_at,
              "waiting_reason": q.waiting_reason,
              "waiting_because": snd.WAITING_EXPLAINED.get(q.waiting_reason, ""),
              "paste_attempts": q.paste_attempts}
             for q in ss.pending_sends.get(name, [])]
    return com.envelope_ok({**report, "send_queue": queue,
                         "headless_runs": headless.merge(name, found),
                         "raw": result["stdout"]})


def exec_command(name: str, cmd: str, timeout_seconds: int = 60) -> dict[str, Any]:
    """The session_exec tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    audit.log_event("tool_call", tool="session_exec", session=name, cmd_redacted=cmd[:50])
    container = backend.target(name)
    argv = backend.exec_argv(container, ["bash", "-lc", cmd], user="vscode")
    try:
        proc = _run_bounded(name, argv, timeout_seconds)
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        return com.envelope_err(f"timeout after {timeout_seconds}s",
                                {"stdout": out}, code="timeout")
    return com.envelope_ok({"stdout": proc.stdout, "stderr": proc.stderr,
                            "exit": proc.returncode})


# How long a timed-out exec is waited for after it is killed, before it is left behind.
EXEC_KILL_WAIT_SECONDS = 5


def _run_bounded(name: str, argv: list[str],
                 timeout_seconds: int) -> subprocess.CompletedProcess[str]:
    """subprocess.run(argv, capture_output=True, text=True, timeout=timeout_seconds), except
    that a timeout always ends as subprocess.TimeoutExpired: run() kills the child and lets
    the kill's error escape (a PermissionError when the child is another user's, as live with
    a command that left a child in the background), then waits for the child without end.
    Here a kill that fails is logged, the child is waited for a short while only, and the
    timeout is raised as it is."""
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        out, err = proc.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except OSError as exc:
            # The child may be another user's, or already gone.
            audit.log_event("session_exec_kill_failed", session=name, pid=proc.pid,
                            error_type=type(exc).__name__, error=str(exc))
        try:
            proc.wait(timeout=EXEC_KILL_WAIT_SECONDS)
        except subprocess.TimeoutExpired:
            audit.log_event("session_exec_left_running", session=name, pid=proc.pid)
        for stream in (proc.stdout, proc.stderr):
            try:
                if stream is not None:
                    stream.close()
            except OSError:
                pass
        raise
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


async def transcript(name: str, last_n: int = 5, since_uuid: str = "") -> dict[str, Any]:
    """The session_transcript tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    if not 1 <= last_n <= tv.MAX_TURNS:
        return com.envelope_err(f"last_n must be between 1 and {tv.MAX_TURNS}",
                                code="invalid_argument")
    objs, _, status = tn.session_transcript(name)
    if status == "unreadable":
        return com.envelope_err("the session's transcript could not be read",
                                code="command_failed")
    try:
        view = tv.view(objs, last_n=last_n, since_uuid=since_uuid.strip())
    except tv.UnknownTurn:
        return com.envelope_err(
            f"'{since_uuid}' is not a completed turn in the session's transcript; omit "
            "since_uuid for the newest turns", code="invalid_argument")
    audit.log_event("tool_call", tool="session_transcript", session=name,
              turns=len(view["turns"]), cut=view["cut"])
    data: dict[str, Any] = {"session": name, **view, "untrusted": True}
    if status == "none":
        data["note"] = "nobody has prompted this session yet"
    return com.envelope_ok(data)


async def interrupt(name: str, target: str = inv.INTERRUPT_AGENT) -> dict[str, Any]:
    """The session_interrupt tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    container = backend.target(name)
    target = (target or inv.INTERRUPT_AGENT).strip()
    if target not in (inv.INTERRUPT_AGENT, inv.INTERRUPT_HEADLESS):
        return com.envelope_err(
            f'target must be "{inv.INTERRUPT_AGENT}" or "{inv.INTERRUPT_HEADLESS}", '
            f"not {target!r}", code="invalid_argument")
    if target == inv.INTERRUPT_HEADLESS:
        return await inv.interrupt_headless(name, container)
    state = await tn.session_state(container, name)
    objs, _, _ = tn.session_transcript(name)
    tree = await rps.tree(name)
    if not (state.claude_running and state.turn == tn.TURN_RUNNING):
        audit.log_event("tool_call", tool="session_interrupt", session=name, interrupted=False,
                  why=state.why)
        return com.envelope_ok({"session": name, "interrupted": False, "was_running": None,
                             "tree": tree, "note": "nothing was running"})
    was = {"why": state.why, **tv.turn_info(objs)}
    rc = await tmx.tmux_exec(container,
                             ["send-keys", "-t", f"main:{tmx.SESSION_WINDOW}", "Escape"])
    if rc != 0:
        audit.log_event("tool_call", tool="session_interrupt", session=name, ok=False, rc=rc)
        return com.envelope_err(f"the Esc could not be sent to the session (tmux exited {rc})",
                                {"was_running": was, "tree": tree}, code="command_failed")
    audit.log_event("tool_call", tool="session_interrupt", session=name, interrupted=True,
              why=state.why)
    com.session_changed(name)
    return com.envelope_ok({"session": name, "interrupted": True, "was_running": was,
                         "tree": tree})


# Writes stdin to "$1" with mode "$2": into a temporary file beside it, then renamed over it,
# so a reader never sees half a file and an existing file is replaced. `install -m MODE
# /dev/stdin PATH` was used before and fails on an existing file with the uutils coreutils
# the session image ships ("No such file or directory"). The path and mode are arguments,
# never spliced into the script.
FILE_PUT_SCRIPT = (
    'set -e; tmp=$(mktemp "$(dirname -- "$1")/.aidc-put.XXXXXX"); '
    'trap \'rm -f -- "$tmp"\' EXIT; cat > "$tmp"; chmod -- "$2" "$tmp"; mv -f -- "$tmp" "$1"'
)


def file_put(name: str, path: str, content: str, mode: str = "0644") -> dict[str, Any]:
    """The file_put tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    audit.log_event("tool_call", tool="file_put", session=name, path=path,
              bytes=len(content), mode=mode)
    container = backend.target(name)
    proc = subprocess.run(
        backend.exec_argv(container, ["bash", "-c", FILE_PUT_SCRIPT, "file_put", path, mode],
                          user="vscode", stdin=True),
        input=content.encode("utf-8"), capture_output=True, timeout=30,
    )
    if proc.returncode != 0:
        return com.envelope_err(proc.stderr.decode("utf-8", errors="replace") or "write failed",
                                code="command_failed")
    return com.envelope_ok({"path": path, "bytes": len(content)})


async def audit_get(name: str, since: str | None = None, kind: str | None = None) -> dict[str, Any]:
    """The audit_get tool's work. tearstools/ holds the tool (its schema and
    description), authz.py the guards around it."""
    # NB: log_event's first positional param is itself named `kind`; pass the
    # audit filter as `filter_kind` so it doesn't collide.
    audit.log_event("tool_call", tool="audit_get", session=name, since=since, filter_kind=kind)
    try:
        events = await sf.policy_events(name)
    except sf.TaintUnknown as exc:
        if backend.container_missing(str(exc)):
            return com.envelope_err(f"There is no session named '{name}'. Check session_list.",
                                    code="no_such_session")
        return com.envelope_err(f"the session's policy sidecar did not answer: {exc}",
                                code="command_failed")
    def wanted(e: dict[str, Any]) -> bool:
        if since and str(e.get("at", "")) < since:
            return False
        return not kind or kind in str(e.get("trigger", "")) + str(e.get("outcome", ""))

    matched = [e for e in events if wanted(e)]
    kept = matched[-AUDIT_EVENTS_MAX:]
    return com.envelope_ok({"session": name, "audit_dir": await sf.audit_dir(name),
                         "events": kept, "count": len(matched),
                         "cut": len(kept) < len(matched)})
