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
if k8s_is_git_session "$NAME"; then
    printf 'session:  %s (your git agent: the git container, kubernetes, namespace %s)\n' "$NAME" "$ns"
    AIDC_GIT_BACKEND=kubernetes exec bash "$AIDC_SCRIPTS/git/git-status.sh"
fi
k8s_require_session "$ns" "$NAME"
sts=$(k8s_kubectl -n "$ns" get statefulset "${NAME}-dev" -o json) \
    || die "cannot read session '${NAME}': the cluster did not answer"
printf 'session:  %s (kubernetes, namespace %s)\n' "$NAME" "$ns"
printf 'repo:     %s\n' "$(printf '%s' "$sts" | yq -p=json '.metadata.annotations["aidc/repo"] // "?"')"
printf 'profile:  %s\n' "$(printf '%s' "$sts" | yq -p=json '.metadata.annotations["aidc/profile"] // "?"')"
printf 'pods:\n'
k8s_kubectl -n "$ns" get pods -l "aidc/session=${NAME}" --request-timeout=10s \
    -o custom-columns='  NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,NODE:.spec.nodeName,STARTED:.status.startTime' 2>/dev/null \
    || printf '  unknown (the cluster did not answer)\n'
taint=$(k8s_session_taint "$ns" "$NAME")
case "$taint" in
    yes*) printf 'taint:    TAINTED %s\n' "${taint#yes }" ;;
    no) printf 'taint:    clean\n' ;;
    *) printf 'taint:    %s\n' "$taint" ;;
esac
# The lockdown is the session's NetworkPolicies: say so only when they are there, and "unknown"
# when the cluster cannot be asked (never NOT ENFORCED for a read that failed).
if have=$(k8s_kubectl -n "$ns" get networkpolicy -o name --request-timeout=10s 2>/dev/null); then
    have=$(printf '%s\n' "$have" | sed 's|.*/||' | sort | paste -sd' ' -)
    want="default-deny ${NAME}-dev-only-to-its-proxy ${NAME}-proxy-public-only"
    missing=""
    for p in $want; do case " $have " in *" $p "*) ;; *) missing="${missing} ${p}" ;; esac; done
    if [ -z "$missing" ]; then
        printf 'egress:   enforced: NetworkPolicy, dev pod -> its proxy only, proxy -> public addresses only; no DNS in the dev pod\n'
    else
        printf 'egress:   NOT ENFORCED: NetworkPolicy missing:%s\n' "$missing"
    fi
else
    printf 'egress:   unknown (the cluster did not answer)\n'
fi
audit=$(printf '%s' "$sts" | yq -p=json '.metadata.annotations["aidc/audit"] // ""')
printf 'audit:    volume claim %s in %s (kept by aidc kill)\n' "${audit:-?}" "$ns"
