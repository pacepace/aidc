#!/usr/bin/env bash
# Runs as `vscode`. Starts the tmux session, then blocks PID forever.
# Invoked by entrypoint.sh after it drops privileges.
set -uo pipefail

log() { printf '[aidc-user-main] %s\n' "$*" >&2; }

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
