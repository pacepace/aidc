#!/usr/bin/env bash
# aidc git login: the git container's GitHub login, as the user (owner ruling 2026-11-24): gh's
# device code, approved in the user's browser, kept where only gitcred can read it; then the
# identity every commit made there carries (the user's GitHub name and email). Interactive.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc git login takes no arguments (got: $*)"
k8s_require || exit 1
k8s_git_target
info "logging the git container in to GitHub: copy the one-time code, open the address and approve it"
k8s_kubectl -n "$GIT_NS" exec -it "$GIT_POD" -c git -- env TERM="${TERM:-xterm-256color}" gitctl login
