"""The backend module is the only place that knows sessions run on Docker.

If another module starts `docker` itself or spells a container name, a second backend
(Kubernetes, docs/design-12-kubernetes.md) would silently keep talking to Docker on that path.
"""

from __future__ import annotations

import ast
import json
from pathlib import Path

import pytest

from aidc_mcp import backend

PKG = Path(backend.__file__).parent
ROLE_SUFFIXES = ("-dev", "-policy", "-audit", "-net", "-proxy", "-refresher")


def docker_leaks(source: str) -> list[str]:
    """Places in `source` that start the docker program or build an aidc container name:
    a string constant exactly "docker", or an f-string or constant beginning "aidc-" and
    ending in a role suffix."""
    found = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Constant) and node.value == "docker":
            found.append(f"line {node.lineno}: the string 'docker'")
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and (
                not any(ch.isspace() for ch in node.value)
                and (node.value.startswith("aidc-")
                     and ("{" in node.value or node.value.endswith("-"))
                     or node.value in ROLE_SUFFIXES)):
            found.append(f"line {node.lineno}: part of an aidc container name")
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and (
                "no such container" in node.value.lower()):
            found.append(f"line {node.lineno}: reads the backend's error text")
        if isinstance(node, ast.JoinedStr) and node.values:
            first, last = node.values[0], node.values[-1]
            if (isinstance(first, ast.Constant) and str(first.value).startswith("aidc-")
                    and isinstance(last, ast.Constant)
                    and str(last.value) in ROLE_SUFFIXES):
                found.append(f"line {node.lineno}: an aidc container name")
    return found


def test_the_leak_scanner_catches_each_kind_of_leak():
    """Without this, a scanner that matched nothing would pass the real check forever."""
    assert docker_leaks('subprocess.run(["docker", "ps"])')
    assert docker_leaks('c = f"aidc-{name}-dev"')
    assert docker_leaks('n = f"aidc-{s}-net"')
    assert docker_leaks('p = f"aidc-{s}-proxy"')
    assert docker_leaks('c = "aidc-" + name + "-dev"')
    assert docker_leaks('c = "aidc-{}-dev".format(name)')
    assert docker_leaks('if "No such container" in err: pass')
    assert not docker_leaks('log("docker exec exited 1")')
    assert not docker_leaks('buf = "aidc-send"; cmd = "aidc-claude"')
    assert not docker_leaks('"""aidc-mcp entry point, {see} below."""')
    assert not docker_leaks('backend.target(name)')


def test_no_module_but_backend_starts_docker_or_names_a_container():
    leaks = {}
    for path in sorted(PKG.glob("*.py")):
        if path.name == "backend.py":
            continue
        found = docker_leaks(path.read_text())
        if found:
            leaks[path.name] = found
    assert leaks == {}


def test_a_target_names_the_sessions_container_for_the_role():
    assert backend.target("proj") == "aidc-proj-dev"
    assert backend.target("proj", backend.ROLE_POLICY) == "aidc-proj-policy"
    assert backend.target("proj", backend.ROLE_AUDIT) == "aidc-proj-audit"


@pytest.mark.parametrize(("kwargs", "expected"), [
    ({}, ["docker", "exec", "c", "ls"]),
    ({"user": "vscode"}, ["docker", "exec", "-u", "vscode", "c", "ls"]),
    ({"stdin": True, "user": "vscode"}, ["docker", "exec", "-i", "-u", "vscode", "c", "ls"]),
    ({"user": "vscode", "workdir": "/r", "env": {"A": "1", "B": "x y"}},
     ["docker", "exec", "-u", "vscode", "-w", "/r", "-e", "A=1", "-e", "B=x y", "c", "ls"]),
])
def test_exec_argv_places_each_option_before_the_container(kwargs, expected):
    """docker reads options only before the container name; one after it would be passed
    to the command instead."""
    assert backend.exec_argv("c", ["ls"], **kwargs) == expected


def test_exec_args_is_exec_argv_without_the_program():
    assert backend.exec_args("c", ["ls"], user="u") == backend.exec_argv("c", ["ls"],
                                                                         user="u")[1:]


