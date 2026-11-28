"""An orchestrator's answer to the git agent's question about a git request, carried out
by the MCP server as the request holder (gitapprove.py; owner ruling 2026-11-26, "git
approvals out of the agent's reach": the orchestrator approves by answering).

The git container is not run: the holder's `git-requests` is a stand-in recording what it
was asked, with the waiting list it answers. The send path is the session_send tests' own
wiring, with the git agent's question menu drawn as Claude Code 2.1.332 draws it
(fixtures/screens/claude-2.1.332-question-menu.ansi) and moved by the keys sent to it."""
import re
from pathlib import Path

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
        self.options = ("Deny", "Approve")
        self.keys = []

    async def capture(self, container, window):
        if not self.shown or not self.open:
            return IDLE
        return _menu_screen(self.request_id, self.pointer, self.options)

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
    """The git container's request holder: what it was asked, as which user. It acts as
    gitctl/git-requests.sh does: a decision on a waiting request takes it out of the waiting
    list, whether it is done (exit 0) or ran and failed (exit 1: the result says failed, and
    why); one on a request not waiting decides nothing (exit 3, EXIT_NOT_WAITING). An exit
    of -1 is the holder not reached (the exec timed out): nothing moves. `show` prints the
    recorded state as the real one does ("request:  <id> (<state>)"); `legacy` is a git
    container from before EXIT_NOT_WAITING, which exits 1 for a request not waiting too."""

    FAILED = "the git container is not logged in to GitHub (the user runs: aidc git login)"

    def __init__(self, waiting=(A,), list_exit=0, decide_exit=0, legacy=False, show_exit=0):
        self.waiting = set(waiting)
        self.list_exit = list_exit
        self.decide_exit = decide_exit
        self.legacy = legacy
        self.show_exit = show_exit
        self.states = {i: "pending" for i in self.waiting}
        self.calls = []

    async def run(self, argv, timeout):
        self.calls.append(argv)
        if argv[0] == "list":
            rows = "\n".join(f"{i}  2026-11-26T08:00:00Z  proj  push  octocat/hello-world  feat"
                             for i in sorted(self.waiting))
            return self.list_exit, "ID  RECEIVED  SESSION  ACTION  REPO  WHAT\n" + rows
        if argv[0] == "show":
            if self.show_exit:
                return self.show_exit, "git-requests: no request " + argv[1]
            return 0, (f"request:  {argv[1]} ({self.states.get(argv[1], '')})\n"
                       "result:   x\nsession:  proj\naction:   push")
        if self.decide_exit == -1:
            return -1, f"git-requests {argv[0]} did not finish in 300 s"
        if argv[1] not in self.waiting:
            return (1 if self.legacy else ga.EXIT_NOT_WAITING), (
                f"git-requests: request {argv[1]} is not waiting for approval "
                f"({self.states.get(argv[1], '')})")
        self.waiting.discard(argv[1])
        if self.decide_exit == 1:
            self.states[argv[1]] = "failed"
            return 1, self.FAILED
        self.states[argv[1]] = "done" if argv[0] == "approve" else "denied"
        return 0, f"{argv[0]}d {argv[1]}"

    @property
    def decisions(self):
        return [c for c in self.calls if c[0] not in ("list", "show")]


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
async def test_a_question_that_cannot_be_answered_leaves_the_decision_standing(git, monkeypatch,
                                                                              setup, why):
    """The holder's decision is the one that counts; the menu only lets the agent go on.
    When the menu cannot be answered (its pointer does not move, or, by the time the holder
    has decided, it is not on screen or asks about another request), the decision is still
    reported, the result says the question is open, and no Enter is pressed on an option
    that was not read back."""
    real = git.run

    async def then_changes(argv, timeout):
        out = await real(argv, timeout)
        if argv[0] != "list":
            setup(git.menu)
        return out
    monkeypatch.setattr(ga, "_holder", then_changes)
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
])
async def test_a_menu_that_cannot_be_read_right_gets_no_keys(git, monkeypatch, screen, why):
    """No pointer read, several questions, or no option for the answer: nothing is pressed."""
    async def capture(container, window):
        return screen(A)
    monkeypatch.setattr(tmx, "capture_screen", capture)
    res = await _send("Deny")
    assert git.decisions == [["deny", A]]
    assert res["data"]["question_not_answered"] == why and git.menu.keys == []


