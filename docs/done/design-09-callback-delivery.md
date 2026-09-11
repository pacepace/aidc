# Design 09 — Reliable Callback Delivery (JSONL-sourced)

**What this covers.** How the shared-session watcher delivers Claude's responses back to
an external orchestrator (MetaLLM / Saoirse) reliably: sourcing content from Claude Code's
native JSONL transcript instead of scraping the tmux pane, detecting turn completion from
transcript structure, delivering exactly-once via a durable high-water mark, and retrying
failed deliveries without silent loss. This is the structural replacement for the
`capture-pane` + idle-heuristic delivery path.

**Requirements implemented:** MCP-15 (transcript-sourced delivery, P0), MCP-16
(transcript-structure completion, P1), MCP-17 (exactly-once + durable high-water mark, P0),
MCP-18 (retry on failure, no silent drop, P0), MCP-19 (per-attempt delivery logging, P1).

**Status:** implemented — delivered v0.3.0 (MCP-15..19), hardened through v0.4.3. Supersedes
the `_run_watcher` / `_wait_for_idle` / `_extract_delta` delivery path in
`mcp/src/aidc_mcp/tools.py`.

---

## Background — why this exists

The watcher behind `session_send` / `session_run` / `session_watch`
delivered responses by screen-scraping the tmux `claude` window: poll `capture-pane`, wait
for the pane to be byte-identical for 1.5s (`_wait_for_idle`), strip ANSI, anchor-match the
new text (`_extract_delta`), POST. A production incident (2026-06-08) exposed three failure
classes inherent to that approach:

1. **Idle-heuristic misfire** — Claude's animated `(123s · esc to interrupt)` line mutates
   the pane every second, so "unchanged for 1.5s" can never be reached while Claude works;
   completion is inferred only when the screen finally stills, and pathological cases ride
   the 1800s ceiling.
2. **Restart double-ping** — on `aidc restart`, `claude --continue` re-renders the prior
   conversation into the pane; the still-running watcher saw the redraw as a fresh response
   and re-delivered it.
3. **ANSI-stripping fragility** — delivery correctness depends on a hand-maintained escape
   regex and anchor-matching against a TUI Anthropic restyles regularly.

All three vanish if we deliver from the **structured transcript** Claude Code already
writes, which both the interactive session and headless `--print` share via `--continue`.

---

## Verified transcript schema

> **Confidence: verified**, not recalled. The findings below were read from real transcripts
> at `~/.claude/projects/<encoded-repo>/*.jsonl` on 2026-06-08. This is a Claude Code
> *internal* format with no stability guarantee — the implementation MUST re-verify the
> field names and turn-boundary semantics against the installed Claude Code version, and
> MUST fail safe (log + skip, never crash the watcher) on an unrecognized line shape.

- **One JSONL file per session**, named `<sessionId>.jsonl`. Each line is one JSON object
  with a top-level `type`. Lines are append-only and in chronological order.
- **Message line types** are `assistant` and `user`. Other observed types are noise for our
  purposes and MUST be ignored: `system`, `attachment`, `file-history-snapshot`,
  `last-prompt`, `ai-title`, `agent-name`, `mode`, `permission-mode`, `queue-operation`.
  The file tail frequently ends on these — **"last line" ≠ "last turn."**
- **An assistant message** carries: `uuid`, `parentUuid`, `sessionId`, `timestamp`, `type`,
  `isSidechain`, and a nested `message` with `role`, `content` (an array of blocks), and
  `stop_reason`.
- **A turn spans many assistant lines.** Within one user→assistant turn, assistant lines
  with `stop_reason: "tool_use"` interleave with tool activity. The turn is **complete**
  only when an assistant line has `stop_reason ∈ {"end_turn", "stop_sequence"}` (control
  returns to the user). `stop_reason: null` is an incomplete/aborted message.
- **Content blocks** have `type ∈ {text, thinking, tool_use}`. Only `text` blocks are the
  user-visible answer; `thinking` and `tool_use` MUST be excluded from delivered content.
- **Sidechains/subagents** live in a separate `subagents/*.jsonl` subdir and/or carry
  `isSidechain: true`. The watcher MUST read only the main session file and MUST skip lines
  with `isSidechain == true`.
