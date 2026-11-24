#!/usr/bin/env bash
# aidc git merge <repo> <pr-number>: the git container merges the pull request, always with a
# merge commit (gitctl pr-merge, after checking its texts and commits), then tidies the working
# copy (gitctl tidy) and lists what is left for the user.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 2 ] || die "usage: aidc git merge <repo> <pr-number>"
printf '%s' "$2" | grep -Eq '^[1-9][0-9]{0,9}$' || die "${2}: not a pull request number"
k8s_require || exit 1
repo=$(k8s_git_repo_arg "$1")
k8s_git_target
k8s_git_exec gitctl pr-merge "$repo" "$2" | k8s_printable || die "the git container did not merge pull request ${2}"
info "merged pull request ${2}; tidying ${repo}"
out=$(k8s_git_exec gitctl tidy "$repo" 2>&1 | k8s_printable || true)
[ "$(printf '%s\n' "$out" | tail -n1)" = end ] || die "tidy did not finish: $(printf '%s\n' "$out" | tail -n1)"
printf '%s\n' "$out" | k8s_git_print_tidy