async def test_a_menu_offering_no_such_option_is_refused_before_anything_runs(git, monkeypatch):
    """The screen is the question that is open: one offering no Deny refuses a Deny before
    the holder is asked, and no key is pressed."""
    async def capture(container, window):
        return _menu_screen(A, options=("Refuse", "Approve"))
    monkeypatch.setattr(tmx, "capture_screen", capture)
    res = await _send("Deny")
    assert res["ok"] is False and res["error_code"] == "git_answer_unclear"
    assert git.decisions == [] and git.menu.keys == []


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
    # A result field, not an error code (one code, one meaning: Critic 2026-11-28 R-5).
    assert res["data"]["git_request"]["already_decided"] is True
    assert "code" not in res["data"]["git_request"]
    assert res["data"]["question_answered"] is True and git.menu.open is False
    assert "already decided" in res["data"]["delivery"]


async def test_a_request_already_decided_is_not_decided_again(git):
    git.waiting.clear()
    res = await _send("Deny: too late")
    assert git.decisions == []
    assert res["data"]["git_request"]["already_decided"] is True


async def test_the_holder_refusing_is_reported_not_hidden(git):
    """The holder ran the approval and it failed (here: not logged in to GitHub). The real
    holder writes `failed` before exit 1, so the request no longer waits: that is a failure
    with the holder's reason, never "already decided ... Do NOT re-send" (Critic 2026-11-28
    R-1). The option is chosen so the agent goes on and reports the failed request."""
    git.decide_exit = 1
    res = await _send("Approve")
    assert res["ok"] is True
    gr = res["data"]["git_request"]
    assert gr["done"] is False and gr["exit"] == 1
    assert gr["code"] == "git_request_not_decided" and gr["failed"] is True
    assert "already_decided" not in gr
    assert Holder.FAILED in gr["message"]
    assert "FAILED" in res["data"]["delivery"] and Holder.FAILED in res["data"]["delivery"]
    assert "already decided" not in res["data"]["delivery"]
    assert res["data"]["question_answered"] is True and git.menu.keys == ["Down", "Enter"]
    assert git.wiring.paste_calls == []


async def test_a_holder_not_reached_leaves_the_request_and_its_question_open(git):
    """The holder did not answer (the exec timed out): the request still waits, so the
    question is left open and the answer can be sent again."""
    git.decide_exit = -1
    res = await _send("Approve")
    gr = res["data"]["git_request"]
    assert gr["done"] is False and gr["code"] == "git_request_not_decided"
    assert "failed" not in gr and "already_decided" not in gr
    assert res["data"]["question_not_answered"] == "request_not_decided"
    assert "still waits" in res["data"]["delivery"] and "did not finish" in res["data"]["delivery"]
    assert git.menu.keys == [] and git.wiring.paste_calls == []
    assert git.waiting == {A}


async def test_an_answer_that_lost_the_race_at_the_holder_says_already_decided(git, monkeypatch):
    """The request waited when the answer was read, and another answer decided it before
    this one reached the holder: the holder exits EXIT_NOT_WAITING, which alone is
    already_decided, and the option is still chosen in the menu that is still open."""
    real = git.run

    async def decided_meanwhile(argv, timeout):
        if argv[0] != "list":
            git.waiting.discard(argv[1])
        return await real(argv, timeout)
    monkeypatch.setattr(ga, "_holder", decided_meanwhile)
    res = await _send("Deny")
    gr = res["data"]["git_request"]
    assert gr["exit"] == ga.EXIT_NOT_WAITING and gr["already_decided"] is True
    assert "code" not in gr and "failed" not in gr
    assert res["data"]["question_answered"] is True
    assert "already decided" in res["data"]["delivery"]


