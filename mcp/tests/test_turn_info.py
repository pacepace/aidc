"""What a running turn is doing: what opened it, when, and its newest step.

2026-10-22, metallm: an orchestrator's prompt waited 45 minutes behind one turn a
background task's notification had opened, while session_status named, as what the
agent was working on, the person's earlier prompt it had already answered. These tests
pin that a caller now reads what really opened the turn (turn_info), never a system
wrapper as a person's words, and that such a turn reads busy from its first line.

The fixture keeps the line shapes of that transcript (Claude Code 2.1.300: the
notification's provenance fields, a prompt pasted mid-turn as a queue-operation and
its queued_command attachment, the stop records); its words are replaced, because the
original is a private repository's.
"""
import json
from pathlib import Path

import pytest

from aidc_mcp import transcript as ts
from aidc_mcp import turns_view as tv

FIXTURES = Path(__file__).parent / "fixtures"
EVENING = [json.loads(ln) for ln in
           (FIXTURES / "claude-2.1.300-notification-turn.jsonl").read_text().splitlines()]


def _through(uuid: str) -> list[dict]:
    """The fixture as the mirror showed it once the line `uuid` was written."""
    index = next(i for i, o in enumerate(EVENING) if o.get("uuid") == uuid)
    return EVENING[:index + 1]


def _user(text, uuid="u", ts_="2026-10-22T10:00:00.000Z", **kw):
    return {"type": "user", "uuid": uuid, "timestamp": ts_,
            "message": {"role": "user", "content": text}, **kw}


def _asst(blocks, uuid="a", ts_="2026-10-22T10:00:05.000Z", stop="end_turn"):
    return {"type": "assistant", "uuid": uuid, "timestamp": ts_,
            "message": {"role": "assistant", "content": blocks, "stop_reason": stop}}


def _done(uuid="d", ts_="2026-10-22T10:00:06.000Z"):
    return {"type": "system", "subtype": "turn_duration", "uuid": uuid, "timestamp": ts_}


FINISHED = [_user("what is f", "u0", promptSource="typed", origin={"kind": "human"}),
            _asst([{"type": "text", "text": "f returns 1"}], "a0"), _done("d0")]


# --- the evening's turn ---------------------------------------------------------------


def test_a_turn_a_background_task_opened_says_so_and_never_names_the_earlier_prompt():
    """The bug: working_on named 'Bring the two branches in…', answered at 18:29, for
    the whole 47-minute notification turn."""
    info = tv.turn_info(_through("r3"))
    assert info["started_by"] == "background_task"
    assert info["working_on"] == ('background task completed: Agent "Map the memory code" '
                                  "finished (task a5f3d4d002a7a711d)")
    assert "Bring the two branches" not in info["working_on"]
    assert "<task-notification>" not in info["working_on"]
    assert info["turn_started_at"] == "2026-10-22T18:31:12.702000Z"


def test_the_newest_step_tells_progress_from_a_stall():
    assert tv.turn_info(_through("r3"))["last_activity"] == {
        "kind": "tool_use", "name": "Bash", "at": "2026-10-22T19:17:42Z"}
    assert tv.turn_info(_through("a8"))["last_activity"] == {
        "kind": "thinking", "at": "2026-10-22T19:18:17Z"}
    assert tv.turn_info(_through("a4"))["last_activity"] == {
        "kind": "text", "at": "2026-10-22T18:31:21Z"}


def test_a_turn_a_notification_opened_reads_busy_before_claude_writes_anything():
    """19:19:35 that evening: the notification line was the tail for two seconds, read
    as local output (it opens with a tag), so the session looked free and a queued
    prompt was pasted into the turn just starting."""
    tail = _through("n1")
    assert ts.log_shows_turn_in_progress(tail) is True
    info = tv.turn_info(tail)
    assert info["started_by"] == "background_task" and info["last_activity"] is None


