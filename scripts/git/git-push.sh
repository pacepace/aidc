#!/usr/bin/env bash
# aidc git push <repo> <branch>: the git container pushes a branch of a working copy the user
# added (gitctl push: fast-forward only, never main/master/develop or origin's default branch,
# attribution refused). The user running the command is the approval. The first push to a repo
# also reports GitHub's protections of it (aidc git protect turns missing ones on).

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -eq 2 ] || die "usage: aidc git push <repo> <branch>"
gb_require
repo=$(gb_repo_arg "$1") || exit 1
branch="$2"
gb_target
gb_exec gitctl push "$repo" "$branch" | aidc_printable || die "the git container did not push ${branch}"
report=$(gb_exec git-requests first-use "$repo" 2>/dev/null | aidc_printable || true)
if [ -n "$report" ] && ! printf '%s\n' "$report" | aidc_git_print_protection; then
    info "this repo is missing protections; turn them on with: aidc git protect ${1}"
fi
