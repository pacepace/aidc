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

## 2026-10-22: the malware blocklist's feeds: URLhaus from a keyless mirror, ThreatFox dropped

<!-- prawduct: scope=malware-feeds-keyless -->

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

<!-- prawduct: scope=loop-guard-human-turns -->

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


## 2026-10-19: a memory dir Docker made as root no longer silences a session

<!-- prawduct: scope=memory-dir-writable | release=v1.9.4 -->

**Why:** live, 2026-10-19, session handmcp: Claude showed "Transcript writes are failing
(permission denied — EACCES)". The bridged memory dir `~/.claude/projects/<enc>` on the host was
root:root 0755, born 01:38:22 between the session's first container (00:43) and its second
(02:03), with no aidc command at that time. Docker materialises a missing bind-mount source as
root whenever it starts a container, so the dir had gone missing and Docker made it again; the
02:03 `aidc create`, run on the host, found it present and mounted it as it was
(`aidc_mkdir_host` repairs ownership only inside aidc-mcp). For half an hour Claude saved
nothing and the MCP saw no transcript (`session_send_not_seen_in_transcript`). Fixing the
ownership exposed a second fault: the Claude that had been unable to write left a transcript
holding only bookkeeping (cost-state, mode, a file-history snapshot) on exit, `aidc-claude` saw
a `*.jsonl` and passed `--continue`, and `claude` exited with "No conversation found to
continue".

**What:** `claude-state-install.sh` (now sourced by entrypoint.sh, user-main.sh, the
`aidc-claude` wrapper and cmd-create.sh) adds:
- `aidc_claim_docker_made_dirs`, run by entrypoint.sh as root on every start over
  `~/.claude/projects` and `/tmp/claude-<uid>`: each of those dirs, and each dir directly inside
  it, that root owns goes to vscode, non-recursively; a dir owned by anyone else is left alone.
  A claimed scratchpad dir also gets 0700, the mode create gives it. Not covered: when Docker
  also had to make the host's `/tmp/claude-<uid>` (after a reboot cleared /tmp), that parent
  stays root-owned on the host, since inside the container it is not a mount (backlog).
- `aidc_host_user_is_session_user`, the guard on that claim: it runs only when the bind-mounted
  repo's owner, seen from inside, is vscode's uid. Under rootless Docker the host user appears as
  root, so their own memory dir reads as uid 0 and an unguarded claim would take it from them; a
  host user whose uid is not the container's would lose a Docker-made dir to whoever holds that
  uid. Otherwise the entrypoint logs why it is not claiming.