def test_a_prompt_taken_into_the_running_turn_does_not_change_what_opened_it():
    """The queue-operation and queued_command attachment of a mid-turn paste are not a
    new turn: the joined prompt's answer is part of this turn's reply."""
    info = tv.turn_info(_through("at1"))
    assert info["started_by"] == "background_task"
    assert info["turn_started_at"] == "2026-10-22T18:31:12.702000Z"
    turns = ts.extract_completed_turns(_through("s4"))
    assert turns[-1].text.endswith("On your status check: I was on the merge.")
    assert turns[-1].terminal_uuid == "a9"


def test_no_turn_is_open_once_the_turn_has_ended():
    assert tv.turn_info(_through("s4")) == tv.NO_TURN
    assert tv.turn_info(_through("s2")) == tv.NO_TURN


def test_a_prompt_opens_the_next_turn_with_its_words_unwrapped():
    info = tv.turn_info(EVENING)
    assert info == {"working_on": "Amend the spec copy.", "started_by": "prompt",
                    "turn_started_at": "2026-10-22T19:18:30.633000Z", "last_activity": None}


# --- what opens a turn ------------------------------------------------------------------


def test_another_sessions_message_opens_a_turn_and_reads_busy():
    peer = _user("Another Claude session sent a message:\n<agent-message from=\"general-purpose\">"
                 "\nhi\n</agent-message>", "m1", "2026-10-22T10:01:00.000Z", isMeta=True,
                 promptSource="system", origin={"kind": "peer", "from": "general-purpose"})
    objs = FINISHED + [peer]
    assert ts.log_shows_turn_in_progress(objs) is True
    info = tv.turn_info(objs)
    assert info["started_by"] == "session_message"
    assert info["working_on"] == "a message from another Claude session (general-purpose)"
    assert info["turn_started_at"] == "2026-10-22T10:01:00Z"


def test_the_coordinators_message_is_a_session_message():
    note = _user("The coordinator sent a message while you were working:\nstop", "m1",
                 isMeta=True, origin={"kind": "coordinator"})
    assert tv.turn_info(FINISHED + [note])["started_by"] == "session_message"


def test_a_message_handed_to_a_running_turn_does_not_reopen_it():
    running = [_user("fix the test", "u1", promptSource="typed", origin={"kind": "human"}),
               _asst([{"type": "tool_use", "name": "Bash", "id": "t"}], "a1", stop="tool_use")]
    peer = _user("Another Claude session sent a message while you were working:\nx", "m1",
                 isMeta=True, origin={"kind": "peer", "from": "x"})
    info = tv.turn_info(running + [peer])
    assert info["started_by"] == "prompt" and info["working_on"] == "fix the test"


def test_a_prompt_sent_through_remote_control_or_held_by_claude_code_is_a_prompt():
    for source, origin in (("sdk", None), ("queued", {"kind": "human"})):
        line = _user("Status report, please.", "u1", promptSource=source,
                     **({"origin": origin} if origin else {}))
        info = tv.turn_info(FINISHED + [line])
        assert (info["started_by"], info["working_on"]) == ("prompt", "Status report, please.")


def test_an_auto_continue_is_claude_code_starting_the_turn_itself():
    cont = _user("Continue from where you left off.", "m1", isMeta=True)
    work = _asst([{"type": "tool_use", "name": "Read", "id": "t"}], "a1", stop="tool_use")
    info = tv.turn_info(FINISHED + [cont, work])
    assert info["started_by"] == "system"
    assert info["working_on"] == "something Claude Code started itself, not a prompt"


def test_a_scheduled_wake_up_is_not_shown_as_a_persons_words():
    wake = _user("Check on the batch job status", "u1", promptSource="system")
    info = tv.turn_info(FINISHED + [wake])
    assert info["started_by"] == "system" and "batch job" not in info["working_on"]


def test_work_with_no_opening_line_in_the_transcript_says_so():
    info = tv.turn_info([_asst([{"type": "tool_use", "name": "Read", "id": "t"}], stop="tool_use")])
    assert info["started_by"] == "system"
    assert info["working_on"] == "a turn whose opening line is not in the transcript"
    assert info["last_activity"]["name"] == "Read"


