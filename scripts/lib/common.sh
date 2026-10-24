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
#   aidc_scratchpad_mount   -- compose line bridging Claude's scratchpad dir

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

# ---- Claude scratchpad bridge ------------------------------------------------
#
# Claude Code keeps per-session working files -- scratchpad/ and tasks/ -- under
# /tmp/claude-<uid>/<encoded-cwd>/<session-id>/. That is derived from the uid
# Claude runs as and the directory it was launched in, so the container and the
# host agree on it only because two other things already line up: the workspace
# is bind-mounted at its own host path, and tmux starts Claude in REPO_PATH.
# <encoded-cwd> is therefore the same string the memory bridge uses, which is
# why both mounts take ENCODED_REPO.
#
# The dev container's `vscode` user is pinned to this uid (.devcontainer/
# Dockerfile), which is what lets a host-owned scratchpad dir be written from
# inside the container.
AIDC_CONTAINER_UID=1000

# Host-side scratchpad dir for one repo: (uid, encoded-repo).
aidc_scratchpad_host_dir() {
    printf '/tmp/claude-%s/%s' "$1" "$2"
}

# Compose volume line bridging that dir into the container: (uid, encoded-repo).
#
# Only this repo's subdirectory is bridged, never the whole /tmp/claude-<uid>
# root -- the root holds every other project's scratchpad plus harness scratch,
# and exposing all of it to the sandbox is the same mistake as sharing the whole
# ~/.claude.
#
# Emits nothing and returns 1 when the host uid differs from the container's:
# the host dirs are mode 0700, so the mount would land unwritable and Claude
# could not create its own scratchpad. Not bridging degrades; bridging wrong
# breaks.
aidc_scratchpad_mount() {
    local host_uid="$1" encoded_repo="$2"
    [ "$host_uid" = "$AIDC_CONTAINER_UID" ] || return 1
    printf -- '- %s:%s:rw' \
        "$(aidc_scratchpad_host_dir "$host_uid" "$encoded_repo")" \
        "$(aidc_scratchpad_host_dir "$AIDC_CONTAINER_UID" "$encoded_repo")"
}

# Create the host scratchpad dir and its root at 0700: (dir).
#
# Returns 1 instead of creating anything when the path cannot be claimed
# safely. Both levels sit under /tmp, which is world-writable and sticky, so
# either one may already exist as another user's directory -- or as a symlink
# someone planted -- and `mkdir -p`/`chmod` would follow it. Refusing there
# costs a session its scratchpad bridge; chmod'ing through it would hand a
# stranger's directory the 0700 treatment, or retarget it entirely.
#
# Every failure is a refusal, never an abort: callers run under `set -e`, and
# an optional convenience must not be able to take `aidc create` down with it.
# The container entrypoint's half of this bridge is non-fatal for the same
# reason.
aidc_scratchpad_prepare_host_dir() {
    local dir="$1" root p
    root=$(dirname "$dir")
    for p in "$root" "$dir"; do
        # -O is "owned by the effective uid"; the -e guard lets a path that
        # does not exist yet through to mkdir.
        if [ -L "$p" ] || { [ -e "$p" ] && [ ! -O "$p" ]; }; then
            return 1
        fi
    done
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 0700 "$root" "$dir" 2>/dev/null || return 1
}

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

# Retire the host-side auth-bridge watcher that aidc < 1.5.0 left running on
# macOS. It was a nohup-detached loop whose only stop paths were commands that
# no longer exist, so a host that upgraded the CLI would otherwise keep a
# Keychain poller alive until reboot, rewriting credentials files nobody
# reads. Idempotent and silent when there is nothing to retire; called from
# `aidc create` and `aidc kill`, the commands every host runs eventually.
aidc_retire_auth_bridge() {
    local dir="${HOME}/.config/aidc" pid
    [ -e "${dir}/auth-bridge.pid" ] || [ -e "${dir}/auth-bridge.log" ] || [ -e "${dir}/auth-bridge.log.1" ] \
        || [ -e "${dir}/auth-bridge.disabled" ] || [ -e "${dir}/auth-bridge.last-hash" ] || return 0
    pid=$(cat "${dir}/auth-bridge.pid" 2>/dev/null || true)
    # The pid file outlives reboots and the watcher did not, so a number in it
    # may belong to an unrelated process by now: signal it only if its command
    # line is the watcher's.
    case "$pid" in
        ''|*[!0-9]*) ;;
        *)
            if ps -o command= -p "$pid" 2>/dev/null | grep -q 'aidc-auth-bridge-watcher'; then
                kill "$pid" 2>/dev/null || true
                info "retired the auth-bridge watcher (pid ${pid}) left by an earlier aidc; logins now live inside each session"
            fi
            ;;
    esac
    rm -f "${dir}/auth-bridge.pid" "${dir}/auth-bridge.log" "${dir}/auth-bridge.log.1" \
          "${dir}/auth-bridge.disabled" "${dir}/auth-bridge.last-hash"
}

