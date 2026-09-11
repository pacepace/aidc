#!/usr/bin/env bash
# Runs as `vscode`. Starts the tmux session, then blocks PID forever.
# Invoked by entrypoint.sh after it drops privileges.
set -uo pipefail

log() { printf '[aidc-user-main] %s\n' "$*" >&2; }

# Onboarding seed (see cmd-create.sh "Onboarding seed"). Installed on the FIRST
# start only: once Claude has written its own ~/.claude.json on the volume --
# the account you logged in with, settings you changed -- the seed must never
# overwrite it, or a restart/upgrade would undo the login.
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_STATE_SEED=/var/aidc/audit/claude-state-seed.json
# A session created before v1.5.0 bind-mounted the host's login files here;
# Docker materialises a bind-mount target as an empty file, and that empty
# file outlives the mount in the volume once `aidc upgrade` strips it. An empty
# credentials file is not a login and an empty .claude.json is not state, so
# clear them before Claude reads either.
for _placeholder in "${CLAUDE_CONFIG_DIR}/.credentials.json" "${HOME}/.claude.json"; do
    if [ -f "$_placeholder" ] && [ ! -s "$_placeholder" ]; then
        rm -f "$_placeholder" && log "removed empty pre-v1.5.0 mount placeholder ${_placeholder}"
    fi
done
if [ ! -e "${CLAUDE_CONFIG_DIR}/.claude.json" ] && [ -s "$CLAUDE_STATE_SEED" ]; then
    if mkdir -p "$CLAUDE_CONFIG_DIR" \
        && ( umask 0077; cp "$CLAUDE_STATE_SEED" "${CLAUDE_CONFIG_DIR}/.claude.json" ); then
        log "claude state: seeded ${CLAUDE_CONFIG_DIR}/.claude.json from the host (first start)"
    else
        log "WARN: could not install the claude state seed; first launch will run onboarding"
    fi
fi

# Set up tmux session (idempotent).
log "starting tmux session 'main'"
/usr/local/bin/aidc-tmux-start.sh || log "WARN: tmux-start exited non-zero"

# Transcript mirror (design-09, MCP-15). See transcript-mirror.sh for the
# copy-forward function and why it copies via temp-file + atomic rename
# instead of writing the destination in place. The mount only exists when
# `aidc create` surfaced it, so guard on the dir.
# shellcheck source=transcript-mirror.sh
. /usr/local/bin/aidc-transcript-mirror.sh
TRANSCRIPT_OUT=/var/aidc/transcript-out
if [ -d "$TRANSCRIPT_OUT" ]; then
    _enc=$(printf '%s' "${AIDC_REPO_PATH:-$HOME}" | tr '/.' '-')
    _src="${HOME}/.claude/projects/${_enc}"
    log "transcript mirror: ${_src}/*.jsonl -> ${TRANSCRIPT_OUT}"
    (
        while true; do
            aidc_mirror_copy_forward_pass "$_src" "$TRANSCRIPT_OUT"
            sleep 2
        done
    ) &
fi

# Block forever, but in a way that's awake to signals (tini -g forwards them).
# We use a sleep-loop instead of tail -f /dev/null because tail leaves a
# defunct child if PID 1 ever changes parents under us.
log "ready (tmux running, sleeping forever)"
while true; do
    sleep 86400 &
    wait $!
done
