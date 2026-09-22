---
lifecycle: completed
archived: 2026-09-12
released_in: v1.6.0
unbuilt_at_archive: "no readable `## Status` roster — completeness cannot be read, and an unreadable plan is not evidence of completion"
maintained: false
---

> **Archived — no longer maintained.** This plan records what was built, not what will be. Do not edit it to reflect later changes; write those where they are true.

# Build plan: bridge Claude's scratchpad across the container boundary

**Size:** medium · **Type:** feature · **Branch:** `feature/scratchpad-bridge`
**Critic mode:** final

## Problem

Claude Code keeps per-session working files at
`/tmp/claude-<uid>/<encoded-cwd>/<session-id>/{scratchpad,tasks}`. In an aidc session
that path lives on the dev container's writable layer: it survives `aidc restart`
(a `docker restart`) and is destroyed by `aidc upgrade` (recreate) and `aidc kill`
(`cmd-kill.sh:64`, `docker compose down -v`).

Conversation history does not have this problem — `share_memory` bind-mounts
`~/.claude/projects/<encoded>` so a session's transcript follows the repo across the
boundary. The scratchpad has no equivalent, so a session that moves host → container
→ host loses its working files while its transcript survives.

## Success

Write to the scratchpad inside the container, pop out to the host, resume the same
session — the files are there. Pop back in — still there. Same bridge shape as
`share_memory`, same toggle semantics.

## Out of scope

- Relocating where Claude Code puts its scratchpad (no env var is relied on).
- The copy-forward/audit-mirror shape — explicitly rejected in favour of the live
  bind mount, on the user's instruction to follow the memory-bridge pattern.
- Retrofitting **already-created** sessions. `aidc upgrade` reuses the create-time
  compose file (`cmd-upgrade.sh:80,118`), so existing sessions need `aidc kill` +
  `aidc create`. Documented, not implemented.
- Durability across a host reboot. `/tmp` is reboot-cleared on the host, so a
  bridged scratchpad dies exactly when a host-only session's would. This is the
  correct semantics — container sessions now behave like host sessions — not a gap.

## Key facts (verified, not assumed)

- `<encoded-cwd>` is **byte-identical** on both sides: the workspace is bind-mounted
  at its own host path (`compose.yaml.template`: `${WORKSPACE_PATH}:${WORKSPACE_PATH}`)
  and Claude launches from `REPO_PATH` (`tmux-start.sh:20`, `-c "$REPO"`).
- Container `vscode` is pinned to **uid 1000** (`.devcontainer/Dockerfile:300-301`).
- Host scratchpad dirs are mode **0700**. Bridging therefore requires host uid ==
  container uid; a mismatch would leave `vscode` unable to write its own scratchpad,
  which is worse than not bridging.
- `/tmp/claude-<uid>/` also holds harness scratch *outside* the per-project dir
  (e.g. `bash-edit-diff`). Mounting only the `<enc>` subdir leaves that parent
  created by Docker as root-owned 0755 → the entrypoint must own it.
- `compose-render.sh` restricts `envsubst` to an allowlist; a new placeholder must be
  added to the defaults block **and** the allowlist or the render breaks.

## Decision record

**Live rw bind mount, not a one-way mirror.** The mirror shape (copy-forward into the
audit dir, as transcripts do) would avoid giving the sandboxed agent a predictable
writable host path adjacent to where host sessions keep scripts they execute. It was
rejected because it cannot satisfy the requirement: a mirror is one-way, so popping
*back in* would not see host-side work. The user was shown this trade-off and chose
the bind mount. Exposure is bounded to this repo's own scratchpad dir — the whole
`/tmp/claude-<uid>` root is deliberately **not** mounted, for the same reason the
README rejects sharing all of `~/.claude`.

**Default on.** Matches `share_memory`; the feature is worthless if it must be opted
into per session. Toggle: `share_scratchpad: false`.

## Chunks

### Status

- [x] 1 — Bridge mechanism (lib helper, config key, create wiring, compose, entrypoint)
- [x] 2 — Tests
- [x] 3 — Artifacts (README, requirements, CHANGELOG)

### Chunk 1 — Bridge mechanism

- `scripts/lib/common.sh` — `AIDC_CONTAINER_UID`, `aidc_scratchpad_host_dir`,
  `aidc_scratchpad_mount` (pure, testable; emits nothing + rc1 on uid mismatch).
- `scripts/lib/config.sh` — `AIDC_SHARE_SCRATCHPAD` default `true`, parse, snapshot,
  sample-config comment.
- `scripts/cmd-create.sh` — compute host dir, `mkdir -p` at 0700, export
  `CLAUDE_SCRATCHPAD_MOUNT`, `info` on each path (bridged / disabled / uid mismatch).
- `proxy/compose.yaml.template` — `${CLAUDE_SCRATCHPAD_MOUNT}` on the dev service.
- `proxy/compose-render.sh` — default + **envsubst allowlist** entry.
- `.devcontainer/entrypoint.sh` — ensure `/tmp/claude-1000` is `vscode:vscode` 0700
  before the privilege drop.

**Done when:** `make lint` clean; a standalone render emits the mount line.

### Chunk 2 — Tests

`tests/unit/test-scratchpad-bridge.sh`, sourcing the shipped helpers (no
re-implementation), covering: mount line shape; uid-mismatch suppression; encoded-path
agreement with the memory bridge; the placeholder surviving a real `compose-render.sh`
run and collapsing to nothing when unset.

**Done when:** new test passes; all 8 pre-existing unit tests still pass.

### Chunk 3 — Artifacts

README "What's bridged from your host"; a requirement in `docs/requirements.md`;
CHANGELOG entry noting existing sessions need kill + create.

**Done when:** artifacts describe shipped behaviour, including the two descoped
limits above.