- `aidc_transcript_dir_warning`, which user-main.sh logs when the project dir is still not
  writable. It and a failed claim carry one tag, `transcript-unwritable:`, and the new
  `relay_transcript_warnings` in common.sh repeats any line carrying it to the operator from
  `wait_for_dev_ready` (create, upgrade) and from cmd-restart.sh (this start's log only).
- `aidc_has_resumable_conversation` for the wrapper: a transcript must hold a `user` or
  `assistant` line. Any transcript counts, not only the newest: live, `claude --continue` (2.1.303)
  with a newer bookkeeping-only stub beside an older conversation resumed the conversation.
- `aidc_claude_project_name`, the one encoder for the project-dir name, used by cmd-create.sh's
  memory mount, user-main.sh's check and transcript mirror, the wrapper and the smoke test. Claude
  Code 2.1.303's encoder (read from its binary) replaces every non-alphanumeric character with
  "-"; aidc replaced only "/" and ".", so a repo path holding "_" or a space got a memory mount,
  mirror and resume check at a dir Claude never writes, and the MCP no replies. Paths over 200
  characters (Claude adds a hash) and non-ASCII paths (Claude counts UTF-16 units, this counts
  bytes) are not handled. An existing session on such a path needs kill+create: upgrade keeps
  its compose file, mount included.

Tests: test-claude-state-install.sh (claims, non-recursion, host-owned left alone, failure tagged
and non-zero; the guard for a matching, root and foreign repo owner; the warning silent for a
writable or absent dir and tagged for an unwritable one; the encoder on "_", space and
punctuation; the handmcp stub not resumable). New test-dev-ready.sh builds its log from those
functions' real output, so rewording a line cannot leave it green while the CLI goes quiet; a
quiet log does not trip `set -e` (the `|| true` is load-bearing: it caught its own removal during
the refactor). Live, aidc/dev-base:v1.9.3 with the branch entrypoint, library and wrapper mounted
over and a host memory dir Docker created as root, repo at /work/my_repo: with the repo owned by
the host user the dir is claimed, the host shows pace:pace, vscode writes, and the wrapper adds
`--continue` once a message exists (and not for no transcript or the stub); with the repo owned
by uid 1234 the claim stands down, the dir stays root:root, and the tagged warning is produced.

Review rev-20261019T024728Z-dfb55d9f: R-1 (blocking) the WARN had no test and its consumer
matched hand-typed wording; now a library function with a tag the consumer matches, tested from
real output. O-1/O-8 the root-ownership premise is checked (the guard above). O-2 settled live,
no change. O-3/O-4 the encoder is shared and corrected. O-5 the tag. O-6 the library header
rewritten. O-7 the entrypoint reuses CLAUDE_TMP_ROOT. O-9 restart relays the warnings. Backlog
#35 (symlinks in the bridged memory dir) is untouched: the claim skips symlinks and never
recurses. Cumulative rev-20261019T030421Z-60591e6e (0 blocking): R-1 the claimed scratchpad
gets 0700 and the comment states the parent it cannot reach (filed to the backlog); R-3 the
claim's bounds are written into docs/security-model.md as the security property; R-4 the
Claude Code facts are in claude-code-measurements.md (P1-P4). Verify rev-20261019T031033Z-22f7e282 caught
the split claim under the entrypoint's `set -e` (a failed memory-side chown would have skipped the
scratchpad side): both now run inside `aidc_claim_session_mounts`, each attempted regardless,
tested with a chown that fails on one side.


## 2026-10-19: aidc create from $HOME no longer reads ~/.profile as the profile

<!-- prawduct: scope=yq-expression-file-collision | release=v1.9.3 -->

**Why:** live, 2026-10-19: `aidc create` run from `~` on plexdock failed with "invalid profile
'# ~/.profile: executed by the command interpreter …'". yq decides which argument is its
expression by checking whether the first one names a file in the current directory; `yq eval
.profile <config>` run from `~` read `~/.profile` instead, and `_aidc_yaml_scalar` returned its
text. Any scalar key whose `.key` matched a file in the caller's directory was exposed.

**What:** `scripts/lib/yq.sh` adds `aidc_yq <expr> [args...]`, which passes the expression with
`--expression` when the installed yq offers it (the flag exists for exactly this) and the old
form otherwise. Every yq call goes through it: the scalar, list and `mcp.*` readers in
config.sh, `aidc_declared_networks` in network.sh, and the compose labelling in cmd-create.sh
(now `aidc_yq "<expr>" -i <file>`). config.sh and network.sh each source yq.sh themselves, so
neither depends on the other being loaded. test-config-sources.sh loads config from a directory
holding `.profile` and `.mcp.port` (red before the fix, under yq; green after under both
parsers) and checks `aidc_yq -i` edits in place. Live: `aidc config` and a throwaway
`aidc create` from `~` with the branch CLI read `profile: multi` and labelled every container.

Review rev-20261019T004817Z-4313009a (0 blocking): R-1 the flag probe piped yq's help into
`grep -q`, which under pipefail can SIGPIPE yq and fall back silently, and cached its answer inside
`$(...)`; it now runs once when yq.sh is sourced, with no pipe. R-4 `_aidc_has_yq` moved into
yq.sh, so `AIDC_NO_YQ=1` now also hides yq from network.sh and cmd-create.sh. R-2/R-3 a stub yq
covers both forms, and a guard fails on any `yq eval` outside yq.sh. Verified by
rev-20261019T005225Z-5b0eac65.


