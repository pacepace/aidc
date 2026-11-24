#!/usr/bin/env bash
# shellcheck shell=bash
# Globals set here are read by the wrappers and the hook (SC2034); the tokenizer compares
# single characters with a backslash (SC1003).
# shellcheck disable=SC2034,SC1003
# The git container's hard rules (docs/design-12-kubernetes.md, "Git", K8S-24), shared by the
# wrapped git and gh and by Claude Code's PreToolUse hook, so the two cannot drift.
#
# The git container's Claude reads text written by sandboxed sessions, which can try to talk it
# into breaking a rule; these checks hold whatever it is told. Every check is a function that
# returns 0 to allow or 1 to refuse, with the one-line reason in GITCTL_REASON.
#
# Who runs what (see git-wrapper.sh): the agent's own user (git, uid 2000) holds no secret.
# Real git runs as gitrun, which holds no secret either but may ask for the GitHub token
# through the credential helper; real gh and that helper run as gitcred, the only user that can
# read the token. So code run as gitrun or gitcred, or a file gitcred reads, is a path to the
# token, and the rules below close those paths as well as the force pushes, non-merge merges
# and attribution the owner ruled out.
#
# Not in scope here: rewriting already-pushed history by other means than a forced push (a
# local rebase is allowed; the remote refuses a non-fast-forward without --force), and GitHub
# itself, whose branch protection is the backstop for anything that reaches its API.

GITCTL_PROTECTED_BRANCHES="main master develop"

# Names that mark AI authorship in a trailer or a "Generated with" line. Matched as words,
# case-insensitively.
GITCTL_AI='claude|anthropic|openai|chatgpt|gpt-?[0-9]|copilot|gemini|codex|cursor|codeium|windsurf|tabnine|aider|devin|codewhisperer|cody|deepseek|mistral|llama|grok|qwen|\bai\b|\[bot\]'

gitctl_refuse() { GITCTL_REASON="$1"; return 1; }

# gitctl_attribution TEXT: 0 (and the offending line in GITCTL_HIT) when TEXT carries AI
# attribution: a Co-Authored-By or Signed-off-by naming an AI, a "Generated with"/"Created
# with" line naming one, the robot emoji, or a Claude Code link. Trailers and footers only,
# anchored at the line start, so a message that merely talks about Claude (this repo's do)
# passes.
gitctl_attribution() {
    local text="$1"
    GITCTL_HIT=""
    GITCTL_HIT=$(printf '%s\n' "$text" | LC_ALL=C grep -m1 -F "$(printf '\360\237\244\226')") && return 0
    GITCTL_HIT=$(printf '%s\n' "$text" | LC_ALL=C grep -m1 -iE \
        -e "^[[:space:]]*co[- ]?authored[- ]?by[[:space:]]*:.*(${GITCTL_AI})" \
        -e "^[[:space:]]*signed[- ]?off[- ]?by[[:space:]]*:.*(${GITCTL_AI})" \
        -e "^[^[:alnum:]]*(generated|created|written|authored|made)[[:space:]]+(with|by|using|via|in)[[:space:]].*(${GITCTL_AI})" \
        -e 'claude\.(com|ai)/(claude-)?code') && return 0
    GITCTL_HIT=""
    return 1
}

gitctl_check_text() {
    gitctl_attribution "$1" || return 0
    gitctl_refuse "$2 carries AI attribution (${GITCTL_HIT:0:120}); no attribution in commits, PRs or comments"
}

# gitctl_abbrev ARG FULL MIN: ARG is FULL or a prefix of it at least MIN characters long (git
# accepts unique prefixes of long options, so --forc is --force).
gitctl_abbrev() {
    [ "${#1}" -ge "$3" ] && [ "${2#"$1"}" != "$2" ]
}

gitctl_protected_ref() {
    local r="${1#refs/heads/}" b
    for b in $GITCTL_PROTECTED_BRANCHES; do [ "$r" = "$b" ] && return 0; done
    return 1
}

# Config keys a caller may set, with -c or `git config`. An allowlist, not a blocklist: git
# reads dozens of keys that run a command (core.pager, core.sshCommand, credential.helper,
# filter.*.clean, diff.*.textconv, alias.*, include.path, ...), and one missed is code run as
# gitrun, which can ask for the token.
gitctl_config_key_ok() {
    local key="${1,,}"
    case "$key" in
        user.name|user.email|core.quotepath|core.sharedrepository|init.defaultbranch) return 0 ;;
        push.default|push.autosetupremote|pull.ff|merge.ff|fetch.prune|gc.auto) return 0 ;;
        color.*|advice.*|log.*) return 0 ;;
        pull.rebase) return 0 ;;
        branch.*.remote|branch.*.merge|branch.*.pushremote|branch.*.description|branch.*.rebase) return 0 ;;
        remote.*.url|remote.*.pushurl|remote.*.fetch|remote.*.gh-resolved) return 0 ;;
    esac
    return 1
}

