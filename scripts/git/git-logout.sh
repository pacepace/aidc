#!/usr/bin/env bash
# aidc git logout: the git container's GitHub login and commit identity are removed.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
[ $# -eq 0 ] || die "aidc git logout takes no arguments (got: $*)"
gb_require
gb_target
gb_exec gitctl logout
