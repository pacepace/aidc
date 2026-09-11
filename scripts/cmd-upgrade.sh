#!/usr/bin/env bash
# desc: Swap a session's dev container onto the latest local dev-base image.
#
# Usage: aidc upgrade <session> [--yes]
#
# Replaces ONLY the dev container of the named session against the current
# aidc/dev-base:${AIDC_VERSION_TAG} image. The proxy stack stays running
# (squid never blinks; audit aggregator keeps collecting; taint flag is
# preserved). The dev-home volume, workspace bind mount, Claude memory
# mount, audit dir, and pyenv-versions volume all survive.
#
# Adhoc port forwards (aidc proxy) are removed; re-add explicitly post-upgrade.
# Declared ports (--port at create time) survive.
#
# Adhoc network attachments (aidc network <s> add) are ALSO dropped, because
# the recreate below builds a new container and endpoints are container state.
# Note the asymmetry with `aidc restart`, which they survive. Declared networks
# (--network at create time) ride the compose file and come back.
#
# In-flight claude conversation IS interrupted -- the dev container is
# stopped mid-call. claude --continue re-attaches to the same conversation
# when the container comes back up.

set -euo pipefail

trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/network.sh
. "$AIDC_SCRIPTS/lib/network.sh"

NAME=""
YES=0

usage() {
    cat <<'EOF'
aidc upgrade <session> [--yes]

Swaps just the dev container of <session> onto the current aidc/dev-base
image. Proxy stack, dev-home, repo mount, memory, audit dir all survive.
Adhoc port forwards are removed (re-add via 'aidc proxy <session> add ...').
Adhoc network attachments are removed too (re-add via 'aidc network <session>
add ...'); declared --network attachments survive.
In-flight claude conversation is interrupted; claude --continue re-attaches.

Run 'aidc rebuild' first if you want the latest image content.

Use 'aidc restart <session>' instead for an in-place restart against the
SAME image (no version swap).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --yes) YES=1; shift ;;
        --*) die "unknown flag: $1" ;;
        *)
            if [ -z "$NAME" ]; then
                NAME="$1"; shift
            else
                die "unexpected positional argument: $1"
            fi ;;
    esac
done

[ -z "$NAME" ] && { usage >&2; exit 2; }

validate_session_name "$NAME"
require_docker
session_exists "$NAME" || die "no such session: $NAME"

DEV_CT="$(container_name "$NAME" dev)"
PROJECT="$(compose_project_name "$NAME")"
COMPOSE_FILE="/tmp/aidc-${NAME}.yaml"

[ -f "$COMPOSE_FILE" ] || die "rendered compose file not found at ${COMPOSE_FILE} (was the session created on this host? use 'aidc kill' + 'aidc create' instead)"

# Idempotency check: compare current dev container's image digest to the
# tag's digest. If equal, no work to do.
NEW_TAG="aidc/dev-base:${AIDC_VERSION_TAG}"
NEW_DIGEST=$(docker image inspect "$NEW_TAG" --format '{{.Id}}' 2>/dev/null || true)
if [ -z "$NEW_DIGEST" ]; then
    die "no local image found for ${NEW_TAG}; run 'aidc rebuild' first"
fi
OLD_DIGEST=$(docker inspect "$DEV_CT" --format '{{.Image}}' 2>/dev/null || true)
if [ -n "$OLD_DIGEST" ] && [ "$OLD_DIGEST" = "$NEW_DIGEST" ]; then
    info "${DEV_CT} is already on the current dev-base image (${NEW_DIGEST}); nothing to do"
    info "(use 'aidc restart ${NAME}' for an in-place restart)"
    exit 0
fi

# Pre-flight: warn about the in-flight conversation. Always print the summary;
# only prompt for confirmation if --yes was not passed.
printf '\n' >&2
printf 'This will interrupt %s:\n' "$DEV_CT" >&2
printf '  - any in-flight claude conversation tool call is aborted\n' >&2
printf '    (claude --continue re-attaches to the same conversation when the container comes back)\n' >&2
printf '  - adhoc port forwards (aidc proxy) are removed; re-add after upgrade\n' >&2
printf '  - declared ports (--port at create time) survive\n' >&2
# Adhoc network attachments live in the dev container's own config, so the
# recreate below drops them silently -- unlike `aidc restart`, which they
# survive. Name them here so the user knows what to re-add, rather than
# discovering it when the session can no longer reach a database.
ADHOC_NETS=$(aidc_adhoc_networks "$NAME" "$COMPOSE_FILE" 2>/dev/null || true)
if [ -n "$ADHOC_NETS" ]; then
    printf '  - adhoc network attachments (aidc network) are dropped; re-add after upgrade:\n' >&2
    printf '%s\n' "$ADHOC_NETS" | while IFS= read -r n; do
        [ -z "$n" ] && continue
        printf '        aidc network %s add %s\n' "$NAME" "$n" >&2
    done
