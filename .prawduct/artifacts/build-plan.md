---
artifact: build-plan
version: 1
scope: session-compose-in-state
branch: fix/session-compose-in-state
lifecycle: active
---

# Build Plan — a session's compose file outlives /tmp

**Work:** `session-compose-in-state` · **Branch:** `fix/session-compose-in-state` (off
`develop` 80f668c, the v1.9.8 content) · **Started:** 2026-10-24 · **Release:** v1.9.9
**Critic mode:** single review after the one chunk

## Why

2026-10-24: `aidc upgrade` could not run for either live session on this host. handmcp
(v1.9.5) and metallm (v1.9.0) both lacked `/tmp/aidc-<name>.yaml`, most likely taken when
/tmp was cleared to free disk on 2026-10-22. That file is the only record of how a session was
created, and upgrade, network and kill read it back, so each session could only be killed and
recreated. Pace (2026-10-24): "move session setup files out of /tmp".

## Confidence check

- **Problem:** a session's rendered compose file lives in /tmp, which a reboot or a cleanup
  empties, and then `aidc upgrade` refuses for the rest of the session's life.
- **Success:** `aidc create` writes `~/.local/state/aidc/sessions/<name>.yaml` (0600, dir
  0700), on the host and from inside aidc-mcp alike. upgrade, network and kill read it there.
  An older session's surviving /tmp copy is moved in on first read. kill removes it.
- **Out of scope:** rebuilding a lost compose file from the running containers. A session
  whose copy is already gone is recreated; upgrade's error says so.

## Design decisions

- [DECISION: the path is built from the host home only, not XDG_STATE_HOME] because
  `aidc create` also runs inside aidc-mcp, whose env carries AIDC_HOST_HOME but not the host's
  XDG settings, and both must name one file.
- [DECISION: written through aidc_mkdir_host + aidc_fix_host_owner] for the
  boundary rule in learnings/core.md: inside aidc-mcp the CLI is root and the file must land
  operator-owned at the host path. Checked live (an aidc-mcp-image container, root, home
  mounted at its own path: the host saw pace:pace 600 in a 700 dir).
- [DECISION: a legacy /tmp copy is moved, not just read] so the next cleanup cannot take it.
  If the move fails, it is used in place with a warning.

## Chunks

### Chunk 01: State path

- [x] Helpers in `scripts/lib/common.sh` (`aidc_session_compose_path`, `_find`, `_file`,
  `aidc_remove_session_compose`). `cmd-create.sh` renders there through aidc_mkdir_host and
  clears a stale /tmp copy. `cmd-upgrade.sh` and `cmd-network.sh` read it, moving a /tmp copy
  in. `cmd-kill.sh` removes every copy, including for a session with no containers left.
- [x] `tests/unit/test-session-compose-path.sh`. Smoke asserts the place, the mode, the stale
  /tmp clear, the upgrade read-back and the removal. README, design-11, CHANGELOG.

### Chunk 02: Release

- [ ] `chore(release): aidc v1.9.9`, gates, Critic, PR review.

## Status

Context: chunk A built and unit-tested, live write probe done; smoke and Critic next.
