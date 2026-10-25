# Design 10 — Turn State from the Transcript, and a Send Queue That Never Drops

**What this covers.** Two halves of how the MCP server works with the shared Claude session in
a dev container's tmux `claude` window:

- **Delivery** (Claude → orchestrator): when a turn is really finished, what is delivered for
  an interrupted turn, and how the payload says who the turn belongs to.
- **Sending** (orchestrator → Claude): how the MCP decides Claude is free to receive a prompt,
  how it avoids typing over a person's unsent text, and how the per-session queue holds prompts
  until they land.

**Requirements implemented:** MCP-24 .. MCP-30, MCP-32 .. MCP-37 and MCP-40 .. MCP-43 (`docs/requirements.md`). Extends MCP-15..19 and
MCP-23; builds on `docs/done/design-09-callback-delivery.md`.

**Status:** designed and built 2026-09-17 (branch `feature/turn-state`). D4's `speaker` is built
behind `metallm.send_speaker`, off until MetaLLM's side is deployed. Transcript and screen facts measured in a dev container on Claude Code
2.1.270 and 2.1.274 the same day. D7, D8 and the dropped-prompt callback in D5 came out of the
joint test with the metallm session that day.

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
| That removal is a `queue-operation` `remove` with `reason: "absorbed_mid_turn"`, followed by an `attachment` of type `queued_command` carrying the prompt. If the turn ends first, Claude Code runs the prompt as the next turn, written as a `user` line with `promptSource: "queued"` | metallm transcript, Claude Code 2.1.300, 2026-10-22 |
| A notification line opens with `<task-notification>`; read as local output it made a notification turn look idle until Claude's first line, and a paste in that gap joined the new turn | metallm, 2026-10-22 19:19:35-40 |
| A message from another Claude session is an `isMeta` `user` line with `origin.kind` `peer` (or `coordinator`), and Claude runs a turn on it | host transcripts, 2026-10-22 |

Raw notes and captures: `.prawduct/artifacts/claude-code-measurements.md`.

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

