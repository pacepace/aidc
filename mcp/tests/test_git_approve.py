"""An orchestrator's answer to the git agent's question about a git request, carried out
by the MCP server as the request holder (gitapprove.py; owner ruling 2026-11-26, "git
approvals out of the agent's reach": the orchestrator approves by answering).

The git container is not run: the holder's `git-requests` is a stand-in recording what it
was asked, with the waiting list it answers. The send path is the session_send tests' own
wiring, with the git agent's question menu drawn as Claude Code 2.1.332 draws it
(fixtures/screens/claude-2.1.332-question-menu.ansi) and moved by the keys sent to it."""
import pytest

from aidc_mcp import backend
from aidc_mcp.service import common as com
from aidc_mcp.service import gitapprove as ga
from aidc_mcp.service import sending as snd
from aidc_mcp.service import state as ss
from aidc_mcp.service import tmux as tmx
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


RULE = "─" * 120
IDLE = "\n".join(["", RULE, "❯\xa0", RULE, "  ? for shortcuts", ""])


def _menu_screen(request_id, pointer=1, options=("Deny", "Approve")):
    """Claude Code's question menu (AskUserQuestion), as the live capture shows it."""
    rows = ["● older output", RULE, " ☐ PR request", "",
            f"│ Git request {request_id}: session proj asks to open a pull request on",
            "│ octocat/hello-world, branch feat → main. Approve or deny?", ""]
    labels = [*options, "Type something."]
    for i, label in enumerate(labels, 1):
        rows.append(("❯ " if i == pointer else "  ") + f"{i}. {label}")
        if i <= len(options):
            rows.append("     What this option does.")
    rows += [RULE, f"  {len(labels) + 1}. Chat about this", "",
             "Enter to select · ↑/↓ to navigate · Esc to cancel", ""]
    return "\n".join(rows)


class Menu:
    """The git agent's question menu: the arrows move its pointer, Enter answers it."""

    def __init__(self, w, request_id=A):
        self.wiring = w
        self.request_id = request_id
        self.pointer = 1
        self.open = True
        self.shown = True      # False: the screen shows no menu at all
        self.stuck = False     # the pointer does not move
        self.keys = []

    async def capture(self, container, window):
        if not self.shown or not self.open:
            return IDLE
        return _menu_screen(self.request_id, self.pointer)

    async def tmux(self, container, args):
        self.wiring.tmux_calls.append((container, args))
        if args[:1] == ["send-keys"]:
            for key in args[3:]:
                self.keys.append(key)
                if key == "Enter":
                    self.open = False
                elif not self.stuck:
                    self.pointer += 1 if key == "Down" else -1 if key == "Up" else 0
        return 0


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
    holder.menu = Menu(wiring)
    monkeypatch.setattr(tmx, "capture_screen", holder.menu.capture)
    monkeypatch.setattr(tmx, "tmux_exec", holder.menu.tmux)
    holder.state = state
    holder.wiring = wiring
    return holder


async def _send(prompt, name=backend.GIT_SESSION):
    return await toolcall.call("session_send", name=name, prompt=prompt, conversation_id="c1")


async def test_an_approve_runs_as_the_holder_and_answers_the_agents_question(git, monkeypatch):
    """The decision is the holder's; then Approve is chosen in the agent's question menu
    (one arrow down from Deny, read back, Enter), so its turn goes on. Typed text never
    reaches that menu (live 2026-11-27: the answer waited, never pasted), so none is sent."""
    logged = []
    patch_log_event(monkeypatch, lambda kind, **f: logged.append((kind, f)))
    res = await _send("Approve")
    assert git.decisions == [["approve", A]]
    assert res["ok"] is True and res["data"]["git_request"]["done"] is True
    assert res["data"]["git_request"]["request_id"] == A
    assert git.menu.keys == ["Down", "Enter"] and git.menu.open is False
    assert res["data"]["status"] == "answered_question"
    assert res["data"]["question_answered"] is True and res["data"]["prompt_id"]
    assert git.wiring.paste_calls == [] and not ss.pending_sends.get(backend.GIT_SESSION)
    answered = [f for k, f in logged if k == "git_request_answered"]
    assert answered and answered[0]["request_id"] == A and answered[0]["decision"] == "approve"
    assert [f["option"] for k, f in logged if k == "git_question_answered"] == ["approve"]


async def test_a_deny_chooses_deny_where_the_pointer_already_is(git):
    res = await _send("Deny: not now")
    assert git.menu.keys == ["Enter"]
    assert res["data"]["question_answered"] is True


@pytest.mark.parametrize("setup, why", [
    (lambda m: setattr(m, "stuck", True), "pointer_not_moved"),
    (lambda m: setattr(m, "shown", False), "no_question_on_screen"),
    (lambda m: setattr(m, "request_id", B), "another_question"),
])
async def test_a_question_that_cannot_be_answered_leaves_the_decision_standing(git, setup, why):
    """The holder's decision is the one that counts; the menu only lets the agent go on.
    When the menu cannot be answered (its pointer does not move, it is not on screen, or it
    asks about another request), the decision is still reported, the result says the
    question is open, and no Enter is pressed on an option that was not read back."""
    setup(git.menu)
    res = await _send("Approve")
    assert git.decisions == [["approve", A]]
    assert res["ok"] is True and res["data"]["git_request"]["done"] is True
    assert res["data"]["question_answered"] is False
    assert res["data"]["question_not_answered"] == why
    assert res["data"]["status"] == "question_open"
    assert "Enter" not in git.menu.keys
    assert "decision stands" in res["data"]["delivery"]
    assert git.wiring.paste_calls == [] and not ss.pending_sends.get(backend.GIT_SESSION)


