"""Tests for the JSONL transcript delivery core (design-09, MCP-15..19).

Fixtures mirror the real Claude Code schema verified 2026-06-09:
message lines (type user/assistant) with .uuid, .message.{role,content,stop_reason},
content blocks of type text/thinking/tool_use, and the
isSidechain/isCompactSummary/isVisibleInTranscriptOnly skip flags.
"""
from pathlib import Path

from aidc_mcp.transcript import (
    TERMINAL_PROMPT_NOTE,
    Turn,
    Watermark,
    consume_sent_prompt,
    delay_for_attempt,
    extract_completed_turns,
    human_prompt_text,
    load_watermark,
    objs_after_uuid,
    parse_jsonl,
    record_sent_prompt,
    render_delivery,
    resolve_active_transcript,
    save_watermark,
    sent_prompts_path,
    watermark_path,
)

# --- fixture builders --------------------------------------------------------

def _user(uuid, text):
    return {"type": "user", "uuid": uuid,
            "message": {"role": "user", "content": [{"type": "text", "text": text}]}}


def _assistant(uuid, blocks, stop, **extra):
    return {"type": "assistant", "uuid": uuid,
            "message": {"role": "assistant", "content": blocks, "stop_reason": stop}, **extra}


def _text(t):
    return {"type": "text", "text": t}


def _tool():
    return {"type": "tool_use", "id": "tu", "name": "Bash", "input": {}}


def _ask(question="Which should win?", options=(("New spec", "overwrite"),
                                                ("Keep disk", "leave it"))):
    return {"type": "tool_use", "id": "aq", "name": "AskUserQuestion",
            "input": {"questions": [{"question": question,
                                     "options": [{"label": lbl, "description": desc}
                                                 for lbl, desc in options]}]}}


def _exit_plan(plan="Step 1. do the thing"):
    return {"type": "tool_use", "id": "ep", "name": "ExitPlanMode",
            "input": {"plan": plan}}


def _tool_result(uuid="tr", content="ok"):
    return {"type": "user", "uuid": uuid,
            "message": {"role": "user", "content": [{"type": "tool_result", "content": content}]}}


def _thinking(t="hmm"):
    return {"type": "thinking", "thinking": t}


# --- parse_jsonl -------------------------------------------------------------

class TestParseJsonl:
    def test_parses_objects_skips_blanks(self):
        data = '{"a":1}\n\n  \n{"b":2}\n'
        assert parse_jsonl(data) == [{"a": 1}, {"b": 2}]

    def test_skips_malformed_and_partial_trailing_line(self):
        data = '{"ok":1}\n{"torn": "unterminated\n{"after":2}\n{"partial"'
        out = parse_jsonl(data)
        assert {"ok": 1} in out and {"after": 2} in out
        assert all("partial" not in o for o in out)

    def test_ignores_non_object_json(self):
        assert parse_jsonl('123\n"str"\n[1,2]\n{"keep":1}') == [{"keep": 1}]

    def test_survives_recursionerror_from_deeply_nested_line(self, monkeypatch):
        # A deeply-nested crafted line makes json.loads raise RecursionError, which
        # is NOT a ValueError — it must still be skipped, not crash the watcher.
        import aidc_mcp.transcript as t
        real = t.json.loads

        def loads(s):
            if s.startswith("["):
                raise RecursionError("too deep")
            return real(s)

        monkeypatch.setattr(t.json, "loads", loads)
        # the middle line raises RecursionError inside parse; neighbors survive.
        assert parse_jsonl('{"ok":1}\n[[[]]]\n{"after":2}') == [{"ok": 1}, {"after": 2}]


# --- extract_completed_turns -------------------------------------------------

