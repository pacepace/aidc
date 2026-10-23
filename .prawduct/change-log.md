# Change Log — aidc

<!-- Append new entries at the top. Each entry is a ## section.
     This file is separate from project-state.yaml to reduce merge conflicts
     when multiple branches add entries simultaneously.

     # Tagged entries

     This file is PROSE. Its body is what a reader — and a release note —
     actually gets. Two machine-read keys ride in a tag-line directly under
     the ## header, and `check-releasability` is the only thing that reads
     them:

         ## YYYY-MM-DD: title (vN.M.P)

         <!-- prawduct: scope=v1.4 | release=v1.3.18 -->

         **Why:** ...

     Recognized keys:
       scope    - rollup identifier (e.g., v1.4), matching the `scope:`
                  frontmatter of the build plan that governs the work.
       release  - the version that carried this entry. Its ABSENCE is what
                  marks the entry release-pending, so write NO release= on
                  the feature branch and add it at release. Any value at all
                  — including a placeholder naming the absence, e.g.
                  `release=unreleased` — drops the whole scope out of the
                  release-pending set and silently unships the work.

     Nothing else is read. `chunks=` and `status=` were retired along with the
     derived views they fed; entries in older logs still carry them and are
     parsed as inert — leave them. Which chunks an entry shipped belongs in
     the entry BODY, where release notes and readers actually find it: a
     deliverable omitted from the body ships invisibly, and no tag ever
     caught that either. -->

<!-- Older entries live in .prawduct/change-log-archive/YYYY-MM.md, moved there verbatim by `prawduct-hook archive-change-log`. -->

## 2026-10-23: What a busy session is doing, joining its turn, and headless runs that are fresh, single and stoppable (v1.9.8)

<!-- prawduct: scope=turn-visibility-and-join | release=v1.9.8 -->

**Why:** 2026-10-22, metallm. An orchestrator `session_send` waited 45 minutes (18:33 to 19:18Z)
behind one turn that a background task's notification had opened, while `session_status`
named the person's earlier prompt as what the agent was working on. Pace asked that callers be
able to tell an agent is mid-flight and choose to queue, join or interrupt ("yes" to this design).
Later that night four `session_invoke` calls left two `claude --print` runs editing the same spec
23 and 9 minutes after their callers gave up, each resuming the resident agent's whole
conversation. Pace's rulings: no timeout on session_invoke; one headless run at a time per dev
container; long work belongs to session_send, and the tool text must say so; metallm probably
sends nothing when its stop button is pressed, so design for no cancel arriving.

**What:**
- Turn info (design 10 S5, MCP-40): `transcript.open_turn` finds the open turn's opening line;
  `turns_view.turn_info` gives `working_on`, `started_by`, `turn_started_at`, `last_activity`
  on `session_status`, `session_interrupt`'s `was_running`, and a queued or joined
  `session_send`. A notification line was being read as local-command output (it opens with a
  tag), so a notification turn looked idle until Claude's first line; it and another session's
  message now read busy.
- `session_send(deliver="join")` (MCP-41): pastes into the running turn, `joined_turn`, or
  queues with `join_declined`. `_prompt_arrived` also releases the send record of a prompt Claude
  Code held and ran next (`promptSource: "queued"`).
- Headless runs (design 10 S6, MCP-42/43, new `headless.py` and `disconnect.py`): the wrapper
  never adds `--continue` to `--print`, and the MCP passes `AIDC_CLAUDE_RESUME=false`; runs are
  tagged with `AIDC_HEADLESS_RUN`; one per session (`invoke_busy`), counting orphans found in the
  container; `headless_runs` on `session_status`; stopped in the container on cancel, session
  close or dropped connection (the SDK does not cancel on the last; measured with a real
  transport test), and on `session_invoke_async`'s 30-minute limit;
  `session_interrupt(target="headless")`. Tool descriptions, server instructions and README lead
  with the rule.
- Tests: `test_turn_info.py` (fixture with the shapes of the metallm transcript, private words
  replaced), join and held-prompt cases in `test_turn_state.py`, `test_headless.py` (the
  in-container scripts against real /proc processes), `test_invoke_cancel_wire.py` (uvicorn and
  a real HTTP client), wire tests, `tests/unit/test-aidc-claude-resume.sh`, and a smoke step.

