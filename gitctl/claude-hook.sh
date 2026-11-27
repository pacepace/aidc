#!/usr/bin/env bash
# Claude Code's PreToolUse hook in the git container, set in the read-only managed settings
# (/etc/claude-code/managed-settings.json), which no user, project or local setting can turn
# off. It runs before every tool call (matcher "*") and does two things.
#
# 1. The allow list. The git agent's Claude runs in the default permission mode, not dontAsk:
#    Claude Code 2.1.332 refuses AskUserQuestion in dontAsk whatever the settings or a hook say,
#    and the question is how ask mode reaches the user (docs/design-12-kubernetes.md, "Git").
#    So this hook is the one authority over the agent's tools, with dontAsk's effective set: it
#    refuses ("deny", with a reason) every call the managed settings' permissions.allow would
#    not allow, and allows ("allow", with a reason) every call the list allows and it has
#    checked. The explicit allow is needed: a call left without a decision goes on to Claude's
#    own check, which in the default mode still asks about some listed calls (a cd before git;
#    a git -C read of a working copy outside its working folder; three live instances, the last
#    a plain "Do you want to proceed?"), and that prompt waits with no one there. Claude's safety
#    shapes (a cd, an unquoted glob, a redirect it cannot pre-approve, a protected path) are
#    still denied, with what to write instead, not allowed past the prompt. No decision is given
#    only to Claude's tools that ask no permission (TodoWrite, ToolSearch, ...) and to
#    AskUserQuestion, whose "permission" is the question itself: an "allow" would answer it
#    with nothing, and no decision opens the real question. The hook matches rules as Claude
#    does, for the shapes it models: a bare tool name, Bash(...) and Edit(//<dir>/**). A rule
#    of any other shape scoped to a tool (WebFetch(domain:...), Read(//x/**)) is not matched:
#    such a call is denied with a reason naming that rule, so a rule added to the list is never
#    refused without a word. The list is read from the managed settings each time; this hook
#    keeps no copy of it.
# 2. The guard rules (gitctl-rules.sh), a courtesy, not the enforcement: the agent holds no
#    credential, and gitctl, the only way to the GitHub login, checks everything itself. They
#    stop early what would fail or break a rule anyway: switching user, reading the login's
#    home, changing the guard files, a gh login in the agent's own home, and attribution in a
#    git or gitctl command. Exit 2 blocks the call, with the reason on stderr.
#
# Input it cannot read is blocked (exit 2). If the hook itself fails (a crash, a timeout), Claude
# Code lets the call go on to its own permission check: a listed call runs or asks, any other
# one asks, and the session shows waiting_on_permission. It never runs a call the list does not
# allow.
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
# allow WHAT: the call is on the allow list and passed every check here; Claude's own prompt,
# which no one would answer, is skipped. Only ever reached after the list matched.
allow() {
    jq -n -c --arg r "aidc gitctl: on the git agent's allow list (${1}), checked by its hook" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: $r}}'
    exit 0
}

# Claude Code's tools that ask no permission: dontAsk let them run whatever the list said
# (code.claude.com/docs, "Tools available to Claude"), so they get no decision here either.
# AskUserQuestion is not one of them here: dontAsk refused it, and the list names it. Read, Grep
# and Glob are, but the list names them, and Claude asks before they read outside its working
# folder, so a listed one gets the list's "allow" (the list is checked first).
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

# Claude Code's own safety prompts (code.claude.com/docs, permissions, "Read-only commands",
# "Compound commands", "Redirections"; permission-modes, "Protected paths"). In the default mode
# Claude asks before some calls the allow list covers, whatever the list or a hook's silence
# says, and no one is there to answer: the agent sits at waiting_on_permission. So the hook
# denies those shapes, with a reason that says what to write instead, rather than allow them.
_STEER="(Claude Code would stop at its own safety prompt, which no one answers here)"
_NO_CD="never cd (or pushd/popd): Claude Code asks before a cd followed by git, and the shell's folder does not stay put. Name the folder instead: git -C <dir> ..., gh -C <dir> ..., and absolute paths for gitctl, git-requests and ls"

