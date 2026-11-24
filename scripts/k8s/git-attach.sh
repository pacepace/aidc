#!/usr/bin/env bash
# aidc git attach: the git agent's tmux (its Claude, and a shell beside it), where the user logs
# in to Claude and GitHub themselves (`gitctl login`, which runs gh as gitcred, the login's only
# reader) and answers the agent's questions. A shortcut for `aidc attach git`: the git agent is
# an aidc session under a reserved name.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc git attach takes no arguments (got: $*)"
k8s_require || exit 1
k8s_git_attach
