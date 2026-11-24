#!/usr/bin/env bash
# Claude Code's PreToolUse hook in the git container, set in the read-only managed settings
# (/etc/claude-code/managed-settings.json), which no user, project or local setting can turn
# off. A courtesy, not the enforcement: the agent holds no credential, and gitctl, the only way
# to the GitHub login, checks everything itself. The hook stops early what would fail or break
# a rule anyway: switching user, reading the login's home, changing the guard files, a gh login
# in the agent's own home, and attribution in a git or gitctl command.
#
# Exit 2 blocks the tool call, with the reason on stderr. Input it cannot read is blocked too.
set -u
self=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=gitctl-rules.sh
. "$(dirname "$self")/gitctl-rules.sh"

block() { printf 'aidc gitctl: refused: %s\n' "$1" >&2; exit 2; }

input=$(cat)
command -v jq >/dev/null 2>&1 || block "the hook cannot read the tool call (no jq)"
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || block "the hook cannot read the tool call"
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || block "the hook cannot read the tool call"
if [ -n "$cmd" ]; then
    gitctl_hook_command "$cmd" || block "$GITCTL_REASON"
fi
case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
        path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
        [ -z "$path" ] || gitctl_hook_path "$path" || block "$GITCTL_REASON" ;;
esac
exit 0
