#!/usr/bin/env bash
# aidc git push <repo> <branch>: the git container pushes a branch of a working copy on the
# user's disk (gitctl push: fast-forward only, never main/master/develop, attribution refused).
# The user running the command is the approval. The first push to a repo also reports GitHub's
# protections of it (aidc git protect turns missing ones on).

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 2 ] || die "usage: aidc git push <repo> <branch>"
k8s_require || exit 1
repo=$(k8s_git_repo_arg "$1"); branch="$2"
k8s_git_target
k8s_git_exec gitctl push "$repo" "$branch" | k8s_printable || die "the git container did not push ${branch}"
report=$(k8s_git_exec git-requests first-use "$repo" 2>/dev/null | k8s_printable || true)
if [ -n "$report" ] && ! printf '%s\n' "$report" | k8s_git_print_protection; then
    info "this repo is missing protections; turn them on with: aidc git protect ${1}"
fi
