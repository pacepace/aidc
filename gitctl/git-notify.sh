#!/usr/bin/env bash
# git-notify <id>: hand a waiting request to the git agent's Claude (AIDC_GIT_NOTIFY, run by the
# request watcher in ask mode). Types one line into its tmux window, naming only the request's
# id: nothing a session wrote is typed in. The agent then reads the request with
# `git-requests prompt <id>`, which marks the session's text as data, and asks the user.
#
# Exit 1 when Claude is not running in window "claude" (the window shows a shell, or there is no
# such window: the line would be run by the shell), or is not set up yet (no key of any kind,
# first-run screens not done): nothing is typed. The request stays in `git-requests list` for the
# user and for the agent's next look.
set -u
id="${1:-}"
[[ "$id" =~ ^[0-9a-f]{32}$ ]] || { echo "git-notify: not a request id" >&2; exit 2; }
# Not before the user has set Claude up (its first-run screens and login, in `aidc git attach`):
# a line pasted there would answer one of those screens. Claude has a key by any of the ways it
# takes one: a login (the credentials file), a token or an API key in the environment, or an
# apiKeyHelper in the git home's Claude settings.
h="${HOME:-/home/git}"
[ -s "$h/.claude/.credentials.json" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] \
    || [ -n "$(jq -r '.apiKeyHelper // empty | strings' "$h/.claude/settings.json" 2>/dev/null)" ] || exit 1
[ "$(jq -r '.hasCompletedOnboarding // false' "$h/.claude.json" 2>/dev/null)" = true ] || exit 1
cmd=$(tmux display-message -p -t main:claude '#{pane_current_command}' 2>/dev/null) || exit 1
case "$cmd" in ""|bash|sh|dash|zsh|login) exit 1 ;; esac
line="git request ${id} waits for the user's decision: run git-requests prompt ${id} and follow it."
# Pasted, then Enter on its own, as aidc's MCP sends a prompt: typed keys could be read as
# shortcuts while Claude draws.
printf '%s' "$line" | tmux load-buffer -b aidc-git-notify - || exit 1
tmux paste-buffer -d -b aidc-git-notify -t main:claude || exit 1
sleep 0.5
tmux send-keys -t main:claude Enter
