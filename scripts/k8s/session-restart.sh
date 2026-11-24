#!/usr/bin/env bash
# aidc restart <name> (a Kubernetes session): a new dev pod on the same image.
#
# The Docker verb restarts the dev container in place; a pod cannot be restarted in place, so
# its StatefulSet makes a new one. Everything that matters outlives it as on Docker: the session
# home (Claude's conversation and login, shell history) and the user's disk are claims, and the
# proxy pod (squid, the taint flag, the audit trail) is not touched. Claude starts again with
# --continue when the home holds a conversation (AIDC_CLAUDE_RESUME), so it picks up where it
# was. What ran only in the old pod (a process started by hand, its inner Docker's containers)
# is gone, as after a Docker restart.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in
    -h|--help)
        cat <<'USAGE'
aidc restart <name>

Gives the session a new dev pod on the same image; the proxy pod keeps running. The
session home and your disk are kept, so Claude resumes its conversation (--continue).
Use 'aidc upgrade <name>' to move it onto this aidc version's image instead.
USAGE
        exit 0 ;;
esac
NAME="${1:-}"
[ $# -le 1 ] || die "aidc restart takes one session name"
validate_session_name "$NAME"
k8s_require || exit 1
k8s_is_git_session "$NAME" \
    && die "git is your git agent (the git container), not a session aidc restart manages: aidc git setup starts or updates it"
ns=$(k8s_user_ns "$AIDC_K8S_USER")
k8s_require_session "$ns" "$NAME"
# The old pod's uid tells the new pod from it (the old one keeps its name and its ready line
# while it terminates): a read that fails stops here, before anything changes.
old=$(k8s_dev_pod_uid "$ns" "$NAME") \
    || die "cannot read ${NAME}'s dev pod in ${ns}: the cluster did not answer (${old}); nothing changed"
info "restarting ${NAME}'s dev pod (the proxy keeps running)"
k8s_kubectl -n "$ns" delete pod "${NAME}-dev-0" --ignore-not-found --wait=false >/dev/null \
    || die "the cluster did not take the restart; nothing changed"
k8s_wait_dev_ready "$ns" "$NAME" "$old" "${AIDC_K8S_READY_WAIT:-600}" || exit 1
info "session ${NAME} is back; Claude resumes its conversation when the session home holds one"
info "attach with: aidc attach ${NAME}"