# gitctl_url_ok URL: https, a local path or file://. Not http (the token would cross in the
# clear), not ssh (the container logs in over HTTPS), not transport helpers (`ext::` runs a
# command).
gitctl_url_ok() {
    case "$1" in
        *::*|-*) return 1 ;;
        https://*|file:///*|/*|./*|../*) return 0 ;;
        *:*) return 1 ;;
        *) return 0 ;;
    esac
}

gitctl_config_value_ok() { # KEY VALUE
    local key="${1,,}" val="$2"
    case "$key" in
        remote.*.url|remote.*.pushurl)
            gitctl_url_ok "$val" || { gitctl_refuse "${1}=${val}: only https, a local path or file:// remotes"; return 1; } ;;
        pull.rebase|branch.*.rebase)
            case "${val,,}" in i|interactive) gitctl_refuse "interactive rebase runs an editor; refused"; return 1 ;; esac ;;
    esac
    return 0
}

gitctl_config_pair_ok() { # KEY=VALUE as given to -c
    local kv="$1" key val
    key="${kv%%=*}"
    if [ "$key" = "$kv" ]; then val="true"; else val="${kv#*=}"; fi
    gitctl_config_key_ok "$key" || { gitctl_refuse "git -c ${key}: only identity, colour and remote/branch settings may be set (other keys can run a command or change a push)"; return 1; }
    gitctl_config_value_ok "$key" "$val"
}

# The git subcommands the git container runs, including the ones git runs for itself (a push
# to a local path starts receive-pack, a fetch index-pack). Anything else is refused: the
# container is a narrow tool, and each command left out is one less way to run code or write
# a file as gitrun.
GITCTL_GIT_COMMANDS=" add annotate blame branch cat-file check-attr check-ignore check-ref-format checkout checkout--worker cherry cherry-pick clean clone commit commit-graph commit-tree config count-objects describe diff diff-files diff-index diff-tree fetch fetch-pack for-each-ref fsck gc grep hash-object index-pack init log ls-files ls-remote ls-tree maintenance merge merge-base merge-tree mktree multi-pack-index mv name-rev pack-objects pack-refs prune prune-packed pull push range-diff read-tree rebase receive-pack reflog remote repack replay reset restore rev-list rev-parse revert rm shortlog show show-branch show-index show-ref stash status switch symbolic-ref tag unpack-objects update-index update-ref upload-pack var verify-pack version whatchanged worktree write-tree "

# gitctl_check_git ARGS...: the whole of one git command line. Sets GITCTL_SUB (the subcommand),
# GITCTL_SUB_ARGS, GITCTL_QGLOBAL (the global options that change which repo and config a
# query sees: -C and -c) and, for push, GITCTL_PUSH_*.
gitctl_check_git() {
    GITCTL_SUB=""; GITCTL_SUB_ARGS=(); GITCTL_QGLOBAL=(); GITCTL_REASON=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -c)
                [ $# -ge 2 ] || return 0
                gitctl_config_pair_ok "$2" || return 1
                GITCTL_QGLOBAL+=("$1" "$2"); shift 2 ;;
            --config-env=*|--config-env)
                gitctl_refuse "git --config-env is refused (use -c with an allowed key)"; return 1 ;;
            -C)
                [ $# -ge 2 ] || return 0
                GITCTL_QGLOBAL+=("$1" "$2"); shift 2 ;;
            --git-dir|--git-dir=*|--work-tree|--work-tree=*)
                if [ "${AIDC_GITCTL_NESTED:-0}" = 1 ]; then
                    case "$1" in *=*) shift ;; *) shift 2 ;; esac
                    continue
                fi
                # An explicit git dir skips git's check that the repo belongs to the user
                # running it, which is what keeps a planted repo's config from running code.
                gitctl_refuse "git ${1%%=*} is refused (use -C <repo>)"; return 1 ;;
            --exec-path=*|--super-prefix*)
                gitctl_refuse "git ${1%%=*} is refused: it changes where git finds its own programs"; return 1 ;;
            --namespace|--attr-source)
                GITCTL_QGLOBAL+=("$1" "${2:-}"); shift 2 ;;
            --*) shift ;;
            -*) shift ;;
            *) GITCTL_SUB="$1"; shift; GITCTL_SUB_ARGS=("$@"); break ;;
        esac
    done
    [ -n "$GITCTL_SUB" ] || return 0
    case "$GITCTL_GIT_COMMANDS" in
        *" $GITCTL_SUB "*) ;;
        *)
            case "$GITCTL_SUB" in
                send-pack|http-push) gitctl_refuse "git ${GITCTL_SUB} is refused: it updates a remote outside push's checks" ;;
                credential|credential-*) gitctl_refuse "git ${GITCTL_SUB} is refused: it hands out the GitHub token" ;;
                *) gitctl_refuse "git ${GITCTL_SUB} is not something the git container runs (refused; an alias, a tool or a command that runs code)" ;;
            esac
            return 1 ;;
    esac
    gitctl_check_git_sub "$GITCTL_SUB" "${GITCTL_SUB_ARGS[@]}"
}