def test_a_dev_list_row_names_its_session_and_nothing_else_does():
    assert backend.session_of_dev("aidc-proj-dev") == "proj"
    assert backend.session_of_dev("aidc-a-b-dev") == "a-b"
    assert backend.session_of_dev("aidc-proj-policy") is None
    assert backend.session_of_dev("other-dev") is None


@pytest.mark.parametrize(("stderr", "gone"), [
    ("Error response from daemon: network aidc-proj-net not found", True),
    ("Error: No such network: aidc-proj-net", True),
    ("Error: no such object: aidc-proj-net", True),
    ("context \"remote\" not found", False),
    ("Cannot connect to the Docker daemon", False),
    ("Error response from daemon: network aidc-other-net not found", False),
])
def test_only_a_missing_network_of_this_session_means_gone(stderr, gone):
    """Anything else is the backend not answering, and queued prompts must keep waiting."""
    assert backend.instance_gone("proj", stderr) is gone


def test_the_inspect_and_list_commands_match_what_their_parsers_read():
    """Each pairs with a reader in session_facts or tools: a changed column, separator or
    format here would be read as no data rather than failing loudly."""
    assert backend.mount_source_args("aidc-p-audit", "/var/aidc/audit") == [
        "inspect", "aidc-p-audit", "--format",
        '{{range .Mounts}}{{if eq .Destination "/var/aidc/audit"}}{{.Source}}{{end}}{{end}}']
    assert backend.env_workdir_args("aidc-p-dev") == [
        "inspect", "aidc-p-dev", "--format",
        "{{range .Config.Env}}{{println .}}{{end}}\x1f{{.Config.WorkingDir}}"]
    assert backend.dev_list_args() == [
        "ps", "-a", "--filter", "label=aidc.role=dev", "--format", backend.DEV_LIST_FORMAT]
    assert backend.dev_list_args(by_name=True)[3] == "name=^aidc-.*-dev$"
    assert backend.DEV_LIST_FORMAT.count("\t") == 3
    assert backend.instance_argv("p") == [
        "docker", "inspect", "--type", "network", "--format", "{{.Id}}", "aidc-p-net"]


def test_the_inspect_readers_turn_output_into_facts():
    audit = "aidc-p-audit"
    assert backend.mount_source(b"/home/u/audit/p\n", audit, "/var/aidc/audit") == "/home/u/audit/p"
    assert backend.mount_source(b"\n", audit, "/var/aidc/audit") is None
    env, wd = backend.env_and_workdir(b"PATH=/bin\nAIDC_REPO_PATH=/r\nX=a=b\n\x1f/w\n",
                                      "aidc-p-dev")
    assert env == {"PATH": "/bin", "AIDC_REPO_PATH": "/r", "X": "a=b"} and wd == "/w"
    assert backend.env_and_workdir(b"", "aidc-p-dev") == ({}, "")


@pytest.mark.parametrize(("stderr", "missing"), [
    ("Error response from daemon: No such container: aidc-p-dev", True),
    ("Error: No such container: aidc-p-dev", True),
    ("cat: /var/state/tainted: No such file or directory", False),
    ("Error response from daemon: container is paused", False),
])
def test_a_missing_container_is_told_from_a_failure_inside_it(stderr, missing):
    assert backend.container_missing(stderr) is missing


def test_the_git_agents_session_user_is_its_git_user():
    """The git agent (`aidc git setup`) is a session named git whose tmux and Claude run as the
    git container's git user: the session tools, which ask for vscode, reach it as any
    session's. Any other user, and every other session, is left as asked."""
    git = backend.target(backend.GIT_SESSION)
    assert backend.exec_argv(git, ["tmux", "ls"], user="vscode") == [
        "docker", "exec", "-u", "git", git, "tmux", "ls"]
    assert backend.exec_argv(git, ["id"], user="root") == ["docker", "exec", "-u", "root", git, "id"]
    assert backend.exec_argv(git, ["id"]) == ["docker", "exec", git, "id"]
    assert backend.exec_argv("aidc-proj-dev", ["id"], user="vscode") == [
        "docker", "exec", "-u", "vscode", "aidc-proj-dev", "id"]
    assert backend.is_git_session("git") and not backend.is_git_session("gitx")


# --- the default backend: one rule, the shell's ------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
GIT_COMMON = REPO_ROOT / "scripts" / "lib" / "git-common.sh"

