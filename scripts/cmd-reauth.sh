#!/usr/bin/env bash
# desc: Recover a session's claude from auth failure: push fresh creds + relaunch claude in tmux.
#
# Usage: aidc reauth <session>
#
# When the Anthropic OAuth refresh-token race (issue #24317) fires and the
# in-container claude says "Please run /login", this subcommand:
#   1. Extracts the host's CURRENT Keychain entry (macOS) or reads
#      ~/.claude/.credentials.json (Linux/WSL2)
#   2. In-place writes it to the session's bridged credentials file
#      (preserves inode, so the bind-mount remains valid)
#   3. Kills the claude process running in the session's tmux `claude`
#      window
#   4. Sends keys to re-run `aidc-claude` (which by default does
#      --continue, resuming the conversation thread)
#
# Result: ~3-second recovery. The in-flight tool call (the one that
# failed) is lost; the conversation history is preserved via --continue.
#
# Does NOT require the auth-bridge daemon to be running -- this command
# does its own extraction. If the daemon IS running, this is just a
# manual trigger of what the daemon would do automatically at the next
# poll, plus the tmux relaunch (which the daemon can't do).

set -euo pipefail

trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

NAME="${1:-}"
case "$NAME" in
    ''|-h|--help)
        cat <<'EOF'
aidc reauth <session>

Push fresh credentials into the session and relaunch claude in tmux.
Recovers from the Anthropic OAuth refresh-token race (issue #24317)
without losing the conversation thread (claude --continue picks it up).

Steps:
  1. Read current credentials from host (macOS Keychain or Linux file)
  2. In-place write to the session's bridged credentials file
  3. Kill the claude process inside the session's tmux 'claude' window
  4. Send keys to relaunch aidc-claude (which resumes via --continue)

Does NOT require aidc auth-bridge to be running.
EOF
        exit 0 ;;
esac

validate_session_name "$NAME"
require_docker
session_exists "$NAME" || die "no such session: $NAME"

DEV_CT="$(container_name "$NAME" dev)"

# ---- 1. Extract current host credentials ------------------------------------

case "$(uname -s)" in
    Darwin)
        info "extracting host Keychain entry"
        CREDS=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)
        if [ -z "$CREDS" ]; then
            die "could not read 'Claude Code-credentials' from macOS Keychain (run 'claude /login' on host first)"
        fi
        ;;
    Linux)
        HOST_CREDS_FILE="${HOME}/.claude/.credentials.json"
        if [ ! -f "$HOST_CREDS_FILE" ]; then
            die "host credentials file not found at ${HOST_CREDS_FILE} (run 'claude /login' on host first)"
        fi
        info "reading host credentials file"
        CREDS=$(cat "$HOST_CREDS_FILE")
        ;;
    *)
        die "unsupported platform: $(uname -s)"
        ;;
esac

# Sanity-check the JSON shape so we don't write garbage.
require_cmd python3
if ! printf '%s' "$CREDS" | python3 -c "
import json, sys, time
d = json.load(sys.stdin).get('claudeAiOauth', {})
if 'accessToken' not in d or 'refreshToken' not in d:
    print('ERROR: credentials JSON missing accessToken or refreshToken', file=sys.stderr)
    sys.exit(1)
exp = d.get('expiresAt', 0)
if exp:
    h = (exp/1000 - time.time()) / 3600 if exp > 1e12 else (exp - time.time()) / 3600
    print(f'host credentials look valid; expiresAt in {h:+.2f}h', file=sys.stderr)
" >&2; then
    die "host credentials JSON failed sanity check"
fi

# ---- 2. Locate + in-place write the session's bridged file ------------------

