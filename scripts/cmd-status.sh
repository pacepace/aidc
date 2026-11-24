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
# shellcheck source=lib/egress.sh
. "$AIDC_SCRIPTS/lib/egress.sh"
# shellcheck source=lib/feeds.sh
. "$AIDC_SCRIPTS/lib/feeds.sh"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
aidc status [<name>]

No arg   pass through to `aidc list` plus a session count.
<name>   detailed per-session report: component health, taint status, the
         malware feeds (a lost feed or a stale list), declared + adhoc port
         forwards, and the last few dev-container logs.
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
# `test -f` says "no flag" by exiting 1 with nothing on stderr. docker exits 1 too when the
# policy container is gone, stopped or paused, but says why on stderr: that is not a clean
# session, and is said as such.
taint_rc=0
taint_err=$(docker exec "$POLICY_CT" test -f /var/state/tainted 2>&1 >/dev/null) || taint_rc=$?
if [ "$taint_rc" -eq 0 ]; then
    printf 'TAINTED.\n'
    docker exec "$POLICY_CT" cat /var/state/tainted 2>/dev/null || true
elif [ "$taint_rc" -eq 1 ] && [ -z "$taint_err" ]; then
    printf 'clean.\n'
else
    printf 'unknown: the policy sidecar did not answer (%s).\n' "${taint_err:-docker exec exited ${taint_rc}}"
fi

# The malware feeds behind the blocklist (#60): a lost feed or a refresh that stopped, from the
# refresher's state file. A refresher that cannot be asked is unknown, never fine.
printf '\n-- malware feeds --\n'
REFRESHER_CT="$(container_name "$NAME" refresher)"
if fstate=$(docker exec "$REFRESHER_CT" sh -c 'cat /etc/squid/aidc-feeds.state 2>/dev/null; true' 2>/dev/null); then
    aidc_feeds_describe "$fstate" "$(date +%s)" | sed 's/^/  /'
else
    printf '  unknown: the refresher sidecar did not answer\n'
fi

DEV_CT="$(container_name "$NAME" dev)"

# Port forwards: declared (from compose, baked at create time) + adhoc
# (from `aidc proxy`, one socat sidecar per forward). Declared ports are published by the
# aidc-<s>-dfwd-<host port> sidecars (the dev container is on an internal network and publishes
# nothing), and by the dev container itself only on a session from before those sidecars.
printf '\n-- port forwards --\n'
declared_ports=$( {
    aidc_declared_forwards "$NAME"
    docker inspect "$DEV_CT" \
        --format '{{range $p, $b := .NetworkSettings.Ports}}{{if $b}}{{(index $b 0).HostPort}}:{{$p}}{{"\n"}}{{end}}{{end}}' \
        2>/dev/null | sed 's|/tcp$||'
} | awk 'NF && !seen[$0]++')
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

# TCP egress relays (NET-15): the only non-HTTP ways out of a proxied session.
printf '\n-- tcp egress --\n'
relays=$(aidc_egress_describe "$NAME")
if [ -n "$relays" ]; then
    printf '%s\n' "$relays" | sed 's/^/  /'
else
    printf '  (none)\n'
fi

# Egress posture (NET-14). Printed before attachments because it is the coarser
# fact: whether this session can reach the internet without passing through squid.
printf '\n-- egress --\n'
case "$(aidc_session_egress_mode "$NAME")" in
    enforced)
        printf '  enforced: session bridge is a docker internal network (no NAT).\n'
        printf '  squid is the only route out; direct egress is not possible.\n' ;;
    direct)
        printf '  DIRECT: session bridge is NATed -- squid is configured but NOT enforced.\n'
        printf '  A process here can reach the internet without passing through the proxy,\n'
        printf '  which means the blocklist does not apply and taint detection cannot see it.\n'
        printf '  Either this session used --egress direct, or it predates v1.3.0.\n'
        printf '  To enforce: aidc kill %s && aidc create %s ...  (upgrade will NOT switch it)\n' "$NAME" "$NAME" ;;
    *)
        printf '  unknown (session network not found)\n' ;;
esac

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
