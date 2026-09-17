"""Tests for the send path's free check and the interrupted-before-output report
(design-10 S1/S2).

The transcript decides whether Claude is busy; the screen is consulted only for the
input box, whether Claude is at its prompt, and (when the transcript shows a turn in
progress that has gone quiet) the status row's working text. The Docker/tmux boundary
is patched; the transcript is a real file under a temp mirror dir, and the screens
are real captures from Claude Code 2.1.27x.
"""
import json
import os
from pathlib import Path

import pytest

from aidc_mcp import tools
from aidc_mcp import transcript as ts
from aidc_mcp.screen import EMPTY, ScreenState, classify

SCREENS = Path(__file__).parent / "fixtures" / "screens"
NOW = 1_789_609_900.0   # 2026-09-17T01:51:40Z
ISO_NOW = "2026-09-17T01:51:40.000Z"


def _screen(name):
    return (SCREENS / f"claude-2.1.27x-{name}.ansi").read_text()


def _typed(uuid, text, when=ISO_NOW):
    return {"type": "user", "uuid": uuid, "timestamp": when, "promptSource": "typed",
            "origin": {"kind": "human"}, "message": {"role": "user", "content": text}}


def _reply(uuid, text, stop="end_turn", when=ISO_NOW):
    blocks = [{"type": "text", "text": text}] if text else [{"type": "tool_use", "id": "t"}]
    return {"type": "assistant", "uuid": uuid, "timestamp": when,
            "message": {"role": "assistant", "content": blocks, "stop_reason": stop}}


SUMMARY = {"type": "system", "subtype": "stop_hook_summary", "hookErrors": []}
DURATION = {"type": "system", "subtype": "turn_duration", "durationMs": 900}
FINISHED = [_typed("u0", "q"), _reply("a0", "A."), SUMMARY, DURATION]
# The prompt in claude-2.1.27x-esc-before-output-sent-prompt-restored.ansi.
RESTORED = "Think carefully, then write a 300-word explanation of how TCP slow start works."


class Session:
    def __init__(self, tmp_path, monkeypatch):
        self.base = tmp_path / "mirror"
        self.running = True
        self.screen = _screen("idle-empty")
        self.clock = NOW
        monkeypatch.setattr(tools, "_TRANSCRIPTS_BASE", self.base)
        monkeypatch.setattr(tools.time, "time", lambda: self.clock)

        async def is_running(container):
            return self.running

        async def capture(container, window):
            return self.screen

        monkeypatch.setattr(tools, "_is_claude_running", is_running)
        monkeypatch.setattr(tools, "_capture_screen", capture)

    def write(self, objs, age=100.0):
        d = self.base / "proj"
        d.mkdir(parents=True, exist_ok=True)
        p = d / "sid.jsonl"
        p.write_text("\n".join(json.dumps(o) for o in objs) + "\n")
        os.utime(p, (self.clock - age, self.clock - age))
        return p

    async def check(self):
        return await tools._check_free("aidc-proj-dev", "proj")


@pytest.fixture
def session(tmp_path, monkeypatch):
    return Session(tmp_path, monkeypatch)


