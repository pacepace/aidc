#!/usr/bin/env bash
# aidc repo remove <path|owner/name> (Docker): the git container forgets a working copy: gitrun's
# private copy of its GitHub repo is deleted (so copies do not pile up in its store) and the
# working copy is no longer mounted. The working copy itself is the user's own and is never
# deleted here.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) exec bash "$AIDC_SCRIPTS/cmd-repo.sh" --help ;;
        --delete-working-copy|--even-unpushed) die "on Docker the working copy is your own: aidc repo remove never deletes it (delete it yourself)" ;;
        -*) die "aidc repo remove: unknown option $1" ;;
        *) [ -z "$ARG" ] || die "one repo at a time (got: $ARG and $1)"; ARG="$1"; shift ;;
    esac
done
[ -n "$ARG" ] || die "usage: aidc repo remove <path|owner/name>"
f=$(dk_git_repos_file)
paths="" slug=""
if printf '%s' "$ARG" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' && [ ! -d "$ARG" ]; then
    slug="$ARG"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        s=$(dk_git_slug "$(dk_git_origin "$r" || true)" || true)
        [ "${s,,}" = "${slug,,}" ] && paths+="${r}"$'\n'
    done < <(dk_git_repos)
else
    p=$(realpath_portable "$(translate_wsl_path "$ARG")" 2>/dev/null || printf '%s' "$ARG")
    dk_git_repos | grep -qxF -- "$p" || die "${p} is not a working copy the git container works on (aidc repo list)"
    paths="${p}"$'\n'
    if [ -d "$p/.git" ]; then slug=$(dk_git_slug "$(dk_git_origin "$p" || true)" || true); fi
fi
dk_git_target
if [ -n "$slug" ]; then
    dk_git_exec gitctl remove-copy "$slug" >&2 || die "the git container could not remove its copy of ${slug}"
else
    info "cannot tell ${ARG}'s GitHub repo (the working copy is gone or its origin changed): its private copy, if any, is left (gitctl remove-copy <owner/name>)"
fi
if [ -n "$paths" ]; then
    { grep -vxF -f <(printf '%s' "$paths") "$f" || true; } > "${f}.tmp"
    mv -f "${f}.tmp" "$f"
    info "unmounting $(printf '%s' "$paths" | tr '\n' ' ')from the git container (it restarts)"
    dk_git_start
fi
info "removed${slug:+ ${slug}}; your working copy is left as it is"
