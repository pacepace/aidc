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
# The first-launch screens named: dialogs a starting Claude shows before its input box ever
# appears and cannot get past without a person. They are named in session_status so an
# orchestrator sees why such a session is stuck, which the bare "not at prompt" does not say.
# Each is recognised by its own structure, never by its text anywhere on screen (a diff or a
# reply can quote that text): the dialog's rows run from the last full-width rule down to its
# hint row, which is the last row on screen; the first of them is the title, and one of them
# is the option.
#   TRUST_PROMPT    the folder-trust prompt (no seeded ~/.claude.json), measured on 2.1.270
#                   and 2.1.332 (where a home folder adds "This is your home folder, so Yes
#                   lasts for this session only").
#   ADD_DIR_PROMPT  the prompt for a folder passed with --add-dir that this Claude has not
#                   worked in ("Adding a new directory:", options "No, exit" and "Yes, add
#                   it"), measured on 2.1.332 (the git agent, live 2026-11-27).
TRUST_PROMPT = "trust_prompt"
ADD_DIR_PROMPT = "add_dir_prompt"
_FIRST_LAUNCH_ROWS = (
    (TRUST_PROMPT, "Accessing workspace:",
     re.compile(r"(?:❯\s+)?(?:\d+\.\s+)?Yes, I trust this folder")),
    (ADD_DIR_PROMPT, "Adding a new directory:",
     re.compile(r"(?:❯\s+)?(?:\d+\.\s+)?Yes, add it")),
)
FIRST_LAUNCH_DIALOGS = frozenset(name for name, _, _ in _FIRST_LAUNCH_ROWS)
# The menu of Claude's question tool (AskUserQuestion), measured on 2.1.332 (the git agent,
# live 2026-11-27). Below the last-but-one full-width rule: a tab row with one `☐ <header>`
# per question, the question's rows (each starting `│ `), then one row per option, numbered,
# the one under the keyboard carrying the pointer `❯ ` in place of the two-space indent, with
# its description indented further on the next row. Claude Code adds "Type something." and,
# under the last rule, "Chat about this"; the last row is the hint
# "Enter to select · ↑/↓ to navigate · Esc to cancel". Recognised by that structure, never by
# text anywhere on screen: a reply or a diff can quote any of it.
QUESTION_MENU = "question"
_QUESTION_HINTS = ("Enter to select", "to navigate")
_QUESTION_TAB_RE = re.compile(r"\s*(?:←\s+)?[☐☒✔]\s+\S")
_QUESTION_MARK_RE = re.compile(r"[☐☒✔]")
_QUESTION_OPTION_RE = re.compile(r"(❯ |  )(\d+)\. (\S.*)")
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
class QuestionMenu:
    """The question menu on screen: its text, its numbered options in order, which one the
    pointer is on, and whether it holds more than one question (tabs)."""

    text: str
    options: tuple[tuple[int, str], ...]
    pointer: int          # the number of the option under the pointer, 0 for none
    several: bool = False


@dataclass(frozen=True)
class ScreenState:
    input_box: str   # EMPTY, HAS_TEXT, NOT_AT_PROMPT or UNRECOGNIZED
    working: bool    # the status row shows `esc to interrupt`
    # Which dialog, when input_box is NOT_AT_PROMPT: one of FIRST_LAUNCH_DIALOGS, or
    # QUESTION_MENU (then `question` holds the menu); "" for any other (a permission menu).
    dialog: str = field(default="", compare=False)
    question: QuestionMenu | None = field(default=None, compare=False)
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

    Reverse video (SGR 7, off with 27 or a reset) is Claude Code's own cursor. Over
    the startup placeholder it covers the first character, drawn reverse but not dim
    (`\\x1b[7mT\\x1b[0;2mry "edit <filepath> to…"`, measured on 2.1.332): a reverse
    character with dim text right after it is the placeholder's, so it counts as dim.
    """
    out: list[tuple[str, bool]] = []
    rev: list[bool] = []
    reverse = False
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
                    if p in ("", "0"):
                        dim = reverse = False
                    elif p == "22":
                        dim = False
                    elif p == "2":
                        dim = True
                    elif p == "7":
                        reverse = True
                    elif p == "27":
                        reverse = False
                    k += 1
                i = m.end()
                continue
            other = _OTHER_ESCAPE_RE.match(line, i)
            i = other.end() if other else i + 1
            continue
        out.append((line[i], dim))
        rev.append(reverse)
        i += 1
    for j in range(len(out) - 1):
        if rev[j] and not out[j][1] and out[j + 1][1]:
            out[j] = (out[j][0], True)
    return out, dim


def _is_rule(text: str) -> bool:
    """A full-width `─` rule, which may carry one label set off by spaces: Claude Code
    2.1.284 draws a named session's name into the box's top rule (`──── orchestrator ─`)."""
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


def _first_launch_dialog(plain: list[str], rules: list[int]) -> str:
    """The first-launch screen a screen without the input box shows (one of
    FIRST_LAUNCH_DIALOGS), read from the dialog's own rows only, or "" for any other dialog
    (a permission or question menu, which may quote a first-launch text in a preview)."""
    if not plain or not rules or not any(hint in plain[-1] for hint in _DIALOG_HINTS):
        return ""
    body = [text.strip() for text in plain[rules[-1] + 1:-1] if text.strip()]
    for name, title, option in _FIRST_LAUNCH_ROWS:
        if body and body[0] == title and any(option.fullmatch(t) for t in body):
            return name
    return ""


def _question_menu(plain: list[str], rules: list[int]) -> QuestionMenu | None:
    """The question menu a screen without the input box shows, read from its own rows (from
    the last-but-one rule down to its hint row, the last row on screen), or None."""
    if len(rules) < 2 or not plain or not all(h in plain[-1] for h in _QUESTION_HINTS):
        return None
    rows = plain[rules[-2] + 1:-1]
    tab = next((i for i, text in enumerate(rows) if text.strip()), None)
    if tab is None or not _QUESTION_TAB_RE.match(rows[tab]):
        return None
    several = (len(_QUESTION_MARK_RE.findall(rows[tab])) > 1
               or rows[tab].strip().startswith("←"))
    text: list[str] = []
    options: list[tuple[int, str]] = []
    pointer = 0
    for row in rows[tab + 1:]:
        m = _QUESTION_OPTION_RE.fullmatch(row.rstrip())
        if m is not None:
            number = int(m.group(2))
            if number != len(options) + 1:
                return None
            options.append((number, m.group(3).strip()))
            if m.group(1) == _POINTER:
                pointer = number
        elif not options and row.startswith("│"):
            text.append(row[1:].strip())
    if not options or not text:
        return None
    return QuestionMenu(text="\n".join(text), options=tuple(options), pointer=pointer,
                        several=several)


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
    question = _question_menu(plain, rules) if dialog else None
    no_box = (ScreenState(NOT_AT_PROMPT, False, dialog=QUESTION_MENU, question=question)
              if question is not None
              else ScreenState(NOT_AT_PROMPT, False, dialog=_first_launch_dialog(plain, rules))
              if dialog else ScreenState(UNRECOGNIZED, False))
    end = _agent_list_start(plain)
    if len(rules) < 2 or end - 1 - rules[-1] > _MAX_ROWS_BELOW_BOX:
        return no_box
    top, bottom = rules[-2], rules[-1]
    working = any(_WORKING_TEXT in text for text in plain[bottom + 1:end])
    box = rows[top + 1:bottom]
    if not box or not plain[top + 1].startswith(_BOX_GLYPH):
        return ScreenState(no_box.input_box, working, dialog=no_box.dialog,
                           question=no_box.question)

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
