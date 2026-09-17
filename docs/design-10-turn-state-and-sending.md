# Design 10 — Turn State from the Transcript, and a Send Queue That Never Drops

**What this covers.** Two halves of how the MCP server works with the shared Claude session in
a dev container's tmux `claude` window:

- **Delivery** (Claude → orchestrator): when a turn is really finished, what is delivered for
  an interrupted turn, and how the payload says who the turn belongs to.
- **Sending** (orchestrator → Claude): how the MCP decides Claude is free to receive a prompt,
  how it avoids typing over a person's unsent text, and how the per-session queue holds prompts
  until they land.

**Requirements implemented:** MCP-24 .. MCP-30 (`docs/requirements.md`). Extends MCP-15..19 and
MCP-23; builds on `docs/done/design-09-callback-delivery.md`.

**Status:** designed 2026-09-17, not built. Transcript and screen facts measured in a dev container
on Claude Code 2.1.270 and 2.1.274 the same day.

---

## Why this exists

A comparison with TangleClaw (another tmux-driven session orchestrator) on 2026-09-16 surfaced
defects and gaps in how aidc tracks a shared session's state.

1. **A Stop hook that pushes back makes aidc report "done" too early.** When a Stop hook
   blocks (prawduct's gates do this routinely), Claude Code writes the block into the transcript
   and Claude keeps working. aidc's parser (`extract_completed_turns`) reads the block's
   feedback line as a new user prompt, splits the turn there, and the pre-block text is
   delivered as a finished reply. The continuation arrives later as an unprompted second reply.
   Even without the split, the 4s settle window closes long before Claude resumes (13s in one
   measured case), so the pre-block terminal still reads as complete.
2. **An interrupted turn is never reported.** When someone presses Esc mid-turn, the turn has no
   terminal. It is dropped as abandoned when the next prompt arrives, and the orchestrator is
   never told the work it asked for was cut off.
3. **Who a turn belongs to is split across two unconnected fields.** aidc sends
   `prompt_origin: "terminal"` plus a note in the content (MCP-23, 2026-09-11). MetaLLM added a
   `speaker` field (2026-09-12) and never reads `prompt_origin`; aidc never sends `speaker`.
4. **Sending still reads the screen.** Design 09 moved delivery onto the transcript, but the send
   path kept `_wait_for_idle` (pane byte-stable for 1.5s). It depends on Claude Code animating
   something on screen every second while it works. If a Claude Code version stops doing that
   during silent thinking, the MCP types the next prompt into a running turn.
5. **The send path types over a person's unsent text.** A half-typed line in Claude's input box
   is static, reads as idle, and the MCP's paste plus Enter merges it into the orchestrator's
   prompt.
6. **The send queue gives up.** An accepted prompt is dead-lettered after ~4h of waiting,
   immediately when Claude is not running, or after 3 failed pastes, and the whole queue lives
   in process memory, so an `aidc-mcp` restart loses every waiting prompt silently.

## Product stance

The shared session is a **collaboration surface**. A person attaches to the session and works in
the same Claude the orchestrator drives, and the orchestrator watches what the person does,
including Claude's replies to the person's own prompts. Nothing in this design hides a person's
turns from the orchestrator. Where the orchestrator could misread a turn, the fix is labelling.

The transcript is the source of truth for Claude's state. The screen is read only for what the
transcript cannot show, and each such use is listed below with its reason.

---

## Transcript facts this design relies on

Measured in an aidc dev container on Claude Code 2.1.270 and 2.1.274 (2026-09-17), and on host
transcripts (2.1.273). The JSONL is an undocumented internal format (see design 09): every rule
below fails safe when a line is missing or unrecognized.

| Fact | Evidence |
|---|---|
| A Stop-hook block writes a `user` line with `isMeta: true` and string content starting `Stop hook feedback:`, whether the hook blocks by JSON `decision: "block"` or by exit 2 | container: both kinds; host: 14 lines in the metallm project |
| The feedback line is followed ~150 ms later by `system` / `stop_hook_summary` with non-empty `hookErrors` (both block kinds). No `turn_duration` follows a blocked stop | container: both kinds |
| An allowed stop writes `stop_hook_summary` with `hookErrors: []`, then `system` / `turn_duration` within a few ms. One `turn_duration` covers the whole exchange, pushbacks included | container: 5 of 5 allowed stops; host: 7 of 7; tangle's scan ~9.9k |
| `turn_duration` is sometimes absent after an allowed stop (155 of ~10k in tangle's scan, cause unknown) | reported by a peer session; not reproduced; treat as not guaranteed |
| A reply's thinking and text are written as separate `assistant` lines, each with `stop_reason: end_turn` | container |
| Esc **after** Claude has written anything writes a `user` line `[Request interrupted by user]` (with `interruptedMessageId`) and no system line; Stop hooks do not run | container |
| Esc **before** Claude has written anything writes **nothing**: the prompt line stays with no reply, and the prompt text is put back into the input box on screen | container |
| A background task finishing writes a `user` line `<task-notification>…` with `promptSource: "system"` and `origin.kind: "task-notification"`, and Claude runs a new turn on it | container |

Raw notes and captures: `.prawduct/artifacts/claude-code-measurements.md` (not committed).

---

## Delivery

### D1. A Stop-hook pushback reopens the turn (MCP-24)

`extract_completed_turns` gains two rules:

- **A pushback is not a prompt.** A `user` line with `isMeta: true` never closes the current
  group. (Today any user line carrying text does.) This also applies to other `isMeta` lines
  Claude Code writes on the user's behalf, which MCP-23 already refuses to attribute to a person.
- **A pushback cancels the preceding terminal.** When the group has reached a terminal and the
  next relevant line is a Stop-hook feedback line or a `stop_hook_summary` with non-empty
  `hookErrors`, the group's terminal is withdrawn: `has_terminal` goes false, the committed text
  stays pending, and the group completes only at a later terminal.

The parser currently skips every `system` line (`_MESSAGE_TYPES`). It starts reading exactly two
subtypes, `stop_hook_summary` and `turn_duration`, and keeps ignoring the rest.

**Observability.** When a group that already had a terminal receives more assistant content with
no pushback or real prompt between them, log `transcript_terminal_superseded`. That is the case
tangle could not explain (a block that leaves no trace) and would still deliver early; the log
tells us whether it happens in aidc sessions.

**Exactly-once is unchanged.** The watermark still anchors on the delivered terminal's uuid, and
the delivery ledger (MCP-17) still guards the POST.

### D2. The end-of-turn record skips the settle wait (MCP-25)

The drain's settle gate (`_drain_once_body`, `settle_seconds`) holds delivery until the
transcript has been quiet for `metallm.turn_settle_seconds` (default 4s). New rule: when the last
group's terminal is followed by a `turn_duration` line, and nothing but ignorable lines comes
after that, deliver on this poll without waiting.

`turn_duration` is only ever a shortcut. When it is absent, the settle window applies exactly as
today. A Claude Code that stops writing it costs a few seconds per reply, never a hang.

### D3. An interrupted turn is delivered, marked incomplete (MCP-26)

When a group with no terminal is followed by an interrupt line, the interrupt closes the turn:

- `interrupted: true`, with `ok: true`. An interrupt is a person's choice, not a failure.
- Content opens with the note below, then the text Claude wrote before the interrupt, or the
  sentence "Claude had not written anything yet." when there is none. The note carries the
  meaning on its own, so a receiver that ignores `interrupted` still shows the reader what
  happened.
- The turn's anchor is the interrupt line's uuid (it has one; a uuid-less interrupt line is not
  treated as terminal, for the same reason as design 09's empty-uuid rule).
- `prompt_origin` and `speaker` are computed from the turn's prompts as for any other turn. An
  interrupt is a person's act, but the turn it cuts off may be the orchestrator's.

```
[Interrupted: the person at the terminal pressed Esc and stopped this task before Claude
finished. The text below is what Claude had written up to that point, and it is incomplete.]
```

The interrupt line is delivered without waiting for the next prompt. It still goes through the
settle gate, because Claude Code can write more lines right after an interrupt.

**Why not `ok: false`.** It was the first choice, but MetaLLM renders `ok: false` as
"Dev agent (error)" with an `[ERROR]` prefix, which reads as a crash. MetaLLM's `CallbackRequest`
is a plain pydantic model that ignores unknown fields (confirmed by the metallm session,
2026-09-17), so `interrupted` can ship before MetaLLM knows it: until then the turn shows as an
ordinary reply with the note on top. MetaLLM will render `interrupted: true` as
"stopped at the terminal".

### D4. `speaker` says who the turn belongs to (MCP-27)

The payload gains `speaker`:

- `"human"` when the turn answers only prompts typed at the terminal.
- `"agent"` otherwise, including a turn that answers both an orchestrator prompt and a typed
  one (part of it is the orchestrator's answer), and a turn with no prompt of its own.

`prompt_origin` and the content note stay as they are.

**Ordering constraint.** MetaLLM today *drops* callbacks with `speaker: "human"` (not enqueued,
BUSY not cleared). Sending the field before MetaLLM changes that would hide every person turn
from the orchestrator. The metallm session has been asked (2026-09-17) to change the rule so a
human turn is shown to the orchestrator as something the person did, not answered, and not
counted as its own task finishing. The metallm session confirmed the same day: Pace chose "record
without wake" (the turn is written into the conversation, runs no turn, leaves BUSY alone, and
renders under a distinct source). aidc starts sending `speaker` only when the metallm session
reports that change released and deployed.

### D5. The callback payload contract

aidc and MetaLLM once built the same feature twice with fields neither side read (`prompt_origin`
vs `speaker`). This table is the single description of the shared-session callback body
(`POST {callback_url}/api/v1/internal/callback/{conversation_id}`). A change to it is agreed with
the metallm session and written here before either side builds it.

| Field | Type | Values and meaning | Since |
|---|---|---|---|
| `content` | string | The reply text. May open with the terminal-prompt note (MCP-23) and/or the interrupt note (D3). | design 09 |
| `ok` | bool | `false` only when the turn ended on an API error Claude Code did not recover from. An interrupt is `true`. | design 09 |
| `source` | string | Always `"agent_watch"` for this path. | design 09 |
| `session` | string | The aidc session that produced the turn. | design 09 |
| `prompt_origin` | string | `"terminal"` if any prompt the turn answers was typed at the pane, `"orchestrator"` if all were sent by the MCP, `""` if the turn had no prompt of its own. | MCP-23 |
| `interrupted` | bool | `true` when the turn was cut off by Esc at the terminal (D3), else `false`. Always sent. | MCP-26 |
| `speaker` | string | `"human"` when every prompt the turn answers was typed at the terminal, else `"agent"`. **Not sent until MetaLLM's record-without-wake change is deployed.** | MCP-27 |

Combinations are independent. An interrupted turn on a prompt the person typed carries
`interrupted: true` and (once enabled) `speaker: "human"`, so MetaLLM records it without waking
the orchestrator and labels it as stopped at the terminal.

---

## Sending

### S1. The transcript decides whether Claude is busy (MCP-28)

A per-session **turn state** is read from the session's mirrored transcript (the same file design
09's watcher resolves: pinned session id, newest `*.jsonl` fallback, `subagents/` excluded).
Claude is **busy** when the newest relevant line leaves a turn open:

- a real user prompt with no terminal after it,
- an assistant line with `stop_reason: "tool_use"`, or a tool result, with no terminal after it,
- a terminal that a pushback (D1) has withdrawn.

Claude is **free** when the newest relevant line closes a turn: a terminal (preferably followed
by `turn_duration`), an interrupt line, or an API-error line with nothing after it for the settle
window.

`_wait_for_idle` (pane byte-stability) is removed from `session_send`, the queue drainer,
`session_run`, and `session_resend`. `session_run`'s per-turn response comes from the transcript
too, which retires `_extract_delta` and `_strip_ansi` (MCP-15 already barred them from delivery).

**After a send, busy until the transcript shows it.** The container mirror copies the transcript
about every 2s, so right after a paste the transcript still shows the previous closed turn. After
injecting, the session counts as busy until a user line matching the injected prompt (by the
normalized fingerprint MCP-23 already records) appears. If it has not appeared after a bounded
wait (the paste did not land), the prompt is treated as not sent and stays queued (S3).

**An open turn that has gone quiet.** The transcript can show a turn as open when Claude is not
working: an Esc before Claude wrote anything leaves no marker (measured), and a crash mid-turn
leaves the last line open. Only then, when the transcript shows an open turn and has not grown for
a few seconds, the screen's status row decides: if it does not show `esc to interrupt`, Claude has
stopped. For a prompt with no assistant line after it, that is reported as an interrupt (D3, with
"Claude had not written anything yet"), and the session counts as free. While the transcript is
growing, or the status row still shows `esc to interrupt`, the session stays busy. If a future
Claude Code drops that wording, the check never finds it, so this path falls back to a long quiet
period (minutes) with Claude running and at its input prompt. It never types into a busy session.

### S2. What the screen is still read for (MCP-28, MCP-29)

Only three things, each invisible to the transcript:

1. **Unsent text in Claude's input box.** The transcript records a prompt only after it is sent.
2. **Whether Claude is at its input prompt at all.** After a start or restart, Claude can be on a
   login, trust, or startup screen while the transcript's last turn reads closed.
3. **Whether `esc to interrupt` is on the status row**, and only when the transcript shows an open
   turn that has gone quiet (S1). Never used while the transcript can answer.

Both are read from one `capture-pane -e` of the `claude` window (with escape sequences, so text
attributes are visible). Measured on Claude Code 2.1.270 and 2.1.274:

- **The input box** is the region between the last two full-width `─` rules near the bottom of
  the pane; the status row sits directly below the second rule.
- **Its first row** starts with the glyph `❯` followed by a no-break space (`❯\xa0`). Earlier
  prompts in the scrollback also start with `❯` but are drawn on a background colour
  (`\x1b[48;5;237m`), so they do not match.
- **Empty** means nothing after `❯\xa0`, or only dim text: the placeholder (`Try "…"`) is drawn
  with SGR 2 and appears for a fraction of a second after startup. Typed text is unstyled.
- **Multi-line** unsent text continues on rows indented two spaces, still between the rules.
- **Not at prompt:** no such box row. Examples seen: the folder-trust menu on first launch (`❯`
  used as a menu cursor, no `─` box), and a bare shell after `/exit` (`pane_current_command` is
  `bash`).

Cursor position was recorded (x=2 on an empty box row) but is not needed: the row content decides.

When the screen cannot be classified (a Claude Code redesign), the send path treats it as **not
safe to type** and says so (S3). An unrecognized screen holds prompts; it never types into them.

### S3. Waiting for the person, visibly (MCP-29)

When the input box holds unsent text, a prompt is not injected. It stays queued, and the tmux
status line of the session shows:

```
aidc: orchestrator message waiting — press Enter or clear your input to let it through
```

The line is set when a prompt starts waiting on input-box text and cleared as soon as that prompt
is injected or the queue empties. It is written through a tmux user option referenced from
`status-right`, so it does not overwrite anything else on the status line.

The check runs again immediately before the paste, under the send lock, so the window in which a
person can start typing between check and paste is milliseconds. It cannot be closed entirely.

### S4. A queue that never gives up (MCP-30)

The per-session queue keeps FIFO order and the existing lock discipline, and changes in five
ways:

1. **No wait deadline.** `_PENDING_MAX_IDLE_POLLS` goes. A prompt waits as long as its session
   exists.
2. **Held while Claude is not running.** A stopped Claude (restart, crash, the person exited it)
   holds the queue instead of dead-lettering it. Delivery resumes when Claude is back at its
   prompt.
3. **Paste failures retry.** A failed paste backs off (bounded interval, unbounded attempts) and
   is reported as the waiting reason, instead of being dropped after 3 attempts.
4. **Persisted.** The queue is written to the watcher-state dir (atomic temp+rename, like the
   watermark) on every change. On `aidc-mcp` start, sessions with a non-empty persisted queue get
   a drainer. A queue file whose session no longer exists is dead-lettered on start.
5. **The only exits** are "injected" and "session killed". On kill, every waiting prompt is
   written to the send dead-letter dir, so there is still a record.

**Why a prompt is waiting** is always one of a closed set, reported in the `session_send` result
when it queues and in `session_status` for every waiting prompt:

| Reason | Meaning |
|---|---|
| `claude_busy` | the transcript shows a turn in progress |
| `input_has_text` | the person has unsent text in Claude's input box |
| `claude_not_running` | the `claude` window is at a shell |
| `screen_unrecognized` | Claude is running but the screen is not its input prompt (startup, login, or an unrecognized layout) |
| `paste_failing` | the paste did not land; retrying |
| `queued_behind` | an earlier prompt in the queue is waiting |

The queue-depth cap (25) stays: it refuses a *new* prompt audibly at the door; it never drops an
accepted one.

**Persisted format.** A persisted queue locks in a schema, so its questions come first. What reads
it: the MCP on restart (to resume draining), `session_status` (to report), and a person
inspecting `~/aidc-mcp-audit/watcher-state/` after an incident. The questions it answers: which
prompts are waiting for which session, in what order, since when, how many paste attempts each
has had, and the last recorded waiting reason. File:
`watcher-state/<session>.send-queue.json`, one object per session:

```json
{ "session": "metallm",
  "updated_at": "2026-09-17T12:00:00Z",
  "prompts": [
    { "text": "...", "enqueued_at": "2026-09-17T11:58:02Z",
      "paste_attempts": 0, "waiting_reason": "input_has_text" } ] }
```

Prompt text is stored as the queue receives it (already newline-flattened by `session_send`).
Same trust level as the existing send record and dead-letter files, which already store prompts.

---

## Out of scope

- A channel into Claude other than the pane. None is known that feeds a running interactive
  session; running `--print` into the same session would give one transcript two writers.
- MetaLLM's handling of `speaker: "human"`. That change belongs to the metallm repo; this design
  only records the ordering constraint.
- Engines other than Claude.
- Detecting permission dialogs. aidc prevents them (`--dangerously-skip-permissions`, and
  `--disallowedTools` for the interactive-input tools, per design 09).

## Cross-references

- Requirements: MCP-15..19, MCP-23, MCP-24..30 (`docs/requirements.md`).
- Delivery path: `mcp/src/aidc_mcp/transcript.py` (`extract_completed_turns`, `human_prompt_text`),
  `mcp/src/aidc_mcp/tools.py` (`_drain_once_body` settle gate, `_post_turn`).
- Send path: `mcp/src/aidc_mcp/tools.py` (`session_send`, `_drain_pending_sends`,
  `_enqueue_send`, `_inject`, `_wait_for_idle`, `session_run`, `session_resend`).
- Transcript mirror: `.devcontainer/transcript-mirror.sh`. tmux session: `.devcontainer/tmux-start.sh`.
- MetaLLM callback contract: `api/src/api/v1/internal/callback.py` in the metallm repo.
