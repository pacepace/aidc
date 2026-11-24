#!/usr/bin/env bash
# The git container's GIT_EDITOR and GH_EDITOR. It never opens an editor (one would run a
# program as gitrun or gitcred on a terminal the agent can type into); it checks the message
# git or gh hands it and fails on AI attribution, which aborts the commit. git's repo hooks are
# off by design (core.hooksPath=/dev/null), so this is the commit-msg check.
set -u
self=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=gitctl-rules.sh
. "$(dirname "$self")/gitctl-rules.sh"

f="${1:-}"
[ -n "$f" ] && [ -r "$f" ] || exit 0
if [ "${AIDC_GITCTL_MSG_MODE:-git}" = gh ]; then
    text=$(cat -- "$f")
else
    # What git keeps: no comment lines, nothing below the scissors line of --verbose.
    text=$(sed -e '/^# -\{24\} >8 -\{24\}$/,$d' -e '/^#/d' -- "$f")
fi
if ! gitctl_check_text "$text" "the message"; then
    printf 'aidc gitctl: refused: %s\n' "$GITCTL_REASON" >&2
    exit 1
fi
exit 0
