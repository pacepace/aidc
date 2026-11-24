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


def docker_leaks(source: str) -> list[str]:
    """Places in `source` that start the docker program or build an aidc container name:
    a string constant exactly "docker", or an f-string or constant beginning "aidc-" and
    ending in a role suffix."""
    found = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Constant) and node.value == "docker":
            found.append(f"line {node.lineno}: the string 'docker'")
        if isinstance(node, ast.JoinedStr) and node.values:
            first, last = node.values[0], node.values[-1]
            if (isinstance(first, ast.Constant) and str(first.value).startswith("aidc-")
                    and isinstance(last, ast.Constant)
                    and str(last.value) in ("-dev", "-policy", "-audit", "-net", "-proxy",
                                            "-refresher")):
                found.append(f"line {node.lineno}: an aidc container name")
    return found


def test_the_leak_scanner_catches_each_kind_of_leak():
    """Without this, a scanner that matched nothing would pass the real check forever."""
    assert docker_leaks('subprocess.run(["docker", "ps"])')
    assert docker_leaks('c = f"aidc-{name}-dev"')
    assert docker_leaks('n = f"aidc-{s}-net"')
    assert docker_leaks('p = f"aidc-{s}-proxy"')
    assert not docker_leaks('log("docker exec exited 1")')
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