@pytest.mark.parametrize("other", ["approve", "deny"])
async def test_an_older_git_container_losing_the_race_with_exit_1_says_already_decided(
        git, monkeypatch, other):
    """A git container from before EXIT_NOT_WAITING exits 1 when another answer decided the
    request first. Its recorded result (show) says done or denied by that answer, so this is
    already_decided, never "carried out and FAILED"."""
    git.legacy = True
    real = git.run

    async def decided_meanwhile(argv, timeout):
        if argv[0] in ("approve", "deny"):
            git.waiting.discard(argv[1])
            git.states[argv[1]] = "done" if other == "approve" else "denied"
        return await real(argv, timeout)
    monkeypatch.setattr(ga, "_holder", decided_meanwhile)
    res = await _send("Approve")
    gr = res["data"]["git_request"]
    assert gr["exit"] == 1 and gr["already_decided"] is True
    assert "code" not in gr and "failed" not in gr
    assert ["show", A] in git.calls
    assert "FAILED" not in res["data"]["delivery"] and "already decided" in res["data"]["delivery"]


async def test_an_older_git_container_whose_run_failed_still_says_failed(git):
    """The same older container, exit 1 for a run that failed: its result says failed, so it
    is a failure, as with a current one."""
    git.legacy = True
    git.decide_exit = 1
    res = await _send("Approve")
    gr = res["data"]["git_request"]
    assert gr["exit"] == 1 and gr["code"] == "git_request_not_decided" and gr["failed"] is True
    assert "already_decided" not in gr and ["show", A] in git.calls
    assert "FAILED" in res["data"]["delivery"]


async def test_an_exit_1_with_an_unreadable_result_falls_back_to_the_waiting_list(git):
    """show cannot be read: whether it failed is told by the waiting list, as before (the
    request left it: failed)."""
    git.decide_exit = 1
    git.show_exit = 1
    res = await _send("Approve")
    gr = res["data"]["git_request"]
    assert gr["code"] == "git_request_not_decided" and gr["failed"] is True
    assert ["list"] in git.calls[1:]


async def test_an_exit_1_with_nothing_readable_after_is_not_known_never_still_waiting(
        git, monkeypatch):
    """The holder exited 1, and neither the request's result (show) nor the waiting list could
    be read after: whether it ran cannot be told. That is its own code, never "still waits,
    send the answer again" (Critic 2026-11-28 O-3); the question is left alone."""
    git.decide_exit = 1
    git.show_exit = 1
    git.list_exit = 1
    real = git.run
    listed = {"n": 0}

    async def list_fails_after(argv, timeout):
        # The first list (before the decision) answers; the one after fails.
        if argv[0] == "list":
            listed["n"] += 1
            if listed["n"] == 1:
                git.list_exit = 0
                rc_out = await real(argv, timeout)
                git.list_exit = 1
                return rc_out
        return await real(argv, timeout)
    monkeypatch.setattr(ga, "_holder", list_fails_after)
    res = await _send("Approve")
    gr = res["data"]["git_request"]
    assert gr["code"] == "git_request_outcome_unknown"
    assert "failed" not in gr and "already_decided" not in gr
    assert res["data"]["question_not_answered"] == "outcome_unknown"
    assert res["data"]["status"] == "question_open"
    d = res["data"]["delivery"]
    assert "NOT KNOWN" in d and "Do NOT re-send" in d and "Send the answer again" not in d
    assert git.menu.keys == [] and git.wiring.paste_calls == []


def test_exit_not_waiting_is_the_holders_own_value():
    """The MCP server tells a lost race from a failed run by the holder's exit status: its
    EXIT_NOT_WAITING must be the one gitctl/git-requests.sh exits with."""
    src = (Path(__file__).resolve().parents[2] / "gitctl" / "git-requests.sh").read_text()
    found = re.findall(r"^EXIT_NOT_WAITING=(\d+)$", src, re.MULTILINE)
    assert found == [str(ga.EXIT_NOT_WAITING)]
    assert 'exit "$EXIT_NOT_WAITING"' in src