class TestExtractTurns:
    def test_simple_single_turn(self):
        objs = [_user("u1", "hi"), _assistant("a1", [_text("hello")], "end_turn")]
        turns = extract_completed_turns(objs)
        assert turns == [Turn(terminal_uuid="a1", text="hello", prompts=("hi",))]

    def test_tool_use_lines_continue_turn_until_terminal(self):
        objs = [
            _user("u1", "do it"),
            _assistant("a1", [_text("working")], "tool_use"),
            {"type": "user", "uuid": "tr", "message": {"role": "user",
             "content": [{"type": "tool_result", "content": "ok"}]}},  # tool result (user role)
            _assistant("a2", [_text("done")], "end_turn"),
        ]
        turns = extract_completed_turns(objs)
        # Tool-result does NOT break the turn; intermediate + final text accumulate.
        assert turns == [Turn(terminal_uuid="a2", text="working\ndone", prompts=("do it",))]

    def test_tool_result_user_line_is_not_a_turn_boundary(self):
        # A bare tool_result (no text) must not start a new turn or be delivered.
        objs = [
            _user("u1", "go"),
            _assistant("a1", [_tool()], "tool_use"),
            {"type": "user", "uuid": "tr", "message": {"role": "user",
             "content": [{"type": "tool_result", "content": "data"}]}},
            _assistant("a2", [_text("final")], "end_turn"),
        ]
        assert extract_completed_turns(objs) == [Turn("a2", "final", prompts=("go",))]

    def test_stop_sequence_also_completes(self):
        objs = [_user("u1", "x"), _assistant("a1", [_text("y")], "stop_sequence")]
        assert extract_completed_turns(objs)[0].terminal_uuid == "a1"

    def test_null_stop_reason_not_complete(self):
        objs = [_user("u1", "x"), _assistant("a1", [_text("partial")], None)]
        assert extract_completed_turns(objs) == []

    def test_excludes_thinking_and_tool_use_blocks(self):
        objs = [_user("u1", "x"),
                _assistant("a1", [_thinking(), _text("answer"), _tool()], "end_turn")]
        assert extract_completed_turns(objs) == [Turn("a1", "answer", prompts=("x",))]

    def test_skips_sidechain(self):
        objs = [_user("u1", "x"),
                _assistant("side", [_text("subagent")], "end_turn", isSidechain=True),
                _assistant("a1", [_text("main")], "end_turn")]
        assert [t.terminal_uuid for t in extract_completed_turns(objs)] == ["a1"]

    def test_skips_compact_summary_and_visible_only(self):
        objs = [
            {"type": "user", "uuid": "s", "isCompactSummary": True,
             "isVisibleInTranscriptOnly": True,
             "message": {"role": "user", "content": [{"type": "text",
                         "text": "This session is being continued..."}]}},
            _user("u1", "real prompt"),
            _assistant("a1", [_text("real answer")], "end_turn"),
        ]
        assert extract_completed_turns(objs) == [Turn("a1", "real answer", prompts=("real prompt",))]

    def test_api_error_turn_marked_not_ok(self):
        objs = [_user("u1", "x"),
                _assistant("a1", [_text("rate limited")], None, isApiErrorMessage=True)]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1 and turns[0].ok is False and "rate limited" in turns[0].text

    def test_api_error_terminal_when_user_reprompts(self):
        # Real recorded shape: the error carries stop_reason "stop_sequence" and is
        # followed by a real user prompt (the human/orchestrator typed "try again").
        # Control genuinely returned to the user, so the error IS delivered ok=False.
        objs = [
            _user("u1", "do the thing"),
            _assistant("a1", [_text("API Error: 529 Overloaded")], "stop_sequence",
                       isApiErrorMessage=True),
            _user("u2", "try again"),
            _assistant("a2", [_text("done now")], "end_turn"),
        ]
        turns = extract_completed_turns(objs)
        assert [(t.terminal_uuid, t.text, t.ok) for t in turns] == [
            ("a1", "API Error: 529 Overloaded", False),
            ("a2", "done now", True),
        ]

    def test_api_error_superseded_by_retry_continuation(self):
        # The live-session shape: the API call fails mid-turn, Claude auto-retries
        # WITHOUT a user prompt, and the same turn continues to a real end_turn. The
        # error must NOT be delivered as its own completion — the successful answer
        # supersedes it and is delivered ok=True.
        objs = [
            _user("u1", "go"),
            _assistant("a1", [_text("API Error: 529 Overloaded")], "stop_sequence",
                       isApiErrorMessage=True),
            _assistant("a2", [_text("the real answer")], "end_turn"),
        ]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1
        assert turns[0].terminal_uuid == "a2"
        assert turns[0].text == "the real answer"
        assert turns[0].ok is True

    def test_api_error_preserves_pre_error_text_on_retry(self):
        # Text produced BEFORE the error is in-flight (stop_reason null/tool_use), so
        # the group has not reached a terminal. The old eager flush() dropped it. It
        # must ride along to whichever terminal wins — here the successful retry.
        objs = [
            _user("u1", "go"),
            _assistant("a1", [_text("partial work")], None),  # in flight, no terminal
            _assistant("a2", [_text("API Error: 529")], "stop_sequence",
                       isApiErrorMessage=True),
            _assistant("a3", [_text("finished work")], "end_turn"),
        ]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1
        assert turns[0].ok is True
        assert turns[0].text == "partial work\nfinished work"  # error text not folded in

    def test_api_error_terminal_carries_pre_error_text(self):
        # When the error IS terminal (session waiting for input), the pre-error text
        # is delivered WITH the error message, not discarded.
        objs = [
            _user("u1", "go"),
            _assistant("a1", [_text("partial work")], None),  # in flight
            _assistant("a2", [_text("API Error: 529")], "stop_sequence",
                       isApiErrorMessage=True),
            _user("u2", "try again"),
        ]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1
        assert turns[0].terminal_uuid == "a2"
        assert turns[0].ok is False
        assert turns[0].text == "partial work\nAPI Error: 529"

    def test_empty_tool_only_turn_emitted_with_empty_text(self):
        objs = [_user("u1", "x"), _assistant("a1", [_tool()], "end_turn")]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1 and turns[0].is_empty

    def test_two_turns_chained(self):
        objs = [_user("u1", "a"), _assistant("a1", [_text("ALPHA")], "end_turn"),
                _user("u2", "b"), _assistant("a2", [_text("BETA")], "end_turn")]
        assert [t.text for t in extract_completed_turns(objs)] == ["ALPHA", "BETA"]

    def test_coalesces_empty_then_real_end_turn_under_one_prompt(self):
        # The meltdown shape: one prompt yields an EMPTY end_turn (textlen 0)
        # immediately followed by the real answer in a second end_turn, with no
        # user line between. These must coalesce into ONE delivered turn — not two,
        # and not a premature empty "ready" signal.
        objs = [
            _user("u1", "deep dive please"),
            _assistant("empty1", [_thinking()], "end_turn"),         # empty: no text
            _assistant("real1", [_text("the real answer")], "end_turn"),
        ]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1
        assert turns[0].terminal_uuid == "real1"                     # last terminal
        assert turns[0].text == "the real answer"
        assert not turns[0].is_empty

    def test_coalesces_many_segments_then_splits_on_real_prompt(self):
        # Several end_turn segments under prompt 1 collapse to one turn; a real
        # user prompt starts a fresh turn.
        objs = [
            _user("u1", "go"),
            _assistant("s1", [_text("part one")], "end_turn"),
            _assistant("s2", [_tool()], "end_turn"),                 # empty segment
            _assistant("s3", [_text("part two")], "end_turn"),
            _user("u2", "next"),
            _assistant("s4", [_text("second answer")], "end_turn"),
        ]
        turns = extract_completed_turns(objs)
        assert [t.terminal_uuid for t in turns] == ["s3", "s4"]
        assert turns[0].text == "part one\npart two"
        assert turns[1].text == "second answer"

    # --- interactive-input tools (AskUserQuestion / ExitPlanMode) -------------
    # A turn ending on one of these blocks awaiting a HUMAN choice: its
    # stop_reason is "tool_use" and no tool_result ever comes on its own. It must
    # be delivered (rendered from the tool_use input) or an orchestrated session
    # deadlocks — the incident these tests pin down.

    def test_ask_user_question_terminal_is_delivered(self):
        # No user line after the ask: the transcript ends blocked on the question.
        objs = [_user("u1", "help"), _assistant("a1", [_ask()], "tool_use")]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1
        assert turns[0].terminal_uuid == "a1"
        assert not turns[0].is_empty
        assert "[Question] Which should win?" in turns[0].text
        assert "- New spec: overwrite" in turns[0].text
        assert "- Keep disk: leave it" in turns[0].text

    def test_ask_user_question_includes_preamble_text(self):
        objs = [_user("u1", "go"),
                _assistant("a1", [_text("Found a conflict."), _ask()], "tool_use")]
        turns = extract_completed_turns(objs)
        assert turns[0].text.startswith("Found a conflict.")
        assert "[Question]" in turns[0].text

    def test_ask_multiple_questions_all_rendered(self):
        # AskUserQuestion carries up to 4 questions in one call; every one must
        # render (a bug that emitted only the first would still "deliver a turn").
        multi = {"type": "tool_use", "id": "aq", "name": "AskUserQuestion",
                 "input": {"questions": [
                     {"question": "First?", "options": [{"label": "A", "description": "aa"}]},
                     {"question": "Second?", "options": [{"label": "B", "description": "bb"}]},
                     {"question": "Third?", "options": [{"label": "C", "description": "cc"}]},
                 ]}}
        objs = [_user("u1", "go"), _assistant("a1", [multi], "tool_use")]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1
        text = turns[0].text
        assert "[Question] First?" in text
        assert "[Question] Second?" in text
        assert "[Question] Third?" in text
        assert "- A: aa" in text and "- B: bb" in text and "- C: cc" in text

    def test_exit_plan_mode_terminal_is_delivered(self):
        objs = [_user("u1", "plan it"),
                _assistant("a1", [_exit_plan("Step 1. do the thing")], "tool_use")]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1 and turns[0].terminal_uuid == "a1"
        assert "[Plan ready for approval]" in turns[0].text
        assert "Step 1. do the thing" in turns[0].text

    def test_malformed_ask_still_delivers_non_empty_marker(self):
        # A blocking tool with an unusable payload must NOT fall through to an
        # empty (skipped) turn — that would re-open the deadlock.
        bad_ask = {"type": "tool_use", "id": "aq", "name": "AskUserQuestion",
                   "input": {"questions": []}}
        objs = [_user("u1", "x"), _assistant("a1", [bad_ask], "tool_use")]
        turns = extract_completed_turns(objs)
        assert len(turns) == 1 and not turns[0].is_empty

    def test_unhashable_fields_do_not_crash_the_watcher(self):
        # The transcript is written by yolo-mode Claude (attacker-influenced). An
        # unhashable value at any membership-tested field (type / tool name /
        # stop_reason) must be skipped, never raise — the watcher must never crash
        # on a crafted line (parse-layer contract). Each bad line below crashed a
        # different `in`/`not in` site before the str-gates were added.
        objs = [
            {"type": ["assistant"], "uuid": "bad-type",   # unhashable type
             "message": {"role": "assistant", "stop_reason": "end_turn",
                         "content": [_text("nope")]}},
            {"type": "assistant", "uuid": "bad-name",      # unhashable tool name
             "message": {"role": "assistant", "stop_reason": "tool_use",
                         "content": [{"type": "tool_use", "id": "e",
                                      "name": ["AskUserQuestion"], "input": {}}]}},
            {"type": "assistant", "uuid": "bad-stop",      # unhashable stop_reason
             "message": {"role": "assistant", "stop_reason": {"weird": 1},
                         "content": [_text("also nope")]}},
            {"type": "assistant", "uuid": "bad-text",      # non-str text -> would crash "".join
             "message": {"role": "assistant", "stop_reason": "tool_use",
                         "content": [{"type": "text", "text": 999}]}},
            _user("u1", "real"),
            _assistant("good", [_text("real answer")], "end_turn"),
        ]
        turns = extract_completed_turns(objs)  # must not raise
        assert [t.terminal_uuid for t in turns] == ["good"]
        assert turns[0].text == "real answer"

    def test_text_after_intermediate_terminal_not_carried_past_anchor(self):
        # An empty end_turn then a continuation whose text sits on a NON-terminal
        # (tool_use) line — settle can fire here during a long tool call. The flushed
        # turn's text must NOT include that post-terminal text (its anchor is the
        # earlier terminal, so resume would re-deliver it). It is delivered once,
        # with its own terminal, on the next poll.
        objs = [
            _user("u1", "go"),
            _assistant("empty1", [_thinking()], "end_turn"),                 # empty terminal
            _assistant("real1", [_text("Let me verify."), _tool()], "tool_use"),  # post-terminal, in flight
        ]
        turns = extract_completed_turns(objs)
        assert [t.terminal_uuid for t in turns] == ["empty1"]
        assert turns[0].is_empty  # committed text is empty, NOT "Let me verify."

        objs2 = objs + [
            {"type": "user", "uuid": "tr1", "message": {"role": "user",
             "content": [{"type": "tool_result", "content": "ok"}]}},
            _assistant("final1", [_text("Confirmed.")], "end_turn"),
        ]
        follow = extract_completed_turns(objs_after_uuid(objs2, "empty1"))
        assert [t.terminal_uuid for t in follow] == ["final1"]
        assert follow[0].text == "Let me verify.\nConfirmed."  # delivered once, in full

    def test_terminal_line_without_uuid_is_not_delivered(self):
        # An empty terminal_uuid can't anchor exactly-once resume: the drain loop
        # would persist last_delivered_uuid="" and objs_after_uuid would then replay
        # the whole file every poll (webhook flood). Such a turn must not be emitted.
        objs = [_user("u1", "x"),
                {"type": "assistant",  # no uuid
                 "message": {"role": "assistant", "stop_reason": "end_turn",
                             "content": [_text("no uuid here")]}}]
        assert extract_completed_turns(objs) == []

    def test_uuidless_interactive_block_not_delivered(self):
        # Same guard on the interactive path.
        objs = [_user("u1", "x"),
                {"type": "assistant",  # no uuid
                 "message": {"role": "assistant", "stop_reason": "tool_use",
                             "content": [_ask()]}}]
        assert extract_completed_turns(objs) == []

    def test_explicit_null_uuid_is_not_an_anchor(self):
        # A JSON null uuid (key present, value None) must be treated as "no anchor"
        # just like a missing one — str(None)=="None" is truthy and would otherwise
        # slip through as terminal_uuid="None".
        objs = [_user("u1", "x"),
                {"type": "assistant", "uuid": None,
                 "message": {"role": "assistant", "stop_reason": "end_turn",
                             "content": [_text("null uuid")]}}]
        assert extract_completed_turns(objs) == []

    def test_ask_flushed_as_own_turn_not_coalesced_with_continuation(self):
        # After an ask, an in-flight continuation must NOT be folded into the ask's
        # turn — otherwise its text rides under the ask anchor and is re-delivered
        # when resume reads past the ask (double send). The ask is its own turn.
        objs = [
            _user("u1", "go"),
            _assistant("ask1", [_ask()], "tool_use"),
            {"type": "user", "uuid": "tr1", "message": {"role": "user",
             "content": [{"type": "tool_result", "content": "A"}]}},
            _assistant("a2", [_text("Applying A.")], "tool_use"),  # continuation, in flight
        ]
        turns = extract_completed_turns(objs)
        assert [t.terminal_uuid for t in turns] == ["ask1"]
        assert "[Question]" in turns[0].text
        assert "Applying A." not in turns[0].text  # continuation not coalesced in

    def test_plain_tool_use_turn_is_not_delivered_while_in_flight(self):
        # Regression guard: a Bash (non-interactive) tool_use with nothing after is
        # a turn still in flight — it must NOT be treated as complete.
        objs = [_user("u1", "run it"), _assistant("a1", [_tool()], "tool_use")]
        assert extract_completed_turns(objs) == []

    def test_answered_question_delivered_once_via_line_anchored_resume(self):
        # Cycle 1 delivers the question; cycle 2 (after the human answer +
        # continuation) resumes past the ask line and delivers ONLY the follow-up.
        objs = [
            _user("u1", "go"),
            _assistant("ask1", [_ask()], "tool_use"),          # delivered cycle 1
            _tool_result("tr1", "Your questions have been answered: New spec"),
            _assistant("cont1", [_text("Applying the new spec.")], "end_turn"),
        ]
        # cycle 1: only the ask has completed at the point it blocked
        first = extract_completed_turns(objs[:2])
        assert [t.terminal_uuid for t in first] == ["ask1"]
        # cycle 2: resume strictly after the delivered ask line
        suffix = objs_after_uuid(objs, "ask1")
        follow = extract_completed_turns(suffix)
        assert [t.terminal_uuid for t in follow] == ["cont1"]
        assert follow[0].text == "Applying the new spec."
        assert "[Question]" not in follow[0].text  # question not re-delivered