# Configs the rule must read the same way on both sides: no file, no backend line, a
# kubernetes: block alone (Docker: the block does not change the default), quoted values, an
# indented key of another section, two lines (the first counts), an empty value, a CRLF file.
DEFAULT_BACKEND_CONFIGS = [
    None,
    "",
    "profile: multi\n",
    "kubernetes:\n  user: alice\n  storage_class: x\n",
    "backend: kubernetes\n",
    "backend: k8s\n",
    'backend: "kubernetes"\n',
    "backend: 'docker'\n",
    "kubernetes:\n  backend: kubernetes\nbackend: docker\nbackend: kubernetes\n",
    "backend:\n",
    "backend: kubernetes  # the cluster\n",
    "backend: kubernetes\r\n",
]


def _shell_default_backend(home: Path) -> str:
    """aidc_default_backend, the shell rule `aidc create`, `aidc git` and `aidc repo` share."""
    import subprocess

    out = subprocess.run(
        ["bash", "-c", '. "$1"; AIDC_BACKEND_FLAG="" aidc_default_backend', "bash", str(GIT_COMMON)],
        env={"HOME": str(home), "PATH": "/usr/bin:/bin"}, capture_output=True, text=True,
        check=False)
    return out.stdout.strip() if out.returncode == 0 else f"error: {out.stderr.strip()}"


@pytest.mark.parametrize("config", DEFAULT_BACKEND_CONFIGS)
def test_create_backend_is_the_shell_rule(config, tmp_path, monkeypatch):
    """The MCP server's create_backend is a Python copy of the shell's aidc_default_backend:
    session_create must pick the backend `aidc create` will, or the arguments it passes (the
    Kubernetes create refuses --repo) are the other backend's. Held to the shell itself."""
    monkeypatch.setenv("HOME", str(tmp_path))
    if config is not None:
        cfg = tmp_path / ".config" / "aidc" / "config.yaml"
        cfg.parent.mkdir(parents=True)
        cfg.write_text(config, encoding="utf-8")
    shell = _shell_default_backend(tmp_path)
    py = backend.create_backend()
    # The shell says "kubernetes" for both spellings; Python keeps the CLI's spelling.
    assert ("kubernetes" if backend.is_kubernetes(py) else py) == shell, config


def test_git_session_name_is_the_shells():
    """The reserved session name of the git agent is defined once in the shell; the server's
    GIT_SESSION must be it."""
    text = GIT_COMMON.read_text(encoding="utf-8")
    assert f"\nAIDC_GIT_SESSION={backend.GIT_SESSION}\n" in text


# --- the Kubernetes backend ----------------------------------------------------------------
#
# The same questions answered with kubectl in the server's user namespace. The tests below
# mirror the Docker ones above; the last group runs the callers against a kubectl stub.

NS = "aidc-u-alice"


@pytest.fixture
def k8s(monkeypatch):
    monkeypatch.setenv(backend.KIND_ENV, "kubernetes")
    monkeypatch.setenv(backend.NAMESPACE_ENV, NS)


def cluster_leaks(source: str) -> list[str]:
    """Places in `source` that start kubectl or spell a cluster object of a session: the
    string "kubectl", a pod or workload reference, or a dev pod's name."""
    found = []
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, ast.Constant) or not isinstance(node.value, str):
            continue
        v = node.value
        if v == "kubectl":
            found.append(f"line {node.lineno}: the string 'kubectl'")
        if not any(ch.isspace() for ch in v) and (
                v.startswith(("pod/", "deployment/", "statefulset/"))
                or v.endswith("-dev-0")):
            found.append(f"line {node.lineno}: part of a cluster object's name")
        if "(NotFound)" in v:
            found.append(f"line {node.lineno}: reads kubectl's error text")
    return found


def test_the_cluster_leak_scanner_catches_each_kind_of_leak():
    assert cluster_leaks('subprocess.run(["kubectl", "get"])')
    assert cluster_leaks('t = f"pod/{s}-dev-0"')
    assert cluster_leaks('t = "deployment/git"')
    assert cluster_leaks('c = "-dev-0"')
    assert cluster_leaks('if "(NotFound)" in err: pass')
    assert not cluster_leaks('log("kubectl exec exited 1")')
    assert not cluster_leaks('backend.target(name)')


