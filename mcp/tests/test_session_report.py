"""What a session is DOING, not only whether its containers are up.

An orchestrator's helper, asked what two sessions were working on, answered "all five
subprocesses running, squid healthy": session_status said nothing else. It now says
whether the coding agent is working and on what, its repository and branch, its taint
as a typed field, and where its audit trail is; session_list says the same per session.
session_interrupt and session_queue_cancel say what was running when they acted.
"""
import json
import os
import time

import pytest
from mcp.server.mcpserver import MCPServer

from aidc_mcp import repo, scope, tools
from aidc_mcp import session_facts as sf
from aidc_mcp import transcript as ts

OLD = time.time() - 3600


class _StubTask:
    def cancel(self):
        pass


def _tool(name):
    app = MCPServer("t")
    tools.register(app)
    return app._tool_manager._tools[name].fn


@pytest.fixture
def facts(monkeypatch, tmp_path):
    """A session `proj`: tainted or not, its audit mount and repo, a transcript whose
    newest turn finished at 09:01:30 and whose open prompt is 'fix the flaky test'."""
    state = {"tainted": False, "working": True}

    async def run(*args, timeout=20.0):
        if sf.TAINT_FILE in args:
            if state["tainted"]:
                return sf.DockerResult(0, b'{"tainted_at":"2026-10-14T09:00:00Z",'
                                          b'"trigger":"blocklist","domain":"evil.example"}', b"")
            return sf.DockerResult(1, b"", b"cat: No such file or directory")
        if args[:2] == ("inspect", "aidc-proj-audit"):
            return sf.DockerResult(0, b"/home/u/audit/proj\n", b"")
        if args[:2] == ("inspect", "aidc-proj-dev"):
            return sf.DockerResult(0, b"PATH=/bin\nAIDC_REPO_PATH=/home/u/code/proj\n\x1f/x\n", b"")
        if args[0] == "ps":
            return sf.DockerResult(0, b"aidc-proj-dev\tUp 2 hours\tmulti\t2026-10-14 07:00:00\n"
                                      b"aidc-other-dev\tExited (0)\tpython\t2026-10-13\n", b"")
        return sf.DockerResult(1, b"", b"No such file or directory")
    monkeypatch.setattr(sf, "run_docker", run)

    async def session_state(container, name):
        if name == "proj" and state["working"]:
            return tools.SessionState(True, None, tools.TURN_RUNNING, "log_growing")
        return tools.SessionState(name == "proj", None, tools.TURN_IDLE, "log_finished")
    monkeypatch.setattr(tools, "_session_state", session_state)

    async def branch(name, repo_dir):
        return "project/fix-1234abcd"

    async def head(name, repo_dir):
        return "0123456789ab"

    async def status(name, repo_dir):
        return {"branch": "project/fix-1234abcd", "head": "0123456789ab",
                "changes": [{"path": "a.py", "status": ".M"}]}
    monkeypatch.setattr(repo, "current_branch", branch)
    monkeypatch.setattr(repo, "head", head)
    monkeypatch.setattr(repo, "status", status)
    monkeypatch.setattr(tools, "_run_cli", lambda args, timeout=60.0: {
        "exit": 0, "stdout": "SESSION ...\nproj Up\nother Exited\n", "stderr": ""})

    monkeypatch.setattr(tools, "_TRANSCRIPTS_BASE", tmp_path / "transcripts")
    path = tmp_path / "transcripts" / "proj" / "s1.jsonl"
    path.parent.mkdir(parents=True)
    lines = [
        {"type": "user", "uuid": "u1", "timestamp": "2026-10-14T09:01:00.000Z",
         "message": {"role": "user", "content": [{"type": "text", "text": "what is f"}]}},
        {"type": "assistant", "uuid": "a1", "timestamp": "2026-10-14T09:01:30.000Z",
         "message": {"role": "assistant", "stop_reason": "end_turn",
                     "content": [{"type": "text", "text": "f returns 1"}]}},
        {"type": "user", "uuid": "u2", "timestamp": "2026-10-14T09:02:00.000Z",
         "message": {"role": "user", "content": [{"type": "text", "text": "fix the flaky test"}]}},
    ]
    path.write_text("\n".join(json.dumps(x) for x in lines) + "\n")
    os.utime(path, (OLD, OLD))
    return state


