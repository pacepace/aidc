"""Headless runs (session_invoke, session_invoke_async): fresh, one at a time per
session, visible, and stopped in the container when nobody waits on them.

2026-10-22, metallm: two `claude --print` runs were still going 23 and 9 minutes after
their callers gave up, both editing the same spec, each resuming the resident agent's
whole conversation, and nothing an orchestrator could call showed them. Pace's rulings
that night: no timeout on session_invoke; one headless run at a time per dev
container; long work goes to session_send.

The in-container scripts are run here against this machine's own /proc, on a stand-in
claude process tree; the tools are driven with docker faked.
"""
import asyncio
import os
import signal
import subprocess
import sys
import time

import pytest
from mcp.server.mcpserver import MCPServer

from aidc_mcp import headless, tools

# The real listing: conftest stands it in for every test, and this one needs it.
_REAL_CONTAINER_RUNS = headless.container_runs


def _tool(name):
    app = MCPServer("t")
    tools.register(app)
    return app._tool_manager._tools[name].fn


# --- the in-container scripts, on real processes ------------------------------------

# A stand-in for `claude --print <prompt>`: argv[0] is .../claude, and it starts a child
# (as claude starts tools), which inherits its environment.
_CHILD = ("import subprocess, sys, time; "
          "c = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)']); "
          "print(c.pid, flush=True); time.sleep(120)")


@pytest.fixture
def fake_claude(tmp_path):
    procs = []
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin" / "claude").symlink_to(sys.executable)

    def start(run_id=None, prompt="edit the spec"):
        env = dict(os.environ)
        env.pop(headless.RUN_ENV, None)
        if run_id:
            env[headless.RUN_ENV] = run_id
        proc = subprocess.Popen([str(tmp_path / "bin" / "claude"), "-c", _CHILD, "--print",
                                 prompt], env=env,
                                stdout=subprocess.PIPE, text=True)
        child = int(proc.stdout.readline())
        procs.append((proc, child))
        return proc, child

    yield start
    for proc, child in procs:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass


def _bash(script, *args, run_env=True):
    env = dict(os.environ)
    if run_env:
        env["RUN_ENV"] = headless.RUN_ENV
    return subprocess.run(["bash", "-c", script, "x", *args], env=env, capture_output=True,
                          timeout=30).stdout


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie (killed, not yet reaped by the test) counts as gone.
    with open(f"/proc/{pid}/stat") as f:
        return f.read().split(")")[-1].split()[0] != "Z"


def test_the_listing_finds_a_headless_claude_with_its_tag_and_exact_prompt(fake_claude):
    proc, _ = fake_claude("session_invoke-abc123", "amend the spec\n§8.3, then reply")
    found = headless.parse_listing(_bash(headless._LIST_SCRIPT), time.time())
    mine = [f for f in found if f["pid"] == proc.pid]
    assert len(mine) == 1
    assert mine[0]["run_id"] == "session_invoke-abc123"
    assert mine[0]["prompt"] == "amend the spec\n§8.3, then reply"
    assert time.time() - mine[0]["started_at"] < 60


def test_the_listing_finds_an_untagged_one_too(fake_claude):
    """One started before this server tagged its runs, or by anything else."""
    proc, _ = fake_claude(None)
    found = headless.parse_listing(_bash(headless._LIST_SCRIPT), time.time())
    assert [f["run_id"] for f in found if f["pid"] == proc.pid] == [""]


def test_stopping_a_tagged_run_stops_its_whole_tree(fake_claude):
    proc, child = fake_claude("session_invoke-abc123")
    other, other_child = fake_claude("session_invoke-other")
    out = _bash(headless._KILL_SCRIPT, "session_invoke-abc123", "3")
    assert {int(p) for p in out.split()} == {proc.pid, child}
    proc.wait(timeout=10)
    for _ in range(50):
        if not _alive(child):
            break
        time.sleep(0.1)
    assert not _alive(child), "the run's child process is still running"
    assert other.poll() is None and _alive(other_child), "another run was stopped too"


def test_stopping_an_untagged_run_by_pid_stops_its_whole_tree(fake_claude):
    proc, child = fake_claude(None)
    out = _bash(headless._KILL_TREE_SCRIPT, str(proc.pid), "3", run_env=False)
    assert {int(p) for p in out.split()} == {proc.pid, child}
    proc.wait(timeout=10)
    for _ in range(50):
        if not _alive(child):
            break
        time.sleep(0.1)
    assert not _alive(child)