- **Resume/compaction writes a single flagged summary line, NOT a verbatim re-emission.**
  When a session is continued from a prior conversation (or auto-compacted mid-session),
  Claude Code injects exactly ONE `user`-type line carrying `isCompactSummary: true` and
  `isVisibleInTranscriptOnly: true`, whose text begins *"This session is being continued
  from a previous conversation that ran out of context…"*. Prior assistant turns are **not**
  re-written as individual assistant lines. The watcher MUST skip any line with
  `isCompactSummary == true` or `isVisibleInTranscriptOnly == true`. (Verified 2026-06-08
  from a real compacted transcript: one such line at position 3395/8548, role `user`.)
- **`--continue` APPENDS to the existing session file — it does NOT fork a new file or
  re-emit prior turns.** Empirically verified (2026-06-09, live aidc dev container, below):
  a fresh turn then a `--continue` turn produced **one** `<sessionId>.jsonl`; the second
  turn's `user` line chained directly off the first turn's assistant `uuid` (clean
  `parentUuid` chain), with no duplication of prior lines and no new file. A **new**
  `<sessionId>.jsonl` is created only by a *fresh* session (a launch with no resumable
  history, or `/clear`), not by resuming. uuids are disjoint across files because each file
  is a *separate* session — not because `--continue` rewrites anything.

---

## Architecture

The watcher remains a per-`(session, conversation_id)` background task in the long-lived
`aidc-mcp` process. What changes is its *source of truth* and its *durability*.

```
aidc-mcp process
  watcher(session, conversation_id)
    ├─ resolve active transcript   (direct read: newest *.jsonl, excl. subagents/)
    ├─ incremental read            (direct read: bytes since persisted offset)
    ├─ parse complete JSON lines   (buffer a partial trailing line)
    ├─ detect completed turns      (stop_reason end_turn|stop_sequence)
    ├─ extract text blocks         (text only; ordered)
    ├─ deliver (POST) with retry   (bounded backoff; dead-letter on abandon)
    └─ advance high-water mark     (atomic; only AFTER confirmed delivery)
         persisted under the audit volume (survives MCP restart)
```

**Transcript access — scoped per-session mount into the MCP audit volume (decided).** The
MCP server is a single long-lived container with a fixed mount set, so it cannot take a new
mount per session. The one RW host path it *already* mounts is the MCP audit volume
(`~/aidc-mcp-audit` → `/var/log/aidc-mcp`). Each managed session's transcript is therefore
**surfaced under that volume**, where MCP reads it directly — scoped to aidc-managed
sessions only, with **no blanket mount** of the host's `~/.claude/projects`.

Layout (host → containers):

```
host  ~/aidc-mcp-audit/transcripts/<session>/   <sessionId>.jsonl ...
        ├─ dev container aidc-<session>-dev : surfaced live here (mechanism below)
        └─ aidc-mcp  (existing mount):  /var/log/aidc-mcp/transcripts/<session>/   [reads]
```

- **MCP read path (direct, no `docker exec`):** resolve the active file = the one matching
  the tracked `session_id` while it exists, falling back to newest `*.jsonl` only for the
  first resolution or once that file is gone (exclude `subagents/`). Pinning is deliberate:
  the copy-forward mirror rewrites whole files and bumps mtimes, so a plain newest-mtime
  pick *flaps* between transcripts — and each flap looked like a rotation that reset the
  watermark and replayed the entire file (the 2026-06-15 incident that hammered the webhook).
  Incremental read =
  `open`, `seek(byte_offset)`, read appended bytes, split on newlines, parse complete
  objects, buffer any partial trailing line. No subprocess per poll. Polling stays ≈2s but
  is now cheap and exact — appended bytes parsed by structure, no timing heuristic.

- **Surfacing (set up at `aidc create`):** the session's transcript dir is made to live
  under `~/aidc-mcp-audit/transcripts/<session>/` and exposed to the dev container so Claude
  writes there and MCP sees every append live through its existing mount. Two viable
  mechanisms:
  - **(Recommended) Relocate + host symlink — zero-copy.** Make
    `~/aidc-mcp-audit/transcripts/<session>/` the canonical project dir bind-mounted to
    `~/.claude/projects/<enc>` inside the dev container; on the host, symlink
    `~/.claude/projects/<enc>` → the session dir so host-side memory bridging still
    resolves. Single source of truth, live appends, no copying.
  - **(Fallback) Copy-forward mirror.** Leave the existing per-project memory mount
    untouched; a per-session surfacer in the dev container tails the active transcript and
    appends new bytes into the audit-volume-mounted dir. Non-invasive to memory semantics,
    at the cost of duplicated transcript bytes.

