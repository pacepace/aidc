---
artifact: build-plan
version: 1
scope: turn-visibility-and-join
branch: feature/turn-visibility-and-join
lifecycle: active
---

# Build Plan — what a busy session is doing, and joining its turn

**Work:** `turn-visibility-and-join` · **Branch:** `feature/turn-visibility-and-join` (off
`develop` e80cfb2, the v1.9.7 content) · **Started:** 2026-10-22 · **Release:** v1.9.8
**Critic mode:** cumulative-final (one boundary review after the last chunk)

## Why

2026-10-22, metallm session: an orchestrator `session_send` at 18:33:32 was queued as
`claude_busy` and pasted at 19:18:30. The agent was really busy, in one 47-minute turn opened
by a background task's `<task-notification>` (18:31:12 to 19:18:24). During that turn
`session_status.working_on` named the previous, already-answered human prompt, because
`turns_view.working_on` returns the newest `human_prompt_text`, which skips system-sourced
prompts. A caller could not tell that the agent was mid-flight on something else, or for how
long, or whether it was progressing; and its only choices were to wait or to interrupt. Five
times that evening a paste landed just as a turn started and Claude took it into the running
turn (`session_send_queued_by_claude`), and the reply came back normally: joining a running
turn already works, by accident. Pace (2026-10-22) said yes to making it deliberate.

## Confidence check

- **Problem:** a caller cannot see what opened a running turn, when, or whether it is still
  moving; `working_on` is wrong for a turn not started by a prompt; and a send to a busy session
  can only queue behind the whole turn.
- **Success:** `session_status` (and `session_interrupt`'s `was_running`, and a queued
  `session_send`) says `working_on`, `started_by`, `turn_started_at`, `last_activity`; on the
  real metallm transcript the 18:31-19:18 turn reads `started_by: background_task`,
  `turn_started_at: 2026-10-22T18:31:12…Z`. `session_send(deliver="join")` to a busy session at
  an empty input box pastes now, returns `status: "joined_turn"`, the prompt arrives as a
  queue-operation (`session_send_queued_by_claude`), and the reply comes in that turn's final
  answer. Default `deliver` is exactly today's behaviour.
- **Out of scope:** interrupting on the caller's behalf; joining when an earlier prompt waits
  in the queue (order is kept); any change to the callback payload; `session_list`.

**Requirements Confidence: High** for the fields and the join rules (spec from Pace, 2026-10-22).
Medium on one point: the `started_by` value for a prompt Claude Code marks `promptSource:
"sdk"` (claude.ai remote control) with no origin. [ASSUMPTION: it is a person's prompt —
`prompt` — and its words are shown; it carries no wrapper tag, and a line that opens with one is
never shown as words.]

## Requirements

- **MCP-40** (new): what a running turn is doing — `working_on`, `started_by`,
  `turn_started_at`, `last_activity` — on `session_status`, `session_interrupt` and a queued
  `session_send`.
- **MCP-41** (new): `session_send(deliver="join")`.

## Design decisions

- [DECISION: `started_by` is one of `prompt` | `background_task` | `session_message` |
  `system`, read from the line that opened the open turn: `origin.kind` `task-notification` (or
  a `<task-notification>` body) → background_task; `peer` / `coordinator` → session_message;
  a person's or the MCP's prompt (`origin.kind` human or absent, `promptSource` typed, queued,
  suggestion_accepted or sdk, no wrapper tag) → prompt; anything else (an auto-continue, a
  scheduled wake-up, a turn whose opening line is not in the transcript) → system. Measured
  over every transcript on this host (2026-10-22): these cover every provenance combination
  seen.]
- [DECISION: the open turn is found by one forward scan of the transcript already read: a
  real prompt opens a turn; an isMeta message (another session's message, a notification) opens
  one only when no turn is open or the last assistant line ended a reply; a `turn_duration`,
  interrupt marker or local command closes it. A Stop-hook pushback continues it.
  `working_on`/`started_by`/`turn_started_at`/`last_activity` are null/"" while not working.]
- [DECISION: `last_activity` is `{kind: tool_use|text|thinking, name (tool_use only), at}` from
  the newest assistant line of the open turn.]
- [DECISION: join refuses (queues, `join_declined` names why) on: an earlier queued prompt
  (`queued_behind`), Claude not running, a dialog or unrecognized screen, the agent list
  focused, unsent text in the box, an interrupt the watcher has not reported yet
  (`interrupt_not_reported_yet`, so its report is not lost under a new prompt), and a session
  tainted under the lock (`session_tainted`). A tainted session is already refused at the door.]
- [DECISION: `_prompt_arrived` also gives back the send record when the prompt's line is a
  user line no turn will claim (Claude Code dequeued it as `promptSource: "queued"`, which
  `human_prompt_text` does not attribute), so a joined prompt that lands just after its turn ends
  leaves no stale record.]

## Chunks

- [ ] **A. Turn info** — `turns_view.open_turn` / `turn_info`; `working_on` fixed; status,
  interrupt and queued send carry the fields. Tests first (`test_turns_view_open_turn`,
  `test_session_report`).
- [ ] **B. deliver="join"** — `session_send` argument, join checks under the send lock,
  `joined_turn`; `_prompt_arrived` dequeued case; descriptions, `published-tools.json`, wire test.
- [ ] **C. Docs and smoke** — design-10 S5, requirements MCP-40/41, CHANGELOG, change-log,
  smoke step.
- [ ] **D. Release** — `chore(release): aidc v1.9.8`, gates, Critic, PR review (no push).

## Status

Context: starting Chunk A (tests first).
