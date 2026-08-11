#!/usr/bin/env bash
# desc: Tail logs for a session component (default: dev).
#
# Usage: aidc logs <name> [--component dev|squid|refresher|policy|audit] [--follow]

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

NAME=""
COMPONENT="dev"
FOLLOW=0

while [ $# -gt 0 ]; do
    case "$1" in
        --component)
            [ $# -ge 2 ] || die "--component requires a value"
            COMPONENT="$2"; shift 2 ;;
        --component=*) COMPONENT="${1#--component=}"; shift ;;
        --follow|-f)   FOLLOW=1; shift ;;
        -h|--help)
            cat <<'EOF'
aidc logs <name> [--component dev|squid|refresher|policy|audit] [--follow]
EOF
            exit 0 ;;
        --*) die "unknown flag: $1" ;;
        *)
            if [ -z "$NAME" ]; then
                NAME="$1"; shift
            else
                die "unexpected positional argument: $1"
            fi ;;
    esac
done

validate_session_name "$NAME"
case "$COMPONENT" in
    dev|squid|refresher|policy|audit) : ;;
    *) die "unknown component: $COMPONENT" ;;
esac
require_docker
session_exists "$NAME" || die "no such session: $NAME"

CT="$(container_name "$NAME" "$COMPONENT")"
if [ "$FOLLOW" -eq 1 ]; then
    exec docker logs -f "$CT"
else
    exec docker logs "$CT"
fi