class TestCheckFree:
    async def test_free_when_the_turn_is_finished_and_the_box_is_empty(self, session):
        session.write(FINISHED)
        assert await session.check() == ""

    async def test_free_when_nothing_has_been_sent_yet(self, session):
        assert await session.check() == ""

    async def test_claude_not_running(self, session):
        session.running = False
        assert await session.check() == "claude_not_running"

    async def test_not_at_prompt_on_the_trust_screen_even_if_the_log_is_finished(self, session):
        session.write(FINISHED)
        session.screen = _screen("trust-folder")
        assert await session.check() == "claude_not_at_prompt"

    async def test_unsent_text_holds_the_prompt(self, session):
        session.write(FINISHED)
        session.screen = _screen("typed-unsent")
        assert await session.check() == "input_has_text"

    async def test_busy_whatever_the_screen_shows_while_the_log_is_growing(self, session):
        session.write([_typed("u1", "q"), _reply("a1", None, stop="tool_use")], age=1.0)
        assert await session.check() == "claude_busy"

    async def test_silent_long_tool_call_is_busy_by_the_status_row(self, session):
        session.write([_typed("u1", "q"), _reply("a1", None, stop="tool_use")], age=120.0)
        session.screen = _screen("busy-tool-empty-box")
        assert await session.check() == "claude_busy"

    async def test_esc_before_output_is_free_once_the_working_text_has_been_seen(self, session):
        """The prompt has no reply and nothing marks the interrupt; the status row,
        whose wording this session has shown before, says Claude stopped."""
        session.screen = _screen("busy-tool-empty-box")
        session.write([_typed("u1", "q"), _reply("a1", None, stop="tool_use")], age=120.0)
        assert await session.check() == "claude_busy"          # seen working
        session.write([*FINISHED, _typed("u2", "essay")], age=30.0)
        session.screen = _screen("idle-empty")
        assert await session.check() == ""

    async def test_a_prompt_put_back_in_the_box_is_a_stop_without_the_working_text(
            self, session):
        """Claude Code returns the prompt to the input box when Esc is pressed before
        it writes anything. That is proof enough, with no working text ever seen; the
        session is then held for the person's text in the box, not for a turn."""
        session.write([*FINISHED, _typed("u1", RESTORED)], age=10.0)
        session.screen = _screen("esc-before-output-sent-prompt-restored")
        assert await session.check() == "input_has_text"
        assert tools._last_free_verdict["proj"][1] == "prompt_restored"

    async def test_other_text_in_the_box_is_not_proof_of_a_stop(self, session):
        session.write([*FINISHED, _typed("u1", "a different prompt")], age=10.0)
        session.screen = _screen("esc-before-output-sent-prompt-restored")
        assert await session.check() == "claude_busy"
        assert tools._last_free_verdict["proj"][1] == "status_row_unproven"

    async def test_the_working_text_is_remembered_across_a_restart(self, session):
        session.screen = _screen("busy-tool-empty-box")
        session.write([_typed("u1", "q"), _reply("a1", None, stop="tool_use")], age=120.0)
        assert await session.check() == "claude_busy"          # seen working
        tools._working_indicator_seen.clear()                  # the MCP restarts
        session.write([*FINISHED, _typed("u2", "essay")], age=30.0)
        session.screen = _screen("idle-empty")
        assert await session.check() == ""
        assert tools._last_free_verdict["proj"][1] == "status_row_idle"

    async def test_a_removed_session_forgets_the_working_text_on_disk(self, session):
        session.screen = _screen("busy-tool-empty-box")
        session.write([_typed("u1", "q"), _reply("a1", None, stop="tool_use")], age=120.0)
        await session.check()
        tools._forget_session_send_state("proj")
        assert not tools._working_indicator_known("proj")

    async def test_without_ever_seeing_the_working_text_a_quiet_open_turn_stays_busy(
            self, session):
        session.write([_typed("u1", "essay")], age=30.0)
        assert await session.check() == "claude_busy"
        session.write([_typed("u1", "essay")], age=tools._LOG_STALL_S)
        assert await session.check() == ""

    async def test_reply_whose_stop_hooks_are_still_running_is_busy(self, session):
        session.write([*FINISHED, _typed("u1", "q"), _reply("a1", "B.")], age=1.0)
        assert await session.check() == "claude_busy"

    async def test_stop_hook_hold_is_busy_whatever_the_screen_shows(self, session):
        tools._working_indicator_seen.add("proj")
        session.write([*FINISHED, _typed("u1", "q"), _reply("a1", "B.")], age=30.0)
        assert await session.check() == "claude_busy"
        assert tools._last_free_verdict["proj"][1] == "stop_hooks_running"

    async def test_past_the_stop_hook_hold_an_idle_status_row_means_free(self, session):
        tools._working_indicator_seen.add("proj")
        session.write([*FINISHED, _typed("u1", "q"), _reply("a1", "B.")],
                      age=tools._STOP_HOOK_WAIT_S)
        assert await session.check() == ""
        assert tools._last_free_verdict["proj"][1] == "status_row_idle"

    async def test_past_the_stop_hook_hold_a_working_status_row_still_wins(self, session):
        """A Stop hook that runs longer than the hold (a long review gate) with the
        status row still saying Claude is working must not get a prompt pasted in."""
        session.write([*FINISHED, _typed("u1", "q"), _reply("a1", "B.")],
                      age=tools._STOP_HOOK_WAIT_S + 60)
        session.screen = _screen("busy-tool-empty-box")
        assert await session.check() == "claude_busy"
        assert tools._last_free_verdict["proj"][1] == "status_row_working"

    async def test_just_pasted_prompt_is_busy_until_the_log_shows_it(self, session):
        session.write(FINISHED)
        tools._sent_awaiting_echo["proj"] = ("next task", NOW - 3)
        assert await session.check() == "claude_busy"
        session.write([*FINISHED, _typed("u1", "next task", when=ISO_NOW)], age=1.0)
        assert await session.check() == "claude_busy"           # now busy by the log
        assert "proj" not in tools._sent_awaiting_echo

    async def test_prompt_queued_behind_a_running_turn_counts_as_arrived(self, session):
        session.write([*FINISHED, {"type": "queue-operation", "operation": "enqueue",
                                   "timestamp": ISO_NOW, "content": "next task"}])
        tools._sent_awaiting_echo["proj"] = ("next task", NOW - 3)
        assert await session.check() == ""
        assert "proj" not in tools._sent_awaiting_echo

    async def test_free_check_logs_each_change_of_verdict_with_its_evidence(
            self, session, monkeypatch):
        logged = []
        monkeypatch.setattr(tools, "log_event", lambda kind, **f: logged.append((kind, f)))
        session.write(FINISHED)
        await session.check()
        await session.check()
        session.screen = _screen("typed-unsent")
        await session.check()
        checks = [f for kind, f in logged if kind == "session_free_check"]
        assert [(c["reason"], c["why"]) for c in checks] == [
            ("", "log_finished"), ("input_has_text", "log_finished")]

    async def test_free_without_a_transcript_says_so(self, session, monkeypatch):
        logged = []
        monkeypatch.setattr(tools, "log_event", lambda kind, **f: logged.append((kind, f)))
        assert await session.check() == ""
        assert logged[-1][1]["why"] == "transcript_none"

    async def test_unrecognized_screen_is_reported_and_saved(self, session):
        session.write(FINISHED)
        session.screen = "some layout nobody has seen\nwith no input box\n"
        assert await session.check() == "screen_unrecognized"
        saved = tools._WATCHER_STATE_DIR / "screens" / "proj-unrecognized.ansi"
        assert saved.read_text() == session.screen


