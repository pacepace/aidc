"""The backend module is the only place that knows sessions run on Docker.

If another module starts `docker` itself or spells a container name, a second backend
(Kubernetes, docs/design-12-kubernetes.md) would silently keep talking to Docker on that path.
"""

from __future__ import annotations

import ast
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
    assert backend.mount_source(b"/home/u/audit/p\n") == "/home/u/audit/p"
    assert backend.mount_source(b"\n") is None
    env, wd = backend.env_and_workdir(b"PATH=/bin\nAIDC_REPO_PATH=/r\nX=a=b\n\x1f/w\n")
    assert env == {"PATH": "/bin", "AIDC_REPO_PATH": "/r", "X": "a=b"} and wd == "/w"
    assert backend.env_and_workdir(b"") == ({}, "")


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
