#!/usr/bin/env bash
# desc: Manage adhoc host->container port forwards for a running session.
#
# Usage:
#   aidc proxy <session> add <PORT|HOST:CONTAINER>     # start a forward
#   aidc proxy <session> rm  <HOST_PORT>               # stop one
#   aidc proxy <session> ls                            # list active forwards
#   aidc proxy <session> clear                         # stop all forwards for the session
#
# Mechanic: one `aidc/forwarder:${AIDC_VERSION_TAG}` socat sidecar per forward, joined to
# the session's docker network, publishing the requested host port. Adhoc
# forwards do NOT persist across `aidc restart` or `aidc kill` (per CLI-14).
#
# For port forwards baked into the session at create time, use `aidc create
# --port HOST:CONTAINER` instead -- those live in the compose stack and
# survive restart.

set -euo pipefail

# Tolerate piped consumers (grep -q, head, less) that close stdin early.
trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

FORWARDER_IMAGE="aidc/forwarder:${AIDC_VERSION_TAG}"

usage() {
    cat <<'EOF'
aidc proxy <session> <subcommand> [args]

Subcommands:
  add  <PORT|HOST:CONTAINER>   start a forward (PORT shorthand = same on both sides)
  rm   <HOST_PORT>             stop a single forward (key is the host port)
  ls                           list active forwards for this session
  clear                        stop every forward for this session

Examples:
  aidc proxy foo add 3000           # localhost:3000 -> dev:3000
  aidc proxy foo add 8080:80        # localhost:8080 -> dev:80
  aidc proxy foo rm 3000
  aidc proxy foo ls
  aidc proxy foo clear
EOF
}

# ---- arg parsing -------------------------------------------------------------

NAME="${1:-}"
case "$NAME" in
    ''|-h|--help) usage; exit 0 ;;
esac
shift

SUBVERB="${1:-}"
[ -z "$SUBVERB" ] && { usage >&2; exit 2; }
shift

validate_session_name "$NAME"
require_docker
session_exists "$NAME" || die "no such session: $NAME (try: aidc list)"

DEV_CT="$(container_name "$NAME" dev)"
NET_NAME="aidc-${NAME}-net"

# ---- helpers -----------------------------------------------------------------

# A forwarder container's name encodes its session AND host port, e.g.
#   aidc-foo-fwd-3000
fwd_name() {
    printf 'aidc-%s-fwd-%s' "$NAME" "$1"
}

# Validate "N" or "H:C" and split into HOST_PORT / CONTAINER_PORT globals.
# Dies on invalid input. Range: 1..65535 (lazy regex; docker enforces).
HOST_PORT=""
CONTAINER_PORT=""
parse_port_spec() {
    local spec="$1"
    case "$spec" in
        *:*) HOST_PORT="${spec%%:*}"; CONTAINER_PORT="${spec##*:}" ;;
        *)   HOST_PORT="$spec";       CONTAINER_PORT="$spec" ;;
    esac
    case "$HOST_PORT" in
        [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9]) ;;
        *) die "invalid host port: '${HOST_PORT}' (expected 1-65535)" ;;
    esac
    case "$CONTAINER_PORT" in
        [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9]) ;;
        *) die "invalid container port: '${CONTAINER_PORT}' (expected 1-65535)" ;;
    esac
}

# ---- subverb: add ------------------------------------------------------------

