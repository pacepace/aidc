#!/usr/bin/env bash
# aidc git merge <repo> <pr-number>: the git container merges the pull request, always with a
# merge commit (gitctl pr-merge, after checking its texts and commits, bound to the head it
# checked), then tidies the working copy (gitctl tidy) and lists what is left for the user.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -eq 2 ] || die "usage: aidc git merge <repo> <pr-number>"
printf '%s' "$2" | grep -Eq '^[1-9][0-9]{0,9}$' || die "${2}: not a pull request number"
gb_require
repo=$(gb_repo_arg "$1") || exit 1
gb_target
gb_exec gitctl pr-merge "$repo" "$2" | aidc_printable || die "the git container did not merge pull request ${2}"
info "merged pull request ${2}; tidying ${repo}"
out=$(gb_exec gitctl tidy "$repo" 2>&1 | aidc_printable || true)
[ "$(printf '%s\n' "$out" | tail -n1)" = end ] || die "tidy did not finish: $(printf '%s\n' "$out" | tail -n1)"
printf '%s\n' "$out" | aidc_git_print_tidy
