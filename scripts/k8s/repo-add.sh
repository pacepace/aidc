#!/usr/bin/env bash
# aidc repo add <github-url|owner/name> [--path P]: the user's git container clones a GitHub
# repo onto the user's disk (docs/design-12-kubernetes.md, "Git").
#
# First the repo goes on the user's list of added repos (the git-repos ConfigMap, written from
# here with the user's kubectl, mounted read-only in the git pod: lib.sh, k8s_git_repos_*), and
# this waits until the git pod sees it there: gitrun copies no repo off that list, whoever asks,
# so the agent's own gitctl clone adds nothing. Then three steps. A one-shot root pod makes the
# repo folder and gives it to the git container's agent (only root can, on the session user's disk; manifests.sh, k8s_render_repo_dir). Then
# `gitctl clone`: gitrun fetches the repo into its private copy and hands the agent a bundle,
# which the agent clones from, as itself (gitrun never writes a working copy). Last, another
# one-shot pod gives the working copy to the session user, group-shared with the agent: an
# ordinary repo, in which sessions make their own worktrees and branches (owner rulings
# 2026-11-24).

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

SRC="" PATH_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) exec bash "$AIDC_SCRIPTS/cmd-repo.sh" --help ;;
        --path) [ $# -ge 2 ] || die "--path needs a value"; PATH_ARG="$2"; shift 2 ;;
        --path=*) PATH_ARG="${1#--path=}"; shift ;;
        -*) die "aidc repo add: unknown option $1" ;;
        *) [ -z "$SRC" ] || die "one repo at a time (got: $SRC and $1)"; SRC="$1"; shift ;;
    esac
done
[ -n "$SRC" ] || die "usage: aidc repo add <github-url|owner/name> [--path P]"

# owner/name from the forms a user copies from GitHub. Only GitHub, and only one repo: the
# git container's origin is always https://github.com/<owner>/<name>.
slug="$SRC"
case "$slug" in
    https://github.com/*) slug="${slug#https://github.com/}" ;;
    git@github.com:*) slug="${slug#git@github.com:}" ;;
    ssh://git@github.com/*) slug="${slug#ssh://git@github.com/}" ;;
    *://*|*@*) die "${SRC}: not a GitHub repo (https://github.com/<owner>/<name> or owner/name)" ;;
esac
slug="${slug%/}"; slug="${slug%.git}"
name="${slug#*/}"
if ! printf '%s' "$slug" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' || [ "$name" = . ] || [ "$name" = .. ]; then
    die "${SRC}: not a GitHub repo (https://github.com/<owner>/<name> or owner/name)"
fi

k8s_require || exit 1
if [ -n "$PATH_ARG" ]; then
    path=$(k8s_cluster_repo_path "$PATH_ARG") \
        || die "the path must be under your home directory (${HOME}) or /home/${AIDC_K8S_USER}: got ${PATH_ARG}"
else
    path="/home/${AIDC_K8S_USER}/${name}"
fi
k8s_repo_path_ok "$path" \
    || die "${path}: a repo goes in a folder below /home/${AIDC_K8S_USER}, named with letters, digits, '.', '_' and '-' only"

ns=$(k8s_user_ns "$AIDC_K8S_USER")
rc=0
pod=$(k8s_git_pod "$ns") || rc=$?
case "$rc" in
    0) ;;
    1) die "no running git container in ${ns}: run \`aidc git setup\` first" ;;
    *) die "cannot reach the git container: the cluster did not answer: ${pod#unknown }" ;;
esac

# list_repo: put the repo on the user's list and wait until the git pod sees it there.
# LISTED_HERE=1 when it was not on it before (a failed clone takes it off again).
LISTED_HERE=0
list_repo() {
    k8s_git_repos_read "$ns" || exit 1
    printf '%s\n' "$K8S_GIT_REPOS" | grep -qixF -- "$slug" || LISTED_HERE=1
    k8s_git_repos_change "$ns" add "$slug" || exit 1
    info "waiting for the git container to see ${slug} on the list of added repos (up to ${AIDC_K8S_GIT_REPOS_WAIT:-180}s)"
    if ! k8s_git_repos_wait "$ns" "$pod" "$slug"; then
        unlist_repo
        die "the git container does not see ${slug} on the list of added repos yet (is it set up with this aidc? aidc git setup); run aidc repo add again"
    fi
}
unlist_repo() {
    [ "$LISTED_HERE" = 1 ] || return 0
    k8s_git_repos_change "$ns" remove "$slug" || info "warning: ${slug} is still on the list of added repos (aidc repo remove ${slug})"
}

state=$(k8s_repo_state "$ns" "$pod" "$path")
case "$state" in
    "repo $(printf 'https://github.com/%s' "$slug")"|"repo $(printf 'https://github.com/%s.git' "$slug")")
        # Already there (added earlier, or before the list existed): make sure it is listed and
        # gitrun holds its copy (gitctl adopt reads the working copy's origin, changes nothing).
        list_repo
        k8s_kubectl -n "$ns" exec "$pod" -c git -- gitctl adopt "$path" </dev/null >&2 \
            || die "${path} is a working copy of ${slug}, but the git container could not take it (a private repo needs its GitHub login: aidc git attach, then gitctl login)"
        info "${path} is already a working copy of ${slug} (aidc repo list)"; exit 0 ;;
    repo*) die "${path} is already a git working copy, of ${state#repo }" ;;
    folder) die "${path} is not empty" ;;
    empty) ;;
    *) die "cannot tell what is at ${path}: ${state#unknown }" ;;
esac
list_repo

# The folder, given to the git container's agent while it clones, then to the session user.
sel=$(k8s_node_selector) || exit 1
info "making ${path} for the git container"
k8s_repo_dir_step "$ns" "$path" make "$sel" >/dev/null || { unlist_repo; die "could not make ${path}"; }
info "cloning https://github.com/${slug} into ${path} (through the git container's private copy)"
if ! k8s_kubectl -n "$ns" exec "$pod" -c git -- gitctl clone "$slug" "$path" </dev/null >&2; then
    k8s_repo_dir_step "$ns" "$path" own "$sel" >/dev/null || true
    unlist_repo
    die "the git container could not clone ${slug} (a private repo needs its GitHub login: aidc git attach, then gitctl login)"
fi
k8s_repo_dir_step "$ns" "$path" own "$sel" >/dev/null \
    || die "cloned, but ${path} could not be given to the session user; run aidc repo add again to retry"
info "added ${slug} at ${path}. Sessions see it on the disk; one works on it in its own worktree:"
info "  git -C ${path} worktree add -b <branch> ${path}/<folder> origin/HEAD"
