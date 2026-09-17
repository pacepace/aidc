"""Tests for the tmux screen classifier (design-10 S2).

Fixtures under fixtures/screens/ are real `capture-pane -p -e` captures of Claude
Code 2.1.270 / 2.1.274 in an aidc dev container, with paths sanitized.
"""
from pathlib import Path

import pytest

from aidc_mcp.screen import (
    EMPTY,
    HAS_TEXT,
    NOT_AT_PROMPT,
    UNRECOGNIZED,
    ScreenState,
    classify,
    same_text,
)

SCREENS = Path(__file__).parent / "fixtures" / "screens"


def _screen(name):
    return (SCREENS / f"claude-2.1.27x-{name}.ansi").read_text()


@pytest.mark.parametrize("name, expected", [
    ("idle-empty", ScreenState(EMPTY, working=False)),
    ("idle-after-pushbacks", ScreenState(EMPTY, working=False)),
    ("typed-unsent", ScreenState(HAS_TEXT, working=False)),
    ("typed-multiline", ScreenState(HAS_TEXT, working=False)),
    ("busy-tool-empty-box", ScreenState(EMPTY, working=True)),
    # The dim "Press up to edit queued messages" placeholder is not typed text.
    ("busy-with-queued-message", ScreenState(EMPTY, working=True)),
    # An Esc before Claude wrote anything puts the prompt back in the box.
    ("esc-before-output-prompt-restored", ScreenState(HAS_TEXT, working=False)),
    ("esc-before-output-sent-prompt-restored", ScreenState(HAS_TEXT, working=False)),
    ("trust-folder", ScreenState(NOT_AT_PROMPT, working=False)),
    # No box and no known dialog hint. (The send path reports a shell as "Claude not
    # running" before it ever reads the screen.)
    ("shell-after-exit", ScreenState(UNRECOGNIZED, working=False)),
])
def test_real_captures(name, expected):
    assert classify(_screen(name)) == expected


@pytest.mark.parametrize("name, typed", [
    ("typed-unsent", None),   # checked only for being non-empty below
    ("typed-multiline", "line one\nline two"),
    ("esc-before-output-prompt-restored",
     "Write a 600-word essay about lighthouses. Do not use any tools."),
    # A prompt the MCP pasted, restored by an Esc 1 s later (joint test, 2026-09-17).
    ("esc-before-output-sent-prompt-restored",
     "Think carefully, then write a 300-word explanation of how TCP slow start works."),
])
def test_typed_text_is_read_from_the_box(name, typed):
    state = classify(_screen(name))
    assert state.typed if typed is None else state.typed == typed


@pytest.mark.parametrize("name", ["idle-empty", "busy-with-queued-message", "trust-folder"])
def test_no_typed_text_without_text_in_the_box(name):
    assert classify(_screen(name)).typed == ""


def test_same_text_ignores_wrapping_and_indent():
    assert same_text("Think carefully, then write\n  a 300-word explanation",
                     "Think carefully, then write a 300-word explanation")
    assert same_text("line one\nline two", "line one line two")
    assert not same_text("reply ONE", "reply TWO")


RULE = "─" * 60


def _box(row, status="  ⏵⏵ bypass permissions on (shift+tab to cycle)", extra_rows=()):
    return "\n".join(["some reply text", "", RULE, row, *extra_rows, RULE, status, ""])


def test_startup_placeholder_is_empty():
    """Measured right after launch: `❯\\xa0` then dim `Try "refactor <filepath>"`."""
    row = '\x1b[39m❯\xa0\x1b[2mTry "refactor <filepath>"\x1b[0m'
    assert classify(_box(row)).input_box == EMPTY


def test_dim_is_cleared_by_reset_so_later_typed_text_counts():
    row = '\x1b[39m❯\xa0\x1b[2mhint\x1b[0mtyped'
    assert classify(_box(row)).input_box == HAS_TEXT


def test_dim_cleared_by_sgr_22():
    row = '❯\xa0\x1b[2mhint\x1b[22mtyped'
    assert classify(_box(row)).input_box == HAS_TEXT


def test_whitespace_only_is_empty():
    assert classify(_box("❯\xa0   ")).input_box == EMPTY


def test_continuation_row_with_text_counts():
    assert classify(_box("❯\xa0", extra_rows=["  second line"])).input_box == HAS_TEXT


def test_scrollback_prompt_style_row_is_not_the_box():
    """Earlier prompts are drawn `❯ ` with a normal space on a background colour;
    a box whose first row looks like that is not Claude's live input box."""
    row = "\x1b[38;5;239m\x1b[48;5;237m❯ \x1b[38;5;231mold prompt\x1b[39m"
    assert classify(_box(row)).input_box == UNRECOGNIZED


def test_working_is_read_from_the_status_row_only():
    status = "  ⏵⏵ bypass permissions on · esc to interrupt · ← for agents"
    assert classify(_box("❯\xa0", status=status)).working is True
    # The words appearing in the conversation above the box do not count.
    text = "\n".join(["press esc to interrupt it", RULE, "❯\xa0", RULE, "  ⏵⏵ bypass", ""])
    assert classify(text).working is False


def test_rules_far_above_the_bottom_are_not_the_box():
    lines = [RULE, "❯\xa0", RULE] + [f"shell output {i}" for i in range(10)]
    assert classify("\n".join(lines)).input_box == UNRECOGNIZED


def test_garbage_and_empty_fail_closed():
    assert classify("").input_box == UNRECOGNIZED
    assert classify("\x1b[31mhello\x1b[0m\n\x1b]0;title\x07world").input_box == UNRECOGNIZED
    assert classify("\x1b").input_box == UNRECOGNIZED


@pytest.mark.parametrize("colour", ["38;2;2;2;2", "38;5;2", "48;5;2", "38;2;0;2;0;1", "58;5;2"])
def test_extended_colour_values_are_not_the_dim_attribute(colour):
    """Under truecolor or 256-colour themes, a `2` inside a colour spec must not turn
    typed text into 'placeholder' and let a prompt be pasted on top of it."""
    row = f"❯\xa0\x1b[{colour}mtyped by a person\x1b[0m"
    assert classify(_box(row)).input_box == HAS_TEXT


def test_dim_inside_a_combined_sgr_still_counts():
    row = "❯\xa0\x1b[38;5;246;2mTry something\x1b[0m"
    assert classify(_box(row)).input_box == EMPTY