def test_no_module_but_backend_starts_kubectl_or_names_a_cluster_object():
    leaks = {}
    for path in sorted(PKG.rglob("*.py")):
        if path.name == "backend.py":
            continue
        found = cluster_leaks(path.read_text())
        if found:
            leaks[str(path.relative_to(PKG))] = found
    assert leaks == {}


def test_no_module_in_a_subpackage_starts_docker_or_names_a_container_either():
    """The scan above the Kubernetes part reads the package's top level; the service and
    the tools live in subpackages."""
    leaks = {}
    for path in sorted(PKG.rglob("*.py")):
        if path.name == "backend.py":
            continue
        found = docker_leaks(path.read_text())
        if found:
            leaks[str(path.relative_to(PKG))] = found
    assert leaks == {}


def test_the_backend_is_docker_unless_the_server_is_told_kubernetes(monkeypatch):
    assert backend.kind() == "docker" and backend.program() == "docker"
    for value in ("kubernetes", "k8s", " Kubernetes "):
        monkeypatch.setenv(backend.KIND_ENV, value)
        assert backend.kind() == "kubernetes" and backend.program() == "kubectl"
    monkeypatch.setenv(backend.KIND_ENV, "podman")
    with pytest.raises(backend.BackendConfigError):
        backend.check_config()


@pytest.mark.parametrize("ns", ["", "Alice", "a_b", "-a", "x" * 64])
def test_a_kubernetes_server_needs_its_users_namespace(ns, monkeypatch):
    """A server that cannot say which namespace is its user's must not start: every call it
    made would go to kubectl's own default namespace."""
    monkeypatch.setenv(backend.KIND_ENV, "kubernetes")
    monkeypatch.setenv(backend.NAMESPACE_ENV, ns)
    with pytest.raises(backend.BackendConfigError):
        backend.check_config()


def test_a_kubernetes_target_names_the_sessions_pod_and_container(k8s):
    assert backend.check_config() == "kubernetes"
    assert backend.target("proj") == "pod/proj-dev-0:dev"
    assert backend.target("proj", backend.ROLE_POLICY) == "deployment/proj-proxy:policy"
    assert backend.target("proj", backend.ROLE_AUDIT) == "deployment/proj-proxy:audit"
    assert backend.target(backend.GIT_SESSION) == "deployment/git:git"


K8S_EXEC = ["kubectl", "-n", NS, "exec"]
WAIT = "--pod-running-timeout=10s"


@pytest.mark.parametrize(("kwargs", "expected"), [
    ({}, [*K8S_EXEC, WAIT, "pod/p-dev-0", "-c", "dev", "--", "ls"]),
    ({"user": "vscode"},
     [*K8S_EXEC, WAIT, "pod/p-dev-0", "-c", "dev", "--", "sudo", "-E", "-H", "-u", "vscode",
      "--", "ls"]),
    ({"stdin": True, "user": "vscode"},
     [*K8S_EXEC, "-i", WAIT, "pod/p-dev-0", "-c", "dev", "--", "sudo", "-E", "-H", "-u",
      "vscode", "--", "ls"]),
    ({"user": "root"}, [*K8S_EXEC, WAIT, "pod/p-dev-0", "-c", "dev", "--", "ls"]),
    ({"user": "vscode", "workdir": "/r", "env": {"A": "1", "B": "x y"}},
     [*K8S_EXEC, WAIT, "pod/p-dev-0", "-c", "dev", "--", "sudo", "-E", "-H", "-u", "vscode",
      "--", "env", "A=1", "B=x y", "sh", "-c", backend._IN_DIR, "aidc-workdir", "/r", "ls"]),
])
def test_a_kubernetes_exec_carries_user_workdir_and_env_in_the_command(k8s, kwargs, expected):
    """kubectl exec has no --user, --workdir or --env: the session user is reached by sudo
    (keeping the pod's environment), the rest are part of the command, and every kubectl
    option comes before the `--` that ends them."""
    assert backend.exec_argv("pod/p-dev-0:dev", ["ls"], **kwargs) == expected
    assert backend.exec_args("pod/p-dev-0:dev", ["ls"], **kwargs) == expected[1:]