gitctl_check_git_sub() {
    local sub="$1"; shift
    local a
    # Options that run a program or write a file, wherever they appear.
    for a in "$@"; do
        [ "$a" = "--" ] && break
        case "$a" in
            --output|--output=*|--output-directory*)
                gitctl_refuse "git ${sub} ${a%%=*} is refused: git writes no files outside the repo"; return 1 ;;
            --upload-pack|--upload-pack=*|--receive-pack|--receive-pack=*|--exec|--exec=*)
                gitctl_refuse "git ${sub} ${a%%=*} is refused: it runs a command"; return 1 ;;
            --template|--template=*)
                case "$sub" in clone|init) gitctl_refuse "git ${sub} --template is refused: a template can carry config"; return 1 ;; esac ;;
        esac
    done
    case "$sub" in
        push) gitctl_check_push "$@" ;;
        commit|merge|tag|commit-tree|cherry-pick|revert) gitctl_check_message_args "$sub" "$@" ;;
        clone) gitctl_check_clone "$@" ;;
        fetch|pull|ls-remote|fetch-pack) gitctl_check_fetch "$sub" "$@" ;;
        rebase) gitctl_check_rebase "$@" ;;
        config) gitctl_check_config "$@" ;;
        remote) gitctl_check_remote "$@" ;;
        maintenance)
            [ "${1:-}" = run ] || { gitctl_refuse "git maintenance ${1:-} is refused (it schedules jobs); only maintenance run"; return 1; } ;;
        stash|worktree|branch|checkout|switch) return 0 ;;
    esac
}

gitctl_check_push() {
    local a name positional=() del=0 endopts=0 i c rest
    GITCTL_PUSH_ALL=0; GITCTL_PUSH_TAGS=0
    while [ $# -gt 0 ]; do
        a="$1"; shift
        if [ "$endopts" = 1 ] || [ "${a#-}" = "$a" ] || [ "$a" = "-" ]; then positional+=("$a"); continue; fi
        case "$a" in
            --) endopts=1; continue ;;
            --no-*) continue ;;
            --*)
                name="${a%%=*}"
                if gitctl_abbrev "$name" --force 4 || gitctl_abbrev "$name" --force-with-lease 4 || gitctl_abbrev "$name" --force-if-includes 4; then
                    gitctl_refuse "git push ${a}: force pushes are refused (never force-push; push a new commit instead)"; return 1
                fi
                if gitctl_abbrev "$name" --mirror 4; then
                    gitctl_refuse "git push --mirror is refused: it force-updates and deletes every remote ref"; return 1
                fi
                if gitctl_abbrev "$name" --prune 5; then
                    gitctl_refuse "git push --prune is refused: it deletes remote branches"; return 1
                fi
                gitctl_abbrev "$name" --delete 4 && del=1
                gitctl_abbrev "$name" --all 4 && GITCTL_PUSH_ALL=1
                gitctl_abbrev "$name" --branches 4 && GITCTL_PUSH_ALL=1
                gitctl_abbrev "$name" --tags 4 && GITCTL_PUSH_TAGS=1
                case "$name" in
                    --repo|--push-option|--recurse-submodules|--signed)
                        [ "$name" = "$a" ] && [ $# -gt 0 ] && [ "$name" != --signed ] && shift ;;
                esac ;;
            -*)
                rest="${a#-}"
                for (( i=0; i<${#rest}; i++ )); do
                    c="${rest:i:1}"
                    case "$c" in
                        f) gitctl_refuse "git push ${a}: force pushes are refused (never force-push; push a new commit instead)"; return 1 ;;
                        d) del=1 ;;
                        o) [ $((i + 1)) -lt ${#rest} ] || shift; break ;;
                    esac
                done ;;
        esac
    done
    for a in "${positional[@]}"; do
        case "$a" in +*) gitctl_refuse "git push ${a}: a +refspec is a force push; refused"; return 1 ;; esac
    done
    GITCTL_PUSH_REPO="${positional[0]:-}"
    GITCTL_PUSH_REFSPECS=("${positional[@]:1}")
    local dst
    for a in "${GITCTL_PUSH_REFSPECS[@]}"; do
        dst=""
        if [ "$del" = 1 ]; then dst="$a"
        else case "$a" in :?*) dst="${a#:}" ;; esac
        fi
        if [ -n "$dst" ] && gitctl_protected_ref "$dst"; then
            gitctl_refuse "git push: deleting ${dst} on the remote is refused"; return 1
        fi
    done
    if [ -n "$GITCTL_PUSH_REPO" ] && ! gitctl_url_ok "$GITCTL_PUSH_REPO"; then
        gitctl_refuse "git push to ${GITCTL_PUSH_REPO}: only https, a local path or a named remote"; return 1
    fi
    return 0
}

