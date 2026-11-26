"""Where a session's containers run: the one module that knows Docker and Kubernetes.

A session is a set of containers addressed by (session, role): `dev` (Claude, the repo,
tmux), `policy` (the taint flag and policy events), `audit` (the audit dir mount).
Everything else in this package builds commands and reads facts through the functions
here, so the two backends answer the same questions without touching each caller
(docs/design-12-kubernetes.md, "Backend seam").

One server serves one backend (MCP-02 as amended): the Docker aidc-mcp, one per host, drives
Docker sessions; the per-user server in the cluster (K8S-07) drives that user's sessions in
their namespace. The backend is the server's environment, AIDC_MCP_BACKEND (`docker`, the
default, or `kubernetes`), with the namespace in AIDC_K8S_NAMESPACE; both are read on every
call, so a test can switch them.

The functions return argv lists rather than running them: callers differ in sync or async,
stdin, timeouts and stream handling, and those stay where they are.

On Kubernetes a target is "<object>:<container>", the object being one kubectl exec takes
(pod/<name>, deployment/<name>): a session's dev pod is its StatefulSet's one pod, its
policy and audit sidecars are containers of its proxy Deployment's pod, and the git agent is
the git Deployment's pod (scripts/k8s/manifests.sh names them all).
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

DOCKER = "docker"
KUBERNETES = "kubernetes"

#: The server's backend, and the namespace of its sessions on Kubernetes.
KIND_ENV = "AIDC_MCP_BACKEND"
NAMESPACE_ENV = "AIDC_K8S_NAMESPACE"

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
#: The git container's request holder (gitctl, gitreq): on Docker a user of the git
#: container; on Kubernetes the git pod's own gitreq container, since kubectl exec cannot
#: choose a user.
GIT_HOLDER_USER = "gitreq"

#: How long kubectl waits for a pod of a Deployment to be running before an exec gives up
#: (its default is a minute, longer than any caller waits).
_K8S_POD_WAIT = "--pod-running-timeout=10s"
#: How long a kubectl read waits for the API server.
_K8S_READ_WAIT = "--request-timeout=10s"


class BackendConfigError(ValueError):
    """The server's backend settings are unusable: it must not start on them."""


def kind() -> str:
    """The server's backend: DOCKER or KUBERNETES.

    :raises BackendConfigError: for a value that names neither
    """
    raw = os.environ.get(KIND_ENV, "").strip().lower()
    if raw in ("", DOCKER):
        return DOCKER
    if is_kubernetes(raw):
        return KUBERNETES
    raise BackendConfigError(f"{KIND_ENV}={raw!r}: expected docker or kubernetes")


def _k8s() -> bool:
    return kind() == KUBERNETES


def namespace() -> str:
    """The namespace a Kubernetes server's sessions are in.

    :raises BackendConfigError: when it is unset or not a namespace name
    """
    ns = os.environ.get(NAMESPACE_ENV, "").strip()
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?", ns):
        raise BackendConfigError(
            f"{NAMESPACE_ENV}={ns!r}: a Kubernetes server needs its user's namespace")
    return ns


def check_config() -> str:
    """The backend this server runs on, checked whole (the namespace too on Kubernetes), so
    a server with unusable settings stops at start rather than failing every call.

    :raises BackendConfigError: as kind and namespace do
    """
    k = kind()
    if k == KUBERNETES:
        namespace()
    return k


def program() -> str:
    """The program every command here starts with."""
    return "kubectl" if _k8s() else "docker"


def target(session: str, role: str = ROLE_DEV) -> str:
    """The name that addresses one of the session's containers."""
    if not _k8s():
        return f"aidc-{session}-{role}"
    if role == ROLE_DEV:
        if is_git_session(session):
            return f"deployment/{GIT_SESSION}:{GIT_USER}"
        return f"pod/{session}-dev-0:{ROLE_DEV}"
    return f"deployment/{session}-proxy:{role}"


def _split(tgt: str) -> tuple[str, str]:
    """A Kubernetes target's object and container."""
    obj, _, container = tgt.rpartition(":")
    return obj, container


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
    if _k8s():
        return _k8s_exec_args(tgt, argv, user=user, workdir=workdir, env=env, stdin=stdin)
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


#: Runs the rest of the command in the directory given first (kubectl exec has no --workdir).
_IN_DIR = 'cd -- "$1" || exit 126; shift; exec "$@"'


