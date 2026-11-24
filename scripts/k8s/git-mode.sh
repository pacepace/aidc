#!/usr/bin/env bash
# aidc git mode [<session> <rules|ask|default>]: the user's git mode and the sessions given
# their own. A session given rules runs its requests at once while the user's mode is ask. The
# git container keeps the session's name with the SHA-256 of its token (AIDC_GIT_TOKEN, made by
# aidc create and readable only in that session's pod and from here), and the mode applies only
# to requests carrying that token: another session cannot take it by using the name.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
k8s_require || exit 1
if [ $# = 0 ]; then
    k8s_git_target
    k8s_git_exec git-requests modes | k8s_printable
    exit
fi
[ $# = 2 ] || die "usage: aidc git mode [<session> <rules|ask|default>]"
NAME="$1" MODE="$2"
validate_session_name "$NAME"
! k8s_is_git_session "$NAME" || die "the git agent sends no requests; its mode is the user's (kubernetes.git_mode)"
case "$MODE" in rules|ask|default) ;; *) die "${MODE}: not rules, ask or default" ;; esac
k8s_git_target
if [ "$MODE" = rules ]; then
    k8s_require_session "$GIT_NS" "$NAME"
    token=$(k8s_kubectl -n "$GIT_NS" get statefulset "${NAME}-dev" \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="dev")].env[?(@.name=="AIDC_GIT_TOKEN")].value}') \
        || die "cannot read session '${NAME}': the cluster did not answer"
    printf '%s' "$token" | grep -Eq '^[0-9a-f]{64}$' \
        || die "session '${NAME}' was created before sessions had their own git mode: create it again (aidc kill ${NAME}; aidc create ${NAME})"
    printf '%s\n' "$token" | k8s_kubectl -n "$GIT_NS" exec -i "$GIT_POD" -c git -- git-requests mode "$NAME" rules 2>&1 | k8s_printable
    exit "${PIPESTATUS[1]}"
fi
k8s_git_exec git-requests mode "$NAME" "$MODE" 2>&1 | k8s_printable
exit "${PIPESTATUS[0]}"
