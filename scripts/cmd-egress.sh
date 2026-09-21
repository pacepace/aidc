#!/usr/bin/env bash
# desc: Let a running session reach a TCP host:port the host can reach (a database over ZeroTier).
#
# Usage:
#   aidc egress <session> add <host:port>   # relay one destination
#   aidc egress <session> rm  <host:port>   # stop relaying it
#   aidc egress <session> ls                # list relays, declared and live
#   aidc egress <session> clear             # remove every live relay
#
# The live counterpart of `aidc create --egress-tcp` / `egress_tcp:` (NET-15); the
# mechanism and its constraints are in lib/egress.sh. Live relays survive restart and
# upgrade (neither touches them) and are removed by `aidc kill`.

set -euo pipefail

# Tolerate piped consumers (grep -q, head, less) that close stdin early.
trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"
# shellcheck source=lib/egress.sh
. "$AIDC_SCRIPTS/lib/egress.sh"

usage() {
    cat <<'EOF'
aidc egress <session> <subcommand> [args]

Let the session reach one TCP destination the host can reach -- a database over
ZeroTier, a VPN or the LAN -- without giving it a route out. The session connects to
the same host:port it would outside; a relay forwards to that one address and port,
and every connection is logged to the session's audit dir (egress-*.log).

Subcommands:
  add   <host:port>   relay a destination. The name is resolved on this machine now;
                      if its address changes, rm and add it again.
  rm    <host:port>   stop relaying it
  ls                  list the session's relays, declared (--egress-tcp / egress_tcp:)
                      and live (added here)
  clear               remove every live relay

Live relays survive 'aidc restart' and 'aidc upgrade'; 'aidc kill' removes them. To
make one permanent, add it to egress_tcp: in ~/.config/aidc/config.yaml.

Examples:
  aidc egress api add db.internal.example:5432
  aidc egress api ls
  aidc egress api rm db.internal.example:5432
EOF
}

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

# The relay of the session for $1, as "container|kind|host|ip|ports|state", or nothing.
relay_for_host() {
    aidc_egress_relays "$NAME" | awk -F'|' -v h="$1" '$3 == h { print; exit }'
}

# The session's audit dir on the host, where relays log.
session_audit_dir() {
    docker inspect "$(container_name "$NAME" audit)" \
        --format '{{range .Mounts}}{{if eq .Destination "/var/aidc/audit"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null || printf ''
}