def test_a_kubernetes_exec_with_a_workdir_runs_there(k8s, tmp_path):
    """The workdir wrapper itself: the command runs in the dir, with its arguments intact,
    and a missing dir is a failure, not a run somewhere else."""
    import subprocess

    argv = backend.exec_argv("pod/p-dev-0:dev", ["sh", "-c", 'pwd; printf "%s|" "$@"', "x",
                                                  "a b", "c"], workdir=str(tmp_path))
    inner = argv[argv.index("--") + 1:]
    out = subprocess.run(inner, capture_output=True, text=True, check=False)
    assert out.stdout.splitlines() == [str(tmp_path), "a b|c|"]
    argv = backend.exec_argv("pod/p-dev-0:dev", ["true"], workdir=str(tmp_path / "gone"))
    assert subprocess.run(argv[argv.index("--") + 1:], check=False,
                          capture_output=True).returncode == 126


def test_the_git_pods_users_are_its_containers(k8s):
    """The git pod's containers run as their own users and kubectl exec cannot choose one:
    the session user (and git) is the git container as it is; the request holder is the
    pod's gitreq container, never a sudo from the agent's."""
    git = backend.target(backend.GIT_SESSION)
    assert backend.exec_argv(git, ["tmux", "ls"], user="vscode") == [
        *K8S_EXEC, WAIT, "deployment/git", "-c", "git", "--", "tmux", "ls"]
    assert backend.exec_argv(git, ["git-requests", "list"], user="gitreq",
                             env={"HOME": "/var/lib/gitctl/gitreq"}) == [
        *K8S_EXEC, WAIT, "deployment/git", "-c", "gitreq", "--",
        "env", "HOME=/var/lib/gitctl/gitreq", "git-requests", "list"]
    with pytest.raises(ValueError):
        backend.exec_argv(git, ["id"], user="root")
    with pytest.raises(ValueError):
        backend.exec_argv(backend.target("p", backend.ROLE_POLICY), ["id"], user="vscode")


@pytest.mark.parametrize(("stderr", "missing"), [
    ('Error from server (NotFound): pods "p-dev-0" not found', True),
    ('Error from server (NotFound): deployments.apps "p-proxy" not found', True),
    ('Error from server (NotFound): statefulsets.apps "p-dev" not found', True),
    ('Error from server (NotFound): namespaces "aidc-u-x" not found', False),
    ('error: unable to upgrade connection: container not found ("dev")', False),
    ("cat: /var/state/tainted: No such file or directory", False),
    ("Unable to connect to the server: dial tcp 10.0.0.1:6443: i/o timeout", False),
])
def test_a_missing_pod_is_told_from_one_starting_or_a_failure_inside_it(k8s, stderr, missing):
    """A pod that is there but whose container is not running yet is a session starting; a
    namespace that is not there is this server misconfigured: neither is a gone session."""
    assert backend.container_missing(stderr) is missing


@pytest.mark.parametrize(("session", "stderr", "gone"), [
    ("proj", 'Error from server (NotFound): persistentvolumeclaims "proj-state" not found', True),
    ("git", 'Error from server (NotFound): persistentvolumeclaims "git-home" not found', True),
    ("proj", 'Error from server (NotFound): persistentvolumeclaims "other-state" not found',
     False),
    ("proj", 'Error from server (NotFound): namespaces "aidc-u-alice" not found', False),
    ("proj", "Unable to connect to the server: EOF", False),
    ("proj", 'Error from server (Forbidden): persistentvolumeclaims "proj-state" is forbidden',
     False),
])
def test_only_a_missing_state_claim_of_this_session_means_gone(k8s, session, stderr, gone):
    """The cluster's mirror of the Docker network rule: the state claim is made by create
    and deleted by kill, and kept by restart and upgrade; anything else is the cluster not
    answering, and queued prompts keep waiting."""
    assert backend.instance_gone(session, stderr) is gone


def test_a_kubernetes_instance_is_its_state_claims_uid(k8s):
    assert backend.instance_argv("p") == [
        "kubectl", "-n", NS, "get", "pvc", "p-state", "-o", "jsonpath={.metadata.uid}",
        "--request-timeout=10s"]
    assert backend.instance_argv("git")[5] == "git-home"


