#!/usr/bin/env bash
# aidc status <name> (a Kubernetes session): its pods, taint, repo, egress and audit.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) printf 'aidc status <name>\n'; exit 0 ;; esac
NAME="${1:-}"
validate_session_name "$NAME"
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
sts=$(k8s_kubectl -n "$ns" get statefulset "${NAME}-dev" -o json 2>/dev/null) \
    || die "no session '${NAME}' in ${ns}"
printf 'session:  %s (kubernetes, namespace %s)\n' "$NAME" "$ns"
printf 'repo:     %s\n' "$(printf '%s' "$sts" | yq -p=json '.metadata.annotations["aidc/repo"] // "?"')"
printf 'profile:  %s\n' "$(printf '%s' "$sts" | yq -p=json '.metadata.annotations["aidc/profile"] // "?"')"
printf 'pods:\n'
k8s_kubectl -n "$ns" get pods -l "aidc/session=${NAME}" \
    -o custom-columns='  NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,NODE:.spec.nodeName,STARTED:.status.startTime' 2>/dev/null
proxy=$(k8s_kubectl -n "$ns" get pod -l "aidc/session=${NAME},app=proxy" -o name 2>/dev/null | head -n1)
if [ -n "$proxy" ] && taint=$(k8s_kubectl -n "$ns" exec "$proxy" -c policy -- cat /var/state/tainted 2>/dev/null </dev/null); then
    printf 'taint:    TAINTED %s\n' "$taint"
elif [ -n "$proxy" ]; then
    printf 'taint:    clean\n'
else
    printf 'taint:    unknown (no proxy pod)\n'
fi
printf 'egress:   enforced: NetworkPolicy, dev pod -> its proxy only, proxy -> public addresses only; no DNS in the dev pod\n'
printf 'audit:    volume claim %s-audit in %s (kept by aidc kill)\n' "$NAME" "$ns"