async def test_the_pointer_moves_up_when_it_is_below_the_option(git):
    git.menu.pointer = 3
    res = await _send("Deny")
    assert git.menu.keys == ["Up", "Up", "Enter"]
    assert res["data"]["question_answered"] is True


@pytest.mark.parametrize("screen, why", [
    (lambda rid: _menu_screen(rid).replace("❯ 1. Deny", "  1. Deny"), "pointer_not_moved"),
    (lambda rid: _menu_screen(rid).replace(" ☐ PR request", " ☐ PR request  ☐ Merge"),
     "several_questions"),
    (lambda rid: _menu_screen(rid, options=("Refuse", "Approve")), "no_such_option"),
])
async def test_a_menu_that_cannot_be_read_right_gets_no_keys(git, monkeypatch, screen, why):
    """No pointer read, several questions, or no option for the answer: nothing is pressed."""
    async def capture(container, window):
        return screen(A)
    monkeypatch.setattr(tmx, "capture_screen", capture)
    res = await _send("Deny")
    assert git.decisions == [["deny", A]]
    assert res["data"]["question_not_answered"] == why and git.menu.keys == []


async def test_a_menu_still_open_after_enter_is_reported(git, monkeypatch):
    async def ignores_enter(container, args):
        git.menu.keys.extend(args[3:])
        return 0
    monkeypatch.setattr(tmx, "tmux_exec", ignores_enter)
    res = await _send("Deny")
    assert git.decisions == [["deny", A]]
    assert res["data"]["question_not_answered"] == "menu_still_open"


async def test_a_full_queue_does_not_hold_back_the_answer(git):
    """The answer is never queued (it goes into the question menu), and the queue fills while
    that menu is open, every other prompt waiting behind it: a full queue must not refuse
    the one answer that frees it (Critic, 2026-11-27)."""
    ss.pending_sends[backend.GIT_SESSION] = [object()] * snd.PENDING_MAX_DEPTH
    try:
        res = await _send("Approve")
    finally:
        ss.pending_sends.pop(backend.GIT_SESSION, None)
    assert res["ok"] is True and git.decisions == [["approve", A]]
    assert res["data"]["question_answered"] is True


async def test_a_deny_carries_its_reason(git):
    res = await _send("Deny: the branch has a debug print")
    assert git.decisions == [["deny", A, "the branch has a debug print"]]
    assert res["data"]["git_request"]["decision"] == "deny"


async def test_an_answer_to_a_question_naming_no_waiting_request_approves_nothing(git):
    """The question names B, which is not waiting (decided, or never there): nothing is
    approved, whatever the answer says, and the answer still reaches the question."""
    git.state["objs"] = _asked(B)
    git.menu.request_id = B
    res = await _send("Approve")
    assert git.decisions == []
    assert res["ok"] is True
    assert res["data"]["git_request"]["done"] is False
    assert res["data"]["git_request"]["code"] == "git_request_not_waiting"
    assert res["data"]["question_answered"] is True and git.menu.open is False


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
    # Its question is left open, so the answer can be sent again.
    assert res["data"]["question_not_answered"] == "request_not_decided"
    assert git.menu.keys == [] and git.wiring.paste_calls == []


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
    """Its question answered, the agent has none open: an Approve then waits for nothing."""
    git.state["objs"] = _asked(A, answered=True)
    res = await _send("Approve")
    assert git.calls == [] and res["ok"] is False
    assert res["error_code"] == "git_request_not_waiting"


@pytest.mark.parametrize("objs", [_asked(A, answered=True), []], ids=["answered", "no-question"])
@pytest.mark.parametrize("prompt", ["Approve", "approve.", "Deny", "Deny: not this one"])
async def test_a_git_answer_with_no_question_open_is_refused_and_not_sent(git, objs, prompt):
    """Live 2026-11-27: an "Approve" sent while the agent asked nothing was pasted as a
    prompt, and the agent answered that it had nothing to act on. No request waits for
    such an answer, so it is refused, nothing decided, nothing pasted or queued."""
    git.state["objs"] = objs
    res = await _send(prompt)
    assert res["ok"] is False and res["error_code"] == "git_request_not_waiting"
    assert "no question open" in res["error"]
    assert git.calls == [] and git.wiring.paste_calls == [] and git.menu.keys == []
    assert not ss.pending_sends.get(backend.GIT_SESSION)


async def test_a_git_answer_with_an_unreadable_transcript_says_so(git, monkeypatch):
    """Refused as well (no question can be told), and the reason says why."""
    monkeypatch.setattr(tn, "session_transcript", lambda name: ([], 0.0, "unreadable"))
    res = await _send("Approve")
    assert res["error_code"] == "git_request_not_waiting" and "could not be read" in res["error"]
    assert git.calls == [] and git.wiring.paste_calls == []


@pytest.mark.parametrize("prompt", [
    "Approve if the tests pass", "list the waiting requests", "What is waiting?",
])
async def test_an_ordinary_prompt_with_no_question_open_goes_in(git, prompt):
    git.state["objs"] = _asked(A, answered=True)
    res = await _send(prompt)
    assert res["ok"] is True and "git_request" not in res["data"] and git.calls == []


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
