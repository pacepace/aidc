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


## 2026-09-29: v1.8.3 — a labelled box rule still bounds Claude's input box

<!-- prawduct: scope=screen-labelled-rule -->

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
