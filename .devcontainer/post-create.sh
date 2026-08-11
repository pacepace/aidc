#!/usr/bin/env bash
# aidc post-create: runs once when the dev container is first created.
#
# Responsibilities:
#   1. Activate the system-level pre-push hook (GIT-05).
#   2. Override /etc/resolv.conf to point at Quad9 (belt-and-suspenders;
#      the compose template also sets DNS via `dns:` array).
#   3. Report the baked-in Claude Code version (it is installed by the
#      image, NOT here -- see the section-3 comment below).
#   4. Start the long-lived tmux session.
#
# This script is idempotent. Re-running it should be safe.

set -euo pipefail

log() { printf 'aidc post-create: %s\n' "$*"; }

# ----- 1. System-level git hooks path ----------------------------------------
# `git config --system` writes to /etc/gitconfig and applies to all users
# in the container, not just `vscode`. This activates /etc/git-hooks/pre-push
# (installed by the Dockerfile), which hard-fails every push attempt.
if command -v git >/dev/null 2>&1; then
    sudo git config --system core.hooksPath /etc/git-hooks
    log "system core.hooksPath set to /etc/git-hooks"
else
    log "WARNING: git not found; skipping hooksPath config"
fi

# ----- 2. DNS override -------------------------------------------------------
# Docker normally manages /etc/resolv.conf. With --privileged we can rewrite
# it; the change persists until the next container restart, at which point
# the compose-level `dns:` setting takes over.
if [ -w /etc/resolv.conf ] || sudo test -w /etc/resolv.conf; then
    {
        echo "# Written by aidc post-create.sh"
        echo "nameserver 9.9.9.9"
        echo "nameserver 149.112.112.112"
    } | sudo tee /etc/resolv.conf >/dev/null
    log "/etc/resolv.conf -> Quad9"
else
    log "WARNING: /etc/resolv.conf not writable; skipping DNS override"
fi

# ----- 3. Claude Code -- intentionally NOT installed here ---------------------
# This step used to run `sudo npm install -g @anthropic-ai/claude-code`. It is
# gone on purpose. The image now bakes Claude Code via Anthropic's native
# installer, as the `vscode` user, into ~/.local/share/claude/ (see Dockerfile).
# The npm-global copy landed in root-owned /usr/lib/node_modules/, shadowed the
# native one on PATH, and broke in-session auto-update with EACCES. Since npm is
# always present in the image now, this step would fire on every create and
# reintroduce that exact breakage. Do not restore it.
if [ -x "${HOME}/.local/bin/claude" ]; then
    log "Claude Code present: $("${HOME}/.local/bin/claude" --version 2>/dev/null || echo unknown)"
else
    log "WARNING: ${HOME}/.local/bin/claude not found (expected from the image bake)"
fi

# ----- 4. tmux session -------------------------------------------------------
if command -v tmux >/dev/null 2>&1; then
    /usr/local/bin/aidc-tmux-start.sh
    log "tmux session 'main' ready"
else
    log "WARNING: tmux not found; skipping session start"
fi

log "done"
