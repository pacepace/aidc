#!/usr/bin/env bash
# aidc git deny <id> [reason]: refuse a waiting session request; the session is told why.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
{ [ $# -ge 1 ] && [ $# -le 2 ]; } || die "usage: aidc git deny <id> [reason]"
printf '%s' "$1" | grep -Eq '^[0-9a-f]{32}$' || die "${1}: not a request id"
gb_require
gb_target
gb_exec git-requests deny "$1" "${2:-}" 2>&1 | aidc_printable
exit "${PIPESTATUS[0]}"
