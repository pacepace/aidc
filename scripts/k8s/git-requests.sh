#!/usr/bin/env bash
# aidc git requests: the sessions' push and pull request requests waiting for the user's
# approval (git mode ask): aidc git approve <id> or aidc git deny <id>.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
k8s_require || exit 1
k8s_git_target
if [ $# = 1 ]; then
    printf '%s' "$1" | grep -Eq '^[0-9a-f]{32}$' || die "${1}: not a request id"
    k8s_git_exec git-requests show "$1" | k8s_printable
else
    [ $# = 0 ] || die "usage: aidc git requests [<id>]"
    k8s_git_exec git-requests list | k8s_printable
fi
