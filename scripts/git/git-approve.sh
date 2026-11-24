#!/usr/bin/env bash
# aidc git approve <id>: the git container runs a waiting session request (by gitctl's rules)
# and the session gets its result.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -eq 1 ] || die "usage: aidc git approve <id>"
printf '%s' "$1" | grep -Eq '^[0-9a-f]{32}$' || die "${1}: not a request id"
gb_require
gb_target
gb_exec git-requests approve "$1" 2>&1 | aidc_printable
exit "${PIPESTATUS[0]}"
