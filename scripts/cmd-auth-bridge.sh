#!/usr/bin/env bash
# desc: Manage the host-side auth bridge that syncs macOS Keychain into running aidc sessions (macOS only; no-op on Linux/WSL2).
#
# Usage:
#   aidc auth-bridge start [--force]   # idempotent; --force clears the disabled sentinel
#   aidc auth-bridge stop              # also touches disabled sentinel so auto-start respects user intent
#   aidc auth-bridge status            # daemon state, last-push, disabled sentinel
#   aidc auth-bridge logs [-n N]       # tail the log
#   aidc auth-bridge restart           # stop + start (clears disabled sentinel)
#
# Auto-managed: aidc create and aidc mcp start ensure the daemon is running;
# aidc kill and aidc mcp stop stop the daemon when no aidc-managed containers
# remain on the host. An explicit `aidc auth-bridge stop` is respected -- the
# daemon stays stopped until something else triggers a start.

set -uo pipefail

trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"

CONFIG_DIR="${HOME}/.config/aidc"
PID_FILE="${CONFIG_DIR}/auth-bridge.pid"
LOG_FILE="${CONFIG_DIR}/auth-bridge.log"
HASH_FILE="${CONFIG_DIR}/auth-bridge.last-hash"
DISABLED_SENTINEL="${CONFIG_DIR}/auth-bridge.disabled"
WATCHER="${AIDC_SCRIPTS}/aidc-auth-bridge-watcher.sh"

is_macos() { [ "$(uname -s)" = "Darwin" ]; }

is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

usage() {
    cat <<'EOF'
aidc auth-bridge <verb>

Verbs:
  start [--force]   Idempotent start. --force overrides the disabled sentinel.
  stop              Stop the daemon. Touches the disabled sentinel so auto-start
                    (from `aidc create` / `aidc mcp start`) does NOT re-spawn it.
  status            Daemon state + last activity.
  logs [-n N]       Tail the auth-bridge log (default: tail -f). -n N for last N lines.
  restart           Stop + start. Clears the disabled sentinel.

Auto-managed:
  - `aidc create` and `aidc mcp start` ensure the daemon is running.
  - `aidc kill` and `aidc mcp stop` stop the daemon when no aidc-managed
    containers remain on the host.
  - An explicit `aidc auth-bridge stop` is respected -- the daemon stays
    stopped until something else triggers a start (next create, next mcp
    start, or explicit `auth-bridge start`).

macOS only. On Linux/WSL2 the daemon is a no-op (host credentials file is
bind-mounted directly into the container, so updates propagate for free).
EOF
}

# Print platform notice + exit 0 (non-error) when not on macOS. Callers
# (auto-start from create/mcp) can ignore the output safely.
not_needed_on_this_platform() {
    info "auth bridge is not needed on this platform (host credentials are bind-mounted directly)"
    exit 0
}

do_start() {
    local force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1; shift ;;
            *) die "unknown flag for start: $1" ;;
        esac
    done

    is_macos || not_needed_on_this_platform

    if [ -f "$DISABLED_SENTINEL" ] && [ "$force" -ne 1 ]; then
        die "auth bridge is disabled (sentinel at ${DISABLED_SENTINEL}); use 'aidc auth-bridge start --force' or 'aidc auth-bridge restart' to re-enable"
    fi
    if [ "$force" -eq 1 ]; then
        rm -f "$DISABLED_SENTINEL"
    fi

    if is_running; then
        info "auth bridge already running (pid=$(cat "$PID_FILE"))"
        return 0
    fi

    # Stale PID file from a previous crash.
    rm -f "$PID_FILE"

    mkdir -p "$CONFIG_DIR"
    [ -x "$WATCHER" ] || chmod 0755 "$WATCHER" 2>/dev/null || true

    # Load config to pick up auth_bridge.poll_seconds, propagate to watcher via env.
    load_config "$(pwd -P)" 2>/dev/null || true
    export AIDC_AUTH_BRIDGE_POLL_SECONDS="${AIDC_AUTH_BRIDGE_POLL_SECONDS:-30}"

    # Detach via nohup + setsid-equivalent (use nohup + & + disown).
    nohup bash "$WATCHER" >/dev/null 2>&1 &
    spawned_pid=$!
    disown "$spawned_pid" 2>/dev/null || true

    # Verify the watcher came up and wrote its own PID file.
    waited=0
    while [ "$waited" -lt 10 ]; do
        if is_running; then
            info "auth bridge started (pid=$(cat "$PID_FILE"))"
            return 0
        fi
        sleep 0.2
        waited=$((waited + 1))
    done
    die "auth bridge failed to start (no PID file appeared); check ${LOG_FILE}"
}