def test_a_stop_hook_pushback_keeps_the_turn_its_prompt_opened():
    """A real 2.1.274 capture: the hook's feedback line is not a new turn."""
    objs = [json.loads(ln) for ln in (FIXTURES / "claude-2.1.274-pushback-interrupt-task.jsonl")
            .read_text().splitlines()]
    info = tv.turn_info(objs[:3])
    assert info["started_by"] == "prompt"
    assert info["working_on"] == "Reply with exactly the word FIRST and nothing else."


def test_an_interrupt_or_a_local_command_ends_the_turn():
    running = [_user("fix the test", "u1"),
               _asst([{"type": "tool_use", "name": "Bash", "id": "t"}], "a1", stop="tool_use")]
    marker = _user([{"type": "text", "text": "[Request interrupted by user]"}], "i1")
    assert tv.turn_info(running + [marker]) == tv.NO_TURN
    caveat = _user("<local-command-caveat>Caveat</local-command-caveat>", "c0", isMeta=True)
    clear = _user("<command-name>/clear</command-name><command-message>clear</command-message>",
                  "c1")
    assert tv.turn_info(FINISHED + [caveat, clear]) == tv.NO_TURN


def test_back_to_back_prompts_are_one_turn_named_by_the_newest():
    objs = FINISHED + [_user("first", "u1", "2026-10-22T10:02:00.000Z"),
                       _user("second", "u2", "2026-10-22T10:02:01.000Z")]
    info = tv.turn_info(objs)
    assert info["working_on"] == "second"
    assert info["turn_started_at"] == "2026-10-22T10:02:00Z"


def test_a_secret_in_the_prompt_is_redacted_and_the_text_is_cut():
    key = "sk-ant-" + "a" * 30
    info = tv.turn_info(FINISHED + [_user(f"use {key} then " + "x" * 400, "u1")])
    assert key not in info["working_on"] and tv.REDACTED in info["working_on"]
    assert len(info["working_on"]) == 300


@pytest.mark.parametrize("cut", [e.get("uuid") for e in EVENING if e.get("uuid")])
def test_started_by_is_always_one_of_the_documented_values(cut):
    info = tv.turn_info(_through(cut))
    assert info["started_by"] in (None, *tv.STARTED_BY)
    assert (info["started_by"] is None) == (info == tv.NO_TURN)


# --- one rule for "a turn is open" ---------------------------------------------------

_ENDINGS = {
    "api error": FINISHED + [
        _user("go", "u1"),
        {"type": "assistant", "uuid": "e1", "timestamp": "2026-10-22T10:01:00.000Z",
         "isApiErrorMessage": True,
         "message": {"role": "assistant", "content": [{"type": "text", "text": "overloaded"}],
                     "stop_reason": "stop_sequence"}}],
    "interactive question": FINISHED + [
        _user("go", "u1"),
        _asst([{"type": "tool_use", "name": "AskUserQuestion", "id": "q",
                "input": {"questions": []}}], "a1", stop="tool_use")],
    "auto-continue at rest": FINISHED + [_user("Continue from where you left off.", "m1",
                                               isMeta=True)],
}


def _every_cut():
    real = [json.loads(ln) for ln in (FIXTURES / "claude-2.1.274-pushback-interrupt-task.jsonl")
            .read_text().splitlines()]
    for name, objs in (("evening", EVENING), ("2.1.274", real), *_ENDINGS.items()):
        for n in range(len(objs) + 1):
            yield f"{name}[:{n}]", objs[:n]


@pytest.mark.parametrize("label,objs", list(_every_cut()), ids=lambda v: v if isinstance(
    v, str) else "")
def test_turn_info_and_the_busy_verdict_never_disagree(label, objs):
    """The send path and session_status decide "working" with log_shows_turn_in_progress;
    turn_info must describe a turn exactly when that says one is open, or a caller is
    told about a turn that has ended (an API error, a question to the user)."""
    assert (ts.open_turn(objs) is None) == (not ts.log_shows_turn_in_progress(objs)), label
    assert (tv.turn_info(objs) == tv.NO_TURN) == (not ts.log_shows_turn_in_progress(objs)), label


def test_a_turn_that_ended_on_an_api_error_or_a_question_is_not_open():
    for name in ("api error", "interactive question"):
        assert tv.turn_info(_ENDINGS[name]) == tv.NO_TURN, name