def test_a_run_is_started_fresh_and_tagged():
    run = headless.new_run("proj", "session_invoke", "q")
    argv = headless.exec_argv("aidc-proj-dev", run)
    assert argv[:2] == ["docker", "exec"]
    assert "AIDC_CLAUDE_RESUME=false" in argv
    assert f"{headless.RUN_ENV}={run.run_id}" in argv
    assert argv[-3:] == ["aidc-claude", "--print", "q"]


def test_what_status_shows_marks_runs_nobody_waits_on_as_orphans():
    run = headless.new_run("proj", "session_invoke", "mine " + "x" * 300)
    found = [{"pid": 11, "started_at": 1_800_000_000.0, "run_id": run.run_id, "prompt": "p"},
             {"pid": 12, "started_at": 1_800_000_100.0,
              "run_id": "session_invoke_async-9f", "prompt": "token=abcdefghijklmnopqrst"},
             {"pid": 13, "started_at": 1_800_000_200.0, "run_id": "", "prompt": "old"}]
    shown = {r["pid"]: r for r in headless.merge("proj", found)}
    assert shown[11]["orphan"] is False and shown[11]["run_id"] == run.run_id
    assert len(shown[11]["prompt"]) == headless.PROMPT_PREVIEW
    assert shown[12] == {"run_id": "session_invoke_async-9f",
                         "started_at": "2027-01-15T08:01:40Z", "tool": "session_invoke_async",
                         "prompt": "token=[redacted]", "pid": 12, "orphan": True}
    assert shown[13]["tool"] is None and shown[13]["run_id"] is None and shown[13]["orphan"]


def test_a_run_the_container_does_not_show_yet_is_still_listed():
    run = headless.new_run("proj", "session_invoke", "q")
    assert [r["run_id"] for r in headless.merge("proj", None)] == [run.run_id]


# --- the tools ----------------------------------------------------------------------


class _Proc:
    """A docker exec: answers `out` when released, or never until killed."""

    def __init__(self, out=b"the answer", rc=0, release=None):
        self.returncode = None
        self._rc = rc
        self._out = out
        self.release = release or asyncio.Event()
        self.killed = False
        self.stdout = self._stream(out)
        self.stderr = self._stream(b"")

    async def _stream(self, data):
        await self.release.wait()
        if data:
            yield data

    def kill(self):
        self.killed = True
        self.returncode = -9
        self.release.set()

    async def wait(self):
        await self.release.wait()
        if self.returncode is None:
            self.returncode = self._rc
        return self.returncode

    async def communicate(self):
        await self.wait()
        return self._out, b""


@pytest.fixture
def docker(monkeypatch):
    state = {"argv": [], "procs": [], "stopped": [], "found": [], "events": [],
             "release_now": True}

    async def create(*args, **kwargs):
        proc = _Proc()
        if state["release_now"]:
            proc.release.set()
        state["argv"].append(list(args))
        state["procs"].append(proc)
        return proc

    async def found(container):
        await asyncio.sleep(0)   # a docker round trip: lets a concurrent claim interleave
        return list(state["found"])

    async def stop(container, run):
        run.stopped = True   # as headless.stop does, before it reaches docker
        state["stopped"].append(("run", run.run_id))
        return [101]

    async def stop_tagged(container, run_id):
        state["stopped"].append(("tag", run_id))
        return [102]

    async def stop_tree(container, pid):
        state["stopped"].append(("pid", pid))
        return [pid]

    real_log = tools.log_event

    def log(kind, **fields):
        state["events"].append((kind, fields))
        real_log(kind, **fields)

    monkeypatch.setattr(tools.asyncio, "create_subprocess_exec", create)
    monkeypatch.setattr(headless, "container_runs", found)
    monkeypatch.setattr(headless, "stop", stop)
    monkeypatch.setattr(headless, "stop_tagged", stop_tagged)
    monkeypatch.setattr(headless, "stop_tree", stop_tree)
    monkeypatch.setattr(tools, "log_event", log)
    return state


async def test_an_invoke_runs_fresh_and_says_how_long_it_took(docker):
    res = await _tool("session_invoke")(name="proj", prompt="what does f return?")
    assert res["ok"] is True and res["data"]["response"] == "the answer"
    assert "AIDC_CLAUDE_RESUME=false" in docker["argv"][0]
    assert isinstance(res["data"]["elapsed_s"], float) and "warning" not in res["data"]
    assert headless._runs == {}


