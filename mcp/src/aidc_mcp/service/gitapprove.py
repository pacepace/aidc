"""An orchestrator's answer to the git agent's question about a git request, carried out.

In ask mode the git agent asks about each waiting push, pull request or merge with its
question tool, naming the request's id, and decides nothing itself (owner ruling 2026-11-26,
"git approvals out of the agent's reach"). An orchestrator answers that question with
session_send to the session `git`. When the agent's open question names exactly one git
request that is still waiting, and the answer is plainly Approve or Deny, this module runs
`git-requests approve|deny <id> [why]` in the git container as the request holder (gitreq),
which acts only on a request still waiting. The same option is then chosen in the agent's
question menu (sending.answer_question_menu), so its turn goes on.

Strict, because an approval pushes to GitHub:

- The id comes from the question the agent asked, never from the orchestrator's text, and
  must be among the waiting requests. Which question is open, if any, is decided once for
  everything that asks (turns.open_question): the question menu on the agent's screen, or,
  when the screen cannot be read, the question its current turn waits on in its transcript.
  A question a cut-off turn left unanswered is not open.
- The question must name one request id; naming several is `git_request_ambiguous`. A plain
  Approve or Deny sent while a question is open that names no request id aidc can read (the
  menu cut the id short, or the question is about something else) answers nothing it can
  tell: `git_request_not_named`, and nothing is sent (a bare answer is never pasted).
- The answer must start with Approve or Deny, and say nothing else for Approve (Deny may give
  its reason after it): anything else is `git_answer_unclear`, and nothing is sent.
- A request no longer waiting (decided, or gone) is approved or denied by nothing; the option
  is still chosen in the question, and the result says so (`already_decided`, a field of the
  successful result, not an error code). So does a second answer that lost a race to the
  first: the holder says so by its own exit status (EXIT_NOT_WAITING), never by exit 1.
  A git container older than that status exits 1 for a lost race too, so an exit 1 is read
  again from the request's recorded result (request_state): done or denied by another answer
  (or being run by it) is already_decided, not a failure.
- An approval the holder ran that failed (the push refused, no GitHub login, the working copy
  moved: exit 1, the request now failed) is a failure, `git_request_not_decided` with the
  holder's reason and `failed: true`; the option is still chosen, so the agent goes on and
  reports the failed request. Sending the answer again decides nothing.
- An answer sent while the agent has no question open answers nothing: no request waits for
  it, so it is refused, `git_request_not_waiting`, and nothing is sent (live 2026-11-27: pasted
  as a prompt, "Approve" left the agent with nothing to act on). When neither its screen nor
  its transcript can be read, whether a question is open cannot be told: that is
  `git_transcript_unreadable`, retryable, and nothing is sent. Any other text goes in as an
  ordinary prompt.

The holder's own checks stand behind all of this: it refuses a request that is not waiting,
one being run, or one whose working copy moved (git-requests.sh).
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from typing import Any

from aidc_mcp import audit, backend
from aidc_mcp.service import common as com
from aidc_mcp.service import turns as tn

#: the request holder, and its home, in the git container (gitctl/Dockerfile)
HOLDER_USER = backend.GIT_HOLDER_USER
HOLDER_HOME = "/var/lib/gitctl/gitreq"
#: how long a decision may take: an approval runs the push, pull request or merge
DECIDE_TIMEOUT_S = 300.0
LIST_TIMEOUT_S = 30.0

APPROVE, DENY = "approve", "deny"
#: git-requests approve|deny's exit status when it decided nothing because the request was
#: not waiting: decided or gone already, or another answer holds it or got there first
#: (gitctl/git-requests.sh EXIT_NOT_WAITING). Exit 1 is a run that failed.
EXIT_NOT_WAITING = 3

_ANSWER = re.compile(r"\s*(approve|deny)\b(.*)\Z", re.IGNORECASE | re.DOTALL)
#: what may follow Approve: punctuation only (no condition, no second thought)
_APPROVE_TAIL = re.compile(r"[\s.!]*\Z")


@dataclass(frozen=True)
class Decision:
    """A decision to carry out: the request, approve or deny, and a denial's reason."""

    request_id: str
    verb: str
    reason: str = ""
    waiting: bool = True


@dataclass(frozen=True)
class Answer:
    """What a send to the git agent asks of the holder: nothing (None, None), a decision,
    or a refusal envelope (nothing is sent)."""

    decision: Decision | None = None
    refusal: dict[str, Any] | None = None


NOTHING = Answer()