> **Open sub-decision for implementation (flagged, not silently chosen).** Relocate vs
> copy-forward turns on `share_memory` semantics: today `~/.claude/projects/<enc>` is
> **per-project** and shared across concurrent sessions of the same repo (and with
> host-`claude`); the surfaced transcript dir is **per-session**. Relocate is cleanest for a
> single session per repo, but for *concurrent* sessions on one repo the host symlink can
> only point at one of them — so either (a) accept per-session transcript dirs (dropping
> cross-session memory sharing for those), or (b) use copy-forward to preserve the shared
> per-project memory dir. This changes `cmd-create.sh` mount wiring either way; resolve with
> Pace before coding.

- **Security.** The dev-side exposure is limited to that session's `transcripts/<session>/`
  subdir, not the whole audit volume. No path is opened from a dev container to the MCP
  *server* — MCP-12 is network isolation; this is a shared host directory, not a network
  route. Transcripts are written by yolo-mode Claude and are therefore attacker-influenced
  (exactly as they are today via any read path), so the JSONL parser MUST be defensive:
  unknown line shape → log + skip, never crash. No blanket host `~/.claude/projects` access
  is granted to MCP.

---

## Turn-completion detection (MCP-16)

Walk message lines (`type ∈ {user, assistant}`, `isSidechain != true`) in file order,
maintaining the current turn as the run of assistant lines since the last `user` line.

- A turn is **complete** when an assistant line in it has
  `stop_reason ∈ {end_turn, stop_sequence}`.
- `stop_reason: tool_use` → turn continues (more lines coming after the tool result).
- `stop_reason: null` → incomplete; do not deliver. If a subsequent `user` line appears
  before any terminal stop, the turn was abandoned (user interrupt / crash) — log
  `delivery_turn_abandoned`, advance past it, do not deliver.
- `isApiErrorMessage == true` (assistant API error) → treat as a **terminal candidate**,
  not an immediate delivery. Claude Code may auto-retry and continue the same turn, or give
  up and return control to the user, and which it is cannot be known when the error line is
  written. So record it like an `end_turn` but with `ok: false`, and let a later real
  terminal under the same prompt **supersede** it (the retry succeeded → deliver the
  successful answer, `ok: true`). Only when the error is the last terminal before the next
  real prompt or EOF — the session is genuinely waiting for input — is it delivered as a
  failure result (`ok: false`), carrying the pre-error text plus the error message. The old
  eager flush+emit both signalled "done" while a retry was still in flight and discarded the
  in-flight turn's pre-error text (it advanced the watermark past the error, so that work
  never came back).

No idle timer. `_wait_for_idle`, `_IDLE_STABLE_SECS`, `_extract_delta`, and `_strip_ansi`
are removed from the delivery path. (`session_send` no longer returns a captured response
at all — it is non-blocking and the watcher is the sole delivery path. `capture-pane` /
`_extract_delta` remain only for `session_run`'s synchronous transcript; they MUST NOT be
the authoritative delivered content for watched sessions — MCP-15.)

## Content extraction

Delivered content = the ordered concatenation of `text`-type content blocks from the
assistant messages in the completed turn (excluding `thinking` and `tool_use`). A
tool-only turn that ends with no text blocks delivers nothing (log `delivery_empty_turn`,
advance — there is no user-facing answer to send).

---

## Interactive-input tools — AskUserQuestion / ExitPlanMode

`AskUserQuestion` and `ExitPlanMode` are harness tools whose "result" is a **human
decision**, not an automated `tool_result`. An assistant line that calls one ends with
`stop_reason: "tool_use"`, and no `tool_result` is ever appended on its own — control has
returned to the user. In an aidc session there is no human at the pane (the orchestrator
drives it via pasted text), so such a turn is a **deadlock**: the widget can't be answered
over paste+Enter, and the `end_turn`-only turn detector never delivers it, so the
orchestrator never even learns the session is blocked (the 2026-07-01 `faidh` incident).

Two layers address this:

1. **Prevention (primary) — the tools are denied (mode-aware).** `aidc-claude` launches with
   `--disallowedTools` for the human-in-the-loop tools, removing them from the model's context
   (the deny applies even under `--dangerously-skip-permissions`). `AskUserQuestion` (the
   undrivable multi-field widget) is denied in **every** mode. The plan-mode tools
   (`ExitPlanMode` / `EnterPlanMode`) are denied in every mode **except** `plan`: outside plan
   mode a session that entered it could never exit (`ExitPlanMode` gone) and would strand
   read-only, but plan mode is *built on* those tools, so selecting it (`AIDC_CLAUDE_MODE=plan`)
   keeps them — its approve prompt is answered by the orchestrator over the existing
   `session_send` / delivery loop, like any other turn. In the default `yolo` mode all three
   are gone and the agent asks any question as plain assistant text — an ordinary `end_turn`
   turn the existing path delivers, answered with a normal `session_send`.