BRIDGED_MOUNT_DEST="/home/vscode/.claude/.credentials.json"
BRIDGED_HOST_PATH=$(docker inspect "$DEV_CT" \
    --format '{{range .Mounts}}{{if eq .Destination "'"$BRIDGED_MOUNT_DEST"'"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null || true)

if [ -z "$BRIDGED_HOST_PATH" ]; then
    die "session ${NAME} has no bridged credentials mount; auth bridging may have been disabled at create time (try aidc kill + aidc create)"
fi

# docker inspect's Source path on macOS includes a /host_mnt prefix that
# isn't writable from host shells; strip it to get the real path.
case "$BRIDGED_HOST_PATH" in
    /host_mnt/*) BRIDGED_HOST_PATH="${BRIDGED_HOST_PATH#/host_mnt}" ;;
esac

if [ ! -f "$BRIDGED_HOST_PATH" ]; then
    die "bridged credentials file not found at ${BRIDGED_HOST_PATH}"
fi

# In-place write (preserves inode -- see auth-bridge-watcher.sh for the long
# explanation of why mv-rename would break the bind-mount).
info "writing fresh credentials to ${BRIDGED_HOST_PATH}"
printf '%s' "$CREDS" > "$BRIDGED_HOST_PATH"
chmod 0600 "$BRIDGED_HOST_PATH" 2>/dev/null || true

# Verify the container sees it (catches the inode-already-broken case).
CONT_HASH=$(docker exec -u vscode "$DEV_CT" sha256sum /home/vscode/.claude/.credentials.json 2>/dev/null | awk '{print $1}')
HOST_HASH=$(shasum -a 256 "$BRIDGED_HOST_PATH" | awk '{print $1}')
if [ -z "$CONT_HASH" ]; then
    die "container cannot read /home/vscode/.claude/.credentials.json -- the bind-mount inode was likely broken by a prior mv-rename. Recover with: aidc restart ${NAME}"
fi
if [ "$CONT_HASH" != "$HOST_HASH" ]; then
    die "container sees different credentials than host (hash mismatch); the bind-mount may be stale. Recover with: aidc restart ${NAME}"
fi
info "container confirms fresh credentials are visible"

# ---- 3+4. Kill claude inside tmux and relaunch ------------------------------

TMUX_SESSION="main"
TMUX_WINDOW="claude"

# Confirm tmux session + window exist.
if ! docker exec -u vscode "$DEV_CT" tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    die "tmux session '${TMUX_SESSION}' not found inside ${DEV_CT}"
fi
if ! docker exec -u vscode "$DEV_CT" tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$TMUX_WINDOW"; then
    die "tmux window '${TMUX_WINDOW}' not found inside ${DEV_CT}"
fi

# Send C-c to interrupt claude. Multiple times in case it's in a tool call
# confirmation. Then send 'q' (in case claude is in a paginated view), then
# send '/quit' as a graceful exit if claude is still receiving input. Then
# C-c again as a last resort. This is intentionally aggressive -- we want
# claude DEAD before relaunching, not partially-alive racing with the new
# instance.
info "killing claude in tmux window ${TMUX_SESSION}:${TMUX_WINDOW}"
docker exec -u vscode "$DEV_CT" tmux send-keys -t "${TMUX_SESSION}:${TMUX_WINDOW}" C-c 2>/dev/null || true
sleep 0.3
docker exec -u vscode "$DEV_CT" tmux send-keys -t "${TMUX_SESSION}:${TMUX_WINDOW}" C-c 2>/dev/null || true
sleep 0.3
# Force-clear the line in case prompts are stacked.
docker exec -u vscode "$DEV_CT" tmux send-keys -t "${TMUX_SESSION}:${TMUX_WINDOW}" C-u 2>/dev/null || true
sleep 0.2

# Find any claude processes inside the container and kill them. Belt + suspenders.
CLAUDE_PIDS=$(docker exec "$DEV_CT" pgrep -f '^node.*claude' 2>/dev/null || true)
if [ -n "$CLAUDE_PIDS" ]; then
    info "force-killing remaining claude processes: ${CLAUDE_PIDS}"
    docker exec "$DEV_CT" bash -c "echo '$CLAUDE_PIDS' | xargs -r kill -TERM" 2>/dev/null || true
    sleep 0.5
    # Anything that didn't die to TERM gets KILL.
    STILL_ALIVE=$(docker exec "$DEV_CT" pgrep -f '^node.*claude' 2>/dev/null || true)
    if [ -n "$STILL_ALIVE" ]; then
        docker exec "$DEV_CT" bash -c "echo '$STILL_ALIVE' | xargs -r kill -KILL" 2>/dev/null || true
    fi
fi

# Relaunch via aidc-claude in the same tmux window. aidc-claude wraps the
# session's configured flags (yolo-mode, --continue, etc.) so this is the
# same launch the user got at session create time.
info "relaunching aidc-claude in ${TMUX_SESSION}:${TMUX_WINDOW}"
docker exec -u vscode "$DEV_CT" tmux send-keys -t "${TMUX_SESSION}:${TMUX_WINDOW}" "aidc-claude" C-m 2>/dev/null || \
    die "tmux send-keys failed"

# Brief wait so the user sees claude come up before the prompt returns.
sleep 1
info "done. attach with: aidc attach ${NAME}"
info "  the conversation thread resumes via --continue; the in-flight tool call (if any) is lost."

# Nudge the user toward the better fix if they haven't already adopted it.
# Long-lived OAuth tokens (claude setup-token) bypass the refresh race
# entirely. reauth is a recovery; the token is the prevention.
AIDC_TOKEN_FILE="${HOME}/.config/aidc/claude-oauth-token"
if [ ! -f "$AIDC_TOKEN_FILE" ]; then
    printf '\n' >&2
    info "TIP: if you keep needing to run aidc reauth, the underlying problem is"
    info "     Anthropic's OAuth refresh-token race (issue #24317). aidc has a"
    info "     workaround: 'aidc claude-token setup' generates a 1-year token that"
    info "     bypasses the race entirely. Trade-offs explained in 'aidc claude-token setup'."
fi
