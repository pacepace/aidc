"""An orchestrator's answer to the git agent's question about a git request, carried out
by the MCP server as the request holder (gitapprove.py; owner ruling 2026-11-26, "git
approvals out of the agent's reach": the orchestrator approves by answering).

The git container is not run: the holder's `git-requests` is a stand-in recording what it
was asked, with the waiting list it answers. The send path is the session_send tests' own
wiring."""
import pytest

from aidc_mcp import backend
from aidc_mcp.service import common as com
from aidc_mcp.service import gitapprove as ga
from aidc_mcp.service import sending as snd
from aidc_mcp.service import state as ss
from aidc_mcp.service import turns as tn
from tests import toolcall
from tests.logs import patch_log_event
from tests.test_session_send import _StubTask, wiring  # noqa: F401 - the fixture

A = "a" * 31 + "1"
B = "b" * 31 + "2"


def _asked(*ids, options=("Deny", "Approve"), answered=False):
    """The git agent's transcript, its last line a question naming `ids`."""
    q = {"type": "assistant", "uuid": "q1", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "tu1", "name": "AskUserQuestion", "input": {"questions": [{
            "question": "Session proj asks to push feat to octocat/hello-world "
                        + " ".join(f"(git request {i})" for i in ids) + ". Approve?",
            "header": "git request",
            "options": [{"label": o, "description": ""} for o in options]}]}}]}}
    lines = [{"type": "user", "uuid": "u1", "message": {"role": "user", "content": "go"}}, q]
    if answered:
        lines.append({"type": "user", "uuid": "r1", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "tu1", "content": "Deny"}]}})
    return lines


class Holder:
    """The git container's request holder: what it was asked, as which user."""

    def __init__(self, waiting=(A,), list_exit=0, decide_exit=0):
        self.waiting = set(waiting)
        self.list_exit = list_exit
        self.decide_exit = decide_exit
        self.calls = []

    async def run(self, argv, timeout):
        self.calls.append(argv)
        if argv[0] == "list":
            rows = "\n".join(f"{i}  2026-11-26T08:00:00Z  proj  push  octocat/hello-world  feat"
                             for i in sorted(self.waiting))
            return self.list_exit, "ID  RECEIVED  SESSION  ACTION  REPO  WHAT\n" + rows
        return self.decide_exit, f"{argv[0]}d {argv[1]}"

    @property
    def decisions(self):
        return [c for c in self.calls if c[0] != "list"]


@pytest.fixture
def git(wiring, monkeypatch):  # noqa: F811 - pytest's fixture injection
    holder = Holder()
    monkeypatch.setattr(ga, "_holder", holder.run)
    state = {"objs": _asked(A)}
    monkeypatch.setattr(tn, "session_transcript", lambda name: (
        (state["objs"], 1.0, "ok") if name == backend.GIT_SESSION else ([], 0.0, "none")))
    ss.session_watchers[backend.GIT_SESSION] = _StubTask()
    ss.session_watchers["proj"] = _StubTask()
    holder.state = state
    holder.wiring = wiring
    return holder


async def _send(prompt, name=backend.GIT_SESSION):
    return await toolcall.call("session_send", name=name, prompt=prompt, conversation_id="c1")


async def test_an_approve_runs_as_the_holder_and_the_answer_still_goes_in(git, monkeypatch):
    logged = []
    patch_log_event(monkeypatch, lambda kind, **f: logged.append((kind, f)))
    res = await _send("Approve")
    assert git.decisions == [["approve", A]]
    assert res["ok"] is True and res["data"]["git_request"]["done"] is True
    assert res["data"]["git_request"]["request_id"] == A
    assert len(git.wiring.paste_calls) == 1          # the agent's question is answered too
    answered = [f for k, f in logged if k == "git_request_answered"]
    assert answered and answered[0]["request_id"] == A and answered[0]["decision"] == "approve"


async def test_an_answer_that_cannot_be_queued_decides_nothing(git):
    """session_send never succeeds in part (design-10 D6): with the git agent's queue full,
    the answer is refused before its request is approved, not after."""
    ss.pending_sends[backend.GIT_SESSION] = [object()] * snd.PENDING_MAX_DEPTH
    try:
        res = await _send("Approve")
    finally:
        ss.pending_sends.pop(backend.GIT_SESSION, None)
    assert res["ok"] is False and res["error_code"] == "queue_full"
    assert git.decisions == []
    assert "was not decided" in res["error"]


