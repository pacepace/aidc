#!/usr/bin/env bash
# aidc git requests [<id>] (Docker): the sessions' requests waiting for the user's approval (git
# mode ask), or one of them: aidc git approve <id> or aidc git deny <id>.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
dk_git_target
if [ $# = 1 ]; then
    printf '%s' "$1" | grep -Eq '^[0-9a-f]{32}$' || die "${1}: not a request id"
    dk_git_exec git-requests show "$1" | aidc_printable
else
    [ $# = 0 ] || die "usage: aidc git requests [<id>]"
    dk_git_exec git-requests list | aidc_printable
fi