def _k8s_exec_args(tgt: str, argv: list[str], *, user: str | None, workdir: str | None,
                   env: dict[str, str] | None, stdin: bool) -> list[str]:
    """kubectl exec has no --user, --workdir or --env, so they become part of the command.

    The user: the git pod's containers run as their own users (git, gitreq), so asking for
    one of them chooses the container; in a dev pod, whose container starts as root, the
    session user is reached with `sudo -E -H -u vscode`, as `aidc attach` does: -E keeps the
    pod's environment (its proxy settings among it), -H sets the user's HOME, and the dev
    image's sudo rule gives it the session's umask (scripts/k8s, entrypoint.sh), so what it
    writes on the shared disk stays group-writable."""
    obj, container = _split(tgt)
    prefix: list[str] = []
    if obj == _split(target(GIT_SESSION))[0]:
        if user == GIT_HOLDER_USER:
            container = GIT_HOLDER_USER
        elif user not in (None, SESSION_USER, GIT_USER):
            raise ValueError(f"the git pod runs nothing as {user!r}")
    elif user is not None and container == ROLE_DEV:
        if user != "root":
            prefix = ["sudo", "-E", "-H", "-u", user, "--"]
    elif user is not None:
        raise ValueError(f"the {container} container runs nothing as {user!r}")
    if env:
        prefix += ["env", *(f"{key}={value}" for key, value in env.items())]
    if workdir:
        prefix += ["sh", "-c", _IN_DIR, "aidc-workdir", workdir]
    out = ["-n", namespace(), "exec"]
    if stdin:
        out.append("-i")
    return [*out, _K8S_POD_WAIT, obj, "-c", container, "--", *prefix, *argv]


def exec_argv(tgt: str, argv: list[str], *, user: str | None = None,
              workdir: str | None = None, env: dict[str, str] | None = None,
              stdin: bool = False) -> list[str]:
    """The command that runs `argv` in the container `tgt` (see :func:`target`), as
    `user`, in `workdir`, with `env` added, and with stdin attached when `stdin`."""
    return [program(), *exec_args(tgt, argv, user=user, workdir=workdir, env=env,
                                  stdin=stdin)]


def _k8s_get_json(obj: str) -> list[str]:
    return ["-n", namespace(), "get", obj, "-o", "json", _K8S_READ_WAIT]


def _pod_spec(stdout: bytes) -> dict[str, Any]:
    """The pod spec of a kubectl get -o json of a pod or a workload (its template's)."""
    try:
        doc = json.loads(stdout.decode("utf-8", errors="replace") or "{}")
    except ValueError:
        return {}
    spec = doc.get("spec") if isinstance(doc, dict) else None
    if not isinstance(spec, dict):
        return {}
    template = spec.get("template")
    if isinstance(template, dict) and isinstance(template.get("spec"), dict):
        return template["spec"]
    return spec