def _pod(env=None, workdir="", mounts=None, volumes=None, container="dev", template=False):
    spec = {"containers": [{"name": "other", "env": [{"name": "AIDC_REPO_PATH", "value": "/x"}]},
                           {"name": container, "env": env or [], "workingDir": workdir,
                            "volumeMounts": mounts or []}],
            "volumes": volumes or []}
    doc = {"spec": {"template": {"spec": spec}}} if template else {"spec": spec}
    return json.dumps(doc).encode()


def test_the_kubernetes_readers_turn_object_json_into_facts(k8s):
    env, wd = backend.env_and_workdir(_pod(
        env=[{"name": "PATH", "value": "/bin"}, {"name": "AIDC_REPO_PATH", "value": "/home/a/r"},
             {"name": "TOKEN", "valueFrom": {"secretKeyRef": {"name": "s", "key": "k"}}},
             {"name": "PATH", "value": "/later"}], workdir="/home/a/r"), "pod/p-dev-0:dev")
    assert env == {"PATH": "/bin", "AIDC_REPO_PATH": "/home/a/r"} and wd == "/home/a/r"
    assert backend.env_and_workdir(b"", "pod/p-dev-0:dev") == ({}, "")
    assert backend.env_and_workdir(b"not json", "pod/p-dev-0:dev") == ({}, "")
    audit = backend.target("p", backend.ROLE_AUDIT)
    doc = _pod(container="audit", template=True,
               mounts=[{"name": "home", "mountPath": "/var/aidc/dev-home"},
                       {"name": "audit", "mountPath": "/var/aidc/audit"}],
               volumes=[{"name": "home", "persistentVolumeClaim": {"claimName": "p-home"}},
                        {"name": "audit", "persistentVolumeClaim": {"claimName": "p-audit-1"}}])
    assert backend.mount_source(doc, audit, "/var/aidc/audit") == f"pvc:{NS}/p-audit-1"
    assert backend.mount_source(doc, audit, "/nowhere") is None
    assert backend.mount_source_args(audit, "/var/aidc/audit") == [
        "-n", NS, "get", "deployment/p-proxy", "-o", "json", "--request-timeout=10s"]
    assert backend.env_workdir_args("pod/p-dev-0:dev")[3] == "pod/p-dev-0"


def test_the_kubernetes_list_has_each_session_and_the_git_agent(k8s):
    doc = {"items": [
        {"kind": "StatefulSet", "metadata": {
            "labels": {"aidc/session": "proj", "app": "dev"}, "annotations": {"aidc/profile": "multi"},
            "creationTimestamp": "2026-11-26T10:00:00Z"}, "status": {"readyReplicas": 1}},
        {"kind": "StatefulSet", "metadata": {
            "labels": {"aidc/session": "new", "app": "dev"}, "creationTimestamp": "t2"},
         "status": {}},
        {"kind": "Deployment", "metadata": {
            "labels": {"aidc/session": "git", "app": "git"}, "creationTimestamp": "t3"},
         "status": {"readyReplicas": 1}},
        # Not sessions: a dev labelled with the git agent's name, a git with another name.
        {"kind": "StatefulSet", "metadata": {"labels": {"aidc/session": "git", "app": "dev"}}},
        {"kind": "Deployment", "metadata": {"labels": {"aidc/session": "x", "app": "git"}}},
        "junk",
    ]}
    assert backend.dev_rows(json.dumps(doc).encode()) == [
        {"name": "proj", "status": "running", "profile": "multi",
         "started": "2026-11-26T10:00:00Z"},
        {"name": "new", "status": "starting", "profile": "?", "started": "t2"},
        {"name": "git", "status": "running", "profile": "git-agent", "started": "t3"},
    ]
    assert backend.dev_rows(b"") == [] and backend.dev_rows(b"[") == []
    assert backend.dev_list_args() == [
        "-n", NS, "get", "statefulsets,deployments", "-l", "app in (dev,git)", "-o", "json",
        "--request-timeout=10s"]


def test_a_kubernetes_server_creates_in_the_cluster_whatever_the_config_says(k8s, tmp_path,
                                                                             monkeypatch):
    cfg = tmp_path / ".config" / "aidc" / "config.yaml"
    cfg.parent.mkdir(parents=True)
    cfg.write_text("backend: docker\n", encoding="utf-8")
    monkeypatch.setenv("HOME", str(tmp_path))
    assert backend.create_backend() == "kubernetes"