async def test_a_long_invoke_is_told_that_long_work_belongs_to_session_send(docker, monkeypatch):
    monkeypatch.setattr(tools, "_INVOKE_LONG_S", -1.0)
    res = await _tool("session_invoke")(name="proj", prompt="q")
    assert "session_send" in res["data"]["warning"]


async def test_a_second_invoke_while_one_runs_is_refused_with_what_runs(docker):
    docker["release_now"] = False
    first = asyncio.create_task(_tool("session_invoke")(name="proj", prompt="edit the spec"))
    for _ in range(20):
        await asyncio.sleep(0)
    res = await _tool("session_invoke")(name="proj", prompt="also this")
    assert res["ok"] is False and res["error_code"] == "invoke_busy"
    running = res["data"]["running"]
    assert running["tool"] == "session_invoke" and running["prompt"] == "edit the spec"
    assert running["run_id"].startswith("session_invoke-") and "started_at" in running
    assert "session_send" in res["error"] and 'target "headless"' in res["error"]
    assert len(docker["procs"]) == 1
    docker["procs"][0].release.set()
    assert (await first)["ok"] is True
    docker["release_now"] = True
    assert (await _tool("session_invoke")(name="proj", prompt="now"))["ok"] is True


async def test_an_orphan_left_from_before_a_restart_holds_the_session(docker, monkeypatch):
    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "http://cb")
    docker["found"] = [{"pid": 77, "started_at": time.time() - 600, "run_id": "",
                        "prompt": "edit the spec"}]
    for tool, args in (("session_invoke", {}), ("session_invoke_async",
                                                {"conversation_id": "c1"})):
        res = await _tool(tool)(name="proj", prompt="q", **args)
        assert res["error_code"] == "invoke_busy", tool
        assert res["data"]["running"]["pid"] == 77 and res["data"]["running"]["orphan"]
    assert docker["procs"] == []


async def test_two_invokes_arriving_together_get_one_run(docker):
    docker["release_now"] = False
    a = asyncio.create_task(_tool("session_invoke")(name="proj", prompt="a"))
    b = asyncio.create_task(_tool("session_invoke")(name="proj", prompt="b"))
    for _ in range(50):
        await asyncio.sleep(0)
    assert len(docker["procs"]) == 1
    docker["procs"][0].release.set()
    results = await asyncio.gather(a, b)
    assert sorted(r["ok"] for r in results) == [False, True]


async def test_another_sessions_run_does_not_hold_this_one(docker):
    headless.new_run("other", "session_invoke", "x")
    assert (await _tool("session_invoke")(name="proj", prompt="q"))["ok"] is True


async def test_an_async_invoke_claims_the_session_before_it_returns(docker, monkeypatch):
    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "http://cb")
    fired = []
    monkeypatch.setattr(tools, "fire", lambda coro: (fired.append(coro), coro.close()))
    res = await _tool("session_invoke_async")(name="proj", prompt="q", conversation_id="c1")
    assert res["ok"] is True
    again = await _tool("session_invoke")(name="proj", prompt="q2")
    assert again["error_code"] == "invoke_busy"
    assert again["data"]["running"]["tool"] == "session_invoke_async"


async def test_a_cancelled_invoke_is_stopped_in_the_container(docker):
    docker["release_now"] = False
    task = asyncio.create_task(_tool("session_invoke")(name="proj", prompt="edit the spec"))
    for _ in range(20):
        await asyncio.sleep(0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    for _ in range(20):
        await asyncio.sleep(0)
    assert docker["stopped"] and docker["stopped"][0][0] == "run"
    assert docker["procs"][0].killed
    assert "session_invoke_cancelled" in [k for k, _ in docker["events"]]
    assert headless._runs == {}


async def test_an_async_invoke_past_its_limit_is_stopped_in_the_container(docker, monkeypatch):
    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "http://cb")
    monkeypatch.setattr(tools, "_ASYNC_INVOKE_TIMEOUT_S", 0.05)
    monkeypatch.setattr(tools, "_load_token", lambda: "t")
    docker["release_now"] = False
    jobs = []
    monkeypatch.setattr(tools, "fire", lambda coro: jobs.append(coro))

    class _Http:
        def __init__(self, *a, **k):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def post(self, url, json, headers):
            docker["posted"] = json
            return type("R", (), {"is_success": True, "status_code": 202, "text": ""})()

    monkeypatch.setattr(tools.httpx, "AsyncClient", _Http)
    await _tool("session_invoke_async")(name="proj", prompt="q", conversation_id="c1")
    await jobs[0]
    assert docker["stopped"][0][0] == "run"
    assert docker["posted"]["ok"] is False and "timed out" in docker["posted"]["content"]
    assert "session_invoke_async_timed_out" in [k for k, _ in docker["events"]]
    assert headless._runs == {}