# --- objs_after_uuid (line-anchored resume, stable under coalescing) ---------

class TestObjsAfterUuid:
    objs = [_user("u1", "a"), _assistant("a1", [_text("one")], "end_turn"),
            _user("u2", "b"), _assistant("a2", [_text("two")], "end_turn")]

    def test_none_anchor_returns_all(self):
        assert objs_after_uuid(self.objs, None) == self.objs

    def test_empty_anchor_returns_all(self):
        assert objs_after_uuid(self.objs, "") == self.objs

    def test_returns_lines_after_the_anchor_line(self):
        after = objs_after_uuid(self.objs, "a1")
        assert [o.get("uuid") for o in after] == ["u2", "a2"]

    def test_anchor_at_last_line_returns_empty(self):
        assert objs_after_uuid(self.objs, "a2") == []

    def test_absent_anchor_returns_none_not_all(self):
        # The crux of the no-replay guard: a missing anchor line is a torn read,
        # NOT a signal to redeliver everything.
        assert objs_after_uuid(self.objs, "from-old-file") is None

    def test_anchor_on_absorbed_terminal_still_resolves(self):
        # An end_turn that was a terminal when delivered, later absorbed into a
        # bigger coalesced group, is still a real line -> resume stays stable.
        objs = [_user("u1", "a"),
                _assistant("a1", [_text("first")], "end_turn"),   # delivered, then...
                _assistant("a2", [_text("more")], "end_turn")]    # ...absorbs a1's group
        after = objs_after_uuid(objs, "a1")
        assert [o.get("uuid") for o in after] == ["a2"]           # continuation only