async def test_a_second_answer_that_lost_the_race_says_already_decided(git, monkeypatch):
    """Two Approves race: the first decides the request and answers the menu; the holder
    refuses the second (exit 3, EXIT_NOT_WAITING: another approver moved it first). The second is told the
    request is already decided, never to send its answer again (Critic 2026-11-28 O-4)."""
    real = git.run

    async def first_wins(argv, timeout):
        if argv[0] != "list":
            git.calls.append(argv)
            git.waiting.discard(argv[1])
            git.menu.open = False
            return ga.EXIT_NOT_WAITING, (f"git-requests: request {argv[1]} was not approved: "
                                         "it is running now")
        return await real(argv, timeout)
    monkeypatch.setattr(ga, "_holder", first_wins)
    res = await _send("Approve")
    assert res["ok"] is True and res["data"]["git_request"]["already_decided"] is True
    assert "code" not in res["data"]["git_request"]
    assert "send the answer again" not in res["data"]["delivery"]
    assert "already decided" in res["data"]["delivery"] and "Do NOT re-send" in res["data"]["delivery"]
    assert "Enter" not in git.menu.keys


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
    git.menu.request_id = f"{A} and {B}"
    git.waiting.add(B)
    res = await _send("Approve")
    assert res["ok"] is False and res["error_code"] == "git_request_ambiguous"
    assert res["data"]["request_ids"] == sorted([A, B])
    assert git.decisions == [] and git.wiring.paste_calls == []


async def test_a_question_that_offers_no_such_option_is_unclear(git):
    git.state["objs"] = _asked(A, options=("Deny", "Skip"))
    git.menu.options = ("Deny", "Skip")
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
    git.menu.shown = False
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
    git.menu.shown = False
    res = await _send(prompt)
    assert res["ok"] is False and res["error_code"] == "git_request_not_waiting"
    assert "no question open" in res["error"]
    assert git.calls == [] and git.wiring.paste_calls == [] and git.menu.keys == []
    assert not ss.pending_sends.get(backend.GIT_SESSION)


async def test_a_git_answer_with_an_unreadable_transcript_says_so(git, monkeypatch):
    """Neither the transcript nor the screen can be read: whether a question is open is not
    known, so the answer is refused with its own code, retryable (a mirror rewriting the file
    passes), never as git_request_not_waiting (Critic 2026-11-28 R-2)."""
    monkeypatch.setattr(tn, "session_transcript", lambda name: ([], 0.0, "unreadable"))

    async def unread(container, window):
        return ""
    monkeypatch.setattr(tmx, "capture_screen", unread)
    res = await _send("Approve")
    assert res["error_code"] == "git_transcript_unreadable" and "could not be read" in res["error"]
    assert res["error_code"] in com.RETRYABLE_ERROR_CODES
    assert git.calls == [] and git.wiring.paste_calls == []


async def test_an_unreadable_transcript_with_the_menu_on_screen_is_answered(git, monkeypatch):
    """The screen shows the question: that is enough, whatever the transcript."""
    monkeypatch.setattr(tn, "session_transcript", lambda name: ([], 0.0, "unreadable"))
    res = await _send("Approve")
    assert git.decisions == [["approve", A]] and res["data"]["question_answered"] is True


async def test_a_transcript_lagging_the_screen_does_not_refuse_the_answer(git):
    """The menu is on screen before the transcript records the question (the copy lags):
    the screen's question for that request id wins (Critic 2026-11-28 R-4)."""
    git.state["objs"] = _asked(A)[:1]          # the prompt only, no question yet
    res = await _send("Approve")
    assert git.decisions == [["approve", A]]
    assert res["data"]["status"] == "answered_question"


def _cut_off(*ids):
    """A turn cut off while it asked about `ids`, then a new prompt: that question is stale."""
    return [*_asked(*ids),
            {"type": "user", "uuid": "i1", "message": {"role": "user", "content": [
                {"type": "text", "text": "[Request interrupted by user for tool use]"}]}},
            {"type": "user", "uuid": "u2", "message": {"role": "user", "content": "go on"}}]


async def test_a_stale_question_from_a_cut_off_turn_is_not_open(git, monkeypatch):
    """Its AskUserQuestion never answered, but a later prompt started another turn: an
    Approve then answers nothing, and the holder is never asked (Critic 2026-11-28 R-4)."""
    git.state["objs"] = _cut_off(A)

    async def unread(container, window):
        return ""
    monkeypatch.setattr(tmx, "capture_screen", unread)
    res = await _send("Approve")
    assert res["ok"] is False and res["error_code"] == "git_request_not_waiting"
    assert git.calls == []
    assert tn.open_question(_cut_off(A), None) is None
    assert tn.open_question(_asked(A), None).request_ids == (A,)


