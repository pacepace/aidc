#!/usr/bin/env bash
# aidc repo remove <path|owner/name> [--delete-working-copy [--even-unpushed]]: forget a repo in
# the git container.
#
# Always deletes gitrun's private copy of the GitHub repo (gitctl remove-copy), so copies do not
# pile up in its store. The working copy on the user's disk holds the sessions' work, so it is
# deleted only when the user says so, by a one-shot root pod (manifests.sh, k8s_render_repo_dir,
# mode delete) that refuses anything but a git working copy. Sessions' worktrees usually sit
# inside the working copy, so before that the git agent fetches and lists what the delete would
# lose (gitctl unpushed: branches on no origin branch, uncommitted changes, stashes, and every
# worktree); any such work refuses the delete unless --even-unpushed is given too, and a list
# that cannot be had refuses it the same way.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

ARG="" DELETE_WC=0 EVEN_UNPUSHED=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) exec bash "$AIDC_SCRIPTS/cmd-repo.sh" --help ;;
        --delete-working-copy) DELETE_WC=1; shift ;;
        --even-unpushed) EVEN_UNPUSHED=1; shift ;;
        -*) die "aidc repo remove: unknown option $1" ;;
        *) [ -z "$ARG" ] || die "one repo at a time (got: $ARG and $1)"; ARG="$1"; shift ;;
    esac
done
[ -n "$ARG" ] || die "usage: aidc repo remove <path|owner/name> [--delete-working-copy [--even-unpushed]]"
[ "$EVEN_UNPUSHED" = 0 ] || [ "$DELETE_WC" = 1 ] || die "--even-unpushed goes with --delete-working-copy"
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
rc=0
pod=$(k8s_git_pod "$ns") || rc=$?
case "$rc" in
    0) ;;
    1) die "no running git container in ${ns}: run \`aidc git setup\` first" ;;
    *) die "cannot reach the git container: the cluster did not answer: ${pod#unknown }" ;;
esac

slug="" path=""
if printf '%s' "$ARG" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' && [ ! -d "$ARG" ]; then
    slug="$ARG"
    [ "$DELETE_WC" = 0 ] || die "--delete-working-copy needs the working copy's path, not owner/name"
else
    path=$(k8s_cluster_repo_path "$ARG") \
        || die "the path must be under your home directory (${HOME}) or /home/${AIDC_K8S_USER}: got ${ARG}"
    k8s_repo_path_ok "$path" || die "${path}: not a repo folder below /home/${AIDC_K8S_USER}"
    state=$(k8s_repo_state "$ns" "$pod" "$path")
    case "$state" in
        "repo https://github.com/"*)
            url="${state#repo }"; slug="${url#https://github.com/}"; slug="${slug%.git}" ;;
        repo*) die "${path}'s origin is not a GitHub repo (${state#repo }): the git container keeps no copy of it" ;;
        unknown*) die "cannot tell what is at ${path}: ${state#unknown }" ;;
        *) die "${path} is not a git working copy" ;;
    esac
fi

# Before anything is removed: what deleting the working copy would lose. Names and paths come
# from a disk sessions write, so control characters are stripped before they reach the terminal.
if [ -n "$path" ] && [ "$DELETE_WC" = 1 ]; then
    report=$(k8s_kubectl -n "$ns" exec "$pod" -c git -- gitctl unpushed "$path" </dev/null 2>&1) || true
    report=$(printf '%s\n' "$report" | k8s_printable)
    if [ "$(printf '%s\n' "$report" | tail -n1)" != end ]; then
        why=$(printf '%s\n' "$report" | tail -n1)
        [ "$EVEN_UNPUSHED" = 1 ] \
            || die "cannot tell whether ${path} holds unpushed work (${why}); nothing was removed. --even-unpushed deletes it without knowing"
        info "warning: cannot tell whether ${path} holds unpushed work (${why}); deleting it anyway (--even-unpushed)"
    else
        work="" trees=""
        while IFS= read -r line; do
            case "$line" in
                "branch "*) n="${line#branch }"; work+=$'\n'"  branch ${n#* }: ${n%% *} commit(s) on no origin branch" ;;
                "detached "*) n="${line#detached }"; work+=$'\n'"  ${n#* }: ${n%% *} commit(s) on a detached HEAD, on no origin branch" ;;
                "uncommitted "*) work+=$'\n'"  ${line#uncommitted }: uncommitted changes" ;;
                "stash "*) work+=$'\n'"  ${line#stash } stash(es)" ;;
                "worktree "*) trees+=$'\n'"  ${line#worktree }" ;;
            esac
        done <<<"$report"
        if [ -n "$work" ]; then
            [ -z "$trees" ] || work+=$'\n'"worktrees of it:${trees}"
            [ "$EVEN_UNPUSHED" = 1 ] \
                || die "${path} holds work that is not on GitHub; nothing was removed:${work}"$'\n'"Push it or drop it first, or add --even-unpushed to delete it anyway."
            info "warning: deleting work that is not on GitHub (--even-unpushed):${work}"
        elif [ -n "$trees" ]; then
            info "the worktrees in it go too (nothing unpushed or uncommitted in them):${trees}"
        fi
    fi
fi

k8s_kubectl -n "$ns" exec "$pod" -c git -- gitctl remove-copy "$slug" </dev/null >&2 \
    || die "the git container could not remove its copy of ${slug}"
if [ -n "$path" ]; then
    if [ "$DELETE_WC" = 1 ]; then
        sel=$(k8s_node_selector) || exit 1
        k8s_repo_dir_step "$ns" "$path" delete "$sel" >/dev/null || die "could not delete ${path}"
        info "deleted the working copy ${path}"
    else
        info "the working copy ${path} is kept, with the sessions' work in it (--delete-working-copy deletes it)"
    fi
fi