# --- retry schedule ----------------------------------------------------------

class TestBackoff:
    def test_schedule_shape(self):
        assert [delay_for_attempt(n) for n in range(8)] == [0, 2, 4, 8, 16, 32, 60, 60]

    def test_cap_respected(self):
        assert delay_for_attempt(20) == 60.0


# --- watermark persistence ---------------------------------------------------

class TestWatermark:
    def test_roundtrip(self, tmp_path):
        m = Watermark("sess", "conv", session_id="sid", byte_offset=42,
                      last_delivered_uuid="a9")
        save_watermark(tmp_path, m)
        loaded = load_watermark(tmp_path, "sess", "conv")
        assert loaded.session_id == "sid"
        assert loaded.byte_offset == 42
        assert loaded.last_delivered_uuid == "a9"
        assert loaded.updated_at  # stamped on save

    def test_missing_returns_zero_mark(self, tmp_path):
        m = load_watermark(tmp_path, "sess", "conv")
        assert m.byte_offset == 0 and m.last_delivered_uuid == "" and m.session_id == ""

    def test_corrupt_file_returns_zero_mark(self, tmp_path):
        p = watermark_path(tmp_path, "sess", "conv")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("{not json", encoding="utf-8")
        m = load_watermark(tmp_path, "sess", "conv")
        assert m.byte_offset == 0

    def test_save_is_atomic_no_leftover_temp(self, tmp_path):
        save_watermark(tmp_path, Watermark("s", "c", byte_offset=1))
        assert not list(tmp_path.glob("*.new"))

    def test_watermark_exists(self, tmp_path):
        from aidc_mcp.transcript import watermark_exists
        assert watermark_exists(tmp_path, "s", "c") is False
        save_watermark(tmp_path, Watermark("s", "c", byte_offset=1))
        assert watermark_exists(tmp_path, "s", "c") is True

    def test_slug_sanitizes_path_separators(self, tmp_path):
        p = watermark_path(tmp_path, "a/b", "c:d")
        assert "/" not in p.name and p.name == "a_b__c_d.json"

    def test_path_traversal_in_ids_is_neutralized(self, tmp_path):
        # ../ in ids must not escape base_dir.
        p = watermark_path(tmp_path, "..", "../etc")
        assert p.parent == Path(tmp_path)


