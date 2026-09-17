# Design 10 — Turn State from the Transcript, and a Send Queue That Never Drops

**What this covers.** Two halves of how the MCP server works with the shared Claude session in
a dev container's tmux `claude` window:

- **Delivery** (Claude → orchestrator): when a turn is really finished, what is delivered for
  an interrupted turn, and how the payload says who the turn belongs to.
- **Sending** (orchestrator → Claude): how the MCP decides Claude is free to receive a prompt,
  how it avoids typing over a person's unsent text, and how the per-session queue holds prompts
  until they land.

**Requirements implemented:** MCP-24 .. MCP-30 and MCP-32 .. MCP-34 (`docs/requirements.md`). Extends MCP-15..19 and
MCP-23; builds on `docs/done/design-09-callback-delivery.md`.

**Status:** designed and built 2026-09-17 (branch `feature/turn-state`), except D4's `speaker`,
which waits on MetaLLM. Transcript and screen facts measured in a dev container on Claude Code
2.1.270 and 2.1.274 the same day. D7 and the dropped-prompt callback in D5 came out of the joint
test with the metallm session that day.

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
| The feedback line is written when the blocking hook **finishes** (8 s after the reply for a hook that runs 8 s), and is followed ~150 ms later by `system` / `stop_hook_summary` with non-empty `hookErrors`. No `turn_duration` follows a blocked stop | container: both kinds, and an 8 s hook |
| A Stop hook that **fails without blocking** (exit 1) is also listed in `hookErrors` (`Failed with non-blocking status code: …`), but there is no feedback line, Claude stops, and `turn_duration` follows. So non-empty `hookErrors` does not mean a block | container |
| An allowed stop writes `stop_hook_summary` with `hookErrors: []`, then `system` / `turn_duration` within a few ms. One `turn_duration` covers the whole exchange, pushbacks included | container: 5 of 5 allowed stops; host: 7 of 7; tangle's scan ~9.9k |
| `turn_duration` is sometimes absent after an allowed stop (155 of ~10k in tangle's scan, cause unknown) | reported by a peer session; not reproduced; treat as not guaranteed |
| A reply's thinking and text are written as separate `assistant` lines, each with `stop_reason: end_turn` | container |
| Esc **after** Claude has written anything writes a `user` line `[Request interrupted by user]` (with `interruptedMessageId`) and no system line; Stop hooks do not run | container |
| Esc **before** Claude has written anything writes **nothing**: the prompt line stays with no reply, and the prompt text is put back into the input box on screen | container |
| A background task finishing writes a `user` line `<task-notification>…` with `promptSource: "system"` and `origin.kind: "task-notification"`, and Claude runs a new turn on it | container |
| A prompt submitted while Claude is working is not written as a `user` line. Claude Code writes a `queue-operation` enqueue carrying its text, removes it at the next tool boundary, and answers it inside the running turn | container |

Raw notes and captures: `.prawduct/artifacts/claude-code-measurements.md` (not committed).

---

## Delivery

### D1. A Stop-hook pushback reopens the turn (MCP-24)

`extract_completed_turns` gains two rules:

- **A pushback is not a prompt.** A `user` line with `isMeta: true` never closes the current
  group. (Today any user line carrying text does.) This also applies to other `isMeta` lines
  Claude Code writes on the user's behalf, which MCP-23 already refuses to attribute to a person.
- **A pushback cancels the preceding terminal.** When the group has reached a terminal and a
  Stop-hook feedback line follows, the group's terminal is withdrawn: the committed text stays
  pending, and the group completes only at a later terminal. The feedback line is the only block
  signal: `stop_hook_summary`'s `hookErrors` also lists hooks that failed without blocking, after
  which Claude does stop (measured), so treating it as a block would lose that reply.

**Hooks still running.** The feedback line is written when the blocking hook finishes, which can
be well after the reply. While the transcript's tail is a reply with no `stop_hook_summary` or
`turn_duration` after it, the watcher holds delivery for up to `_STOP_HOOK_WAIT_S` (120 s) of
quiet instead of the 4 s settle window. This applies only to a transcript that has shown at least
one stop record, so a Claude Code that writes none never makes replies wait. A hook that runs
longer than the hold still splits the reply; that is logged (below).

**Observability.** Three events, each for a case that would otherwise be invisible:
- `transcript_terminal_superseded`: a reply followed by more assistant work with no pushback or
  prompt between them (a block that leaves no trace).
- `transcript_late_pushback`: a pushback arrived after the reply before it was already delivered
  (a hook slower than the hold).
- `transcript_withdrawn_reply_dropped`: a reply was pushed back and Claude produced nothing more
  before the next prompt, so nothing could be delivered for it. Logged once per reply.

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

**A prompt interrupted before Claude wrote anything** leaves no marker (see the facts table).
Until the send side detects it (S1), the transcript shows it as a prompt with no reply. When a
prompt Claude Code raised itself (a background task's notification) arrives next, the unanswered
prompt is dropped from the turn's prompts, so the notification's reply is not labelled as
answering it.

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
| `prompt_origin` | string | `"terminal"` if any prompt the turn answers was typed at the pane, `"orchestrator"` if all were sent by the MCP, `""` if the turn had no prompt of its own. MetaLLM does not read it (confirmed 2026-09-17); `speaker` carries what it needs. | MCP-23 |
| `interrupted` | bool | `true` when the turn was cut off by Esc at the terminal (D3), else `false`. Always sent. | MCP-26 |
| `speaker` | string | `"human"` when every prompt the turn answers was typed at the terminal, else `"agent"`. **Not sent until MetaLLM's record-without-wake change is deployed.** | MCP-27 |
| `error_code` | string | Present only on a callback that reports a failure rather than a reply. The one value is `"prompt_dropped"` (below). It never says anything `content` does not. | MCP-33 |

**A prompt that will never be pasted** (MCP-33). A queued prompt leaves the queue unpasted only
when its session is gone: the container no longer exists, or a container of the same name has a
different id because the session was killed and created again. Each such prompt that came with a
`conversation_id` gets one callback to that conversation (agreed with the metallm session
2026-09-17):

```json
{ "content": "[Not delivered: the session '<s>' was removed before this prompt could be pasted. It was never seen by the agent.]\n\n<the prompt>",
  "ok": false, "source": "agent_watch", "session": "<s>", "prompt_origin": "orchestrator",
  "interrupted": false, "error_code": "prompt_dropped" }
```

It is retried and dead-lettered like a reply, and the prompt is also written to the send
dead-letter dir. A prompt sent without a `conversation_id` has nobody to tell; only the
dead-letter record remains.

### D6. The tool result envelope

Every MCP tool returns one envelope. An MCP client sees it twice: as a JSON string in
`content[0].text`, and as an object in `structuredContent`. `isError` stays false. A failure is
reported inside the envelope, not through the MCP error flag.

- Success: `{"ok": true, "data": {...}}`.
- Failure: `{"ok": false, "error": "<a sentence for a model or person to read>", "error_code": "<kind>"}`,
  sometimes with `data` for context.

`error_code` lets a caller decide what to do without matching prose (agreed with the metallm
session 2026-09-17). The set is `tools.ERROR_CODES`, and a test fails if any failure path is
missing a code or uses one outside the set:

| Code | Meaning | Caller |
|---|---|---|
| `no_such_session` | the session's container does not exist | tell the person, no retry |
| `queue_full` | 25 prompts already waiting: the session is wedged | tell the person, no retry |
| `out_of_scope` | a scoped server refusing another session (MCP-31) | tell the person, no retry |
| `create_not_allowed` | `session_create` on a scoped server | tell the person, no retry |
| `invalid_argument` | a required argument is missing or invalid | fix the call |
| `not_configured` | the aidc config lacks what the call needs (`metallm.callback_url`) | tell the person |
| `cli_failed` | an `aidc` CLI call exited non-zero | transient: retry once |
| `command_failed` | a command inside the session failed | tell the person |
| `timeout` | a command inside the session ran out of time | tell the person |
| `claude_not_running` / `session_not_ready` / `turn_not_finished` / `paste_failed` | synchronous `session_run` only (`session_send` queues a failed paste) | tell the person |
| `no_reply` / `callback_failed` | `session_resend` found nothing, or its POST failed | tell the person |
| `not_found` | a file or directory the call reads is missing | tell the person |

`session_send` itself only fails with `no_such_session`, `queue_full`, `out_of_scope` or
`invalid_argument`. Every other condition, a failed paste included, queues the prompt. The
metallm side never retries a `session_send`, even after a transport failure (a retry could paste
the prompt twice), and retries a read once on a transport failure or `cli_failed`.

### D7. A webhook survives an `aidc-mcp` restart (MCP-34)

Found in the joint test: after a restart the send queue resumed and pasted its prompt, Claude
answered, and no callback was sent, because webhooks lived only in memory. Now:

- Opening a webhook (`session_watch`, or `session_send` with a `conversation_id`) saves
  `watcher-state/<session>.watch.json` (`session`, `conversation_id`, `callback_base`,
  `updated_at`; atomic write). `session_unwatch` removes it.
- At startup (`server.ResumeOnStartup`), after the send queues, `resume_watchers` reopens every
  saved webhook in scope whose session still exists, and removes the file of one that does not.
  An unreadable file is logged and left in place.
- A resumed webhook does **not** re-anchor the watermark to the end of the transcript, as a new
  one does. It continues from the saved watermark, so a reply written while the MCP was down is
  delivered, and the delivery ledger keeps it to once.

Combinations are independent. An interrupted turn on a prompt the person typed carries
`interrupted: true` and (once enabled) `speaker: "human"`, so MetaLLM records it without waking
the orchestrator and labels it as stopped at the terminal.

---

## Sending

### S1. The transcript decides whether Claude is busy (MCP-28)

Two questions are kept apart, because they have different callers:

- **Is Claude working on a turn?** `_session_state` returns a `SessionState` whose `turn` is
  `running` or `idle`, with `why` naming the evidence. `session_resend`'s "still working"
  warning and `session_run`'s wait for a turn to end (`_wait_for_turn_end`) read only this.
  A person's unsent text, or a prompt Esc put back in the box, does not keep a turn running.
- **May a prompt be pasted now?** `_paste_reason` combines the turn with the screen (S2) and
  returns `""` or a reason (S4's table). `_check_free` is that answer; `session_send` and the
  queue drainer use it. Every change of verdict is logged as `session_free_check` with its
  `why`, so a "free" reached without transcript evidence (no transcript, an unreadable one, the
  status row, a stall) is on record.

**One rule for "Claude stopped".** `_turn_verdict` is shared by the send path and the watcher:

1. The transcript's tail (`transcript.log_shows_turn_in_progress`) says **not working** for a
   finished turn, an interrupt marker, an API error, a turn waiting on an interactive-input
   tool, a local command's output (`/login`, `!` bash mode), or an empty transcript. It says
   **working** for a prompt with no reply, a tool call or result, an unanswered Stop-hook
   pushback, or a reply whose Stop hooks have not reported yet.
2. A turn the transcript shows in progress is **working** while the transcript has been quiet
   for less than 6 s (the mirror copies about every 2 s).
3. A reply still waiting on its Stop hooks stays **working** until 120 s of quiet
   (`_STOP_HOOK_WAIT_S`, the same hold the watcher's delivery uses, D1), whatever the screen
   shows.
4. Past that hold, and for any other quiet open turn, the status row decides: `esc to interrupt` means **working** (a long silent tool
   call, or thinking before the first line). Its absence means **stopped**, trusted once this
   MCP process has seen the working text on that session's screen; until then, only after 10
   minutes of quiet. So a Claude Code that renames the text costs a slow queue, never a paste
   into a running turn. The send path learns the text on its own screen reads; the watcher
   reads the screen while a turn is in progress until it has seen it once.

**Pasting requires two consecutive free readings**, 2.5 s apart (past the mirror's copy
interval, so both cannot come from the same stale copy), in `_wait_until_free`. That catches a
turn starting the moment another ends (a background task's notification). The drainer re-checks
once more under the send lock right before pasting, and `_wait_for_turn_end` likewise needs two
idle readings. `session_resend` takes a single reading: it only labels a reply, it does not paste.
Pane byte-stability (`_wait_for_idle`) and pane-scraped replies (`_extract_delta`, `_strip_ansi`)
are gone; `session_run` reads each reply from the transcript, starting at its prompt's line.

**After a paste, busy until the transcript shows it.** Right after a paste the mirrored
transcript still shows the previous finished turn. `_inject` marks the session busy
(`sent_prompt_not_in_log`) and starts `_watch_for_echo`, which clears the mark once the transcript
shows the prompt: a `user` line with the same text (or, for a slash command, its rendered
`/name args`), or a `queue-operation` enqueue with that text when it was pasted into a running
turn. After 30 s without it, the mark is cleared and `session_send_not_seen_in_transcript` is
logged, whether or not anything checks the session again.

[DECISION: a prompt that never shows in the transcript is logged, not re-sent | a paste whose
tmux commands returned success almost always landed (a lagging or rotated transcript is the likelier
cause), and a duplicate prompt answered twice is worse than a missing log line | Pace can veto]

**Esc before Claude writes anything.** Claude Code writes no marker, so the transcript shows a
prompt with no reply. The watcher reports it (D3) when `_turn_verdict` says stopped on two
consecutive polls with Claude running at its input box: an interrupted turn anchored on the
prompt's line, with "Claude had not written anything yet", delivered once and consuming the
sent-record entry. Until it has reported that prompt, the send path holds a session with an open
watcher as `interrupt_not_reported_yet`, so the orchestrator hears about the interrupt before its
next prompt lands. A tail made of a local command's output or a background task's notification is
never reported; a slash command with no output (a skill Claude was about to run) is.

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
- **Not at prompt:** no such box row, with a dialog footer (`Enter to confirm` / `Esc to cancel`),
  as on the folder-trust menu at first launch (`❯` used as a menu cursor, no `─` box).
- **Unrecognized:** no box row and no dialog footer. A bare shell after `/exit` looks like this,
  but the send path reports that as "Claude not running" (`pane_current_command` is `bash`)
  before reading the screen, so in practice this is a layout aidc does not know.
- **Colour codes:** only the SGR intensity attribute counts as dim. The numbers inside an
  extended colour (`38;5;N`, `38;2;R;G;B`, and the 48/58 forms) are skipped, so a `2` there is not
  mistaken for dim.

Cursor position was recorded (x=2 on an empty box row) but is not needed: the row content decides.

When the screen cannot be classified (a Claude Code redesign), the send path treats it as **not
safe to type** and says so (S3). An unrecognized screen holds prompts; it never types into them.

### S3. Waiting for the person, visibly (MCP-29)

When the input box holds unsent text, a prompt is not injected. It stays queued, and the tmux
status line of the session shows:

```
aidc: orchestrator message waiting — press Enter or clear your input
```

The line is set when the queue's first prompt starts waiting on input-box text, and cleared as
soon as that prompt is pasted or waits for a different reason. The MCP sets and unsets the tmux
user option `@aidc_waiting`; `tmux-start.sh` shows it in `status-right`, in reverse video, in
place of the window title and clock while it is set. tmux cuts an over-long `status-right` from
its start, so the message is kept short enough to show whole on an 80-column terminal, and
`tests/unit/test-tmux-status-line.sh` renders the real status line at that width. A session created
before this change has no such `status-right` and shows nothing until it is recreated on the new
image.

The check runs again immediately before the paste, under the send lock, so the window in which a
person can start typing between check and paste is milliseconds. It cannot be closed entirely.

### S4. A queue that never gives up (MCP-30)

The per-session queue keeps FIFO order and the existing lock discipline, and changes in five
ways:

1. **No wait deadline.** A prompt waits as long as its session exists. The drainer waits for the
   session to be free in 60 s rounds, recording the latest reason after each.
2. **Held while Claude is not running.** A stopped Claude (restart, crash, the person exited it)
   holds the queue. `session_send` itself queues instead of refusing; it refuses only a session
   whose container does not exist. Pasting resumes when Claude is back at its prompt.
3. **Paste failures retry** with backoff (2, 4, 8 … s, capped at 60 s) and no attempt limit;
   each is logged and shown as `paste_failing`. A failed paste in `session_send` itself queues
   the prompt the same way.
4. **Persisted.** The queue is written to the watcher-state dir (atomic temp+rename, like the
   watermark) on every change; an emptied queue removes its file. When `aidc-mcp` starts
   (`server.ResumeOnStartup`, on the ASGI lifespan start), `resume_send_queues` gives each
   persisted queue a drainer, and dead-letters the queue of a session whose container is gone. An
   unreadable queue file is logged and left in place. Loading a saved queue happens once per
   process, under the session's send lock, from whichever comes first: startup resume or a
   `session_send` to that session. Saved prompts always go ahead of new ones.
5. **The only exits** are "pasted" and "session gone": its container no longer exists, or a
   container of the same name has a different id than when the prompt was accepted (killed and
   re-created; each prompt records the id, so the new session is never handed the old one's
   prompts). A gone prompt is written to the send dead-letter dir with reason `session_killed`
   and reported to its conversation (D5, `prompt_dropped`). Docker failing to answer is neither.

**Why a prompt is waiting** is always one of a closed set, reported in the `session_send` result
when it queues (`waiting_reason`, plus a sentence in `delivery`) and in `session_status`'s
`send_queue` for every waiting prompt (a 120-character preview, `enqueued_at`, `waiting_reason`,
a plain-language `waiting_because`, and `paste_attempts`):

| Reason | Meaning |
|---|---|
| `claude_busy` | the transcript shows a turn in progress |
| `input_has_text` | the person has unsent text in Claude's input box |
| `claude_not_running` | the `claude` window is at a shell |
| `claude_not_at_prompt` | Claude is running and showing a dialog (e.g. the folder-trust or login screen) instead of its input box |
| `screen_unrecognized` | Claude is running but the screen is neither its input box nor a known dialog; the capture is saved to `watcher-state/screens/<session>-unrecognized.ansi` for whoever updates `screen.py` |
| `paste_failing` | the paste did not land; retrying |
| `queued_behind` | an earlier prompt in the queue is waiting |

The queue-depth cap (25) stays: it refuses a *new* prompt audibly at the door; it never drops an
accepted one.

**Persisted format.** A persisted queue locks in a schema, so its questions come first. What reads
it: the MCP on restart (to resume draining), `session_status` (to report), and a person
inspecting the MCP's `watcher-state/` dir after an incident. The questions it answers: which
prompts are waiting for which session, in what order, since when, how many paste attempts each
has had, and the last recorded waiting reason. File:
`watcher-state/<session>.send-queue.json`, one object per session:

```json
{ "session": "metallm",
  "updated_at": "2026-09-17T12:00:00Z",
  "prompts": [
    { "text": "...", "enqueued_at": "2026-09-17T11:58:02Z",
      "paste_attempts": 0, "waiting_reason": "input_has_text",
      "conversation_id": "...", "container_id": "..." } ] }
```

`conversation_id` is where to report the prompt if it is dropped (`""` without a webhook);
`container_id` is the session's docker id when the prompt was accepted.

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

- Requirements: MCP-15..19, MCP-23, MCP-24..30, MCP-32..34 (`docs/requirements.md`).
- Delivery path: `mcp/src/aidc_mcp/transcript.py` (`extract_completed_turns`, `human_prompt_text`),
  `mcp/src/aidc_mcp/tools.py` (`_drain_once_body` settle gate, `_post_turn`).
- Send path: `mcp/src/aidc_mcp/tools.py` (`session_send`, `_drain_pending_sends`,
  `_enqueue_send`, `_inject`, `_session_state`, `_turn_verdict`, `_paste_reason`, `_check_free`,
  `_wait_until_free`, `_wait_for_turn_end`, `_watch_for_echo`, `_load_persisted_queue`,
  `_drop_prompts_of_removed_session`, `_notify_dropped`, `resume_on_startup`, `resume_watchers`,
  `session_run`, `session_resend`);
  `mcp/src/aidc_mcp/screen.py` (`classify`).
- Transcript mirror: `.devcontainer/transcript-mirror.sh`. tmux session: `.devcontainer/tmux-start.sh`.
- MetaLLM callback contract: `api/src/api/v1/internal/callback.py` in the metallm repo.
