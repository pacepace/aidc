#!/usr/bin/env bash
# desc: Restart a session's dev container in place. Faster than kill+create; preserves memory.
#
# Usage: aidc restart <name>
#
# Restarts ONLY the dev container. The proxy stack (squid, refresher, policy,
# audit) keeps running. The dev-home volume + repo bind-mount + memory bind-mount
# all persist, so Claude can pick up where it left off via --continue (default
# for the aidc-claude wrapper).
#
# Use when:
#   - Claude got into a weird state
#   - You want a fresh shell + restarted dockerd inside the dev container
#   - You changed settings.json on the host and want the container to re-read it
#     (the container's own ~/.claude.json and login live on the dev-home volume
#     and survive a restart untouched)
#
# Use `aidc kill` + `aidc create` instead when you want a fresh image (after
# rebuilding it) or when you want to drop the dev-home volume entirely.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
aidc restart <name>

Restart ONLY the dev container in place; the proxy stack keeps running. Faster
than kill+create and preserves memory (claude --continue resumes). Adhoc port
forwards are dropped (re-add via 'aidc proxy <name> add ...'); declared --port
forwards ride the compose stack and come back.

Network attachments (aidc network / --network) all survive: this restarts the
container rather than recreating it, and endpoints are container state.

Use 'aidc upgrade <name>' to swap onto a freshly rebuilt image instead.
EOF
        exit 0 ;;
esac

NAME="${1:-}"
validate_session_name "$NAME"
require_docker
session_exists "$NAME" || die "no such session: $NAME"

DEV="$(container_name "$NAME" dev)"

# Adhoc port forwards must NOT survive restart (per CLI-14). The user
# re-adds them explicitly after the container is back. Declared ports
# (CLI-13) ride in compose and come back automatically.
remove_adhoc_forwards "$NAME" "removing adhoc port-forwards (re-add via 'aidc proxy ${NAME} add ...' after restart)"

info "restarting $DEV"
docker restart "$DEV" >/dev/null

# Wait briefly for tmux to come back up after entrypoint runs.
i=0
while [ $i -lt 20 ]; do
    if docker exec -u vscode "$DEV" tmux has-session -t main 2>/dev/null; then
        info "tmux session 'main' is back; aidc-claude (with --continue) should be running in window 0"
        info "attach with: aidc attach $NAME"
        exit 0
    fi
    i=$((i + 1))
    sleep 0.5
done
err "tmux didn't come back up within 10s; check: docker logs $DEV"
exit 1