# Messages given on the command line. The wrapper checks the final message again through
# GIT_EDITOR, which also sees -F files, --amend, -C and templates.
gitctl_check_message_args() {
    local sub="$1"; shift
    local a name i c rest v
    while [ $# -gt 0 ]; do
        a="$1"; shift
        case "$a" in
            --) break ;;
            --*=*)
                name="${a%%=*}"; v="${a#*=}"
                if gitctl_abbrev "$name" --message 5 || gitctl_abbrev "$name" --trailer 5; then
                    gitctl_check_text "$v" "the ${sub} message" || return 1
                fi ;;
            --*)
                if gitctl_abbrev "$a" --message 5 || gitctl_abbrev "$a" --trailer 5; then
                    gitctl_check_text "${1:-}" "the ${sub} message" || return 1; shift
                fi ;;
            -?*)
                rest="${a#-}"
                for (( i=0; i<${#rest}; i++ )); do
                    c="${rest:i:1}"
                    case "$c" in
                        m)
                            if [ $((i + 1)) -lt ${#rest} ]; then v="${rest:i+1}"; else v="${1:-}"; shift; fi
                            gitctl_check_text "$v" "the ${sub} message" || return 1
                            break ;;
                        F|C|c|t|u|S|s|X|n) break ;;
                    esac
                done ;;
        esac
    done
    return 0
}

gitctl_check_clone() {
    local a
    for a in "$@"; do
        case "$a" in
            -c|--config|--config=*|-c*)
                gitctl_refuse "git clone ${a%%=*} is refused: it writes config into the new repo"; return 1 ;;
            -u|-u*)
                gitctl_refuse "git clone -u is refused: it runs a command"; return 1 ;;
            --recurse-submodules*|--recursive)
                gitctl_refuse "git clone ${a%%=*} is refused: submodules are not used here"; return 1 ;;
            -*) ;;
            *) gitctl_url_ok "$a" || { gitctl_refuse "git clone ${a}: only https, a local path or file://"; return 1; }; return 0 ;;
        esac
    done
    return 0
}

gitctl_check_fetch() {
    local sub="$1"; shift
    local a
    for a in "$@"; do
        case "$a" in
            --) break ;;
            -u|-u*)
                case "$sub" in pull) ;; *) gitctl_refuse "git ${sub} -u is refused: it runs a command"; return 1 ;; esac ;;
            --rebase=i|--rebase=interactive|-ri)
                gitctl_refuse "git ${sub} ${a}: interactive rebase runs an editor; refused"; return 1 ;;
            --recurse-submodules*)
                gitctl_refuse "git ${sub} --recurse-submodules is refused: submodules are not used here"; return 1 ;;
            *::*)
                gitctl_refuse "git ${sub} ${a}: transport helpers are refused"; return 1 ;;
        esac
    done
    return 0
}

gitctl_check_rebase() {
    local a
    for a in "$@"; do
        case "$a" in
            --) break ;;
            -i|--interactive|--edit-todo|--exec|--exec=*)
                gitctl_refuse "git rebase ${a} is refused: an interactive or --exec rebase runs commands and editors (a plain rebase is fine)"; return 1 ;;
            --*|-[XsC]*) ;;
            -*[ix]*)
                gitctl_refuse "git rebase ${a} is refused: an interactive or --exec rebase runs commands and editors (a plain rebase is fine)"; return 1 ;;
        esac
    done
    return 0
}

# git config: reads are free; writes only to allowed keys, in the repo or --global config.
gitctl_check_config() {
    local a write=0 file=0 pos=() action="" key
    for a in "$@"; do
        case "$a" in
            --add|--replace-all|--unset|--unset-all|--rename-section|--remove-section) write=1 ;;
            -e|--edit) gitctl_refuse "git config --edit runs an editor; refused"; return 1 ;;
            -f|--file|--file=*|--blob|--blob=*|--system|--worktree) file=1 ;;
            --*) ;;
            -*) ;;
            *) pos+=("$a") ;;
        esac
    done
    # The subcommand form: git config set|unset|get|list|edit|rename-section|remove-section.
    case "${pos[0]:-}" in
        edit) gitctl_refuse "git config edit runs an editor; refused"; return 1 ;;
        set|unset|rename-section|remove-section) action="${pos[0]}"; write=1; pos=("${pos[@]:1}") ;;
        get|list) return 0 ;;
    esac
    [ "$write" = 1 ] || [ ${#pos[@]} -ge 2 ] || return 0
    if [ "$file" = 1 ]; then
        gitctl_refuse "git config writes to --file, --blob, --system or --worktree are refused"; return 1
    fi
    key="${pos[0]:-}"
    if printf '%s\n' "$@" | grep -qE -- '^--(rename|remove)-section$' || [ "$action" = rename-section ] || [ "$action" = remove-section ]; then
        case "${key,,}" in
            remote.*|branch.*) return 0 ;;
            *) gitctl_refuse "git config: only remote and branch sections may be renamed or removed"; return 1 ;;
        esac
    fi
    gitctl_config_key_ok "$key" || { gitctl_refuse "git config ${key}: only identity, colour and remote/branch settings may be set (other keys can run a command or change a push)"; return 1; }
    [ ${#pos[@]} -ge 2 ] || return 0
    gitctl_config_value_ok "$key" "${pos[1]}"
}

gitctl_check_remote() {
    local a pos=()
    for a in "$@"; do case "$a" in -*) ;; *) pos+=("$a") ;; esac; done
    case "${pos[0]:-}" in
        add) gitctl_url_ok "${pos[2]:-}" || { gitctl_refuse "git remote add ${pos[2]:-}: only https, a local path or file://"; return 1; } ;;
        set-url) gitctl_url_ok "${pos[${#pos[@]}-1]}" || { gitctl_refuse "git remote set-url: only https, a local path or file://"; return 1; } ;;
    esac
    return 0
}