class TestSessionStateSeparatesTurnFromInputBox:
    async def test_a_running_turn_with_text_in_the_box_is_still_running(self, session):
        """session_resend's 'STILL WORKING' warning reads the turn, not the box."""
        session.write([_typed("u1", "q"), _reply("a1", None, stop="tool_use")], age=1.0)
        session.screen = _screen("typed-unsent")
        state = await tools._session_state("aidc-proj-dev", "proj")
        assert (state.turn, tools._paste_reason(state)) == (tools.TURN_RUNNING, "claude_busy")

    async def test_turn_end_ignores_a_prompt_put_back_in_the_box(self, session, monkeypatch):
        """Esc before output puts the prompt back in the box. session_run's wait for the
        turn to end must not sit out its full timeout on that."""
        async def nosleep(_):
            return None
        monkeypatch.setattr(tools.asyncio, "sleep", nosleep)
        session.write(FINISHED)
        session.screen = _screen("esc-before-output-prompt-restored")
        assert await tools._wait_for_turn_end("aidc-proj-dev", "proj", timeout=60) == ""

    async def test_send_path_waits_for_the_watcher_to_report_the_interrupt(self, session):
        tools._working_indicator_seen.add("proj")
        tools._session_watchers["proj"] = object()
        try:
            session.write([*FINISHED, _typed("u2", "essay")], age=30.0)
            state = await tools._session_state("aidc-proj-dev", "proj")
            assert (state.turn, state.why) == (tools.TURN_RUNNING, "interrupt_not_reported_yet")
            tools._reported_interrupts.add(("proj", "u2"))
            state = await tools._session_state("aidc-proj-dev", "proj")
            assert (state.turn, state.why) == (tools.TURN_IDLE, "status_row_idle")
        finally:
            tools._session_watchers.pop("proj", None)

    async def test_without_a_watcher_there_is_no_report_to_wait_for(self, session):
        tools._working_indicator_seen.add("proj")
        session.write([*FINISHED, _typed("u2", "essay")], age=30.0)
        assert await session.check() == ""


