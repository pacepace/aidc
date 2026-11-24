#!/usr/bin/env bash
# aidc repo list: the GitHub working copies on the user's disk (the repos the git container
# can fetch and push for): path, origin, and the branch checked out.
#
# A container that cannot be asked is never reported as "no repos".

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-repo.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc repo list takes no arguments (got: $*)"
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
rc=0
pod=$(k8s_git_pod "$ns") || rc=$?
case "$rc" in
    0) ;;
    1) die "no running git container in ${ns}: run \`aidc git setup\` (repos are unknown until it runs)" ;;
    *) die "cannot reach the git container: the cluster did not answer: ${pod#unknown }" ;;
esac

# One exec. Each repo is a line "repo=<path>\t<origin>\t<branch>": only lines the script
# printed count, and the list ends with "end", so an exec cut short is not a short list.
# Worktrees (a .git file, not a folder) are not listed: they belong to their repo.
# shellcheck disable=SC2016  # expanded by the container's shell
out=$(k8s_kubectl -n "$ns" exec "$pod" -c git -- sh -c '
    find "$1" -maxdepth 6 -type d -name .git -prune -print 2>/dev/null | sort |
    while IFS= read -r g; do
        o=$(git config --file "$g/config" --get remote.origin.url 2>/dev/null) || continue
        case "$o" in https://github.com/*) ;; *) continue ;; esac
        b=$(sed -n "s|^ref: refs/heads/||p" "$g/HEAD" 2>/dev/null)
        printf "repo=%s\t%s\t%s\n" "${g%/.git}" "$o" "${b:--}"
    done
    echo end' sh "/home/${AIDC_K8S_USER}" </dev/null 2>/dev/null || true)
if ! printf '%s\n' "$out" | grep -qx end; then
    die "unknown: the git container did not answer"
fi
rows=$(printf '%s\n' "$out" | sed -n 's/^repo=//p')
if [ -z "$rows" ]; then
    info "no repos yet (aidc repo add <owner/name>)"
    exit 0
fi
printf '%-36s %-48s %s\n' REPO ORIGIN BRANCH
while IFS=$'\t' read -r r o l; do
    printf '%-36s %-48s %s\n' "$r" "$o" "$l"
done <<<"$rows"