# Where a session's rendered compose file lives on the host. It is the only record of
# how the session was created, and `aidc upgrade`, `aidc network` and `aidc kill` read it
# back for the session's whole life, so it is kept with the operator's state rather
# than in /tmp, which a reboot or a disk cleanup empties and then leaves the session
# impossible to upgrade. The path is built from the host home alone (not
# XDG_STATE_HOME) because `aidc create` also runs inside aidc-mcp, whose environment
# carries the host home (AIDC_HOST_HOME) but not the host's XDG settings, and both
# must name the same file.
aidc_session_compose_path() {
    printf '%s/.local/state/aidc/sessions/%s.yaml' "${AIDC_HOST_HOME:-$HOME}" "$1"
}

# Where an aidc before v1.9.9 rendered it.
aidc_legacy_compose_path() {
    printf '/tmp/aidc-%s.yaml' "$1"
}

# The compose file session $1 has now, without moving anything: the state copy, else a
# /tmp copy left by an older aidc, else the state path (callers test -f). For `kill`,
# which is about to delete it.
aidc_session_compose_find() {
    local new legacy
    new=$(aidc_session_compose_path "$1")
    legacy=$(aidc_legacy_compose_path "$1")
    if [ ! -f "$new" ] && [ -f "$legacy" ]; then
        printf '%s' "$legacy"
    else
        printf '%s' "$new"
    fi
}

# Remove every copy of session $1's compose file (it carries the session's secrets).
# Prints the paths it removed, space-separated, or nothing.
aidc_remove_session_compose() {
    local f removed=""
    for f in "$(aidc_session_compose_path "$1")" "$(aidc_legacy_compose_path "$1")"; do
        [ -f "$f" ] || continue
        if rm -f "$f" 2>/dev/null && [ ! -e "$f" ]; then
            removed="${removed:+${removed} }${f}"
        else
            printf '[aidc] warning: could not remove %s; it holds the session secrets, delete it by hand\n' "$f" >&2
        fi
    done
    printf '%s' "$removed"
}

# The compose file to read for session $1: the state copy, after first moving a
# /tmp copy left by an older aidc into place so the next cleanup of /tmp cannot take
# it. Prints the state path whether or not the file exists (callers test -f), or the
# /tmp path when it could not be moved. A library function: reports on stderr and
# never calls die (see the shell-libraries learnings).
aidc_session_compose_file() {
    local name="$1" new legacy
    new=$(aidc_session_compose_path "$name")
    legacy=$(aidc_session_compose_find "$name")
    if [ "$legacy" != "$new" ]; then
        if ( umask 0077; mkdir -p "$(dirname "$new")" ) 2>/dev/null \
                && cp -p "$legacy" "$new" 2>/dev/null && chmod 600 "$new"; then
            rm -f "$legacy"
            printf '[aidc] moved session %s compose file from %s to %s\n' "$name" "$legacy" "$new" >&2
        else
            rm -f "$new" 2>/dev/null
            printf '[aidc] warning: could not move %s to %s; using it where it is\n' "$legacy" "$new" >&2
            printf '%s' "$legacy"
            return 0
        fi
    fi
    printf '%s' "$new"
}

