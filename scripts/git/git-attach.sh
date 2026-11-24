#!/usr/bin/env bash
# aidc git attach (also aidc attach git): the git agent's tmux (its Claude in window claude, a
# shell beside it), as the git user, where the user logs in to Claude and answers the agent's
# questions. The git agent is an aidc session under a reserved name.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -eq 0 ] || die "aidc git attach takes no arguments (got: $*)"
gb_require
gb_target
gb_exec_tty tmux attach -d -t main
