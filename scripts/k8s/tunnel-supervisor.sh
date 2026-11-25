#!/usr/bin/env bash
# tunnel-supervisor.sh <namespace> <session> <host port> <container port> <pid file>: keeps one
# port of a Kubernetes session on 127.0.0.1 of this machine (K8S-14; scripts/k8s/tunnel.sh
# starts and stops it).
#
# `kubectl port-forward` to the dev pod, started again when it exits and when the dev pod is
# replaced: a port-forward to a pod that is gone does not always exit by itself, so the
# supervisor watches the pod's uid and restarts the forward when it changes. Between attempts it
# waits a little longer each time (up to 10 s). TERM stops the forward and the supervisor.
# When the session itself is gone (its dev StatefulSet not found, a few checks running: an
# `aidc kill` made on another machine), the supervisor stops by itself; a restart or upgrade keeps
# the StatefulSet, and a read that fails (the cluster not answering) is never "gone".

set -uo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"

NS="$1" S="$2" H="$3" C="$4" PIDFILE="$5"
POD="${S}-dev-0"
CHECK="${AIDC_K8S_TUNNEL_CHECK:-5}"
k8s_load_settings
printf '%s\n' "$$" > "$PIDFILE"

say() { printf '%s [tunnel %s localhost:%s -> %s:%s] %s\n' "$(date -u +%FT%TZ)" "$S" "$H" "$POD" "$C" "$*"; }
pf=""
# end_pf: stop the port-forward. k8s_kubectl is a function, so the background job is a subshell
# with kubectl as its child: both go.
end_pf() { [ -n "$pf" ] || return 0; pkill -TERM -P "$pf" 2>/dev/null; kill "$pf" 2>/dev/null; }
stop() {
    end_pf
    say "stopped"
    rm -f "$PIDFILE"
    exit 0
}
trap stop TERM INT HUP

# pod_uid: the dev pod's uid when it is running and not being deleted, else "".
pod_uid() {
    k8s_kubectl -n "$NS" get pod "$POD" --request-timeout=10s \
        -o jsonpath='{.metadata.uid}|{.status.phase}|{.metadata.deletionTimestamp}' </dev/null 2>/dev/null \
        | awk -F'|' '$2 == "Running" && $3 == "" { print $1 }'
}

# session_gone: 0 when the API says the dev StatefulSet does not exist; 1 when it exists or the
# read failed.
session_gone() {
    local out
    out=$(k8s_kubectl -n "$NS" get statefulset "${S}-dev" --ignore-not-found -o name --request-timeout=10s \
        </dev/null 2>/dev/null) || return 1
    [ -z "$out" ]
}

# nap <seconds>: a sleep TERM interrupts (a foreground sleep would hold the trap until it ends).
nap() { sleep "$1" & wait $! 2>/dev/null; }

wait_s=1 gone=0
GONE_CHECKS="${AIDC_K8S_TUNNEL_GONE_CHECKS:-3}"
say "started"
while :; do
    uid=$(pod_uid)
    if [ -z "$uid" ]; then
        if session_gone; then
            gone=$((gone + 1))
            if [ "$gone" -ge "$GONE_CHECKS" ]; then
                say "the session is gone (no ${S}-dev StatefulSet); stopping"
                rm -f "$PIDFILE" "${PIDFILE%.pid}.spec"
                exit 0
            fi
        else
            gone=0
        fi
        nap "$wait_s"
        [ "$wait_s" -ge 10 ] || wait_s=$((wait_s + 1))
        continue
    fi
    k8s_kubectl -n "$NS" port-forward "pod/${POD}" --address 127.0.0.1 "${H}:${C}" </dev/null &
    pf=$!
    say "forwarding (pod ${uid})"
    while kill -0 "$pf" 2>/dev/null; do
        nap "$CHECK"
        kill -0 "$pf" 2>/dev/null || break
        now=$(pod_uid)
        if [ "$now" != "$uid" ]; then
            say "the dev pod changed (${uid} -> ${now:-none}); reconnecting"
            end_pf
            break
        fi
        wait_s=1
    done
    wait "$pf" 2>/dev/null
    pf=""
    say "port-forward ended; again in ${wait_s}s"
    nap "$wait_s"
    [ "$wait_s" -ge 10 ] || wait_s=$((wait_s + 1))
done