# --- the callers, against a kubectl stub ---------------------------------------------------

from aidc_mcp import session_facts as _sf  # noqa: E402

REAL_RUN = _sf.run_backend

KUBECTL_STUB = r'''#!/usr/bin/env python3
"""A kubectl for tests: records its argv, answers from the canned replies file."""
import json, os, sys
args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(json.dumps(args) + "\n")
replies = json.load(open(os.environ["STUB_REPLIES"]))
for reply in replies:
    if all(word in args for word in reply["when"]):
        sys.stdout.write(reply.get("out", ""))
        sys.stderr.write(reply.get("err", ""))
        sys.exit(reply.get("exit", 0))
sys.stderr.write("stub: no reply for " + " ".join(args))
sys.exit(2)
'''


@pytest.fixture
def kubectl(k8s, tmp_path, monkeypatch):
    """A kubectl stub first on PATH; returns (set replies, read the argv it was run with)."""
    d = tmp_path / "bin"
    d.mkdir()
    (d / "kubectl").write_text(KUBECTL_STUB)
    (d / "kubectl").chmod(0o755)
    log, replies = tmp_path / "kubectl.log", tmp_path / "replies.json"
    log.write_text("")
    replies.write_text("[]")
    monkeypatch.setenv("PATH", f"{d}:/usr/bin:/bin")
    monkeypatch.setenv("STUB_LOG", str(log))
    monkeypatch.setenv("STUB_REPLIES", str(replies))
    monkeypatch.setattr(_sf, "run_backend", REAL_RUN)

    def reply(*rules):
        replies.write_text(json.dumps(list(rules)))

    def calls():
        return [json.loads(line) for line in log.read_text().splitlines()]
    return reply, calls


async def test_session_facts_read_a_cluster_session_through_kubectl(kubectl):
    reply, calls = kubectl
    pod = json.loads(_pod(env=[{"name": "AIDC_REPO_PATH", "value": "/home/alice/r"}]))
    proxy = json.loads(_pod(container="audit", template=True,
                            mounts=[{"name": "audit", "mountPath": "/var/aidc/audit"}],
                            volumes=[{"name": "audit",
                                      "persistentVolumeClaim": {"claimName": "p-audit-9"}}]))
    reply({"when": ["pod/p-dev-0"], "out": json.dumps(pod)},
          {"when": ["deployment/p-proxy", "json"], "out": json.dumps(proxy)},
          {"when": ["policy", "cat", _sf.TAINT_FILE],
           "out": '{"tainted_at": "t", "trigger": "blocklist", "domain": "evil.example"}'},
          {"when": ["statefulsets,deployments"], "out": json.dumps({"items": [
              {"metadata": {"labels": {"aidc/session": "p", "app": "dev"}},
               "status": {"readyReplicas": 1}}]})})
    assert await _sf.repo_path("p") == "/home/alice/r"
    assert await _sf.audit_dir("p") == f"pvc:{NS}/p-audit-9"
    assert await _sf.read_taint("p") == {"at": "t", "trigger": "blocklist",
                                         "domain": "evil.example"}
    assert [r["name"] for r in await _sf.dev_containers() or []] == ["p"]
    assert all(c[:2] == ["-n", NS] for c in calls())
    taint = next(c for c in calls() if "exec" in c)
    assert taint == ["-n", NS, "exec", WAIT, "deployment/p-proxy", "-c", "policy", "--",
                     "cat", _sf.TAINT_FILE]


async def test_a_cluster_that_does_not_answer_is_no_answer_not_a_clean_session(kubectl):
    reply, _ = kubectl
    reply({"when": ["exec"], "exit": 1, "err": "Unable to connect to the server: EOF"},
          {"when": ["get"], "exit": 1, "err": "Unable to connect to the server: EOF"})
    with pytest.raises(_sf.TaintUnknown):
        await _sf.read_taint("p")
    assert await _sf.dev_containers() is None
    assert await _sf.repo_path("p") is None


