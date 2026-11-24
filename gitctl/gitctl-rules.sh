#!/usr/bin/env bash
# shellcheck shell=bash
# The globals set here are read by gitctl and the hook (SC2034).
# shellcheck disable=SC2034
# The git container's hard rules (docs/design-12-kubernetes.md, "Git", K8S-24), shared by
# gitctl (the only way to the GitHub login) and Claude Code's PreToolUse hook.
#
# Every check returns 0 to allow or 1 to refuse, with the one-line reason in GITCTL_REASON.
# No function here calls a helper from another file: a missing one inside `check || die`
# would be swallowed and the refusal lost.

# Names that mark AI authorship, matched case-insensitively.
GITCTL_AI='claude|anthropic|openai|chatgpt|gpt-?[0-9]|copilot|gemini|codex|cursor|codeium|windsurf|tabnine|aider|devin|codewhisperer|cody|deepseek|mistral|llama|grok|qwen|\bai\b|\[bot\]'

gitctl_refuse() { GITCTL_REASON="$1"; return 1; }

# gitctl_attribution TEXT: 0, with the offending line in GITCTL_HIT, when TEXT carries AI
# attribution anywhere: a Co-Authored-By or Signed-off-by naming an AI, a "Generated with"
# (created, written, made...) followed by one, the robot emoji, or a Claude Code link. Anywhere
# on a line, not only at its start: `--body="Thanks. Co-Authored-By: Claude"` is still a
# trailer once GitHub renders it. Text that merely talks about Claude passes.
gitctl_attribution() {
    local text="$1"
    GITCTL_HIT=$(printf '%s\n' "$text" | LC_ALL=C grep -m1 -F "$(printf '\360\237\244\226')") && return 0
    GITCTL_HIT=$(printf '%s\n' "$text" | LC_ALL=C grep -m1 -iE \
        -e "co[- ]?authored[- ]?by[[:space:]]*:?.*(${GITCTL_AI})" \
        -e "signed[- ]?off[- ]?by[[:space:]]*:.*(${GITCTL_AI})" \
        -e "(generated|created|written|authored|made|produced)[[:space:]]+(with|by|using|via|in)[[:space:]]+[^[:alnum:]]*(${GITCTL_AI})" \
        -e 'claude\.(com|ai)/(claude-)?code') && return 0
    GITCTL_HIT=""
    return 1
}

gitctl_check_text() { # TEXT WHAT
    gitctl_attribution "$1" || return 0
    gitctl_refuse "$2 carries AI attribution (${GITCTL_HIT:0:120}); no attribution in commits, PRs or comments"
}

# An author or committer that is an AI tool or a bot.
gitctl_ai_identity() {
    printf '%s\n' "$1" | LC_ALL=C grep -qiE '@anthropic\.com|@openai\.com|copilot|\[bot\]'
}

# gitctl_slug_from_url URL: owner/name (in GITCTL_SLUG) of https://github.com/<owner>/<name>[.git].
# Nothing else: not http (the token would cross in the clear), not ssh, not another host, not a
# transport helper.
gitctl_slug_from_url() {
    local re='^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)$' name
    [[ "$1" =~ $re ]] || { gitctl_refuse "origin ${1} is not https://github.com/<owner>/<name>"; return 1; }
    name="${BASH_REMATCH[2]%.git}"
    case "$name" in ""|.|..) gitctl_refuse "origin ${1} names no repo"; return 1 ;; esac
    GITCTL_SLUG="${BASH_REMATCH[1]}/${name}"
}

gitctl_slug_ok() {
    if [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]] && [ "${1#*/}" != . ] && [ "${1#*/}" != .. ]; then
        return 0
    fi
    gitctl_refuse "${1}: not an owner/name"
}

gitctl_number_ok() {
    [[ "$1" =~ ^[1-9][0-9]{0,9}$ ]] || { gitctl_refuse "${1}: not a pull request number"; return 1; }
}

# gitctl_branch_ok GIT NAME: a branch name git accepts, that cannot be read as an option.
gitctl_branch_ok() {
    case "$2" in
        ""|-*|*:*|+*) gitctl_refuse "${2}: not a branch name"; return 1 ;;
    esac
    "$1" check-ref-format --branch "$2" >/dev/null 2>&1 || { gitctl_refuse "${2}: not a branch name"; return 1; }
}