2. **Delivery (safety net) — deliver the block if it ever appears.** If one of these tools
   fires anyway (a bypassed launch, a resumed pre-fix conversation, a future interactive
   tool), `extract_completed_turns` treats the line as a turn boundary and delivers it,
   rendering the question + options from the tool_use `input` (they are not in a text block).
   Same callback contract, no new wire signal — the orchestrator reads it as any other turn.
   The ask is flushed as its **own** turn (not coalesced with a following continuation) so its
   text is never re-sent when resume reads past it, and a line with no usable `uuid` is not
   treated as terminal (an empty anchor would replay the whole file — see MCP-17).

Because the transcript is written by yolo-mode Claude (attacker-influenced), the parse/extract
layer str-gates every membership test (`type` / tool `name` / `stop_reason` / `text`) and
`parse_jsonl` catches `RecursionError`: a crafted line is skipped, never crashing the watcher.

---

## High-water mark — exactly-once + durable (MCP-17)

**Key.** The mark records the last delivered turn as the **terminal assistant message
`uuid`** plus the `sessionId` (file) and the byte offset reached in that file:

```json
{ "session": "ai-devcontainers",
  "conversation_id": "conv-abc",
  "session_id": "c35691fc-...",          // the active transcript file
  "byte_offset": 482113,                  // bytes consumed in that file
  "last_delivered_uuid": "667e4f8b-...",  // terminal assistant uuid last delivered
  "updated_at": "2026-06-08T23:06:00Z" }
```

`byte_offset` drives cheap incremental reads within a file; `last_delivered_uuid` is the
resume anchor — where to start reading — NOT the safety authority for exactly-once. It was
originally intended as the idempotency token, but in production the watermark proved to have
many ways to be wrong (mtime-flap rotation, torn-read rewind on the copy-forward mirror,
reconnect catch-up), and each corruption re-surfaced an already-delivered turn and replayed
it — the recurring "same message repeated" meltdown.

**Exactly-once is enforced by a separate durable delivery ledger, not the watermark.** The
ledger (`transcript.py`: `content_fingerprint` / `load_delivered` / `record_delivered`) is a
per-`(session, conversation_id)` append-only set of the `sha256` content fingerprints of every
turn CONFIRMED delivered. `_drain_once_body` consults it right before every POST and refuses to
send a fingerprint it already holds. This decouples safety from the resume hint: even if the
watermark is corrupted and re-surfaces a delivered turn, the ledger drops it at the POST
boundary. A watermark bug degrades from "double-deliver and poison the agent's context" to
"waste a disk read". Fingerprinting on content (not uuid) also catches a turn re-emitted under
a new uuid (coalescing, re-extraction) — the guarantee is "the same message content is
delivered to a conversation at most once, ever". The ledger is a sibling file of the watermark:
`.../watcher-state/<session>__<conversation_id>.delivered`.

**Persistence location.** A JSON file per `(session, conversation_id)` under the
MCP audit volume, which is host-mounted RW and therefore survives MCP-container restart:
`/var/log/aidc-mcp/watcher-state/<session>__<conversation_id>.json` (host:
`~/aidc-mcp-audit/watcher-state/...`). The `/aidc-config` volume is read-only and cannot be
used. Writes are atomic (temp + `rename`), matching the taint-flag pattern in
`proxy/policy/policy.sh`.

**The mark advances only AFTER a delivery is confirmed (2xx).** A failed POST never advances
it (MCP-18).

---

## `--continue` and the double-ping (empirically settled)

**`--continue` resumes the *same* transcript file and appends; it does not fork a new file
or re-emit prior turns.** So on `aidc restart` (which relaunches `aidc-claude` =
`claude --continue`):

1. Each poll re-resolves the active file (newest `*.jsonl`) and reads from the persisted
   `byte_offset`.
2. After a resume, the active file is **unchanged** (no new bytes) until a genuinely new
   turn is written; new turns are **appended** and chain off the prior turn's `uuid`.
3. The watcher's offset is already at end-of-file, so it sees nothing to deliver until real
   new content arrives → **no double-ping**. The old, already-delivered response is never
   re-written, so it is never re-read.