async def test_status_lists_the_headless_runs(docker, monkeypatch, idle_session):
    monkeypatch.setattr(tools, "_run_cli", lambda args, timeout=60.0: {
        "exit": 0, "stdout": "ok", "stderr": ""})
    docker["found"] = [{"pid": 77, "started_at": 1_800_000_000.0, "run_id": "",
                        "prompt": "edit the spec"}]
    d = (await _tool("session_status")(name="proj"))["data"]
    assert d["headless_runs"] == [{"run_id": None, "started_at": "2027-01-15T08:00:00Z",
                                   "tool": None, "prompt": "edit the spec", "pid": 77,
                                   "orphan": True}]


async def test_interrupting_the_headless_run_stops_a_call_still_waiting(docker, monkeypatch):
    async def tree(name):
        return None
    monkeypatch.setattr(tools, "_tree", tree)
    docker["release_now"] = False
    ctx = type("Ctx", (), {"headers": {"mcp-session-id": "s1"}, "request_id": "7",
                           "info": staticmethod(lambda chunk: asyncio.sleep(0))})()
    call = asyncio.create_task(_tool("session_invoke")(name="proj", prompt="edit", ctx=ctx))
    for _ in range(20):
        await asyncio.sleep(0)
    run_id = next(iter(headless._runs))
    res = await _tool("session_interrupt")(name="proj", target="headless")
    d = res["data"]
    assert d["interrupted"] is True and d["target"] == "headless"
    assert [r["run_id"] for r in d["stopped"]] == [run_id] and d["pids"] == [101]
    assert docker["procs"][0].killed
    assert (await call)["ok"] is False    # the call it stopped returns


async def test_interrupting_an_orphan_finds_it_in_the_container(docker, monkeypatch):
    async def tree(name):
        return None
    monkeypatch.setattr(tools, "_tree", tree)
    docker["found"] = [{"pid": 77, "started_at": 1.0, "run_id": "session_invoke-aa",
                        "prompt": "x"},
                       {"pid": 78, "started_at": 2.0, "run_id": "", "prompt": "y"}]
    d = (await _tool("session_interrupt")(name="proj", target="headless"))["data"]
    assert docker["stopped"] == [("tag", "session_invoke-aa"), ("pid", 78)]
    assert d["pids"] == [102, 78]


async def test_interrupting_with_no_headless_run_does_nothing(docker, monkeypatch):
    async def tree(name):
        return None
    monkeypatch.setattr(tools, "_tree", tree)
    d = (await _tool("session_interrupt")(name="proj", target="headless"))["data"]
    assert d["interrupted"] is False and d["note"] == "no headless run was going"
    assert d["stopped"] == [] and docker["stopped"] == []


async def test_an_unknown_interrupt_target_is_refused(docker):
    res = await _tool("session_interrupt")(name="proj", target="everything")
    assert res["error_code"] == "invalid_argument"


def test_the_descriptions_lead_with_the_rule():
    """A model skimming the first line must get it: invoke is for short, single-shot
    questions, and long work goes to session_send (Pace, 2026-10-22)."""
    app = MCPServer("t")
    tools.register(app)
    t = app._tool_manager._tools
    for name in ("session_invoke", "session_invoke_async"):
        first = t[name].description.splitlines()[0]
        assert "SHORT, single-shot" in first and "session_send" in first, name
        assert "invoke_busy" in t[name].description
        for example in ("run the tests", "amend the spec", "implement"):
            assert example in t[name].description, (name, example)
    assert "anything long" in t["session_send"].description.splitlines()[0]
    assert "session_invoke is only for short" in " ".join(t["session_send"].description.split())


# --- a stop that fails is said to have failed -------------------------------------