# gitctl_repo_check PATH: the main checkout of a repo whose git config the caller cannot
# change. gitrun runs git there with the login's helper; a config the agent could write
# (core.pager, filters, aliases, includes) would be its code run as gitrun, and so the token.
# So .git and .git/config must belong to the user running this (gitrun) or root, be no
# symlinks, and be writable by neither group nor others, and the config may include no other
# file. Sets GITCTL_REPO to the resolved path.
gitctl_repo_check() {
    local r p owner mode me
    r=$(realpath -e -- "$1" 2>/dev/null) || { gitctl_refuse "${1}: no such folder"; return 1; }
    me=$(id -u)
    for p in "$r/.git" "$r/.git/config"; do
        if [ ! -e "$p" ] || [ -L "$p" ]; then
            gitctl_refuse "${r}: not the main checkout of a repo (${p})"; return 1
        fi
        owner=$(stat -c %u -- "$p"); mode=$(stat -c %a -- "$p")
        if [ "$owner" != "$me" ] && [ "$owner" != 0 ]; then
            gitctl_refuse "${p} belongs to uid ${owner}: only a repo the git container owns"; return 1
        fi
        if (( 8#$mode & 8#022 )); then
            gitctl_refuse "${p} is writable by its group or others: its config would run as the git container"; return 1
        fi
    done
    [ -d "$r/.git" ] || { gitctl_refuse "${r}: not the main checkout of a repo"; return 1; }
    if LC_ALL=C grep -qiE '^[[:space:]]*\[[[:space:]]*include' "$r/.git/config"; then
        gitctl_refuse "${r}/.git/config includes another file"; return 1
    fi
    GITCTL_REPO="$r"
}

# --- the PreToolUse hook: a courtesy, not the enforcement ----------------------------------

# gitctl_hook_command STRING: a Bash command Claude is about to run.
gitctl_hook_command() {
    local s="$1"
    GITCTL_REASON=""
    if printf '%s' "$s" | grep -qE '(^|[^[:alnum:]_./-])(sudo|su|doas|runuser|setpriv|pkexec)([^[:alnum:]_-]|$)'; then
        gitctl_refuse "switching user is refused; gitctl switches for its own verbs"; return 1
    fi
    if printf '%s' "$s" | grep -qE '/var/lib/gitctl|/etc/sudoers'; then
        gitctl_refuse "the command touches the GitHub login's home or the sudo rules"; return 1
    fi
    if printf '%s' "$s" | grep -qE '/etc/claude-code|/opt/aidc|/etc/gitconfig' \
        && printf '%s' "$s" | grep -qE '>|(^|[^[:alnum:]_-])(tee|cp|mv|rm|ln|chmod|chown|install|truncate|dd|sed[[:space:]]+-i|perl|python3?)([^[:alnum:]_-]|$)'; then
        gitctl_refuse "the command changes the git container's protected files"; return 1
    fi
    if printf '%s' "$s" | grep -qE '(^|[^[:alnum:]_-])gh([^[:alnum:]_-]|$).*auth.*login'; then
        gitctl_refuse "gh auth login here would keep the login where the agent can read it; the user runs: gitctl login"; return 1
    fi
    if printf '%s' "$s" | grep -qE '(^|[^[:alnum:]_-])(git|gitctl)([^[:alnum:]_-]|$)' && gitctl_attribution "$s"; then
        gitctl_refuse "the command carries AI attribution (${GITCTL_HIT:0:120}); no attribution in commits, PRs or comments"; return 1
    fi
    return 0
}

# gitctl_hook_path PATH: an Edit or Write target.
gitctl_hook_path() {
    local r
    r=$(realpath -m -- "$1" 2>/dev/null || printf '%s' "$1")
    case "$r" in
        /opt/aidc/*|/etc/claude-code/*|/etc/sudoers*|/etc/gitconfig|/var/lib/gitctl/*)
            gitctl_refuse "${1} is one of the git container's protected files"; return 1 ;;
    esac
    return 0
}
