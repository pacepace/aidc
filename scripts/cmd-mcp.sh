#!/usr/bin/env bash
# desc: Manage the aidc-mcp control plane server (start/stop/status/logs/token).
#
# Usage:
#   aidc mcp start                   - launch the server container
#   aidc mcp stop                    - tear it down
#   aidc mcp status                  - is it running? bind, port, last-access
#   aidc mcp logs [--follow]         - container stdout
#   aidc mcp token rotate            - new token, restart, print
#   aidc mcp token show              - print current token (sparingly)

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"

# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"

CONTAINER="aidc-mcp"
# Versioned per task-13; AIDC_VERSION_TAG is exported by the dispatcher.
IMAGE="aidc/mcp:${AIDC_VERSION_TAG}"
TOKEN_FILE="${HOME}/.config/aidc/mcp-token"
# MCP audit log + per-session transcript mirrors. XDG state dir (private,
# per-user) — NOT a bare ~/ dir or system /var/log — because these hold
# conversation transcripts that must not be world-readable.
AUDIT_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/aidc-mcp"
CONFIG_DIR="${HOME}/.config/aidc"

# require_docker is applied per-verb in the dispatch below (NOT globally) so
# `mcp help`, `mcp --help`, and `mcp token show` work without a running daemon.

# ---- helpers ----------------------------------------------------------------

mcp_token_generate() {
    # 32 bytes base64url, no padding. Portable on macOS + Linux.
    local raw b64
    raw=$(LC_ALL=C dd if=/dev/urandom bs=32 count=1 2>/dev/null)
    b64=$(printf '%s' "$raw" | base64 | tr '+/' '-_' | tr -d '=' | tr -d '\n')
    mkdir -p "$CONFIG_DIR"
    umask 077
    printf '%s\n' "$b64" > "$TOKEN_FILE"
    umask 022
    chmod 0600 "$TOKEN_FILE"
}

mcp_ensure_token() {
    if [ ! -s "$TOKEN_FILE" ]; then
        mcp_token_generate
        info "generated new MCP bearer token at $TOKEN_FILE"
    fi
}

mcp_validate_bind_address() {
    local addr="$1"
    # Accept localhost.
    [ "$addr" = "127.0.0.1" ] && return 0
    # Otherwise verify the address belongs to a real host interface.
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -E "inet[^6]* ${addr//./\\.}( |$)" >/dev/null && return 0
    fi
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr 2>/dev/null | grep -E "inet ${addr//./\\.}/" >/dev/null && return 0
    fi
    err "mcp.bind_address '$addr' does not match any host interface."
    err "available interface addresses:"
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '/inet [0-9]/ { print "  " $2 }' >&2 || true
    elif command -v ip >/dev/null 2>&1; then
        ip -4 -br addr 2>/dev/null | awk '{ print "  " $1 " " $3 }' >&2 || true
    fi
    return 1
}

