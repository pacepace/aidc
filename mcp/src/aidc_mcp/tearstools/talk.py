"""The tools that talk to a session's agents: send a prompt (queued or joined), ask a headless
Claude, watch and resend replies, take back queued prompts."""

from __future__ import annotations

from typing import TYPE_CHECKING, Annotated, Any

from pydantic import Field

from aidc_mcp.service import delivery as dlv
from aidc_mcp.service import invoke as inv
from aidc_mcp.service import sending as snd
from aidc_mcp.tearstools.base import AidcTool, SessionAwareTool, progress_of
from aidc_mcp.tearstools.descriptions import (
    CONV_ID_DESC,
    DELIVER_DESC,
    NAME_DESC,
    PROMPT_DESC,
    SENDER_LABEL_DESC,
    SENT_BY_DESC,
)

if TYPE_CHECKING:
    from threetears.mcp import CallContext


class SessionInvoke(SessionAwareTool):
    local_name = "session_invoke"

    async def call(
        self, ctx: CallContext | None,
        name: Annotated[str, Field(description=NAME_DESC)],
        prompt: Annotated[str, Field(description=PROMPT_DESC)]
    ) -> dict[str, Any]:
        """For SHORT, single-shot questions only. Anything long goes to session_send.

        Asks a FRESH headless Claude in the session one question and BLOCKS until it
        answers. It is NOT for running dev processes, builds or test suites, editing
        files, multi-step work, or anything that may take more than about a minute: hand
        those to the session's agent with session_send, which does not block and reports
        back over the webhook.

        WHEN TO USE: a quick question about the code whose answer you need inline — "what
        does function X return?", "which file defines the retry policy?", "is there a test
        for Y?".
        WHEN NOT: "run the tests", "amend the spec", "implement the endpoint", "fix the
        build" -> session_send. A question for the session's resident agent, the one that
        knows the session's work -> session_send; this Claude knows nothing of it and does
        not resume the session's conversation.

        One headless run at a time per session (this and session_invoke_async): while one
        is going, another is refused at once with error_code "invoke_busy", naming it.
        There is no time limit; if you cancel the call, the run is stopped in the
        session. The result says how long it took (elapsed_s), with a warning when
        that was over a minute. Returns the answer text; relay it verbatim, do not
        summarize.

        Args:
            name: the aidc session to run in (see session_list for running sessions).
            prompt: the single prompt to run.
        """
        return await inv.invoke(
            name=name,
            prompt=prompt,
            progress=progress_of(ctx),
        )


class SessionInvokeAsync(SessionAwareTool):
    local_name = "session_invoke_async"

    async def call(
        self, ctx: CallContext | None,
        name: Annotated[str, Field(description=NAME_DESC)],
        prompt: Annotated[str, Field(description=PROMPT_DESC)],
        conversation_id: Annotated[str, Field(description=CONV_ID_DESC)],
    ) -> dict[str, Any]:
        """For SHORT, single-shot questions only. Anything long goes to session_send.

        Fires one question at a FRESH headless Claude in the session and returns at once;
        the answer is delivered back to THIS conversation when done. Like session_invoke,
        it is NOT for running dev processes, builds or test suites, editing files,
        multi-step work, or anything long: those go to the session's agent with
        session_send.

        WHEN TO USE: a self-contained question whose answer can land here later — e.g. a
        scheduled check such as "what version does the lockfile pin for X?".
        WHEN NOT: "run the tests", "amend the spec", "implement…", or any back-and-forth
        with the session -> session_send; you need the answer inline -> session_invoke.
        Each call is a fresh Claude with no memory of the session's work. One headless
        run at a time per session (this and session_invoke): while one is going, another
        is refused at once with error_code "invoke_busy". A run still going after 30
        minutes is stopped.

        Args:
            name: the aidc session to run in.
            prompt: the prompt to run.
            conversation_id: this conversation's id (the orchestrator injects it) — where the
                result is delivered.
        """
        return await inv.invoke_async(name=name, prompt=prompt, conversation_id=conversation_id)


