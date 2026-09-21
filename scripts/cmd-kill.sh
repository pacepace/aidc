#!/usr/bin/env bash
# desc: Tear down a session; preserve its audit dir.
#
# Usage: aidc kill <name>
#
# Order matters:
#   1. Pause the dev container -- freeze further outbound activity.
#   2. Best-effort finalize the audit sidecar so meta.json gets killed_at.
#   3. Remove adhoc port-forwarders and live TCP egress relays: they are attached to
#      the session's networks, and compose cannot remove a network something outside
#      it still uses.
#   4. `docker compose down -v` to remove containers, networks, anonymous
#      volumes. Named volumes labelled aidc-* go too.
#   5. Force-remove the dev container if it lingered (rare; defensive).
#   6. Make sure the session's networks are gone. aidc-mcp tells sessions apart by
#      the network's id, so a leftover one would outlive the session there.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/egress.sh
. "$AIDC_SCRIPTS/lib/egress.sh"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
aidc kill <name>

Tear down a session (proxy stack + dev container) and preserve its audit dir.
Pauses the dev container, finalizes the audit sidecar (stamps killed_at),
runs `docker compose down -v`, and sweeps any adhoc port-forwards / overlay
volumes that escaped compose.
EOF
        exit 0 ;;
esac

NAME="${1:-}"
validate_session_name "$NAME"
require_docker
aidc_retire_auth_bridge
if ! session_exists "$NAME"; then
    # No containers, but a network may be left over (from a kill that could not remove
    # it). aidc-mcp still counts the session as alive while it exists, so remove it.
    if docker network inspect "aidc-${NAME}-net" >/dev/null 2>&1 \
            || docker network inspect "aidc-${NAME}-egress" >/dev/null 2>&1; then
        remove_session_networks "$NAME" || \
            die "could not remove the leftover network(s) of '${NAME}'; remove by hand: docker network rm aidc-${NAME}-net aidc-${NAME}-egress"
        printf "Session '%s' had no containers left; removed its leftover network(s).\n" "$NAME"
        exit 0
    fi
    die "no such session: $NAME"
fi

DEV="$(container_name "$NAME" dev)"
AUDIT_CT="$(container_name "$NAME" audit)"
PROJECT="$(compose_project_name "$NAME")"
COMPOSE_FILE="/tmp/aidc-${NAME}.yaml"

# Recover the audit dir for the final message. The audit container has it
# mounted at /var/aidc/audit; ask Docker rather than re-deriving from config.
AUDIT_HOST=""
if docker inspect "$AUDIT_CT" >/dev/null 2>&1; then
    AUDIT_HOST=$(docker inspect "$AUDIT_CT" \
        --format '{{range .Mounts}}{{if eq .Destination "/var/aidc/audit"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null || printf '')
fi

info "pausing $DEV"
docker pause "$DEV" >/dev/null 2>&1 || true

info "finalizing audit (best-effort)"
docker exec "$AUDIT_CT" /usr/local/bin/finalize.sh >/dev/null 2>&1 || \
    info "audit finalize failed or audit container not running (continuing)"

# Adhoc port-forward sidecars (aidc-${NAME}-fwd-*) run outside the compose
# project, so compose-down doesn't touch them, and they are attached to the
# session's networks, so they must go first or those networks survive the down.
remove_adhoc_forwards "$NAME" "cleaning up adhoc port-forwards"
# Live TCP egress relays (`aidc egress add`) are outside the project and on its
# networks for the same reason.
aidc_egress_remove_adhoc "$NAME" "cleaning up live TCP egress relays"

# `docker compose down` needs the file we rendered at create time. If it's
# gone (e.g. /tmp cleared), `-p $PROJECT` with no file still works for
# stop+rm of named containers but won't catch volumes; try both.
info "stopping compose project $PROJECT"
if [ -f "$COMPOSE_FILE" ]; then
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans
else
    docker compose -p "$PROJECT" down -v --remove-orphans || true
fi

# Defensive cleanup: if anything escaped compose, kill it by container name.
for role in dev squid refresher policy audit; do
    ct="$(container_name "$NAME" "$role")"
    docker rm -f "$ct" >/dev/null 2>&1 || true
done

# Container-only-path overlay volumes (aidc-sovl-${NAME}-*) are normally
# declared in the rendered compose, so `docker compose down -v` removes
# them. Defensive sweep here for the case where a session died mid-create
# before compose tracked them.
sovl_vols=$(docker volume ls --filter "name=aidc-sovl-${NAME}-" -q 2>/dev/null || true)
if [ -n "$sovl_vols" ]; then
    info "cleaning up container-only-path overlay volumes"
    printf '%s\n' "$sovl_vols" | xargs docker volume rm >/dev/null 2>&1 || true
fi

# Drop the rendered compose file.
rm -f "$COMPOSE_FILE"

# Anything else still attached (another session joined with `aidc network`) keeps a
# network alive past the down; detach it and remove the network, or say so loudly.
remove_session_networks "$NAME" || \
    die "session '${NAME}' is down but its network remains, so aidc-mcp still treats it as a live session. Remove it by hand: docker network rm aidc-${NAME}-net aidc-${NAME}-egress"

if [ -n "$AUDIT_HOST" ]; then
    printf "Session '%s' killed. Audit preserved at %s\n" "$NAME" "$AUDIT_HOST"
else
    printf "Session '%s' killed.\n" "$NAME"
fi
