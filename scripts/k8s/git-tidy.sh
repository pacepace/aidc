#!/usr/bin/env bash
# aidc git tidy [<repo>]: after merges, the git container deletes merged branches (on GitHub and
# in the working copy) and their clean worktrees, and lists every leftover (unmerged, unpushed,
# uncommitted, orphaned worktree folders) without deleting it. With no repo, every GitHub
# working copy on the disk (aidc repo list).

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -le 1 ] || die "usage: aidc git tidy [<repo>]"
k8s_require || exit 1
if [ $# = 1 ]; then repos=$(k8s_git_repo_arg "$1")
else
    repos=$(bash "$AIDC_SCRIPTS/k8s/repo-list.sh" | tail -n +2 | awk '{ print $1 }') || exit 1
    [ -n "$repos" ] || { info "no repos to tidy"; exit 0; }
fi
k8s_git_target
rc=0
while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    k8s_repo_path_ok "$repo" || { info "skipping ${repo}: not a plain path"; continue; }
    printf '== %s\n' "$repo"
    out=$(k8s_git_exec gitctl tidy "$repo" 2>&1 | k8s_printable || true)
    if [ "$(printf '%s\n' "$out" | tail -n1)" != end ]; then
        printf 'tidy did not finish: %s\n' "$(printf '%s\n' "$out" | tail -n1)"; rc=1; continue
    fi
    printf '%s\n' "$out" | k8s_git_print_tidy
done <<<"$repos"
exit "$rc"