def _container_spec(stdout: bytes, tgt: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """The pod spec and the spec of the target's container in it ({} when absent)."""
    spec = _pod_spec(stdout)
    name = _split(tgt)[1]
    for c in spec.get("containers") or []:
        if isinstance(c, dict) and c.get("name") == name:
            return spec, c
    return spec, {}


def mount_source_args(tgt: str, destination: str) -> list[str]:
    """Arguments (after the program) that print what is mounted at `destination` in `tgt`."""
    if _k8s():
        return _k8s_get_json(_split(tgt)[0])
    return ["inspect", tgt, "--format",
            "{{range .Mounts}}{{if eq .Destination \"" + destination + "\"}}{{.Source}}"
            "{{end}}{{end}}"]


def mount_source(stdout: bytes, tgt: str, destination: str) -> str | None:
    """What :func:`mount_source_args` printed, as where the data is: on Docker the host
    path; on Kubernetes `pvc:<namespace>/<claim>`, the volume claim mounted there. None when
    nothing is mounted there."""
    if _k8s():
        spec, container = _container_spec(stdout, tgt)
        volume = next((m.get("name") for m in container.get("volumeMounts") or []
                       if isinstance(m, dict) and m.get("mountPath") == destination), None)
        for v in spec.get("volumes") or []:
            if isinstance(v, dict) and volume and v.get("name") == volume:
                claim = (v.get("persistentVolumeClaim") or {}).get("claimName")
                return f"pvc:{namespace()}/{claim}" if claim else None
        return None
    path = stdout.decode("utf-8", errors="replace").strip()
    return path or None


def env_workdir_args(tgt: str) -> list[str]:
    """Arguments (after the program) that print `tgt`'s environment and working dir, for
    :func:`env_and_workdir`."""
    if _k8s():
        return _k8s_get_json(_split(tgt)[0])
    return ["inspect", tgt, "--format",
            "{{range .Config.Env}}{{println .}}{{end}}\x1f{{.Config.WorkingDir}}"]


def env_and_workdir(stdout: bytes, tgt: str) -> tuple[dict[str, str], str]:
    """What :func:`env_workdir_args` printed: the environment (first value wins, as a
    process sees it) and the working dir ("" when unset). On Kubernetes the environment is
    the container spec's literal values (one from a Secret or a field is not read)."""
    env: dict[str, str] = {}
    if _k8s():
        _, container = _container_spec(stdout, tgt)
        for e in container.get("env") or []:
            if isinstance(e, dict) and isinstance(e.get("value"), str) and e.get("name"):
                env.setdefault(str(e["name"]), e["value"])
        return env, str(container.get("workingDir") or "").strip()
    env_text, _, workdir = stdout.decode("utf-8", errors="replace").partition("\x1f")
    for line in env_text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key not in env:
            env[key] = value
    return env, workdir.strip()


#: kubectl's word for an object that is not there, naming the kinds a target is.
_K8S_TARGET_GONE = re.compile(
    r'\(NotFound\): (?:pods|deployments\.apps|statefulsets\.apps) "[^"]+" not found')


def container_missing(stderr: str) -> bool:
    """Whether a failed exec or inspect says the container does not exist (the session is
    gone or was never made), as opposed to the command failing inside it. On Kubernetes:
    the pod or Deployment is not there (a pod that is there but not running yet is a
    session starting, not a missing one)."""
    if _k8s():
        return bool(_K8S_TARGET_GONE.search(stderr))
    return "no such container" in stderr.lower()


#: Columns of :func:`dev_list_args`' rows on Docker, tab-separated.
DEV_LIST_FORMAT = "{{.Names}}\t{{.Status}}\t{{.Label \"aidc.profile\"}}\t{{.CreatedAt}}"


def dev_list_args(*, by_name: bool = False) -> list[str]:
    """Arguments (after the program) listing every session's dev container, running or not,
    for :func:`dev_rows`. `by_name` finds Docker sessions made before the role label by
    their container names (every Kubernetes session is labelled: the same list)."""
    if _k8s():
        return ["-n", namespace(), "get", "statefulsets,deployments", "-l", "app in (dev,git)",
                "-o", "json", _K8S_READ_WAIT]
    flt = "name=^aidc-.*-dev$" if by_name else f"label=aidc.role={ROLE_DEV}"
    return ["ps", "-a", "--filter", flt, "--format", DEV_LIST_FORMAT]


def session_of_dev(container: str) -> str | None:
    """The session a Docker dev container in a :func:`dev_list_args` row belongs to."""
    prefix, suffix = "aidc-", f"-{ROLE_DEV}"
    if container.startswith(prefix) and container.endswith(suffix):
        return container[len(prefix):-len(suffix)]
    return None


def dev_rows(stdout: bytes) -> list[dict[str, str]]:
    """What :func:`dev_list_args` printed, one {name, status, profile, started} per session.
    On Kubernetes a session's status is `running` once its dev pod is ready, `starting`
    before, and the git agent's profile is `git-agent`, as `aidc list` shows them."""
    text = stdout.decode("utf-8", errors="replace")
    rows: list[dict[str, str]] = []
    if _k8s():
        try:
            items = json.loads(text or "{}").get("items") or []
        except (ValueError, AttributeError):
            return []
        for item in items:
            if not isinstance(item, dict):
                continue
            meta = item.get("metadata") or {}
            labels = meta.get("labels") or {}
            name = str(labels.get("aidc/session") or "")
            app = labels.get("app")
            if not name or (app == "git") != is_git_session(name) or app not in ("dev", "git"):
                continue
            ready = (item.get("status") or {}).get("readyReplicas") or 0
            profile = ("git-agent" if app == "git"
                       else str((meta.get("annotations") or {}).get("aidc/profile") or ""))
            rows.append({"name": name, "status": "running" if ready else "starting",
                         "profile": profile or "?",
                         "started": str(meta.get("creationTimestamp") or "")})
        return rows
    for line in text.splitlines():
        parts = line.split("\t")
        session = session_of_dev(parts[0]) if parts else None
        if not session:
            continue
        parts += [""] * (4 - len(parts))
        rows.append({"name": session, "status": parts[1],
                     "profile": parts[2] or "?", "started": parts[3]})
    return rows


def _instance_claim(session: str) -> str:
    """The claim a Kubernetes session's identity is: its state claim, which `aidc create`
    makes, `aidc kill` deletes, and restart and upgrade keep; the git agent's home claim."""
    return "git-home" if is_git_session(session) else f"{session}-state"


def instance_argv(session: str) -> list[str]:
    """The command that prints the session's instance id.

    On Docker a session is identified by its network, aidc-<name>-net: `aidc create` makes
    it, `aidc kill` removes it, and `aidc upgrade` / `aidc restart` keep it while they
    replace or restart the dev container. On Kubernetes, by its state claim's uid, which
    has the same lifetime (_instance_claim). So the id tells a session killed and created
    again under the same name from the same session upgraded."""
    if _k8s():
        return [program(), "-n", namespace(), "get", "pvc", _instance_claim(session),
                "-o", "jsonpath={.metadata.uid}", _K8S_READ_WAIT]
    return [program(), "inspect", "--type", "network", "--format", "{{.Id}}",
            f"aidc-{session}-net"]


def instance_gone(session: str, stderr: str) -> bool:
    """Whether a failed :func:`instance_argv` means the session does not exist, as
    opposed to the backend not answering.

    Measured on Docker 29.8: "Error response from daemon: network <name> not found".
    Other versions say "No such network: <name>" or "no such object: <name>". The message
    must name this network, so a "not found" about anything else (a docker context, say)
    is not taken for a killed session. On Kubernetes, the API server's NotFound for this
    session's claim; a namespace or a cluster that is not there is not answering."""
    if _k8s():
        return (f'(NotFound): persistentvolumeclaims "{_instance_claim(session)}" not found'
                in stderr)
    err = stderr.lower()
    return f"aidc-{session}-net" in err and ("not found" in err or "no such" in err)


def server_freezes() -> bool:
    """Whether this server carries out a tainted session's freeze (SEC-05/08). On Docker the
    session's policy sidecar pauses its dev container itself; on Kubernetes it has no API
    token, so the user's server cuts the session's egress (plan-aidc-2.0 Q-K3)."""
    return _k8s()


def session_policies_args(session: str) -> list[str]:
    """Arguments (after the program) that print the session's NetworkPolicies as JSON
    (Kubernetes), for :func:`egress_to_cut`."""
    return ["-n", namespace(), "get", "networkpolicy", "-l", f"aidc/session={session}",
            "-o", "json", _K8S_READ_WAIT]


def egress_to_cut(stdout: bytes) -> list[str] | None:
    """The session's NetworkPolicies that still let one of its pods out: each that governs
    egress and has an egress rule. None when the listing cannot be read. Under the namespace's
    default-deny, a pod whose every egress policy has no rule reaches nothing."""
    try:
        items = json.loads(stdout.decode("utf-8", errors="replace") or "{}").get("items")
    except (ValueError, AttributeError):
        return None
    if not isinstance(items, list):
        return None
    names = []
    for item in items:
        if not isinstance(item, dict):
            continue
        spec = item.get("spec") or {}
        if "Egress" in (spec.get("policyTypes") or []) and spec.get("egress"):
            name = (item.get("metadata") or {}).get("name")
            if isinstance(name, str) and name:
                names.append(name)
    return names


def cut_egress_args(policy: str) -> list[str]:
    """Arguments (after the program) that leave the NetworkPolicy `policy` with no egress rule
    (its pods then reach nothing), keeping what it lets in."""
    return ["-n", namespace(), "patch", "networkpolicy", policy, "--type=json",
            "-p", '[{"op": "add", "path": "/spec/egress", "value": []}]', _K8S_READ_WAIT]


_BACKEND_LINE = re.compile(r"""backend:\s*["']?([a-z0-9]*)""")


def create_backend() -> str:
    """The backend `aidc create` is told to use (session_create passes it as --backend).

    A Kubernetes server creates its user's sessions in the cluster, whatever a config says.
    The Docker server keeps the rule `aidc create` follows with no --backend flag: a copy of
    the CLI's one rule (scripts/lib/git-common.sh, aidc_default_backend, which `aidc git` and
    `aidc repo` use too; tests/test_backend.py holds this copy to it): the first top-level
    `backend:` line of $HOME/.config/aidc/config.yaml, docker when there is none. The file is
    the one the CLI this server runs would read (same HOME), not the /aidc-config mount:
    inside the aidc-mcp container the dispatcher does not see that mount and creates on
    Docker, and session_create must agree with it, because the two backends take different
    create arguments (the Kubernetes create refuses --repo)."""
    if _k8s():
        return KUBERNETES
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


def cli_backend_args() -> list[str]:
    """What a session verb of the CLI (list, status) is given so it goes to this server's
    backend: nothing on Docker; `--backend kubernetes` on Kubernetes, where the CLI would
    otherwise ask the cluster and fall back to Docker, which the server's pod has not."""
    return ["--backend", KUBERNETES] if _k8s() else []


def is_kubernetes(name: str) -> bool:
    """Whether a backend name, as the CLI spells it, is the Kubernetes one."""
    return name in ("kubernetes", "k8s")
