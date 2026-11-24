#!/usr/bin/env bash
# aidc attach <name> (a Kubernetes session): the session's tmux, as the session user.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) printf 'aidc attach <name>\n\nAttaches to the session'"'"'s tmux in the cluster.\n'; exit 0 ;; esac
NAME="${1:-}"
validate_session_name "$NAME"
k8s_require || exit 1
# The git agent: its own pod and user (aidc git attach is the same).
if k8s_is_git_session "$NAME"; then k8s_git_attach; exit; fi
ns=$(k8s_user_ns "$AIDC_K8S_USER")
pod="${NAME}-dev-0"
k8s_require_session "$ns" "$NAME"
phase=$(k8s_kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}') \
    || die "cannot read session '${NAME}': the cluster did not answer"
[ "$phase" = "Running" ] || die "session '${NAME}' has no running dev pod (it is ${phase:-not there yet})"
# kubectl exec has no --user; sudo -u gives tmux the session user's socket, as `docker exec -u`.
k8s_kubectl -n "$ns" exec -it "$pod" -c dev -- sudo -u vscode -H env TERM="${TERM:-xterm-256color}" tmux attach -d -t main
