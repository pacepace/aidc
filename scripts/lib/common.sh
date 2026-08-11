#!/usr/bin/env bash
# aidc common library -- sourced by the dispatcher and every subcommand.
#
# Bash 3.2 compatible. No `mapfile`, no `declare -A`, no `${var,,}`-style
# case modification. macOS still ships bash 3.2 by default.
#
# Provides:
#   err / die / info        -- stderr logging helpers
#   validate_session_name   -- regex gate for Docker resource names
#   is_wsl2                 -- WSL2 detection
#   translate_wsl_path      -- C:\foo  ->  /mnt/c/foo  (under WSL2)
#   compose_project_name    -- session  ->  aidc-<session>
#   container_name          -- (session, role) -> aidc-<session>-<role>
#   session_exists          -- presence check via Docker label
#   realpath_portable       -- macOS-safe realpath

# ---- stderr logging ----------------------------------------------------------

err()  { printf '[aidc] error: %s\n' "$*" >&2; }
info() { printf '[aidc] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---- session name validation -------------------------------------------------
#
# Session names are interpolated into Docker container names, volume names,
# and network names. Restrict to a conservative subset to avoid breaking
# Docker's own resource-name rules.

validate_session_name() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        die "validation: session name is required (got empty string)"
    fi
    if ! printf '%s' "$name" | grep -Eq '^[a-z0-9][a-z0-9-]{0,30}$'; then
        die "validation: invalid session name '$name' (must match ^[a-z0-9][a-z0-9-]{0,30}$)"
    fi
}

# ---- WSL2 detection ----------------------------------------------------------

is_wsl2() {
    [ -f /proc/sys/kernel/osrelease ] && \
        grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease
}

