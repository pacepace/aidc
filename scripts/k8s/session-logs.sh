#!/usr/bin/env bash
# aidc logs <name> [--component dev|squid|refresher|policy|audit] [--follow] (a Kubernetes
# session): the component's log, as `aidc logs` shows it on Docker.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
NAME="" COMPONENT="dev" FOLLOW=()
while [ $# -gt 0 ]; do
    case "$1" in
        --component) COMPONENT="${2:-}"; shift 2 ;;
        --component=*) COMPONENT="${1#--component=}"; shift ;;
        --follow|-f) FOLLOW=(-f); shift ;;
        -h|--help) printf 'aidc logs <name> [--component dev|squid|refresher|policy|audit] [--follow]\n'; exit 0 ;;
        --*) die "unknown flag: $1" ;;
        *) [ -z "$NAME" ] || die "unexpected positional argument: $1"; NAME="$1"; shift ;;
    esac
done
validate_session_name "$NAME"
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
if k8s_is_git_session "$NAME"; then
    # The git agent: its container's log, or the request holder's (gitreq: the request
    # watcher's errors; it keeps its own record of requests, git-requests).
    case "$COMPONENT" in dev|git) c=git ;; gitreq) c=gitreq ;; *) die "the git agent's components: git, gitreq" ;; esac
    k8s_kubectl -n "$ns" logs ${FOLLOW[@]+"${FOLLOW[@]}"} deployment/git -c "$c"
    exit
fi
case "$COMPONENT" in
    dev) target="statefulset/${NAME}-dev" ;;
    squid|refresher|policy|audit) target="deployment/${NAME}-proxy" ;;
    *) die "unknown component: ${COMPONENT} (dev, squid, refresher, policy or audit)" ;;
esac
k8s_kubectl -n "$ns" logs ${FOLLOW[@]+"${FOLLOW[@]}"} "$target" -c "$COMPONENT"
