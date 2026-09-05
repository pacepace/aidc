#!/usr/bin/env bash
# desc: Attach a running session to another docker bridge network.
#
# Usage:
#   aidc network <session> add <network>   # attach the dev container
#   aidc network <session> rm  <network>   # detach it
#   aidc network <session> ls              # show attached networks
#
# The use case: a session that has to talk to a stack running elsewhere on the
# host -- another compose project's postgres, NATS, redis -- for troubleshooting
# and iteration. Once attached, the dev container resolves that project's
# containers by name through Docker's embedded DNS and reaches them on any port.
#
# ---- this widens the sandbox -------------------------------------------------
#
# aidc's premise is a fully adversarial agent (docs/done/design-07-safety-model.md).
# Attaching a foreign bridge is a deliberate, and deliberately visible, hole in
# that premise: every service on that network becomes reachable on every port,
# and the traffic is invisible to squid's access log, so the taint detector
# never sees it. It is also bidirectional -- containers on that network can
# reach aidc-<session>-dev. Attach the narrowest network that does the job, and
# expect anything on it to be within the agent's reach.
#
# ---- persistence -------------------------------------------------------------
#
#   aidc restart <s>     SURVIVES  (docker restart; endpoints are container state)
#   aidc upgrade <s>     LOST      (recreates the dev container)
#   aidc kill + create   LOST
#
# That differs from adhoc port forwards, which `aidc restart` sweeps: a network
# endpoint lives in the dev container's own config, so there is nothing to
# rebuild and nothing to sweep. For an attachment that survives everything, use
# `aidc create --network <net>` or the `networks:` config key instead.

set -euo pipefail

# Tolerate piped consumers (grep -q, head, less) that close stdin early.
trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/network.sh
. "$AIDC_SCRIPTS/lib/network.sh"

usage() {
    cat <<'EOF'
aidc network <session> <subcommand> [args]

Subcommands:
  add <network>    attach the dev container to an existing bridge network
  rm  <network>    detach it
  ls               list the networks the dev container is on

Examples:
  aidc network metallm add metallm_default
  aidc network metallm ls
  aidc network metallm rm metallm_default

Attachments survive 'aidc restart' but NOT 'aidc upgrade' or 'aidc kill'.
Use 'aidc create --network <net>' for one that survives everything.

Attaching a network makes every service on it reachable from the session, on
every port, without passing through squid. Attach the narrowest one that works.
EOF
}

# ---- arg parsing -------------------------------------------------------------

NAME="${1:-}"
case "$NAME" in
    ''|-h|--help) usage; exit 0 ;;
esac
shift

SUBVERB="${1:-}"
[ -z "$SUBVERB" ] && { usage >&2; exit 2; }
shift

validate_session_name "$NAME"
require_docker
session_exists "$NAME" || die "no such session: $NAME (try: aidc list)"

DEV_CT="$(container_name "$NAME" dev)"
OWN_NET="$(aidc_session_network "$NAME")"
COMPOSE_FILE="/tmp/aidc-${NAME}.yaml"

# Declared-vs-adhoc classification lives in lib/network.sh so this command and
# `aidc upgrade` (which drops the adhoc ones) agree on what each word means.

# ---- subverb: add ------------------------------------------------------------

do_add() {
    local net="${1:-}"
    [ -n "$net" ] || die "add requires a network name (list them with: docker network ls)"

    aidc_assert_attachable "$NAME" "$net"

    if aidc_container_networks "$DEV_CT" | grep -qx "$net"; then
        info "${DEV_CT} is already attached to ${net}"
        return 0
    fi

    # --gw-priority is what keeps the session's own bridge as the default
    # gateway; see the rationale block in lib/network.sh. Without it Docker
    # hands the default route to the network being attached, which silently
    # reroutes ALL egress -- squid-proxied traffic included -- through it.
    # Docker < 28 has no such flag, so there we attach anyway and say plainly
    # what changed rather than pretending it did not.
    if aidc_connect_supports_gw_priority; then
        docker network connect --gw-priority -100 "$net" "$DEV_CT" >/dev/null 2>&1 || \
            die "docker network connect failed for ${net} -> ${DEV_CT}"
    else
        err "this docker is too old for 'docker network connect --gw-priority' (needs 28+)."
        err "attaching anyway, but ${net} will take over the default route for ${DEV_CT}:"
        err "the session's outbound traffic will now exit via ${net}'s gateway."
        docker network connect "$net" "$DEV_CT" >/dev/null 2>&1 || \
            die "docker network connect failed for ${net} -> ${DEV_CT}"
    fi

    info "attached: ${DEV_CT} -> ${net}"
    info "  reachable by container name over docker DNS, on every port"
    info "  NOT proxied by squid and NOT visible to taint detection"
    info "  survives 'aidc restart'; lost on 'aidc upgrade' and 'aidc kill'"
}

# ---- subverb: rm -------------------------------------------------------------

do_rm() {
    local net="${1:-}"
    [ -n "$net" ] || die "rm requires a network name"

    if [ "$net" = "$OWN_NET" ]; then
        die "refusing to detach ${net}: it is this session's own network (that would cut it off from squid)"
    fi

    if ! aidc_container_networks "$DEV_CT" | grep -qx "$net"; then
        info "${DEV_CT} is not attached to ${net} (already gone?)"
        return 0
    fi

    docker network disconnect "$net" "$DEV_CT" >/dev/null 2>&1 || \
        die "docker network disconnect failed for ${net} -> ${DEV_CT}"
    info "detached: ${DEV_CT} from ${net}"

    if aidc_declared_networks "$COMPOSE_FILE" 2>/dev/null | grep -qx "$net"; then
        info "note: ${net} is DECLARED for this session, so it will come back on"
        info "      'aidc upgrade'. Remove it from the session's config / recreate"
        info "      without --network to drop it permanently."
    fi
}

# ---- subverb: ls -------------------------------------------------------------

do_ls() {
    # Output phase: tolerate piped consumers that early-exit.
    set +e
    set +o pipefail

    local attached declared have_declared=1
    attached=$(aidc_container_networks "$DEV_CT")
    if [ -z "$attached" ]; then
        printf 'no networks found for %s (is the session running?)\n' "$DEV_CT"
        return 0
    fi

    declared=$(aidc_declared_networks "$COMPOSE_FILE") || have_declared=0

    printf '%-32s  %-9s  %s\n' "NETWORK" "KIND" "NOTE"
    printf '%-32s  %-9s  %s\n' "$OWN_NET" "own" "session bridge; holds the default gateway"

    local foreign=0 net kind note
    while IFS= read -r net; do
        [ -z "$net" ] && continue
        [ "$net" = "$OWN_NET" ] && continue
        foreign=$((foreign + 1))
        if [ "$have_declared" -eq 0 ]; then
            kind="?"
            note="rendered compose file missing; cannot tell declared from adhoc"
        elif printf '%s\n' "$declared" | grep -qx "$net"; then
            kind="declared"
            note="survives restart and upgrade"
        else
            kind="adhoc"
            note="survives restart; lost on upgrade/kill"
        fi
        printf '%-32s  %-9s  %s\n' "$net" "$kind" "$note"
    done <<EOF
${attached}
EOF

    if [ "$foreign" -eq 0 ]; then
        printf '\nno foreign networks attached.\n'
    fi
}

# ---- dispatch ----------------------------------------------------------------

case "$SUBVERB" in
    add) do_add "$@" ;;
    rm)  do_rm  "$@" ;;
    ls)  do_ls  "$@" ;;
    -h|--help) usage ;;
    *) err "unknown subverb: ${SUBVERB}"; usage >&2; exit 2 ;;
esac