# --- gh ------------------------------------------------------------------------------------

# The gh commands the git container runs. Everything else (extensions, gists, secrets, keys,
# codespaces, config set, alias set) is refused: gh runs as gitcred, which holds the token, so
# a command that runs code, opens a file or prints the token is a way to it.
gitctl_gh_allowed() { # GROUP CMD
    case "$1 $2" in
        "auth login"|"auth logout"|"auth status"|"auth refresh"|"auth switch") return 0 ;;
        "pr create"|"pr edit"|"pr comment"|"pr merge"|"pr view"|"pr list"|"pr status"|"pr checks"|"pr diff"|"pr close"|"pr reopen"|"pr ready"|"pr review") return 0 ;;
        "issue create"|"issue edit"|"issue comment"|"issue view"|"issue list"|"issue close"|"issue reopen"|"issue status") return 0 ;;
        "repo view"|"repo list"|"repo edit"|"repo set-default") return 0 ;;
        "run list"|"run view"|"workflow list"|"workflow view"|"release list"|"release view"|"label list") return 0 ;;
        "config get"|"config list"|"alias list"|"search "*) return 0 ;;
    esac
    case "$1" in
        api|status|browse|version|--version|help|"") return 0 ;;
    esac
    return 1
}

# gitctl_check_gh ARGS...: one gh command line. Bodies given as files must come on stdin (`-`):
# gh reads a named file as gitcred, which can read the token. GITCTL_STDIN_TEXT, when the
# wrapper has read stdin, is checked as the body.
gitctl_check_gh() {
    GITCTL_REASON=""
    local group="${1:-}" cmd="${2:-}"
    case "$group" in
        -R|--repo) gitctl_refuse "gh: put --repo after the command"; return 1 ;;
    esac
    if ! gitctl_gh_allowed "$group" "$cmd"; then
        case "$group $cmd" in
            "auth token"*|"auth git-credential"*) gitctl_refuse "gh ${group} ${cmd} is refused: it hands out the GitHub token" ;;
            "auth setup-git"*) gitctl_refuse "gh auth setup-git is refused: the git container's git config sets the credential helper" ;;
            extension*|ext*) gitctl_refuse "gh extensions are refused: they run code with the GitHub login" ;;
            "alias set"*|"alias import"*) gitctl_refuse "gh alias set is refused: an alias can hide a refused command or run a shell" ;;
            "config set"*) gitctl_refuse "gh config set is refused: the editor, pager, browser and socket settings run code with the GitHub login" ;;
            *) gitctl_refuse "gh ${group} ${cmd} is not something the git container runs (refused)" ;;
        esac
        return 1
    fi
    # api, status, browse and version take no subcommand.
    case "$group" in
        api|status|browse|version|--version|help|"") shift $(( $# > 0 ? 1 : 0 )) ;;
        *) shift $(( $# > 1 ? 2 : $# )) ;;
    esac
    local a
    for a in "$@"; do
        case "$a" in
            --show-token|-t)
                [ "$group $cmd" = "auth status" ] && { gitctl_refuse "gh auth status ${a} is refused: it prints the GitHub token"; return 1; } ;;
            --with-token) ;;
        esac
    done
    case "$group" in
        api) gitctl_check_gh_api "$@" || return 1 ;;
        pr|issue|repo|release)
            gitctl_check_gh_files "$group $cmd" "$@" || return 1
            [ "$group $cmd" = "pr merge" ] && { gitctl_check_gh_merge "$@" || return 1; }
            gitctl_check_text "$(printf '%s\n' "$@")" "gh ${group} ${cmd}" || return 1
            if [ -n "${GITCTL_STDIN_TEXT:-}" ]; then
                gitctl_check_text "$GITCTL_STDIN_TEXT" "the gh ${group} ${cmd} body" || return 1
            fi ;;
    esac
    return 0
}

# File-taking flags of pr/issue: only `-` (stdin) is allowed.
gitctl_check_gh_files() {
    local what="$1"; shift
    local a v
    while [ $# -gt 0 ]; do
        a="$1"; shift
        case "$a" in
            -F|--body-file|--notes-file|-T|--template) v="${1:-}"; shift ;;
            --body-file=*|--notes-file=*|--template=*) v="${a#*=}" ;;
            -F?*) v="${a#-F}" ;;
            *) continue ;;
        esac
        case "$a" in -T|--template*) gitctl_refuse "gh ${what} --template is refused (give the body with --body or --body-file -)"; return 1 ;; esac
        [ "$v" = "-" ] || { gitctl_refuse "gh ${what} ${a%%=*} ${v}: give the body on stdin (--body-file -); gh reads no files in the git container"; return 1; }
    done
    return 0
}

