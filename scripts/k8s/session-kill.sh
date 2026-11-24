#!/usr/bin/env bash
# aidc kill <name> --backend kubernetes: remove a session from the cluster.
#
# Everything the session made goes (labelled aidc/session=<name>): its dev StatefulSet and
# home volume, its proxy, Service and NetworkPolicies. Its audit volume is kept (SEC-06), and so
# is the user's disk with the repo on it.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"

case "${1:-}" in
    -h|--help) printf 'aidc kill <name> --backend kubernetes\n\nRemoves the session from the cluster; its audit volume and your disk stay.\n'; exit 0 ;;
esac
NAME="${1:-}"
validate_session_name "$NAME"
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
sel="aidc/session=${NAME}"
if [ -z "$(k8s_kubectl -n "$ns" get deployment,statefulset -l "$sel" -o name 2>/dev/null)" ]; then
    die "no session '${NAME}' in ${ns}"
fi
info "removing session ${NAME} from ${ns}"
k8s_kubectl -n "$ns" delete statefulset,deployment,service,networkpolicy -l "$sel" --wait=true >&2
for pvc in $(k8s_kubectl -n "$ns" get pvc -l "$sel" -o name 2>/dev/null); do
    case "$pvc" in
        "persistentvolumeclaim/${NAME}-audit") ;;
        *) k8s_kubectl -n "$ns" delete "$pvc" --wait=false >&2 ;;
    esac
done
info "session ${NAME} removed; audit kept in volume claim ${NAME}-audit (namespace ${ns})"
