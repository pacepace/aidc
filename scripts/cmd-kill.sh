#!/usr/bin/env bash
# desc: Tear down a session; preserve its audit dir.
#
# Usage: aidc kill <name>
#
# Order matters:
#   1. Pause the dev container -- freeze further outbound activity.
#   2. Best-effort finalize the audit sidecar so meta.json gets killed_at.
#   3. `docker compose down -v` to remove containers, networks, anonymous
#      volumes. Named volumes labelled aidc-* go too.
#   4. Force-remove the dev container if it lingered (rare; defensive).

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

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
session_exists "$NAME" || die "no such session: $NAME"

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

# Adhoc port-forward sidecars (aidc-${NAME}-fwd-*) run outside the compose
# project, so compose-down doesn't touch them. Sweep here.
remove_adhoc_forwards "$NAME" "cleaning up adhoc port-forwards"

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

if [ -n "$AUDIT_HOST" ]; then
    printf "Session '%s' killed. Audit preserved at %s\n" "$NAME" "$AUDIT_HOST"
else
    printf "Session '%s' killed.\n" "$NAME"
fi