A **new** `<sessionId>.jsonl` appears only on a *fresh* session (`/clear`, or a launch with
no resumable history). Rotation is detected only when the **pinned** file is gone and
resolution falls back to a different active file — and it is handled **forward-only**: the
watermark is re-baselined to the new file's *end* (deliver nothing from its history), exactly
like a first watch. It is NOT reset to `byte_offset 0` and replayed — that reset, combined
with the mtime flap above, was the replay bug. A torn/partial mirror read (the last-delivered
uuid momentarily absent from the pinned file) is likewise skipped, never replayed.

**The re-anchor itself must be torn-read-safe, not just the resume path.** A reconnect
(`session_watch` / a watcher restart) re-baselines by reading the pinned file fresh and
taking its current last turn as the new anchor. If that read races a non-atomic
copy-forward rewrite of the SAME file, it can see a torn/partial copy — one missing the
tail already delivered past — and naively taking its last turn as the new anchor **rewinds
the watermark**, causing the next drain to replay every turn after it, including
already-delivered ones (prod 2026-07-18, conv 019f6cf5: a reconnect re-anchor landed on a
torn read and re-delivered 3 already-confirmed turns to the orchestrator in one burst). The
fix reuses the resume path's own anchor lookup during re-anchor: when re-baselining the
SAME pinned `session_id` and an anchor already exists, the anchor must still resolve in the
fresh read; if it doesn't, the read is torn and the mark is left untouched (a later,
complete read re-anchors correctly on the next pass).

**Turn coalescing + settle (premature-ready fix).** Claude can emit an empty `end_turn`
(a thinking/tool phase that ended with no text) and then continue with the real answer in a
second `end_turn` under the *same* prompt. `extract_completed_turns` coalesces all `end_turn`
segments between two real user prompts into one turn (merged text, last terminal uuid), and
the watcher holds delivery until the transcript has been quiet for `metallm.turn_settle_seconds`
(default 4s, `<= 0` disables). Together these signal "ready" once per exchange instead of
firing on the empty intermediate segment.