# --- delivery ledger (structural exactly-once at the POST boundary) ----------

class TestDeliveryLedger:
    def test_fingerprint_is_stable_and_content_dependent(self):
        from aidc_mcp.transcript import content_fingerprint
        assert content_fingerprint("hello") == content_fingerprint("hello")
        assert content_fingerprint("hello") != content_fingerprint("hell0")
        # A known sha256 anchor so a refactor can't silently change the scheme.
        assert content_fingerprint("") == (
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )

    def test_missing_ledger_is_empty_set(self, tmp_path):
        from aidc_mcp.transcript import load_delivered
        assert load_delivered(tmp_path, "sess", "conv") == set()

    def test_record_then_load_roundtrips(self, tmp_path):
        from aidc_mcp.transcript import load_delivered, record_delivered
        record_delivered(tmp_path, "sess", "conv", "fp1")
        record_delivered(tmp_path, "sess", "conv", "fp2")
        record_delivered(tmp_path, "sess", "conv", "fp1")  # dup append is harmless
        assert load_delivered(tmp_path, "sess", "conv") == {"fp1", "fp2"}

    def test_ledger_is_per_conversation(self, tmp_path):
        from aidc_mcp.transcript import load_delivered, record_delivered
        record_delivered(tmp_path, "sess", "convA", "fp1")
        assert load_delivered(tmp_path, "sess", "convB") == set()

    def test_torn_final_line_is_inert(self, tmp_path):
        """A crash mid-append can leave a partial last line; it must not corrupt
        the load or cause a false match — it is just a value no fingerprint equals."""
        from aidc_mcp.transcript import ledger_path, load_delivered
        p = ledger_path(tmp_path, "sess", "conv")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("fpcomplete\nfppar", encoding="utf-8")  # no trailing newline
        assert load_delivered(tmp_path, "sess", "conv") == {"fpcomplete", "fppar"}

    def test_ledger_path_neutralizes_traversal(self, tmp_path):
        from aidc_mcp.transcript import ledger_path
        p = ledger_path(tmp_path, "..", "../etc")
        assert p.parent == Path(tmp_path) and p.name.endswith(".delivered")