do_stop() {
    is_macos || not_needed_on_this_platform

    # Always touch the sentinel -- explicit stop means "stay stopped."
    mkdir -p "$CONFIG_DIR"
    : > "$DISABLED_SENTINEL"

    if ! is_running; then
        info "auth bridge not running (sentinel touched so auto-start won't respawn)"
        rm -f "$PID_FILE"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    if kill "$pid" 2>/dev/null; then
        # Wait briefly for the watcher's SIGTERM handler to clean up the PID file.
        waited=0
        while [ "$waited" -lt 10 ] && [ -f "$PID_FILE" ]; do
            sleep 0.2
            waited=$((waited + 1))
        done
        rm -f "$PID_FILE"
        info "auth bridge stopped (pid=${pid})"
    else
        rm -f "$PID_FILE"
        info "auth bridge process was not alive (PID file cleaned up)"
    fi
}

do_status() {
    is_macos || not_needed_on_this_platform

    printf '== aidc auth-bridge ==\n\n'

    if is_running; then
        printf 'state:     running (pid=%s)\n' "$(cat "$PID_FILE")"
    else
        printf 'state:     stopped\n'
    fi

    if [ -f "$DISABLED_SENTINEL" ]; then
        printf 'disabled:  YES (sentinel at %s) -- auto-start from create/mcp is suppressed\n' "$DISABLED_SENTINEL"
    else
        printf 'disabled:  no\n'
    fi

    if [ -f "$HASH_FILE" ]; then
        printf 'last-hash: %s\n' "$(cat "$HASH_FILE" 2>/dev/null | cut -c1-16)..."
    else
        printf 'last-hash: (never pushed)\n'
    fi

    # Count audit dirs the daemon would update.
    local audit_count=0
    if [ -d "${HOME}/aidc-audit" ]; then
        audit_count=$(find "${HOME}/aidc-audit" -mindepth 2 -maxdepth 2 -name '.claude-credentials.json' 2>/dev/null | wc -l | tr -d ' ')
    fi
    printf 'sessions:  %s bridged credential file(s) under ~/aidc-audit/\n' "$audit_count"

    printf 'log:       %s\n' "$LOG_FILE"

    # Show last 5 log lines if log exists.
    if [ -f "$LOG_FILE" ]; then
        printf '\n-- last 5 log lines --\n'
        tail -n 5 "$LOG_FILE" 2>/dev/null
    fi
}

do_logs() {
    is_macos || not_needed_on_this_platform

    local n=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -n) n="$2"; shift 2 ;;
            -n*) n="${1#-n}"; shift ;;
            *) die "unknown flag for logs: $1" ;;
        esac
    done

    [ -f "$LOG_FILE" ] || die "log file not found: ${LOG_FILE}"

    if [ -n "$n" ]; then
        tail -n "$n" "$LOG_FILE"
    else
        tail -f "$LOG_FILE"
    fi
}

do_restart() {
    is_macos || not_needed_on_this_platform
    # Restart is explicit re-enable -- clear sentinel before stop so stop's
    # sentinel-touch doesn't fight us, then start clean.
    rm -f "$DISABLED_SENTINEL"
    do_stop
    # do_stop touches the sentinel again; remove it before do_start.
    rm -f "$DISABLED_SENTINEL"
    do_start
}

# ---- ensure-running (internal) ----------------------------------------------
# Called by `aidc create` and `aidc mcp start`. Silent on success. If
# disabled by sentinel, log to auth-bridge.log (so users see in `aidc
# auth-bridge logs` that the auto-start was suppressed) but do NOT error.
do_ensure_running() {
    is_macos || exit 0
    if [ -f "$DISABLED_SENTINEL" ]; then
        mkdir -p "$CONFIG_DIR"
        printf '[%s] [aidc-auth-bridge] auto-start suppressed by disabled sentinel\n' "$(date -u +%FT%TZ)" >> "$LOG_FILE" 2>/dev/null || true
        exit 0
    fi
    if is_running; then
        exit 0
    fi
    # Reuse do_start path. Failure here should NOT fail the caller
    # (create/mcp); the session works without the bridge, just won't
    # auto-refresh.
    do_start || true
}

# ---- ensure-stopped (internal) ----------------------------------------------
# Called by `aidc kill` and `aidc mcp stop` when no aidc-managed containers
# remain. Stops the daemon without touching the disabled sentinel (so this
# auto-stop doesn't masquerade as user intent).
do_ensure_stopped() {
    is_macos || exit 0
    if ! is_running; then
        exit 0
    fi
    local pid
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    # Wait briefly for the watcher's SIGTERM handler to clean up.
    waited=0
    while [ "$waited" -lt 10 ] && [ -f "$PID_FILE" ]; do
        sleep 0.2
        waited=$((waited + 1))
    done
    rm -f "$PID_FILE"
}

VERB="${1:-}"
[ -z "$VERB" ] && { usage >&2; exit 2; }
shift

case "$VERB" in
    start)            do_start "$@" ;;
    stop)             do_stop "$@" ;;
    status)           do_status "$@" ;;
    logs)             do_logs "$@" ;;
    restart)          do_restart "$@" ;;
    ensure-running)   do_ensure_running "$@" ;;
    ensure-stopped)   do_ensure_stopped "$@" ;;
    -h|--help|help)   usage; exit 0 ;;
    *)                err "unknown verb: ${VERB}"; usage >&2; exit 2 ;;
esac
