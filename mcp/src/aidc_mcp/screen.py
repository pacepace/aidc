"""Reading Claude Code's tmux screen for the few things its transcript cannot show.

The transcript decides whether Claude is working (design-10 S1). The screen is read
only for:
  - unsent text in Claude's input box (the transcript records a prompt only once it
    is sent), so the MCP never pastes on top of what a person is typing;
  - whether Claude is at its input prompt at all (a startup, login or trust screen, or
    a layout this module does not recognize, has no input box);
  - whether the status row says Claude is working (`esc to interrupt`), and the text in
    the input box, which are consulted only when the transcript shows a turn in
    progress that has gone quiet: an Esc before Claude writes anything leaves no marker
    in the transcript, but Claude Code puts the prompt back in the box.

Layout measured on Claude Code 2.1.270, 2.1.274 and 2.1.300
(docs/design-10-turn-state-and-sending.md): the input box is the region between the
last two full-width `─` rules (the top one may carry the session's name, measured on
2.1.284), its first row starts with `❯` and a no-break space, placeholder text is drawn
dim (SGR 2), and the status row sits right below the second rule; from 2.1.300 a list of
running background agents may follow the status rows, one of its rows possibly under the
pointer. Everything here fails closed: a screen
without the input box is "not at prompt" (a known dialog) or "unrecognized", and both
hold prompts rather than typing blind.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

EMPTY = "empty"
HAS_TEXT = "has_text"
NOT_AT_PROMPT = "not_at_prompt"   # a recognizable menu or dialog (trust, login) instead of the box
UNRECOGNIZED = "unrecognized"     # neither the input box nor a known dialog

_BOX_GLYPH = "❯\xa0"
_RULE_CHAR = "─"
_RULE_MIN_LEN = 20
_WORKING_TEXT = "esc to interrupt"
# Footer hints on Claude Code's selection screens (the folder-trust prompt measured on
# 2.1.270). A screen without the input box that shows one of these is a dialog waiting
# for a person; one that shows neither is a layout this module does not know.
_DIALOG_HINTS = ("Enter to confirm", "Esc to cancel")
# The live box's second rule is the last rule on screen, with only the status row(s)
# below it. More trailing rows than this means the rules belong to something else.
_MAX_ROWS_BELOW_BOX = 4
# Claude Code 2.1.300 lists background agents under the status rows while any run: a
# blank row, then one row per agent (`  ● main`, `  ◯ general-purpose  <activity>`).
# The list grows with the agents, so it is set aside before the rows below the box
# are counted. Only the glyphs measured are accepted; another one fails closed.
# The row under the mouse, or the one selected from the keyboard (`←`, `↓`), is drawn
# with the pointer `❯ ` (a plain space, unlike the box's `❯` and no-break space) in
# place of the indent. Only a keyboard selection also swaps the permission-mode status
# row for the list's key hints (measured on Claude Code 2.1.304, 2026-10-22). While the
# list has the keyboard, a burst of several characters still goes to the input box, but
# a single one is a list key: `x` stopped the selected agent.
_POINTER = "❯ "
_AGENT_ROW_RE = re.compile(f"(  |{_POINTER})[●◯] \\S")
_LIST_KEY_HINTS = ("↑/↓ to select", "Enter to view")

_RULE_RE = re.compile(f"({_RULE_CHAR}+)(?: [^{_RULE_CHAR}]+ ({_RULE_CHAR}+))?")
_SGR_RE = re.compile(r"\x1b\[([0-9;]*)m")
_OTHER_ESCAPE_RE = re.compile(r"\x1b(?:\[[\x20-\x3f]*[\x40-\x7e]|\][^\x07\x1b]*(?:\x07|\x1b\\)|.)")


@dataclass(frozen=True)
class ScreenState:
    input_box: str   # EMPTY, HAS_TEXT, NOT_AT_PROMPT or UNRECOGNIZED
    working: bool    # the status row shows `esc to interrupt`
    # The text in the input box when it is HAS_TEXT: the non-dim characters, rows
    # joined with newlines, continuation indent and trailing padding removed. How
    # Claude Code wraps a long line is not preserved, so compare it with
    # same_text(), which ignores whitespace.
    typed: str = field(default="", compare=False)
    # A row of the background-agent list carries the pointer: the mouse rests on it,
    # or the keyboard selected it (then list_focused is set too). A paste is
    # confirmed in the box before it is submitted while the pointer shows.
    agent_pointed: bool = field(default=False, compare=False)
    # The background-agent list has the keyboard: its key hints replace the status
    # row. Keys typed now are list commands, so nothing is pasted.
    list_focused: bool = field(default=False, compare=False)


def same_text(a: str, b: str) -> bool:
    """Whether two texts match ignoring all whitespace: the input box wraps and
    indents what was typed, and a pasted prompt had its newlines flattened."""
    return "".join(a.split()) == "".join(b.split())


def _cells(line: str, dim: bool) -> tuple[list[tuple[str, bool]], bool]:
    """Split one captured line into (char, drawn-dim) pairs, carrying SGR state.

    Only intensity matters here: SGR 2 turns dim on; 0, 22 or an empty parameter
    list turns it off. Colour changes (e.g. 39) leave it alone, which is exactly how
    Claude Code draws the queued-message placeholder (`\\x1b[2m\\x1b[39m…`).
    """
    out: list[tuple[str, bool]] = []
    i = 0
    while i < len(line):
        if line[i] == "\x1b":
            m = _SGR_RE.match(line, i)
            if m:
                params = m.group(1).split(";") if m.group(1) else ["0"]
                k = 0
                while k < len(params):
                    p = params[k]
                    if p in ("38", "48", "58"):
                        # Extended colour: 5;N or 2;R;G;B. Its numbers are colour
                        # values, not attributes (a `2` there is not dim).
                        mode = params[k + 1] if k + 1 < len(params) else ""
                        k += 3 if mode == "5" else 5 if mode == "2" else 2
                        continue
                    if p in ("", "0", "22"):
                        dim = False
                    elif p == "2":
                        dim = True
                    k += 1
                i = m.end()
                continue
            other = _OTHER_ESCAPE_RE.match(line, i)
            i = other.end() if other else i + 1
            continue
        out.append((line[i], dim))
        i += 1
    return out, dim


def _is_rule(text: str) -> bool:
    """A full-width `─` rule, which may carry one label set off by spaces: Claude Code
    2.1.284 draws a named session's name into the box's top rule (`──── metallm ─`)."""
    m = _RULE_RE.fullmatch(text.strip())
    return m is not None and len(m.group(1)) + len(m.group(2) or "") >= _RULE_MIN_LEN


def _agent_list_start(plain: list[str]) -> int:
    """Where the background-agent list under the status rows begins (its blank
    separator row), or len(plain) when the screen does not end with one."""
    start = len(plain)
    while start > 0 and _AGENT_ROW_RE.match(plain[start - 1]):
        start -= 1
    if start == len(plain) or start == 0 or plain[start - 1].strip():
        return len(plain)
    return start - 1


def classify(ansi: str) -> ScreenState:
    """Classify a `tmux capture-pane -p -e -J` capture of the claude window."""
    rows: list[list[tuple[str, bool]]] = []
    dim = False
    for line in ansi.split("\n"):
        cells, dim = _cells(line, dim)
        rows.append(cells)
    plain = ["".join(c for c, _ in r) for r in rows]
    while plain and not plain[-1].strip():
        plain.pop()
        rows.pop()

    rules = [i for i, text in enumerate(plain) if _is_rule(text)]
    dialog = any(hint in text for text in plain for hint in _DIALOG_HINTS)
    no_box = ScreenState(NOT_AT_PROMPT if dialog else UNRECOGNIZED, False)
    end = _agent_list_start(plain)
    if len(rules) < 2 or end - 1 - rules[-1] > _MAX_ROWS_BELOW_BOX:
        return no_box
    top, bottom = rules[-2], rules[-1]
    working = any(_WORKING_TEXT in text for text in plain[bottom + 1:end])
    box = rows[top + 1:bottom]
    if not box or not plain[top + 1].startswith(_BOX_GLYPH):
        return ScreenState(no_box.input_box, working)

    pointed = any(text.startswith(_POINTER) for text in plain[end:])
    focused = pointed and any(hint in text for text in plain[bottom + 1:end]
                              for hint in _LIST_KEY_HINTS)
    rows_typed = [box[0][len(_BOX_GLYPH):], *box[1:]]
    if not any(not ch.isspace() and not is_dim for row in rows_typed for ch, is_dim in row):
        return ScreenState(EMPTY, working, agent_pointed=pointed, list_focused=focused)
    text = "\n".join("".join(ch for ch, is_dim in row if not is_dim).strip()
                     for row in rows_typed)
    return ScreenState(HAS_TEXT, working, typed=text.strip(), agent_pointed=pointed,
                       list_focused=focused)
