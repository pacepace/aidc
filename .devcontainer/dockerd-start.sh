#!/usr/bin/env bash
# Start the inner Docker daemon (DinD), idempotently.
#
# Called in two contexts:
#   1. From entrypoint.sh on the `aidc create` path (we own PID 1 via tini).
#   2. From devcontainer.json's postStartCommand on the VS Code Dev Containers
#      path (VS Code owns PID 1 with its own keep-alive loop, so our entrypoint
#      never runs — postStartCommand is the only hook that fires every start).
#
# Must run as root. From postStartCommand the caller is `vscode`, which has
# NOPASSWD sudo, so `sudo /usr/local/bin/aidc-dockerd-start.sh` is the typical
# invocation. Idempotent: re-running while dockerd is already up is a no-op.
set -euo pipefail

log() { printf '[aidc-dockerd-start] %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    log "must be run as root (try: sudo $0)"
    exit 1
fi

# ---- watchdog spawner ------------------------------------------------------
# Self-healing supervisor for dockerd. dockerd can die mid-session (OOM, vfs
# disk exhaustion, iptables conflict, etc.) and leave the container alive
# with no daemon -- every `docker` call inside then fails. Spawn a small
# backgrounded loop that probes liveness every 15s and re-invokes this
# script's start logic when dockerd is unresponsive.
#
# Idempotent: if a watchdog is already running for this container, do not
# spawn a second one. Tracked via /var/run/aidc-dockerd-watchdog.pid.
WATCHDOG_PID_FILE=/var/run/aidc-dockerd-watchdog.pid
spawn_watchdog() {
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        local existing
        existing=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || true)
        if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
            log "watchdog already running (pid=${existing}); not spawning another"
            return 0
        fi
    fi
    (
        # Detach from parent's stdin so a postStartCommand context can exit
        # without dragging the watchdog with it.
        exec </dev/null
        while true; do
            sleep 15
            if ! docker -H unix:///var/run/docker.sock version >/dev/null 2>&1; then
                printf '[%s] [aidc-dockerd-start] watchdog: dockerd unresponsive; restarting\n' \
                    "$(date -u +%FT%TZ)" >> /var/log/aidc/dockerd.log
                "$0" --no-watchdog || true   # re-invoke self for restart; flag prevents recursion
            fi
        done
    ) >/dev/null 2>&1 &
    echo $! > "$WATCHDOG_PID_FILE"
    log "spawned dockerd watchdog (pid=$!)"
}

# Allow the watchdog to call back into this script for the restart logic
# without also spawning a second watchdog.
SPAWN_WATCHDOG=1
case "${1:-}" in
    --no-watchdog) SPAWN_WATCHDOG=0; shift ;;
esac

if ! command -v dockerd >/dev/null 2>&1; then
    log "dockerd not installed; nothing to do"
    exit 0
fi

mkdir -p /var/log/aidc

# Liveness probe. Just checking that the socket file exists isn't enough --
# dockerd can crash and leave a stale socket behind, which would fool a
# naive `-S` test into bailing out. Probe with the client; if it answers,
# dockerd is genuinely up.
if [ -S /var/run/docker.sock ]; then
    if docker -H unix:///var/run/docker.sock version >/dev/null 2>&1; then
        log "dockerd already running and responding; ensuring watchdog is up"
        # Watchdog may have died independently of dockerd; ensure it exists.
        if [ "$SPAWN_WATCHDOG" = "1" ]; then
            spawn_watchdog
        fi
        exit 0
    fi
    log "stale docker.sock found (dockerd not responding); removing and restarting"
    rm -f /var/run/docker.sock
fi

# Also clean stale pidfile from a previous run so dockerd doesn't refuse to
# start with "Unable to get the TempDir under /var/run/docker..." style errors.
rm -f /var/run/docker.pid

# Storage driver: see entrypoint.sh for the long explanation. vfs is the
# safest default — works on every kernel and every outer storage stack.
STORAGE_DRIVER="${AIDC_DOCKER_STORAGE_DRIVER:-vfs}"
log "starting inner dockerd (logs: /var/log/aidc/dockerd.log, storage driver: ${STORAGE_DRIVER})"

nohup dockerd \
    --host=unix:///var/run/docker.sock \
    --storage-driver="${STORAGE_DRIVER}" \
    > /var/log/aidc/dockerd.log 2>&1 &

# Wait up to ~15s for the socket to appear.
waited=0
while [ ! -S /var/run/docker.sock ] && [ $waited -lt 30 ]; do
    sleep 0.5
    waited=$((waited + 1))
done

if [ -S /var/run/docker.sock ]; then
    # Make the socket usable from `docker` group (vscode is a member).
    chgrp docker /var/run/docker.sock 2>/dev/null || true
    chmod g+rw   /var/run/docker.sock 2>/dev/null || true
    log "inner dockerd ready"
else
    log "WARN: inner dockerd did not produce a socket within 15s; check /var/log/aidc/dockerd.log"
    exit 1
fi

if [ "$SPAWN_WATCHDOG" = "1" ]; then
    spawn_watchdog
fi
