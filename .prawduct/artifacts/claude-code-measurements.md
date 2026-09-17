# Claude Code measurements in an aidc dev container (Chunk 01)

Session `measure` (aidc v1.6.0, profile multi, `--no-resume`), 2026-09-17 01:10–01:20 UTC.
Claude Code **2.1.270** at first launch; it auto-updated to **2.1.274** on the first restart. Pane
180x45 (sized by Pace's attached client). Prawduct plugin bridged and enabled, so `hookCount` is
2 once the test hook is added (prawduct's Stop hook plus the test hook).

Raw captures (`.ansi` = `capture-pane -e`, `.txt` = plain, `.cursor`), sample logs and copies of
both transcripts are in this session's scratchpad `measure/`. Transcripts: `4fee27ae….jsonl`
(first launch) and `d0837af9….jsonl` (after restart).

## Transcript

| # | Case | What was written | Lines (d0837af9 unless noted) |
|---|---|---|---|
| T1 | Normal turn with a 20s Bash call | `assistant` tool_use → `user` tool_result → `assistant` end_turn text → `system` `stop_hook_summary` (`hookErrors: []`) → `system` `turn_duration` 3 ms later | 4fee27ae 29–41 |
| T2 | Stop hook blocks via JSON `{"decision":"block","reason":…}` | `assistant` end_turn → `user` `isMeta: true`, content `"Stop hook feedback:\n<reason>"` (39 ms later) → `system` `stop_hook_summary` with `hookErrors: [<reason>]` (146 ms after that) → no `turn_duration` | 25, 28, 35 |
| T3 | Stop hook blocks via exit 2 + stderr | same as T2; feedback content is `"Stop hook feedback:\n[<command path>]: <stderr>"` and `hookErrors` carries the same `[<command>]: <stderr>` string | 37, 38, 39 |
| T4 | Final allowed stop after two blocks | `assistant` end_turn → `stop_hook_summary` `hookErrors: []` → `turn_duration` (4 ms). One `turn_duration` for the whole exchange (`durationMs: 3601`) | 40–42 |
| T5 | Thinking and text in one reply | Written as two `assistant` lines, each with `stop_reason: end_turn` (thinking-only, then text) | 36–37, 57–58, 64–65 |
| T6 | Esc after Claude had started (thinking + tool_use + tool_result written) | `user` line `[{"type":"text","text":"[Request interrupted by user]"}]` with `interruptedMessageId`; **no** system line; Stop hooks did not run | 50 |
| T7 | **Esc before Claude wrote any assistant line** | **Nothing.** The prompt's `user` line stays with no reply and no interrupt marker. The prompt text is put back into the input box on screen | 52 (no follow-up) |
| T8 | A background shell finishing | `queue-operation` enqueue/dequeue, then a `user` line with content `<task-notification>…`, `promptSource: "system"`, `origin.kind: "task-notification"`; Claude runs a new turn on it (end_turn, summary, turn_duration) | 54–60 |
| T9 | `turn_duration` presence | After every allowed stop observed: 5 of 5 (T1, T4, T8, the thinking turn, the first-launch turn) | — |
| T10 | Rotation | `/exit` then relaunching without `--continue` started a new `<sessionId>.jsonl` on the first prompt | d0837af9 |
| T11 | API error | Not produced; would need breaking the session's network. Existing design-09 handling stays | — |

Notes:
- The 20s `sleep` in T6 was run as a background shell (status row showed `1 shell`), so its
  tool_result arrived at once and its completion later produced T8.
- In T7 the essay prompt (line 52) is followed by the task-notification prompt (line 56) with no
  assistant line between them. Today's parser accumulates both as the prompts of the turn that
  follows, so the `DONE` reply to the background task would be attributed to the essay prompt.

## Screen

| # | Case | What the `claude` window shows |
|---|---|---|
| S1 | Input box | The last two full-width `─` rules near the bottom enclose the box; the status row is directly below the second rule |
| S2 | Empty box | Box row is `\x1b[39m❯\xa0` and nothing after (NBSP after the glyph). Cursor x=2 on the box row |
| S3 | Typed, unsent | `❯\xa0can you also check the`, typed text not styled; cursor at the end of the text. Status row drops `· ← for agents` |
| S4 | Multi-line unsent | Continuation rows between the rules indented two spaces (`  line two`) |
| S5 | Placeholder | `❯\xa0\x1b[2mTry "refactor <filepath>"\x1b[0m` — dim (SGR 2). Seen only for ~0.15s right after startup |
| S6 | Earlier prompts in scrollback | `❯` rows drawn on a background (`\x1b[48;5;237m`), so they do not look like the live box row |
| S7 | Busy | Status row contains `esc to interrupt` while Claude works (tool running, thinking, writing) on 2.1.270 and 2.1.274. Gone at rest |
| S8 | Pane change while busy | During a 20s silent Bash call the pane changed at least every 0.87s (81 of 81 samples at 0.25s) |
| S9 | Not at prompt: folder trust | First launch in a new folder: `Accessing workspace:` … `❯ No, exit` / `Yes, I trust this folder` / `Enter to confirm · Esc to cancel`. No `─` box, `❯` used as a menu cursor |
| S10 | Not at prompt: shell | After `/exit`, `pane_current_command` is `bash` |
| S11 | Startup | Claude's banner and a box appear ~1.4s after launch; `pane_current_command` is `claude` from ~0.6s |
| S12 | Other status-row text | `✔ Update installed · Restart to update`, `tmux detected · scroll with PgUp/PgDn …`, `tmux focus-events off …`, `1 shell · ↓ to manage` |

Not captured: the `/login` screen (the session was already logged in). Any screen without the
box row counts as "not at prompt", which covers it.

## What contradicts or extends design 10

1. **T7: an Esc before Claude writes anything leaves no marker in the transcript.** The transcript
   shows an open turn forever. Design 10's S1 would call the session busy until the crash
   fallback, and D3 never reports the interrupt. The screen shows it: no `esc to interrupt`, and
   the prompt back in the input box. Needs Pace's decision.
2. **T7 + T8: an unanswered prompt gets attributed to the next turn.** Fix belongs in Chunk 02.
3. **S7 contradicts the TangleClaw note** that `esc to interrupt` only appears in a retry branch.
   On the container's versions it is on the status row whenever Claude works.
4. **S5: the dim placeholder exists but is transient.** The empty-box rule is "nothing, or only
   dim text, after `❯\xa0`".
