#!/usr/bin/env bash
# aidc TCP egress relays (NET-15).
#
# Bash 3.2 compatible -- no `declare -A`, no `mapfile`, no `${var,,}`.
#
# A proxied session has no route out (NET-14): squid is the only way, and squid
# carries HTTP. A session that must reach a database, a queue or an SSH host the
# HOST can reach -- over ZeroTier, a VPN, a LAN -- gets one relay per destination
# host instead:
#
#   dev --(session network)--> aidc-<s>-egress-<host>  --(egress network)--> host:port
#
# The relay is an aidc/forwarder (socat) container on both session networks. On the
# session network it carries the destination's own name as an alias, so the session
# connects to `db.example:5432` exactly as it would outside, and a TLS client still
# checks the real hostname (sslmode=verify-full works: the relay never touches the
# bytes). It forwards only to the address and ports it was made for.
#
# Two constraints shape it:
#
#   - The destination is resolved HERE, on the host, and the relay is given the
#     address. The relay cannot resolve the name itself: on the session network that
#     name is its own alias, so Docker's DNS would answer with the relay and it would
#     connect to itself. The host's resolver is also the one that knows overlay and
#     split-horizon names. Cost: an address that changes needs the relay re-made.
#
#   - One relay per HOST, listening on each of that host's ports. Docker answers an
#     alias with every container that carries it, so two relays for one host (one per
#     port) would both answer, and a client could land on the relay for the other port.
#
# Every connection is logged by socat (-d -d) to egress-<slug>-<port>.log in the
# session's audit dir (aidc_egress_slug: db.internal.example -> db-internal-example).
#
# Shared by cmd-create.sh (declared: `egress_tcp:` config, --egress-tcp) and
# cmd-egress.sh (live: `aidc egress <s> add|rm|ls`). Pure functions are unit-tested by
# tests/unit/test-egress-tcp.sh; aidc_egress_resolve needs a resolver.

# ---- PURE --------------------------------------------------------------------

