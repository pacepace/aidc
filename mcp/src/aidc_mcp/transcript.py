"""JSONL transcript delivery core (design-09, MCP-15..19).

Pure, dependency-free logic for turning Claude Code's native per-session JSONL
transcript into deliverable assistant turns, plus the durable high-water mark
that makes delivery exactly-once across restarts. The watcher (tools.py) wires
file I/O and the callback POST around this; everything here is unit-testable
against recorded `.jsonl` fixtures.

Schema facts this relies on (verified 2026-06-09 against real transcripts; see
docs/design-09-callback-delivery.md):
  - Each line is one JSON object with a top-level `type`.
  - Message lines are type "user" / "assistant"; everything else is noise.
  - A turn spans many assistant lines; it is COMPLETE only when an assistant
    line has stop_reason in {"end_turn", "stop_sequence"}. "tool_use" continues
    the turn; null is incomplete.
  - Deliverable content = "text" content blocks only (drop "thinking"/"tool_use").
  - Skip lines flagged isSidechain / isCompactSummary / isVisibleInTranscriptOnly.
  - `--continue` APPENDS to the same file (no re-emission); new files appear only
    on fresh sessions. So a per-file byte offset + terminal-uuid is a sound
    exactly-once key.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import time
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from pathlib import Path

# Assistant stop_reason values that mark a turn as complete (control returns to user).
TERMINAL_STOP = frozenset({"end_turn", "stop_sequence"})

# Harness tools whose "result" is a human decision, not an automated tool_result.
# A turn that ends on one of these hands control back to the user exactly like
# end_turn — the awaited tool_result is a choice only a human can make, so it
# never arrives on its own. Such a turn MUST be delivered (rendered from the
# tool_use input, since the question is not in a text block), or an orchestrated
# session waits forever for a tool_result that never comes — the AskUserQuestion
# deadlock (design-09: interactive-block delivery).
INTERACTIVE_BLOCK_TOOLS = frozenset({"AskUserQuestion", "ExitPlanMode"})

# Top-level line types that carry conversation messages. Everything else
# (system, attachment, file-history-snapshot, last-prompt, ai-title, agent-name,
# mode, permission-mode, queue-operation, ...) is ignored.
_MESSAGE_TYPES = frozenset({"user", "assistant"})


@dataclass
class Turn:
    """A completed assistant turn ready for delivery decisions."""

    terminal_uuid: str
    text: str
    ok: bool = True  # False for API-error turns (delivered as a failure result)
    # The person-typed prompt lines that opened this turn (see human_prompt_text),
    # in file order. Empty when the turn was opened by something Claude Code
    # synthesized (hook feedback, a task notification, an auto-continue) or when
    # the turn is a continuation with no prompt of its own in the read window.
    # The watcher matches these against the prompts IT injected to decide which
    # were typed at the terminal by a person (consume_sent_prompt, in the drain).
    prompts: tuple[str, ...] = ()
    # Set by the watcher at delivery time: "terminal" when at least one prompt
    # was typed at the terminal (the delivered content then carries it),
    # "orchestrator" when every prompt was one the MCP injected, "" when unknown.
    prompt_origin: str = ""

    @property
    def is_empty(self) -> bool:
        return not self.text.strip()


def parse_jsonl(data: str) -> list[dict]:
    """Parse JSONL text into objects, defensively skipping malformed lines.

    A torn/partial trailing line (mid-append) or any unparseable line is
    skipped rather than raising — the transcript is written by yolo-mode Claude
    and must never crash the watcher (design-09 "defensive parsing").
    """
    out: list[dict] = []
    for line in data.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        # RecursionError (a deeply-nested crafted line) is not a ValueError, so it
        # must be caught explicitly or it escapes and crashes the watcher.
        except (ValueError, TypeError, RecursionError):
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def _is_skippable(obj: dict) -> bool:
    """Sidechain/subagent lines and resume/compaction summary lines are not turns."""
    return bool(
        obj.get("isSidechain")
        or obj.get("isCompactSummary")
        or obj.get("isVisibleInTranscriptOnly")
    )


def _text_of(message: dict) -> str:
    """Concatenate 'text' content blocks; ignore thinking/tool_use."""
    content = message.get("content")
    if isinstance(content, list):
        # Require the text value itself to be a str: the transcript is
        # attacker-influenced, and a non-str text (e.g. {"text": 999}) would make
        # "".join raise TypeError and crash the watcher (parse-layer contract).
        parts = [
            b["text"]
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
            and isinstance(b.get("text"), str)
        ]
        return "".join(parts)
    if isinstance(content, str):
        return content
    return ""


def _blocking_tool_use_block(message: dict) -> dict | None:
    """Return the tool_use block for an interactive-input tool, or None.

    AskUserQuestion / ExitPlanMode stop the turn awaiting a human choice;
    structurally the assistant line carries a tool_use block whose name is in
    INTERACTIVE_BLOCK_TOOLS. The line's stop_reason is "tool_use" (never a
    TERMINAL_STOP), so the ordinary terminal check would treat the turn as still
    in flight and never deliver it.
    """
    content = message.get("content")
    if not isinstance(content, list):
        return None
    for b in content:
        if not (isinstance(b, dict) and b.get("type") == "tool_use"):
            continue
        # `name` is attacker-influenced (yolo-mode Claude writes the transcript):
        # gate the frozenset membership on a str, or an unhashable name (list/dict)
        # would raise TypeError and crash the watcher — the module's parse layer
        # must never do that (see parse_jsonl docstring).
        name = b.get("name")
        if isinstance(name, str) and name in INTERACTIVE_BLOCK_TOOLS:
            return b
    return None


def _render_interactive_prompt(block: dict) -> str:
    """Render an interactive-input tool_use block into deliverable text.

    The user-facing content of AskUserQuestion / ExitPlanMode lives in the
    tool_use `input`, not in a text block, so _text_of misses it entirely.
    Render it as a plain prompt the orchestrator can read and answer as an
    ordinary "your turn" message — no new wire signal, same callback.
    """
    inp = block.get("input")
    if not isinstance(inp, dict):
        inp = {}
    if block.get("name") == "ExitPlanMode":
        plan = str(inp.get("plan", "")).strip()
        return f"[Plan ready for approval]\n{plan}".strip()
    # AskUserQuestion
    lines: list[str] = []
    questions = inp.get("questions")
    if isinstance(questions, list):
        for q in questions:
            if not isinstance(q, dict):
                continue
            qtext = str(q.get("question", "")).strip()
            if qtext:
                lines.append(f"[Question] {qtext}")
            opts = q.get("options")
            if isinstance(opts, list) and opts:
                lines.append("Options:")
                for o in opts:
                    if not isinstance(o, dict):
                        continue
                    label = str(o.get("label", "")).strip()
                    desc = str(o.get("description", "")).strip()
                    if label and desc:
                        lines.append(f"- {label}: {desc}")
                    elif label:
                        lines.append(f"- {label}")
    rendered = "\n".join(lines).strip()
    # Never return empty for a genuine interactive block: an empty render would
    # fall through to delivery_empty_turn and silently skip the turn — the very
    # deadlock this path exists to prevent. A malformed/empty payload still gets a
    # marker so the orchestrator is told the session is awaiting input.
    return rendered or "[Waiting for user input]"


def _uuid_of(obj: dict) -> str:
    """The line's uuid as a str, or '' if absent/non-str.

    An empty result means the line has no usable exactly-once anchor, so callers
    must NOT treat it as terminal. Gate on isinstance(str): a JSON `null` uuid
    returns None from .get(), and str(None) == "None" is truthy — it would slip a
    "can't anchor" guard that only checked truthiness.
    """
    u = obj.get("uuid")
    return u if isinstance(u, str) else ""


def _role(obj: dict) -> str:
    msg = obj.get("message")
    if isinstance(msg, dict) and msg.get("role"):
        return str(msg["role"])
    return str(obj.get("type", ""))


def _is_real_user_prompt(obj: dict) -> bool:
    """True for a genuine user prompt; False for tool-result lines.

    Tool results are written as role "user" with tool_result content blocks and
    no text — they continue the assistant's turn rather than starting a new one.
    Only a real prompt (carrying text) is a turn boundary.
    """
    raw_msg = obj.get("message")
    msg = raw_msg if isinstance(raw_msg, dict) else {}
    content = msg.get("content")
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") == "text" for b in content)
    return False


# A slash command typed at the terminal is transcribed as
# `<command-name>/x</command-name><command-message>x</command-message><command-args>...`.
_COMMAND_NAME_RE = re.compile(r"<command-name>(.*?)</command-name>", re.DOTALL)
_COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)
# A user line that OPENS with a tag is one Claude Code wrapped on the user's
# behalf — local-command output and its caveat, `!` bash-mode input and output
# (<bash-input>/<bash-stdout>, which can carry shell output such as an auth code),
# and any wrapper a later Claude Code adds. Most carry no provenance fields at
# all, so "no provenance means typed" would post them under "the user typed the
# following". The one wrapper a person does type is a slash command
# (<command-name>), rendered below; everything else tagged is never attributed.
_OPENS_WITH_TAG_RE = re.compile(r"^<[A-Za-z][\w-]*>")
# The interrupt marker is not always accompanied by interruptedMessageId (the
# tool-use variant "[Request interrupted by user for tool use]" is not).
_INTERRUPT_PREFIX = "[Request interrupted by user"


def human_prompt_text(obj: dict) -> str:
    """The text a PERSON typed at the terminal for this user line, or "".

    Verified against a live aidc transcript (2026-09-11): a prompt pasted by the
    MCP and one typed by a person are structurally identical — both carry
    ``origin.kind == "human"`` and ``promptSource == "typed"`` — so this cannot
    tell them apart (the watcher does that by matching the MCP's own send record).
    What it CAN exclude is everything Claude Code writes on the user's behalf and
    that no one typed:
      - ``isMeta`` lines: hook feedback, skill bodies, system reminders, the
        "Continue from where you left off." auto-continue;
      - ``promptSource`` other than "typed" / ``origin.kind`` other than "human":
        task notifications and other system-sourced prompts;
      - any line that opens with a wrapper tag: local-command output and its
        caveat, `!` bash-mode input/output, and the like (_OPENS_WITH_TAG_RE);
      - the "[Request interrupted by user ...]" markers, with or without an
        interruptedMessageId.
    A typed slash command is rendered compactly as ``/name args``.

    Absent provenance fields are otherwise treated as "typed" so older
    transcripts (and fixtures) still attribute plain prompts to the person. The
    tag rule is deliberately broader than the wrappers seen so far: a plain prompt
    that happens to open with a tag loses its note (harmless), whereas a wrapper
    that slipped through would be posted as the person's words (the failure this
    mechanism must never produce).
    """
    if obj.get("isMeta") or obj.get("interruptedMessageId"):
        return ""
    source = obj.get("promptSource")
    if source is not None and source != "typed":
        return ""
    origin = obj.get("origin")
    if isinstance(origin, dict) and origin.get("kind") not in (None, "human"):
        return ""
    raw_msg = obj.get("message")
    msg = raw_msg if isinstance(raw_msg, dict) else {}
    text = _text_of(msg).strip()
    if not text or text.startswith(_INTERRUPT_PREFIX):
        return ""
    if _OPENS_WITH_TAG_RE.match(text):
        m = _COMMAND_NAME_RE.search(text)
        if not m:
            return ""
        args_m = _COMMAND_ARGS_RE.search(text)
        args = args_m.group(1).strip() if args_m else ""
        return f"{m.group(1).strip()} {args}".strip()
    return text


def extract_completed_turns(objs: list[dict]) -> list[Turn]:
    """Return completed assistant turns in file order, COALESCED by user-prompt
    boundary.

    A turn spans a real user prompt through the LAST assistant TERMINAL_STOP
    before the next real user prompt (or end of file). Claude can emit several
    end_turn segments under a single prompt with no user input between them — e.g.
    an empty end_turn (a thinking/tool phase that ended with no text) immediately
    followed by the real answer in a second end_turn. Delivering on each end_turn
    fragments one exchange into multiple turns and signals "done" prematurely on
    the empty one; coalescing MERGES the segments so the watcher delivers once per
    exchange, with the text of the whole group.

    Tool-result (user-role) lines and tool_use/thinking blocks do not break or
    contribute to the turn. Empty turns (tool-only, no text) are emitted with empty
    text so the caller can still advance past them.

    Each turn also carries the person-typed prompt lines that opened it
    (``Turn.prompts``). Consecutive real user prompts with no assistant line
    between them (a slash command followed by its hook feedback, an auto-continue
    followed by the person's actual ask) all belong to the turn that follows, so
    they accumulate until an assistant line starts the reply.
    """
    turns: list[Turn] = []
    pending: list[str] = []   # text accumulated in the current group (all lines)
    committed: str = ""       # snapshot of pending text AS OF the last terminal line
    terminal_uuid: str = ""   # uuid of the last TERMINAL_STOP seen in this group
    has_terminal = False      # has this group reached a TERMINAL_STOP yet?
    committed_ok = True        # False when the committed terminal is an API error
    prompts: list[str] = []   # person-typed prompt lines that opened this group
    saw_assistant = False     # has an assistant line been seen since the prompt(s)?

    def flush() -> None:
        nonlocal pending, committed, terminal_uuid, has_terminal, committed_ok
        nonlocal prompts, saw_assistant
        # Only a group that reached a terminal is a completed (deliverable) turn.
        # Deliver the text COMMITTED at that terminal — never the trailing `pending`
        # text from non-terminal lines after it. Those lines sit past the turn's
        # terminal_uuid anchor, so including them here would re-deliver them when the
        # next poll resumes after that uuid (a double send). They are re-read and
        # delivered with their own terminal on a later poll.
        if has_terminal:
            turns.append(Turn(terminal_uuid=terminal_uuid, text=committed.strip(),
                              ok=committed_ok, prompts=tuple(prompts)))
        pending = []
        committed = ""
        terminal_uuid = ""
        has_terminal = False
        committed_ok = True
        prompts = []
        saw_assistant = False

    for obj in objs:
        # `type` is attacker-influenced; an unhashable value would raise on the
        # `not in` membership test. A non-str type is not a message line anyway.
        otype = obj.get("type")
        if not (isinstance(otype, str) and otype in _MESSAGE_TYPES) or _is_skippable(obj):
            continue
        role = _role(obj)
        if role == "user":
            if _is_real_user_prompt(obj):
                # A real prompt closes the previous group — but only once that
                # group has assistant content. Back-to-back prompts with nothing
                # between them (a command's hook feedback, an auto-continue and
                # then the person's ask) all open the SAME upcoming turn, so their
                # typed text accumulates rather than being dropped by a flush.
                if saw_assistant:
                    flush()
                typed = human_prompt_text(obj)
                if typed:
                    prompts.append(typed)
            continue

        # assistant line
        saw_assistant = True
        raw_message = obj.get("message")
        message = raw_message if isinstance(raw_message, dict) else {}

        if obj.get("isApiErrorMessage"):
            # An API-error line means the API call failed. Claude Code may auto-retry
            # and CONTINUE the same turn afterwards, or give up and hand control back
            # to the user — and which it is cannot be known at the instant the error
            # is written. So DON'T eagerly deliver the error as its own completion
            # (the old flush()+emit here did, which both signalled "done" while a
            # retry was still in flight AND — because flush() drops a not-yet-terminal
            # group's `pending` — discarded the work done before the error, then
            # advanced the watermark past it so it never came back).
            #
            # Instead treat the error like any TERMINAL_STOP candidate: record it as
            # the group's committed terminal with ok=False. A later real terminal
            # under the same prompt (the retry succeeded) SUPERSEDES it — its text and
            # uuid overwrite these, so the successful answer is delivered ok=True and
            # the error never surfaces as a completion. Only when the error is the
            # LAST terminal before the next real prompt or EOF — the session is
            # genuinely sitting waiting for input — is it delivered, as a failure
            # result carrying the pre-error `pending` text plus the error message.
            uid = _uuid_of(obj)
            if uid:  # empty uuid can't anchor exactly-once resume (see end_turn note)
                err = _text_of(message) or str(obj.get("error") or "API error")
                committed = "\n".join(pending + [err]) if err else "\n".join(pending)
                terminal_uuid = uid
                has_terminal = True
                committed_ok = False
            continue

        text = _text_of(message)
        if text:
            pending.append(text)

        # An interactive-input tool (AskUserQuestion / ExitPlanMode) hands control
        # back to the user just like end_turn — its result is a human decision that
        # never arrives on its own. Render the question (it lives in the tool_use
        # input, not a text block) and treat the line as a turn completion so the
        # watcher delivers it instead of waiting forever for a tool_result.
        block = _blocking_tool_use_block(message)
        if block is not None:
            rendered = _render_interactive_prompt(block)
            if rendered:
                pending.append(rendered)
            uid = _uuid_of(obj)
            if uid:
                # The ask IS a turn boundary (control returned to the user). Commit
                # the text up to & including it and flush it as its own turn now, so a
                # later continuation's text is never folded in under the ask's anchor.
                # An empty uuid can't anchor resume, so a uuid-less ask is not treated
                # as terminal (see end_turn note below).
                committed = "\n".join(pending)
                terminal_uuid = uid
                has_terminal = True
                committed_ok = True
                flush()

        # str-gate the membership: an unhashable stop_reason would otherwise raise.
        stop_reason = message.get("stop_reason")
        if isinstance(stop_reason, str) and stop_reason in TERMINAL_STOP:
            # Record the terminal but DON'T emit yet — more end_turn segments may
            # follow under the same prompt; emit only at the next boundary / EOF.
            # Snapshot the text COMMITTED up to this terminal so a later non-terminal
            # line's text is not delivered under this anchor (double-send guard).
            # Require a uuid: an empty terminal_uuid can't anchor exactly-once resume
            # (objs_after_uuid treats "" as "no anchor" and returns the whole file,
            # so the drain loop would replay everything and flood the webhook).
            uid = _uuid_of(obj)
            if uid:
                committed = "\n".join(pending)
                terminal_uuid = uid
                has_terminal = True
                # A real terminal SUPERSEDES a preceding API error in this group
                # (the retry succeeded): deliver the successful answer, not a failure.
                committed_ok = True

    flush()  # emit the final open group if it reached a terminal
    return turns


def objs_after_uuid(objs: list[dict], last_delivered_uuid: str | None) -> list[dict] | None:
    """Return the transcript objects strictly AFTER the line whose uuid matches.

    Resume is anchored on the last-delivered *line* uuid, not on a coalesced
    Turn's terminal uuid. That matters because coalescing is not stable across
    appends: an end_turn that was a group's terminal when delivered can later be
    absorbed into a larger group with a different terminal. A line uuid, by
    contrast, is append-only and always present, so it is a stable resume point.

    Returns:
      - all objs when last_delivered_uuid is falsy (no anchor yet);
      - objs after the matching line otherwise;
      - None when the anchor line is absent — a torn/partial mirror read (or a
        wrong file): the caller must NOT treat the whole file as new (that was
        the replay bug); skip this pass and retry.
    """
    if not last_delivered_uuid:
        return list(objs)
    for i, obj in enumerate(objs):
        if str(obj.get("uuid", "")) == last_delivered_uuid:
            return objs[i + 1:]
    return None


# --- retry schedule (MCP-18) -------------------------------------------------

def delay_for_attempt(attempt: int, *, cap: float = 60.0) -> float:
    """Bounded exponential backoff: 0, 2, 4, 8, 16, 32, 60, 60, ... seconds.

    attempt 0 is the immediate first try (no delay). Capped at `cap`.
    """
    if attempt <= 0:
        return 0.0
    return float(min(2 ** attempt, cap))


# --- durable high-water mark (MCP-17) ----------------------------------------

@dataclass
class Watermark:
    """Per-(session, conversation_id) delivery position. Persisted across restarts."""

    session: str
    conversation_id: str
    session_id: str = ""          # active transcript file stem (sessionId)
    # Diagnostic/informational only: the byte length observed at the last save.
    # Resume is anchored on last_delivered_uuid (line-stable under coalescing), so
    # this offset is written for debugging but never read to make a delivery decision.
    byte_offset: int = 0
    last_delivered_uuid: str = ""  # terminal assistant uuid last delivered
    # Loop-guard state (durable across MCP restart): the count of consecutive
    # deliveries and the wall-clock time of the last one. Only a genuinely IDLE
    # gap (the orchestrator stopped driving — far longer than any single turn)
    # resets the count; a slow turn does NOT — those slow-turn gaps are exactly
    # what let the 019f1fde runaway dodge the old rate-based guard. See the loop
    # guard in tools._drain_transcript_once.
    consecutive_deliveries: int = 0
    last_delivery_at: float = 0.0
    updated_at: str = ""

    def to_json(self) -> str:
        return json.dumps(asdict(self), separators=(",", ":"))


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _slug(value: str) -> str:
    """Filesystem-safe token for a (session|conversation_id) component."""
    return "".join(c if (c.isalnum() or c in "-_.") else "_" for c in value)


def watermark_path(base_dir: Path, session: str, conversation_id: str) -> Path:
    return Path(base_dir) / f"{_slug(session)}__{_slug(conversation_id)}.json"


def watermark_exists(base_dir: Path, session: str, conversation_id: str) -> bool:
    """True once a mark has been persisted for this (session, conversation).

    Used to distinguish a first-ever watch (which must baseline forward-only, so
    pre-existing transcript history is not replayed) from a resume (which picks
    up where it left off — survives MCP restart)."""
    return watermark_path(base_dir, session, conversation_id).exists()


def load_watermark(base_dir: Path, session: str, conversation_id: str) -> Watermark:
    """Load the persisted mark, or a fresh zero mark if none/corrupt."""
    path = watermark_path(base_dir, session, conversation_id)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return Watermark(
            session=session,
            conversation_id=conversation_id,
            session_id=str(data.get("session_id", "")),
            byte_offset=int(data.get("byte_offset", 0)),
            last_delivered_uuid=str(data.get("last_delivered_uuid", "")),
            consecutive_deliveries=int(
                # Back-compat: pre-rename watermarks stored this as
                # ``fast_consecutive``; honor it so a deploy mid-incident does not
                # silently reset a latched run and let another cap's worth through.
                data.get("consecutive_deliveries", data.get("fast_consecutive", 0))
            ),
            last_delivery_at=float(data.get("last_delivery_at", 0.0)),
            updated_at=str(data.get("updated_at", "")),
        )
    except (OSError, ValueError, TypeError):
        return Watermark(session=session, conversation_id=conversation_id)


def save_watermark(base_dir: Path, mark: Watermark) -> None:
    """Atomically persist the mark (temp + rename), matching the taint-flag pattern."""
    base = Path(base_dir)
    base.mkdir(parents=True, exist_ok=True)
    mark.updated_at = _now_iso()
    path = watermark_path(base, mark.session, mark.conversation_id)
    tmp = path.with_suffix(path.suffix + ".new")
    tmp.write_text(mark.to_json(), encoding="utf-8")
    os.replace(tmp, path)


# --- durable delivery ledger (structural exactly-once at the POST boundary) --
#
# The watermark answers "where do I resume reading"; it is best-effort and has
# a long history of subtle bugs (mtime-flap rotation, torn-read rewind, reconnect
# catch-up, retry storms) that each re-surfaced an already-delivered turn and
# replayed it to the orchestrator — the recurring meltdown. Fixing those causes
# one at a time is whack-a-mole: the delivery path trusts the watermark for
# SAFETY, and the watermark has many ways to be wrong.
#
# The ledger decouples safety from the watermark. It is the durable set of
# content fingerprints CONFIRMED delivered to a (session, conversation). The
# drain consults it right before every POST and refuses to send a fingerprint it
# already holds. So exactly-once becomes a property of the delivery boundary
# itself, independent of the watermark: even if a watermark bug re-surfaces a
# turn, the ledger drops it before it reaches the orchestrator. The watermark bugs
# degrade from "double-deliver and poison the agent" to "waste a disk read".
#
# Growth: one ~65-byte line per delivered turn, bounded per conversation by its
# turn count; the file accumulates across conversations exactly like the sibling
# watermark files (both persist under watcher-state and are not auto-evicted).
# A future janitor sweep can drop ledgers for conversations no longer watched;
# there is no compaction here by design (Retrieval > premature optimization).

def content_fingerprint(text: str) -> str:
    """Stable idempotency key for a deliverable turn: sha256 of its exact text.

    Content — not uuid — is the key so a turn re-emitted under a DIFFERENT uuid
    (coalescing picking a new terminal, a re-extraction after a rewind) is still
    recognized as the same message. The guarantee is literally "the same message
    content is delivered to a conversation at most once, ever". The only thing
    this suppresses that could be legitimate is the agent emitting byte-identical
    text in two genuinely distinct turns — which, in an unattended orchestration
    loop, is the runaway pathology, so dropping the duplicate is correct.
    """
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def ledger_path(base_dir: Path, session: str, conversation_id: str) -> Path:
    """Delivery-ledger file, a sibling of the watermark (same state dir/keying)."""
    return Path(base_dir) / f"{_slug(session)}__{_slug(conversation_id)}.delivered"


def load_delivered(base_dir: Path, session: str, conversation_id: str) -> set[str]:
    """The set of confirmed-delivered content fingerprints for this conversation.

    Missing file -> empty set (nothing delivered yet). The file is append-only,
    one hex fingerprint per line; a torn final line from a crash mid-append is a
    value that can never equal a real sha256, so it is inert on load — it can
    neither corrupt prior entries nor cause a false dedup."""
    try:
        text = ledger_path(base_dir, session, conversation_id).read_text(encoding="utf-8")
    except OSError:
        return set()
    return {line.strip() for line in text.splitlines() if line.strip()}


def record_delivered(base_dir: Path, session: str, conversation_id: str,
                     fingerprint: str) -> None:
    """Append one confirmed-delivered fingerprint to the durable ledger.

    Append-only: a crash mid-write can lose at most the trailing line (worst case
    one future duplicate — never corruption of prior entries). Called ONLY after
    a 2xx ack, so a turn that failed delivery or was dead-lettered is never
    recorded and stays eligible for a later resend."""
    base = Path(base_dir)
    base.mkdir(parents=True, exist_ok=True)
    with ledger_path(base, session, conversation_id).open("a", encoding="utf-8") as fh:
        fh.write(fingerprint + "\n")


# --- injected-prompt record (terminal-typed prompt attribution) ---------------
#
# A person attached to the session's tmux window can type a prompt straight into
# Claude, and the reply is delivered over the same webhook as a reply to a prompt
# the orchestrator sent. In the transcript the two are indistinguishable (see
# human_prompt_text), so the orchestrator received answers to questions it never
# asked and could not tell where they came from. The watcher therefore records
# every prompt the MCP itself injects, and at delivery time any prompt on the
# turn that is NOT in that record was typed at the terminal — its text is
# prepended to the delivered content so the reply reads in context.
#
# Keyed by normalized text (whitespace-collapsed), not by uuid: the MCP never
# learns the uuid of the line its paste produced. Verified 2026-09-11 against a
# live transcript that a pasted prompt is transcribed byte-for-byte. Durable on
# disk (sibling of the watermark) so an MCP restart between a send and its reply
# does not mislabel the orchestrator's own prompt as the person's. Bounded by
# count and age: an entry that never matched (a dead-lettered paste) must not
# linger forever and swallow a person later typing the same words.

_SENT_PROMPTS_MAX = 200
_SENT_PROMPTS_TTL_S = 24 * 3600.0


def normalize_prompt(text: str) -> str:
    """Whitespace-insensitive form of a prompt: the paste path already folds
    newlines to spaces and Claude Code trims, so runs of whitespace are the only
    expected difference between what was sent and what was transcribed."""
    return " ".join(text.split())


def prompt_fingerprint(text: str) -> str:
    return hashlib.sha256(normalize_prompt(text).encode("utf-8")).hexdigest()


def sent_prompts_path(base_dir: Path, session: str) -> Path:
    """Per-session (not per-conversation) record: a session has one tmux pane, and
    whichever conversation watches it needs the same answer."""
    return Path(base_dir) / f"{_slug(session)}.sent-prompts.json"


def _load_sent_prompts(base_dir: Path, session: str, now: float) -> list[dict]:
    """Entries as ``[{"fp": <sha256>, "at": <epoch>}]``, expired ones dropped.
    A missing or corrupt file is an empty record (never raises)."""
    try:
        data = json.loads(sent_prompts_path(base_dir, session).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return []
    if not isinstance(data, list):
        return []
    out: list[dict] = []
    for e in data:
        if not (isinstance(e, dict) and isinstance(e.get("fp"), str)):
            continue
        try:
            at = float(e.get("at", 0.0))
        except (TypeError, ValueError):
            continue
        if now - at <= _SENT_PROMPTS_TTL_S:
            out.append({"fp": e["fp"], "at": at})
    return out


def _save_sent_prompts(base_dir: Path, session: str, entries: list[dict]) -> None:
    """Atomic write (temp + rename), matching save_watermark."""
    base = Path(base_dir)
    base.mkdir(parents=True, exist_ok=True)
    path = sent_prompts_path(base, session)
    tmp = path.with_suffix(path.suffix + ".new")
    tmp.write_text(json.dumps(entries, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, path)


def record_sent_prompt(base_dir: Path, session: str, text: str, *,
                       now_fn=time.time) -> None:
    """Remember that the MCP injected ``text`` into ``session``'s pane. Call only
    after the paste succeeded, so a prompt that never reached Claude is not on
    record to mis-claim a person's identical words later."""
    now = now_fn()
    entries = _load_sent_prompts(base_dir, session, now)
    entries.append({"fp": prompt_fingerprint(text), "at": now})
    del entries[:-_SENT_PROMPTS_MAX]
    _save_sent_prompts(base_dir, session, entries)


def sent_prompts_remaining(base_dir: Path, session: str, *, now_fn=time.time) -> int:
    """Live (unexpired) entries still waiting to be matched — the health signal
    for the record: a count that only grows while replies keep arriving means
    matching has drifted (every reply then goes out under the terminal note)."""
    return len(_load_sent_prompts(base_dir, session, now_fn()))


def consume_sent_prompt(base_dir: Path, session: str, text: str, *,
                        now_fn=time.time) -> bool:
    """True — and the entry is removed — when ``text`` matches a prompt the MCP
    injected into ``session``. Removes ONE entry per call so the orchestrator
    sending the same words twice ("continue") is matched twice, and a person
    typing those words a third time is not."""
    now = now_fn()
    entries = _load_sent_prompts(base_dir, session, now)
    fp = prompt_fingerprint(text)
    for i, e in enumerate(entries):
        if e["fp"] == fp:
            del entries[i]
            _save_sent_prompts(base_dir, session, entries)
            return True
    return False


# Delivered-content framing for a reply whose prompt was typed at the terminal.
# Addressed to the orchestrating LLM: it must learn, in the content it reads,
# that this prompt did not come from it — otherwise it reads the reply as an
# answer to whatever IT last sent and is "very confused about where the
# instructions came from".
TERMINAL_PROMPT_NOTE = (
    "[Note: the user typed the following prompt directly into the session's terminal. "
    "It was not sent by you. The reply below answers it.]"
)


def render_delivery(reply: str, terminal_prompts: Sequence[str]) -> str:
    """The content to POST: the reply alone, or the terminal-typed prompt(s)
    prepended under TERMINAL_PROMPT_NOTE with a rule between them and the reply."""
    if not terminal_prompts:
        return reply
    quoted = "\n\n".join(p.strip() for p in terminal_prompts if p.strip())
    return f"{TERMINAL_PROMPT_NOTE}\n{quoted}\n\n---\n\n{reply}"


# --- active transcript resolution --------------------------------------------

def newest_message_ts(objs: list[dict]) -> str:
    """The lexicographically-max ISO ``timestamp`` among message entries.

    ISO-8601 UTC timestamps sort correctly as strings, so ``max`` is the most
    recent. Used to decide which of two transcripts is the genuinely
    more-recently-active session — a CONTENT signal, immune to the copy-forward
    mirror's mtime churn (it rewrites every file's mtime but never rewrites a
    frozen session's content). A frozen sibling therefore can NEVER out-timestamp
    the session active after it, so this cannot false-fire on the mtime flap the
    session pin was added to stop. ``""`` when no timestamped message is present.
    """
    newest = ""
    for o in objs:
        if o.get("type") in _MESSAGE_TYPES:
            t = o.get("timestamp")
            if isinstance(t, str) and t > newest:
                newest = t
    return newest


def resolve_active_transcript(transcript_dir: Path,
                              prefer_session_id: str | None = None) -> Path | None:
    """Newest top-level *.jsonl in the dir (excludes the subagents/ subdir).

    When prefer_session_id is given and a regular file `{prefer_session_id}.jsonl`
    exists, return it regardless of mtime. The copy-forward mirror rewrites whole
    files, so mtime is NOT a reliable "active session" signal — it can flap between
    files and make a still-active session look rotated (which would reset the
    watermark and replay the whole transcript). Pinning to the session we are
    already tracking prevents that false rotation; mtime is only the fallback for
    the first resolution (no prior session) or once the pinned file truly vanishes.

    Returns None when the dir is absent or empty (session not started / down).
    """
    d = Path(transcript_dir)
    if prefer_session_id:
        pinned = d / f"{prefer_session_id}.jsonl"
        try:
            if pinned.is_file() and not pinned.is_symlink():
                return pinned
        except OSError:
            pass
    try:
        # Regular files only — never follow symlinks. The dir is written by an
        # in-container mirror fed from the adversarial (yolo) dev container, so a
        # planted symlink (e.g. x.jsonl -> /etc/passwd) must not be read. This
        # defense lives here, in MCP (trustworthy), not in the mirror.
        candidates = [
            p for p in d.glob("*.jsonl") if p.is_file() and not p.is_symlink()
        ]
    except OSError:
        return None
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)
