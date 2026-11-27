#!/usr/bin/env bash
# Claude Code's PreToolUse hook in the git container, set in the read-only managed settings
# (/etc/claude-code/managed-settings.json), which no user, project or local setting can turn
# off. It runs before every tool call (matcher "*") and does two things.
#
# 1. The allow list. The git agent's Claude runs in the default permission mode, not dontAsk:
#    Claude Code 2.1.332 refuses AskUserQuestion in dontAsk whatever the settings or a hook say,
#    and the question is how ask mode reaches the user (docs/design-12-kubernetes.md, "Git").
#    So this hook refuses ("deny", with a reason) every call the managed settings'
#    permissions.allow would not allow, as dontAsk did, so while the hook runs nothing waits on
#    a permission prompt no one sees (when it fails, see below). A call the list allows gets no
#    decision and goes on to Claude's own permission check of that same list, so the hook
#    matches rules as Claude does. The list is read from the managed settings each time; this
#    hook keeps no copy of it.
# 2. The guard rules (gitctl-rules.sh), a courtesy, not the enforcement: the agent holds no
#    credential, and gitctl, the only way to the GitHub login, checks everything itself. They
#    stop early what would fail or break a rule anyway: switching user, reading the login's
#    home, changing the guard files, a gh login in the agent's own home, and attribution in a
#    git or gitctl command. Exit 2 blocks the call, with the reason on stderr.
#
# Input it cannot read is blocked (exit 2). If the hook itself fails (a crash, a timeout), Claude
# Code lets the call go on to its own permission check: a listed call runs, any other one asks,
# and the session shows waiting_on_permission. It never runs a call the list does not allow.
#
# Usage: claude-hook.sh [managed-settings.json] (tool call JSON on stdin). The settings path is
# for tests; the managed settings name none, so the agent's Claude always reads the image's.
set -u
self=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=gitctl-rules.sh
. "$(dirname "$self")/gitctl-rules.sh"
settings="${1:-/etc/claude-code/managed-settings.json}"

block() { printf 'aidc gitctl: refused: %s\n' "$1" >&2; exit 2; }
deny() {
    jq -n -c --arg r "aidc gitctl: not allowed for the git agent: $1" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

# Claude Code's tools that ask no permission: dontAsk let them run whatever the list said
# (code.claude.com/docs, "Tools available to Claude"), so they get no decision here either.
# AskUserQuestion is not one of them here: dontAsk refused it, and the list names it.
_NO_PERMISSION_TOOLS=" Agent Task Glob Grep LS Read NotebookRead TodoWrite ToolSearch TaskCreate TaskGet TaskList TaskUpdate TaskOutput TaskStop BashOutput KillShell ListMcpResourcesTool ReadMcpResourceTool LSP "

# _bash_segments CMD: CMD's simple commands, one a line (split at &&, ||, ;, |, & and newlines
# outside quotes, as Claude Code checks each part of a compound command on its own). Returns 1
# for a command it cannot judge part by part: a command or process substitution, quotes left
# open, bash's ANSI-C or locale quoting ($'...' or $"..."), or a comment. In $'...' a \' does
# not end the string, so git $'\'' ; rm -rf ~ ; git '\' is three commands to bash and would be
# one here; $"..." is refused with it rather than modelled. A # starting a word (outside quotes)
# starts a comment to the end of the line, where a quote opens nothing: git a #' <newline>
# git b ; rm -rf ~ ; git c #' is four commands to bash, one quoted string here.
_bash_segments() {
    local s="$1" i c n q="" cur="" prev=""
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}" n="${s:i+1:1}"
        if [ "$q" = "'" ]; then
            cur+="$c"; [ "$c" = "'" ] && q=""; prev="$c"; continue
        fi
        if [ "$c" = "\\" ]; then cur+="$c$n"; i=$((i + 1)); prev="$n"; continue; fi
        if [ "$c" = '`' ] || { [ "$c" = '$' ] && [ "$n" = '(' ]; }; then return 1; fi
        if [ "$q" = '"' ]; then
            cur+="$c"; [ "$c" = '"' ] && q=""; prev="$c"; continue
        fi
        case "$c" in
            "'"|'"') q="$c"; cur+="$c" ;;
            '$') case "$n" in "'"|'"') return 1 ;; esac; cur+="$c" ;;
            '#') case "${cur: -1}" in ''|[[:space:]]|'<'|'>'|'('|')') return 1 ;; esac; cur+="$c" ;;
            '<'|'>') [ "$n" = '(' ] && return 1; cur+="$c" ;;
            ';'|$'\n') printf '%s\n' "$cur"; cur="" ;;
            '|') printf '%s\n' "$cur"; cur=""; [ "$n" = '|' ] || [ "$n" = '&' ] && i=$((i + 1)) ;;
            '&')
                if [ "$prev" = '>' ] || [ "$prev" = '<' ] || [ "$n" = '>' ]; then cur+="$c"
                else printf '%s\n' "$cur"; cur=""; [ "$n" = '&' ] && i=$((i + 1)); fi ;;
            *) cur+="$c" ;;
        esac
        prev="$c"
    done
    [ -z "$q" ] || return 1
    printf '%s\n' "$cur"
}