gitctl_check_gh_merge() {
    local a merge=0 other="" disable=0 i c rest
    while [ $# -gt 0 ]; do
        a="$1"; shift
        case "$a" in
            --merge|--merge=true) merge=1 ;;
            --merge=false) merge=0 ;;
            --squash|--squash=true) other="squash" ;;
            --rebase|--rebase=true) other="rebase" ;;
            --squash=*|--rebase=*) ;;
            --disable-auto*) disable=1 ;;
            --body|--body-file|--subject|--author-email|--repo|--match-head-commit) shift ;;
            --*) ;;
            -?*)
                rest="${a#-}"
                for (( i=0; i<${#rest}; i++ )); do
                    c="${rest:i:1}"
                    case "$c" in
                        m) merge=1 ;;
                        s) other="squash" ;;
                        r) other="rebase" ;;
                        b|F|t|A|R) [ $((i + 1)) -lt ${#rest} ] || shift; break ;;
                    esac
                done ;;
        esac
    done
    if [ -n "$other" ]; then gitctl_refuse "gh pr merge --${other} is refused: merge commits only (--merge)"; return 1; fi
    [ "$disable" = 1 ] && return 0
    [ "$merge" = 1 ] || { gitctl_refuse "gh pr merge needs --merge: merge commits only"; return 1; }
    return 0
}

gitctl_check_gh_api() {
    local a v endpoint="" method="" fields="" input=""
    while [ $# -gt 0 ]; do
        a="$1"; shift
        case "$a" in
            -X|--method) method="${1:-}"; shift ;;
            --method=*) method="${a#*=}" ;;
            -X?*) method="${a#-X}" ;;
            -f|--raw-field|-F|--field) v="${1:-}"; shift
                case "$a:$v" in -F:*=@*|--field:*=@*) [ "${v#*=@}" = "-" ] || { gitctl_refuse "gh api ${a} ${v}: gh reads no files in the git container (use @- for stdin)"; return 1; } ;; esac
                fields="${fields}${v}"$'\n' ;;
            --raw-field=*|--field=*) v="${a#*=}"; fields="${fields}${v}"$'\n'
                case "$v" in *=@*) [ "${v#*=@}" = "-" ] || { gitctl_refuse "gh api ${a}: gh reads no files in the git container"; return 1; } ;; esac ;;
            --input) input="${1:-}"; shift
                [ "$input" = "-" ] || { gitctl_refuse "gh api --input ${input}: give the body on stdin (--input -)"; return 1; } ;;
            --input=*) input="${a#*=}"
                [ "$input" = "-" ] || { gitctl_refuse "gh api --input ${input}: give the body on stdin (--input -)"; return 1; } ;;
            --verbose) gitctl_refuse "gh api --verbose is refused: it prints the request headers"; return 1 ;;
            -H|--header|-q|--jq|-t|--template|--hostname|-p|--preview|--cache) shift ;;
            -*) ;;
            *) [ -n "$endpoint" ] || endpoint="$a" ;;
        esac
    done
    case "$endpoint" in
        *://*) gitctl_refuse "gh api ${endpoint}: give an API path, not a URL"; return 1 ;;
    esac
    local body="$fields${GITCTL_STDIN_TEXT:-}"
    method="${method^^}"
    if printf '%s' "$endpoint" | grep -qE '(^|/)pulls/[^/]+/merge/?$'; then
        if printf '%s' "$body" | grep -qiE '(^|[^a-z_])merge_method"?[[:space:]]*[=:][[:space:]]*"?(squash|rebase)'; then
            gitctl_refuse "gh api ${endpoint}: squash and rebase merges are refused (merge_method=merge)"; return 1
        fi
    fi
    if [ "$endpoint" = graphql ]; then
        if printf '%s' "$body" | grep -qE '(mergePullRequest|enablePullRequestAutoMerge)' && printf '%s' "$body" | grep -qE 'mergeMethod[[:space:]]*:[[:space:]]*"?(SQUASH|REBASE)'; then
            gitctl_refuse "gh api graphql: squash and rebase merges are refused"; return 1
        fi
        if printf '%s' "$body" | grep -qE 'allowsForcePushes[[:space:]]*:[[:space:]]*true|allowsDeletions[[:space:]]*:[[:space:]]*true|deleteBranchProtectionRule|deleteRepositoryRuleset'; then
            gitctl_refuse "gh api graphql: loosening branch protection is refused"; return 1
        fi
    fi
    if printf '%s' "$endpoint" | grep -qE '/branches/[^/]+/protection/?$|/rulesets(/|$)'; then
        if [ "$method" = DELETE ]; then gitctl_refuse "gh api -X DELETE ${endpoint}: removing branch protection is refused"; return 1; fi
    fi
    if printf '%s' "$endpoint" | grep -qE '/branches/[^/]+/protection'; then
        if printf '%s' "$body" | grep -qiE 'allow_(force_pushes|deletions)"?[[:space:]]*[=:][[:space:]]*"?(true|1)'; then
            gitctl_refuse "gh api ${endpoint}: allowing force pushes or deletions is refused"; return 1
        fi
    fi
    gitctl_check_text "$body" "the gh api body"
}

# --- shell command lines (the PreToolUse hook) ---------------------------------------------

