#!/usr/bin/env bash
# The git container's git: /opt/aidc/bin/git, and every git builtin in /opt/aidc/git-core, the
# exec path real git is given, so a git that git itself starts (a shell alias, a pager, a
# push to a local path) comes back here too.
#
# Called by the agent (uid 2000), it switches to gitrun through the one sudo rule that names
# this file; sudo resets the environment, so nothing the caller exports (GIT_CONFIG_*,
# GIT_SSH_COMMAND, GIT_DIR, PATH) reaches git. As gitrun it applies the rules
# (gitctl-rules.sh) and runs the real git with hooks and fsmonitor off. gitrun holds no secret;
# GitHub's token reaches git only through the credential helper (cred-helper.sh), as gitcred.
#
# Not closed here: a caller who runs the real /usr/bin/git by its path runs it as itself, with
# no token (the credential helper's sudo rule is gitrun's alone), so it cannot write to GitHub;
# it can still move refs in a repo its group may write, as a session can. Claude's PreToolUse
# hook refuses such calls as well.
set -u

self=$(readlink -f "${BASH_SOURCE[0]}")
GITCTL_LIB=$(dirname "$self")
# shellcheck source=gitctl-rules.sh
. "$GITCTL_LIB/gitctl-rules.sh"

gitctl_die() { printf 'aidc gitctl: refused: %s\n' "$1" >&2; exit 1; }

args=("$@")
name="${0##*/}"
case "$name" in
    git-wrapper.sh) ;;
    git-*) args=("${name#git-}" "$@") ;;  # a dashed builtin from the exec path: git-receive-pack
esac

if [ "$GITCTL_LIB" = /opt/aidc/lib/gitctl ]; then
    REAL_GIT=/usr/bin/git
    EXEC_PATH=/opt/aidc/git-core
    if [ "$(id -un)" != gitrun ]; then
        exec sudo -n -u gitrun -- "$self" "${args[@]}"
    fi
    export HOME=/home/gitrun PATH=/opt/aidc/bin:/usr/local/bin:/usr/bin:/bin
else
    # Run from a checkout (the unit tests): no user switch, and stubs may stand in.
    REAL_GIT="${AIDC_GITCTL_REAL_GIT:-/usr/bin/git}"
    EXEC_PATH="${AIDC_GITCTL_EXEC_PATH:-}"
fi

# Started by a git this wrapper ran (through the exec path), not by a caller: git passes its
# own --git-dir to some of its helpers (receive-pack's), and gitrun's own processes are not
# the caller the rules are for.
nested=0
[ -n "$EXEC_PATH" ] && [ "${GIT_EXEC_PATH:-}" = "$EXEC_PATH" ] && nested=1
export AIDC_GITCTL_NESTED="$nested"

# A caller's private working directory is not gitrun's; -C still works from /.
[ -x . ] 2>/dev/null || cd /
ulimit -c 0 2>/dev/null || true

gitctl_check_git "${args[@]}" || gitctl_die "$GITCTL_REASON"

[ -n "$EXEC_PATH" ] && export GIT_EXEC_PATH="$EXEC_PATH"
# No editor and no pager: either would run a program as gitrun on a terminal the agent can
# type into. GIT_EDITOR only checks the message (msg-check.sh).
export GIT_EDITOR="$GITCTL_LIB/msg-check.sh" GIT_SEQUENCE_EDITOR=false GIT_PAGER=cat PAGER=cat \
    MANPAGER=cat GIT_TERMINAL_PROMPT=0
# sudo already dropped the caller's environment; a git that git itself started (through the
# exec path) still carries what git put there, and config is never taken from it: the
# backstop and the checked -c options are passed again on the command line.
unset GIT_ASKPASS SSH_ASKPASS GIT_SSH GIT_SSH_COMMAND GIT_PROXY_COMMAND GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_COUNT GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
for v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_[0-9]+$'); do unset "$v"; done

q=("$REAL_GIT" --no-pager "${GITCTL_QGLOBAL[@]}")

