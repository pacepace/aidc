#!/usr/bin/env bash
# aidc git login: the git container's GitHub login, as the user (owner ruling 2026-11-24): gh's
# device code, approved in the user's browser, kept where only gitcred can read it; then the
# identity every commit made there carries (the user's GitHub name and email). Interactive.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -eq 0 ] || die "aidc git login takes no arguments (got: $*)"
gb_require
gb_target
info "logging the git container in to GitHub: copy the one-time code, open the address and approve it"
gb_exec_tty gitctl login
