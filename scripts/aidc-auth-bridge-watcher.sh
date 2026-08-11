#!/usr/bin/env bash
# Internal: the actual auth-bridge daemon loop. Not a user-facing subcommand;
# the dispatcher's auto-discovery skips this file (no "cmd-" prefix).
#
# Polls macOS Keychain for the "Claude Code-credentials" entry every
# AIDC_AUTH_BRIDGE_POLL_SECONDS (default 30) and, when the value changes,
# atomically writes it to every ~/aidc-audit/*/.claude-credentials.json
# (the per-session bridged files). The container's bind-mount sees the
# new bytes on next read; in-container Claude picks up the fresh tokens
# without any container restart.
#
# Lifecycle is managed by scripts/cmd-auth-bridge.sh.

set -uo pipefail

trap '' PIPE

CONFIG_DIR="${HOME}/.config/aidc"
PID_FILE="${CONFIG_DIR}/auth-bridge.pid"
LOG_FILE="${CONFIG_DIR}/auth-bridge.log"
LOG_BACKUP="${CONFIG_DIR}/auth-bridge.log.1"
HASH_FILE="${CONFIG_DIR}/auth-bridge.last-hash"

AUDIT_ROOT="${HOME}/aidc-audit"
SERVICE="Claude Code-credentials"
LOG_MAX_BYTES=$((1024 * 1024))   # 1MB

POLL_SECONDS="${AIDC_AUTH_BRIDGE_POLL_SECONDS:-30}"
# Floor at 5s -- tighter polling is wasteful and not part of the contract.
case "$POLL_SECONDS" in
    ''|*[!0-9]*) POLL_SECONDS=30 ;;
    *) [ "$POLL_SECONDS" -lt 5 ] && POLL_SECONDS=5 ;;
esac

mkdir -p "$CONFIG_DIR"

log() {
    local msg="$*"
    local ts
    ts=$(date -u +%FT%TZ)
    # Rotate if oversized.
    if [ -f "$LOG_FILE" ]; then
        local sz
        # macOS stat: -f %z; Linux stat: -c %s. We're macOS-only but be defensive.
        sz=$(stat -f %z "$LOG_FILE" 2>/dev/null || stat -c %s "$LOG_FILE" 2>/dev/null || printf 0)
        if [ "$sz" -ge "$LOG_MAX_BYTES" ]; then
            mv -f "$LOG_FILE" "$LOG_BACKUP" 2>/dev/null || true
        fi
    fi
    printf '[%s] [aidc-auth-bridge] %s\n' "$ts" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

cleanup() {
    log "shutting down (signal received)"
    rm -f "$PID_FILE"
    exit 0
}
trap cleanup TERM INT

# Write our PID. The caller already verified there's no live daemon.
printf '%s' "$$" > "$PID_FILE"
log "started (pid=$$, poll=${POLL_SECONDS}s)"

# Initialize last_hash from disk if present so a daemon restart doesn't
# re-push the same value to every session for no reason.
last_hash=""
if [ -f "$HASH_FILE" ]; then
    last_hash=$(cat "$HASH_FILE" 2>/dev/null || true)
fi

# In-place write helper. Writes content (read from stdin) to $1 with mode 0600.
#
# Why in-place truncate instead of mv-rename atomic write:
#
# Docker on macOS bind-mounts a SPECIFIC FILE by inode at mount time. A
# mv-rename pattern (write to .new, then mv -f to target) replaces the
# inode. The container is still pointing at the OLD inode -- which now
# has zero links and is invisible to the container as a phantom-file
# (`-?????????  ? ?` in ls -la output). The NEW inode at the same path
# is invisible to the container, AND there's no way to re-establish the
# bind-mount without recreating the container.
#
# In-place truncate keeps the same inode, so the bind-mount stays valid.
# Risk of partial-read: claude reading mid-write could see truncated
# content. Mitigated by:
#   - Credentials file is ~471 bytes, well under PIPE_BUF (4096+);
#     single write(2) is atomic on macOS for small writes.
#   - Use shell redirect-with-truncate (`>`) which the kernel implements
#     as open(O_WRONLY|O_TRUNC) + write + close -- not as two operations
#     visible to other readers.
#   - If a reader does see EAGAIN/truncated content, it'll retry on its
#     next API call cycle (claude has built-in retry); the next read will
#     be correct.
inplace_write_0600() {
    local target="$1"
    # Ensure target exists with correct perms before write; create-if-missing
    # so subshell's `>` redirect doesn't need to handle the create case.
    if [ ! -f "$target" ]; then
        umask 0177
        : > "$target" || return 1
        chmod 0600 "$target" 2>/dev/null || true
    fi
    cat > "$target" || return 1
    # Re-assert mode in case umask in the calling environment is non-restrictive.
    chmod 0600 "$target" 2>/dev/null || true
}

# Main loop.
while true; do
    # Extract Keychain. Errors are normal (Keychain locked, user logged out
    # temporarily, etc.) -- log + retry next cycle.
    creds=$(security find-generic-password -s "$SERVICE" -w 2>/dev/null || true)
    if [ -z "$creds" ]; then
        # No log spam: only complain once per "Keychain unavailable" streak.
        if [ "${_in_unavailable_streak:-0}" != "1" ]; then
            log "keychain entry '${SERVICE}' currently unavailable (locked, missing, or extraction failed); will keep polling"
            _in_unavailable_streak=1
        fi
        sleep "$POLL_SECONDS"
        continue
    fi
    if [ "${_in_unavailable_streak:-0}" = "1" ]; then
        log "keychain entry '${SERVICE}' is available again"
        _in_unavailable_streak=0
    fi

    # Hash to detect change without re-writing files when unchanged.
    new_hash=$(printf '%s' "$creds" | shasum -a 256 | awk '{print $1}')

    if [ "$new_hash" = "$last_hash" ]; then
        sleep "$POLL_SECONDS"
        continue
    fi

    # Changed (or first iteration with no prior hash). Find audit-dir files
    # to update.
    pushed=0
    if [ -d "$AUDIT_ROOT" ]; then
        for f in "${AUDIT_ROOT}"/*/.claude-credentials.json; do
            [ -e "$f" ] || continue   # nullglob-equivalent via -e check
            if printf '%s' "$creds" | inplace_write_0600 "$f"; then
                pushed=$((pushed + 1))
            else
                log "failed to update ${f}"
            fi
        done
    fi

    # Record the new hash regardless of how many files we touched.
    # If audit dir is empty (no sessions), we still remember the hash so
    # a later session that gets created picks up its initial extraction
    # via aidc create's normal path (the daemon doesn't backfill new
    # session creates -- create writes its own initial snapshot).
    printf '%s' "$new_hash" > "${HASH_FILE}.new" && mv -f "${HASH_FILE}.new" "$HASH_FILE"
    last_hash="$new_hash"

    if [ "$pushed" -gt 0 ]; then
        log "keychain change detected; pushed to ${pushed} session(s)"
    else
        log "keychain change detected; no active sessions to push to"
    fi

    sleep "$POLL_SECONDS"
done
