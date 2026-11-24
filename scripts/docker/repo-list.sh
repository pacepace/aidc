#!/usr/bin/env bash
# aidc repo list (Docker): the working copies the git container works on: path, origin, the
# branch checked out. Read here, from the working copies themselves; one that is gone is said so.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-repo.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc repo list takes no arguments (got: $*)"
repos=$(dk_git_repos)
if [ -z "$repos" ]; then
    info "no repos yet (aidc repo add <path of a working copy>)"
    exit 0
fi
printf '%-36s %-48s %s\n' REPO ORIGIN BRANCH
while IFS= read -r r; do
    if [ ! -d "$r/.git" ]; then
        printf '%-36s %-48s %s\n' "$r" "(gone: aidc repo remove $r)" -
        continue
    fi
    o=$(dk_git_origin "$r" || echo '?')
    b=$(sed -n 's|^ref: refs/heads/||p' "$r/.git/HEAD" 2>/dev/null)
    printf '%-36s %-48s %s\n' "$r" "$o" "${b:--}"
done <<<"$repos" | aidc_printable