async def test_a_missing_taint_flag_is_clean_but_a_missing_pod_is_not_read_as_one(kubectl):
    reply, _ = kubectl
    reply({"when": ["cat"], "exit": 1, "err": "cat: /var/state/tainted: No such file or directory"})
    assert await _sf.read_taint("p") is None
    reply({"when": ["cat"], "exit": 1,
           "err": 'Error from server (NotFound): deployments.apps "p-proxy" not found'})
    with pytest.raises(_sf.TaintUnknown):
        await _sf.read_taint("p")


async def test_the_instance_of_a_cluster_session_comes_from_kubectl(kubectl):
    from aidc_mcp.service import turns as tn

    reply, calls = kubectl
    reply({"when": ["p-state"], "out": "1f7c-uid"})
    assert await tn.session_instance("p") == (tn.SESSION_EXISTS, "1f7c-uid")
    reply({"when": ["p-state"], "exit": 1,
           "err": 'Error from server (NotFound): persistentvolumeclaims "p-state" not found'})
    assert await tn.session_instance("p") == (tn.SESSION_GONE, "")
    reply({"when": ["p-state"], "exit": 1, "err": "Unable to connect to the server: EOF"})
    assert await tn.session_instance("p") == (tn.SESSION_UNKNOWN, "")


async def test_tmux_reaches_a_cluster_sessions_claude_as_the_session_user(kubectl):
    from aidc_mcp.service import tmux

    reply, calls = kubectl
    reply({"when": ["capture-pane"], "out": "screen text\n"})
    assert "screen text" in await tmux.capture_screen(backend.target("p"), "claude")
    assert calls()[-1][:13] == ["-n", NS, "exec", WAIT, "pod/p-dev-0", "-c", "dev", "--",
                                "sudo", "-E", "-H", "-u", "vscode"]
    assert calls()[-1][14:16] == ["tmux", "capture-pane"]


@pytest.mark.parametrize(("kind", "ns"), [("podman", ""), ("kubernetes", ""),
                                          ("kubernetes", "Not_A_Namespace")])
def test_a_server_with_unusable_backend_settings_does_not_start(kind, ns, monkeypatch):
    """It stops before opening its store or serving, logged, rather than answering every
    call with kubectl's default namespace or a backend it does not have."""
    from aidc_mcp import audit, server

    monkeypatch.setenv(backend.KIND_ENV, kind)
    monkeypatch.setenv(backend.NAMESPACE_ENV, ns)
    logged = []
    monkeypatch.setattr(audit, "log_event", lambda event, **f: logged.append((event, f)))
    monkeypatch.setattr(server, "open_state_store", lambda: pytest.fail("store opened"))
    assert server.main() == 1
    assert logged[-1][0] == "server_start_refused"


async def test_a_kubernetes_servers_cli_calls_go_to_the_cluster(k8s, monkeypatch):
    """session_list, session_status and their resources run the CLI's session verbs with
    --backend kubernetes: without it the CLI asks the cluster and falls back to Docker,
    which the server's pod does not have, so a session the cluster lacks would read as a
    Docker failure. A Docker server passes nothing (its CLI's own rule decides)."""
    from aidc_mcp import resources
    from aidc_mcp.service import common as com
    from aidc_mcp.service import sessions as ses

    seen = []

    def cli(args, timeout=60.0):
        seen.append(args)
        return {"exit": 0, "stdout": "", "stderr": ""}
    monkeypatch.setattr(com, "run_cli", cli)
    monkeypatch.setattr(resources, "_run", lambda args: seen.append(args) or "")
    await ses.list_sessions()
    await ses.status("p")
    await resources.list_all_sessions()
    await resources.session_status_resource("p")
    assert seen.count(["list", "--backend", "kubernetes"]) == 2
    assert seen.count(["status", "p", "--backend", "kubernetes"]) == 2
    monkeypatch.setenv(backend.KIND_ENV, "docker")
    assert backend.cli_backend_args() == []


async def test_a_cluster_list_with_no_sessions_is_asked_once(kubectl):
    """The by-name fallback is for Docker sessions made before the labels; on Kubernetes it
    would be the same query again."""
    reply, calls = kubectl
    reply({"when": ["statefulsets,deployments"], "out": '{"items": []}'})
    assert await _sf.dev_containers() == []
    assert len([c for c in calls() if "statefulsets,deployments" in c]) == 1