## 2026-10-08: a pasted prompt Claude Code wrapped is still the orchestrator's

<!-- prawduct: scope=local-command-opens-no-turn | release=v1.9.0 -->

**Why:** live, 2026-10-08: the MCP pasted an 844-character project brief, and Claude Code
2.1.284 transcribed it as `\n\n<pasted_content id="fab9">\n<brief>\n</pasted_content id="fab9">\n`.
`normalize_prompt` folded only whitespace, so its fingerprint differed from the send record's,
`consume_sent_prompt` found nothing, and the reply went out under `TERMINAL_PROMPT_NOTE` with
`prompt_origin="terminal"` and `speaker="human"`.

**What:** `transcript.unwrap_paste` removes one wrapper that encloses the whole text, with
matching ids. `normalize_prompt` calls it, so the send record, the echo hold
(`prompt_index_since`, queued or not) and `_prompt_arrived` compare through it, and
`human_prompt_text` returns the unwrapped text, so a turn's prompts, `prompt_restored`'s
`same_text` and the terminal note's quote never carry the tags. A wrapper mid-prompt (typed
words, then a paste) or with mismatched ids is left alone. Measured over the host's transcripts
(claude-code-measurements T13): wrapping starts at 2.1.277 with no visible length threshold.
Six mutants each fail on a test's own assertion.

## 2026-10-08: session_send names the conversation a reply goes to

<!-- prawduct: scope=local-command-opens-no-turn | release=v1.9.0 -->

**Why:** live, 2026-10-08: a session was first sent a stray task from metallm conversation A,
which opened its webhook. A project's brief was later sent from conversation B, and
`session_send` told B "Claude's reply will be delivered to this conversation". Every reply,
including the session's final `READY: <branch>`, went to A. One webhook per session is the
design; the false sentence was the defect.

**What:** when `conversation_id` differs from `_watched_conversation(name)`, the `delivery`
text says the reply goes to that conversation and that `session_unwatch` then `session_watch`
move it; the result carries `watched_conversation_id` whenever a webhook is open. The
one-webhook design is unchanged. Three tests (sent, queued, same conversation); two mutants
(the check forced off, the key dropped) each fail on a test's own assertion.

## 2026-10-08: a local command opens no turn

<!-- prawduct: scope=local-command-opens-no-turn | release=v1.9.0 -->

**Why:** live, 2026-10-08: a session was sent `/clear`, then a prompt that queued behind it. 14
minutes later the prompt still waited as `claude_busy` (`status_row_unproven`) while Claude sat
at an empty input box. `_session_state` read the turn as running because
`log_shows_turn_in_progress` took the `/clear` command line for a prompt with no reply, and
`unanswered_prompt_turn` returned `('/clear',)`. Claude never replies to a local command, so the
turn read as running until the transcript went quiet for `_LOG_STALL_S`.

**What:** `transcript.is_local_command` tells a local command from a skill's command by its
neighbours: the isMeta `<local-command-caveat>` line before it, or the `system` /
`local_command` line after it (measured across Claude Code 2.1.222 to 2.1.287 in the host's
transcripts: every local command had the caveat; no skill command had either mark).
`_ends_without_reply` (a local command or its output) is the one rule the three readers use: no
turn in progress, no unanswered prompt, no prompt on the next turn. `prompt_index_since` is
unchanged, so a pasted `/clear` still clears the echo hold; `_prompt_arrived` now gives a local
command's send record back, as it does for a queued prompt, since no turn will claim it.
Tests use the live transcript's lines; nine mutants each fail on a test's own assertion.

## 2026-09-29: v1.8.3 — a labelled box rule still bounds Claude's input box

<!-- prawduct: scope=screen-labelled-rule | release=v1.8.3 -->