do_add() {
    local spec="${1:-}"
    [ -n "$spec" ] || die "add requires a port spec (e.g. 3000 or 8080:80)"
    parse_port_spec "$spec"

    local ct_name
    ct_name="$(fwd_name "$HOST_PORT")"

    if docker inspect "$ct_name" >/dev/null 2>&1; then
        die "host port ${HOST_PORT} is already forwarded for session ${NAME} (try: aidc proxy ${NAME} rm ${HOST_PORT})"
    fi

    ensure_image forwarder

    # `-d --rm`: ephemeral, intentionally lost on restart (per CLI-14).
    # `--network aidc-${SESSION}-net`: joins the session's docker network
    #     so socat can resolve `aidc-${SESSION}-dev` via compose DNS.
    # `-p H:C`: publish host:HOST_PORT into the sidecar's CONTAINER_PORT,
    #     where socat is listening.
    if ! docker run -d --rm \
            --name "$ct_name" \
            --network "$NET_NAME" \
            -p "${HOST_PORT}:${CONTAINER_PORT}" \
            "$FORWARDER_IMAGE" \
            "TCP-LISTEN:${CONTAINER_PORT},fork,reuseaddr" \
            "TCP:${DEV_CT}:${CONTAINER_PORT}" \
            >/dev/null 2>&1; then
        die "docker run failed (host port ${HOST_PORT} may already be in use by another process; try a different port)"
    fi
    info "forward: localhost:${HOST_PORT} -> ${DEV_CT}:${CONTAINER_PORT}"
}

# ---- subverb: rm -------------------------------------------------------------

do_rm() {
    local host_port="${1:-}"
    [ -n "$host_port" ] || die "rm requires a host port"
    case "$host_port" in
        [1-9]*) ;;
        *) die "invalid host port: '${host_port}'" ;;
    esac
    local ct_name
    ct_name="$(fwd_name "$host_port")"
    if ! docker inspect "$ct_name" >/dev/null 2>&1; then
        info "no forward for host port ${host_port} (already gone?)"
        return 0
    fi
    docker rm -f "$ct_name" >/dev/null 2>&1 || \
        die "docker rm failed for ${ct_name}"
    info "removed forward on localhost:${host_port}"
}

# ---- subverb: ls -------------------------------------------------------------

do_ls() {
    local names
    names=$(list_adhoc_forwards "$NAME")
    if [ -z "$names" ]; then
        printf 'no adhoc forwards for session %s\n' "$NAME"
        return 0
    fi
    # Output phase: tolerate piped consumers that early-exit.
    set +e
    set +o pipefail
    printf '%-10s  %s\n' "HOST_PORT" "FORWARD"
    # Each line is "aidc-<sess>-fwd-<host>|0.0.0.0:<host>-><container>/tcp, ...".
    # Drop the name's session prefix; show host port and the target dev:CONTAINER pair.
    while IFS='|' read -r ct ports; do
        local host_port="${ct##*-fwd-}"
        # `docker ps` returns the publish info like "0.0.0.0:3000->3000/tcp".
        # We rebuild a cleaner form pulling the container_port out of ports.
        local container_port
        container_port=$(printf '%s' "$ports" | sed -nE 's/.*->([0-9]+)\/tcp.*/\1/p' | head -1)
        printf '%-10s  localhost:%s -> %s:%s\n' \
            "$host_port" "$host_port" "$DEV_CT" "${container_port:-?}"
    done <<<"$names"
}

# ---- subverb: clear ----------------------------------------------------------

do_clear() {
    local ids
    ids=$(docker ps --filter "name=aidc-${NAME}-fwd-" -q 2>/dev/null)
    if [ -z "$ids" ]; then
        printf 'no adhoc forwards to clear for session %s\n' "$NAME"
        return 0
    fi
    # Count of unique containers, used purely for the summary message.
    local n
    n=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
    # xargs is portable; --no-run-if-empty (-r) is GNU-only, so guard the
    # call with the ids check above instead.
    printf '%s\n' "$ids" | xargs docker rm -f >/dev/null 2>&1 || \
        die "docker rm -f failed during clear"
    info "removed ${n} forward(s) for session ${NAME}"
}

# ---- dispatch ----------------------------------------------------------------

case "$SUBVERB" in
    add)   do_add   "$@" ;;
    rm)    do_rm    "$@" ;;
    ls)    do_ls    "$@" ;;
    clear) do_clear "$@" ;;
    -h|--help) usage ;;
    *) err "unknown subverb: ${SUBVERB}"; usage >&2; exit 2 ;;
esac
