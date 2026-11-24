#!/usr/bin/env bash
# git-claude: the git agent's Claude Code, in window "claude" of the git container's tmux, as a
# session's Claude runs in its own (docs/design-12-kubernetes.md, "Git").
#
# Its instructions are the managed /etc/claude-code/CLAUDE.md and its permissions the managed
# settings beside it (dontAsk: only the git verbs, reads and its question tool run; anything
# else is refused without a prompt, so nothing waits on a permission no one sees). Unlike a
# sandboxed session's Claude it keeps its question tool (AskUserQuestion): in ask mode that is
# how it asks the user about a request, and aidc delivers a session's question to an
# orchestrator the same way. The plan-mode tools are off, as in sessions: nothing would approve
# a plan. It resumes its conversation when it has one, as aidc-claude does in a session.
set -u
cd "${HOME:-/home/git}" || exit 1
args=(--disallowedTools EnterPlanMode --disallowedTools ExitPlanMode --permission-mode dontAsk)
# Claude Code's project folder for this directory, and whether it holds a conversation (a
# message, not only a transcript file): the same tests as the dev image's
# aidc_claude_project_name and aidc_has_resumable_conversation.
proj="${HOME:-/home/git}/.claude/projects/$(printf '%s' "$PWD" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g')"
if compgen -G "${proj}/*.jsonl" >/dev/null && grep -qsE '"type":"(user|assistant)"' "${proj}"/*.jsonl; then
    args+=(--continue)
fi
exec "${HOME:-/home/git}/.local/bin/claude" "$@" "${args[@]}"
