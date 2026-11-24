#!/usr/bin/env bash
# aidc proxy <session> add|rm|ls|clear|up (a Kubernetes session): its ports on this machine.
#
# Each port is a tunnel (scripts/k8s/tunnel.sh): a local supervisor running `kubectl
# port-forward` with your own cluster credentials, on 127.0.0.1, started again when it drops or
# the dev pod is replaced. Tunnels belong to this machine: `aidc proxy <s> up` starts the ports
# the session was created with (--port) on another one.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=tunnel.sh
. "$AIDC_SCRIPTS/k8s/tunnel.sh"

usage() {
    cat <<'EOF'
aidc proxy <session> <subcommand> [args]     (kubernetes backend)

Subcommands:
  add  <PORT|HOST:CONTAINER>   tunnel a session port to localhost:HOST on this machine
  rm   <HOST_PORT>             stop that tunnel
  ls                           the session's declared ports and this machine's tunnels
  clear                        stop every tunnel of the session on this machine
  up                           start the session's declared ports (aidc create --port) here

A tunnel is a local process (kubectl port-forward, restarted when it drops or the dev
pod is replaced); its log is in ~/.local/state/aidc/tunnels/. Tunnels run on 127.0.0.1.
EOF
}

NAME="${1:-}"
case "$NAME" in ''|-h|--help) usage; exit 0 ;; esac
shift
SUBVERB="${1:-}"
[ -n "$SUBVERB" ] || { usage >&2; exit 2; }
shift
validate_session_name "$NAME"
k8s_require || exit 1
k8s_is_git_session "$NAME" && die "git is your git agent (the git container), not a session with ports"
ns=$(k8s_user_ns "$AIDC_K8S_USER")

do_add() {
    local spec="${1:-}" hc
    [ -n "$spec" ] || die "add requires a port (e.g. 3000 or 8080:80)"
    hc=$(k8s_port_spec "$spec") || exit 2
    k8s_require_session "$ns" "$NAME"
    set -- $hc
    k8s_tunnel_start "$ns" "$NAME" "$1" "$2" || exit 1
    info "tunnel: localhost:${1} -> ${NAME}:${2} (log: $(k8s_tunnel_dir "$ns")/${NAME}-${1}.log)"
}

do_rm() {
    local h="${1:-}"
    k8s_port_ok "$h" || die "rm requires a host port (1-65535)"
    if ! k8s_tunnel_pid "$ns" "$NAME" "$h" >/dev/null && [ ! -f "$(k8s_tunnel_dir "$ns")/${NAME}-${h}.spec" ]; then
        info "no tunnel on localhost:${h} for ${NAME} (already gone?)"
        return 0
    fi
    k8s_tunnel_stop "$ns" "$NAME" "$h"
    info "stopped the tunnel on localhost:${h}"
}

do_ls() {
    local declared rows h c pid
    declared=$(k8s_declared_ports "$ns" "$NAME") || declared="unknown (the cluster did not answer)"
    printf 'declared (aidc create --port): %s\n' "$(printf '%s' "${declared:-(none)}" | paste -sd' ' -)"
    rows=$(k8s_tunnels "$ns" "$NAME")
    if [ -z "$rows" ]; then
        printf 'no tunnels for %s on this machine\n' "$NAME"
        return 0
    fi
    printf '%-10s  %-28s  %s\n' HOST_PORT FORWARD SUPERVISOR
    while read -r h c pid; do
        if [ "$pid" = "-" ]; then pid="not running (aidc proxy ${NAME} add ${h}:${c})"; else pid="pid ${pid}"; fi
        printf '%-10s  %-28s  %s\n' "$h" "localhost:${h} -> ${NAME}:${c}" "$pid"
    done <<<"$rows"
}

do_clear() {
    local stopped
    stopped=$(k8s_tunnels_stop_all "$ns" "$NAME")
    if [ -z "$stopped" ]; then
        printf 'no tunnels to clear for %s on this machine\n' "$NAME"
        return 0
    fi
    info "stopped the tunnels on localhost:$(printf '%s' "$stopped" | paste -sd, -)"
}

do_up() {
    local declared spec hc started=0
    k8s_require_session "$ns" "$NAME"
    declared=$(k8s_declared_ports "$ns" "$NAME") \
        || die "cannot read ${NAME}'s declared ports: the cluster did not answer (${declared})"
    [ -n "$declared" ] || { info "${NAME} has no declared ports (aidc proxy ${NAME} add <port> for one here)"; return 0; }
    for spec in $declared; do
        hc=$(k8s_port_spec "$spec") || continue
        # shellcheck disable=SC2086  # "H C"
        set -- $hc
        if k8s_tunnel_start "$ns" "$NAME" "$1" "$2"; then
            info "tunnel: localhost:${1} -> ${NAME}:${2}"
            started=$((started + 1))
        fi
    done
    [ "$started" -gt 0 ] || exit 1
}

case "$SUBVERB" in
    add) do_add "$@" ;;
    rm) do_rm "$@" ;;
    ls) do_ls ;;
    clear) do_clear ;;
    up) do_up ;;
    -h|--help) usage ;;
    *) err "unknown subverb: ${SUBVERB}"; usage >&2; exit 2 ;;
esac