class TestWatchForEcho:
    async def test_a_prompt_that_never_shows_is_logged_after_a_single_send(
            self, session, monkeypatch):
        logged = []
        monkeypatch.setattr(tools, "log_event", lambda kind, **f: logged.append((kind, f)))

        async def nosleep(_):
            return None
        monkeypatch.setattr(tools.asyncio, "sleep", nosleep)
        session.write(FINISHED)
        tools._sent_awaiting_echo["proj"] = ("lost", NOW)
        await tools._watch_for_echo("proj", "lost", NOW)
        assert "proj" not in tools._sent_awaiting_echo
        [(kind, fields)] = [e for e in logged if e[0] == "session_send_not_seen_in_transcript"]
        assert fields["waited_s"] == tools._ECHO_WAIT_S

    async def test_seen_prompt_clears_the_hold_without_logging(self, session, monkeypatch):
        logged = []
        monkeypatch.setattr(tools, "log_event", lambda kind, **f: logged.append(kind))
        session.write([*FINISHED, _typed("u1", "next", when=ISO_NOW)])
        tools._sent_awaiting_echo["proj"] = ("next", NOW - 1)
        await tools._watch_for_echo("proj", "next", NOW - 1)
        assert "proj" not in tools._sent_awaiting_echo
        assert "session_send_not_seen_in_transcript" not in logged

    async def test_a_later_paste_is_not_cleared_by_an_earlier_watch(self, session):
        session.write(FINISHED)
        tools._sent_awaiting_echo["proj"] = ("second", NOW)
        await tools._watch_for_echo("proj", "first", NOW - 5)
        assert tools._sent_awaiting_echo["proj"] == ("second", NOW)


class TestEviction:
    def _fill(self):
        tools._working_indicator_seen.add("proj")
        tools._sent_awaiting_echo["proj"] = ("x", NOW)
        tools._reported_interrupts.add(("proj", "u1"))
        tools._last_free_verdict["proj"] = ("", "log_finished")

    def test_unwatching_keeps_the_send_paths_state(self):
        """A session_unwatch must not make a prompt just pasted look unsent: that
        state belongs to the session, not to its webhook."""
        self._fill()
        tools._evict_session_state("proj")
        assert "proj" in tools._working_indicator_seen
        assert tools._sent_awaiting_echo["proj"] == ("x", NOW)
        assert "proj" in tools._last_free_verdict

    def test_a_removed_session_forgets_it(self):
        self._fill()
        tools._forget_session_send_state("proj")
        assert "proj" not in tools._working_indicator_seen
        assert "proj" not in tools._sent_awaiting_echo
        assert ("proj", "u1") not in tools._reported_interrupts
        assert "proj" not in tools._last_free_verdict


class TestWaitUntilFree:
    async def test_needs_two_consecutive_free_readings(self, monkeypatch):
        readings = iter(["", "claude_busy", "", ""])
        calls = []

        async def check(container, name):
            calls.append(1)
            return next(readings)

        async def nosleep(_):
            return None

        monkeypatch.setattr(tools, "_check_free", check)
        monkeypatch.setattr(tools.asyncio, "sleep", nosleep)
        assert await tools._wait_until_free("c", "proj", timeout=10) == ""
        assert len(calls) == 4

    async def test_returns_the_last_reason_when_it_never_frees(self, monkeypatch):
        async def check(container, name):
            return "input_has_text"

        async def nosleep(_):
            return None

        monkeypatch.setattr(tools, "_check_free", check)
        monkeypatch.setattr(tools.asyncio, "sleep", nosleep)
        assert await tools._wait_until_free("c", "proj", timeout=3) == "input_has_text"