**Review:** cumulative Critic rev-20261023T000723Z-e59116f0, 0 blocking and 6 warnings; five
fixed here (verified, rev-20261023T002708Z-672def60), and the sixth, a live run of a real join,
done afterwards (Live check, below): one rule for "a turn is open" (open_turn defers to log_shows_turn_in_progress, with a
test that they agree at every line of every fixture, and session_send fills the turn fields
under session_status's rule); a joined prompt's reply now carries the joiner's prompt_origin
(_prompt_arrived records it when it releases the send record); the unreachable headless_runs
field of a session_invoke result removed; `stopped` always a list; a failed in-container stop is
`headless_stop_failed` and `interrupted: false` with the reason, never an empty success. Notes
also taken: the shared TERM/KILL snippet, the disconnect callback passed in rather than set on
import, session_queue_cancel's full turn info, a session_invoke_async stopped before it starts
never starts, _invoke_locks pruned with the session. The smoke step moved ahead of the taint
step (a tainted session's container is paused and takes no exec).

**Live check** (2026-10-23, the review's sixth warning, now done): a throwaway session
`joinlive` created with Pace's long-lived token (installed for that create only, then removed),
driven through aidc/mcp:v1.9.8 on a loopback port with a local webhook. Background-task turns read
`started_by: background_task` with their summary and start time; a foreground turn read `prompt`
with `last_activity` Bash. `deliver="join"` returned `joined_turn`; the transcript showed the
queue-operation enqueue (03:30:20) and its `absorbed_mid_turn` removal (03:31:12); the MCP logged
`session_send_joined_turn` and `session_send_queued_by_claude`; the turn's final reply carried
`JOIN-ANSWER=42` to the webhook with `prompt_origin: orchestrator`. A `deliver="queue"` send waited
as `claude_busy` and was answered as its own turn. `session_invoke` answered in 10 s; a second one
was refused `invoke_busy`; `session_interrupt(target="headless")` stopped a run and its tree
(three pids), leaving no `claude --print` in the container.

It found one defect, fixed in 6875690 with tests: a headless run's transcript (entrypoint
`sdk-cli`, written beside the session's) was followed by the watcher as the newest, and the
invoke's answer reached the webhook as the session's reply; it is now never taken for the
session's. Also: `invoke_busy` names the running run's pid, and a stopped invoke says it was
stopped. Re-checked live on a rebuilt image: no invoke answer reached the webhook, the session's
reply did, and no transcript move was logged. Verify-resolutions rev-20261023T034235Z-36a8e86a:
0 findings.

**Not done:** the invoke guard and a join are not in `make smoke` (its session has no Claude
login); they were checked live as above.

## 2026-10-22: Dependabot advisories cleared, and aidc-mcp moved to MCP SDK 2.3

<!-- prawduct: scope=dependabot-pyjwt-certifi | release=v1.9.7 -->

**Why:** pacepace/aidc had fifteen open Dependabot alerts, all on `mcp/uv.lock` with
runtime scope: certifi 2026.7.22 (#27, critical: GHSA-6q48-6c7w-9gw2, the
`emSign ECC Root CA - G3` root, eight of whose intermediate CAs have compromised keys) and PyJWT 2.13.0 (#13-#26: critical, high and medium).
PyJWT is transitive through `mcp`; aidc-mcp does not import jwt. certifi comes in through
httpx and httpcore. Pace then widened the scope (2026-10-22): "let's do the mcp upgrade too".
That meant upgrading the whole lock and moving from mcp 1.30.0 to 2.x, with nothing a client
sees allowed to change.

**What:**
- certifi 2026.10.19 and PyJWT 2.15.1. #24 and #26 needed 2.15.0. #25 lists no patched
  version, but its range ends at 2.13.0 and its fix commit (0c87c8c) is an ancestor of
  the 2.14.0 tag (GitHub compare). certifi 2026.10.19 was uploaded on 2026-10-20, inside
  the REL-09 cooldown, so it gets a per-package `exclude-newer-package` cutoff
  (2026-10-21T00:00Z, which admits that release and nothing later) with its reason beside it
  in `mcp/pyproject.toml`. The cutoff is a fixed date, so after 2026-11-03 it only holds
  certifi back. tests/unit/test-supply-chain-cooldown.sh fails once any `exclude-newer-package`
  cutoff is older than the cooldown (after 2026-11-04T00:00Z for this one, checked with
  `COOLDOWN_NOW`; its fixtures fail on an old cutoff in both TOML forms), so it cannot be
  forgotten. The built image's bundle was checked: v1.9.6 has the four
  emSign roots, and v1.9.7 has all of them except ECC G3, which is what the advisory's fix does.
- `constraint-dependencies` floors (`pyjwt>=2.15.0`, `certifi>=2026.10.19`) under
  `[tool.uv]`. Under the cooldown alone, a re-lock left certifi at 2026.7.22. With the floor
  and the exception removed, `uv lock` fails to resolve instead (checked). They are
  constraints, so neither package becomes a direct dependency.
- `uv lock --upgrade` for everything else, all inside the cooldown. mcp 1.30.0 -> 2.3.0
  brings mcp-types, httpx2 (with httpcore2 and truststore) and opentelemetry-api, and
  drops httpx-sse and pydantic-settings. The full list is in the CHANGELOG.
- The SDK 2.x port, covering the surface the 2.x migration guide changes for aidc:
  `FastMCP` -> `MCPServer`; `transport_security` moved to `streamable_http_app()`; and
  `get_context()` removed. That last one is what the tools/list_changed announcement used, so
  session_send, session_watch and session_unwatch now take the injected Context and pass it on.
  Since a client on protocol 2026-07-28 receives list changes only on a `subscriptions/listen`
  stream, the announcement also publishes there (`ctx.notify_tools_changed()`). The server
  also passes `version=` (serverInfo.version was the SDK's version), and publish.py reads
  `Tool.input_schema`. `server.build_app()` is what `main()` serves.
- Checked and left as is: 2.x runs a synchronous handler in a worker thread, but every
  registered function is already a coroutine (`off_loop`, test_offload). The 4 MiB body
  limit and 30-minute session idle timeout were already the 1.30 defaults. With the stricter
  template matching, a `filename` of `..` in `aidc://sessions/{name}/audit/{filename}` is now
  refused by the SDK as an unknown resource (-32602). Before, aidc's own check answered
  `{"error": "path traversal denied"}`; that check stays as a second line. `ctx.info` progress streaming still reaches
  2025-era clients; it is deprecated (SEP-2577) and reaches a 2026-07-28 client only if
  that request opts in to log delivery.

**Tests:** new `tests/test_wire.py` drives `build_app()` over streamable HTTP as a
2025-11-25 client: no token or a wrong token gives 401, a private-interface Host is served,
the handshake carries the aidc name and instructions, and tools/list matches
`published-tools.json`; it also covers a tool call and resources/list. It passed on 1.30.0
before the port and on 2.3.0 after. After the Critic review (rev-20261022T142758Z-377a7fbe,
W2) it compares every tool description in full, the open-webhook suffix included, checks
the resource list and the three template URIs exactly, and reads `aidc://sessions/proj/audit/..`
over the wire, which must be refused (SDK -32602, or aidc's traversal denial). Mutations
checked: shortening the suffix fails the tools/list case, and exempting `filename` from the
SDK's path check while disabling aidc's check fails the traversal case.

Smoke did not exercise aidc-mcp before this change. Its only MCP check read the running
aidc-mcp's port binding to test the egress refusal, so it never sent a request to the server
or used the image this checkout builds. New step 9a runs `aidc/mcp:<VERSION>` the way `aidc mcp
start` does (docker socket, the aidc tree read-only, a token file). It uses an ephemeral loopback
port and its own name, so a serving aidc-mcp is untouched. It then speaks MCP over HTTP with
curl. The handshake must name aidc at the release version, and a call with no token must get
401. tools/list must equal published-tools.json (less the opt-in session_create).
session_list, run by the aidc CLI inside the container, must list the smoke session, and
session_status must report it tainted. 109 passed, 0 failed. The cooldown scan now also
reports an `exclude-newer-package` it cannot read (a multi-line inline table, a dotted key)
instead of passing it. That was Critic observation 1 of rev-20261022T143917Z-169f256c, and a
new fixture covers it. A full wire dump (initialize, tools/list, resource and
template lists, a tool call and a tool-argument error) is byte-identical between the two
SDKs except for serverInfo.version (SDK version -> aidc version) and an empty
`capabilities.experimental` that 2.x leaves out. New announce tests cover both notify
paths, the no-request path, a failed legacy notify still publishing, and `ctx` being
injected but not advertised. Existing tests changed only in the import rename and in the
`_announce_watchers` stubs taking the optional ctx. No assertion was changed.

## 2026-10-22: session_send takes prompts while a background agent runs, and answers promptly

<!-- prawduct: scope=send-while-background-task | release=v1.9.6 -->

**Why:** metallm conversation 01a15184, 2026-10-21/22. Session `metallm` finished its reply and
sat at its prompt with one background agent running. A session_send at 23:56:37 took 14.7 s to
return "queued" and was pasted 5 min 11 s later; the next send took 12.6 s to return "sent". The
access log gave the reason: `session_free_check reason=screen_unrecognized turn=idle
why=log_finished`. The saved capture (`watcher-state/screens/metallm-unrecognized.ansi`) showed
the agent-list row under the mouse drawn `❯ ◯ general-purpose …`, a pointer `screen.py` did not
accept. The slow answers came from the orchestrator's unwatch/watch before each send:
unwatching dropped the cached newest-message stamps of the session's earlier transcripts (28
files, 775 MB), and the new watcher's first pass re-read them all on the event loop (about 9.3 s
measured on the real files), during the send's 2.5 s gap between free readings.

**What:** `screen.py` accepts the pointer on agent rows (`agent_pointed`) and recognizes a
keyboard selection in the list by the key hints that replace the status row (`list_focused`).
Measured on a local Claude Code 2.1.304: a selected list still takes a multi-character paste into
the input box, but a single `x` stopped the selected agent. So a focused list holds prompts
(new waiting reason `agent_list_selected`); with only the pointer, `_inject` pastes and presses
Enter once the input box shows text, and a paste that shows late is submitted by the drainer
when it is still the queue head (`_unsubmitted_paste`, `_own_unsent_text`), otherwise held as
unsent input. A running main turn still queues. `forget_transcripts` keeps the per-file stamps
(dropping only files that are gone), the sibling scan runs in a worker thread
(`_newest_of_siblings`, the lock narrowed to the cache), and `_wait_until_free` is bounded on the
clock as well as in polls, with a free reading always confirmed by a second. Measured on the
real metallm files after the fix: a drain after unwatch 0.15 s; a cold drain still 9.4 s of wall
time but at most 0.25 s of event-loop stall. Tests: real screen fixtures (sanitized from the
live capture), session_send through the real free check for idle+background, focus, late and
non-queued pastes, the clock bound, and the cache kept across an unwatch.

Reviews: rev-20261022T002658Z-7296f4d7 (0 blocking; observations fixed or accepted, among them
keystrokes into a focused list and the late-paste wedge), verify-resolutions
rev-20261022T004233Z-86b4d4f2 (1 blocking: a late session_run paste merged into the next
prompt; fixed by the queue-head check), rev-20261022T004749Z-5c6761a2 (0 findings). Not done:
the unsubmitted-paste record is in memory only, so after an MCP restart a late paste is held as
unsent input (fails safe).


## 2026-10-22: the malware blocklist's feeds: URLhaus from a keyless mirror, ThreatFox dropped

<!-- prawduct: scope=malware-feeds-keyless | release=v1.9.6 -->

**Why:** found by the v1.9.6 `make smoke` run, 2026-10-22. `https://urlhaus.abuse.ch/downloads/hostfile/`
and `https://threatfox.abuse.ch/export/csv/recent/` both answer 410 Gone: abuse.ch now requires a
per-user Auth-Key for every export. The refresher had been building the list from HaGeZi TIF
alone, and nothing said so, because a refresh that succeeds on one feed still publishes (NET-11).
The same run's HaGeZi TIF download (about 39 MB) hit curl's 60 s limit at 31 MB under load.

**Decision (Pace, 2026-10-22):** "let's see if we can find suitable replacements for the two
missing ones please, and if we can't then we drop to just the one." So no Auth-Key is held;
each feed is replaced by a keyless source where one exists, and dropped where none does.
- URLhaus: replaced by the malware-filter project's mirror of URLhaus data
  (`https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts.txt`, falling back to
  `https://curbengh.github.io/malware-filter/urlhaus-filter-hosts.txt`): hosts format, rebuilt
  every 12 h, about 1,800 domains.
- ThreatFox: dropped. No keyless source of its data was found.
- **Trust shift.** The URLhaus entries now come from a single maintainer's rebuild (curbengh,
  malware-filter) rather than from abuse.ch. Anything that mirror publishes is denied by squid,
  and the first request to a listed domain taints the session; under `taint_response: freeze`
  the dev container is paused. A wrong or hostile entry (a widely used domain) would therefore
  freeze any session that touches it, and an entry the mirror drops would no longer be blocked.
  Both mirrors are the same maintainer's, so the fallback covers an outage, not a bad publish.
  NET-04 and SEC-03 in `docs/requirements.md` are amended to the two feeds and point here;
  `docs/security-model.md` states the trust shift.

**What:** `proxy/refresher/refresh.sh` fetches the URLhaus mirror (gitlab, then github, the
fallback logged), drops the ThreatFox fetch, parse and count (summary line now
`urlhaus=N hagezi=N additions=N`), gives HaGeZi TIF `--max-time 300` (every fetch
`--connect-timeout 15`), and logs a `WARN <feed>:` line for a feed that failed or yielded 0
entries. New `tests/unit/test-refresher-feeds.sh` runs the real refresh.sh against a curl stub:
parsing, the fallback order, the timeouts, the WARN lines, and NET-11's kept list. The smoke now
waits for the startup refresh to finish (either way) for longer than the refresher's worst case,
requires it to have succeeded with entries, requires urlhaus and hagezi each above 0, and names
the missing list instead of requesting an empty domain. Not done: `aidc status` does not show a
lost feed; filed as #60.


## 2026-10-19: the loop guard no longer drops replies to a person's own prompts

<!-- prawduct: scope=loop-guard-human-turns | release=v1.9.5 -->

**Why:** found reviewing metallm's MCP history, 2026-10-19. The loop guard caps an unbroken run of
deliveries (more than 20, reset only by a 15-minute idle gap) to stop an orchestrator and a session
answering each other forever. On 2026-10-08 at 05:56:43 it dead-lettered metallm's reply to Pace
("`aidc-mcp-dev` is confirmed on `aidc/mcp:dev-local-command` ...") while Pace was working at the
terminal: the run that tripped it, reconstructed from the access log and the conversation's
delivered ledger, was 11 replies to typed prompts and 9 turns no one prompted (task
notifications, a subagent hand-back, the turn after a safety-classifier stop), with no
orchestrator prompt at all. The guard counted every delivery; a runaway needs the orchestrator's
prompts, and a typed one proves a human is there.

**What:** the loop guard (in `_drain_once_body`, under `_drain_transcript_once`) resets the run on a delivery whose origin is `terminal` or
`person` and does not count it; replies to the orchestrator's prompts, and turns no one prompted
that carry that origin (`_carry_prompt_origin`), count as before. Origin rests on matching each
prompt to the send record, and that can fail (a failed record write, an expired entry, paste
drift like 2026-10-08's), which would let a runaway read as typed and never trip; so a backstop,
`_LOOP_GUARD_BACKSTOP` = 100, caps every delivery since the last idle gap whatever its origin
(new persisted `deliveries_since_idle`, loading as 0 from older watermarks). Tests: a morning at the terminal
with task notifications between prompts delivers past the cap with nothing dead-lettered (the
10-08 shape); a typed prompt, and a prompt sent for a person, mid-run let two runs below the cap
deliver together; continuations of the orchestrator's turns still trip it; a runaway with no send
record hits the backstop (red with the backstop disabled), and an idle gap resets it. Live: the
real 10-08 metallm transcript replayed through the drain under a constant clock (no idle resets)
from midnight to 05:57: the old code dead-letters 7 replies, the lost one among them; the new
code delivers all 27. The pre-existing guard
tests built their runaways from prompts with no send record, which the drain now reads as typed at
the terminal; their fixtures record those prompts as the orchestrator's sends, as session_send
does, and every assertion is unchanged (TestLoopGuard and the transcript-move test).

Review rev-20261019T045416Z-1738de1c (0 blocking): O-1 the backstop above; O-2 the "no human at
the pane" premise is gone from the comments. Cumulative rev-20261019T050219Z-0b5052d1 (0
blocking): R-1 the CHANGELOG names the backstop; R-2 the comments no longer say only an idle gap
resets the run; R-5 this entry names `_drain_once_body`.

Also on this branch: the shipped change-log entries since v1.8.3 carry their `release=` (mapped
from the tag that first contained each entry's commit), and compose-render.sh's header names
`aidc_claude_project_name` as ENCODED_REPO's rule. Looked at and not changed: the 10-15 queued send
held 25 minutes by `screen_unrecognized` was the agent-panel screen v1.9.1 fixed (the saved capture
classifies as idle on the current parser, and a fixture covers it); the abandoned deliveries were
the orchestrator answering 404/502; the October dedupe followed a stale-pin recovery and stopped a
duplicate, as designed. #55 stays open: sessions restart with the daemon (`unless-stopped`) before
any aidc command runs, so every fix trades something (a session down after a reboot, a wider mount,
or root repairs on every command) and needs Pace's call.
