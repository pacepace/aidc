#!/usr/bin/env bash
# aidc git login (Docker): the git container's GitHub login, as the user: gh's device code,
# approved in the user's browser, kept where only gitcred can read it (the aidc-git-cred
# volume); then the identity its commits carry. Interactive.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc git login takes no arguments (got: $*)"
dk_git_target
info "logging the git container in to GitHub: copy the one-time code, open the address and approve it"
exec docker exec -it -u git -e "TERM=${TERM:-xterm-256color}" "$DK_GIT_CT" gitctl login