> **Why "the screen shows old text on attach" does not imply transcript re-emission**
> (Pace's hypothesis, resolved). `claude --continue` repaints the prior conversation onto
> the tmux alternate screen so a re-attaching human sees context — a *terminal render*
> reconstructed from the existing transcript. It is NOT written back into the JSONL. The
> original double-ping was the old `capture-pane` watcher delivering that on-screen
> *re-render*; a JSONL+offset watcher is immune because the file itself does not change on
> resume. **Symptom real, mechanism not re-emission.**

### Empirical verification (2026-06-09)

Settled in a live aidc dev container (`continue-test`, isolated `~/.claude.json`, the
non-rotating long-lived OAuth token — so no race with any other session):

| Step | Action | Transcript result |
|------|--------|-------------------|
| 1 | `aidc-claude --print "…ALPHAONE"` (fresh) | **1 file** created; `user:ALPHAONE → assistant:ALPHAONE` |
| 2 | `aidc-claude --print "…BETATWO"` (wrapper auto-adds `--continue`) | **same file**, grew 9137→11786 B; `user:BETATWO.parentUuid == turn-1 assistant uuid`; **no new file, no re-emit** |
| 3 | interactive `aidc-claude` launch (`claude --continue`) | **same file, byte-unchanged**; resumes in place |
| — | summary-flag lines (`isCompactSummary`/`isVisibleInTranscriptOnly`) | **0** in this session |

Conclusion: the `(role, text-hash)` re-emission guard previously held as a fallback is
**not required** for `--continue`. The `isCompactSummary` / `isVisibleInTranscriptOnly`
skip is still required for the *separate* mechanism of mid-session **auto-compaction**
(context overflow injects one flagged `user` summary line in place — verified earlier from a
real 8548-line transcript at line 3395). Both mechanisms are now characterized; no open
empirical question remains.

---

## Retry on failure — no silent drop (MCP-18)

On a delivery whose POST raises (connection/timeout) or returns non-2xx:

- **Do not advance the high-water mark.** The same turn is retried.
- **Bounded backoff:** immediate, then 2s, 4s, 8s, 16s, 32s, capped at 60s, for a total
  wall-clock bound of ~30 min per turn. Each attempt logs (MCP-19).
- **Abandonment (dead-letter):** if the bound is exhausted, write the undelivered turn
  (conversation_id, uuid, content, last error) to
  `~/aidc-mcp-audit/watcher-state/dead-letter/<...>.json`, log a terminal
  `delivery_abandoned`, and advance the mark so later turns are not blocked head-of-line.
  This satisfies "MUST NOT be silently lost" (it is durably recorded + logged) while
  preventing a permanent stall.

Head-of-line policy: a turn is retried to confirmation or dead-letter **before** the next
turn is delivered, preserving order. (A future enhancement could pipeline, but ordering is
the safer default for a conversation.)

---

## Delivery payload & observability

**Payload** is backward compatible with the original contract, so the MetaLLM side needs no
change: `POST {callback_url}/api/v1/internal/callback/{conversation_id}` with
`{"content": <text>, "ok": <bool>, "source": "agent_watch", "session": <name>,
"prompt_origin": "terminal" | "orchestrator" | ""}` and `Authorization: Bearer <mcp-token>`.
`session` names which aidc session finished the turn; `prompt_origin` says whose prompt it
answers (next section).

---

## Terminal-typed prompts — telling the person's prompt from the orchestrator's

A person attached to the session (`aidc attach`) can type straight into the same Claude
the orchestrator drives over `session_send`. The reply to such a prompt completes a turn
like any other and is delivered over the same webhook — but the orchestrator never saw the
prompt, so it read the reply as an answer to whatever *it* last sent and could not tell
where the new instructions came from.

**Verified (2026-09-11, live `metallm` transcript):** a prompt pasted by the MCP and one a
person typed are structurally identical in the JSONL — both are `type: user` lines with
`origin.kind: "human"` and `promptSource: "typed"`, and the pasted text is transcribed
byte-for-byte (lengths matched the audit log's `prompt_len` exactly; no `[Pasted text]`
collapsing). So the transcript alone cannot attribute a prompt; the MCP's own memory of
what it sent can.

Mechanism (`transcript.py` + the drain in `tools.py`):

- **Send record.** `_inject` is the only way a prompt reaches the pane, and it is the only
  writer of the record: every successful paste (`session_send` direct or queued,
  `session_run`) appends the prompt's whitespace-normalized sha256 to a per-*session* file
  under the watcher-state dir (`<session>.sent-prompts.json`, atomic temp+rename like the
  watermark).
  Durable so an MCP restart between a send and its reply does not mislabel the
  orchestrator's own prompt as the person's. Bounded (200 entries, 24h TTL) so a paste that
  never landed cannot linger and swallow a person later typing the same words.
- **Turn prompts.** `extract_completed_turns` now records, on each `Turn`, the
  person-eligible prompt lines that opened it (`Turn.prompts`). Consecutive real user
  prompts with no assistant line between them (an auto-continue then the ask; a slash
  command then its hook feedback) all belong to the turn that follows, so they accumulate
  instead of being dropped by the boundary flush. `human_prompt_text` excludes what Claude
  Code writes on the user's behalf: `isMeta` lines (hook feedback, skill bodies, system
  reminders, "Continue from where you left off."), `promptSource != "typed"` /
  `origin.kind != "human"` (task notifications), any line that *opens* with a wrapper tag
  (`<local-command-stdout>`, `<bash-input>` / `<bash-stdout>` from `!` mode, and whatever
  wrapper a later Claude Code adds — these carry no provenance fields, so the rule fails
  closed), and the `[Request interrupted by user ...]` markers with or without an
  `interruptedMessageId`. The one tagged line a person types is a slash command, rendered
  compactly as `/name args`.
- **Attribution at delivery.** For every extracted turn (empty ones too, so each record
  entry is consumed exactly once; a turn the ledger already holds is skipped, so a
  re-surfaced turn cannot eat the entry of the next identical send) the drain matches
  each prompt against the send record; a match consumes one entry. Prompts that do not
  match were typed at the terminal and are prepended to the delivered content under a
  note addressed to the orchestrating LLM
  (`TERMINAL_PROMPT_NOTE`), followed by a `---` rule and the reply. `prompt_origin` is
  `"terminal"` when any prompt was typed, `"orchestrator"` when all matched, `""` when the
  turn had no prompt of its own (a continuation, or a system-sourced prompt).
- **Exactly-once is unaffected.** The delivery ledger fingerprint stays on the *bare*
  reply text: a re-surfaced turn's record entry is gone by then, so its framing would
  differ, and keying on framed content would let the ledger miss it. `session_resend`
  therefore re-posts the bare reply (no note) — it cannot know the origin after the fact.
- **Observability.** `transcript_terminal_prompt` carries `record_remaining`, the count of
  live unmatched entries. A real typed prompt leaves it flat; a count that climbs with
  every reply means matching has drifted (e.g. a Claude Code that collapses pastes) and
  every reply is going out under the note.
