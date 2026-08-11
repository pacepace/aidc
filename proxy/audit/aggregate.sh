#!/usr/bin/env bash
# aidc audit aggregator -- main loop.
#
# Mirrors forensic artefacts from the running session into the host-visible
# audit directory mounted at /var/aidc/audit/. The audit dir persists after
# `aidc kill` so post-incident review is possible.
#
# Usage:
#   aggregate.sh           # loop forever, sweeping every AIDC_AUDIT_INTERVAL seconds
#   aggregate.sh --once    # single sweep, then exit (used by finalize.sh)
#
# Source mounts (read-only at runtime, set up by compose):
#   /var/log/squid/          squid access.log
#   /var/log/aidc/           policy-events.log, refresher.log
#   /var/aidc/dev-home/      dev container's .bash_history, .zsh_history
#   /var/aidc/claude-transcript/  Claude transcript dir (optional)
#   /var/aidc/state/         tainted flag
#
# Output (read-write):
#   /var/aidc/audit/         this session's host-visible audit subdirectory
#
# Disk usage: v1 simply mirrors the logs. Rotation/pruning is deferred to a
# future `aidc audit-prune` command. Audit data is NEVER deleted automatically
# by this script -- cleanup is a user action.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

AUDIT_DIR=/var/aidc/audit
SQUID_DIR=/var/log/squid
AIDC_LOG_DIR=/var/log/aidc
DEV_HOME=/var/aidc/dev-home
CLAUDE_TRANSCRIPT=/var/aidc/claude-transcript
STATE_DIR=/var/aidc/state

: "${AIDC_SESSION:=unknown}"
: "${AIDC_PROFILE:=unknown}"
: "${AIDC_AUDIT_INTERVAL:=60}"

META="${AUDIT_DIR}/meta.json"

ONCE=0
if [ "${1:-}" = "--once" ]; then
    ONCE=1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

iso8601_now() {
    date -u +%FT%TZ
}

log() {
    printf '[aggregate] %s %s\n' "$(iso8601_now)" "$*" >&2
}

# Atomic copy: cp src dst.tmp && mv dst.tmp dst.
# Wrapped so a single failure (locked file, transient I/O) does not abort
# the sweep -- the audit container should keep running.
atomic_copy() {
    local src="$1"
    local dst="$2"
    if [ ! -e "$src" ]; then
        return 0
    fi
    if cp "$src" "${dst}.tmp" 2>/dev/null; then
        mv "${dst}.tmp" "$dst" 2>/dev/null || log "mv failed: $dst"
    else
        log "copy failed: $src -> $dst"
        rm -f "${dst}.tmp" 2>/dev/null || true
    fi
}

# Tree copy for claude-transcript/. Alpine doesn't ship rsync; use cp -a into
# a staging dir then atomically swap. If the source is empty/missing, skip.
atomic_copy_tree() {
    local src="$1"
    local dst="$2"
    if [ ! -d "$src" ]; then
        return 0
    fi
    # Skip silently if the directory is empty -- avoids creating a noisy empty
    # claude-transcript/ subdir when the user hasn't configured Claude.
    if [ -z "$(ls -A "$src" 2>/dev/null || true)" ]; then
        return 0
    fi
    local staging="${dst}.tmp"
    rm -rf "$staging" 2>/dev/null || true
    if cp -a "$src" "$staging" 2>/dev/null; then
        rm -rf "${dst}.old" 2>/dev/null || true
        if [ -d "$dst" ]; then
            mv "$dst" "${dst}.old" 2>/dev/null || true
        fi
        mv "$staging" "$dst" 2>/dev/null || log "tree mv failed: $dst"
        rm -rf "${dst}.old" 2>/dev/null || true
    else
        log "tree copy failed: $src -> $dst"
        rm -rf "$staging" 2>/dev/null || true
    fi
}

