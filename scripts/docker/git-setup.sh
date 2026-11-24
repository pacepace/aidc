#!/usr/bin/env bash
# aidc git setup (Docker): the user's git container on this machine (scripts/docker/lib.sh says
# what it is made of). Idempotent: volumes, which hold the user's secrets and gitrun's copies,
# are never recreated; the proxy and the container are recreated, so they run the current
# image and settings (a request running then is reported to its session as interrupted).

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"

case "${1:-}" in -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;; esac
[ $# -eq 0 ] || die "aidc git setup takes no arguments (got: $*)"
require_docker
dk_git_settings
disk=$(dk_git_disk)
dk_git_path_ok "${disk}/x" \
    || die "your home (${disk}) is not a path of letters, digits, '.', '_' and '-': the git container cannot take requests from it"

ensure_image gitctl
ensure_image squid

for v in $DK_GIT_VOLUMES; do
    docker volume inspect "$v" >/dev/null 2>&1 \
        || docker volume create --label aidc.git=volume "$v" >/dev/null || die "could not create the volume ${v}"
done
dk_git_seed || die "could not prepare the git container's volumes"

# The MCP server's transcript folder for the git agent: an orchestrator reads its questions
# there like any session's.
transcripts=$(dk_git_transcripts_dir)
aidc_mkdir_host "$transcripts" || die "cannot make ${transcripts}"
dk_git_own_transcripts "$transcripts" || die "could not give ${transcripts} to the git container"

# Its networks: an internal one (no route out) shared with the proxy only, and the proxy's own
# way out. Made once; kept while the container is recreated.
if ! docker network inspect "$DK_GIT_NET" >/dev/null 2>&1; then
    docker network create --internal --label "aidc.session=${DK_GIT_SESSION}" "$DK_GIT_NET" >/dev/null \
        || die "could not create the network ${DK_GIT_NET}"
fi
[ "$(docker network inspect -f '{{.Internal}}' "$DK_GIT_NET" 2>/dev/null)" = true ] \
    || die "${DK_GIT_NET} exists and is not internal: remove it (docker network rm ${DK_GIT_NET}) and run aidc git setup again"
if ! docker network inspect "$DK_GIT_EGRESS" >/dev/null 2>&1; then
    docker network create --label "aidc.session=${DK_GIT_SESSION}" "$DK_GIT_EGRESS" >/dev/null \
        || die "could not create the network ${DK_GIT_EGRESS}"
fi

info "starting the git container's proxy (public addresses only)"
docker rm -f "$DK_GIT_PROXY" >/dev/null 2>&1 || true
docker run -d --name "$DK_GIT_PROXY" --restart unless-stopped --network "$DK_GIT_EGRESS" \
    --label "aidc.session=${DK_GIT_SESSION}" --label aidc.role=squid --label aidc.git=proxy \
    -e AIDC_PUBLIC_ONLY=1 \
    --health-cmd /usr/local/bin/healthcheck.sh --health-interval 5s --health-timeout 3s \
    --health-retries 5 --health-start-period 10s \
    "aidc/squid:${AIDC_VERSION_TAG}" >/dev/null || die "could not start the git container's proxy"
docker network connect --alias aidc-proxy "$DK_GIT_NET" "$DK_GIT_PROXY" \
    || die "could not attach the proxy to ${DK_GIT_NET}"
ok=0
for _ in $(seq 60); do
    case "$(docker inspect -f '{{.State.Health.Status}}' "$DK_GIT_PROXY" 2>/dev/null)" in
        healthy) ok=1; break ;;
        unhealthy) break ;;
    esac
    sleep 1
done
[ "$ok" = 1 ] || die "the git container's proxy did not become healthy; see: docker logs ${DK_GIT_PROXY}"

info "starting the git container (${DK_GIT_CT}; git mode ${AIDC_DK_GIT_MODE})"
dk_git_start
n=$(dk_git_repos | grep -c . || true)
info "the git container is ready, with ${n} working cop$([ "$n" = 1 ] && echo y || echo ies) added (aidc repo list)."
info "Next: \`aidc git login\` (a device code you approve in your browser); add the working copies"
info "it pushes for with \`aidc repo add <path>\`. Sessions created from now on can ask it with gh pr create;"
info "a session created before this has no request folder: create it again to give it one."
