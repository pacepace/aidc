#!/usr/bin/env bash
# desc: Force an on-demand blocklist refresh for a session.
#
# Usage: aidc refresh <name>
#
# Invokes the refresher sidecar's one-shot refresh.sh, which re-pulls the
# upstream feeds, merges with per-project blocklist_additions, and atomically
# rewrites /etc/squid/blocklist.txt. Squid picks it up without a reload (NET-16).

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
aidc refresh <name>

Force an on-demand blocklist refresh for the session: the refresher sidecar
re-pulls the upstream feeds, merges blocklist_additions, and atomically rewrites
/etc/squid/blocklist.txt. Squid's lookup helper uses the new list at once; nothing
reloads, and no connection drops.
EOF
        exit 0 ;;
esac

NAME="${1:-}"
validate_session_name "$NAME"
require_docker
session_exists "$NAME" || die "no such session: $NAME"

REFRESHER="$(container_name "$NAME" refresher)"
exec docker exec "$REFRESHER" /usr/local/bin/refresh.sh
