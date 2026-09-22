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


## 2026-09-21: v1.8.0 — TCP egress relays, repo-config trust, supply-chain cooldown, blocklist without reloads

<!-- prawduct: scope=egress-tcp -->

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
- Records: risk_surfaces declared; six strategy-doc pointers; docs/security-model.md rename;
  union-merge for this log; api_versioning_decided (semver, breaking only in a major); learnings
  migrated to .claude/rules/learnings; VERSION bumped to v1.8.0.

Reviews: rev-20260921T204623Z-fa131876, rev-20260921T211012Z-58345080,
rev-20260922T015403Z-28cf6fcf and their verify passes (last: rev-20260922T032134Z-66b98d8b).
Smoke 94/94 on rebuilt images; pytest 537; shell units 398.
