#!/usr/bin/env bash
# aidc git push <repo> <branch> (Docker): the git container pushes a branch of a working copy
# the user added (gitctl push: fast-forward only, never main/master/develop or origin's default
# branch, attribution refused). The user running the command is the approval. The first push to
# a repo also reports GitHub's protections of it (aidc git protect turns missing ones on).

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 2 ] || die "usage: aidc git push <repo> <branch>"
repo=$(dk_git_repo_arg "$1"); branch="$2"
dk_git_target
dk_git_exec gitctl push "$repo" "$branch" | aidc_printable || die "the git container did not push ${branch}"
report=$(dk_git_exec git-requests first-use "$repo" 2>/dev/null | aidc_printable || true)
if [ -n "$report" ] && ! printf '%s\n' "$report" | aidc_git_print_protection; then
    info "this repo is missing protections; turn them on with: aidc git protect ${1}"
fi
