---
artifact: build-plan
version: 2
scope: turn-state
branch: feature/turn-state
depends_on:
  - doc: docs/design-10-turn-state-and-sending.md
  - doc: docs/requirements.md (MCP-24..MCP-30)
# No governed_by: this repo was never onboarded and declares no Direction norms.
partition: serial — 02 and 03 both edit transcript.py, 03 and 04 both rewrite the send path in tools.py, and 01's measurements feed every later chunk
last_validated: 2026-09-17
---

# Build plan: turn state from the transcript, and a send queue that never drops

**Size:** large (five chunks) · **Type:** fix + feature · **Branch:** `feature/turn-state`

## Requirements Confidence

**Level:** Medium

**Why:** Every behaviour was talked through and agreed with Pace on 2026-09-16/17 (design 10). The
unknowns are facts about Claude Code's transcript and screen inside the dev container, which the
design marks "to measure".

**Open assumptions / unknowns:**
- [ASSUMPTION: the container's Claude Code writes `stop_hook_summary`, `turn_duration`, the `isMeta` Stop-hook feedback line and the interrupt line in the shapes seen on the host | HIGH impact | Chunk 01 confirms or corrects]
- [ASSUMPTION: Claude's empty input box is distinguishable from one holding typed text (dim placeholder, cursor position) | HIGH impact | Chunk 01 confirms; if not, S2 needs a different signal and Pace decides]
- [ASSUMPTION: the orchestrator learns why a prompt waits by pulling (`session_send` result, `session_status`), not by a pushed callback | MED impact | Pace can ask for a push]
- [ASSUMPTION: if MetaLLM's speaker change has not shipped when Chunk 04 is done, Pace is asked whether to open the PR without Chunk 05 | MED impact | Pace decides then]
- [ASSUMPTION: the 25-prompt queue-depth cap stays; it refuses new prompts at the door and never drops accepted ones | LOW impact | Pace can override]

**What would raise confidence:** Chunk 01 — about an hour on a throwaway aidc session, after Pace runs `/login` in it once.

## Status

- [x] Chunk 01: Measure transcript and screen facts in a throwaway aidc session
- [x] Chunk 02: Delivery — pushback reopens the turn, end-of-turn shortcut, interrupts delivered
- [x] Chunk 03: Turn state from the transcript; screen read only for the input box and prompt
- [x] Chunk 04: A send queue that never drops, with waiting reasons and the tmux status line
- [x] Chunk 05: `speaker` on the payload (after MetaLLM displays human turns)
- [x] Chunk 07: Session-scoped MCP mode (AIDC_MCP_ALLOWED_SESSIONS, MCP-31)
- [x] Chunk 08: Enforce MCP-12: dev containers cannot reach the live MCP through squid
- [ ] Chunk 06: Joint end-to-end test with the metallm agent in a dev container
Context: Chunks 01–05, 07, 08 done 2026-09-17. Chunk 05 built behind metallm.send_speaker (off by default) at Pace's decision, with prompt_waiting (MCP-36); forced cumulative review rev-20260917T062841Z-0930096f + verify rounds clean through 36fe131. aaaeb8d (kill cleans a leftover network; broader not-found match) is UNREVIEWED: round budget exhausted (7/6), Pace to decide whether to force. Chunk 06 (joint test) complete, all 12 scenarios pass on both sides; log in .prawduct/artifacts/joint-test-metallm.md awaits Pace's read before ticking. Then: cleanup of the test rig (needs Pace's OK), make smoke, PR only when Pace says.

## Verification Strategy

Unit tests use recorded transcript fixtures (real JSONL lines captured in Chunk 01, trimmed) for
every parser rule, and fakes of `_tmux_exec` / `_capture_pane` for the send path, following
`mcp/tests/test_session_send.py` and `test_transcript.py`. Beyond tests, Chunks 02–04 are each
exercised on the throwaway session through the MCP tools against a local callback receiver: a
blocked Stop hook, an Esc, typed-but-unsent text, a Claude restart, and an `aidc-mcp` restart with
prompts queued. `make smoke` runs before the PR.

## Build Chunks

### Chunk 01: Measure transcript and screen facts in a throwaway aidc session

- **Description:** Create a throwaway session (`aidc create`), have Pace `/login` once, then record what the transcript and the `claude` window show for: a normal turn, a turn a Stop hook blocks (a temporary project-level Stop hook that blocks once), Esc mid-turn, an API-error line if one can be produced, an empty input box, typed-but-unsent text, Claude at startup/login, and Claude silently thinking. Record the Claude Code version. `aidc kill` it afterwards.
- **Type:** doc-only
- **Foreign API:** claude-code-transcript-and-tui
- **Depends on:** none
- **Deliverables:** new `.prawduct/artifacts/claude-code-measurements.md` (raw notes, captured lines, `capture-pane -e` excerpts); the "Transcript facts" table and S2 signals in `docs/design-10-turn-state-and-sending.md` updated from "to measure" to what was found; trimmed fixtures saved for Chunks 02–03 under new `mcp/tests/fixtures/`
- **Tests:** none (measurement)
- **Acceptance criteria:** every "to measure" item in design 10 is confirmed, corrected, or explicitly marked unmeasurable with the fallback it gets; any finding that changes an agreed behaviour is taken back to Pace before Chunk 02
- **Done when:**
  0. verify-api — the measurements above, captured from the live container
  1. Design 10 updated and committed
  2. Throwaway session killed (Pace: keep it up for Chunks 02–04 live checks; killed at plan end)
  3. Chunk marked `[x]` in Status

### Chunk 02: Delivery — pushback reopens the turn, end-of-turn shortcut, interrupts delivered

- **Description:** D1–D3 of design 10. `extract_completed_turns` stops closing turns on `isMeta` user lines, withdraws a terminal on a Stop-hook pushback, reads the two system subtypes, closes a turn on an interrupt line with the interrupt note and `interrupted: true` (payload per design 10 D5), and logs `transcript_terminal_superseded`. The drain's settle gate delivers immediately when `turn_duration` follows the terminal.
- **Depends on:** Chunk 01
- **Deliverables:** changes in `mcp/src/aidc_mcp/transcript.py` and the settle gate in `mcp/src/aidc_mcp/tools.py`; tests in `mcp/tests/test_transcript.py` and `mcp/tests/test_transcript_delivery.py`
- **Tests:** blocked stop then real finish delivers once with merged text; blocked stop with the quiet window elapsed delivers nothing; `turn_duration` bypasses settle and its absence does not; interrupt with text, interrupt with no assistant line, interrupt on an orchestrator prompt vs a typed one; uuid-less interrupt not terminal; exactly-once across a re-read of each case; existing MCP-23 attribution tests still pass
- **Acceptance criteria:** full `mcp` suite, ruff and mypy green; on the throwaway session a blocked stop produces one callback and an Esc produces one `interrupted: true` callback with the note
- **Done when:**
  1. Acceptance criteria met and tests pass
  2. `/prawduct:critic` run and blocking findings resolved
  3. Committed (`fix(mcp): … (Chunk 02)`) and chunk marked `[x]` in Status

### Chunk 03: Turn state from the transcript; screen read only for the input box and prompt

- **Description:** S1–S2 of design 10. A per-session turn-state reader over the mirrored transcript (busy / free, with the post-send "busy until the prompt appears" rule and the crash fallback); a screen classifier for "input box empty / has text / not at prompt / unrecognized"; `_wait_for_idle` replaced in `session_send`, the drainer, `session_run` and `session_resend`; `session_run` responses from the transcript; `_wait_for_idle`, `_extract_delta` and `_strip_ansi` deleted.
- **Depends on:** Chunk 02 (shares the parser's turn rules)
- **Critic mode:** final
  <!-- Keystone: Chunk 04's queue is built on this busy/free verdict. -->
- **Deliverables:** turn-state reader in `mcp/src/aidc_mcp/transcript.py`; screen classifier and send-path rewiring in `mcp/src/aidc_mcp/tools.py`; tests in `mcp/tests/test_session_send.py`, `test_session_watch.py`, `test_roundtrip.py`
- **Tests:** busy on open turn whatever the pane shows; free on terminal / interrupt; busy after inject until the prompt's line appears, and "not sent" when it never does; crash fallback frees only when Claude runs, the transcript is quiet past the limit, and the screen is at the prompt; classifier on captured fixtures for each screen state from Chunk 01, and "unrecognized" on garbage
- **Acceptance criteria:** no call to pane byte-stability remains anywhere in `mcp/src`; suite, ruff, mypy green; on the throwaway session a send during silent thinking queues instead of pasting, and a send with typed-but-unsent text queues
- **Done when:**
  1. Acceptance criteria met and tests pass
  2. `/prawduct:critic` run and blocking findings resolved
  3. Committed (`… (Chunk 03)`) and chunk marked `[x]` in Status

### Chunk 04: A send queue that never drops, with waiting reasons and the tmux status line

- **Carried from the Chunk 03 review (R-10):** rename the send-path names left from the pane check (`_SEND_IDLE_TIMEOUT`, `_PENDING_IDLE_POLL`, `_PENDING_MAX_IDLE_POLLS`, `never_went_idle`) when this chunk rewrites the drainer.
- **Description:** S3–S4 of design 10. Remove the idle-poll deadline and the paste-attempt limit (bounded backoff instead); hold while Claude is not running; persist the queue to `watcher-state/<session>.send-queue.json` and resume drainers on `aidc-mcp` start; dead-letter only on session kill (and for queue files of sessions that no longer exist at start); report the waiting reason in `session_send` and `session_status`; set and clear the tmux status-line message via a user option referenced from `status-right`.
- **Depends on:** Chunk 03
- **Deliverables:** queue changes in `mcp/src/aidc_mcp/tools.py`; persistence helpers in `mcp/src/aidc_mcp/transcript.py` next to the watermark and send record; `status-right` wiring in `.devcontainer/tmux-start.sh`; tool docstrings updated (MCP-22); README / design 09 prose that describes dead-lettering after a timeout corrected; `CHANGELOG.md` entry
- **Tests:** a prompt survives a simulated MCP restart and drains in order; Claude not running holds, then drains when it returns; paste failures retry past 3 attempts; kill dead-letters every waiting prompt; each waiting reason reported; status-line option set on `input_has_text` and cleared on inject; depth cap still refuses the 26th prompt
- **Acceptance criteria:** suite, ruff, mypy, shell suites green; on the throwaway session a queued prompt survives `aidc mcp stop && aidc mcp start`, the status line appears while unsent text blocks a prompt, and disappears when the prompt goes in
- **Done when:**
  1. Acceptance criteria met and tests pass
  2. `/prawduct:critic` run and blocking findings resolved
  3. Committed (`… (Chunk 04)`) and chunk marked `[x]` in Status

### Chunk 05: `speaker` on the payload (after MetaLLM displays human turns)

- **Description:** D4 of design 10. `speaker: "human"` when every prompt the turn answers was typed at the terminal, `"agent"` otherwise. Starts only when the metallm session confirms its change to show human turns has shipped.
- **Depends on:** Chunk 02; the MetaLLM change
- **Type:** cumulative-final
  <!-- Its review IS the branch's one cumulative pass. If MetaLLM is not ready when Chunk 04 is
       done, ask Pace whether to run cumulative on Chunk 04 and open the PR without this chunk. -->
- **Deliverables:** payload change in `_post_turn` (`mcp/src/aidc_mcp/tools.py`) and turn attribution in `mcp/src/aidc_mcp/transcript.py`; tests in `mcp/tests/test_transcript_delivery.py`; design 09 payload section updated
- **Tests:** typed-only turn → `human`; orchestrator-only, mixed, and prompt-less turns → `agent`; interrupt turns follow the same rule; ledger fingerprint unaffected
- **Acceptance criteria:** suite green; one end-to-end callback carrying `speaker: "human"` shown in MetaLLM as a watched turn
- **Done when:**
  1. Acceptance criteria met and tests pass
  2. Committed, then `/prawduct:critic cumulative` run and blocking findings resolved
  3. Chunk marked `[x]` in Status

### Chunk 06: Joint end-to-end test with the metallm agent in a dev container

- **Description:** Pace asked (2026-09-17) that, once aidc is ready, this session and the `metallm` agent test aidc and MetaLLM together. The metallm agent moves into an aidc dev container, running a build of this branch. The two sessions then drive the real loop: the orchestrator sends through `session_send`, and callbacks land in MetaLLM. Cases: a plain reply; a Stop-hook pushback delivered as one reply; Esc after output and before output (`interrupted`, rendered "stopped at the terminal"); a prompt typed at the terminal (and `speaker: "human"` recorded without wake, if Chunk 05 is in); sends while busy, while text is typed, while Claude is restarting; an `aidc-mcp` restart with prompts queued.
- **Type:** doc-only
- **Depends on:** Chunks 04, 07 and 08 (and Chunk 05 if MetaLLM's record-without-wake is deployed by then)
- **Deliverables:** a written test log (cases, what each side saw, pass/fail) in new `.prawduct/artifacts/joint-test-metallm.md`; any defect found goes back into a code chunk before the PR
- **Acceptance criteria:** every case passes on both sides, or has an agreed disposition
- **Done when:**
  1. Test log written and reviewed with Pace
  2. Chunk marked `[x]` in Status

### Chunk 07: Session-scoped MCP mode (AIDC_MCP_ALLOWED_SESSIONS, MCP-31)

- **Description:** Design 11. A test MCP's token goes inside the orchestrator's dev container; limit that server to named sessions so the token cannot reach any other session on the host.
- **Depends on:** none
- **Deliverables:** new `mcp/src/aidc_mcp/scope.py`; `_scoped` wrapper on every named tool and scope checks on create/list/resources/queue resume; new `mcp/tests/test_scope.py`; MCP-31; new `docs/design-11-sandboxed-orchestrator-testing.md`
- **Acceptance criteria:** every named tool refuses an out-of-scope session without side effects; a test fails if a future named tool is not wrapped; suite, ruff and mypy green
- **Done when:**
  1. Acceptance criteria met and tests pass
  2. `/prawduct:critic` run and blocking findings resolved
  3. Committed (`feat(mcp): … (Chunk 07)`) and chunk marked `[x]` in Status

### Chunk 08: Enforce MCP-12: dev containers cannot reach the live MCP through squid

- **Description:** Measured 2026-09-17: squid's `allow localnet` lets a dev container reach the MCP's bind address and port (only the token stops it). Add a deny rule for the configured MCP bind address + port (every destination on that port when bound to all interfaces), rendered into each session's squid config at create time, with a verification from inside a session.
- **Depends on:** none
- **Deliverables:** squid config / entrypoint change, create-time wiring from `mcp.bind_address` / `mcp.port`, shell tests, docs (design 11, README safety section)
- **Acceptance criteria:** from a new session, the live MCP port returns a squid denial; the test MCP port on another port is still reachable; shell suites and `make smoke` green
- **Done when:**
  1. Acceptance criteria met and tests pass
  2. `/prawduct:critic` run and blocking findings resolved
  3. Committed (`fix(proxy): … (Chunk 08)`) and chunk marked `[x]` in Status

## Early Feedback Milestone

**Milestone chunk:** 02
**What the user can do:** on the throwaway session, watch a Stop-hook pushback produce one callback instead of two, and an Esc produce an "Interrupted" callback.

## Governance Checkpoints

**Commit & PR cadence:** commit per chunk after its Critic review. The PR into `develop` (never `main`; `resolve-base` is wrong for this repo) follows the cumulative review plus the independent PR reviewer, which Pace wants run before every PR. No release until Pace decides.

- After Chunk 01: take any measurement that contradicts design 10 back to Pace before building.
- After Chunk 03 (final review): confirm the busy/free verdict before the queue depends on it.
- Before the PR: cumulative review, `make smoke`, `CHANGELOG.md` checked by hand (the prawduct change-log probe cannot pass here).