async def test_a_deny_carries_its_reason(git):
    res = await _send("Deny: the branch has a debug print")
    assert git.decisions == [["deny", A, "the branch has a debug print"]]
    assert res["data"]["git_request"]["decision"] == "deny"


async def test_an_answer_to_a_question_naming_no_waiting_request_approves_nothing(git):
    """The question names B, which is not waiting (decided, or never there): nothing is
    approved, whatever the answer says, and the answer still reaches the question."""
    git.state["objs"] = _asked(B)
    res = await _send("Approve")
    assert git.decisions == []
    assert res["ok"] is True
    assert res["data"]["git_request"]["done"] is False
    assert res["data"]["git_request"]["code"] == "git_request_not_waiting"
    assert len(git.wiring.paste_calls) == 1


async def test_a_request_already_decided_is_not_decided_again(git):
    git.waiting.clear()
    res = await _send("Deny: too late")
    assert git.decisions == []
    assert res["data"]["git_request"]["code"] == "git_request_not_waiting"


async def test_the_holder_refusing_is_reported_not_hidden(git):
    git.decide_exit = 2       # another approver moved it first
    res = await _send("Approve")
    assert res["ok"] is True
    assert res["data"]["git_request"]["done"] is False
    assert res["data"]["git_request"]["code"] == "git_request_not_decided"


@pytest.mark.parametrize("prompt", [
    "Approve if the tests pass", "approve, then deny the next one", "Maybe", "Yes",
    "I approve", "Deny approve",
])
async def test_an_answer_that_is_not_plainly_approve_or_deny_is_refused_and_not_sent(git,
                                                                                     prompt):
    res = await _send(prompt)
    assert res["ok"] is False and res["error_code"] == "git_answer_unclear"
    assert git.decisions == [] and git.wiring.paste_calls == []


async def test_a_question_naming_two_requests_is_ambiguous(git):
    git.state["objs"] = _asked(A, B)
    git.waiting.add(B)
    res = await _send("Approve")
    assert res["ok"] is False and res["error_code"] == "git_request_ambiguous"
    assert res["data"]["request_ids"] == sorted([A, B])
    assert git.decisions == [] and git.wiring.paste_calls == []


async def test_a_question_that_offers_no_such_option_is_unclear(git):
    git.state["objs"] = _asked(A, options=("Deny", "Skip"))
    res = await _send("Approve")
    assert res["error_code"] == "git_answer_unclear" and git.decisions == []


async def test_an_unreadable_waiting_list_approves_nothing_and_says_retry(git):
    git.list_exit = 1
    res = await _send("Approve")
    assert res["ok"] is False and res["error_code"] == "git_requests_unreadable"
    assert res["error_code"] in com.RETRYABLE_ERROR_CODES     # rides the result as retryable
    assert git.decisions == [] and git.wiring.paste_calls == []


async def test_an_answered_question_is_not_open(git):
    git.state["objs"] = _asked(A, answered=True)
    res = await _send("Approve")
    assert git.calls == [] and res["ok"] is True and "git_request" not in res["data"]


async def test_a_question_naming_no_request_is_an_ordinary_send(git):
    git.state["objs"] = _asked()
    res = await _send("Approve")
    assert git.calls == [] and "git_request" not in res["data"]


async def test_another_sessions_answer_never_reaches_the_holder(git):
    res = await _send("Approve", name="proj")
    assert git.calls == [] and res["ok"] is True


def test_the_holder_runs_as_gitreq_in_the_git_container(monkeypatch):
    """The command the decision runs: the holder's own user and home, in the git container,
    as `aidc git approve` runs it (scripts/docker/lib.sh dk_git_exec_req)."""
    seen = {}

    async def fake_exec(*argv, **kw):
        seen["argv"] = list(argv)
        raise RuntimeError("stop here")
    import asyncio
    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    with pytest.raises(RuntimeError):
        asyncio.run(ga._holder(["approve", A], 1.0))
    assert seen["argv"] == ["docker", "exec", "-u", "gitreq", "-e",
                            "HOME=/var/lib/gitctl/gitreq", "aidc-git-dev",
                            "git-requests", "approve", A]


def test_parse_answer():
    assert ga.parse_answer("Approve") == ("approve", "")
    assert ga.parse_answer("  approve. ") == ("approve", "")
    assert ga.parse_answer("Deny") == ("deny", "")
    assert ga.parse_answer("deny — not ours") == ("deny", "not ours")
    assert ga.parse_answer("Approved") is None
    assert ga.parse_answer("Denying it") is None
