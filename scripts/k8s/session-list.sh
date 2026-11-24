#!/usr/bin/env bash
# aidc list, Kubernetes part: the user's sessions in the configured cluster, with their taint.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
# A cluster that does not answer is not a cluster with no sessions.
rows=$(k8s_kubectl -n "$ns" get statefulset -l app=dev --request-timeout=10s \
    -o jsonpath='{range .items[*]}{.metadata.labels.aidc/session}{"\t"}{.status.readyReplicas}{"\t"}{.metadata.annotations.aidc/profile}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}') \
    || die "the cluster did not answer; its sessions are unknown (${ns})"
if [ -z "$rows" ]; then
    printf 'No aidc sessions in the cluster (%s).\n' "$ns"
    exit 0
fi
printf '%-20s %-15s %-10s %-25s %-9s %s\n' "SESSION" "STATUS" "PROFILE" "STARTED" "TAINTED" "BACKEND"
printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r s ready profile started; do
    [ -n "$s" ] || continue
    case "${ready:-0}" in 0|'') st="starting" ;; *) st="running" ;; esac
    printf '%-20s %-15s %-10s %-25s %-9s %s\n' "$s" "$st" "${profile:-?}" "$started" \
        "$(k8s_session_taint "$ns" "$s" | cut -d' ' -f1)" "kubernetes"
done
