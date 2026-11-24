#!/usr/bin/env bash
# aidc git log [<lines>]: what the git container changed on GitHub, from the action logs gitrun
# and gitcred keep where its agent cannot change them (gitctl log): time, verb, repo, branch or
# pull request, commit, who asked (a request id or direct) and the calling user.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -le 1 ] || die "usage: aidc git log [<lines>]"
n="${1:-100}"
printf '%s' "$n" | grep -Eq '^[1-9][0-9]{0,5}$' || die "${n}: not a number of lines"
gb_require
gb_target
gb_exec gitctl log "$n" 2>&1 | aidc_printable
exit "${PIPESTATUS[0]}"