async def test_the_gate_runs_no_request_without_an_open_question(git):
    """The transcript still shows the question, but the screen shows Claude at its prompt
    (answered at the terminal, the copy behind): no question is open, nothing is run."""
    git.menu.shown = False
    res = await _send("Approve")
    assert res["ok"] is False and res["error_code"] == "git_request_not_waiting"
    assert git.calls == [] and git.menu.keys == []


async def test_an_empty_read_after_enter_is_not_taken_for_answered(git, monkeypatch):
    """After Enter the screen cannot be read (the exec fails, the capture is empty): the
    question is not reported answered (Critic 2026-11-28 R-7)."""
    async def capture(container, window):
        return "" if not git.menu.open else _menu_screen(A, git.menu.pointer)
    monkeypatch.setattr(tmx, "capture_screen", capture)
    res = await _send("Approve")
    assert git.decisions == [["approve", A]]
    assert res["data"]["question_answered"] is False
    assert res["data"]["question_not_answered"] == "screen_unread"
    assert res["data"]["status"] == "question_open"


async def test_another_dialog_after_enter_is_named_not_called_unreadable(git, monkeypatch):
    """After Enter the question is gone and a permission prompt asks about the agent's next
    command: the screen was read, so the result names that dialog, not screen_unread. The
    question is no longer open: status dialog_open, question_answered true (the option was
    chosen), never question_open (Critic 2026-11-28 O-4)."""
    perm = "\n".join(["● older output", RULE, " Bash command", "",
                      "   git-requests show " + A, "", " Do you want to proceed?",
                      " ❯ 1. Yes", "   2. No", "", " Esc to cancel", ""])

    async def capture(container, window):
        return perm if not git.menu.open else _menu_screen(A, git.menu.pointer)
    monkeypatch.setattr(tmx, "capture_screen", capture)
    res = await _send("Approve")
    assert git.decisions == [["approve", A]]
    assert res["data"]["status"] == "dialog_open"
    assert res["data"]["question_answered"] is True
    assert "question_not_answered" not in res["data"]
    assert "permission prompt" in res["data"]["dialog"]
    assert "no longer open" in res["data"]["delivery"]
    assert "could not be read" not in res["data"]["delivery"]
    assert "permission prompt" in res["data"]["delivery"]


async def test_keys_that_cannot_be_sent_are_reported(git, monkeypatch):
    async def fails(container, args):
        git.menu.keys.extend(args[3:])
        return 1
    monkeypatch.setattr(tmx, "tmux_exec", fails)
    res = await _send("Approve")
    assert res["data"]["question_not_answered"] == "keys_not_sent"
    assert git.menu.keys == ["Down"]


@pytest.mark.parametrize("prompt", [
    "Approve if the tests pass", "list the waiting requests", "What is waiting?",
])
async def test_an_ordinary_prompt_with_no_question_open_goes_in(git, prompt):
    git.state["objs"] = _asked(A, answered=True)
    git.menu.shown = False
    res = await _send(prompt)
    assert res["ok"] is True and "git_request" not in res["data"] and git.calls == []


async def test_a_bare_answer_to_a_question_naming_no_request_is_refused(git):
    """The menu is on screen, but no request id can be read from it (cut short, or a
    question about something else): a plain Approve is refused, never queued as a prompt
    behind the menu (bare answers are never pasted)."""
    git.state["objs"] = _asked()
    git.menu.request_id = "for a session"
    res = await _send("Approve")
    assert res["ok"] is False and res["error_code"] == "git_request_not_named"
    assert git.calls == [] and git.wiring.paste_calls == [] and git.menu.keys == []
    assert not ss.pending_sends.get(backend.GIT_SESSION)


async def test_a_bare_answer_is_refused_when_the_screen_cuts_the_id_short(git):
    git.menu.request_id = A[:20]           # the menu shows part of the id
    res = await _send("Deny")
    assert res["ok"] is False and res["error_code"] == "git_request_not_named"
    assert git.calls == [] and git.wiring.paste_calls == []


async def test_other_text_to_a_question_naming_no_request_is_an_ordinary_send(git):
    git.state["objs"] = _asked()
    git.menu.request_id = "for a session"
    res = await _send("Use the second one")
    assert res["ok"] is True and git.calls == [] and "git_request" not in res["data"]


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