# aidc_egress_is_ipv4 <s>: a dotted quad, each part 0-255.
aidc_egress_is_ipv4() {
    local s="$1" part n=0
    case "$s" in
        *[!0-9.]*|.*|*.|*..*|'') return 1 ;;
    esac
    local IFS=.
    # shellcheck disable=SC2086  # splitting on dots is the point
    set -- $s
    [ $# -eq 4 ] || return 1
    for part in "$@"; do
        [ ${#part} -le 3 ] || return 1
        n=$((10#$part))
        [ "$n" -le 255 ] || return 1
    done
    return 0
}

# aidc_egress_valid_host <s>: a DNS name (letters, digits, hyphens, dots; no label
# starting or ending with a hyphen) or an IPv4 address.
aidc_egress_valid_host() {
    local h="$1" label
    aidc_egress_is_ipv4 "$h" && return 0
    [ -n "$h" ] && [ ${#h} -le 253 ] || return 1
    case "$h" in
        *[!A-Za-z0-9.-]*|.*|*.|*..*) return 1 ;;
        *[!0-9.]*) : ;;
        *) return 1 ;;   # digits and dots only, and not an IPv4 address (no TLD is numeric)
    esac
    local IFS=.
    for label in $h; do
        [ ${#label} -le 63 ] || return 1
        case "$label" in
            -*|*-) return 1 ;;
        esac
    done
    return 0
}

# aidc_egress_valid_port <s>: 1-65535, no leading zero.
aidc_egress_valid_port() {
    case "$1" in
        ''|*[!0-9]*|0*) return 1 ;;
    esac
    [ ${#1} -le 5 ] && [ "$1" -le 65535 ]
}

# aidc_egress_parse <host:port>: sets AIDC_EGRESS_HOST (lower-cased) and
# AIDC_EGRESS_PORT, or prints why not and returns 1.
aidc_egress_parse() {
    local spec="$1" host port
    case "$spec" in
        *:*:*|*:|:*) printf 'expected host:port, got %s\n' "'$spec'" >&2; return 1 ;;
        *:*) host="${spec%:*}"; port="${spec##*:}" ;;
        *) printf 'expected host:port, got %s (the port is required)\n' "'$spec'" >&2; return 1 ;;
    esac
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    if ! aidc_egress_valid_host "$host"; then
        printf 'not a host name or IPv4 address: %s\n' "'$host'" >&2; return 1
    fi
    # The relay answers to the host's name on the session network, so a name the
    # session already uses there would be taken over: the session's own services and
    # squid's alias, and aidc's container names.
    case "$host" in
        squid|refresher|policy|audit|dev|aidc-proxy|aidc-*)
            printf '%s is a name the session already uses; name the destination by its full name or address\n' "'$host'" >&2
            return 1 ;;
    esac
    if ! aidc_egress_valid_port "$port"; then
        printf 'not a port (1-65535): %s\n' "'$port'" >&2; return 1
    fi
    # shellcheck disable=SC2034  # results, read by the caller
    AIDC_EGRESS_HOST="$host"
    # shellcheck disable=SC2034  # as above
    AIDC_EGRESS_PORT="$port"
    return 0
}

# aidc_egress_slug <host>: the host as a container-name-safe token, one per host:
# each hyphen doubles and each dot becomes a hyphen, so a-b.example (a--b-example) and
# a.b-example (a-b--example) cannot collide. No label starts or ends with a hyphen, so
# a dot never meets one and the mapping cannot be read two ways. Two hosts sharing a
# slug would share a container name, and replacing one relay would remove the other.
aidc_egress_slug() {
    printf '%s' "$1" | sed -e 's/-/--/g' -e 's/\./-/g'
}

# aidc_egress_refusal <ip> <port> <mcp_deny>: prints why the destination is refused
# and returns 0, or returns 1 when it is fine.
#   - aidc-mcp's own address and port (MCP-12). Bound on every interface (0.0.0.0),
#     aidc-mcp answers on each of the host's addresses, which aidc cannot list from
#     inside the aidc-mcp container, so there its port is refused on any address.
#   - loopback and 0.0.0.0: from the relay those mean the relay itself.
aidc_egress_refusal() {
    local ip="$1" port="$2" deny="$3" deny_ip deny_port
    case "$ip" in
        127.*|0.0.0.0)
            printf '%s is loopback: from the relay that is the relay itself\n' "$ip"; return 0 ;;
    esac
    if [ -n "$deny" ]; then
        deny_ip="${deny%:*}"; deny_port="${deny##*:}"
        if [ "$port" = "$deny_port" ]; then
            if [ "$ip" = "$deny_ip" ] || [ "$deny_ip" = "0.0.0.0" ]; then
                printf '%s:%s is aidc-mcp (%s), which sessions must not reach\n' "$ip" "$port" "$deny"
                return 0
            fi
        fi
    fi
    return 1
}

# aidc_egress_group <lines of "host port ip">: one line per host,
# "host ip port1 port2 ...", ports deduped and in first-seen order, hosts sorted.
aidc_egress_group() {
    awk 'NF == 3 {
            if (!($1 in ip)) { ip[$1] = $3; order[++n] = $1 }
            key = $1 SUBSEP $2
            if (!(key in seen)) { seen[key] = 1; ports[$1] = ports[$1] " " $2 }
         }
         END { for (i = 1; i <= n; i++) print order[i] " " ip[order[i]] ports[order[i]] }' |
        sort
}

# aidc_egress_script <host> <ip> <port>...: the relay's shell command. One socat per
# port; the container exits (and restart: unless-stopped brings it back) if any dies,
# rather than half-working.
aidc_egress_script() {
    local host="$1" ip="$2" slug script="" port
    shift 2
    slug=$(aidc_egress_slug "$host")
    for port in "$@"; do
        script="${script}socat -d -d -lf /var/aidc/audit/egress-${slug}-${port}.log TCP-LISTEN:${port},fork,reuseaddr TCP:${ip}:${port} & "
    done
    printf '%swait -n; exit 1' "$script"
}

