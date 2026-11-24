#!/usr/bin/env bash
# aidc git mode [<session> <rules|ask|default>]: the user's git mode and the sessions given their
# own, both ways (owner ruling 2026-11-23): rules for one session while the user's mode is ask,
# ask for one session while it is rules, default to give it the user's again. The git container
# keys every mode decision on the session's token (AIDC_GIT_TOKEN, made by aidc create, readable
# only in that session's container or pod and from here): it keeps the session's name with the
# token's SHA-256, and a request without that token is always ask (gitctl/git-requests.sh).

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
gb_require
if [ $# = 0 ]; then
    gb_target
    gb_exec git-requests modes 2>&1 | aidc_printable
    exit "${PIPESTATUS[0]}"
fi
[ $# = 2 ] || die "usage: aidc git mode [<session> <rules|ask|default>]"
NAME="$1" MODE="$2"
validate_session_name "$NAME"
! aidc_is_git_session "$NAME" || die "the git agent sends no requests; its mode is the user's"
case "$MODE" in rules|ask|default) ;; *) die "${MODE}: not rules, ask or default" ;; esac
gb_target
token=$(gb_session_token "$NAME") || exit 1
printf '%s\n' "$token" | gb_exec_in git-requests mode "$NAME" "$MODE" 2>&1 | aidc_printable
exit "${PIPESTATUS[1]}"