async def test_docker_failing_is_an_error_not_an_empty_answer(monkeypatch):
    async def no_docker(*args, **kwargs):
        raise FileNotFoundError("docker")
    monkeypatch.setattr(asyncio, "create_subprocess_exec", no_docker)
    with pytest.raises(headless.DockerFailed):
        await headless.stop_tagged("aidc-proj-dev", "session_invoke-aa")
    with pytest.raises(headless.DockerFailed):
        await headless.stop_tree("aidc-proj-dev", 77)
    run = headless.new_run("proj", "session_invoke", "q")
    with pytest.raises(headless.DockerFailed):
        await headless.stop("aidc-proj-dev", run)
    assert run.stopped   # so a run not started yet never starts


async def test_a_paused_or_gone_container_lists_as_unknown_not_as_empty(monkeypatch):
    """A tainted session's container is paused: nothing can be listed in it, which is
    not the same as nothing running."""
    async def failing(*args, **kwargs):
        raise headless.DockerFailed("docker exited 1: container is paused")
    monkeypatch.setattr(headless, "_docker", failing)
    assert await _REAL_CONTAINER_RUNS("aidc-proj-dev") is None


async def test_an_interrupt_whose_stop_fails_says_it_did_not_interrupt(docker, monkeypatch):
    async def tree(name):
        return None
    monkeypatch.setattr(tools, "_tree", tree)

    async def failing(container, run_id):
        raise headless.DockerFailed("docker exited 1: container is paused")
    monkeypatch.setattr(headless, "stop_tagged", failing)
    docker["found"] = [{"pid": 77, "started_at": 1.0, "run_id": "session_invoke-aa",
                        "prompt": "x"}]
    d = (await _tool("session_interrupt")(name="proj", target="headless"))["data"]
    assert d["interrupted"] is False and "paused" in d["note"]
    assert d["stopped"][0]["run_id"] == "session_invoke-aa"
    assert "headless_stop_failed" in [k for k, _ in docker["events"]]


async def test_an_interrupt_that_cannot_read_the_container_says_so(docker, monkeypatch):
    async def tree(name):
        return None
    monkeypatch.setattr(tools, "_tree", tree)

    async def unreadable(container):
        return None
    monkeypatch.setattr(headless, "container_runs", unreadable)
    d = (await _tool("session_interrupt")(name="proj", target="headless"))["data"]
    assert d["interrupted"] is False and "could not be read" in d["note"]


async def test_a_cancelled_invoke_whose_stop_fails_is_logged_as_failed(docker, monkeypatch):
    async def failing(container, run):
        raise headless.DockerFailed("docker did not answer within 23 s")
    monkeypatch.setattr(headless, "stop", failing)
    docker["release_now"] = False
    task = asyncio.create_task(_tool("session_invoke")(name="proj", prompt="edit"))
    for _ in range(20):
        await asyncio.sleep(0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    for _ in range(20):
        await asyncio.sleep(0)
    kinds = [k for k, _ in docker["events"]]
    assert "headless_stop_failed" in kinds and "session_invoke_cancelled" not in kinds
    assert docker["procs"][0].killed


async def test_a_claim_made_without_a_container_listing_is_logged(docker, monkeypatch):
    async def unreadable(container):
        return None
    monkeypatch.setattr(headless, "container_runs", unreadable)
    assert (await _tool("session_invoke")(name="proj", prompt="q"))["ok"] is True
    assert "headless_claim_without_listing" in [k for k, _ in docker["events"]]


async def test_an_async_run_stopped_before_it_started_never_starts(docker, monkeypatch):
    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: "http://cb")
    monkeypatch.setattr(tools, "_load_token", lambda: "t")

    async def tree(name):
        return None
    monkeypatch.setattr(tools, "_tree", tree)
    jobs = []
    monkeypatch.setattr(tools, "fire", lambda coro: jobs.append(coro))

    class _Http:
        def __init__(self, *a, **k):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def post(self, url, json, headers):
            docker["posted"] = json
            return type("R", (), {"is_success": True, "status_code": 202, "text": ""})()

    monkeypatch.setattr(tools.httpx, "AsyncClient", _Http)
    await _tool("session_invoke_async")(name="proj", prompt="q", conversation_id="c1")
    d = (await _tool("session_interrupt")(name="proj", target="headless"))["data"]
    assert d["interrupted"] is True
    await jobs[0]
    assert docker["procs"] == []
    assert docker["posted"]["ok"] is False and "before it started" in docker["posted"]["content"]
