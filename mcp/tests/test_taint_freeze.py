"""A tainted session on Kubernetes: its policy sidecar pokes the user's server, which freezes it.

The poke (W-M4) only says which session to look at: the server reads the taint flag itself.
With the session's response `freeze` (SEC-05/08), the server cuts every egress rule of the
session's NetworkPolicies and marks it frozen beside the flag (plan-aidc-2.0 Q-K3); a policy
a later apply opened again is cut again (SEC-06). A poke that never came is made up for by
looking at every session now and then.
"""
from __future__ import annotations

import json

import pytest
from starlette.testclient import TestClient

from aidc_mcp import audit, backend, server
from aidc_mcp import session_facts as sf
from aidc_mcp.service import common as com
from aidc_mcp.service import state as ss
from aidc_mcp.service import taint as tnt
from aidc_mcp.service import turns as tn

TAINT = b'{"tainted_at":"2026-11-26T09:00:00Z","trigger":"malware_domains","domain":"evil.example"}\n'
NS = "aidc-u-alice"


def _policies(*specs):
    """A NetworkPolicy listing: (name, policyTypes, egress rules)."""
    return json.dumps({"items": [
        {"metadata": {"name": n}, "spec": {"policyTypes": t, "egress": e}} for n, t, e in specs
    ]}).encode()


