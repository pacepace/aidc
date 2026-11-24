# shellcheck shell=bash
# Tunnels: a Kubernetes session's ports on the user's own machine (K8S-14).
#
# One supervisor per port, a local process the user can see (`aidc proxy <s> ls`, `ps`) and stop
# (`aidc proxy <s> rm`): it runs `kubectl port-forward` to the session's dev pod with the user's
# own cluster credentials (k8s_kubectl), on 127.0.0.1 only, and starts it again when it exits or
# when the dev pod is replaced (restart, upgrade, a node reboot), so the port comes back by
# itself. Each supervisor keeps a pid file and a log in this machine's state directory:
#   ${XDG_STATE_HOME:-~/.local/state}/aidc/tunnels/<namespace>/<session>-<host port>.{pid,log,spec}
# The ports a session was created with are also recorded on its StatefulSet (aidc/ports), so
# `aidc proxy <s> up` starts them on another machine.
#
# Sourced after lib.sh.

# k8s_tunnel_dir <namespace>: this machine's tunnel files for the user's namespace.
k8s_tunnel_dir() { printf '%s/aidc/tunnels/%s' "${XDG_STATE_HOME:-${HOME}/.local/state}" "$1"; }

# k8s_port_ok <s>: 1-65535, no leading zero.
k8s_port_ok() {
    case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -le 65535 ]
}

# k8s_port_spec <N|H:C>: prints "H C", or says why not on stderr and returns 1.
k8s_port_spec() {
    local h c
    case "$1" in
        *:*:*) printf 'invalid port: %s (expected N or HOST:CONTAINER)\n' "'$1'" >&2; return 1 ;;
        *:*) h="${1%%:*}" c="${1##*:}" ;;
        *) h="$1" c="$1" ;;
    esac
    k8s_port_ok "$h" || { printf 'invalid host port: %s (expected 1-65535)\n' "'$h'" >&2; return 1; }
    k8s_port_ok "$c" || { printf 'invalid container port: %s (expected 1-65535)\n' "'$c'" >&2; return 1; }
    printf '%s %s\n' "$h" "$c"
}

# k8s_tunnel_pid <namespace> <session> <host port>: the supervisor's pid when it is running,
# else returns 1 (a stale pid file is removed). A pid reused by another program is not it: the
# process must be this supervisor.
k8s_tunnel_pid() {
    local f pid
    f="$(k8s_tunnel_dir "$1")/${2}-${3}.pid"
    [ -f "$f" ] || return 1
    pid=$(cat "$f" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) rm -f "$f"; return 1 ;; esac
    if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q 'tunnel-supervisor'; then
        printf '%s' "$pid"
        return 0
    fi
    rm -f "$f"
    return 1
}

# k8s_tunnels <namespace> <session>: this machine's tunnels of the session, one per line,
# "<host port> <container port> <pid or ->" (- when its supervisor is not running).
k8s_tunnels() {
    local d f h c pid
    d=$(k8s_tunnel_dir "$1")
    [ -d "$d" ] || return 0
    for f in "$d/${2}"-*.spec; do
        [ -f "$f" ] || continue
        h="${f##*/}"; h="${h#"${2}"-}"; h="${h%.spec}"
        case "$h" in ''|*[!0-9]*) continue ;; esac
        c=$(cut -d' ' -f2 "$f" 2>/dev/null)
        pid=$(k8s_tunnel_pid "$1" "$2" "$h") || pid="-"
        printf '%s %s %s\n' "$h" "${c:-?}" "$pid"
    done | sort -n
}

# k8s_tunnel_start <namespace> <session> <host port> <container port>: start the supervisor and
# wait until the port answers here. Returns 1, saying why on stderr, when it does not (the
# supervisor is stopped again then).
k8s_tunnel_start() {
    local ns="$1" s="$2" h="$3" c="$4" d log pid i from
    d=$(k8s_tunnel_dir "$ns")
    mkdir -p "$d" || { printf 'cannot make %s\n' "$d" >&2; return 1; }
    if pid=$(k8s_tunnel_pid "$ns" "$s" "$h"); then
        printf 'localhost:%s already tunnels to %s (supervisor %s)\n' "$h" "$s" "$pid" >&2
        return 0
    fi
    log="$d/${s}-${h}.log"
    # The log is kept across tunnels on the same port: only what this one writes counts.
    from=1
    [ ! -f "$log" ] || from=$(( $(wc -l < "$log") + 1 ))
    printf '%s %s\n' "$h" "$c" > "$d/${s}-${h}.spec"
    # Detached from this shell (nohup; setsid is not on every Mac), so it outlives the command.
    nohup bash "$AIDC_SCRIPTS/k8s/tunnel-supervisor.sh" "$ns" "$s" "$h" "$c" "$d/${s}-${h}.pid" \
        </dev/null >>"$log" 2>&1 &
    for i in $(seq 1 "${AIDC_K8S_TUNNEL_WAIT:-30}"); do
        if tail -n "+${from}" "$log" 2>/dev/null | grep -q "address already in use\|unable to listen"; then
            k8s_tunnel_stop "$ns" "$s" "$h" >/dev/null 2>&1
            printf 'localhost:%s is taken on this machine; pick another host port (HOST:CONTAINER)\n' "$h" >&2
            return 1
        fi
        if k8s_tunnel_pid "$ns" "$s" "$h" >/dev/null && tail -n "+${from}" "$log" 2>/dev/null | grep -q 'Forwarding from'; then
            return 0
        fi
        sleep 1
        : "$i"
    done
    printf 'the tunnel to %s:%s did not come up in %ss; it keeps trying (log: %s)\n' "$s" "$c" "${AIDC_K8S_TUNNEL_WAIT:-30}" "$log" >&2
    return 0
}

# k8s_tunnel_stop <namespace> <session> <host port>: stop the supervisor (it stops its
# port-forward) and forget the tunnel.
k8s_tunnel_stop() {
    local ns="$1" s="$2" h="$3" d pid i
    d=$(k8s_tunnel_dir "$ns")
    if pid=$(k8s_tunnel_pid "$ns" "$s" "$h"); then
        kill "$pid" 2>/dev/null || true
        for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; : "$i"; done
    fi
    rm -f "$d/${s}-${h}.pid" "$d/${s}-${h}.spec"
}

# k8s_tunnels_stop_all <namespace> <session>: stop every tunnel of the session on this machine;
# prints the host ports it stopped.
k8s_tunnels_stop_all() {
    local h c pid
    while read -r h c pid; do
        [ -n "$h" ] || continue
        k8s_tunnel_stop "$1" "$2" "$h"
        printf '%s\n' "$h"
        : "$c" "$pid"
    done <<EOF_T
$(k8s_tunnels "$1" "$2")
EOF_T
}

# k8s_declared_ports <namespace> <session>: the ports the session was created with ("H:C" per
# line), from its StatefulSet. Returns 2 when the cluster did not answer.
k8s_declared_ports() {
    local out
    out=$(k8s_get "$1" statefulset "${2}-dev" -o jsonpath='{.metadata.annotations.aidc/ports}') \
        || { printf '%s' "$out"; return 2; }
    printf '%s' "$out" | tr ', ' '\n\n' | awk 'NF'
}