**Built behind a setting** (Pace, 2026-09-17). `metallm.send_speaker: true` in the aidc config
turns it on; off (the default) leaves the payload unchanged. The metallm session corrected an
assumption on the way: the released MetaLLM (v0.46.0) already reads `speaker` and drops `human`
turns, so sending it unconditionally before its deploy would hide typed turns rather than change
nothing. The setting lets the joint test prove the whole path against metallm's dev instance while
the live MCP keeps it off. Turn it on only once the metallm session confirms record-without-wake
is released and deployed, and the production host's running version is checked. It is not sent on
the `prompt_dropped` and `prompt_waiting` notices, which are not replies.

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
| `prompt_origin` | string | `"terminal"` if any prompt the turn answers was typed at the pane; else `"person"` if the MCP sent one for a person (`session_send`'s `sent_by`); else `"orchestrator"` if all were sent by the MCP for the caller; `""` if the turn had no prompt and none came before it. A turn with no prompt of its own (a continuation, a task notification) carries the origin of the session's last prompted turn. MetaLLM records a `"terminal"` or `"person"` reply as addressed to that person, not as a report on its own prompt. | MCP-23 |
| `sent_by` | string | Present only with `prompt_origin: "person"`: the `sent_by` the caller gave `session_send`, returned as given. The orchestrator names who the prompt was for; aidc does not read it. | 2026-10-09 |
| `interrupted` | bool | `true` when the turn was cut off by Esc at the terminal (D3), else `false`. Always sent. | MCP-26 |
| `speaker` | string | `"human"` when every prompt the turn answers was typed at the terminal, else `"agent"`. Sent only on replies, and only with `metallm.send_speaker: true` (D4), which stays off until MetaLLM's record-without-wake change is deployed. | MCP-27 |
| `error_code` | string | Present only on a callback that is not a reply, naming what it is: `"prompt_dropped"` (a failure, `ok: false`) or `"prompt_waiting"` (a status, `ok: true`), both below. It never says anything `content` does not. | MCP-33, MCP-36 |
| `prompts` | list | The `session_send` prompts the turn answers, in paste order, each `{"prompt_id", "sent_by", "conversation_id"}` (`sent_by` `""` for the caller's own; `conversation_id` the conversation that sent it, which may differ from the one this callback goes to). One entry for a prompt pasted alone, several for a batch (S7). A continuation carries its turn's. Absent when no paste of the MCP's opened the turn (a prompt typed at the pane, a task notification with nothing before it) and on `session_resend`. On `prompt_dropped` and `prompt_waiting` it names the one prompt the notice is about. | MCP-44 |
| `pasted_at` | string | ISO UTC time the batch carrying those prompts was pasted (the latest paste, when one turn answers several). Present exactly when `prompts` is, on replies. | MCP-44 |

**A prompt that will never be pasted** (MCP-33). A queued prompt leaves the queue unpasted only
when its session is gone: it no longer exists, or a session of the same name is a different
instance because it was killed and created again (S4 item 5). Each such prompt that came with a
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

**A prompt that has waited long** (MCP-36; proposed by the metallm session, approved by Pace
2026-09-17). The orchestrator is told a queued prompt will go in when the session is free, and
by design it does not poll, so a queue that never moves (a bug, a forgotten dialog, text left in
the box) would otherwise leave it waiting in silence. A queued prompt with a `conversation_id` that
has waited 10 minutes (`AIDC_MCP_PROMPT_WAITING_S` overrides it, for tests) gets one callback,
once, with the flag persisted in the queue file so a restart does not repeat it:

```json
{ "content": "[Still waiting: this prompt has been queued for the session '<s>' for N minutes, because <reason>. It has not been seen by the agent yet. It will still go in when the session is free.]\n\n<the prompt>",
  "ok": true, "source": "agent_watch", "session": "<s>", "prompt_origin": "orchestrator",
  "interrupted": false, "error_code": "prompt_waiting" }
```

`<reason>` is `session_status`'s `waiting_because` for the queue's first prompt; a prompt behind
it reads "an earlier prompt is still waiting (held because <that reason>)". `ok` is true: nothing
has failed, and MetaLLM renders `ok: false` as an error, which invites a resend (the metallm
session's objection, accepted). The drainer checks once per round, so the notice can be up to about
a minute late. If the prompt is pasted later, its reply follows as usual; if the session goes,
`prompt_dropped` follows.

### D6. The tool result envelope

Every MCP tool returns one envelope. An MCP client sees it twice: as a JSON string in
`content[0].text`, and as an object in `structuredContent`. `isError` stays false. A failure is
reported inside the envelope, not through the MCP error flag.

- Success: `{"ok": true, "data": {...}}`.
- Failure: `{"ok": false, "error": "<a sentence for a model or person to read>", "error_code": "<kind>"}`,
  sometimes with `data` for context.

`error_code` lets a caller decide what to do without matching prose (MCP-32, agreed with the
metallm session 2026-09-17). The set is `tools.ERROR_CODES`, and a test fails if any failure path is
missing a code or uses one outside the set:

| Code | Meaning | Caller |
|---|---|---|
| `no_such_session` | the session does not exist (its network is gone) | tell the person, no retry |
| `queue_full` | 25 prompts already waiting: the session is wedged | tell the person, no retry |
| `out_of_scope` | a scoped server refusing another session (MCP-31) | tell the person, no retry |
| `create_not_allowed` | `session_create` on a scoped server | tell the person, no retry |
| `invalid_argument` | a required argument is missing or invalid | fix the call |
| `not_configured` | the aidc config lacks what the call needs (`metallm.callback_url`) | tell the person |
| `cli_failed` | an `aidc` CLI call exited non-zero | transient: retry once |
| `command_failed` | a command inside the session failed | tell the person |
| `timeout` | a command inside the session ran out of time | tell the person |
| `claude_not_running` / `session_not_ready` / `turn_not_finished` / `paste_failed` | synchronous `session_run` only (`session_send` queues a failed paste); `session_not_ready` also from `session_mcp_set` on a session whose first start has not finished | tell the person |
| `no_reply` / `callback_failed` | `session_resend` found nothing, or its POST failed | tell the person |
| `not_found` | a file or directory the call reads is missing | tell the person |
| `path_not_allowed` | `session_create`: a `repo` or `workspace` outside the directory the operator exposed to this server (MCP-38) | fix the call |
| `tainted` | the session is tainted: `session_send`, `session_resend`, `session_invoke`, `session_invoke_async`, `session_exec` and `file_put` put nothing into it; `data.tainted` says when and why | tell the person, no retry |
| `outside_repo` | `file_get`, `file_list`, `file_search`, `repo_diff`, `repo_log`: a path outside the session's repository, or a symlink in it that points out | fix the call |
| `invoke_busy` | `session_invoke` / `session_invoke_async`: a headless run is already going in the session (one at a time per session, S6); `data.running` names it (`run_id`, `started_at`, `tool`, `prompt`, `pid`, `orphan`) | wait, stop it with `session_interrupt` `target: "headless"`, or use `session_send` |

`session_send` itself only fails with `no_such_session`, `queue_full`, `out_of_scope`, `tainted`, or `invalid_argument` for a `deliver` other than `"queue"` or `"join"`. Every other condition, a failed paste and a declined join included, queues the prompt. The
metallm side never retries a `session_send`, even after a transport failure (a retry could paste
the prompt twice), and retries a read once on a transport failure or `cli_failed`.

### D7. A webhook survives an `aidc-mcp` restart (MCP-34)

Found in the joint test: after a restart the send queue resumed and pasted its prompt, Claude
answered, and no callback was sent, because webhooks lived only in memory. Now:

- Opening a webhook (`session_watch`, or `session_send` with a `conversation_id`) saves
  `watcher-state/<session>.watch.json` (`session`, `conversation_id`, `callback_base`,
  `session_instance`, `updated_at`; atomic write). `session_unwatch` removes it.
- At startup (`server.ResumeOnStartup`), after the send queues, `resume_watchers` reopens every
  saved webhook in scope whose session still exists, and removes the file of one whose session
  is gone or is a different instance (killed and created again: the new session was never asked
  to report to that conversation; an upgraded session is the same instance and keeps it). An
  instance that cannot be read keeps the webhook. An unreadable file
  is logged and left in place. A failure resuming the queues does not stop the webhooks resuming.
- A resumed webhook does **not** re-anchor the watermark to the end of the transcript, as a new
  one does. It continues from the saved watermark, so a reply written while the MCP was down is
  delivered, and the delivery ledger keeps it to once.

### D8. A reply in a new transcript after Claude restarts (MCP-35)

Found in the joint test (scenario 10): Claude exited, a prompt waited in the queue as
`claude_not_running`, Claude restarted with `--continue` into a **new** transcript file, took
the prompt within seconds and answered. The watcher moves onto a new file only after the old one
has sat fully read for a few polls, and it anchored at the new file's end, so the answer was
already behind the anchor and was never delivered.

When the watcher moves onto a new transcript (the stale-pin follow, the torn-read recovery, or
the pinned file disappearing), it now resumes **after the last line written no later than when
it last saw activity**: the newest line timestamp in the file it is leaving, or, when that file is
gone, the watermark's last save. Lines after that point happened while it was still on the old
file and are delivered; lines up to it are history (a resumed session may carry some) and are not
replayed. That point is never earlier than the conversation's last forward (re)anchor
(`baselined_at` on the watermark): a conversation that watches again after Claude moved to a new
file while nobody watched is not caught up with the work done in between (MCP-17). The log events
for a move (`transcript_stale_pin_recovered`, `transcript_rotated`) record the anchor line, the
point it resumed after, and whether nothing was known so it anchored at the end. The delivery
ledger still blocks any second delivery.

**A transcript the watcher can no longer resume in** (MCP-37). The pinned file can lose the line
the watermark resumes from for good: a torn final line from a session killed mid-write, or a
compaction. Before following a newer session, the watcher looks in the file it is leaving for
completed turns after its resume point (as above, never earlier than the last (re)anchor) whose
content is not in the delivery ledger. If it finds any, it re-anchors there and the ordinary pass
delivers them; the stale-pin follow moves on once the file holds nothing new. Skipping straight to
the newer file, as the first build did, lost every reply left in the damaged one, and nothing else
would have sent them. `session_resend` reads the session's other transcript files too, newest
first, so a reply from before a restart can still be fetched by hand. Measured on Claude Code 2.1.274:
`--continue` starts a new file holding only the new session's lines, not a copy of the old ones.

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
   tool, a local command or its output (`/clear`, `/login`, `!` bash mode), or an empty
   transcript. It says **working** for a prompt with no reply, a tool call or result, an
   unanswered Stop-hook pushback, or a reply whose Stop hooks have not reported yet.

   **A local command opens no turn.** Claude Code runs `/clear`, `/model`, `/login` itself and
   Claude never replies, yet the command is written as an ordinary `user` line, the same shape
   as a skill's command, which Claude does answer. Its neighbours tell them apart (measured on
   Claude Code 2.1.222 to 2.1.287): a local command comes right after the isMeta
   `<local-command-caveat>` line, and one that prints nothing to the conversation (`/clear`) is
   followed by a `system` / `local_command` line. Either mark makes it local
   (`transcript.is_local_command`), and every reader (`log_shows_turn_in_progress`,
   `unanswered_prompt_turn`, `extract_completed_turns`) treats it as it treats a local
   command's output: no turn, no unanswered prompt, no prompt on the next turn. Until
   2026-10-08 a command line counted as a prompt, so after a pasted `/clear` the turn read as
   running until the transcript had been quiet for `_LOG_STALL_S`, and every prompt queued
   behind it waited as `claude_busy`.
2. A turn the transcript shows in progress is **working** while the transcript has been quiet
   for less than 6 s (the mirror copies about every 2 s).
3. A reply still waiting on its Stop hooks stays **working** until 120 s of quiet
   (`_STOP_HOOK_WAIT_S`, the same hold the watcher's delivery uses, D1), whatever the screen
   shows.
4. Past that hold, and for any other quiet open turn, the screen decides. `esc to interrupt` on
   the status row means **working** (a long silent tool call, or thinking before the first
   line). Otherwise, an input box holding exactly a prompt the transcript shows unanswered
   (compared ignoring whitespace, since the box wraps and indents) means **stopped**
   (`prompt_restored`): Claude Code puts the prompt back when Esc is pressed before it writes
   anything. Failing both, the working text's absence means **stopped**, trusted once the MCP
   has seen that text on the session's screen; until then, only after 10 minutes of quiet. So a
   Claude Code that renames the text costs a slow queue, never a paste into a running turn. The
   send path learns the text on its own screen reads; the watcher reads the screen while a turn
   is in progress until it has seen it once. Having seen it is remembered in
   `watcher-state/<session>.working-text-seen`, so a restart does not forget it. The marker
   records the session instance it was seen on (S4 item 5), and one from another instance is
   ignored and removed, so a session killed and created again under the same name, perhaps on a
   Claude Code whose working text reads differently, never inherits it; when the instance changes
   while the MCP runs, everything the send path knew about the old one is forgotten
   (`_sync_session_markers`).

   The joint test showed why both matter: an MCP restarted a minute before an Esc pressed 1 s
   into a turn had never seen the working text, and reported the interrupt only after the
   10-minute fallback.

**Pasting requires two consecutive free readings**, 2.5 s apart (past the mirror's copy
interval, so both cannot come from the same stale copy), in `_wait_until_free`. That catches a
turn starting the moment another ends (a background task's notification). The drainer re-checks
once more under the send lock right before pasting, and `_wait_for_turn_end` likewise needs two
idle readings. `session_resend` takes a single reading: it only labels a reply, it does not paste.
The wait is bounded on the clock as well as in polls: after a reading that was not free, no
reading starts that could not finish inside the timeout, so slow readings do not stretch the free
wait in `session_send` (`_SEND_FREE_WAIT_S`). A free reading is always followed by its confirming
second reading, which can run past the timeout by one poll, so a free session is not reported
busy. The paste that may follow adds its own few docker calls. A session not confirmed free in
time is queued for the drainer.
Pane byte-stability (`_wait_for_idle`) and pane-scraped replies (`_extract_delta`, `_strip_ansi`)
are gone; `session_run` reads each reply from the transcript, starting at its prompt's line.

**After a paste, busy until the transcript shows it.** Right after a paste the mirrored
transcript still shows the previous finished turn. `_inject` marks the session busy
(`sent_prompt_not_in_log`) and starts `_watch_for_echo`, which clears the mark once the transcript
shows the prompt: a `user` line with the same text (or, for a slash command, its rendered
`/name args`), or a `queue-operation` enqueue with that text when it was pasted into a running
turn. "The same text" ignores whitespace and a `<pasted_content id="X">` wrapper Claude Code
puts around a whole paste (measurement T13); `normalize_prompt` applies both rules, and the send
record's fingerprint, this hold and `prompt_restored` all compare through it. A pasted local command (`/clear`) shows as its command line and counts as arrived. When
the prompt arrived as a queued message or as a local command, no turn will ever claim it, so
`_prompt_arrived` gives its send record back there. After 30 s without it, the mark is cleared and `session_send_not_seen_in_transcript` is
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
next prompt lands. Once reported, that prompt's turn is over (`interrupt_reported`) unless the
status row shows Claude working, and the report is kept, with its session instance, in
`watcher-state/<session>.interrupt-reported`: the
watcher's watermark is past the prompt by then, so after a restart nothing would report it again,
and a session remembered only in memory read busy for good (found in the joint test, when a
queued prompt waited behind an interrupt reported before a restart). A tail made of a local command, its output, or a background task's notification is
never reported; a slash command with no local-command mark (a skill Claude was about to run) is.

### S2. What the screen is still read for (MCP-28, MCP-29)

Only three things, each invisible to the transcript:

1. **Unsent text in Claude's input box.** The transcript records a prompt only after it is sent.
2. **Whether Claude is at its input prompt at all.** After a start or restart, Claude can be on a
   login, trust, or startup screen while the transcript's last turn reads closed.
3. **Whether `esc to interrupt` is on the status row, and what text the input box holds**, and
   only when the transcript shows an open turn that has gone quiet (S1). Never used while the
   transcript can answer.

Both are read from one `capture-pane -e` of the `claude` window (with escape sequences, so text
attributes are visible). Measured on Claude Code 2.1.270 and 2.1.274:

- **The input box** is the region between the last two full-width `─` rules near the bottom of
  the pane; the status row sits directly below the second rule. From 2.1.284 the top rule of a
  named session carries its name (`──── metallm ─`), so a rule may hold one label set off by
  spaces. From 2.1.300, while background agents run, a blank row and one row per agent
  (`  ● main`, `  ◯ general-purpose  <activity>`) follow the status rows; that list is set aside
  before the rows below the box are counted, and a row with an unmeasured glyph fails closed.
  The row under the mouse, or the one selected from the keyboard, carries the pointer `❯ ` (a
  plain space) in place of its indent. A keyboard selection also replaces the permission-mode
  status row with the list's key hints (`↑/↓ to select`, `Enter to view · x to stop`); a hover
  changes nothing else (measured on Claude Code 2.1.304, 2026-10-22). While the list has the
  keyboard, a burst of several characters still lands in the input box, but a single character
  is a list key (`x` stopped the selected agent) and Enter opens an agent. So a screen with the
  key hints is not pasted into at all (`agent_list_selected`: a person is in the list). With only
  the pointer (a hover), the prompt is pasted, and `_inject` presses Enter only once the input box
  shows text. A paste that has not shown there after about 1.5 s is left unsubmitted and the
  attempt counts as failed (`paste_failing`). If the text appears later, the next free check
  recognizes it as that prompt (its words, or Claude Code's `[Pasted text …]` placeholder), not as
  a person's unsent input, and `_inject` presses Enter on it without pasting it again. Other text
  in the box still holds the queue as `input_has_text`.
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
   that does not exist. Pasting resumes when Claude is back at its prompt.
3. **Paste failures retry** with backoff (2, 4, 8 … s, capped at 60 s) and no attempt limit;
   each is logged and shown as `paste_failing`. A failed paste in `session_send` itself queues
   the prompt the same way.
4. **Persisted.** The queue is written to the watcher-state dir (atomic temp+rename, like the
   watermark) on every change; an emptied queue removes its file. When `aidc-mcp` starts
   (`server.ResumeOnStartup`, on the ASGI lifespan start), `resume_send_queues` gives each
   persisted queue a drainer, and dead-letters the queue of a session that is gone. An
   unreadable queue file is logged and left in place at startup (its session's name is inside
   it); the first send to that session renames it to `<file>.unreadable-<time>` before saving,
   so it is kept for a person rather than overwritten. Loading a saved queue happens once per
   process, under the session's send lock, from whichever comes first: startup resume or a
   `session_send` to that session. Saved prompts always go ahead of new ones.
5. **The only exits** are "pasted" and "session gone": the session no longer exists, or a
   session of the same name is a different instance than when the prompt was accepted (killed
   and re-created; each prompt records the instance, so the new session is never handed the old
   one's prompts). A session is identified by its network, `aidc-<session>-net`: `aidc create`
   makes it, `aidc kill` removes it, and `aidc upgrade` and `aidc restart` keep it while they
   replace or restart the dev container. So an upgrade keeps its queue, and a dev container
   briefly missing in the middle of one is not a gone session. `aidc kill` removes port
   forwarders before `docker compose down` and then makes sure both session networks are gone
   (`remove_session_networks`): compose leaves a network that an outside container is still
   attached to, exiting 0, and a leftover network would keep a killed session alive here and hand
   a session created again under the name its predecessor's prompts. `aidc create` removes such a
   leftover before it starts, and `aidc kill` on a name with no containers but a leftover network
   removes the network. The drainer checks this at the start of each round and again under the send lock
   right before pasting, since its wait for a free session can outlast a kill and re-create. A
   gone prompt is written to the send dead-letter dir with reason `session_killed`
   and reported to its conversation (D5, `prompt_dropped`). Docker failing to answer is neither.

**Why a prompt is waiting** is always one of a closed set, reported in the `session_send` result
when it queues (`waiting_reason`, plus a sentence in `delivery`) and in `session_status`'s
`send_queue` for every waiting prompt (a 120-character preview, `enqueued_at`, `waiting_reason`,
a plain-language `waiting_because`, and `paste_attempts`):

| Reason | Meaning |
|---|---|
| `claude_busy` | the transcript shows a turn in progress |
| `input_has_text` | the person has unsent text in Claude's input box |
| `agent_list_selected` | the person has the keyboard in Claude Code's background-agent list, where typed keys are list commands |
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
      "conversation_id": "...", "session_instance": "...", "waiting_notified": false,
      "sent_by": "", "prompt_id": "p-0123456789abcdef" } ] }
```

`prompt_id` is the id `session_send` returned (a queue saved before ids existed gets fresh ones
on load); `conversation_id` is where to report the prompt if it is dropped (`""` without a webhook);
`session_instance` is the session's network id when the prompt was accepted; `waiting_notified`
is true once its conversation has been told it is still waiting (D5).

Prompt text is stored as the queue receives it (already newline-flattened by `session_send`).
Same trust level as the existing send record and dead-letter files, which already store prompts.

### S5. What a busy session is doing, and joining its turn (MCP-40, MCP-41)

2026-10-22, metallm: an orchestrator's prompt waited 45 minutes (`claude_busy`) behind one
turn a background task's notification had opened, while `session_status.working_on` named the
person's previous prompt, answered before the turn began. `working_on` was the newest prompt
`human_prompt_text` attributes to a person, and that skips every prompt Claude Code raises
itself. Pace decided the same day that callers should see what a turn is and be able to join it.

**The open turn** (`transcript.open_turn`). Whether a turn is open is
`log_shows_turn_in_progress`'s answer (S1), the one rule the send path, the watcher and
`session_status` use, so the turn fields never describe a turn that ended on an API error or a
question to the user; a test checks the two agree at every line of every fixture. What opened it
is found by one pass over the transcript already read: a real prompt opens a turn (back-to-back prompts with no reply between them are one turn,
named by the newest); an `isMeta` message (another session's message, an auto-continue) opens one
only when no turn is open or the reply before it had ended; a `turn_duration` record, an interrupt
marker, or a local command closes it. A Stop-hook pushback, a tool result, and a prompt Claude
Code takes into the running turn (its queue-operation and `queued_command` attachment) change
nothing. Assistant work with no opening line before it is a turn whose opener is not in the
transcript.

**What a caller reads** (`turns_view.turn_info`), on `session_status` while `working`, on
`session_interrupt`'s `was_running`, on `session_queue_cancel`'s `running`, and on a
`session_send` that joined or queued as `claude_busy` (a prompt held for any other reason gets the
empty values, under the same rule as `session_status`):

| Field | Meaning |
|---|---|
| `working_on` | The prompt's words when a person or `session_send` opened the turn (redacted, cut to 300); otherwise what started it, said as such: `background task completed: <summary> (task <id>)`, `a message from another Claude session (<from>)`, `something Claude Code started itself, not a prompt`, `a turn whose opening line is not in the transcript`. A system wrapper is never shown as a person's words. |
| `started_by` | `prompt` (a person's or `session_send`'s; `promptSource` typed, queued, suggestion_accepted or sdk, origin human or none), `background_task` (`origin.kind` task-notification, or a `<task-notification>` body), `session_message` (`origin.kind` peer or coordinator), `system` (anything else). Measured over every transcript on the build host: these cover every provenance seen. |
| `turn_started_at` | The opening line's time, UTC. |
| `last_activity` | `{kind: tool_use|text|thinking, name: <tool, for tool_use>, at}` from the newest assistant line of the turn; null before Claude writes anything. A long gap is a stall or one long tool call. |

Not working, `working_on` is `""` and the rest null. The five `session_send_queued_by_claude`
events that evening were pastes that landed as a turn started. One cause was the notification
line itself: it opens with a tag, and `_is_local_output` took it for local-command output, so
`log_shows_turn_in_progress` read idle until Claude's first line. A prompt Claude Code raised
itself is no longer local output, and an `isMeta` session message at the tail reads busy too.

**`session_send(deliver="join")`.** `"queue"` (the default) is unchanged. `"join"` takes one
reading of the session (`_join_running_turn`, under the send lock): idle, it sends as usual
(and, if a turn starts during the usual two-reading wait, tries the join once more); running, it
pastes now through `_inject`, with its send record and echo hold, and returns `status:
"joined_turn"`. The two-reading wait exists to keep a prompt out of a turn just starting, which is
what joining asks for. Claude Code holds the paste as a queue-operation and hands it to the turn
at its next tool boundary; `_prompt_arrived` sees the queue-operation, gives the send record back
(no turn will claim the prompt) and logs `session_send_queued_by_claude`. The answer comes in the
running turn's final reply, delivered as any reply. If the turn ends first, Claude Code runs the
prompt next as a `promptSource: "queued"` line, which no turn attributes; `_prompt_arrived` gives
that record back too.

A join is declined, and the prompt queued as `"queue"` would, with `join_declined` naming why,
when: a prompt is already queued for the session (`queued_behind`: order is kept, a join never
jumps the queue); Claude is not running (`claude_not_running`); a dialog or unknown screen
(`claude_not_at_prompt`, `screen_unrecognized`); the agent list has the keyboard
(`agent_list_selected`); someone has unsent text in the box (`input_has_text`); an interrupt the
watcher has not reported yet (`interrupt_not_reported_yet`: a prompt on top would bury the
report, S1); the session became tainted under the lock (`session_tainted`; a tainted session is
refused at the door already); or the paste failed (`paste_failing`).

### S6. Headless runs: fresh, one at a time, visible, stopped (MCP-42, MCP-43)

2026-10-22, metallm: four `session_invoke` calls (22:48-23:04Z) left two `claude --print` runs
going 23 and 9 minutes later, both editing the same spec file; the caller had given up on the
first and sent a correction. Each resumed the resident agent's whole conversation, because the
image's `aidc-claude` wrapper added `--continue` to every launch with a conversation to resume,
headless included, while the tool promised a fresh Claude. Nothing an orchestrator could call
showed them. Pace's rulings that night: no timeout on `session_invoke`; "only allow one session
invoke at a time per dev container"; long work belongs to `session_send`.

- **Fresh.** The wrapper never adds `--continue` to a `--print` / `-p` run
  (`tests/unit/test-aidc-claude-resume.sh`), and the MCP also passes `AIDC_CLAUDE_RESUME=false`,
  which every image's wrapper honours, so sessions on an older image are fresh too.
- **Its transcript is not the session's.** A headless run writes its own transcript into the
  session's project directory, beside the interactive Claude's, and the mirror copies it. Its
  lines carry `entrypoint: "sdk-cli"` (the interactive Claude's carry `"cli"`). Found in the
  live check (2026-10-23): the watcher followed it as the newest transcript and delivered a
  `session_invoke` answer to the orchestrator as the session's reply. `transcript.
  conversation_files` leaves such a file out of every choice of transcript (the active one, the
  watcher's move to a newer one, `session_resend`'s search, `session_status`). A file no line of
  which names its entrypoint still counts, as before.
- **Tagged.** Each run is started with `AIDC_HEADLESS_RUN=<tool>-<id>` in its environment
  (`headless.exec_argv`). Every process it starts inherits it, which is how the MCP finds the
  whole tree inside the container.
- **One at a time per session.** `_claim_headless` checks and claims under a per-session lock:
  a run this server started counts, and so does any `claude --print` found in the container
  (`headless.container_runs` reads `/proc`), so a run left from before an `aidc-mcp` restart, or
  started any other way, holds the session too. A second call is refused at once with
  `invoke_busy`. `session_invoke_async` claims before it returns.
- **Visible.** `session_status.headless_runs` lists each run: `{run_id, started_at, tool,
  prompt, pid, orphan}` (prompt redacted, cut to 120; `orphan`: no request of this server waits
  on it). A queued or joined `session_send` lists this server's runs in `headless_runs`. A
  `session_invoke` result carries `elapsed_s` and, past a minute, a
  `warning` that long work belongs to `session_send`. (It lists no other run: the guard
  refuses a second one.)
- **Stopped when nobody waits.** `session_invoke` has no timeout. When its handler is cancelled
  or reading the answer fails, the run is stopped in a task of its own: every process carrying its
  tag gets SIGTERM, then SIGKILL after 3 s (`headless.stop`), then the host's `docker exec` is
  killed; logged as `session_invoke_cancelled` with the pids. Measured on MCP SDK 2.3 with the
  2025-11-25 protocol (`tests/test_invoke_cancel_wire.py`, real uvicorn and HTTP client): the SDK
  cancels the handler on `notifications/cancelled` and on a session `DELETE`, but not when the
  client drops the connection. `disconnect.StopInvokeOnDisconnect` watches each `session_invoke`
  call for `http.disconnect` and stops its run (`session_invoke_client_disconnected`,
  `session_invoke_stopped_client_gone`). A client that abandons a call with none of the three
  cannot be seen (metallm's stop button, on the evidence of 23:04Z); the one-at-a-time rule and
  `headless_runs` are what is left for it, with `session_interrupt(target="headless")`. The
  call a stop ended says it was stopped, not that claude failed; an `invoke_busy` refusal names
  the running run's pid as well as its `run_id`.
  `session_invoke_async` keeps its 30-minute limit; past it (or on an error) the run is now
  stopped in the container too, where before only the `docker exec` ended.
- **A stop that fails says so.** docker failing (not started, no answer in time, a non-zero
  exit such as a paused container) is `headless.DockerFailed`, never an empty answer. A failed
  stop is logged as `headless_stop_failed` with docker's error, and the run then shows as an
  orphan; a claim made when the container could not be listed is logged as
  `headless_claim_without_listing`.
- **Stopped on request.** `session_interrupt` takes `target`: `"agent"` (the default, Esc to the
  agent as before) or `"headless"`, which stops the session's headless runs: one this server
  waits on through its own call (which then returns), a tagged orphan by its tag, an untagged one
  by its pid and every process below it (`headless.stop_tree`). It returns `stopped`, always a
  list of the runs, and `pids`; `interrupted` is false, with a `note` saying why, when no run was
  found, the container could not be read, or a stop could not be carried out. A
  `session_invoke_async` stopped before its `docker exec` started is never started.

---

### S7. Batch on free, and cancel by id (MCP-44, MCP-45)

2026-10-25, asked by the metallm session and approved by Pace: while a session is busy, prompts
from the person and the agent pile up and used to go in one per idle, each as its own turn.

**Batch on free.** `session_send` still queues and answers `queued` at once. When the session
is next free, the drainer takes every prompt then waiting (`_next_batch`), joins them in send
order with `" [next message] "` and pastes that once, with one Enter. Not a newline: the paste
goes in through `tmux paste-buffer`, where a newline is Enter and would submit the first prompt
alone, which is also why `session_send` flattens a prompt's own newlines. Each prompt opens
with its own sender line, so the marker only marks where one ends. A prompt queued after the
paste waits for the next free moment. A failed paste keeps the whole batch in place, every
prompt's `paste_attempts` counted. `_next_batch` is the one place that decides what goes in
together, so a later per-prompt delivery choice (pasting one at once, mid-turn) belongs there.

**Prompt ids.** Every `session_send` return carries `prompt_id` (`p-` and 16 hex digits),
made before the send decides between pasting now, joining and queueing, so it is the same on
every path. It is persisted with the queue (S4).

**How replies are routed.** A session has one webhook, so one paste is answered by one
turn whose reply goes to the conversation that holds it, as before. A prompt from another
conversation was told so when it was sent (`reply_goes: "elsewhere"`). What changes is
attribution: `_inject` records the paste once, with the joined text's fingerprint, the batch's
`sent_by` (the last prompt's that names a person, so a person's prompt in the batch makes it
the person's reply, as for a turn answering several prompts) and the batch itself (each
prompt's `prompt_id`, `sent_by`, `conversation_id`, and `pasted_at`). The watcher matches the
turn's prompt to that record as it always did and sends the batch as `prompts` and `pasted_at`
(D5). The prompt-origin record carries the batch too, so the continuation that finishes the
work names the same prompts. The receiver attributes per prompt from `prompts`.

**Cancel by id.** `session_queue_cancel(prompt_id=...)` takes back that prompt only and
answers `outcome`: `cancelled`; `already_pasted`, with `pasted_at` (from
`<session>.pasted-prompts.json`, the last 500 pasted ids, so it holds across a restart); or
`unknown`. `position` keeps working (`outcome: "cancelled"` too), and with neither every
waiting prompt is taken back (`"cancelled"`, or `"nothing_waiting"`); both at once is
`invalid_argument`. Atomic against the paste: the drainer chooses its batch and pastes it while
holding the session's send lock, and the cancel decides under the same lock, so a prompt is in
the pasted batch or cancelled, never both. A batch pasted into the box and not yet submitted
(the late-draw case of S2) counts as pasted: the drainer submits exactly that batch, whatever
queued since waits, and a cancel of one of its prompts is `already_pasted` (`pasted_at` null).

## Out of scope

- A channel into Claude other than the pane. None is known that feeds a running interactive
  session; running `--print` into the same session would give one transcript two writers.
- MetaLLM's handling of `speaker: "human"`. That change belongs to the metallm repo; this design
  only records the ordering constraint.
- Engines other than Claude.
- Detecting permission dialogs. aidc prevents them (`--dangerously-skip-permissions`, and
  `--disallowedTools` for the interactive-input tools, per design 09).

## Cross-references

- Requirements: MCP-15..19, MCP-23, MCP-24..30, MCP-32..37 (`docs/requirements.md`).
- Delivery path: `mcp/src/aidc_mcp/transcript.py` (`extract_completed_turns`, `human_prompt_text`),
  `mcp/src/aidc_mcp/tools.py` (`_drain_once_body` settle gate, `_post_turn`).
- Send path: `mcp/src/aidc_mcp/tools.py` (`session_send`, `_drain_pending_sends`,
  `_enqueue_send`, `_inject`, `_session_state`, `_turn_verdict`, `_paste_reason`, `_check_free`,
  `_wait_until_free`, `_wait_for_turn_end`, `_watch_for_echo`, `_load_persisted_queue`,
  `_drop_prompts_of_removed_session`, `_notify_dropped`, `resume_on_startup`, `resume_watchers`,
  `session_run`, `session_resend`);
  `mcp/src/aidc_mcp/screen.py` (`classify`).
- Turn info and join (S5): `transcript.open_turn`, `turns_view.turn_info`,
  `tools._join_running_turn`, `tools._join_refusal`.
- Headless runs (S6): `mcp/src/aidc_mcp/headless.py`, `mcp/src/aidc_mcp/disconnect.py`,
  `tools._claim_headless`, `tools._stop_headless`, `tools._interrupt_headless`; the wrapper in
  `.devcontainer/Dockerfile` (`aidc-claude`).
- Transcript mirror: `.devcontainer/transcript-mirror.sh`. tmux session: `.devcontainer/tmux-start.sh`.
- MetaLLM callback contract: `api/src/api/v1/internal/callback.py` in the metallm repo.