# Read a single child key of a top-level YAML mapping.
# Args: file parent-key child-key
# Echoes the value (stripped of quotes / comments / surrounding whitespace) or
# nothing if absent. Handles the flat-block schema aidc uses; not a general YAML
# parser.
_aidc_yaml_nested() {
    local file="$1" parent="$2" child="$3"
    [ -f "$file" ] || return 0
    awk -v parent="$parent" -v child="$child" '
        BEGIN { in_block=0 }
        $0 ~ "^"parent":" { in_block=1; next }
        /^[A-Za-z]/      { in_block=0 }
        in_block && $0 ~ "^[[:space:]]+"child":" {
            v=$0
            sub("^[[:space:]]+"child":[[:space:]]*", "", v)
            sub(/[[:space:]]*#.*$/, "", v)
            sub(/^["'\'']/, "", v); sub(/["'\'']$/, "", v)
            sub(/[[:space:]]+$/, "", v)
            print v
            exit
        }
    ' "$file"
}

mcp_load_settings() {
    # Read mcp.bind_address and mcp.port from global config.
    # Prefer yq when present, otherwise use the nested-aware awk parser.
    local cfg="${CONFIG_DIR}/config.yaml"
    AIDC_MCP_BIND_ADDRESS="127.0.0.1"
    AIDC_MCP_PORT="7878"
    [ -f "$cfg" ] || return 0

    local b="" p=""
    if command -v yq >/dev/null 2>&1; then
        b=$(yq eval '.mcp.bind_address // ""' "$cfg" 2>/dev/null || printf '')
        p=$(yq eval '.mcp.port // ""' "$cfg" 2>/dev/null || printf '')
        [ "$b" = "null" ] && b=""
        [ "$p" = "null" ] && p=""
    fi
    if [ -z "$b" ]; then b=$(_aidc_yaml_nested "$cfg" "mcp" "bind_address"); fi
    if [ -z "$p" ]; then p=$(_aidc_yaml_nested "$cfg" "mcp" "port"); fi
    [ -n "$b" ] && AIDC_MCP_BIND_ADDRESS="$b"
    [ -n "$p" ] && AIDC_MCP_PORT="$p"
}

# ---- verbs -------------------------------------------------------------------

mcp_start() {
    if docker ps --filter "name=${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        info "aidc-mcp already running"
        mcp_status
        return 0
    fi
    if docker ps -a --filter "name=${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        info "removing stopped container"
        docker rm "$CONTAINER" >/dev/null
    fi
    mcp_ensure_token
    mcp_load_settings
    mcp_validate_bind_address "$AIDC_MCP_BIND_ADDRESS" || die "bad bind_address"

    ensure_image mcp   # inventory-driven build-if-missing (lib/common.sh)

    mkdir -p "$AUDIT_DIR"
    chmod 0700 "$AUDIT_DIR"   # private: transcripts/audit are not world-readable
    info "starting $CONTAINER on ${AIDC_MCP_BIND_ADDRESS}:${AIDC_MCP_PORT}"
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        -v "/var/run/docker.sock:/var/run/docker.sock:rw" \
        -v "${AIDC_ROOT}:/aidc:ro" \
        -v "${CONFIG_DIR}:/aidc-config:ro" \
        -v "${AUDIT_DIR}:/var/log/aidc-mcp:rw" \
        -e "AIDC_MCP_PORT=${AIDC_MCP_PORT}" \
        -p "${AIDC_MCP_BIND_ADDRESS}:${AIDC_MCP_PORT}:${AIDC_MCP_PORT}" \
        "$IMAGE" >/dev/null
    sleep 1
    mcp_status

    # Auto-start the host-side auth bridge so MCP's own Claude invocations
    # benefit from auto-refresh too. No-op on Linux/WSL2 and when the
    # bridge is already running. See task-17 for rationale.
    if [ "$(uname -s)" = "Darwin" ]; then
        bash "$AIDC_SCRIPTS/cmd-auth-bridge.sh" ensure-running 2>/dev/null || true
    fi
}

mcp_stop() {
    if docker ps -a --filter "name=${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        info "stopping $CONTAINER"
        docker rm -f "$CONTAINER" >/dev/null
    else
        info "aidc-mcp not running"
    fi

    # Stop the host-side auth bridge if nothing aidc-managed remains on
    # the host. ensure-stopped is no-op on Linux/WSL2 and when the daemon
    # is already down or stopped by user intent.
    if [ "$(uname -s)" = "Darwin" ] && ! aidc_anything_running; then
        bash "$AIDC_SCRIPTS/cmd-auth-bridge.sh" ensure-stopped 2>/dev/null || true
    fi
}

mcp_status() {
    mcp_load_settings
    local running last_access
    running=$(docker ps --filter "name=${CONTAINER}$" --format '{{.Names}} {{.Status}}' || true)
    if [ -z "$running" ]; then
        printf 'aidc-mcp: NOT RUNNING\n'
        printf '  configured bind: %s:%s\n' "$AIDC_MCP_BIND_ADDRESS" "$AIDC_MCP_PORT"
        return 0
    fi
    printf 'aidc-mcp: %s\n' "$running"
    printf '  bind:        %s:%s\n' "$AIDC_MCP_BIND_ADDRESS" "$AIDC_MCP_PORT"
    printf '  token file:  %s\n' "$TOKEN_FILE"
    printf '  audit dir:   %s\n' "$AUDIT_DIR"
    if [ -f "${AUDIT_DIR}/access.log" ]; then
        last_access=$(tail -1 "${AUDIT_DIR}/access.log" 2>/dev/null | head -c 200)
        [ -n "$last_access" ] && printf '  last event:  %s\n' "$last_access"
    fi
}

mcp_logs() {
    if [ "${1:-}" = "--follow" ] || [ "${1:-}" = "-f" ]; then
        exec docker logs -f "$CONTAINER"
    else
        exec docker logs "$CONTAINER"
    fi
}

mcp_token() {
    local sub="${1:-}"
    case "$sub" in
        rotate)
            require_docker   # rotate restarts the running server to pick up the new token
            mcp_token_generate
            info "wrote new token to $TOKEN_FILE"
            if docker ps --filter "name=${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
                info "restarting $CONTAINER to pick up the new token"
                docker restart "$CONTAINER" >/dev/null
            fi
            printf '%s\n' "$(cat "$TOKEN_FILE")"
            ;;
        show)
            [ -f "$TOKEN_FILE" ] || die "no token file at $TOKEN_FILE; run 'aidc mcp start' first"
            cat "$TOKEN_FILE"
            ;;
        ""|help|-h|--help)
            cat <<'EOF'
aidc mcp token rotate   - generate a new token + restart server, print new token
aidc mcp token show     - print the current token
EOF
            ;;
        *) err "unknown 'aidc mcp token' verb: $sub"; exit 2 ;;
    esac
}

# ---- dispatch ----------------------------------------------------------------

VERB="${1:-}"
shift || true

case "$VERB" in
    start)   require_docker; mcp_start "$@" ;;
    stop)    require_docker; mcp_stop "$@" ;;
    status)  require_docker; mcp_status "$@" ;;
    logs)    require_docker; mcp_logs "$@" ;;
    token)   mcp_token "$@" ;;
    ""|help|-h|--help)
        cat <<'EOF'
aidc mcp <verb> [args]

Verbs:
  start              Launch the aidc-mcp server container
  stop               Tear it down
  status             Running state, bind address, last event
  logs [--follow]    Container stdout
  token rotate       New bearer token + restart, prints the new token
  token show         Print the current token
EOF
        ;;
    *) err "unknown 'aidc mcp' verb: $VERB (try: aidc mcp help)"; exit 2 ;;
esac
