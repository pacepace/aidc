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
# a plan. It resumes its conversation when it has one, as aidc-claude does in a session. The
# hook allows explicitly each call it has checked, reads outside its working folder too
# (Claude's own prompts would wait with no one there). No --add-dir: Claude Code 2.1.332 asks
# about a folder added that way that it has not worked in ("Adding a new directory"), and that
# prompt stopped the agent before it started, with no one there to answer it.
#
# It runs in its own working folder, ~/work, not the home: Claude Code trusts a home folder for
# one run only ("This is your home folder, so Yes lasts for this session only", 2.1.332), so a
# Claude started in the home stopped at the trust prompt on every restart, with no one there to
# answer it (owner ruling 2026-11-27, the git agent trusts its own work folder on both
# backends). Every start marks that folder trusted and onboarding done in ~/.claude.json,
# merged into what is there (the login, the history, a person's choices stay), by the sessions'
# own writer of those keys, lib/claude-state.sh, which the image carries beside this script. A
# file that cannot be merged is left as it is, and one line on stderr says which step failed.
# The conversation lives under that folder's project, as gitctl-main.sh mirrors it.
set -u
h="${HOME:-/home/git}"
work="${h}/work"
mkdir -p -- "$work" && cd -- "$work" || exit 1
# The shared helper: beside this script in the image (aidc_build_context stages it there), in
# scripts/lib/ in the source tree.
here=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
state_lib="${here}/claude-state.sh"
[ -r "$state_lib" ] || state_lib="${here}/../scripts/lib/claude-state.sh"
# claude_state_ready: ~/.claude.json with this folder trusted and onboarding done, replaced
# whole by a rename, so Claude never reads half a file. Never fatal: Claude starts either way.
claude_state_ready() {
    local f="${h}/.claude.json" tmp=""
    _state_failed() {
        printf 'git-claude: %s left as it was: %s failed (Claude may stop at its trust prompt)\n' \
            "$f" "$1" >&2
        [ -z "$tmp" ] || rm -f -- "$tmp"
        return 0
    }
    # shellcheck source=/dev/null
    if ! { . "$state_lib" 2>/dev/null && command -v aidc_claude_state_ready >/dev/null; }; then
        _state_failed "loading ${state_lib}"; return 0
    fi
    if [ -e "$f" ]; then
        jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { _state_failed "reading it as a JSON object"; return 0; }
    fi
    tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || { tmp=""; _state_failed "making a temporary file beside it"; return 0; }
    if [ -e "$f" ]; then
        aidc_claude_state_ready "$work" < "$f" > "$tmp" 2>/dev/null
    else
        printf '{}' | aidc_claude_state_ready "$work" > "$tmp" 2>/dev/null
    fi || { _state_failed "marking ${work} trusted and onboarding done"; return 0; }
    chmod 0600 -- "$tmp" || { _state_failed "setting its mode"; return 0; }
    mv -f -- "$tmp" "$f" || { _state_failed "replacing it"; return 0; }
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