# --- active transcript resolution --------------------------------------------

class TestResolveActive:
    def test_picks_newest(self, tmp_path):
        import os
        old = tmp_path / "old.jsonl"; old.write_text("{}")
        new = tmp_path / "new.jsonl"; new.write_text("{}")
        os.utime(old, (1000, 1000)); os.utime(new, (2000, 2000))
        assert resolve_active_transcript(tmp_path) == new

    def test_excludes_subagents_subdir(self, tmp_path):
        main = tmp_path / "main.jsonl"; main.write_text("{}")
        sub = tmp_path / "subagents"; sub.mkdir()
        (sub / "agent.jsonl").write_text("{}")
        assert resolve_active_transcript(tmp_path) == main

    def test_none_when_empty_or_absent(self, tmp_path):
        assert resolve_active_transcript(tmp_path) is None
        assert resolve_active_transcript(tmp_path / "nope") is None

    def test_skips_symlinks(self, tmp_path):
        # A planted symlink (adversarial container) must never be selected/read.
        secret = tmp_path / "secret.txt"; secret.write_text("/etc/passwd-ish")
        link = tmp_path / "evil.jsonl"; link.symlink_to(secret)
        assert resolve_active_transcript(tmp_path) is None  # only a symlink present
        real = tmp_path / "real.jsonl"; real.write_text("{}")
        assert resolve_active_transcript(tmp_path) == real  # picks the regular file


# --- terminal-typed prompt attribution ----------------------------------------
# Shapes below are copied from a live aidc transcript (2026-09-11): a prompt the
# MCP pasted and one a person typed are IDENTICAL on the wire (origin.kind human,
# promptSource typed), so what human_prompt_text excludes is everything Claude
# Code writes on the user's behalf that nobody typed.

def _typed(uuid, text, **extra):
    return {"type": "user", "uuid": uuid, "promptSource": "typed",
            "origin": {"kind": "human"}, "entrypoint": "cli",
            "message": {"role": "user", "content": text}, **extra}