class TestReplyFromTranscript:
    def test_reply_after_the_prompt(self, session):
        session.write([*FINISHED, _typed("u1", "run it"), _reply("a1", "Done."),
                       SUMMARY, DURATION])
        assert tools._reply_from_transcript("proj", "run it", NOW - 1) == "Done."

    def test_an_older_identical_prompt_is_not_the_one(self, session):
        session.write([_typed("u0", "run it", when="2026-09-17T01:00:00.000Z"),
                       _reply("a0", "OLD"), SUMMARY, DURATION])
        assert tools._reply_from_transcript("proj", "run it", NOW - 1) == ""

    def test_interrupted_reply_carries_the_note(self, session):
        interrupt = {"type": "user", "uuid": "i1", "timestamp": ISO_NOW,
                     "message": {"role": "user", "content": [
                         {"type": "text", "text": "[Request interrupted by user]"}]}}
        session.write([_typed("u1", "run it"), _reply("a1", "Starting.", stop="tool_use"),
                       interrupt])
        assert tools._reply_from_transcript("proj", "run it", NOW - 1) == ts.render_delivery(
            "Starting.", [], interrupted=True)


class TestInterruptedBeforeOutputDelivery:
    """The watcher's report of an Esc pressed before Claude wrote anything."""

    def _setup(self, tmp_path, tail, working=False, seen=True):
        base = tmp_path / "t"; state = tmp_path / "s"
        d = base / "sess"; d.mkdir(parents=True)
        p = d / "sid1.jsonl"
        p.write_text("\n".join(json.dumps(o) for o in FINISHED) + "\n")
        self.path = p
        self.base, self.state = base, state
        self.tail = tail
        self.screen = ScreenState(EMPTY, working=working)
        self.posted = []
        if seen:
            tools._working_indicator_seen.add("sess")

    async def _post(self, turn, attempt):
        self.posted.append(turn)
        return True

    async def _screen_fn(self, session):
        return self.screen

    async def drain(self, quiet=60.0):
        mtime = self.path.stat().st_mtime
        await tools._drain_transcript_once(
            "sess", "conv", "http://cb", transcripts_base=self.base, state_dir=self.state,
            post_fn=self._post, screen_fn=self._screen_fn,
            wall_now_fn=lambda: mtime + quiet)

    def append_tail(self):
        self.path.write_text("\n".join(json.dumps(o) for o in [*FINISHED, *self.tail]) + "\n")

    async def test_reported_once_after_two_quiet_polls(self, tmp_path):
        self._setup(tmp_path, [_typed("u1", "write an essay")])
        await self.drain()                      # baseline
        self.append_tail()
        await self.drain()
        assert self.posted == []                # one reading is not enough
        await self.drain()
        assert [(t.terminal_uuid, t.interrupted) for t in self.posted] == [("u1", True)]
        assert ts.NOTHING_WRITTEN in self.posted[0].text
        await self.drain()
        await self.drain()
        assert len(self.posted) == 1

    async def test_not_reported_while_the_status_row_says_working(self, tmp_path):
        """Claude can think for a long time before writing its first line."""
        self._setup(tmp_path, [_typed("u1", "hard question")], working=True)
        await self.drain()
        self.append_tail()
        for _ in range(4):
            await self.drain()
        assert self.posted == []

    async def test_not_reported_while_the_transcript_is_still_fresh(self, tmp_path):
        self._setup(tmp_path, [_typed("u1", "q")])
        await self.drain()
        self.append_tail()
        for _ in range(3):
            await self.drain(quiet=2.0)
        assert self.posted == []

    async def test_unproven_working_text_waits_for_the_stall_window(self, tmp_path):
        self._setup(tmp_path, [_typed("u1", "q")], seen=False)
        await self.drain()
        self.append_tail()
        for _ in range(3):
            await self.drain(quiet=60.0)
        assert self.posted == []
        await self.drain(quiet=tools._LOG_STALL_S)
        await self.drain(quiet=tools._LOG_STALL_S)
        assert [t.terminal_uuid for t in self.posted] == ["u1"]

    async def test_a_restored_prompt_is_reported_without_waiting_for_the_stall_window(
            self, tmp_path):
        """The joint test of 2026-09-17: an MCP restarted a minute earlier had never
        seen the working text, and reported this Esc only after ten minutes."""
        self._setup(tmp_path, [_typed("u1", RESTORED)], seen=False)
        self.screen = classify(_screen("esc-before-output-sent-prompt-restored"))
        await self.drain()
        self.append_tail()
        await self.drain(quiet=10.0)
        await self.drain(quiet=10.0)
        assert [(t.terminal_uuid, t.interrupted) for t in self.posted] == [("u1", True)]

    async def test_only_the_latest_report_per_session_is_remembered(self, tmp_path):
        self._setup(tmp_path, [_typed("u1", "first")])
        await self.drain()
        self.append_tail()
        await self.drain()
        await self.drain()
        self.tail = [_typed("u1", "first"), _typed("u2", "second")]
        self.append_tail()
        await self.drain()
        await self.drain()
        assert [t.terminal_uuid for t in self.posted] == ["u1", "u2"]
        assert {r for r in tools._reported_interrupts if r[0] == "sess"} == {("sess", "u2")}

    async def test_a_prompt_whose_turn_ended_with_no_reply_is_not_called_interrupted(
            self, tmp_path):
        """Only an open turn the screen shows stopped is an interrupt. A prompt followed
        by Claude Code's end-of-turn record and no reply has not been measured; calling
        it "interrupted at the terminal" would say something nobody saw happen."""
        self._setup(tmp_path, [_typed("u1", "q"), DURATION])
        await self.drain()
        self.append_tail()
        for _ in range(3):
            await self.drain()
        assert self.posted == []

    async def test_not_reported_when_claude_is_not_running(self, tmp_path):
        self._setup(tmp_path, [_typed("u1", "q")])
        self.screen = None
        await self.drain()
        self.append_tail()
        for _ in range(3):
            await self.drain()
        assert self.posted == []

    async def test_a_local_command_is_never_reported(self, tmp_path):
        cmd = {"type": "user", "uuid": "c1", "timestamp": ISO_NOW,
               "message": {"role": "user",
                           "content": "<command-name>/model</command-name><command-args></command-args>"}}
        out = {"type": "user", "uuid": "c2", "timestamp": ISO_NOW,
               "message": {"role": "user",
                           "content": "<local-command-stdout>Set model</local-command-stdout>"}}
        self._setup(tmp_path, [cmd, out])
        await self.drain()
        self.append_tail()
        for _ in range(3):
            await self.drain()
        assert self.posted == []

    async def test_working_text_is_learned_while_a_turn_runs(self, tmp_path):
        """A session only a person types into never goes through the send path's
        screen reads, so the watcher learns the working text itself."""
        self._setup(tmp_path, [_typed("u1", "q"), _reply("a1", None, stop="tool_use")],
                    working=True, seen=False)
        calls = []

        async def screen_fn(session):
            calls.append(session)
            tools._working_indicator_seen.add(session)   # what _read_screen does
            return self.screen

        self._screen_fn = screen_fn
        await self.drain()
        self.append_tail()
        await self.drain(quiet=1.0)
        await self.drain(quiet=1.0)
        assert calls == ["sess"]
        assert "sess" in tools._working_indicator_seen

    async def test_report_consumes_the_send_record_and_names_the_orchestrator(self, tmp_path):
        self._setup(tmp_path, [_typed("u1", "refactor the parser")])
        ts.record_sent_prompt(self.state, "sess", "refactor the parser")
        await self.drain()
        self.append_tail()
        await self.drain()
        await self.drain()
        [turn] = self.posted
        assert turn.prompt_origin == "orchestrator"
        assert turn.text == ts.render_delivery("", [], interrupted=True)
        assert ts.consume_sent_prompt(self.state, "sess", "refactor the parser") is False
        assert ("sess", "u1") in tools._reported_interrupts
