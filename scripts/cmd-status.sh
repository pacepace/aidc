#!/usr/bin/env bash
# desc: Show overall or per-session status.
#
# Usage: aidc status [<name>]
#
# - No arg : pass through to `aidc list` and emit a one-line summary.
# - With arg: detailed per-session report (component health, recent logs,
#             taint detail).

set -euo pipefail

# Status output is often consumed by pipes that early-exit -- `grep -q`,
# `head`, `less` and similar close stdin mid-stream. We:
#   1. Ignore SIGPIPE so the script doesn't die when grep -q quits early.
#   2. Disable set -e / pipefail BEFORE the output phase so a printf to a
#      closed pipe (which returns EPIPE -> non-zero) doesn't kill the
#      script and bubble up as a spurious failure to whatever's piping.
# Validation phase keeps strict mode.
trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/network.sh
. "$AIDC_SCRIPTS/lib/network.sh"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
aidc status [<name>]

No arg   pass through to `aidc list` plus a session count.
<name>   detailed per-session report: component health, taint status,
         declared + adhoc port forwards, and the last few dev-container logs.
EOF
        exit 0 ;;
esac

NAME="${1:-}"

require_docker

if [ -z "$NAME" ]; then
    bash "$AIDC_SCRIPTS/cmd-list.sh"
    count=$(docker ps -a --filter 'label=aidc.role=dev' -q 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" = "0" ]; then
        count=$(docker ps -a --filter 'name=^aidc-.*-dev$' -q 2>/dev/null | wc -l | tr -d ' ')
    fi
    printf '\nTotal sessions: %s\n' "$count"
    exit 0
fi

validate_session_name "$NAME"
session_exists "$NAME" || die "no such session: $NAME"

# Strict-mode work is done; from here on we're producing output that the
# caller may pipe through grep -q / head / less. Relax -e and pipefail so
# a closed-stdin consumer doesn't cause a spurious failure on subsequent
# writes.
set +e
set +o pipefail

printf '== aidc session: %s ==\n\n' "$NAME"

for role in squid refresher policy audit dev; do
    ct="$(container_name "$NAME" "$role")"
    if ! docker inspect "$ct" >/dev/null 2>&1; then
        printf '%-10s  (no container)\n' "$role"
        continue
    fi
    state=$(docker inspect --format '{{.State.Status}}' "$ct" 2>/dev/null || printf '?')
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$ct" 2>/dev/null || printf '-')
    started=$(docker inspect --format '{{.State.StartedAt}}' "$ct" 2>/dev/null || printf '?')
    printf '%-10s  state=%s  health=%s  started=%s\n' "$role" "$state" "$health" "$started"
done

# Taint detail.
POLICY_CT="$(container_name "$NAME" policy)"
printf '\n-- taint status --\n'
if docker exec "$POLICY_CT" test -f /var/state/tainted >/dev/null 2>&1; then
    printf 'TAINTED.\n'
    docker exec "$POLICY_CT" cat /var/state/tainted 2>/dev/null || true
else
    printf 'clean.\n'
fi

DEV_CT="$(container_name "$NAME" dev)"

# Port forwards: declared (from compose, baked at create time) + adhoc
# (from `aidc proxy`, one socat sidecar per forward).
printf '\n-- port forwards --\n'
declared_ports=$(docker inspect "$DEV_CT" \
    --format '{{range $p, $b := .NetworkSettings.Ports}}{{if $b}}{{(index $b 0).HostPort}}:{{$p}}{{"\n"}}{{end}}{{end}}' \
    2>/dev/null | sed 's|/tcp$||' | awk 'NF')
if [ -n "$declared_ports" ]; then
    printf '  declared:\n'
    printf '%s\n' "$declared_ports" | while IFS= read -r line; do
        host_p="${line%%:*}"
        cont_p="${line##*:}"
        printf '    localhost:%s -> %s:%s\n' "$host_p" "$DEV_CT" "$cont_p"
    done
else
    printf '  declared: (none)\n'
fi
adhoc=$(list_adhoc_forwards "$NAME")
if [ -n "$adhoc" ]; then
    printf '  adhoc:\n'
    while IFS='|' read -r ct ports; do
        [ -z "$ct" ] && continue
        host_p="${ct##*-fwd-}"
        cont_p=$(printf '%s' "$ports" | sed -nE 's/.*->([0-9]+)\/tcp.*/\1/p' | head -1)
        printf '    localhost:%s -> %s:%s\n' "$host_p" "$DEV_CT" "${cont_p:-?}"
    done <<<"$adhoc"
else
    printf '  adhoc: (none)\n'
fi

# Attached foreign bridge networks (NET-13). Listed unconditionally, including
# the "(none)" case: an attachment is a widening of the sandbox, and status is
# where someone looks to find out what a session can currently reach.
printf '\n-- attached networks --\n'
attached_nets=$(aidc_session_attached_networks "$NAME")
if [ -n "$attached_nets" ]; then
    printf '%s\n' "$attached_nets" | while IFS= read -r n; do
        [ -z "$n" ] && continue
        printf '    %s\n' "$n"
    done
    printf '  reachable on every port, not proxied by squid, not taint-visible\n'
    printf '  manage with: aidc network %s ls|add|rm\n' "$NAME"
else
    printf '  (none -- session reaches only %s)\n' "$(aidc_session_network "$NAME")"
fi

# Recent dev-container logs (last 10 lines).
printf '\n-- recent dev logs (last 10) --\n'
docker logs --tail 10 "$DEV_CT" 2>&1 || true
