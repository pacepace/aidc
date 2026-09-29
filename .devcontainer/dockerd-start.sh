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
# Self-healing supervisor for dockerd. dockerd can die mid-session (OOM, disk
# exhaustion, iptables conflict, etc.) and leave the container alive
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

# Storage driver. The inner /var/lib/docker sits on the outer container's own
# filesystem (DKR-03), which is overlayfs or ZFS depending on the host, and the
# kernel's overlay2 cannot stack on either. vfs works everywhere but stores every
# layer of every image and container as a full copy: a session running a
# compose stack reached 70-85 GB that way. fuse-overlayfs does the layering in
# userspace, works on any backing filesystem, and stores only each layer's
# changes (about a tenth of vfs for the same images). It needs /dev/fuse, which
# the privileged container has; without it, or if dockerd will not start on it,
# vfs is the fallback.
#
# Storage already on disk keeps the driver that wrote it: this script also runs
# as the watchdog's restart, and a daemon started on a different driver would
# not see the images and containers the session already has.
# The driver that started successfully is recorded in DRIVER_MARKER.
# AIDC_DOCKER_STORAGE_DRIVER overrides the choice and is never second-guessed.
DRIVER_MARKER=/var/lib/docker/.aidc-storage-driver
choose_storage_driver() {
    if [ -n "${AIDC_DOCKER_STORAGE_DRIVER:-}" ]; then
        printf '%s' "$AIDC_DOCKER_STORAGE_DRIVER"
        return
    fi
    if [ -s "$DRIVER_MARKER" ]; then
        cat "$DRIVER_MARKER"
        return
    fi
    # Storage from before the marker existed was always vfs.
    if [ -n "$(ls -A /var/lib/docker/vfs 2>/dev/null)" ]; then
        printf 'vfs'
        return
    fi
    if fuse_overlay_works; then
        printf 'fuse-overlayfs'
    else
        printf 'vfs'
    fi
}

# dockerd accepts fuse-overlayfs as long as the binary exists and fails only at
# the first layer it mounts, so try one real mount, on the filesystem dockerd
# will use, before choosing it.
fuse_overlay_works() {
    command -v fuse-overlayfs >/dev/null 2>&1 && [ -c /dev/fuse ] || return 1
    local t ok=1
    mkdir -p /var/lib/docker
    t=$(mktemp -d /var/lib/docker/.aidc-fuse-probe.XXXXXX) || return 1
    mkdir -p "$t/lower" "$t/upper" "$t/work" "$t/merged"
    echo probe > "$t/lower/f"
    if fuse-overlayfs -o "lowerdir=$t/lower,upperdir=$t/upper,workdir=$t/work" "$t/merged" 2>/dev/null; then
        if [ "$(cat "$t/merged/f" 2>/dev/null)" = probe ] && echo w > "$t/merged/g" 2>/dev/null \
                && [ -f "$t/upper/g" ]; then
            ok=0
        fi
        fusermount3 -u "$t/merged" 2>/dev/null || fusermount -u "$t/merged" 2>/dev/null \
            || umount "$t/merged" 2>/dev/null || true
    fi
    rm -rf "$t"
    return $ok
}

# Start dockerd on one driver and wait up to ~15s for it to answer. The socket
# file alone is not enough: dockerd creates it before initialising storage, so a
# driver that fails leaves a socket behind a daemon that has already exited.
start_dockerd() {
    local driver="$1"
    log "starting inner dockerd (logs: /var/log/aidc/dockerd.log, storage driver: ${driver})"
    rm -f /var/run/docker.sock /var/run/docker.pid
    nohup dockerd \
        --host=unix:///var/run/docker.sock \
        --storage-driver="${driver}" \
        >> /var/log/aidc/dockerd.log 2>&1 &
    local pid=$! waited=0
    while [ $waited -lt 30 ]; do
        if docker -H unix:///var/run/docker.sock version >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.5
        waited=$((waited + 1))
    done
    # Wait for it to exit: a second dockerd started while this one still holds
    # its pidfile and data-root lock fails to start.
    kill "$pid" 2>/dev/null || true
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ $waited -lt 20 ]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    kill -9 "$pid" 2>/dev/null || true
    return 1
}

: > /var/log/aidc/dockerd.log
STORAGE_DRIVER=$(choose_storage_driver)
if ! start_dockerd "$STORAGE_DRIVER"; then
    if [ "$STORAGE_DRIVER" = "fuse-overlayfs" ] && [ -z "${AIDC_DOCKER_STORAGE_DRIVER:-}" ] \
            && [ ! -s "$DRIVER_MARKER" ]; then
        log "WARN: dockerd did not start on fuse-overlayfs; falling back to vfs (full copy per layer)"
        STORAGE_DRIVER=vfs
        start_dockerd vfs || true
    fi
fi

if docker -H unix:///var/run/docker.sock version >/dev/null 2>&1; then
    # Make the socket usable from `docker` group (vscode is a member).
    chgrp docker /var/run/docker.sock 2>/dev/null || true
    chmod g+rw   /var/run/docker.sock 2>/dev/null || true
    printf '%s' "$STORAGE_DRIVER" > "$DRIVER_MARKER"
    log "inner dockerd ready (storage driver: ${STORAGE_DRIVER})"
else
    log "WARN: inner dockerd did not answer within 15s; check /var/log/aidc/dockerd.log"
    exit 1
fi

if [ "$SPAWN_WATCHDOG" = "1" ]; then
    spawn_watchdog
fi