# aidc_egress_render_service <session> <audit_dir> <version_tag> <host> <ip> <port>...:
# the compose service for one declared relay.
aidc_egress_render_service() {
    local session="$1" audit_dir="$2" tag="$3" host="$4" ip="$5" slug
    shift 5
    slug=$(aidc_egress_slug "$host")
    printf '\n  egress-%s:\n' "$slug"
    printf '    image: aidc/forwarder:%s\n' "$tag"
    printf '    container_name: aidc-%s-egress-%s\n' "$session" "$slug"
    printf '    labels:\n'
    printf '      aidc.session: "%s"\n' "$session"
    printf '      aidc.egress: "declared"\n'
    printf '      aidc.egress.host: "%s"\n' "$host"
    printf '      aidc.egress.ip: "%s"\n' "$ip"
    printf '      aidc.egress.ports: "%s"\n' "$*"
    printf '    networks:\n'
    if aidc_egress_is_ipv4 "$host"; then
        printf '      default: {}\n'
    else
        printf '      default:\n'
        printf '        aliases:\n'
        printf '          - %s\n' "$host"
    fi
    printf '      egress: {}\n'
    printf '    volumes:\n'
    printf '      - %s:/var/aidc/audit:rw\n' "$audit_dir"
    printf '    entrypoint: ["/bin/sh", "-c"]\n'
    printf '    command:\n'
    printf '      - "%s"\n' "$(aidc_egress_script "$host" "$ip" "$@")"
    printf '    restart: unless-stopped\n'
}

# aidc_egress_reach_as <session> <host>: the name a session uses to reach the relay.
# A host name is its own alias; an IPv4 destination has no name to borrow, so the
# session uses the relay's container name.
aidc_egress_reach_as() {
    if aidc_egress_is_ipv4 "$2"; then
        printf 'aidc-%s-egress-%s' "$1" "$(aidc_egress_slug "$2")"
    else
        printf '%s' "$2"
    fi
}

# ---- RESOLVER ----------------------------------------------------------------

# aidc_egress_resolve <host>: the host's first IPv4 address, from THIS machine's
# resolver (see the header for why not the relay's). An IPv4 host is itself.
#
# Returns 1 when the name has no IPv4 address, 2 when this machine has no tool to ask
# (no getent and no working python3: a Mac without the Command Line Tools), so a
# caller can say which. Inside aidc-mcp (session_create) "this machine" is the aidc-mcp
# container, whose resolver is the host's upstream DNS, not any per-link resolver the
# host has (systemd-resolved routing a ZeroTier domain, say).
aidc_egress_resolve() {
    local host="$1" ip="" tried=0
    if aidc_egress_is_ipv4 "$host"; then
        printf '%s' "$host"; return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        tried=1
        ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 { print $1 }') || ip=""
    fi
    if ! aidc_egress_is_ipv4 "$ip" && python3 -c 'import socket' >/dev/null 2>&1; then
        tried=1
        ip=$(python3 -c 'import socket, sys; print(socket.gethostbyname(sys.argv[1]))' "$host" 2>/dev/null) || ip=""
    fi
    [ "$tried" -eq 1 ] || return 2
    aidc_egress_is_ipv4 "$ip" || return 1
    printf '%s' "$ip"
}

# aidc_egress_resolve_explained <host>: the address, or say on stderr why there is
# none and return 1. Reports itself rather than calling die: die lives in another
# library, and inside the $(...) a caller wraps this in, it would end only that subshell.
aidc_egress_resolve_explained() {
    local ip rc=0
    ip=$(aidc_egress_resolve "$1") || rc=$?
    case "$rc" in
        0) printf '%s' "$ip" ;;
        2) printf 'cannot resolve %s: no resolver tool here (needs getent or python3)\n' "$1" >&2; return 1 ;;
        *) printf 'cannot resolve %s from this machine (no IPv4 address)\n' "$1" >&2; return 1 ;;
    esac
}

