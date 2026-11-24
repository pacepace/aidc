#!/usr/bin/env bash
# aidc git tidy [<repo>] (Docker): after merges, the git container deletes merged branches (on
# GitHub and in the working copy) and their clean worktrees inside it, and lists every leftover
# without deleting it. With no repo, every working copy the user added.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -le 1 ] || die "usage: aidc git tidy [<repo>]"
if [ $# = 1 ]; then repos=$(dk_git_repo_arg "$1")
else
    repos=$(dk_git_repos)
    [ -n "$repos" ] || { info "no repos to tidy (aidc repo add <path>)"; exit 0; }
fi
dk_git_target
rc=0
while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    printf '== %s\n' "$repo"
    out=$(dk_git_exec gitctl tidy "$repo" 2>&1 | aidc_printable || true)
    if [ "$(printf '%s\n' "$out" | tail -n1)" != end ]; then
        printf 'tidy did not finish: %s\n' "$(printf '%s\n' "$out" | tail -n1)"; rc=1; continue
    fi
    printf '%s\n' "$out" | aidc_git_print_tidy
done <<<"$repos"
exit "$rc"