class SessionSend(SessionAwareTool):
    local_name = "session_send"

    async def call(
        self, ctx: CallContext | None,
        name: Annotated[str, Field(description=NAME_DESC)],
        prompt: Annotated[str, Field(description=PROMPT_DESC)],
        conversation_id: Annotated[str | None, Field(description=CONV_ID_DESC)] = None,
        sent_by: Annotated[str | None, Field(description=SENT_BY_DESC)] = None,
        sender_label: Annotated[str | None, Field(description=SENDER_LABEL_DESC)] = None,
        deliver: Annotated[str, Field(description=DELIVER_DESC, json_schema_extra={
            "enum": [snd.DELIVER_QUEUE, snd.DELIVER_JOIN]})] = snd.DELIVER_QUEUE
    ) -> dict[str, Any]:
        """The place for anything long or that does work: tasks, edits, builds, tests.

        Ask the live Claude agent running in a session a question, or hand it a task —
        and get its reply back. The agent has the project loaded in its context, so to
        learn about or change the code in a session, ASK IT here rather than inspecting
        the repo yourself with session_exec / file_get. Returns immediately; the agent's
        reply is delivered back to THIS conversation when it finishes, so you can keep
        talking to the user while it works.

        WHEN TO USE: the default way to interact with a session — any question or task for
        the agent inside it ("what does X do?", "fix the failing test", "run the tests",
        "amend the spec", "implement…", an ongoing back-and-forth), and always for
        anything long, anything that edits files or runs builds or tests: session_invoke
        is only for short, single-shot questions.
        WHEN NOT: YOU want to run a shell command or read a file directly (git/npm/build,
        raw inspection) -> use session_exec / file_get; you need a one-off answer inline
        and the session's loaded context does NOT matter -> use session_invoke (headless,
        fresh context that knows nothing about the session's work). For a fixed list of
        prompts known up front, call this tool once per prompt in order.

        The reply arrives via webhook (auto-started here), NOT in this tool's return —
        this call returns only a send-confirmation. Newlines become spaces. One webhook
        per session: if a session is already being watched, the reply is delivered to the
        conversation that first opened the watcher, the return says which one
        (`watched_conversation_id`), and session_unwatch then session_watch moves it here.

        SENDING WHILE THE AGENT IS BUSY IS SAFE. A dev-agent turn can run for many
        minutes; if one is in flight (or someone is typing in the session, or Claude is
        restarting) the prompt is QUEUED and pasted automatically as soon as the session
        is free, and the return says status "queued" with a `waiting_reason`. A queued
        prompt is never lost, survives an aidc-mcp restart, and never needs re-sending —
        its reply comes over the webhook like any other. session_status shows what is
        still waiting and why. Every prompt waiting when the session frees up goes in
        TOGETHER, as one message in send order, each prompt joined to the next by
        " [next message] " (not a newline: in the paste a newline would submit the first
        prompt alone). The agent answers the batch in one reply, whose callback names
        every prompt in it (`prompts`: prompt_id, sent_by, conversation_id) and when the
        batch was pasted (`pasted_at`).

        THE GIT AGENT'S QUESTION (session "git"). When it asks about a git request, answer
        "Approve" or "Deny: <why>": the request is decided by aidc as you answer (the
        return's `git_request`), and the same option is chosen in the agent's question menu,
        so its turn goes on (status "answered_question"; nothing is pasted, typed text never
        reaches that menu). If the menu could not be answered, the decision still stands:
        status "question_open", question_answered false and question_not_answered saying
        why; the question then waits for the user at the git agent's terminal. A request
        already decided (by the user, or by another answer first) is git_request's
        already_decided, not an error. Approve or Deny with no question open is refused,
        git_request_not_waiting; when the agent's transcript and screen cannot be read it
        is git_transcript_unreadable, retryable.

        Every return carries `prompt_id`, stable for this prompt: session_queue_cancel
        takes it to take back this prompt alone while it still waits, and the reply's
        `prompts` names it. Never re-send a prompt to "make sure it arrived", and never reach
        for session_resend because a reply is slow: that delivers an OLDER reply and
        is how a conversation ends up answering the wrong question.

        A queued return also says what the agent is busy with: working_on, started_by
        (prompt | background_task | session_message | system), turn_started_at (UTC) and
        last_activity (its newest step and when), as session_status does. From that you
        decide: leave it queued, send again with deliver "join", or session_interrupt.

        deliver "join" — WHEN TO USE: the prompt bears on the work in flight (a correction,
        an answer it is waiting for, "also do X", "what are you on?") and should not wait
        out a long turn. The prompt is pasted now and the agent takes it in at its next
        step; status "joined_turn". The reply is NOT separate: it comes inside the running
        turn's final answer, over the webhook as usual, and may cover the earlier work too.
        If the turn ends before the agent takes it in, the agent runs it next and the reply
        comes the same way. WHEN NOT ("queue", the default): an unrelated task, or anything
        that needs its own clean reply. "join" still queues, saying why in join_declined,
        when a prompt is already queued for the session (it never jumps the queue), when
        Claude is not running or shows a dialog or a screen aidc does not recognize, when
        someone has unsent text in the input box or the agent list selected, when an
        interrupt has not been reported yet, or when the session is tainted. With the
        agent idle, "join" sends like "queue".

        Args:
            name: the aidc session to talk to (see the open-webhook list below).
            prompt: the message to send. It is pasted after one line saying who sent it
                (see sender_label), so the agent knows it was not typed at its terminal.
            deliver: "queue" (default) or "join", see above.
        """
        return await snd.send(
            name=name,
            prompt=prompt,
            conversation_id=conversation_id,
            sent_by=sent_by,
            sender_label=sender_label,
            deliver=deliver,
            announce=self.hooks.announce,
        )