class TestHumanPromptText:
    def test_typed_prompt_is_the_text(self):
        assert human_prompt_text(_typed("u1", "  next  ")) == "next"

    def test_absent_provenance_fields_count_as_typed(self):
        # Older transcripts / fixtures carry no promptSource or origin.
        assert human_prompt_text(_user("u1", "plain")) == "plain"

    def test_meta_lines_are_not_typed(self):
        hook = _typed("u1", "Stop hook feedback:\n[...]", isMeta=True)
        cont = {"type": "user", "uuid": "u2", "isMeta": True,
                "message": {"role": "user",
                            "content": [{"type": "text", "text": "Continue from where you left off."}]}}
        assert human_prompt_text(hook) == ""
        assert human_prompt_text(cont) == ""

    def test_system_sourced_prompts_are_not_typed(self):
        note = {"type": "user", "uuid": "u1", "promptSource": "system",
                "origin": {"kind": "task-notification"},
                "message": {"role": "user", "content": "<task-notification>...</task-notification>"}}
        assert human_prompt_text(note) == ""
        # Either marker alone is enough.
        assert human_prompt_text(_typed("u2", "x", promptSource="system")) == ""
        assert human_prompt_text(_typed("u3", "x", origin={"kind": "task-notification"})) == ""

    def test_local_command_output_is_not_typed(self):
        out = _user("u1", "<local-command-stdout>Login successful</local-command-stdout>")
        caveat = _user("u2", "<local-command-caveat>Caveat: ...</local-command-caveat>")
        assert human_prompt_text(out) == ""
        assert human_prompt_text(caveat) == ""

    def test_interrupt_marker_is_not_typed(self):
        obj = {"type": "user", "uuid": "u1", "interruptedMessageId": "msg_1",
               "message": {"role": "user",
                           "content": [{"type": "text", "text": "[Request interrupted by user]"}]}}
        assert human_prompt_text(obj) == ""
        # The tool-use variant carries no interruptedMessageId; the text alone decides.
        bare = _user("u2", "[Request interrupted by user for tool use]")
        assert human_prompt_text(bare) == ""

    def test_bash_mode_lines_are_not_typed(self):
        """`!` bash mode: the input and its output are wrapped and provenance-less,
        and the output can hold anything the shell printed (an auth code, say)."""
        assert human_prompt_text(_user("u1", "<bash-input>gh auth login</bash-input>")) == ""
        assert human_prompt_text(_user("u2", "<bash-stdout>! First copy your code: XYZ</bash-stdout>")) == ""

    def test_any_unknown_wrapper_tag_is_not_typed(self):
        # Fail closed on wrappers not seen yet: the only tagged line a person
        # types is a slash command.
        assert human_prompt_text(_user("u1", "<some-future-wrapper>x</some-future-wrapper>")) == ""
        assert human_prompt_text(_typed("u2", "<ide_selection>foo</ide_selection>")) == ""

    def test_command_message_first_wrapper_still_renders_the_command(self):
        raw = ("<command-message>run</command-message>"
               "<command-name>/run</command-name><command-args>the app</command-args>")
        assert human_prompt_text(_user("u1", raw)) == "/run the app"

    def test_prose_mentioning_a_tag_mid_sentence_is_typed(self):
        assert human_prompt_text(_typed("u1", "the <div> is misaligned")) == "the <div> is misaligned"

    def test_slash_command_rendered_compactly(self):
        raw = ("<command-name>/goal</command-name>\n            "
               "<command-message>goal</command-message>\n            "
               "<command-args>finish the build plan</command-args>")
        assert human_prompt_text(_user("u1", raw)) == "/goal finish the build plan"
        bare = "<command-name>/clear</command-name><command-message>clear</command-message><command-args></command-args>"
        assert human_prompt_text(_user("u2", bare)) == "/clear"

    def test_non_text_and_malformed_lines_are_empty(self):
        assert human_prompt_text({"type": "user", "uuid": "u1", "message": "junk"}) == ""
        assert human_prompt_text(_tool_result()) == ""


class TestTurnPrompts:
    def test_each_turn_carries_its_own_prompt(self):
        objs = [_typed("u1", "first"), _assistant("a1", [_text("r1")], "end_turn"),
                _typed("u2", "second"), _assistant("a2", [_text("r2")], "end_turn")]
        assert [t.prompts for t in extract_completed_turns(objs)] == [("first",), ("second",)]

    def test_consecutive_prompts_accumulate_onto_the_next_turn(self):
        """An auto-continue (meta) then the person's ask, with no assistant line
        between: the ask must not be lost to the boundary flush of the meta line."""
        cont = {"type": "user", "uuid": "u1", "isMeta": True,
                "message": {"role": "user",
                            "content": [{"type": "text", "text": "Continue from where you left off."}]}}
        objs = [cont, _typed("u2", "please do as asked above"),
                _assistant("a1", [_text("ok")], "end_turn")]
        assert extract_completed_turns(objs) == [
            Turn("a1", "ok", prompts=("please do as asked above",)),
        ]

    def test_two_typed_prompts_both_kept(self):
        objs = [_typed("u1", "/login"), _typed("u2", "please continue"),
                _assistant("a1", [_text("ok")], "end_turn")]
        assert extract_completed_turns(objs)[0].prompts == ("/login", "please continue")

    def test_hook_feedback_after_the_prompt_is_excluded(self):
        objs = [_typed("u1", "ship it"),
                _typed("u2", "Stop hook feedback: BLOCKED", isMeta=True),
                _assistant("a1", [_text("ok")], "end_turn")]
        assert extract_completed_turns(objs)[0].prompts == ("ship it",)

    def test_tool_result_between_does_not_reset_prompts(self):
        objs = [_typed("u1", "go"), _assistant("a1", [_tool()], "tool_use"),
                _tool_result(), _assistant("a2", [_text("done")], "end_turn")]
        assert extract_completed_turns(objs)[0].prompts == ("go",)

    def test_continuation_without_a_prompt_has_none(self):
        # A read window that starts mid-conversation (resume after a delivered
        # terminal): the next segment has no prompt of its own.
        objs = [_assistant("a2", [_text("more")], "end_turn")]
        assert extract_completed_turns(objs) == [Turn("a2", "more")]

    def test_prompt_of_a_system_sourced_turn_is_empty(self):
        note = {"type": "user", "uuid": "u1", "promptSource": "system",
                "origin": {"kind": "task-notification"},
                "message": {"role": "user", "content": "<task-notification>x</task-notification>"}}
        objs = [note, _assistant("a1", [_text("noted")], "end_turn")]
        assert extract_completed_turns(objs)[0].prompts == ()

    def test_ask_turn_carries_prompt_and_continuation_does_not(self):
        objs = [_typed("u1", "decide"), _assistant("a1", [_ask()], "tool_use"),
                _tool_result("tr", "A"), _assistant("a2", [_text("chose A")], "end_turn")]
        turns = extract_completed_turns(objs)
        assert [t.prompts for t in turns] == [("decide",), ()]


