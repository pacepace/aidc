#!/usr/bin/env bash
# aidc git attach (Docker): the git agent's tmux (its Claude in window claude, a shell beside
# it), as the git user, where the user logs in to Claude and answers the agent's questions. The
# same as `aidc attach git`: the git agent is an aidc session under a reserved name.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc git attach takes no arguments (got: $*)"
dk_git_target
exec docker exec -it -u git -e "TERM=${TERM:-xterm-256color}" "$DK_GIT_CT" tmux attach -d -t main
