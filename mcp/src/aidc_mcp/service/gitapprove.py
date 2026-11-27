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

- The id comes from the question the agent asked (its open AskUserQuestion in the session's
  transcript), never from the orchestrator's text, and must be among the waiting requests.
- The question must name one request id; naming several is `git_request_ambiguous`.
- The answer must start with Approve or Deny, and say nothing else for Approve (Deny may give
  its reason after it): anything else is `git_answer_unclear`, and nothing is sent.
- A request no longer waiting (decided, or gone) is approved or denied by nothing; the option
  is still chosen in the question, and the result says so.

The holder's own checks stand behind all of this: it refuses a request that is not waiting,
one being run, or one whose working copy moved (git-requests.sh).
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from typing import Any

from aidc_mcp import audit, backend
from aidc_mcp import transcript as ts
from aidc_mcp.service import common as com
from aidc_mcp.service import turns as tn

#: the request holder, and its home, in the git container (gitctl/Dockerfile)
HOLDER_USER = backend.GIT_HOLDER_USER
HOLDER_HOME = "/var/lib/gitctl/gitreq"
#: how long a decision may take: an approval runs the push, pull request or merge
DECIDE_TIMEOUT_S = 300.0
LIST_TIMEOUT_S = 30.0

APPROVE, DENY = "approve", "deny"

_REQUEST_ID = re.compile(r"(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])")
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


def question_text(question: dict[str, Any]) -> str:
    """Everything an AskUserQuestion shows: each question, header, option and description."""
    parts: list[str] = []
    for q in question.get("questions") or []:
        if not isinstance(q, dict):
            continue
        parts += [str(q.get("question", "")), str(q.get("header", ""))]
        for opt in q.get("options") or []:
            if isinstance(opt, dict):
                parts += [str(opt.get("label", "")), str(opt.get("description", ""))]
    return "\n".join(parts)


def option_labels(question: dict[str, Any]) -> list[str]:
    return [str(opt.get("label", "")) for q in question.get("questions") or []
            if isinstance(q, dict) for opt in q.get("options") or [] if isinstance(opt, dict)]


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


async def answer_in(name: str, prompt: str) -> Answer:
    """What sending `prompt` to session `name` asks of the request holder."""
    if not backend.is_git_session(name):
        return NOTHING
    objs, _, status = tn.session_transcript(name)
    question = ts.open_question(objs) if status == "ok" else None
    if question is None:
        return NOTHING
    ids = sorted(set(_REQUEST_ID.findall(question_text(question))))
    if not ids:
        return NOTHING
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
    if not any(label.strip().lower().startswith(verb) for label in option_labels(question)):
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
            if line.split() and _REQUEST_ID.fullmatch(line.split()[0])}


async def carry_out(decision: Decision) -> dict[str, Any]:
    """Approve or deny the request as the holder; what happened, for session_send's result
    and the access log."""
    if not decision.waiting:
        outcome: dict[str, Any] = {
            "request_id": decision.request_id, "decision": decision.verb, "done": False,
            "code": "git_request_not_waiting",
            "message": f"git request {decision.request_id} is not waiting for a decision "
                       "(already decided, or gone): nothing was approved or denied"}
    else:
        argv = [decision.verb, decision.request_id]
        if decision.verb == DENY and decision.reason:
            argv.append(decision.reason)
        rc, out = await _holder(argv, DECIDE_TIMEOUT_S)
        outcome = {"request_id": decision.request_id, "decision": decision.verb,
                   "done": rc == 0, "exit": rc, "message": out[-2000:]}
        if rc != 0:
            outcome["code"] = "git_request_not_decided"
    audit.log_event("git_request_answered", session=backend.GIT_SESSION,
                    request_id=decision.request_id, decision=decision.verb,
                    done=outcome["done"], exit=outcome.get("exit"),
                    code=outcome.get("code", ""), reason=decision.reason[:300])
    return outcome