async def test_status_says_what_the_agent_is_doing(facts):
    tools._session_watchers["proj"] = _StubTask()
    ts.save_watch(tools._WATCHER_STATE_DIR, "proj", "c-1", "http://cb")
    res = await _tool("session_status")(name="proj")
    d = res["data"]
    assert d["working"] is True and d["turn"] == "running" and d["why"] == "log_growing"
    assert d["working_on"] == "fix the flaky test"
    assert d["started_by"] == "prompt" and d["turn_started_at"] == "2026-10-14T09:02:00Z"
    assert d["last_activity"] is None   # Claude has not written anything on it yet
    assert d["claude_running"] is True
    assert d["repo"] == "/home/u/code/proj" and d["branch"] == "project/fix-1234abcd"
    assert d["head"] == "0123456789ab"
    assert d["tainted"] is None and d["audit_dir"] == "/home/u/audit/proj"
    assert d["last_reply_at"] == "2026-10-14T09:01:30Z"
    assert d["watched_conversation_id"] == "c-1"
    assert d["send_queue"] == [] and "raw" in d


async def test_status_of_an_idle_session_names_no_work(facts):
    facts["working"] = False
    d = (await _tool("session_status")(name="proj"))["data"]
    assert d["working"] is False and d["working_on"] == ""
    assert d["started_by"] is None and d["turn_started_at"] is None
    assert d["last_activity"] is None
    assert d["watched_conversation_id"] is None


async def test_status_of_a_turn_a_background_task_opened_names_the_task(facts, tmp_path):
    """metallm, 2026-10-22: for 47 minutes working_on named the person's prompt the
    agent had answered before a task notification opened a new turn."""
    path = tmp_path / "transcripts" / "proj" / "s1.jsonl"
    lines = path.read_text().splitlines()
    lines[-1:] = [json.dumps(x) for x in [
        {"type": "user", "uuid": "n1", "timestamp": "2026-10-14T09:05:00.000Z",
         "promptSource": "system", "origin": {"kind": "task-notification"},
         "message": {"role": "user", "content": "<task-notification>\n<task-id>b1</task-id>\n"
                     "<status>completed</status>\n<summary>Background command \"Run the "
                     "suite\" completed (exit code 0)</summary>\n</task-notification>"}},
        {"type": "assistant", "uuid": "a2", "timestamp": "2026-10-14T09:06:00.000Z",
         "message": {"role": "assistant", "stop_reason": "tool_use",
                     "content": [{"type": "tool_use", "id": "t", "name": "Bash", "input": {}}]}},
    ]]
    path.write_text("\n".join(lines) + "\n")
    os.utime(path, (OLD, OLD))
    d = (await _tool("session_status")(name="proj"))["data"]
    assert d["started_by"] == "background_task"
    assert d["working_on"] == ('background task completed: Background command "Run the suite" '
                               "completed (exit code 0) (task b1)")
    assert d["turn_started_at"] == "2026-10-14T09:05:00Z"
    assert d["last_activity"] == {"kind": "tool_use", "name": "Bash", "at": "2026-10-14T09:06:00Z"}


async def test_status_carries_the_taint_as_a_typed_field(facts):
    facts["tainted"] = True
    d = (await _tool("session_status")(name="proj"))["data"]
    assert d["tainted"] == {"at": "2026-10-14T09:00:00Z", "trigger": "blocklist",
                            "domain": "evil.example"}


async def test_list_returns_a_record_per_session(facts):
    facts["tainted"] = True
    tools._pending_sends["proj"] = [ts.QueuedPrompt("x", "t"), ts.QueuedPrompt("y", "t")]
    d = (await _tool("session_list")())["data"]
    by = {s["name"]: s for s in d["sessions"]}
    assert set(by) == {"proj", "other"}
    assert by["proj"]["working"] is True and by["proj"]["queue_depth"] == 2
    assert by["proj"]["tainted"]["trigger"] == "blocklist"
    assert by["proj"]["branch"] == "project/fix-1234abcd" and by["proj"]["profile"] == "multi"
    assert by["other"]["status"] == "Exited (0)" and by["other"]["claude_running"] is False
    assert "raw" in d


