#!/usr/bin/env bash
# aidc git tidy [<repo>]: after merges, the git container deletes merged branches (on GitHub and
# in the working copy) and their clean worktrees, and lists every leftover (unmerged, unpushed,
# uncommitted, orphaned worktree folders) without deleting it. With no repo, every working copy
# it works on (aidc repo list); one whose path is not a plain one is skipped, said so.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -le 1 ] || die "usage: aidc git tidy [<repo>]"
gb_require
if [ $# = 1 ]; then repos=$(gb_repo_arg "$1") || exit 1
else
    repos=$(gb_repos) || exit 1
    [ -n "$repos" ] || { info "no repos to tidy (aidc repo add)"; exit 0; }
fi
gb_target
rc=0
while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    gb_repo_ok "$repo" || { info "skipping ${repo}: not a plain path"; continue; }
    printf '== %s\n' "$repo"
    out=$(gb_exec gitctl tidy "$repo" 2>&1 | aidc_printable || true)
    if [ "$(printf '%s\n' "$out" | tail -n1)" != end ]; then
        printf 'tidy did not finish: %s\n' "$(printf '%s\n' "$out" | tail -n1)"; rc=1; continue
    fi
    printf '%s\n' "$out" | aidc_git_print_tidy
done <<<"$repos"
exit "$rc"
