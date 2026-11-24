#!/usr/bin/env bash
# aidc repo add <path> (Docker): one of the user's own working copies on this machine becomes one
# the git container pushes for (owner ruling 2026-11-24: on Docker it works on the user's own
# working copies; it does not clone, lock or re-own them). The path is recorded in
# ~/.config/aidc/git-repos, the git container is started again with it mounted at the same path
# (the one sessions see), its GitHub repo is put on the list of added repos (mounted read-only in
# the git container: lib.sh, dk_git_added), and gitctl adopts it: gitrun makes its private copy
# of the GitHub repo, which every verb on the repo then requires. gitrun copies no repo off that
# list, whoever asks. The working copy is only read.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-repo.sh" --help ;; esac
[ $# -eq 1 ] || die "usage: aidc repo add <path of a working copy> (on Docker the git container works on your own working copies)"
case "$1" in
    https://*|http://*|*@*:*|ssh://*) die "${1}: on Docker the git container works on your own working copies: clone it yourself, then aidc repo add <its path>" ;;
esac
p=$(translate_wsl_path "$1")
[ -d "$p" ] || die "${1}: no such folder"
p=$(realpath_portable "$p") || die "${1}: no such folder"
dk_git_path_ok "$p" \
    || die "${p}: a working copy the git container works on is below your home ($(dk_git_disk)), named with letters, digits, '.', '_' and '-' only"
{ [ -d "$p/.git" ] && [ ! -L "$p/.git" ]; } || die "${p} is not a working copy (no .git folder; add the main working copy, not a worktree)"
url=$(dk_git_origin "$p") || die "${p} has no origin remote"
slug=$(dk_git_slug "$url") || die "${p}'s origin is ${url}: the git container works only with https://github.com/<owner>/<name>. To keep pushing over SSH yourself: git -C ${p} remote set-url origin https://github.com/<owner>/<name> && git -C ${p} remote set-url --push origin <your ssh url>"
dk_git_target

# The repo goes on the list before the adopt (a list the container reads at once: its folder is
# mounted); a failed add takes a new entry off again.
listed_here=0
dk_git_added | grep -qxF -- "${slug,,}" || listed_here=1
dk_git_added_change add "$slug" || die "could not put ${slug} on the list of added repos"
f=$(dk_git_repos_file)
mounted_here=0
if dk_git_repos | grep -qxF -- "$p"; then
    info "${p} (${slug}) is already added; checking the git container's copy"
else
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$p" >> "$f"
    mounted_here=1
    info "mounting ${p} into the git container (it restarts)"
    dk_git_start
fi
if ! dk_git_exec gitctl adopt "$p" 2>&1 | aidc_printable >&2; then
    [ "$listed_here" = 0 ] || dk_git_added_change remove "$slug" || true
    # Only what this run added is undone: a working copy added before stays mounted.
    if [ "$mounted_here" = 1 ]; then
        info "the git container could not take ${slug}; forgetting ${p} again"
        grep -vxF -- "$p" "$f" > "${f}.tmp" || true
        mv -f "${f}.tmp" "$f"
        dk_git_start
    fi
    die "${slug} was not added (a private repo needs the git container's GitHub login: aidc git login; a container set up before the list of added repos: aidc git setup)"
fi
info "added ${p} (${slug}). Sessions created on it (or a workspace holding it) ask with gh pr create;"
info "their worktrees must be inside it: git -C ${p} worktree add -b <branch> ${p}/<folder> origin/HEAD"