# Update meta.json atomically by piping it through jq with the given filter.
# Any number of "--arg k v" pairs may follow the filter.
meta_update() {
    local filter="$1"; shift
    if [ ! -f "$META" ]; then
        return 0
    fi
    local tmp
    # mktemp in $META's OWN directory so the mv below is a same-filesystem atomic
    # rename() -- not a cross-fs copy that a concurrent reader, or a SIGKILL that
    # cuts short the teardown final sweep, can catch half-written (leaving a
    # truncated, invalid-JSON meta.json). chmod 0644 because mktemp is 0600 and we
    # run as root, so a non-root host reader could otherwise not read the file.
    tmp=$(mktemp "${META}.XXXXXX") || return 0
    if jq "$@" "$filter" "$META" > "$tmp" 2>/dev/null; then
        chmod 0644 "$tmp"
        mv "$tmp" "$META"
    else
        log "meta jq update failed"
        rm -f "$tmp" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# meta.json ownership
#
# `aidc create` writes the canonical meta.json BEFORE this container starts,
# with schema {session, profile, repo, created_at, taint_response}. This
# aggregator only *updates* it (tainted_at, killed_at) via meta_update; it
# never creates it. (An earlier init_meta() here wrote a divergent schema and
# was always dead code -- create's file already exists -- so it was removed.
# Consequence: image_digests is not captured; a future enhancement could add
# it here from `docker inspect`.)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Single sweep
# ---------------------------------------------------------------------------

sweep() {
    atomic_copy "${SQUID_DIR}/access.log"        "${AUDIT_DIR}/squid-access.log"
    atomic_copy "${AIDC_LOG_DIR}/policy-events.log" "${AUDIT_DIR}/policy-events.log"
    atomic_copy "${AIDC_LOG_DIR}/refresher.log"  "${AUDIT_DIR}/refresher.log"
    atomic_copy "${DEV_HOME}/.bash_history"      "${AUDIT_DIR}/dev-bash-history"
    atomic_copy "${DEV_HOME}/.zsh_history"       "${AUDIT_DIR}/dev-zsh-history"
    atomic_copy_tree "${CLAUDE_TRANSCRIPT}"      "${AUDIT_DIR}/claude-transcript"

    # Taint propagation: if the policy sidecar dropped a tainted flag,
    # mirror it into the audit dir and stamp meta.json.
    if [ -f "${STATE_DIR}/tainted" ]; then
        atomic_copy "${STATE_DIR}/tainted" "${AUDIT_DIR}/tainted"
        local tainted_at
        tainted_at=$(cat "${STATE_DIR}/tainted" 2>/dev/null | tr -d '\n\r' || echo "")
        if [ -z "$tainted_at" ]; then
            tainted_at=$(iso8601_now)
        fi
        meta_update '.tainted_at = $ts' --arg ts "$tainted_at"
    fi
}

# ---------------------------------------------------------------------------
# Signal handling
#
# SIGTERM (sent by `docker compose down` or `aidc kill`) must NOT be swallowed.
# We trap it, run a final sweep, stamp killed_at into meta.json, then exit 0.
# A flag-based trap means we leave the sleep promptly even if it's mid-cycle.
# ---------------------------------------------------------------------------

TERMINATE=0
on_term() {
    TERMINATE=1
}
trap on_term TERM INT

finalize_and_exit() {
    log "received termination signal -- final sweep"
    sweep
    meta_update '.killed_at = $ts' --arg ts "$(iso8601_now)"
    log "exit 0"
    exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "session=${AIDC_SESSION} profile=${AIDC_PROFILE} interval=${AIDC_AUDIT_INTERVAL}s"

if [ "$ONCE" -eq 1 ]; then
    sweep
    exit 0
fi

while :; do
    sweep
    if [ "$TERMINATE" -eq 1 ]; then
        finalize_and_exit
    fi
    # Sleep in 1-second slices so SIGTERM is observed promptly without
    # depending on `wait` / background-process tricks. `read -t` would also
    # work but coreutils sleep is what's available everywhere.
    i=0
    while [ "$i" -lt "$AIDC_AUDIT_INTERVAL" ]; do
        if [ "$TERMINATE" -eq 1 ]; then
            finalize_and_exit
        fi
        sleep 1
        i=$((i + 1))
    done
done