# Translate a Windows-style host path (e.g. C:\Users\Pace\code\proj) into
# the WSL2 mount-point form (/mnt/c/Users/Pace/code/proj). On non-WSL2 hosts
# the path is returned unchanged.
translate_wsl_path() {
    local p="${1:-}"
    if ! is_wsl2; then
        printf '%s' "$p"
        return 0
    fi
    case "$p" in
        [A-Za-z]:\\*|[A-Za-z]:/*)
            local drive rest
            drive="$(printf '%s' "$p" | cut -c1 | tr '[:upper:]' '[:lower:]')"
            rest="$(printf '%s' "$p" | cut -c4- | tr '\\' '/')"
            printf '/mnt/%s/%s' "$drive" "$rest"
            ;;
        *)
            printf '%s' "$p"
            ;;
    esac
}

# ---- Docker resource naming --------------------------------------------------

compose_project_name() { printf 'aidc-%s' "$1"; }
container_name()       { printf 'aidc-%s-%s' "$1" "$2"; }

# Return 0 iff any container exists (running or not) for this session.
# Use `docker ps -a` because a paused/stopped session must still be considered
# present -- `aidc create my-feature` over the top of one must fail loudly.
#
# Two probes:
#   1. Label `aidc.session=<name>` (preferred; applied by cmd-create when yq
#      is available to splice labels into the rendered compose).
#   2. Container name pattern `aidc-<name>-dev` (always present because
#      compose.yaml.template hard-codes container_name).
session_exists() {
    local name="$1"
    if [ -n "$(docker ps -a --filter "label=aidc.session=${name}" -q 2>/dev/null)" ]; then
        return 0
    fi
    docker inspect "aidc-${name}-dev" >/dev/null 2>&1
}

# ---- portable realpath -------------------------------------------------------
#
# macOS doesn't have GNU `realpath` by default; `readlink -f` is also a
# GNU-ism. Try python3 first (handles symlinks), then fall back to a
# cd-and-pwd pair, which handles the common case of "this exists, resolve
# its parent and append".

realpath_portable() {
    local p="${1:-}"
    if [ -z "$p" ]; then
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null && return 0
    fi
    if [ -d "$p" ]; then
        (cd "$p" && pwd -P)
    elif [ -e "$p" ]; then
        local d b
        d=$(dirname "$p")
        b=$(basename "$p")
        (cd "$d" && printf '%s/%s\n' "$(pwd -P)" "$b")
    else
        # Non-existent path: best-effort.
        case "$p" in
            /*) printf '%s\n' "$p" ;;
            *)  printf '%s/%s\n' "$(pwd -P)" "$p" ;;
        esac
    fi
}

# ---- timestamp helper --------------------------------------------------------

aidc_timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# ---- dependency check --------------------------------------------------------
#
# Run on demand from subcommands that need Docker. The dispatcher itself
# stays cheap so `aidc help` works on a fresh checkout.

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
    docker info >/dev/null 2>&1 || die "docker daemon not reachable (is it running?)"
}

require_cmd() {
    local missing=""
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
        die "required commands missing:${missing}"
    fi
}

# ---- aidc image inventory ----------------------------------------------------
#
# Single source of truth for the seven aidc/* images. Emits lines of:
#   <image-tag>|<build-context-dir>|<dockerfile-path>
#
# Order matters: small images first (fail-fast on the cheap ones), dev-base
# last (the slowest). Used by:
#   - cmd-rebuild.sh (iterates every row; force rebuild of each)
#   - ensure_image() below (looks up one row by role, build-if-missing)
#
# Requires AIDC_ROOT and AIDC_VERSION_TAG to be set in env. The dispatcher
# exports both; subcommands sourcing this lib see them.
aidc_image_inventory() {
    : "${AIDC_ROOT:?AIDC_ROOT not set}"
    : "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
    cat <<EOF
aidc/squid:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/squid|${AIDC_ROOT}/proxy/squid/Dockerfile
aidc/refresher:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/refresher|${AIDC_ROOT}/proxy/refresher/Dockerfile
aidc/policy:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/policy|${AIDC_ROOT}/proxy/policy/Dockerfile
aidc/audit:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/audit|${AIDC_ROOT}/proxy/audit/Dockerfile
aidc/forwarder:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/forwarder|${AIDC_ROOT}/proxy/forwarder/Dockerfile
aidc/mcp:${AIDC_VERSION_TAG}|${AIDC_ROOT}/mcp|${AIDC_ROOT}/mcp/Dockerfile
aidc/dev-base:${AIDC_VERSION_TAG}|${AIDC_ROOT}/.devcontainer|${AIDC_ROOT}/.devcontainer/Dockerfile
EOF
}

# Ensure the aidc/<role> image exists locally, building it from the canonical
# inventory when the tag is absent. Idempotent: a present image short-circuits.
#   ensure_image <role>   role in: squid|refresher|policy|audit|forwarder|mcp|dev-base
#
# Single home for the "build if missing" pattern: cmd-create (proxy stack +
# dev-base, eagerly), cmd-mcp (mcp, lazy), cmd-proxy (forwarder, lazy).
# cmd-rebuild force-builds every inventory row directly and doesn't use this.
ensure_image() {
    local role="$1"
    local row tag context dockerfile
    row=$(aidc_image_inventory | grep -E "^aidc/${role}:" || true)
    [ -n "$row" ] || die "ensure_image: unknown role '${role}' (expected: squid, refresher, policy, audit, forwarder, mcp, dev-base)"
    IFS='|' read -r tag context dockerfile <<EOF
$row
EOF
    if docker image inspect "$tag" >/dev/null 2>&1; then
        return 0
    fi
    [ -f "$dockerfile" ] || die "ensure_image: Dockerfile not found for ${tag}: ${dockerfile}"
    info "building ${tag} (missing locally)"
    docker build -t "$tag" -f "$dockerfile" "$context"
}

# Returns 0 if any aidc-managed container is alive on this host. Used to
# decide whether to tear down host-side daemons (auth-bridge) on
# `aidc kill` / `aidc mcp stop`. Catches both per-session containers
# (aidc-<session>-*) and the global MCP container (aidc-mcp).
aidc_anything_running() {
    if docker ps --filter 'name=^aidc-' -q 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

# ---- adhoc port-forward sidecars --------------------------------------------
#
# `aidc proxy <session> add` launches one socat sidecar per forward, named
# aidc-<session>-fwd-<hostport>, OUTSIDE the compose project. compose-down
# never touches them, so teardown / restart / upgrade must sweep them
# explicitly. These two helpers are the single home for that pattern.

# Emit "name|ports" for each RUNNING adhoc forwarder of a session (for display
# by cmd-proxy ls and cmd-status). Empty output when there are none.
list_adhoc_forwards() {
    local session="$1"
    docker ps --filter "name=aidc-${session}-fwd-" \
              --format '{{.Names}}|{{.Ports}}' 2>/dev/null
}

# Remove ALL adhoc forwarders for a session (running or stopped). Prints the
# optional note only when there was something to remove. Best-effort: never
# fails the caller.
remove_adhoc_forwards() {
    local session="$1" note="${2:-}"
    local ids
    ids=$(docker ps -a --filter "name=aidc-${session}-fwd-" -q 2>/dev/null || true)
    [ -z "$ids" ] && return 0
    [ -n "$note" ] && info "$note"
    printf '%s\n' "$ids" | xargs docker rm -f >/dev/null 2>&1 || true
}

# Wait for the dev container of a session to print its ready marker.
#   wait_for_dev_ready <session> [max-seconds]
# Polls `docker logs` (NOT `docker exec` -- exec polling during the dev
# container's inner-dockerd / iptables setup was observed to race with
# squid's first-fetch and produce transient connection-refused).
#
# Returns 0 on success, 1 on timeout. On timeout, the caller is responsible
# for surfacing the failure context (the loop already printed progress).
# Surfaces progress messages every ~10s as new [aidc-*] log lines appear.
wait_for_dev_ready() {
    local session="$1"
    local max_seconds="${2:-${AIDC_DEV_WAIT_SECONDS:-900}}"
    local dev_ct
    dev_ct="$(container_name "$session" dev)"

    local i=0 last_msg="" logs msg
    while [ "$i" -lt "$max_seconds" ]; do
        logs=$(docker logs "$dev_ct" 2>&1 || true)
        if printf '%s' "$logs" | grep -q '\[aidc-user-main\] ready'; then
            info "$dev_ct ready (user-main reported ready)"
            return 0
        fi
        if [ $((i % 10)) -eq 0 ]; then
            msg=$(printf '%s' "$logs" \
                  | grep -E '^\[aidc-(entrypoint|dockerd-start|user-main)\]|^==> baking|^Downloading Python|^Installing Python' \
                  | tail -1 || true)
            if [ -n "$msg" ] && [ "$msg" != "$last_msg" ]; then
                info "  $msg"
                last_msg="$msg"
            fi
        fi
        i=$((i + 2))
        sleep 2
    done
    return 1
}
