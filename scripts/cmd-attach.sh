#!/usr/bin/env bash
# desc: Attach to a session's tmux inside the dev container.
#
# Usage: aidc attach <name>

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
aidc attach <name>

Attach to the session's tmux (window 0 runs claude). Other clients are
detached so terminal size doesn't fight.
EOF
        exit 0 ;;
esac

NAME="${1:-}"
validate_session_name "$NAME"
require_docker
session_exists "$NAME" || die "no such session: $NAME"

DEV="$(container_name "$NAME" dev)"

# `tmux attach -t main` reuses the long-lived session started by
# aidc-tmux-start.sh. -d detaches other clients so multiple attaches
# don't fight for terminal size.
#
# -u vscode: the container's entrypoint drops privileges to vscode before
# starting tmux, so the tmux socket lives in /tmp/tmux-1000/. docker exec
# without -u runs as the container's USER (root by default in our image),
# which can't see vscode's socket.
exec docker exec -it -u vscode "$DEV" tmux attach -d -t main