async def test_list_keeps_to_the_servers_scope(facts, monkeypatch):
    monkeypatch.setenv(scope.ENV, "proj")
    d = (await _tool("session_list")())["data"]
    assert [s["name"] for s in d["sessions"]] == ["proj"]


async def test_interrupt_says_what_was_running_and_the_state_of_the_tree(facts, monkeypatch):
    sent = []

    async def tmux(container, args):
        sent.append((container, args))
        return 0
    monkeypatch.setattr(tools, "_tmux_exec", tmux)
    d = (await _tool("session_interrupt")(name="proj"))["data"]
    assert d["interrupted"] is True
    assert d["was_running"] == {"why": "log_growing", "working_on": "fix the flaky test",
                                "started_by": "prompt",
                                "turn_started_at": "2026-10-14T09:02:00Z",
                                "last_activity": None}
    assert d["tree"] == {"branch": "project/fix-1234abcd", "head": "0123456789ab",
                         "changes": 1, "dirty": ["a.py"]}
    assert sent == [("aidc-proj-dev", ["send-keys", "-t", "main:claude", "Escape"])]


async def test_interrupt_with_nothing_running_does_nothing(facts, monkeypatch):
    facts["working"] = False

    async def tmux(container, args):
        raise AssertionError("an idle session was sent Esc")
    monkeypatch.setattr(tools, "_tmux_exec", tmux)
    d = (await _tool("session_interrupt")(name="proj"))["data"]
    assert d["interrupted"] is False and d["was_running"] is None
    assert d["note"] == "nothing was running"


@pytest.fixture
def queued(facts, monkeypatch):
    async def instance(name):
        return tools.SESSION_EXISTS, "id-1"
    monkeypatch.setattr(tools, "_session_instance", instance)
    tools._queue_loaded.add("proj")
    tools._pending_sends["proj"] = [
        ts.QueuedPrompt("first prompt", "2026-10-14T09:00:00Z", conversation_id="c-1",
                        prompt_id="p-1"),
        ts.QueuedPrompt("second prompt", "2026-10-14T09:01:00Z", conversation_id="c-2",
                        prompt_id="p-2"),
    ]
    tools._persist_queue("proj")


async def test_queue_cancel_takes_back_one_waiting_prompt(queued):
    d = (await _tool("session_queue_cancel")(name="proj", position=2))["data"]
    assert d["outcome"] == "cancelled"
    assert d["cancelled"] == [{"prompt_id": "p-2", "position": 2, "prompt_preview": "second prompt",
                               "enqueued_at": "2026-10-14T09:01:00Z", "conversation_id": "c-2"}]
    assert d["left"] == 1 and [q.text for q in tools._pending_sends["proj"]] == ["first prompt"]
    assert d["running"] == {"working": True, "working_on": "fix the flaky test",
                            "started_by": "prompt", "turn_started_at": "2026-10-14T09:02:00Z",
                            "last_activity": None}
    saved, _ = ts.load_send_queues(tools._WATCHER_STATE_DIR)
    assert [q.text for q in saved["proj"]] == ["first prompt"]


async def test_queue_cancel_takes_back_every_waiting_prompt(queued):
    d = (await _tool("session_queue_cancel")(name="proj"))["data"]
    assert [c["position"] for c in d["cancelled"]] == [1, 2] and d["left"] == 0
    assert "proj" not in tools._pending_sends


async def test_queue_cancel_of_an_unknown_position_lists_what_waits(queued):
    res = await _tool("session_queue_cancel")(name="proj", position=5)
    assert res["ok"] is False and res["error_code"] == "not_found"
    assert "1: first prompt" in res["error"] and len(tools._pending_sends["proj"]) == 2


async def test_queue_cancel_with_nothing_waiting(facts, monkeypatch):
    tools._queue_loaded.add("proj")
    d = (await _tool("session_queue_cancel")(name="proj"))["data"]
    assert d["cancelled"] == [] and d["note"] == "no prompt was waiting"
