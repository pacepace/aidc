#!/usr/bin/env bash
# aidc git logout: the git container's GitHub login and commit identity are removed.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc git logout takes no arguments (got: $*)"
k8s_require || exit 1
k8s_git_target
k8s_git_exec gitctl logout
