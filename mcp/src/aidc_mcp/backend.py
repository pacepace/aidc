"""Where a session's containers run: the one module that knows it is Docker.

A session is a set of containers addressed by (session, role): `dev` (Claude, the repo,
tmux), `policy` (the taint flag and policy events), `audit` (the audit dir mount).
Everything else in this package builds commands and reads facts through the functions
here, so a second backend (Kubernetes, docs/design-12-kubernetes.md) replaces this module's
answers without touching each caller.

The functions return argv lists rather than running them: callers differ in sync or async,
stdin, timeouts and stream handling, and those stay where they are.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

#: The program every command here starts with.
BIN = "docker"

ROLE_DEV = "dev"
ROLE_POLICY = "policy"
ROLE_AUDIT = "audit"

#: The git agent's session name (`aidc git setup`; reserved on both backends). Its container
#: is the user's git container: trusted, with no sandbox proxy, policy or audit sidecar, and
#: its Claude runs as the image's git user rather than vscode.
GIT_SESSION = "git"
#: The user every session's tmux, Claude and shell run as in its dev container.
SESSION_USER = "vscode"
#: The same in the git container (aidc/gitctl).
GIT_USER = "git"


def target(session: str, role: str = ROLE_DEV) -> str:
    """The name that addresses one of the session's containers."""
    return f"aidc-{session}-{role}"


def is_git_session(session: str) -> bool:
    """Whether `session` is the git agent (see GIT_SESSION)."""
    return session == GIT_SESSION


def exec_args(tgt: str, argv: list[str], *, user: str | None = None,
              workdir: str | None = None, env: dict[str, str] | None = None,
              stdin: bool = False) -> list[str]:
    """`exec_argv` without the leading program, for runners that add it themselves.

    A command for the session user in the git agent's container runs as its git user: its
    tmux and Claude are that user's, so the session tools reach them as they reach any
    session's."""
    if user == SESSION_USER and tgt == target(GIT_SESSION):
        user = GIT_USER
    out = ["exec"]
    if stdin:
        out.append("-i")
    if user:
        out += ["-u", user]
    if workdir:
        out += ["-w", workdir]
    for key, value in (env or {}).items():
        out += ["-e", f"{key}={value}"]
    return [*out, tgt, *argv]


def exec_argv(tgt: str, argv: list[str], *, user: str | None = None,
              workdir: str | None = None, env: dict[str, str] | None = None,
              stdin: bool = False) -> list[str]:
    """The command that runs `argv` in the container `tgt` (see :func:`target`), as
    `user`, in `workdir`, with `env` added, and with stdin attached when `stdin`."""
    return [BIN, *exec_args(tgt, argv, user=user, workdir=workdir, env=env, stdin=stdin)]


def mount_source_args(tgt: str, destination: str) -> list[str]:
    """Arguments (after BIN) that print the host path mounted at `destination` in `tgt`."""
    return ["inspect", tgt, "--format",
            "{{range .Mounts}}{{if eq .Destination \"" + destination + "\"}}{{.Source}}"
            "{{end}}{{end}}"]


def mount_source(stdout: bytes) -> str | None:
    """What :func:`mount_source_args` printed: the host path, or None when nothing is
    mounted there."""
    path = stdout.decode("utf-8", errors="replace").strip()
    return path or None


def env_workdir_args(tgt: str) -> list[str]:
    """Arguments (after BIN) that print `tgt`'s environment, one per line, then a \\x1f,
    then its working dir."""
    return ["inspect", tgt, "--format",
            "{{range .Config.Env}}{{println .}}{{end}}\x1f{{.Config.WorkingDir}}"]


def env_and_workdir(stdout: bytes) -> tuple[dict[str, str], str]:
    """What :func:`env_workdir_args` printed: the environment (first value wins, as a
    process sees it) and the working dir ("" when unset)."""
    env_text, _, workdir = stdout.decode("utf-8", errors="replace").partition("\x1f")
    env: dict[str, str] = {}
    for line in env_text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key not in env:
            env[key] = value
    return env, workdir.strip()


def container_missing(stderr: str) -> bool:
    """Whether a failed exec or inspect says the container does not exist (the session is
    gone or was never made), as opposed to the command failing inside it."""
    return "no such container" in stderr.lower()


#: Columns of :func:`dev_list_args`' rows, tab-separated.
DEV_LIST_FORMAT = "{{.Names}}\t{{.Status}}\t{{.Label \"aidc.profile\"}}\t{{.CreatedAt}}"


def dev_list_args(*, by_name: bool = False) -> list[str]:
    """Arguments (after BIN) listing every session's dev container, running or not, one
    row per line in DEV_LIST_FORMAT. `by_name` finds sessions made before the role label
    by their container names."""
    flt = "name=^aidc-.*-dev$" if by_name else f"label=aidc.role={ROLE_DEV}"
    return ["ps", "-a", "--filter", flt, "--format", DEV_LIST_FORMAT]


def session_of_dev(container: str) -> str | None:
    """The session a dev container in a :func:`dev_list_args` row belongs to."""
    prefix, suffix = "aidc-", f"-{ROLE_DEV}"
    if container.startswith(prefix) and container.endswith(suffix):
        return container[len(prefix):-len(suffix)]
    return None


def instance_argv(session: str) -> list[str]:
    """The command that prints the session's instance id.

    A session is identified by its network, aidc-<name>-net: `aidc create` makes it,
    `aidc kill` removes it, and `aidc upgrade` / `aidc restart` keep it while they replace
    or restart the dev container. So the id tells a session killed and created again
    under the same name from the same session upgraded."""
    return [BIN, "inspect", "--type", "network", "--format", "{{.Id}}", f"aidc-{session}-net"]


def instance_gone(session: str, stderr: str) -> bool:
    """Whether a failed :func:`instance_argv` means the session does not exist, as
    opposed to the backend not answering.

    Measured on Docker 29.8: "Error response from daemon: network <name> not found".
    Other versions say "No such network: <name>" or "no such object: <name>". The message
    must name this network, so a "not found" about anything else (a docker context, say)
    is not taken for a killed session."""
    err = stderr.lower()
    return f"aidc-{session}-net" in err and ("not found" in err or "no such" in err)


_BACKEND_LINE = re.compile(r"""backend:\s*["']?([a-z0-9]*)""")


def create_backend() -> str:
    """The backend `aidc create` would choose with no --backend flag: a copy of the CLI's one
    rule (scripts/lib/git-common.sh, aidc_default_backend, which `aidc git` and `aidc repo`
    use too; tests/test_backend.py holds this copy to it): the first top-level `backend:` line
    of $HOME/.config/aidc/config.yaml, docker when there is none. The file is the one the CLI
    this server runs would read (same HOME), not the /aidc-config mount: inside the aidc-mcp
    container the dispatcher does not see that mount and creates on Docker, and session_create
    must agree with it, because the two backends take different create arguments (the
    Kubernetes create refuses --repo)."""
    path = Path(os.environ.get("HOME", "")) / ".config" / "aidc" / "config.yaml"
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return "docker"
    for line in lines:
        if line.startswith("backend:"):
            m = _BACKEND_LINE.match(line)
            return (m.group(1) if m else "") or "docker"
    return "docker"


def is_kubernetes(name: str) -> bool:
    """Whether a backend name, as the CLI spells it, is the Kubernetes one."""
    return name in ("kubernetes", "k8s")