OPEN = _policies(
    ("demo-dev-only-to-its-proxy", ["Ingress", "Egress"], [{"to": [{"podSelector": {}}]}]),
    ("demo-proxy-public-only", ["Ingress", "Egress"], [{"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}]}]),
    ("demo-expose", ["Ingress"], None),
)
CUT = _policies(
    ("demo-dev-only-to-its-proxy", ["Ingress", "Egress"], []),
    ("demo-proxy-public-only", ["Ingress", "Egress"], []),
    ("demo-expose", ["Ingress"], None),
)


class Cluster:
    """The session's pods and policies as kubectl shows them, and what the server did."""

    def __init__(self, *, tainted=True, response="freeze", policies=OPEN, frozen=None):
        self.tainted, self.response, self.policies, self.frozen = tainted, response, policies, frozen
        self.patched: list[str] = []
        self.marks: list[dict] = []
        self.troubles: list = []
        self.flag_fails = self.patch_fails = self.response_fails = False
        self.instance = "uid-1"

    async def run(self, *args, timeout=20.0):
        a = list(args)
        if "exec" in a and "cat" in a and sf.TAINT_FILE in a:
            if self.flag_fails:
                return sf.BackendResult(1, b"", b"error: unable to upgrade connection")
            return (sf.BackendResult(0, TAINT, b"") if self.tainted else
                    sf.BackendResult(1, b"", b"cat: /var/state/tainted: No such file or directory"))
        if "exec" in a and "cat" in a and sf.FROZEN_FILE in a:
            return (sf.BackendResult(0, json.dumps(self.frozen).encode(), b"") if self.frozen else
                    sf.BackendResult(1, b"", b"cat: /var/state/frozen: No such file or directory"))
        if "exec" in a and "aidc-freeze-trouble" in a:
            self.troubles.append(json.loads(a[a.index("aidc-freeze-trouble") + 1]))
            return sf.BackendResult(0, b"", b"")
        if "exec" in a and "rm" in a and sf.FREEZE_TROUBLE_FILE in a:
            self.troubles.append(None)
            return sf.BackendResult(0, b"", b"")
        if "exec" in a and "aidc-freeze" in a:
            self.frozen = json.loads(a[a.index("aidc-freeze") + 1])
            self.marks.append(self.frozen)
            return sf.BackendResult(0, b"", b"")
        if "get" in a and "deployment/demo-proxy" in a:
            if self.response_fails:
                return sf.BackendResult(1, b"", b"Error from server (Forbidden): deployments.apps is forbidden")
            env = [{"name": "AIDC_TAINT_RESPONSE", "value": self.response}]
            doc = {"spec": {"template": {"spec": {"containers": [{"name": "policy", "env": env}]}}}}
            return sf.BackendResult(0, json.dumps(doc).encode(), b"")
        if "get" in a and "networkpolicy" in a:
            return sf.BackendResult(0, self.policies, b"")
        if "patch" in a and "networkpolicy" in a:
            if self.patch_fails:
                return sf.BackendResult(1, b"", b"forbidden")
            name = a[a.index("networkpolicy") + 1]
            self.patched.append(name)
            return sf.BackendResult(0, b"", b"")
        if "statefulsets,deployments" in a:
            return sf.BackendResult(0, json.dumps({"items": [
                {"metadata": {"labels": {"aidc/session": "demo", "app": "dev"}}, "status": {}},
                {"metadata": {"labels": {"aidc/session": "git", "app": "git"}}, "status": {}},
            ]}).encode(), b"")
        raise AssertionError(f"unexpected: {a}")


@pytest.fixture(autouse=True)
def _fresh_taint_state():
    for table in (ss.taint_reported, ss.freeze_trouble, ss.taint_locks):
        table.clear()


@pytest.fixture
def k8s(monkeypatch):
    monkeypatch.setenv(backend.KIND_ENV, "kubernetes")
    monkeypatch.setenv(backend.NAMESPACE_ENV, NS)


@pytest.fixture
def events(monkeypatch):
    seen = []
    monkeypatch.setattr(audit, "log_event", lambda kind, **f: seen.append((kind, f)))
    changed = []
    monkeypatch.setattr(com, "session_changed", lambda name: changed.append(name))
    return seen, changed


def _use(monkeypatch, cluster):
    monkeypatch.setattr(sf, "run_backend", cluster.run)

    async def instance(name):
        return tn.SESSION_EXISTS, cluster.instance
    monkeypatch.setattr(tn, "session_instance", instance)


async def test_a_tainted_session_whose_response_is_freeze_has_every_egress_rule_cut(
        k8s, events, monkeypatch):
    c = Cluster()
    _use(monkeypatch, c)
    assert await tnt.check("demo") == "frozen"
    assert sorted(c.patched) == ["demo-dev-only-to-its-proxy", "demo-proxy-public-only"]
    assert c.marks and sorted(c.marks[0]["egress_cut"]) == sorted(c.patched)
    assert c.marks[0]["by"] == "aidc-mcp" and c.marks[0]["frozen_at"].endswith("Z")
    kinds = [k for k, _ in events[0]]
    assert "session_tainted" in kinds and "session_frozen" in kinds
    assert "session_refrozen" not in kinds          # a first freeze is not a re-freeze
    assert c.troubles == [None]                     # a trouble left from before is removed
    assert events[1] == ["demo", "demo"]   # tainted, then frozen: subscribers told each time


async def test_a_frozen_session_is_left_as_it_is_and_one_opened_again_is_cut_again(
        k8s, events, monkeypatch):
    c = Cluster(policies=CUT, frozen={"frozen_at": "2026-11-26T09:00:05Z"})
    _use(monkeypatch, c)
    assert await tnt.check("demo") == "frozen"
    assert c.patched == [] and c.marks == []
    c.policies = _policies(("demo-proxy-public-only", ["Egress"],
                            [{"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}]}]))
    assert await tnt.check("demo") == "frozen"
    assert c.patched == ["demo-proxy-public-only"] and c.marks == []
    assert "session_refrozen" in [k for k, _ in events[0]]


@pytest.mark.parametrize("response", ["notify", "log"])
async def test_a_session_whose_response_is_not_freeze_is_only_reported(
        k8s, events, monkeypatch, response):
    c = Cluster(response=response)
    _use(monkeypatch, c)
    assert await tnt.check("demo") == "tainted"
    assert c.patched == [] and c.marks == []
    assert "session_tainted" in [k for k, _ in events[0]]


async def test_a_clean_session_is_never_cut_whoever_pokes(k8s, events, monkeypatch):
    """A poke is not trusted: the flag decides."""
    c = Cluster(tainted=False)
    _use(monkeypatch, c)
    assert await tnt.check("demo") == "clean"
    assert c.patched == [] and c.marks == [] and events[1] == []


async def test_an_unreadable_flag_is_unknown_and_nothing_is_cut(k8s, events, monkeypatch):
    c = Cluster()
    c.flag_fails = True
    _use(monkeypatch, c)
    assert await tnt.check("demo") == "unknown"
    assert c.patched == [] and c.marks == []


async def test_a_cut_the_cluster_refuses_is_a_failed_freeze_and_not_marked(
        k8s, events, monkeypatch):
    """The mark says the egress is cut: it is written only when it is."""
    c = Cluster()
    c.patch_fails = True
    _use(monkeypatch, c)
    assert await tnt.check("demo") == "freeze_failed"
    assert c.marks == []
    assert "session_freeze_stalled" in [k for k, _ in events[0]]
    assert c.troubles and c.troubles[-1]["step"] == "cut_egress"


async def test_on_docker_the_server_leaves_the_freeze_to_the_sidecar(events, monkeypatch):
    """The Docker sidecar pauses the dev container itself; the server only reports."""
    c = Cluster()
    _use(monkeypatch, c)
    assert await tnt.check("demo") == "tainted"
    assert c.patched == [] and c.marks == []


async def test_a_stalled_freeze_is_logged_once_until_its_cause_changes_and_shown_to_status(
        k8s, events, monkeypatch):
    """The reconcile tries every minute: the log says what stops the freeze once, not every
    minute, and the reason is left beside the flag for `aidc status`; once frozen it goes."""
    c = Cluster()
    c.response_fails = True
    _use(monkeypatch, c)
    for _ in range(3):
        assert await tnt.check("demo") == "unknown"
    stalls = [f for k, f in events[0] if k == "session_freeze_stalled"]
    assert len(stalls) == 1 and stalls[0]["step"] == "read_response"
    assert "Forbidden" in stalls[0]["error"]
    assert len(c.troubles) == 1 and c.troubles[0]["step"] == "read_response"
    c.response_fails, c.patch_fails = False, True
    assert await tnt.check("demo") == "freeze_failed"
    assert len([1 for k, _ in events[0] if k == "session_freeze_stalled"]) == 2
    c.patch_fails = False
    assert await tnt.check("demo") == "frozen"
    assert c.troubles[-1] is None and "demo" not in ss.freeze_trouble
    assert "session_refrozen" not in [k for k, _ in events[0]]


async def test_a_refreeze_after_a_stall_is_logged_and_clears_the_trouble(k8s, events, monkeypatch):
    """Already frozen, a rule opened again and the first cut refused: the second pass cuts it,
    logs the re-freeze, and removes the trouble it left."""
    c = Cluster(frozen={"frozen_at": "2026-11-26T09:00:05Z"},
                policies=_policies(("demo-proxy-public-only", ["Egress"],
                                    [{"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}]}])))
    c.patch_fails = True
    _use(monkeypatch, c)
    assert await tnt.check("demo") == "freeze_failed"
    c.patch_fails = False
    assert await tnt.check("demo") == "frozen"
    assert "session_refrozen" in [k for k, _ in events[0]]
    assert c.troubles[-1] is None and c.marks == []


async def test_a_session_created_again_and_tainted_again_is_reported_again(
        k8s, events, monkeypatch):
    """Reported once per instance: the report of one session is never the next one's, even
    when the reconcile never saw it clean in between."""
    c = Cluster(response="notify")
    _use(monkeypatch, c)
    await tnt.check("demo")
    await tnt.check("demo")
    assert [k for k, _ in events[0]].count("session_tainted") == 1
    c.instance = "uid-2"
    await tnt.check("demo")
    assert [k for k, _ in events[0]].count("session_tainted") == 2
    assert events[1] == ["demo", "demo"]


async def test_the_taint_tables_are_the_service_states_and_forgotten_with_the_session(
        k8s, events, monkeypatch):
    c = Cluster(response="notify")
    _use(monkeypatch, c)
    await tnt.check("demo")
    assert "demo" in ss.taint_reported and "demo" in ss.taint_locks
    ss.forget_session_send_state("demo")
    assert "demo" not in ss.taint_reported and "demo" not in ss.taint_locks


async def test_reconcile_looks_at_every_session_but_the_git_agent(k8s, events, monkeypatch):
    c = Cluster()
    _use(monkeypatch, c)
    looked = []
    real = tnt.check

    async def check(name):
        looked.append(name)
        return await real(name)
    monkeypatch.setattr(tnt, "check", check)
    await tnt.reconcile_once()
    assert looked == ["demo"]
    assert sorted(c.patched) == ["demo-dev-only-to-its-proxy", "demo-proxy-public-only"]


@pytest.mark.parametrize(("stdout", "names"), [
    (OPEN, ["demo-dev-only-to-its-proxy", "demo-proxy-public-only"]),
    (CUT, []),
    (_policies(("x", ["Egress"], None)), []),
    (b"", None),
    (b"not json", None),
    (b'{"items": "x"}', None),
])
def test_only_policies_that_still_let_a_pod_out_are_cut(stdout, names):
    assert backend.egress_to_cut(stdout) == names


def test_the_cut_keeps_what_the_policy_lets_in(k8s):
    args = backend.cut_egress_args("demo-proxy-public-only")
    assert args[:6] == ["-n", NS, "patch", "networkpolicy", "demo-proxy-public-only", "--type=json"]
    assert json.loads(args[args.index("-p") + 1]) == [
        {"op": "add", "path": "/spec/egress", "value": []}]
    assert backend.session_policies_args("demo")[3:6] == ["networkpolicy", "-l", "aidc/session=demo"]


# --- the webhook ------------------------------------------------------------------------------

@pytest.fixture
def webhook(monkeypatch, events):
    poked = []
    monkeypatch.setattr(tnt, "poked", lambda name: poked.append(name))
    return TestClient(server.build_taint_app()), poked


def test_a_poke_names_a_session_and_is_answered_at_once(webhook, events):
    client, poked = webhook
    r = client.post("/taint", json={"session": "demo"})
    assert r.status_code == 202 and poked == ["demo"]
    assert ("taint_webhook", {"session": "demo", "client": "testclient"}) in events[0]


@pytest.mark.parametrize("body", [
    b'{"session": "../etc"}', b'{"session": "git"}', b'{"session": 5}', b'{}', b'[]',
    b"not json", b'{"session": "' + b"a" * 2000 + b'"}',
])
def test_anything_but_a_session_name_is_refused_and_logged(webhook, events, body):
    client, poked = webhook
    r = client.post("/taint", content=body, headers={"content-type": "application/json"})
    assert r.status_code == 400 and poked == []
    assert "taint_webhook_refused" in [k for k, _ in events[0]]


@pytest.mark.parametrize(("method", "path"), [("GET", "/taint"), ("POST", "/mcp"),
                                              ("GET", "/metrics"), ("POST", "/")])
def test_the_webhook_port_serves_nothing_else(webhook, events, method, path):
    """Not the MCP endpoint, nor metrics: only the poke is on this port."""
    client, poked = webhook
    r = client.request(method, path)
    assert r.status_code in (404, 405) and poked == []


def test_a_cluster_server_watches_every_sessions_flag_from_its_start(k8s, monkeypatch, tmp_path):
    started = []

    async def watch():
        started.append(True)
    monkeypatch.setattr(tnt, "watch", watch)
    (tmp_path / "token").write_text("t0ken\n", encoding="utf-8")
    monkeypatch.setattr(server.auth, "_TOKEN_PATH", tmp_path / "token")
    with TestClient(server.build_app()):
        pass
    assert started == [True]


def _free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_the_server_answers_on_both_ports_and_stops_cleanly_on_sigterm(tmp_path):
    """main() with a taint port: the MCP port keeps its bearer gate, the webhook port has only
    the poke, and one SIGTERM stops both and the process returns 0."""
    import os
    import signal
    import subprocess
    import sys
    import time
    import urllib.error
    import urllib.request

    mcp_port, taint_port = _free_port(), _free_port()
    (tmp_path / "mcp-token").write_text("t0ken\n", encoding="utf-8")
    env = {**os.environ, "AIDC_MCP_PORT": str(mcp_port), "AIDC_MCP_TAINT_PORT": str(taint_port),
           "AIDC_MCP_TOKEN_FILE": str(tmp_path / "mcp-token"),
           "AIDC_MCP_AUDIT_LOG": str(tmp_path / "access.log"),
           "AIDC_MCP_WATCHER_STATE": str(tmp_path / "state"),
           "AIDC_MCP_TRANSCRIPTS": str(tmp_path / "transcripts")}
    env.pop(backend.KIND_ENV, None)
    proc = subprocess.Popen([sys.executable, "-m", "aidc_mcp"], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        def status(port, path, data=None):
            req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                         headers={"content-type": "application/json"})
            try:
                return urllib.request.urlopen(req, timeout=2).status
            except urllib.error.HTTPError as exc:
                return exc.code

        deadline = time.time() + 30
        while True:
            try:
                status(taint_port, "/taint", b"{}")
                status(mcp_port, "/mcp", b"{}")
                break
            except OSError:
                assert time.time() < deadline, "the server did not come up on both ports"
                time.sleep(0.3)
        assert status(mcp_port, "/mcp", b"{}") == 401          # the bearer gate, unchanged
        assert status(taint_port, "/taint", b'{"session": 1}') == 400
        assert status(taint_port, "/mcp", b"{}") in (404, 405)  # only the poke here
        proc.send_signal(signal.SIGTERM)
        assert proc.wait(timeout=20) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    assert "taint_webhook_refused" in (tmp_path / "access.log").read_text(encoding="utf-8")