# Replace the live relay for a host with one on the given ports (none: just remove).
# Recreating drops that host's open connections, which is why add and rm say so.
# Everything that can fail beforehand is checked before the old relay goes. The start
# itself can still fail after it, so the error names the ports that were lost.
restart_adhoc() {
    local host="$1" ip="$2" audit="" had
    shift 2
    had=$(relay_for_host "$host" | awk -F'|' '$2 == "adhoc" { print $5 }')
    if [ $# -gt 0 ]; then
        audit=$(session_audit_dir)
        [ -n "$audit" ] || die "cannot find the audit dir of session ${NAME} (is its audit container running?); nothing changed"
        ensure_image forwarder
    fi
    docker rm -f "$(aidc_egress_adhoc_name "$NAME" "$host")" >/dev/null 2>&1 || true
    [ $# -eq 0 ] && return 0
    if ! aidc_egress_start_adhoc "$NAME" "$audit" "aidc/forwarder:${AIDC_VERSION_TAG}" "$host" "$ip" "$@"; then
        # Lost: ports that were relayed and were meant to stay (not one being removed).
        local lost="" p q
        for p in $had; do
            for q in "$@"; do
                if [ "$p" = "$q" ]; then lost="${lost:+${lost} }${p}"; fi
            done
        done
        if [ -n "$lost" ]; then
            die "could not start the relay for ${host}; its previous relay is gone too, so port(s) ${lost} are no longer relayed (aidc egress ${NAME} add ${host}:<port> to restore)"
        fi
        die "could not start the relay for ${host}"
    fi
}

do_add() {
    local spec="${1:-}" existing kind ports ip why port
    [ -n "$spec" ] || die "add requires host:port (e.g. db.internal.example:5432)"
    aidc_egress_parse "$spec" || die "invalid destination: ${spec}"
    local host="$AIDC_EGRESS_HOST" want="$AIDC_EGRESS_PORT"

    existing=$(relay_for_host "$host")
    kind=$(printf '%s' "$existing" | cut -d'|' -f2)
    ports=$(printf '%s' "$existing" | cut -d'|' -f5)
    for port in $ports; do
        if [ "$port" = "$want" ]; then
            info "${host}:${want} is already relayed (${kind})"
            return 0
        fi
    done
    if [ "$kind" = "declared" ]; then
        # One relay per host carries the host's name; a second would share it.
        die "${host} has a relay declared at create time (ports: ${ports}); add ${host}:${want} to egress_tcp: and recreate the session"
    fi

    ip=$(aidc_egress_resolve_explained "$host") || die "egress: ${host} has no address to relay to"
    if why=$(aidc_egress_refusal "$ip" "$want" "$(aidc_mcp_deny_target)"); then
        die "refusing ${spec}: ${why}"
    fi
    if [ -n "$existing" ]; then
        info "adding port ${want} to the relay for ${host}: its open connections will drop"
    fi
    # shellcheck disable=SC2086  # ports is a space-separated list, one arg each
    restart_adhoc "$host" "$ip" $ports "$want"
    info "egress: $(aidc_egress_reach_as "$NAME" "$host"):${want} -> ${ip}:${want}"
    info "  every connection is logged to $(session_audit_dir)/egress-$(aidc_egress_slug "$host")-${want}.log"
}

do_rm() {
    local spec="${1:-}" existing kind ports ip left="" port found=0
    [ -n "$spec" ] || die "rm requires host:port"
    aidc_egress_parse "$spec" || die "invalid destination: ${spec}"
    local host="$AIDC_EGRESS_HOST" want="$AIDC_EGRESS_PORT"

    existing=$(relay_for_host "$host")
    if [ -z "$existing" ]; then
        info "${host}:${want} is not relayed (already gone?)"
        return 0
    fi
    kind=$(printf '%s' "$existing" | cut -d'|' -f2)
    ip=$(printf '%s' "$existing" | cut -d'|' -f4)
    ports=$(printf '%s' "$existing" | cut -d'|' -f5)
    for port in $ports; do
        if [ "$port" = "$want" ]; then found=1; else left="${left:+${left} }${port}"; fi
    done
    if [ "$found" -eq 0 ]; then
        info "${host}:${want} is not relayed (already gone?)"
        return 0
    fi
    [ "$kind" = "declared" ] && \
        die "${host}:${want} was declared at create time; remove it from egress_tcp: and recreate the session"
    [ -n "$left" ] && info "keeping ${host} port(s) ${left}: the relay restarts and its open connections will drop"
    # shellcheck disable=SC2086  # left is a space-separated list, one arg each
    restart_adhoc "$host" "$ip" $left
    info "removed relay for ${host}:${want}"
}

do_ls() {
    local lines
    lines=$(aidc_egress_describe "$NAME")
    if [ -z "$lines" ]; then
        printf 'no TCP egress relays for session %s\n' "$NAME"
        return 0
    fi
    set +e
    set +o pipefail
    printf '%-9s  %-40s  %s\n' "KIND" "REACH AS" "FORWARDS TO"
    printf '%s\n' "$lines"
}

do_clear() {
    local n
    n=$(aidc_egress_relays "$NAME" | awk -F'|' '$2 == "adhoc"' | wc -l | tr -d ' ')
    if [ "$n" -eq 0 ]; then
        printf 'no live relays to clear for session %s\n' "$NAME"
        return 0
    fi
    aidc_egress_remove_adhoc "$NAME"
    info "removed ${n} live relay(s) for session ${NAME}"
}

case "$SUBVERB" in
    add)   do_add   "$@" ;;
    rm)    do_rm    "$@" ;;
    ls)    do_ls    "$@" ;;
    clear) do_clear "$@" ;;
    -h|--help) usage ;;
    *) err "unknown subverb: ${SUBVERB}"; usage >&2; exit 2 ;;
esac