# ---- DOCKER ------------------------------------------------------------------

# aidc_egress_relays <session>: one line per relay of the session, running or not,
# "container|kind|host|ip|ports|state" (kind: declared or adhoc; ports space-separated;
# state: docker's, e.g. running, restarting, exited). A relay exits when any of its
# listeners dies, so a relay that is not running is one that is not relaying.
aidc_egress_relays() {
    docker ps -a --filter "label=aidc.session=$1" --filter "label=aidc.egress" \
        --format '{{.Names}}|{{.Label "aidc.egress"}}|{{.Label "aidc.egress.host"}}|{{.Label "aidc.egress.ip"}}|{{.Label "aidc.egress.ports"}}|{{.State}}' \
        2>/dev/null | sort
}

# aidc_egress_describe <session>: the relays as display lines,
# "kind  reach-as:port -> ip:port  [state]" (state shown only when not running).
aidc_egress_describe() {
    local ct kind host ip ports state port flag
    while IFS='|' read -r ct kind host ip ports state; do
        [ -z "$ct" ] && continue
        flag=""
        [ "$state" = "running" ] || flag="  [${state:-unknown}: not relaying; docker logs ${ct}]"
        for port in $ports; do
            printf '%-9s  %-40s  %s%s\n' "$kind" "$(aidc_egress_reach_as "$1" "$host"):${port}" "${ip}:${port}" "$flag"
        done
    done <<EOF_REL
$(aidc_egress_relays "$1")
EOF_REL
}

# aidc_egress_adhoc_name <session> <host>
aidc_egress_adhoc_name() {
    printf 'aidc-%s-egressx-%s' "$1" "$(aidc_egress_slug "$2")"
}

# aidc_egress_start_adhoc <session> <audit_dir> <image> <host> <ip> <port>...: run a
# live relay. Started on the egress network, then joined to the session network under
# the destination's name, like the declared ones. Rolled back if the join fails.
aidc_egress_start_adhoc() {
    local session="$1" audit_dir="$2" image="$3" host="$4" ip="$5" ct
    shift 5
    ct=$(aidc_egress_adhoc_name "$session" "$host")
    docker run -d --name "$ct" \
        --label "aidc.session=${session}" --label "aidc.egress=adhoc" \
        --label "aidc.egress.host=${host}" --label "aidc.egress.ip=${ip}" \
        --label "aidc.egress.ports=$*" \
        --network "aidc-${session}-egress" \
        --restart unless-stopped \
        -v "${audit_dir}:/var/aidc/audit:rw" \
        --entrypoint /bin/sh "$image" -c "$(aidc_egress_script "$host" "$ip" "$@")" \
        >/dev/null || return 1
    local out
    # Reached by the same name as a declared relay would be: the host's own name, or
    # for an IPv4 destination the declared relay's container name (one relay per host,
    # so the two can never both exist).
    if ! out=$(docker network connect --alias "$(aidc_egress_reach_as "$session" "$host")" \
            "aidc-${session}-net" "$ct" 2>&1); then
        printf 'could not join %s to aidc-%s-net: %s\n' "$ct" "$session" "$out" >&2
        docker rm -f "$ct" >/dev/null 2>&1 || true
        return 1
    fi
}

# aidc_egress_remove_adhoc <session> [note]: remove every live relay of a session.
# They are attached to the session's networks, so `aidc kill` must remove them
# before compose can remove those networks. Best-effort; never fails the caller.
aidc_egress_remove_adhoc() {
    local ids
    ids=$(docker ps -a --filter "label=aidc.session=$1" --filter "label=aidc.egress=adhoc" -q 2>/dev/null || true)
    [ -z "$ids" ] && return 0
    if [ -n "${2:-}" ]; then printf '[aidc] %s\n' "$2" >&2; fi
    printf '%s\n' "$ids" | xargs docker rm -f >/dev/null 2>&1 || true
}
