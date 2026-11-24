#!/usr/bin/env bash
# aidc git protect <repo>: shows what GitHub enforces on the repo's default branch and, only on
# the user's yes, turns the missing protections on (gitctl protect: a ruleset blocking force
# pushes and deletion, merge commits allowed). It never turns anything off.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -eq 1 ] || die "usage: aidc git protect <repo>"
gb_require
repo=$(gb_repo_arg "$1") || exit 1
gb_target
report=$(gb_exec gitctl protection "$repo" 2>&1 | aidc_printable || true)
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
report=$(gb_exec gitctl protect "$repo" 2>&1 | aidc_printable || true)
[ "$(printf '%s\n' "$report" | tail -n1)" = end ] || die "GitHub did not take it: $(printf '%s\n' "$report" | grep -v '^$' | tail -n1)"
printf '%s\n' "$report" | aidc_git_print_protection || info "some protections are still off (see above)"