def parse_answer(prompt: str) -> tuple[str, str] | None:
    """(verb, reason) when the text is plainly Approve or Deny [reason]; None otherwise."""
    m = _ANSWER.match(prompt)
    if m is None:
        return None
    verb, rest = m.group(1).lower(), m.group(2)
    other = DENY if verb == APPROVE else APPROVE
    if re.search(rf"\b{other}", rest, re.IGNORECASE):
        return None
    if verb == APPROVE:
        return (APPROVE, "") if _APPROVE_TAIL.match(rest) else None
    return DENY, rest.lstrip(" \t:,.-—").strip()


def _unclear(why: str) -> Answer:
    return Answer(refusal=com.envelope_err(
        f"The git agent is asking about a git request, and this answer is not plainly "
        f"Approve or Deny ({why}). Nothing was approved and nothing was sent. Answer "
        "\"Approve\", or \"Deny: <why>\".", code="git_answer_unclear"))


async def answer_in(name: str, prompt: str, container: str) -> Answer:
    """What sending `prompt` to session `name` asks of the request holder."""
    if not backend.is_git_session(name):
        return NOTHING
    objs, _, status = tn.session_transcript(name)
    screen = await tn.read_screen(container, name)
    # An unreadable transcript is no transcript to go by: with no screen either, whether a
    # question is open cannot be told (UNKNOWN), never taken for none open.
    question = tn.open_question(objs if status == "ok" else None if status == "unreadable"
                                else [], screen)
    if question is None or question is tn.UNKNOWN:
        parsed = parse_answer(prompt)
        if parsed is None:
            return NOTHING
        unread = question is tn.UNKNOWN
        audit.log_event("git_request_answer_refused", session=name,
                        reason="transcript_unreadable" if unread else "no_question",
                        decision=parsed[0])
        if unread:
            return Answer(refusal=com.envelope_err(
                f"This {parsed[0].capitalize()} was not carried out: the git agent's "
                "transcript could not be read and its screen did not show, so whether it has "
                "a question open cannot be told. Nothing was approved or denied, and nothing "
                "was sent. Try again.", code="git_transcript_unreadable"))
        return Answer(refusal=com.envelope_err(
            f"This {parsed[0].capitalize()} answers no question of the git agent's: it has no "
            "question open, so no git request is waiting for it. Nothing was approved or "
            "denied, and nothing was sent. "
            "Answer once the agent asks about a request (its question names the request's "
            "id), or decide a waiting one with aidc git approve|deny <id>.",
            code="git_request_not_waiting"))
    ids = list(question.request_ids)
    if not ids:
        parsed = parse_answer(prompt)
        if parsed is None:
            return NOTHING
        # A bare Approve or Deny is never pasted (it would wait behind the menu, then reach
        # the agent as a stray prompt): with no request id to match it to, it is refused.
        audit.log_event("git_request_answer_refused", session=name, reason="no_request_id",
                        decision=parsed[0])
        return Answer(refusal=com.envelope_err(
            f"This {parsed[0].capitalize()} was not carried out: the git agent has a question "
            "open, but no git request id could be read from it (cut short on its screen, or "
            "a question about something else), so which request it answers cannot be told. "
            "Nothing was approved or denied, and nothing was sent. Read the question "
            "(session_status, or attach), and decide with aidc git approve|deny <id>.",
            code="git_request_not_named"))
    if len(ids) > 1:
        audit.log_event("git_request_answer_refused", session=name, reason="ambiguous",
                        request_ids=ids)
        return Answer(refusal=com.envelope_err(
            f"The git agent's open question names {len(ids)} git requests "
            f"({', '.join(ids)}), so which one this answers cannot be told. Nothing was "
            "approved and nothing was sent; decide each with aidc git approve|deny <id>.",
            {"request_ids": ids}, code="git_request_ambiguous"))
    request_id = ids[0]
    parsed = parse_answer(prompt)
    if parsed is None:
        audit.log_event("git_request_answer_refused", session=name, reason="unclear",
                        request_id=request_id)
        return _unclear("it must start with Approve or Deny, and Approve must stand alone")
    verb, reason = parsed
    if not any(label.strip().lower().startswith(verb) for label in question.options):
        audit.log_event("git_request_answer_refused", session=name, reason="not_an_option",
                        request_id=request_id, decision=verb)
        return _unclear(f"the question offers no {verb.capitalize()} option")
    waiting = await waiting_requests()
    if waiting is None:
        audit.log_event("git_request_answer_refused", session=name, reason="list_failed",
                        request_id=request_id)
        return Answer(refusal=com.envelope_err(
            "The git container's waiting requests could not be read, so this answer was not "
            "carried out and nothing was sent. Try again, or decide with "
            f"aidc git {verb} {request_id}.", code="git_requests_unreadable"))
    return Answer(decision=Decision(request_id, verb, reason, waiting=request_id in waiting))


