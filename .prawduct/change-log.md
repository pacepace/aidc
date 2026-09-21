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


## 2026-09-21: TCP egress relays and repo-config trust

<!-- prawduct: scope=egress-tcp -->

**Why:** a proxied session could not reach a database the host reaches over ZeroTier, a VPN or
the LAN without removing isolation, and a repo's own `.aidc/config.yaml` (writable from inside the
session) could widen its own sandbox.

**What:** Chunk A: SEC-09. One table classifies every config key; from a workspace or repo config,
only safe or tightening values apply, and the rest are shown and need `--trust-repo-config`.
Chunk B: NET-15 declared relays (`egress_tcp:`, `--egress-tcp`), one per host, forwarding only to
the address resolved on the host and logging each connection. Chunk C: `aidc egress <s>
add|rm|ls|clear`, relays in `aidc status`, cleanup by kill, and docs. Also: `aidc create` builds the
forwarder image that declared `--port` forwards needed. Reviews rev-20260921T204623Z-fa131876 and
rev-20260921T210529Z-fbc10ffb; smoke 81/81. Filed #34 (squid refuses connections for ~20 s on
each blocklist reload).