fi
printf '  - declared networks (--network at create time) survive\n' >&2
printf '  - the proxy stack, dev-home volume, repo mount, memory, and audit dir all survive\n' >&2
# NET-14: upgrade re-uses the compose file rendered at create time, so a session
# created before v1.3.0 (or with --egress direct) keeps its NATed bridge. Say so
# here rather than let someone upgrade and assume they gained enforcement.
if [ "$(aidc_session_egress_mode "$NAME")" = "direct" ]; then
    printf '\n' >&2
    printf '  NOTE: this session'"'"'s egress is NOT enforced -- its bridge is NATed, so a\n' >&2
    printf '        process inside can bypass squid entirely (no blocklist, no taint).\n' >&2
    printf '        Upgrading does NOT change that: it reuses the compose file rendered\n' >&2
    printf '        at create time. To enforce, recreate the session instead:\n' >&2
    printf '            aidc kill %s && aidc create %s ...\n' "$NAME" "$NAME" >&2
fi
# A session created before the container owned its Claude login (v1.5.0) still
# carries the host's ~/.claude.json and .credentials.json bind mounts in its
# create-time compose file. The new image reads neither (CLAUDE_CONFIG_DIR),
# and only `create` seeds the onboarding state, so this session's first launch
# after the upgrade runs Claude's onboarding and then asks for /login. Say so;
# the seeded path is one kill + create away.
if grep -qE '/home/vscode/\.claude\.json:ro|/home/vscode/\.claude/\.credentials\.json' "$COMPOSE_FILE" 2>/dev/null; then
    printf '\n' >&2
    printf '  NOTE: this session was created before aidc v1.5.0, when Claude'"'"'s login was\n' >&2
    printf '        bridged from the host. The new image keeps Claude'"'"'s login inside the\n' >&2
    printf '        session instead and ignores those old mounts, so after this upgrade\n' >&2
    printf '        Claude runs its first-launch onboarding and then asks for /login.\n' >&2
    printf '        To skip onboarding (seeded from your host) recreate the session:\n' >&2
    printf '            aidc kill %s && aidc create %s ...\n' "$NAME" "$NAME" >&2
fi
printf '\n' >&2
printf '  current image: %s\n' "${OLD_DIGEST:-(unknown)}" >&2
printf '  new image:     %s (%s)\n' "$NEW_DIGEST" "$NEW_TAG" >&2
printf '\n' >&2

if [ "$YES" -ne 1 ]; then
    printf 'Proceed? [y/N] ' >&2
    REPLY=""
    read -r REPLY || true
    case "$REPLY" in
        y|Y) : ;;
        *) info "aborted"; exit 0 ;;
    esac
fi

# Remove adhoc forwards FIRST so stale forwards don't race with the recreate.
# (They'd be gone either way -- CLI-14 -- but removing up front keeps it clean.)
remove_adhoc_forwards "$NAME" "removing adhoc port-forwards (re-add via 'aidc proxy ${NAME} add ...' after upgrade)"

info "swapping ${DEV_CT} onto ${NEW_TAG}"
# `up -d --force-recreate --no-deps dev` is the atomic swap primitive:
#   --force-recreate    rebuild the dev container even if config looks fine
#   --no-deps           CRITICAL: do NOT also recreate squid/refresher/etc.
#                       even though dev depends_on them. Without --no-deps,
#                       compose detects that the proxy images' content has
#                       also changed (from a recent `aidc rebuild`) and would
#                       recreate them too -- breaking our "proxy stack
#                       untouched" guarantee. The proxy stack only gets
#                       replaced via `aidc kill && aidc create`.
if ! docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d --force-recreate --no-deps dev >/dev/null 2>&1; then
    die "docker compose up --force-recreate dev failed; check 'docker logs ${DEV_CT}'"
fi

# Wait for the new dev container's user-main ready marker.
info "waiting for ${DEV_CT} setup to finish..."
if ! wait_for_dev_ready "$NAME"; then
    die "dev container did not become ready in time; check 'docker logs ${DEV_CT}'"
fi

info "upgraded ${DEV_CT} to ${NEW_TAG}"
info "  attach with: aidc attach ${NAME}"
