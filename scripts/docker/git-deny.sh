#!/usr/bin/env bash
# aidc git deny <id> [reason] (Docker): refuse a waiting session request; the session is told why.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
{ [ $# -ge 1 ] && [ $# -le 2 ]; } || die "usage: aidc git deny <id> [reason]"
printf '%s' "$1" | grep -Eq '^[0-9a-f]{32}$' || die "${1}: not a request id"
dk_git_target
dk_git_exec git-requests deny "$1" "${2:-}" 2>&1 | aidc_printable