# _protected_path PATH: 0 when Claude Code counts PATH as a protected path, whose writes it
# always asks about in the default mode (an allow rule does not pre-approve them).
_protected_path() {
    local p="/$1/" f
    case "$p" in
        */.git/*|*/.config/git/*|*/.vscode/*|*/.idea/*|*/.husky/*|*/.cargo/*|*/.devcontainer/*|*/.yarn/*|*/.mvn/*|*/.claude/*) return 0 ;;
    esac
    f="${1##*/}"
    case "$f" in
        .gitconfig|.gitmodules|.bashrc|.bash_profile|.bash_login|.bash_aliases|.bash_logout|.zshrc|.zprofile|.zshenv|.zlogin|.zlogout|.profile|.envrc|.npmrc|.yarnrc|.yarnrc.yml|.pnp.cjs|.pnp.loader.mjs|.pnpmfile.cjs|bunfig.toml|.bunfig.toml|.bazelrc|.bazelversion|.bazeliskrc|.pre-commit-config.yaml|lefthook.yml|lefthook.yaml|.lefthook.yml|.lefthook.yaml|gradle-wrapper.properties|maven-wrapper.properties|.devcontainer.json|.ripgreprc|pyrightconfig.json|.mcp.json|.claude.json|remote-settings.json) return 0 ;;
    esac
    return 1
}

# _out_target_ok WORD: 0 for an output redirect target Claude Code writes without asking here:
# /dev/null, or an absolute path under /tmp (the list's Edit(//tmp/**)) with no ~, no glob and
# no protected part. Anything else (the working folder too: the default mode asks before a
# write the list does not allow) prompts.
_out_target_ok() {
    local w="$1" real
    [ "$w" = /dev/null ] && return 0
    case "$w" in *'*'*|*'?'*|*'['*|'~'*) return 1 ;; esac
    real=$(realpath -m -- "$w" 2>/dev/null) || return 1
    case "$real" in /tmp/?*) ;; *) return 1 ;; esac
    _protected_path "$real" && return 1
    return 0
}

# _seg_prompts SEG: 1 (GITCTL_REASON set) when Claude Code would ask about this simple command
# although the list allows it: a cd/pushd/popd, an unquoted glob (Claude asks for commands such
# as git whose flags write, as the glob could expand to one; ls is exempt), or a redirect whose
# target it cannot pre-approve (see _out_target_ok; an input target with a glob).
_seg_prompts() {
    local seg="$1" i c n q="" op word wq first
    first="${seg%%[[:space:]]*}"
    case "$first" in
        cd|pushd|popd) GITCTL_REASON="${first} in: ${seg:0:120}: ${_NO_CD}"; return 1 ;;
    esac
    for ((i = 0; i < ${#seg}; i++)); do
        c="${seg:i:1}" n="${seg:i+1:1}"
        if [ "$q" = "'" ]; then [ "$c" = "'" ] && q=""; continue; fi
        if [ "$c" = "\\" ]; then i=$((i + 1)); continue; fi
        if [ "$q" = '"' ]; then [ "$c" = '"' ] && q=""; continue; fi
        case "$c" in
            "'"|'"') q="$c" ;;
            '*'|'?'|'[')
                [ "$first" = ls ] && continue
                GITCTL_REASON="an unquoted ${c} in: ${seg:0:120} ${_STEER}: quote the pattern ('src/*.py'); git reads a quoted pathspec itself"
                return 1 ;;
            '<'|'>')
                if [ "$c" = '<' ] && [ "$n" = '<' ]; then
                    # A here-doc or here-string: no file behind it, Claude checks nothing.
                    while [ "${seg:i+1:1}" = '<' ] || [ "${seg:i+1:1}" = '-' ]; do i=$((i + 1)); done
                    continue
                fi
                op="$c"
                while case "${seg:i+1:1}" in '>'|'|'|'&') true ;; *) false ;; esac; do i=$((i + 1)); op+="${seg:i:1}"; done
                while [ "${seg:i+1:1}" = ' ' ] || [ "${seg:i+1:1}" = $'\t' ]; do i=$((i + 1)); done
                word="" wq=""
                while [ $((i + 1)) -lt ${#seg} ]; do
                    c="${seg:i+1:1}"
                    if [ -z "$wq" ]; then
                        case "$c" in [[:space:]]|'<'|'>'|'&'|'|') break ;; "'"|'"') wq="$c"; i=$((i + 1)); continue ;;
                            "\\") word+="${seg:i+2:1}"; i=$((i + 2)); continue ;; esac
                    elif [ "$c" = "$wq" ]; then wq=""; i=$((i + 1)); continue
                    fi
                    word+="$c"; i=$((i + 1))
                done
                case "$op" in
                    *'&') case "$word" in -|[0-9]|[0-9][0-9]) continue ;; esac ;;
                esac
                if [ "${op:0:1}" = '<' ]; then
                    case "$word" in *'*'*|*'?'*|*'['*) GITCTL_REASON="an input redirect from a pattern (${word}) in: ${seg:0:120} ${_STEER}: name one file" ; return 1 ;; esac
                    continue
                fi
                _out_target_ok "$word" || {
                    GITCTL_REASON="a redirect to ${word:-nothing} in: ${seg:0:120} ${_STEER}: write only to /dev/null or to a file under /tmp, by its absolute path (no ~, no pattern)"
                    return 1; }
                ;;
        esac
    done
    return 0
}

