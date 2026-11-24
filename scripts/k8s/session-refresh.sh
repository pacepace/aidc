#!/usr/bin/env bash
# aidc refresh <name> (a Kubernetes session): refresh the malware blocklist now, as on Docker:
# the refresher sidecar's one-shot refresh, which squid's lookup helper reads at once.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in
    -h|--help) printf 'aidc refresh <name>\n\nRe-pulls the malware feeds for the session now (the refresher sidecar).\n'; exit 0 ;;
esac
NAME="${1:-}"
[ $# -le 1 ] || die "aidc refresh takes one session name"
validate_session_name "$NAME"
k8s_require || exit 1
k8s_is_git_session "$NAME" && die "git is your git agent: it has no proxy and no blocklist to refresh"
ns=$(k8s_user_ns "$AIDC_K8S_USER")
k8s_require_session "$ns" "$NAME"
proxy=$(k8s_kubectl -n "$ns" get pod -l "aidc/session=${NAME},app=proxy" -o name --request-timeout=10s </dev/null) \
    || die "cannot find ${NAME}'s proxy pod: the cluster did not answer"
proxy=$(printf '%s\n' "$proxy" | head -n1)
[ -n "$proxy" ] || die "session ${NAME} has no proxy pod running"
k8s_kubectl -n "$ns" exec "$proxy" -c refresher -- /usr/local/bin/refresh.sh </dev/null
