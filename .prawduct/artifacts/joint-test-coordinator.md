# Joint test: aidc × MetaLLM (Chunk 06)

**Date:** 2026-09-17. **Branch:** `feature/turn-state`.
**Who:** this aidc session, and the metallm agent inside `aidc-metallm-dev`, running its own dev
MetaLLM (API on 8002). The two sessions talked through cross-session messages.

**Setup**
- Test MCP on the host at `:17878`, run from the branch checkout, scoped to the session
  `jointtest` (`AIDC_MCP_ALLOWED_SESSIONS`). Its token and state live in the scratchpad. The token
  was given to metallm, so it must be rotated.
- `callback_url` pointed at the metallm session's declared port on the host's overlay address.
- Session `jointtest`: rc1 images, test repo, and a test Stop hook that blocks once when armed.
- The live `aidc-mcp` and the live `metallm` session were not touched.

**Builds under test, in order:** `e041cb6` → `cce02db` → `4c3bc72` → `e158dce` → `f2558c0` →
`8cbcc6f` → `10839e0` → `9029dea`. The fixes after the test (`36fe131`, `aaaeb8d`, `9e24c54` and
the review follow-ups) have unit evidence only; they were not re-run against MetaLLM.

## Results

| # | Case | Result | Notes |
|---|---|---|---|
| 1 | Plain reply through `session_send` and the webhook | PASS | Confirmed by both sides. |
| 2 | Send while Claude is busy: the second prompt queues (`claude_busy`) | PASS | Two callbacks arrived in order. |
| 3 | Send while a person has unsent text in the box (`input_has_text`) | PASS | The tmux status line showed the notice; the prompt went in once the box was cleared. |
| 4 | Refusal paths on MetaLLM's side | PASS | metallm's graph refused first, as intended. |
| 5 | Queue full (the 26th prompt) | PASS | Rerun on `cce02db` with `error_code: "queue_full"`. metallm sent once and did not retry. |
| 9 | aidc-mcp restart with a prompt queued | **BUG → FIXED → PASS** | The queue survived the restart, but the webhook lived only in memory, so the reply ("SEVEN") was never sent. `cce02db` saves webhooks and resumes them from the saved watermark. On the fixed build SEVEN arrived exactly once and nothing was replayed. |
| 6a | Esc before Claude writes anything | **BUG → FIXED → PASS** | First run: reported only after the 10-minute fallback, because the MCP had never seen the "esc to interrupt" text since its restart. `e158dce` treats the prompt Claude puts back in the box as proof. Rerun: reported 11 s after the Esc (`prompt_restored`). |
| 6a′ | Restart after an early-Esc report | **BUG → FIXED → PASS** | The report was remembered only in memory, so after a restart the session read busy forever and metallm's queued prompt waited for good. `f2558c0` keeps the report on disk. Proven live: the queue went through right after the restart. |
| 6b | Esc after Claude has started writing | PASS | Callback 6 s after the Esc, with the partial text ("**How DN") and `interrupted: true`. |
| 7 | Stop hook pushes back | PASS | Exactly one callback, `"SEVEN-A\nACK-PUSHBACK"`, 4 s after the send, with no early partial reply. |
| 10 | Claude restarts inside the session while a prompt waits | **BUG → FIXED → PASS** | The queue held (`claude_not_running`) and pasted 6 s after the restart, but the reply ("TEN") was lost: aidc moved to Claude's new transcript file reading from its end. `8cbcc6f` resumes from the old file's last activity (MCP-35, design 10 D8). Rerun: ELEVEN arrived exactly once. |
| 8 | A turn typed at the terminal (`speaker: "human"`, recorded without waking the orchestrator) | PASS | Built behind `metallm.send_speaker`, off by default (Pace, after learning that the live MetaLLM v0.46.0 drops `human` turns); on in the test MCP only. One row, "Typed at the terminal", zero orchestrator turns. The first two POSTs timed out because metallm's dev server was down mid-edit (their side). |
| 11 | A prompt stuck in the queue (`prompt_waiting`, 60 s override) | PASS | One notice after 61 s, `ok: true` (changed from `false` at metallm's request: MetaLLM renders `ok: false` as an error), no repeat after an MCP restart, and the normal reply after the box was cleared. metallm fixed a source-list drift on its side and made the notice record-only. |
| 12 | `aidc upgrade` with a prompt queued, then an MCP restart | **BUG → FIXED → PASS** | Review rev-20260917T062841Z-0930096f (blocking R-1): "same session" was the dev container id, which an upgrade replaces, so the queue and the webhook would have been dropped. `9029dea` identifies a session by its network. Live: container f14a…→e168…, network unchanged; the prompt was held through the swap, pasted 4 s after, one reply; the webhook resumed after the MCP restart. |

## Found on MetaLLM's side (fixed by metallm, no aidc change)

- Interrupted callbacks showed up nine times in the conversation. metallm's trigger did not accept
  the `agent_watch_interrupted` source, so each delivery wrote a row, failed, and was retried.
  aidc sent exactly one POST each time. metallm has fixed it.
- A 202 from MetaLLM means "accepted for delivery", not "shown in the conversation".

## Decisions and agreements made during the test

- The `error_code` field on failure envelopes, and its code set (design 10 D6, MCP-32).
- The `prompt_dropped` callback for a queued prompt whose session is removed or re-created
  (design 10 D5, MCP-33).
- A failed paste in `session_send` queues the prompt instead of refusing it.
- metallm never retries `session_send`. It retries a read once on a transport failure or `cli_failed`.
- `prompt_waiting` (MCP-36): approved by Pace, 10 minutes, `ok: true`.
- `speaker` (MCP-27): built behind `metallm.send_speaker`, off by default. Turn it on for the live
  MCP only after metallm confirms record-without-wake is released and deployed, and the production
  host's running MetaLLM version is checked.

## Known gaps found here, all fixed afterwards (2026-09-17, before the release)

- A reply left in a transcript the watcher can no longer resume in (a torn write, a compaction) is
  now delivered before it follows Claude to a new file (MCP-37).
- `session_resend` searches the session's earlier transcripts, so a reply from before a restart
  (like TEN) can be fetched by hand.
- A prompt pasted while Claude was busy now gives its send record back, so the same words typed by
  a person cannot be delivered as the orchestrator's own.
- `load_config` reads the `/aidc-config` mount, so sessions the MCP creates get the host's config
  instead of the defaults (design 11).

## After the test

Rotate the test token, stop the test MCP, `aidc kill jointtest` and `aidc kill measure`, remove
the rc1 image tags.