async def _holder(argv: list[str], timeout: float) -> tuple[int, str]:
    """Run git-requests as the request holder in the git container: (exit, output)."""
    cmd = backend.exec_argv(backend.target(backend.GIT_SESSION), ["git-requests", *argv],
                            user=HOLDER_USER, env={"HOME": HOLDER_HOME})
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT)
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        return -1, f"git-requests {argv[0]} did not finish in {int(timeout)} s"
    return proc.returncode or 0, out.decode("utf-8", "replace").strip()


async def waiting_requests() -> set[str] | None:
    """The ids of the requests waiting for a decision, or None when they cannot be read."""
    rc, out = await _holder(["list"], LIST_TIMEOUT_S)
    if rc != 0:
        audit.log_event("git_requests_list_failed", exit=rc, output=out[-300:])
        return None
    return {line.split()[0] for line in out.splitlines()[1:]
            if line.split() and tn.REQUEST_ID.fullmatch(line.split()[0])}


#: the request's state on the first line of `git-requests show <id>`: "request:  <id> (<state>)"
_SHOW_STATE = re.compile(r"request:\s+(\S+)\s+\(([a-z]*)\)")
#: recorded results that another answer made (or is making): a lost race, never this run's failure
DECIDED_ELSEWHERE = frozenset({"done", "denied", "running"})


async def request_state(request_id: str) -> str | None:
    """The request's recorded state (pending, running, done, denied, failed; "" when it has
    no result), as the holder's `show` prints it; None when it cannot be read."""
    rc, out = await _holder(["show", request_id], LIST_TIMEOUT_S)
    for line in out.splitlines()[:1]:
        m = _SHOW_STATE.match(line.strip())
        if rc == 0 and m and m.group(1) == request_id:
            return m.group(2)
    audit.log_event("git_request_show_failed", request_id=request_id, exit=rc,
                    output=out[-300:])
    return None


async def carry_out(decision: Decision) -> dict[str, Any]:
    """Approve or deny the request as the holder; what happened, for session_send's result
    and the access log. `already_decided` (a result field, never an error code) says the
    request was not waiting: decided before this answer, gone, or decided by another answer
    that reached the holder first (a race the holder lets only one side win, and reports by
    its exit status EXIT_NOT_WAITING). Any other refusal is `code` git_request_not_decided
    with the holder's message; `failed` adds that the holder ran it and it failed (it is no
    longer waiting), rather than not reaching it (still waiting, so it can be sent again).
    `code` git_request_outcome_unknown: the holder did not say it was done, and neither the
    request's result nor the waiting list could be read after, so whether it ran is not
    known (never reported as still waiting)."""
    outcome: dict[str, Any] = {"request_id": decision.request_id, "decision": decision.verb}
    if not decision.waiting:
        outcome.update(done=False, already_decided=True,
                       message=f"git request {decision.request_id} is not waiting for a "
                               "decision (already decided, or gone): nothing was approved or "
                               "denied")
    else:
        argv = [decision.verb, decision.request_id]
        if decision.verb == DENY and decision.reason:
            argv.append(decision.reason)
        rc, out = await _holder(argv, DECIDE_TIMEOUT_S)
        outcome.update(done=rc == 0, exit=rc, message=out[-2000:])
        if rc == EXIT_NOT_WAITING:
            # Another answer moved it first, or it was decided meanwhile: nothing done here.
            outcome["already_decided"] = True
        elif rc != 0:
            # The holder ran it and it failed (it writes `failed` with the reason before exit
            # 1, so it no longer waits), or the holder could not be reached (still waiting).
            # A git container from before EXIT_NOT_WAITING also exits 1 for a lost race: its
            # recorded result then says done or denied (or running) by the other answer.
            state = await request_state(decision.request_id) if rc == 1 else None
            if state in DECIDED_ELSEWHERE:
                outcome["already_decided"] = True
            elif state == "failed":
                outcome.update(code="git_request_not_decided", failed=True)
            elif state is not None:
                outcome["code"] = "git_request_not_decided"   # pending: it still waits
            else:
                outcome["code"] = "git_request_not_decided"
                waiting = await waiting_requests()
                if waiting is None:
                    # Neither its result nor the waiting list could be read: whether the
                    # holder ran it cannot be told, so it is never "still waits, send again".
                    outcome["code"] = "git_request_outcome_unknown"
                elif decision.request_id not in waiting:
                    outcome["failed"] = True
    audit.log_event("git_request_answered", session=backend.GIT_SESSION,
                    request_id=decision.request_id, decision=decision.verb,
                    done=outcome["done"], exit=outcome.get("exit"),
                    already_decided=bool(outcome.get("already_decided")),
                    failed=bool(outcome.get("failed")),
                    code=outcome.get("code", ""), reason=decision.reason[:300])
    return outcome