class TestSentPromptRecord:
    def test_record_then_consume_once(self, tmp_path):
        record_sent_prompt(tmp_path, "s", "fix the test")
        assert consume_sent_prompt(tmp_path, "s", "fix the test") is True
        assert consume_sent_prompt(tmp_path, "s", "fix the test") is False  # consumed

    def test_unrecorded_prompt_does_not_match(self, tmp_path):
        assert consume_sent_prompt(tmp_path, "s", "next") is False
        record_sent_prompt(tmp_path, "s", "something else")
        assert consume_sent_prompt(tmp_path, "s", "next") is False

    def test_same_words_sent_twice_match_twice_not_thrice(self, tmp_path):
        record_sent_prompt(tmp_path, "s", "continue")
        record_sent_prompt(tmp_path, "s", "continue")
        assert consume_sent_prompt(tmp_path, "s", "continue")
        assert consume_sent_prompt(tmp_path, "s", "continue")
        assert not consume_sent_prompt(tmp_path, "s", "continue")

    def test_whitespace_differences_still_match(self, tmp_path):
        # session_send folds newlines to spaces; Claude Code trims. Nothing else.
        record_sent_prompt(tmp_path, "s", "line one\nline two  ")
        assert consume_sent_prompt(tmp_path, "s", "line one line two") is True

    def test_is_per_session(self, tmp_path):
        record_sent_prompt(tmp_path, "a", "hi")
        assert consume_sent_prompt(tmp_path, "b", "hi") is False
        assert consume_sent_prompt(tmp_path, "a", "hi") is True

    def test_entries_expire(self, tmp_path):
        record_sent_prompt(tmp_path, "s", "old", now_fn=lambda: 1000.0)
        late = 1000.0 + 24 * 3600 + 1
        assert consume_sent_prompt(tmp_path, "s", "old", now_fn=lambda: late) is False

    def test_remaining_counts_live_entries(self, tmp_path):
        from aidc_mcp.transcript import sent_prompts_remaining
        assert sent_prompts_remaining(tmp_path, "s") == 0
        record_sent_prompt(tmp_path, "s", "a", now_fn=lambda: 1000.0)
        record_sent_prompt(tmp_path, "s", "b", now_fn=lambda: 1000.0)
        assert sent_prompts_remaining(tmp_path, "s", now_fn=lambda: 1001.0) == 2
        consume_sent_prompt(tmp_path, "s", "a", now_fn=lambda: 1001.0)
        assert sent_prompts_remaining(tmp_path, "s", now_fn=lambda: 1001.0) == 1
        assert sent_prompts_remaining(tmp_path, "s", now_fn=lambda: 1000.0 + 24 * 3600 + 1) == 0

    def test_bounded_by_count_oldest_dropped(self, tmp_path):
        for i in range(205):
            record_sent_prompt(tmp_path, "s", f"p{i}")
        assert consume_sent_prompt(tmp_path, "s", "p0") is False    # evicted
        assert consume_sent_prompt(tmp_path, "s", "p204") is True   # newest kept

    def test_corrupt_file_is_an_empty_record(self, tmp_path):
        sent_prompts_path(tmp_path, "s").parent.mkdir(parents=True, exist_ok=True)
        sent_prompts_path(tmp_path, "s").write_text("{not json")
        assert consume_sent_prompt(tmp_path, "s", "x") is False
        record_sent_prompt(tmp_path, "s", "x")   # recovers by rewriting
        assert consume_sent_prompt(tmp_path, "s", "x") is True

    def test_path_neutralizes_traversal(self, tmp_path):
        p = sent_prompts_path(tmp_path, "../../etc/passwd")
        assert p.parent == Path(tmp_path) and p.name.endswith(".sent-prompts.json")

    def test_record_is_atomic_no_leftover_temp(self, tmp_path):
        record_sent_prompt(tmp_path, "s", "x")
        assert not list(tmp_path.glob("*.new"))


class TestRenderDelivery:
    def test_no_terminal_prompts_is_the_bare_reply(self):
        assert render_delivery("reply", []) == "reply"

    def test_terminal_prompt_is_prepended_under_the_note(self):
        out = render_delivery("the reply", ["what is X?"])
        assert out.startswith(TERMINAL_PROMPT_NOTE + "\nwhat is X?")
        assert out.endswith("\n\n---\n\nthe reply")

    def test_multiple_prompts_joined(self):
        out = render_delivery("r", ["/login", " please continue "])
        assert "/login\n\nplease continue\n\n---" in out
