#!/usr/bin/env bash
# aidc git mode [<session> <rules|ask|default>] (Docker): the user's git mode (git.mode) and the
# sessions given their own. A session given rules runs its requests at once while the user's
# mode is ask. The git container keeps the session's name with the SHA-256 of its token
# (AIDC_GIT_TOKEN, made by aidc create, in that session's dev container only, read here from
# docker), and the mode applies only to requests carrying that token.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
dk_git_target
if [ $# = 0 ]; then
    dk_git_exec git-requests modes | aidc_printable
    exit "${PIPESTATUS[0]}"
fi
[ $# = 2 ] || die "usage: aidc git mode [<session> <rules|ask|default>]"
NAME="$1" MODE="$2"
validate_session_name "$NAME"
[ "$NAME" != "$DK_GIT_SESSION" ] || die "the git agent sends no requests; its mode is the user's (git.mode)"
case "$MODE" in rules|ask|default) ;; *) die "${MODE}: not rules, ask or default" ;; esac
if [ "$MODE" = rules ]; then
    session_exists "$NAME" || die "no session '${NAME}'"
    token=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(container_name "$NAME" dev)" 2>/dev/null \
        | sed -n 's/^AIDC_GIT_TOKEN=//p' | head -n1) || true
    printf '%s' "$token" | grep -Eq '^[0-9a-f]{64}$' \
        || die "session '${NAME}' was created before sessions had their own git mode: create it again (aidc kill ${NAME}; aidc create ${NAME})"
    printf '%s\n' "$token" | dk_git_exec_in git-requests mode "$NAME" rules 2>&1 | aidc_printable
    exit "${PIPESTATUS[1]}"
fi
dk_git_exec git-requests mode "$NAME" "$MODE" 2>&1 | aidc_printable
exit "${PIPESTATUS[0]}"
