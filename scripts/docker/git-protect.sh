#!/usr/bin/env bash
# aidc git protect <repo> (Docker): shows what GitHub enforces on the repo's default branch and,
# only on the user's yes, turns the missing protections on (gitctl protect). Never turns any off.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 1 ] || die "usage: aidc git protect <repo>"
repo=$(dk_git_repo_arg "$1")
dk_git_target
report=$(dk_git_exec gitctl protection "$repo" 2>&1 | aidc_printable || true)
[ "$(printf '%s\n' "$report" | tail -n1)" = end ] || die "cannot read the protections: $(printf '%s\n' "$report" | tail -n1)"
if printf '%s\n' "$report" | aidc_git_print_protection; then
    info "nothing to turn on"; exit 0
fi
printf 'Turn on: a ruleset blocking force pushes and deletion of the default branch, main, master\nand develop, and merge commits where they are off? Nothing is turned off. [y/N] ' >&2
ans=""
read -r ans || true
case "$ans" in
    y|Y|yes|YES|Yes) ;;
    *) info "left as it is"; exit 0 ;;
esac
report=$(dk_git_exec gitctl protect "$repo" 2>&1 | aidc_printable || true)
[ "$(printf '%s\n' "$report" | tail -n1)" = end ] || die "GitHub did not take it: $(printf '%s\n' "$report" | grep -v '^$' | tail -n1)"
printf '%s\n' "$report" | aidc_git_print_protection || info "some protections are still off (see above)"