- **Failure posture.** A record that cannot be written after a paste, or read/updated at
  delivery, is logged (`session_send_record_failed`, `transcript_sent_record_failed`) and
  the prompt counts as the orchestrator's own. Claiming "the user typed this" about a
  prompt the orchestrator sent is the confusion this exists to remove, so it is the side
  never to err on.

**Logging (MCP-19)** reuses the events already added in `dc66df9`
(`watcher_callback_attempt` / `_ok` / `_http_error` / `_failed`, with status, `elapsed_s`,
size, and `error_type` + `repr` on failure), extended with delivery-source context:
`session_id`, `turn_uuid`, `byte_offset`, and `attempt` number. New structural events:
`delivery_turn_abandoned`, `delivery_empty_turn`, `delivery_rotated`, `delivery_abandoned`.

---

## Edge cases

| Case | Handling |
|------|----------|
| Tail ends on noise lines | Scan for structural turn boundary, not the last line. |
| Partial trailing line (mid-append) | Buffer the incomplete bytes; reparse next poll. |
| `stop_reason: null` then a `user` line | Turn abandoned; log + advance, no delivery. |
| Tool-only turn, no text | `delivery_empty_turn`; advance, no delivery. |
| API-error assistant turn | Deliver `ok:false` with error text; advance. |
| Active file genuinely rotates (pinned file gone) | Re-resolve; forward-baseline onto the new file (deliver nothing from its history). |
| Mirror re-touches an old file's mtime | Pinned to the tracked `session_id`; no flap, no replay. |
| Torn/partial mirror read | Last-delivered uuid missing from pinned file → skip pass, retry next poll. |
| Empty `end_turn` then real answer | Coalesced into one turn; held until the transcript settles. |
| Dev container down during poll | Transcript dir stale/unwritten; log, retain state, retry next poll. |
| MCP restart | Watcher re-registers on next `session_*`; resumes from persisted HWM. |
| Turn stops on AskUserQuestion/ExitPlanMode | Denied at launch (Layer 1); if seen anyway, delivered as its own turn with the rendered question (Layer 2). |
| EnterPlanMode (plan mode) | Denied at launch — no human to approve the exit, so the session would otherwise strand read-only. |
| Terminal line with no / null / non-str `uuid` | Not treated as terminal — an empty anchor would replay the whole file. |
| Text on a non-terminal line after a terminal | Committed text is snapshotted at each terminal; trailing text is deferred to its own later turn (no double-send). |
| Crafted line (unhashable/non-str field, deep nesting) | Skipped by str-gated membership + `RecursionError` catch; watcher never crashes. |

---

## Rollout

1. Implement transcript reader + turn detector behind the existing watcher entry points,
   writing the persisted HWM, with the tmux path still present.
2. (`--continue` re-emission is settled — see "Empirical verification" above; no hash guard
   needed. Retain only the `isCompactSummary`/`isVisibleInTranscriptOnly` skip for
   auto-compaction.)
3. Cut delivery over to the transcript source; reduce `capture-pane` to the synchronous
   convenience return only.
4. Remove `_wait_for_idle` / `_extract_delta` / `_strip_ansi` from the delivery path.

Each step is independently testable; the test suite in `mcp/tests/test_session_watch.py`
extends with transcript fixtures (recorded `.jsonl` lines) for turn detection, exactly-once
across a simulated rotation, and retry/dead-letter behavior.

### Implementation status

- **Chunk 1 — core (done).** `aidc_mcp/transcript.py`: parse / turn-detect / text-extract /
  exactly-once dedup / durable watermark / backoff / active-file resolution.
  `mcp/tests/test_transcript.py` (31 tests).
- **Chunk 2 — delivery loop (done).** `tools.py`: `_post_turn` (instrumented),
  `_deliver_with_retry`, `_write_dead_letter`, `_drain_transcript_once`,
  `_run_transcript_watcher`. Added alongside the tmux watcher (no cutover yet).
  `mcp/tests/test_transcript_delivery.py` (9 tests).
- **Chunk 3a — surfacing (done, copy-forward / in-container mirror).** Decision:
  **in-container mirror** (not a sidecar) — the isolation delta is marginal because the
  adversary authors the delivered content in every design; the one real vector (a planted
  symlink read by MCP) is closed at the trustworthy layer (`resolve_active_transcript` skips
  symlinks / non-regular files). Wiring: `cmd-create.sh` creates
  `~/aidc-mcp-audit/transcripts/<session>/` and binds it to `/var/aidc/transcript-out` in
  the dev container (`TRANSCRIPT_MIRROR_MOUNT`, threaded through `compose-render.sh` +
  `compose.yaml.template`); `user-main.sh` runs a ~2s copy-forward loop
  (`~/.claude/projects/<enc>/*.jsonl` → the mount, regular files only, `cp -pu`). Validated:
  `docker compose config` parses with and without the mount; suite 65 passing.
