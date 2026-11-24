#!/usr/bin/env bash
# aidc git attach: the git container's tmux, where the user logs in to GitHub themselves
# (`gitctl login`, which runs gh as gitcred, the login's only reader). The container runs as
# the git user, so `kubectl exec` is already that user and reaches its tmux socket.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc git attach takes no arguments (got: $*)"
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
rc=0
pod=$(k8s_git_pod "$ns") || rc=$?
case "$rc" in
    0) ;;
    1) die "no running git container in ${ns}: run \`aidc git setup\`" ;;
    *) die "cannot reach the git container: the cluster did not answer: ${pod#unknown }" ;;
esac
k8s_kubectl -n "$ns" exec -it "$pod" -c git -- env TERM="${TERM:-xterm-256color}" tmux attach -d -t main