# _claude_prompts CMD: 1 (GITCTL_REASON set) when Claude Code would stop at a safety prompt for
# CMD although every part is on the list: a command longer than its parser reads (10,000
# characters), an operator with nothing after it (it then does not split the command), or a
# part _seg_prompts names. A command it cannot split is left to _bash_allowed, which denies it.
_claude_prompts() {
    local cmd="$1" segs seg t
    [ "${#cmd}" -le 10000 ] || { GITCTL_REASON="a command of ${#cmd} characters ${_STEER}: run it in smaller parts"; return 1; }
    t="${cmd%"${cmd##*[![:space:]]}"}"
    case "$t" in
        *'&&'|*'||'|*[!\\]'|'|'|') GITCTL_REASON="a command that ends with an operator (${t: -2}) ${_STEER}: finish it or drop the operator"; return 1 ;;
    esac
    segs=$(_bash_segments "$cmd") || return 0
    while IFS= read -r seg; do
        seg="${seg#"${seg%%[![:space:]]*}"}"; seg="${seg%"${seg##*[![:space:]]}"}"
        [ -n "$seg" ] || continue
        _seg_prompts "$seg" || return 1
    done <<<"$segs"
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

# _unmodeled_rule TOOL RULES: the first rule scoped to TOOL (a "TOOL(...)" entry) whose shape
# this hook does not match: any other than Bash(...) and Edit(//<dir>/**). Claude may allow a
# call such a rule covers (WebFetch(domain:...), Read(//x/**)); this hook fails safe and denies
# it, and the deny says which rule, so a rule added to the list is not refused without a word.
_unmodeled_rule() {
    local tool="$1" r
    while IFS= read -r r; do
        case "$r" in
            'Bash('*|'Edit(//'*'/**)') ;;
            "${tool}("*) printf '%s' "$r"; return 0 ;;
        esac
    done <<<"$2"
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
if printf '%s\n' "$rules" | grep -qxF -- "$tool"; then
    case "$tool" in
        # No decision (see 1. above): the list names it, so Claude opens the real question.
        AskUserQuestion) exit 0 ;;
        Bash) _claude_prompts "$cmd" || deny "$GITCTL_REASON" ;;
        Edit|Write|MultiEdit|NotebookEdit)
            if [ -n "$path" ] && _protected_path "$(realpath -m -- "$path" 2>/dev/null || printf '%s' "$path")"; then
                deny "the tool ${tool} on ${path}: Claude Code counts it a protected path and always asks before writing it ${_STEER}: write PR and issue texts to a plain file under /tmp"
            fi ;;
    esac
    allow "the tool ${tool}"
fi
case "$_NO_PERMISSION_TOOLS" in *" ${tool} "*) exit 0 ;; esac
case "$tool" in
    Bash)
        _claude_prompts "$cmd" || deny "$GITCTL_REASON"
        _bash_allowed "$cmd" "$rules" && allow "Bash: every part of the command"
        deny "$GITCTL_REASON" ;;
    Edit|Write|MultiEdit|NotebookEdit)
        if [ -n "$path" ] && _protected_path "$(realpath -m -- "$path" 2>/dev/null || printf '%s' "$path")"; then
            deny "the tool ${tool} on ${path}: Claude Code counts it a protected path and always asks before writing it ${_STEER}: write PR and issue texts to a plain file under /tmp"
        fi
        printf '%s\n' "$rules" | grep -qxF -- Edit && allow "the tool ${tool}: the list's Edit"
        _path_allowed Edit "$path" "$rules" && allow "the tool ${tool} on ${path}" ;;
    *) ;;
esac
scope=Edit
case "$tool" in Edit|Write|MultiEdit|NotebookEdit) ;; *) scope="$tool" ;; esac
if unmodeled=$(_unmodeled_rule "$scope" "$rules"); then
    deny "the tool ${tool}${path:+ on ${path}}: the allow list's rule ${unmodeled} has a shape this hook does not match (only a bare tool name, Bash(...) and Edit(//<dir>/**)), so the hook refuses it rather than guess"
fi
deny "the tool ${tool}${path:+ on ${path}}"
exit 0
