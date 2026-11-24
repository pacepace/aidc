#!/usr/bin/env bash
# aidc git approve <id>: the git container runs a waiting session request (by gitctl's rules)
# and the session gets its result.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 1 ] || die "usage: aidc git approve <id>"
printf '%s' "$1" | grep -Eq '^[0-9a-f]{32}$' || die "${1}: not a request id"
k8s_require || exit 1
k8s_git_target
k8s_git_exec git-requests approve "$1" 2>&1 | k8s_printable