class SessionWatch(AidcTool):
    local_name = "session_watch"

    async def call(
        self, ctx: CallContext | None,
        name: Annotated[str, Field(description=NAME_DESC)],
        conversation_id: Annotated[str | None, Field(description=CONV_ID_DESC)] = None
    ) -> dict[str, Any]:
        """CALL THIS FIRST for any back-and-forth with a session.

        Starts a webhook so every reply from the session arrives here automatically —
        without it you are blind to replies unless you poll. Call once; re-calling is
        safe but re-anchors forward (it delivers only turns completing AFTER the call,
        never a backlog — see _baseline_watermark).
        session_send starts one automatically, so you only need this to
        watch a session you are not actively sending to yet.

        Args:
            name: the aidc session to watch (see the open-webhook list below).
        """
        return await dlv.watch(
            name=name,
            conversation_id=conversation_id,
            announce=self.hooks.announce,
        )


class SessionResend(AidcTool):
    local_name = "session_resend"

    async def call(
        self, ctx: CallContext | None,
        name: Annotated[str, Field(description=NAME_DESC)],
        conversation_id: Annotated[str | None, Field(description=CONV_ID_DESC)] = None,
        turn_uuid: Annotated[
            str | None,
            Field(description="Optional: target a specific reply by its turn uuid. "
                              "Omit to target the session's most recent reply."),
        ] = None,
        force: Annotated[
            bool,
            Field(description="Re-POST even if this reply was already confirmed "
                              "delivered here. Almost never correct — the content "
                              "comes back in this tool's result either way. Use ONLY "
                              "when the orchestrator acknowledged the callback but genuinely "
                              "lost the message downstream."),
        ] = False,
    ) -> dict[str, Any]:
        """Fetch a session reply again when it did not land in this conversation.

        WHEN TO USE: a reply from session_send is genuinely absent here — a dropped
        callback, a watcher gap, an MCP restart at the wrong moment.
        WHEN NOT: a reply is merely SLOW. A session mid-turn has not answered yet,
        and the newest COMPLETED reply answers an EARLIER prompt — reading it as the
        pending answer makes the conversation respond to the wrong question. Wait for
        the webhook instead; it always arrives.

        This never duplicates. If the reply was already confirmed delivered here, it
        is NOT re-posted — the content is returned in this result instead, so you can
        read it without a second copy landing in the conversation. `status` says which
        happened:

          resent            - the reply was re-posted and will arrive over the webhook
          already_delivered - NOT re-posted; it is in `content` below, and it is
                              already somewhere above in this conversation

        Args:
            name: the aidc session whose reply to fetch.
            turn_uuid: a specific reply's uuid; omit for the latest reply.
            force: re-POST a reply already delivered here (almost never correct).
        """
        return await dlv.resend(
            name=name,
            conversation_id=conversation_id,
            turn_uuid=turn_uuid,
            force=force,
        )


class SessionUnwatch(AidcTool):
    local_name = "session_unwatch"

    async def call(self, ctx: CallContext | None, name: str
    ) -> dict[str, Any]:
        """Stop watching the agent window for the named session.

        Cancels the background watcher started by session_watch.
        No-op if no watcher is active for the session.
        """
        return await dlv.unwatch(name=name, announce=self.hooks.announce)


class SessionQueueCancel(AidcTool):
    local_name = "session_queue_cancel"

    async def call(
        self, ctx: CallContext | None,
        name: Annotated[str, Field(description=NAME_DESC)],
        position: Annotated[int | None, Field(description=(
            "Which waiting prompt, 1 for the next to go in (as session_status lists them); "
            "omit both this and prompt_id to take back every one."))] = None,
        prompt_id: Annotated[str | None, Field(description=(
            "The prompt_id session_send returned: take back that prompt only. "
            "Not together with position."))] = None,
    ) -> dict[str, Any]:
        """Take back prompts sent with session_send that are still waiting to be pasted.

        Only prompts the session has never seen: one already pasted is the agent's and
        is not touched. Each one taken back is kept in the send dead-letter dir, and is
        left out of the next batch; the rest keep their order.

        With prompt_id, outcome says plainly what happened to that prompt: "cancelled"
        (it was waiting and is taken back), "already_pasted" (too late: it went in, at
        pasted_at, or is in the input box being submitted), or "unknown" (no prompt with
        that id was sent to this session). The check and the take-back are one step
        against the paste: a prompt is either in the pasted batch or cancelled, never
        both.

        Returns outcome, cancelled (prompt_id, position, prompt_preview, enqueued_at,
        conversation_id), left (how many still wait) and running (whether the agent is
        working, and on what).
        """
        return await snd.queue_cancel(name=name, position=position, prompt_id=prompt_id)
