#!/usr/bin/env bash
# git-claude: the git agent's Claude Code, in window "claude" of the git container's tmux, as a
# session's Claude runs in its own (docs/design-12-kubernetes.md, "Git").
#
# Its instructions are the managed /etc/claude-code/CLAUDE.md and its permissions the managed
# settings beside it: only the git verbs, reads, its question tool and writes under /tmp run;
# anything else is refused without a prompt, so nothing waits on a permission no one sees
# unless the hook itself fails (then a call can wait, as waiting_on_permission). The default
# permission mode, not dontAsk: Claude Code refuses AskUserQuestion in dontAsk, whatever the
# settings or a hook allow. The managed PreToolUse hook (claude-hook.sh) refuses what the
# allow list does not allow, as dontAsk did. Unlike a sandboxed session's Claude it keeps its
# question tool (AskUserQuestion): in ask mode that is how it asks the user about a request,
# and aidc delivers a session's question to an orchestrator the same way. The plan-mode tools are off, as in sessions: nothing would approve
# a plan. It resumes its conversation when it has one, as aidc-claude does in a session.
#
# It runs in its own working folder, ~/work, not the home: Claude Code trusts a home folder for
# one run only ("This is your home folder, so Yes lasts for this session only", 2.1.332), so a
# Claude started in the home stopped at the trust prompt on every restart, with no one there to
# answer it (owner ruling 2026-11-27: unattended sessions never stop at first-launch screens).
# Every start marks that folder trusted and onboarding done in ~/.claude.json, merged into what
# is there (the login, the history, a person's choices stay); a file jq cannot read is left as
# it is. The conversation lives under that folder's project, as gitctl-main.sh mirrors it.
set -u
h="${HOME:-/home/git}"
work="${h}/work"
mkdir -p -- "$work" && cd -- "$work" || exit 1
# claude_state_ready: ~/.claude.json with this folder trusted and the first-launch screens done
# (onboarding, the text style, the folder's own onboarding; an API key in the environment
# approved, as a person at the prompt would, unless a person refused it). Replaced whole by a
# rename, so Claude never reads half a file.
claude_state_ready() {
    local f="${h}/.claude.json" cur tmp key=""
    cur='{}'
    if [ -e "$f" ]; then
        cur=$(jq -c 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null) || return 0
    fi
    [ -n "${ANTHROPIC_API_KEY:-}" ] && key="${ANTHROPIC_API_KEY: -20}"
    tmp=$(mktemp "${f}.XXXXXX") || return 0
    if printf '%s' "$cur" | jq --arg dir "$work" --arg key "$key" '
            .hasCompletedOnboarding = true
            | .theme = (.theme // "dark")
            | .projects = (if (.projects | type) == "object" then .projects else {} end)
            | .projects[$dir] = ((if (.projects[$dir] | type) == "object" then .projects[$dir] else {} end)
                + {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true})
            | .projects[$dir].projectOnboardingSeenCount = ((.projects[$dir].projectOnboardingSeenCount // 0) | if . < 1 then 1 else . end)
            | if $key == "" then . else
                .customApiKeyResponses = ((.customApiKeyResponses // {}) | .approved = (.approved // []) | .rejected = (.rejected // []))
                | if (.customApiKeyResponses.rejected | index($key)) or (.customApiKeyResponses.approved | index($key)) then .
                  else .customApiKeyResponses.approved += [$key] end
              end' > "$tmp" 2>/dev/null && chmod 0600 -- "$tmp" && mv -f -- "$tmp" "$f"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 0
}
claude_state_ready
args=(--disallowedTools EnterPlanMode --disallowedTools ExitPlanMode --permission-mode default)
# Claude Code's project folder for this directory, and whether it holds a conversation (a
# message, not only a transcript file): the same tests as the dev image's
# aidc_claude_project_name and aidc_has_resumable_conversation.
proj="${h}/.claude/projects/$(printf '%s' "$PWD" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g')"
if compgen -G "${proj}/*.jsonl" >/dev/null && grep -qsE '"type":"(user|assistant)"' "${proj}"/*.jsonl; then
    args+=(--continue)
fi
exec "${h}/.local/bin/claude" "$@" "${args[@]}"
