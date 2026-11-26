#!/usr/bin/env bash
# aidc git requests [<id>]: the sessions' push and pull request requests waiting for the user's
# approval (git mode ask), or one of them: aidc git approve <id> or aidc git deny <id>.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -le 1 ] || die "usage: aidc git requests [<id>]"
if [ $# = 1 ]; then printf '%s' "$1" | grep -Eq '^[0-9a-f]{32}$' || die "${1}: not a request id"; fi
gb_require
gb_target
if [ $# = 1 ]; then
    gb_exec_req git-requests show "$1" 2>&1 | aidc_printable
else
    gb_exec_req git-requests list 2>&1 | aidc_printable
fi
exit "${PIPESTATUS[0]}"
