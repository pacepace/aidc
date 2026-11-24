#!/usr/bin/env bash
# Claude Code's PreToolUse hook in the git container, set in the read-only managed settings
# (/etc/claude-code/managed-settings.json), which no user, project or local setting can turn
# off. It applies the wrappers' rules (gitctl-rules.sh) to every shell command Claude runs,
# before it runs, and also refuses what the wrappers cannot see: a real git or gh called by
# its path, a changed PATH or GIT_EXEC_PATH, sudo, and writes to the wrappers, the managed
# settings, the sudo rule or the token's home.
#
# Exit 2 blocks the tool call, with the reason on stderr. Anything it cannot read is blocked
# too: a hook that fails open is no rule.
set -u
self=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=gitctl-rules.sh
. "$(dirname "$self")/gitctl-rules.sh"

block() { printf 'aidc gitctl: refused: %s\n' "$1" >&2; exit 2; }

input=$(cat)
command -v jq >/dev/null 2>&1 || block "the hook cannot read the tool call (no jq)"
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || block "the hook cannot read the tool call"
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" 2>/dev/null || true; fi

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || block "the hook cannot read the tool call"
if [ -n "$cmd" ]; then
    gitctl_check_command_string "$cmd" || block "$GITCTL_REASON"
fi

case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
        path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
        [ -z "$path" ] || gitctl_check_path "$path" || block "$GITCTL_REASON"
        # A shell alias or script that calls the real binaries is the same bypass, written down.
        text=$(printf '%s' "$input" | jq -r '[.tool_input.content, .tool_input.new_string, (.tool_input.edits // [] | .[].new_string), .tool_input.new_source] | map(select(. != null)) | join("\n")' 2>/dev/null)
        stripped="${text//\/opt\/aidc\/bin\//}"
        if printf '%s' "$stripped" | grep -qE '(^|[^[:alnum:]_.-])(/usr)?/(local/)?bin/(git|gh)([^[:alnum:]_.-]|$)|git-core|/opt/aidc/lib'; then
            block "the text names a real git or gh binary; use plain git or gh"
        fi ;;
esac
exit 0