# gitctl_split_commands STRING: split a shell command line into simple commands, each a
# string of words joined by \x1f, in GITCTL_CMDS. Quotes, backslashes, separators, command
# substitution, subshells, redirections and here-documents are understood well enough to
# find each git and gh call and its arguments; it is not a full shell parser, and the wrappers
# are the enforcement for anything it misreads.
gitctl_split_commands() {
    local LC_ALL=C
    local s="$1" n=${#1} i=0 c nx word="" inword=0 state="" skipnext=0 heredoc=0
    local -a stack=() cur=() delims=()
    GITCTL_CMDS=()
    _gs_word() {
        if [ "$inword" = 1 ]; then
            if [ "$heredoc" = 1 ]; then delims+=("$word"); heredoc=0
            elif [ "$skipnext" = 1 ]; then skipnext=0
            else cur+=("$word"); fi
        fi
        word=""; inword=0
    }
    _gs_cmd() {
        _gs_word
        if [ ${#cur[@]} -gt 0 ]; then
            local IFS=$'\x1f'; GITCTL_CMDS+=("${cur[*]}")
        fi
        cur=()
    }
    while [ "$i" -lt "$n" ]; do
        c="${s:i:1}"; nx="${s:i+1:1}"
        case "$state" in
            "'")
                if [ "$c" = "'" ]; then state=""; else word+="$c"; fi ;;
            '"')
                if [ "$c" = '\' ]; then
                    case "$nx" in '$'|'`'|'"'|'\') word+="$nx"; i=$((i + 1)) ;; $'\n') i=$((i + 1)) ;; *) word+="$c" ;; esac
                elif [ "$c" = '"' ]; then state=""
                elif [ "$c" = '$' ] && [ "$nx" = '(' ]; then
                    stack+=('"'); _gs_cmd; state=""; i=$((i + 1))
                elif [ "$c" = '`' ]; then
                    stack+=('`"'); _gs_cmd; state=""
                else word+="$c"; fi ;;
            *)
                case "$c" in
                    ' '|$'\t') _gs_word ;;
                    $'\n')
                        _gs_cmd
                        # Skip here-document bodies: they are data, not commands.
                        local d line
                        for d in "${delims[@]}"; do
                            while [ "$i" -lt "$n" ]; do
                                line="${s:i+1}"; line="${line%%$'\n'*}"
                                i=$((i + ${#line} + 1))
                                [ "${line#"${line%%[!$'\t']*}"}" = "$d" ] && break
                            done
                        done
                        delims=() ;;
                    ';'|'&'|'|') _gs_cmd ;;
                    '(') _gs_cmd; stack+=("") ;;
                    ')')
                        _gs_cmd
                        if [ ${#stack[@]} -gt 0 ]; then
                            state="${stack[${#stack[@]}-1]}"; unset 'stack[${#stack[@]}-1]'
                            [ "$state" = '"' ] && inword=1
                        fi ;;
                    '$')
                        if [ "$nx" = '(' ]; then _gs_cmd; stack+=(""); i=$((i + 1))
                        else word+="$c"; inword=1; fi ;;
                    '`')
                        _gs_cmd
                        if [ ${#stack[@]} -gt 0 ] && [ "${stack[${#stack[@]}-1]:0:1}" = '`' ]; then
                            state="${stack[${#stack[@]}-1]:1}"; unset 'stack[${#stack[@]}-1]'
                            [ "$state" = '"' ] && inword=1
                        else
                            stack+=('`')
                        fi ;;
                    '\')
                        if [ "$nx" = $'\n' ]; then :; else word+="$nx"; inword=1; fi
                        i=$((i + 1)) ;;
                    "'") state="'"; inword=1 ;;
                    '"') state='"'; inword=1 ;;
                    '#')
                        if [ "$inword" = 0 ]; then
                            while [ "$i" -lt "$n" ] && [ "${s:i+1:1}" != $'\n' ]; do i=$((i + 1)); done
                        else word+="$c"; fi ;;
                    '<'|'>')
                        # A redirection: drop a leading fd number, the operator and its target.
                        if [ "$inword" = 1 ] && [[ "$word" =~ ^[0-9]+$ ]]; then word=""; inword=0; fi
                        _gs_word
                        if [ "$c" = '<' ] && [ "$nx" = '<' ]; then
                            if [ "${s:i+2:1}" = '<' ]; then i=$((i + 2)); skipnext=1
                            else i=$((i + 1)); [ "${s:i+1:1}" = '-' ] && i=$((i + 1)); heredoc=1; fi
                        else
                            while [ "$i" -lt "$n" ] && [[ "${s:i+1:1}" == [\<\>\&\|] ]]; do i=$((i + 1)); done
                            # >&2 names a descriptor, not a file.
                            if [[ "${s:i:1}" == '&' ]] && [[ "${s:i+1:1}" =~ [0-9-] ]]; then
                                while [[ "${s:i+1:1}" =~ [0-9-] ]]; do i=$((i + 1)); done
                            else skipnext=1; fi
                        fi ;;
                    *) word+="$c"; inword=1 ;;
                esac ;;
        esac
        i=$((i + 1))
    done
    _gs_cmd
    # A here-document delimiter can carry quotes; compare without them.
    unset -f _gs_word _gs_cmd
}