- **Chunk 3b — cutover (done).** `_run_transcript_watcher` is now the live delivery path
  behind `session_send` / `session_run` / `session_watch`; the old
  tmux-scraping watcher (`_run_watcher`) and its callback instrumentation are removed.
  `capture-pane` / `_wait_for_idle` / `_extract_delta` remain **only** for the synchronous
  "response returned directly" convenience value of `send`/`run` — they are no longer in the
  callback delivery path. The "failed callback logs why" contract (the original incident) is
  ported onto `_post_turn` (`test_transcript_delivery.py::TestPostTurnInstrumentation`).
  **Live end-to-end validation still owed** on a real aidc host (create → mirror surfaces
  transcript → drain → callback lands in the MetaLLM conversation) — appropriate for the
  current test loop (Pace + Saoirse), where breakage is observable and cheap to fix.
- **Chunk 4 — interactive-tool deadlock + hardening (done, v0.4.3).** Two layers for the
  AskUserQuestion/ExitPlanMode deadlock (see "Interactive-input tools" above): Layer 1 denies
  the tools in the `aidc-claude` wrapper (`.devcontainer/Dockerfile`); Layer 2 delivers the
  block if it appears (`extract_completed_turns` — interactive-block detection, question
  rendering, flush-as-own-turn). Same pass hardened the parse/extract layer against
  attacker-authored transcripts (str-gated membership + `RecursionError` catch), fixed the
  empty/null-`uuid` watermark-replay hole, and reworked coalescing to a committed-snapshot so
  text after a terminal is never re-delivered. `mcp/tests/test_transcript.py`,
  `test_transcript_delivery.py`, `test_aidc_claude_wrapper.py` (98 tests). **Live end-to-end
  validation still owed** (confirm the deny suppresses the widget under bypass mode in a real
  session; the flag is doc- + parse-verified but not runtime-verified).

---

## Cross-references

- Requirements: MCP-15..MCP-19 (`docs/requirements.md`).
- Current implementation being replaced: `mcp/src/aidc_mcp/tools.py` (`_run_watcher`,
  `_wait_for_idle`, `_extract_delta`, `_strip_ansi`, `_capture_pane`).
- Delivery instrumentation already landed: commit `dc66df9`.
- MCP control plane: `docs/design-08-mcp-control.md`, MCP-01..MCP-14.
- The `aidc-claude` wrapper (`--continue` + project encoding): `.devcontainer/Dockerfile`.
- Incident analysis that motivated this: conversation-2026-06-08.

---

## Tool-description discipline for small models (MCP-21 / MCP-22)

The orchestrator may be a smaller/cheaper model (Haiku-, DeepSeek-class). Two things make
those models select and call the right session tool reliably:

1. **Trigger-first, mutually-disambiguated descriptions.** Each of `session_invoke` /
   `session_invoke_async` / `session_send` / `session_run` opens with WHEN to use it and a
   "WHEN NOT → use *that* tool" line. Smaller and more conservative models get measurable
   lift from a stated trigger condition vs a mechanism-only description. Every parameter
   carries a description; `conversation_id` is marked *auto-injected / do-not-set* so a weak
   model doesn't invent one. (Implemented via `Annotated[..., Field(description=...)]` —
   the installed FastMCP does not parse Google-style `Args:` docstrings into the schema.)
2. **Open-webhook session list in the description** (MCP-21) removes the need to remember the
   target session across turns — DeepSeek is documented as weak at multi-turn tool calling,
   so self-contained calls help disproportionately.

> **Wording is not the on/off switch.** Whether a small model *calls* a tool at all also
> depends on the orchestrator's `tool_choice`: DeepSeek `tool_choice="auto"` is widely
> reported to under-trigger (answer with text instead of calling). Good descriptions move
> reliability from ~good to ~better; the orchestrator (MetaLLM) still owns the `tool_choice`
> decision. See conversation-2026-06-09 and the DeepSeek/Anthropic tool-use sources cited there.

`strict: true` tool schemas (Haiku-friendly, harmless for DeepSeek's OpenAI-compatible API)
are a candidate follow-up — gated on confirming the installed FastMCP exposes per-tool
`strict`.