# gitctl_push_scan: refuse a push that config would turn into a force (a remote's push
# refspec with +, or mirror), and one that would carry a commit with attribution, whoever
# wrote it (a session's commit, a cherry-pick, a message an editor wrote).
gitctl_push_scan() {
    local cfg key val c spec src out rec h body
    cfg=$("${q[@]}" config --get-regexp '^remote\..*\.(push|mirror)$' 2>/dev/null || true)
    while read -r key val; do
        [ -n "$key" ] || continue
        case "$key" in
            *.push) case "$val" in +*) gitctl_die "git push: ${key} is ${val}, a forced refspec" ;; esac ;;
            *.mirror) case "${val,,}" in ""|true|yes|on|1) gitctl_die "git push: ${key} makes every push a mirror (a force push)" ;; esac ;;
        esac
    done <<<"$cfg"

    local revs=()
    [ "$GITCTL_PUSH_ALL" = 1 ] && revs+=(--branches)
    [ "$GITCTL_PUSH_TAGS" = 1 ] && revs+=(--tags)
    for spec in "${GITCTL_PUSH_REFSPECS[@]}"; do
        src="${spec%%:*}"
        [ -n "$src" ] || continue
        case "$src" in *'*'*) revs+=(--branches); continue ;; esac
        c=$("${q[@]}" rev-parse -q --verify "${src}^{commit}" 2>/dev/null) && revs+=("$c")
    done
    if [ ${#GITCTL_PUSH_REFSPECS[@]} -eq 0 ] && [ ${#revs[@]} -eq 0 ]; then
        c=$("${q[@]}" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) && revs+=("$c")
    fi
    [ ${#revs[@]} -gt 0 ] || return 0
    out=$("${q[@]}" log --no-color --format='%h%x1f%B%x1e' "${revs[@]}" --not --remotes -- 2>/dev/null) || return 0
    while IFS= read -r -d $'\x1e' rec; do
        rec="${rec#$'\n'}"
        h="${rec%%$'\x1f'*}"; body="${rec#*$'\x1f'}"
        if gitctl_attribution "$body"; then
            gitctl_die "git push: commit ${h} carries AI attribution (${GITCTL_HIT:0:120}); reword it before pushing"
        fi
    done <<<"$out"
}

sub_args=("${GITCTL_SUB_ARGS[@]}")
case "$GITCTL_SUB" in
    push) gitctl_push_scan ;;
    commit)
        # Every commit message passes msg-check.sh: --edit makes git hand it the final message
        # (from -m, -F, --amend, -C, a template or --trailer). With no message given git would
        # wait in an editor, and there is none.
        want=1
        for a in "${sub_args[@]}"; do
            [ "$a" = "--" ] && break
            case "$a" in
                -m*|--mes*|-F*|--fil*|-C*|--reu*|--no-e*|--fixup*|--squash*) want=0 ;;
                --*) ;;
                -*[mFC]*) want=0 ;;
            esac
        done
        [ "$want" = 0 ] || gitctl_die "git commit needs its message with -m or -F (the git container opens no editor)"
        edit_at=${#sub_args[@]}
        for i in "${!sub_args[@]}"; do [ "${sub_args[i]}" = "--" ] && { edit_at=$i; break; }; done
        sub_args=("${sub_args[@]:0:edit_at}" --edit "${sub_args[@]:edit_at}") ;;
esac

# The global options as given, then the backstop, then the subcommand.
nglobal=$(( ${#args[@]} - ${#GITCTL_SUB_ARGS[@]} - (${#GITCTL_SUB} > 0 ? 1 : 0) ))
backstop=(-c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.ext.allow=never)
if [ -n "$GITCTL_SUB" ]; then
    exec "$REAL_GIT" --no-pager "${args[@]:0:nglobal}" "${backstop[@]}" "$GITCTL_SUB" "${sub_args[@]}"
fi
exec "$REAL_GIT" --no-pager "${backstop[@]}" "${args[@]}"