**Why:** live on metallm, 2026-09-29: an orchestrator's `session_send` waited in the queue as
`screen_unrecognized` while the session sat idle. Claude Code 2.1.284 draws a named session's name
into the input box's top rule (`──── metallm ─`); `screen.classify` accepted only rules made of
nothing but `─`, found one rule, and read the screen as "no box". Typed prompts were unaffected
(they skip the check), so it looked like a black hole only for orchestrator sends.

**What:** `_is_rule` accepts a run of `─` carrying one label set off by spaces, with at least the
old minimum of rule characters. Fixture: that screen, captured live, conversation text replaced.
Tests: the fixture reads EMPTY; labels at the start, middle and end bound the box; lines with too
little rule, two labels, or an unspaced label do not. Hot-patched into the running aidc-mcp to
release the stuck prompt before the release (it pasted at 04:55:55).

Also: `metallm.send_speaker` turned off in the operator's config (not a code change) so replies to
prompts typed at the terminal wake the orchestrator again.

## 2026-09-29: v1.8.2 — blocking MCP tools run off the event loop

<!-- prawduct: scope=mcp-blocking-tools | release=v1.8.2 -->

**Why:** FastMCP calls a synchronous tool or resource inline on the server's one event loop
(mcp/server/fastmcp/utilities/func_metadata.py; FunctionResource.read), which also runs every
transcript watcher, reply callback and other client's call. Seven tools and all five resources
were synchronous and wait on subprocesses (the aidc CLI, `docker exec`), so each call froze the
server for its duration: 60s+ while `aidc list` was slow (fixed in v1.8.1), and up to
`session_exec`'s timeout in general.

**What:**
- `aidc_mcp/offload.py`: `off_loop` wraps a synchronous body as a coroutine function that runs it
  via `asyncio.to_thread`, keeping the signature FastMCP reads. Applied to session_list,
  session_exec, file_get, file_put, audit_get, taint_mark and every resource.
- `session_status` is async instead: its CLI call runs in a thread and the send-queue snapshot is
  read back on the loop, the only thread that mutates `_pending_sends`. (An AST sweep found no
  other synchronous tool touching loop-owned module state; `log_event` holds a lock.)
- `tests/test_offload.py`: through FastMCP's own `call_tool`/`read_resource`, a blocking call that
  only the loop can release must finish quickly; a registry-derived check fails any synchronous
  tool or resource added later; and every off_loop body, followed through the tools helpers it
  calls, touches none of tools' module-level dicts, lists or sets (the state the loop owns).
  Shown failing with session_list back on the loop, with session_status calling the CLI inline,
  and with session_exec reading `_pending_sends`. Tests that called these functions synchronously now
  await them, as FastMCP does; no assertion changed.
- Carried from v1.8.1's review: `start_dockerd` waits for a timed-out dockerd to exit before the
  vfs fallback; smoke runs the image's start script in throwaway containers for a failed test
  mount, a start that times out (a stand-in dockerd that ignores SIGTERM; fails on the v1.8.1
  image, which started the vfs daemon while it was alive), the recorded marker, a restart,
  pre-marker vfs storage and the override; entrypoint.sh no longer
  claims overlay2.
- Carried from v1.8.0: `mcp_load_settings` uses `_aidc_has_yq` and reads `.mcp.<key>` without
  `// ""`, which drops false.

## 2026-09-29: v1.8.1 — aidc list answers in under a second; inner Docker stores diffs, not copies

<!-- prawduct: scope=list-speed | release=v1.8.1 -->

**Why:** `aidc list` took over two minutes with two sessions, and the MCP's `session_list` failed
at its 60s timeout (the `aidc://sessions` resource returned empty at 30s). The listing asked
`docker ps` for `{{json .}}`, whose Size column makes the daemon sum each dev container's writable
layer; these ones hold 69 GB and 82 GB.

**What:** `cmd-list.sh` asks `docker ps` for the name and status columns only, and reads them
without jq. Measured on this host: 2m14s before, 0.3s after, same output. `tests/unit/test-list.sh`
fails if any `docker ps` query in the listing names Size, `--size` or the whole JSON record.
Also: the v1.8.0 plan archived and its entry marked released.