# gitctl_check_words WORDS...: one simple command from the hook's split.
gitctl_check_words() {
    local w base
    while [ $# -gt 0 ]; do
        w="$1"
        case "$w" in
            [A-Za-z_]*=*)
                case "${w%%=*}" in
                    PATH|GIT_EXEC_PATH|AIDC_GITCTL_*|LD_PRELOAD|LD_LIBRARY_PATH|BASH_ENV|ENV)
                        gitctl_refuse "setting ${w%%=*} is refused: it changes which git and gh run"; return 1 ;;
                esac
                [[ "${w%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || break
                shift ;;
            if|then|else|elif|do|while|until|'!'|'{'|'}'|time|command|builtin|exec|nohup|nice|stdbuf|xargs|timeout|ionice|setsid) shift
                while [ $# -gt 0 ] && [ "${1#-}" != "$1" ]; do shift; done ;;
            env)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -i|--ignore-environment|-u|-u*|--unset*|-S*|--split-string*|-) gitctl_refuse "env ${1}: clearing or rewriting the environment around git and gh is refused"; return 1 ;;
                        -*) shift ;;
                        *) break ;;
                    esac
                done ;;
            sudo|doas|su|runuser|setpriv)
                gitctl_refuse "${w} is refused: git and gh switch user themselves"; return 1 ;;
            sh|bash|dash|zsh|ksh)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -*c*) [ $# -ge 2 ] || return 0; gitctl_check_command_string "$2"; return ;;
                        -*) shift ;;
                        *) return 0 ;;
                    esac
                done
                return 0 ;;
            eval) shift; gitctl_check_command_string "$*"; return ;;
            *) break ;;
        esac
    done
    [ $# -gt 0 ] || return 0
    w="$1"; shift; base="${w##*/}"
    if [ "$w" != "$base" ]; then
        case "$base" in
            git|gh|git-*)
                case "$w" in
                    /opt/aidc/bin/git|/opt/aidc/bin/gh) ;;
                    *) gitctl_refuse "${w} runs git or gh outside the wrappers; use plain git or gh"; return 1 ;;
                esac ;;
        esac
    fi
    case "$base" in
        git) gitctl_check_git "$@" ;;
        git-*) gitctl_check_git "${base#git-}" "$@" ;;
        gh) gitctl_check_gh "$@" ;;
    esac
}

# gitctl_check_command_string STRING: the hook's check of one Bash tool command.
gitctl_check_command_string() {
    local s="$1" cmd
    GITCTL_REASON=""
    local stripped="${s//\/opt\/aidc\/bin\//}"
    if printf '%s' "$stripped" | grep -qE '(^|[^[:alnum:]_.-])(/usr)?/(local/)?bin/(git|gh)([^[:alnum:]_.-]|$)|git-core|/usr/lib/git|/opt/aidc/lib|\.local/bin/(git|gh)([^[:alnum:]_.-]|$)'; then
        gitctl_refuse "the command names a real git or gh binary or the wrappers' files; use plain git or gh"; return 1
    fi
    if printf '%s' "$s" | grep -qE '(^|[^[:alnum:]_])(PATH|GIT_EXEC_PATH|LD_PRELOAD)=|--exec-path=|AIDC_GITCTL_'; then
        gitctl_refuse "changing PATH, GIT_EXEC_PATH or LD_PRELOAD is refused: it changes which git and gh run"; return 1
    fi
    if printf '%s' "$s" | grep -qE '/etc/claude-code|/etc/sudoers|/etc/gitconfig|/var/lib/gitctl|managed-settings'; then
        gitctl_refuse "the command touches the git container's protected settings or the token's home"; return 1
    fi
    if printf '%s' "$s" | grep -qE '(^|[^[:alnum:]_-])(git|gh)([^[:alnum:]_-]|$)' && gitctl_attribution "$s"; then
        gitctl_refuse "the command carries AI attribution (${GITCTL_HIT:0:120}); no attribution in commits, PRs or comments"; return 1
    fi
    gitctl_split_commands "$s"
    local -a words
    for cmd in "${GITCTL_CMDS[@]}"; do
        IFS=$'\x1f' read -r -d '' -a words < <(printf '%s\0' "$cmd")
        gitctl_check_words "${words[@]}" || return 1
    done
    return 0
}

# gitctl_check_path PATH: the hook's check of an Edit or Write target.
gitctl_check_path() {
    local p="$1" r
    r=$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")
    case "$r" in
        /opt/aidc/*|/etc/claude-code/*|/etc/sudoers*|/etc/gitconfig|/var/lib/gitctl/*|/usr/bin/git*|/usr/lib/git-core/*|/usr/local/bin/gh)
            gitctl_refuse "${p} is one of the git container's protected files"; return 1 ;;
    esac
    case "${r##*/}" in
        git|gh) gitctl_refuse "${p}: a file named git or gh could shadow the wrappers"; return 1 ;;
    esac
    return 0
}