# _bash_allowed CMD RULES: 0 when every part of CMD starts with a command a Bash(...) rule
# names: "Bash(git *)" allows "git" and "git <anything>", "Bash(x)" allows "x" only.
_bash_allowed() {
    local cmd="$1" rules="$2" segs seg r p ok any=0
    segs=$(_bash_segments "$cmd") || { GITCTL_REASON="a command or process substitution, an open quote, \$'...' or \$\"...\" quoting, or a comment, in: ${cmd:0:120}"; return 1; }
    while IFS= read -r seg; do
        seg="${seg#"${seg%%[![:space:]]*}"}"; seg="${seg%"${seg##*[![:space:]]}"}"
        [ -n "$seg" ] || continue
        any=1 ok=0
        while IFS= read -r r; do
            case "$r" in
                'Bash('*' *)') p="${r#Bash(}"; p="${p% \*)}"
                    if [ "$seg" = "$p" ] || [ "${seg#"$p "}" != "$seg" ]; then ok=1; break; fi ;;
                'Bash('*')') p="${r#Bash(}"; p="${p%)}"
                    case "$p" in *'*'*) ;; *) if [ "$seg" = "$p" ]; then ok=1; break; fi ;; esac ;;
            esac
        done <<<"$rules"
        [ "$ok" = 1 ] || { GITCTL_REASON="the command ${seg%% *} (Bash: ${seg:0:120})"; return 1; }
    done <<<"$segs"
    [ "$any" = 1 ] || { GITCTL_REASON="an empty command"; return 1; }
    return 0
}

# _path_allowed TOOL PATH RULES: 0 when a TOOL(//<dir>/**) rule holds PATH (resolved, so no ..
# leaves the folder). The file-editing tools are judged with TOOL=Edit, as Claude Code judges
# them (code.claude.com/docs, permissions, "What Read and Edit rules cover"): Edit rules apply to
# every built-in tool that edits files (Edit, Write, NotebookEdit, legacy MultiEdit), and a
# Write(path), NotebookEdit(path) or MultiEdit(path) rule is accepted but matches nothing. So the
# list's old Write(//tmp/**) allowed no write at all, under dontAsk denied Write and Edit alike;
# the list now says Edit(//tmp/**), which Claude matches for all four, and so does this hook.
_path_allowed() {
    local tool="$1" path="$2" rules="$3" r d real
    [ -n "$path" ] || return 1
    real=$(realpath -m -- "$path" 2>/dev/null) || return 1
    while IFS= read -r r; do
        case "$r" in
            "${tool}(//"*'/**)') d="${r#"${tool}(/"}"; d="${d%/\*\*)}"
                case "$real" in "$d"/?*) return 0 ;; esac ;;
        esac
    done <<<"$rules"
    return 1
}

input=$(cat)
command -v jq >/dev/null 2>&1 || block "the hook cannot read the tool call (no jq)"
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || block "the hook cannot read the tool call"
[ -n "$tool" ] || block "the hook cannot read the tool call (no tool name)"
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || block "the hook cannot read the tool call"
if [ -n "$cmd" ]; then
    gitctl_hook_command "$cmd" || block "$GITCTL_REASON"
fi
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || path=""
case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
        [ -z "$path" ] || gitctl_hook_path "$path" || block "$GITCTL_REASON" ;;
esac

rules=$(jq -r '.permissions.allow[]' "$settings" 2>/dev/null) \
    || block "the hook cannot read the allow list in ${settings}"
case "$_NO_PERMISSION_TOOLS" in *" ${tool} "*) exit 0 ;; esac
if printf '%s\n' "$rules" | grep -qxF -- "$tool"; then exit 0; fi
case "$tool" in
    Bash)
        _bash_allowed "$cmd" "$rules" || deny "$GITCTL_REASON" ;;
    Edit|Write|MultiEdit|NotebookEdit)
        printf '%s\n' "$rules" | grep -qxF -- Edit && exit 0
        _path_allowed Edit "$path" "$rules" || deny "the tool ${tool}${path:+ on ${path}}" ;;
    *)
        deny "the tool ${tool}${path:+ on ${path}}" ;;
esac
exit 0