**Inner Docker storage.** The sessions were that large because the inner dockerd used `vfs`,
which stores every layer as a full copy (faidh: 85 GB under /var/lib/docker/vfs while its own
`docker system df` counted about 20 GB). `dockerd-start.sh` now picks `fuse-overlayfs` after one
real test mount on the filesystem dockerd will use (dockerd itself accepts the driver whenever
the binary exists and fails only at the first layer), falls back to `vfs`, and records the driver
that started so the watchdog's restarts keep it; storage from before the marker is `vfs`.
Readiness is now "the daemon answers" rather than "the socket exists". Measured on this ZFS host
with the same image and four containers: vfs 6.5 GB of files, fuse-overlayfs 0.6 GB. Kernel
overlay2 was not an option: it cannot stack on the outer container's overlayfs or on ZFS 2.1.
DKR-03 is unchanged: the storage stays inside the container. Smoke asserts the driver.

**Not in this release:** CLI-calling MCP tools still run on the server's event loop, so any
slow CLI call stalls transcript watchers and callbacks while it runs. That follows next.

## 2026-09-21: v1.8.0 — TCP egress relays, repo-config trust, supply-chain cooldown, blocklist without reloads

<!-- prawduct: scope=egress-tcp | release=v1.8.0 -->

**Why:** a proxied session could not reach a database the host reaches over ZeroTier, a VPN or
the LAN without removing isolation; a repo's own `.aidc/config.yaml` (writable from inside the
session) could widen its own sandbox; ten dependency advisories were open with no rule against
adopting a version published yesterday; squid refused every connection for ~20 s on each
blocklist reload (#34) and let subdomains of listed domains through; and settings.json, mounted
read-write, let a session plant hooks the host's Claude Code runs.

**What (Chunks A–F, all reviewed):**
- A, SEC-09: one table classifies every config key; from a workspace or repo config only safe or
  tightening values apply, the rest are shown and need `--trust-repo-config`.
- B, NET-15: declared relays (`egress_tcp:`, `--egress-tcp`), one per host, forwarding only to the
  address resolved on the host and logging each connection.
- C: `aidc egress <s> add|rm|ls|clear`, relays in `aidc status`, cleanup by kill, docs.
- D, REL-09: mcp/uv.lock past ten advisories under a 14-day cooldown; the dev image sets the same
  rule as a system default for uv, pip and npm (inside sessions too); Ubuntu's pip 25.1, which
  ignores it silently, is upgraded and every interpreter is checked at build. Claude Code exempt.
- E, NET-16: squid asks aidc-blocklist-helper instead of loading the list; no reload, no outage
  (fixes #34); subdomains of listed domains denied; the refresher publishes only a byte-sorted
  list.
- F: the host's status-line script bridged read-only (only that file); settings.json copied in at
  create instead of mounted (CTR-13 amended). #35 filed for the memory-dir symlink case.
- Found by CI on the PR (480dba0): the yq-based config reader dropped every `false` value
  (`.key // ""`; yq treats false as missing) on any machine with yq, so `tld_taints: false`,
  `claude_resume: false` and `share_*: false` were silently ignored there. Fixed; the config unit
  tests now run every case under both parsers (AIDC_NO_YQ=1 hides yq).
- Records: risk_surfaces declared; six strategy-doc pointers; docs/security-model.md rename;
  union-merge for this log; api_versioning_decided (semver, breaking only in a major); learnings
  migrated to .claude/rules/learnings; VERSION bumped to v1.8.0.

Reviews: rev-20260921T204623Z-fa131876, rev-20260921T211012Z-58345080,
rev-20260922T015403Z-28cf6fcf and their verify passes (last: rev-20260922T033833Z-b89bd5db).
Smoke 94/94 on rebuilt images; pytest 537; shell units 435 (both config parsers).