# A compose file rendered before v1.5.0 bind-mounts the host's Claude login
# into the dev container. `aidc upgrade` reuses that file, and the new image
# reads /home/vscode/.claude/.credentials.json -- exactly where the old mount
# lands -- so an upgraded session would keep the stale-inode bridge this
# release removes. Drop the two legacy mount lines in place (the file stays
# 0600; sed -i is not portable, so write via a private mktemp file). Returns 0 when it
# removed something, 1 when there was nothing to strip.
aidc_strip_legacy_auth_mounts() {
    local file="$1" tmp
    grep -qE ':/home/vscode/\.claude\.json:ro|:/home/vscode/\.claude/\.credentials\.json:' "$file" 2>/dev/null || return 1
    tmp=$(umask 0077; mktemp "${file}.XXXXXX") || return 1
    grep -vE ':/home/vscode/\.claude\.json:ro|:/home/vscode/\.claude/\.credentials\.json:' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

# `aidc upgrade` reuses the compose file rendered at create time, whose dev
# service pins `image: aidc/dev-base:<tag-at-create-time>`. Recreating from it
# unchanged brings the container back on the OLD tag, so across a version bump
# "upgrade" moved nothing (CLI-17 requires the CURRENT tag). Point the dev
# service at the given tag, in place, via a temp file (sed -i is not portable;
# the file stays 0600). The sidecar image lines are left alone: `--no-deps dev`
# never recreates them, and only kill + create replaces the proxy stack.
aidc_set_compose_dev_image() {
    local file="$1" tag="$2" tmp
    tmp=$(umask 0077; mktemp "${file}.XXXXXX") || return 1
    sed -E "s|^([[:space:]]*image:[[:space:]]*)aidc/dev-base:[^[:space:]]+|\\1${tag}|" "$file" > "$tmp" \
        || { rm -f "$tmp"; return 1; }
    grep -q "image: ${tag}\$" "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

# aidc_session_audit_dir <session>: the session's audit dir on the HOST, read from
# the audit container's mount rather than re-derived from config (the config can
# have changed since the session was created). Empty when the container is gone.
aidc_session_audit_dir() {
    docker inspect "$(container_name "$1" audit)" \
        --format '{{range .Mounts}}{{if eq .Destination "/var/aidc/audit"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null || printf ''
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

# Remove a session's own networks (aidc-<s>-net, aidc-<s>-egress), disconnecting
# anything still attached first. `docker compose down` leaves a network in place --
# printing "Resource is still in use" and exiting 0 -- while a container outside the
# project is connected to it: an `aidc proxy` forwarder, or another session attached
# with `aidc network`. aidc-mcp identifies a session by the id of aidc-<s>-net, so a
# leftover network would keep a killed session alive there, and a session created
# again under the name would inherit its predecessor's queued prompts and webhook.
# Returns 1, naming them on stderr, when a network cannot be removed.
remove_session_networks() {
    local session="$1" net ct left=""
    for net in "aidc-${session}-net" "aidc-${session}-egress"; do
        docker network inspect "$net" >/dev/null 2>&1 || continue
        for ct in $(docker network inspect "$net" \
                --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); do
            # Anything still attached that is not this session's own (another session
            # joined with `aidc network`, a leftover forwarder) loses that network
            # here. Say so: silently cutting a live session off a network it was
            # attached to is the kind of thing someone debugs for an hour.
            case "$ct" in
                "aidc-${session}-"*) ;;
                *) info "detaching ${ct} from ${net} (it is not part of session '${session}')" ;;
            esac
            docker network disconnect -f "$net" "$ct" >/dev/null 2>&1 || true
        done
        docker network rm "$net" >/dev/null 2>&1 || true
        if docker network inspect "$net" >/dev/null 2>&1; then
            left="${left:+${left} }${net}"
        fi
    done
    if [ -n "$left" ]; then
        err "could not remove network(s) of session '${session}': ${left}"
        return 1
    fi
}

# Repeat to the operator every line of a dev container's log that says Claude cannot
# write this session's transcripts.
#   relay_transcript_warnings <log-text>
# Such a session looks healthy from here and says so only in Claude's own status bar,
# while the orchestrator waits on replies the MCP cannot read. The lines are matched
# by the tag alone (AIDC_TRANSCRIPT_UNWRITABLE_TAG in .devcontainer/claude-state-install.sh,
# which writes them), so their wording is free to change. Always returns 0: callers
# run under `set -e`, and a log with nothing to say is the normal case.
relay_transcript_warnings() {
    printf '%s\n' "$1" | grep -F 'transcript-unwritable:' \
        | while IFS= read -r msg; do info "WARNING: $msg"; done || true
    return 0
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
            relay_transcript_warnings "$logs"
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
