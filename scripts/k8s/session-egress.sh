#!/usr/bin/env bash
# aidc egress <session> add|rm|ls|clear (a Kubernetes session): TCP relays, live (NET-15).
#
# The cluster form of Docker's `aidc egress` (scripts/k8s/net.sh says how a relay is made). Live
# changes never touch the dev pod: a relay is its own Deployment, Service and NetworkPolicies, and
# its name goes into the session's names responder, which reloads within seconds (owner's Q-K9
# call: no restart). Changing a host's ports re-makes its relay, dropping its open connections,
# as on Docker. Unlike Docker, a relay declared at create can be changed here too: nothing has to
# be recreated for it.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=net.sh
. "$AIDC_SCRIPTS/k8s/net.sh"

usage() {
    cat <<'EOF'
aidc egress <session> <subcommand> [args]     (kubernetes backend)

Let the session reach one TCP destination this machine can reach -- a database on
the LAN or a VPN -- without giving it a route out. The session connects to the same
host:port it would outside; a relay in the cluster forwards to that one address and
port, and every connection is logged to the session's audit trail.

Subcommands:
  add   <host:port>   relay a destination (resolved on this machine now)
  rm    <host:port>   stop relaying it
  ls                  list the session's relays
  clear               remove every relay of the session

Changes are live: the session keeps running, and the name resolves in it within seconds.
EOF
}

NAME="${1:-}"
case "$NAME" in ''|-h|--help) usage; exit 0 ;; esac
shift
SUBVERB="${1:-}"
[ -n "$SUBVERB" ] || { usage >&2; exit 2; }
shift
validate_session_name "$NAME"
k8s_require || exit 1
k8s_is_git_session "$NAME" && die "git is your git agent (the git container), not a session with relays"
ns=$(k8s_user_ns "$AIDC_K8S_USER")
k8s_require_session "$ns" "$NAME"

# relay_for <host>: the relay row of the session for <host> (k8s_relays), or nothing.
relay_for() {
    local rows
    rows=$(k8s_relays "$ns" "$NAME") || die "cannot read ${NAME}'s relays: the cluster did not answer (${rows})"
    printf '%s\n' "$rows" | awk -F'|' -v h="$1" '$3 == h { print; exit }'
}

# names_now: write the names, saying so when it could not (the relay works by address meanwhile).
names_now() {
    k8s_names_sync "$ns" "$NAME" \
        || die "the relay is in place, but its name could not be written into ${NAME}'s names responder; run the command again"
}

# apply_relay <host> <ip> <kind> <port>...: make or re-make the relay.
apply_relay() {
    local host="$1" ip="$2" kind="$3" audit sel
    shift 3
    audit=$(k8s_get "$ns" statefulset "${NAME}-dev" -o jsonpath='{.metadata.annotations.aidc/audit}') \
        || die "cannot read ${NAME}: the cluster did not answer (${audit})"
    [ -n "$audit" ] || die "cannot find ${NAME}'s audit claim (its StatefulSet has no aidc/audit annotation)"
    sel=$(k8s_node_selector) || exit 1
    k8s_render_relay "$NAME" "$host" "$ip" "$kind" "$audit" "$sel" "$@" | k8s_kubectl apply -f - >&2 \
        || die "the cluster did not take the relay for ${host}"
    k8s_kubectl -n "$ns" rollout status "deployment/$(k8s_relay_name "$NAME" "$host")" --timeout=120s >&2 \
        || die "the relay for ${host} did not become ready; see kubectl -n ${ns} describe deployment $(k8s_relay_name "$NAME" "$host")"
}

# remove_relay <host>: the relay's Deployment, Service and policies.
remove_relay() {
    local n
    n=$(k8s_relay_name "$NAME" "$1")
    k8s_kubectl -n "$ns" delete "deployment/${n}" "service/${n}" "networkpolicy/${n}" "networkpolicy/${n}-dev" \
        --ignore-not-found >&2 || die "the cluster did not remove the relay for ${1}"
}

do_add() {
    local spec="${1:-}" row kind ports ip why port
    [ -n "$spec" ] || die "add requires host:port (e.g. db.internal.example:5432)"
    aidc_egress_parse "$spec" || die "invalid destination: ${spec}"
    local host="$AIDC_EGRESS_HOST" want="$AIDC_EGRESS_PORT"
    row=$(relay_for "$host")
    kind=$(printf '%s' "$row" | cut -d'|' -f2)
    ports=$(printf '%s' "$row" | cut -d'|' -f5)
    for port in $ports; do
        [ "$port" != "$want" ] || { info "${host}:${want} is already relayed (${kind})"; return 0; }
    done
    ip=$(aidc_egress_resolve_explained "$host") || die "egress: ${host} has no address to relay to"
    if why=$(aidc_egress_refusal "$ip" "$want" ""); then die "refusing ${spec}: ${why}"; fi
    [ -z "$row" ] || info "adding port ${want} to the relay for ${host}: its open connections will drop"
    # shellcheck disable=SC2086  # one port per word
    apply_relay "$host" "$ip" "${kind:-live}" $ports "$want"
    names_now
    info "egress: $(k8s_relay_reach_as "$NAME" "$host"):${want} -> ${ip}:${want} (live; every connection logged to the audit trail)"
    if ! k8s_names_wait "$ns" "$NAME" "$(k8s_relay_reach_as "$NAME" "$host")" 30; then
        info "WARNING: $(k8s_relay_reach_as "$NAME" "$host") does not resolve in ${NAME} yet; it should within a minute"
    fi
}

do_rm() {
    local spec="${1:-}" row kind ip ports left="" port found=0
    [ -n "$spec" ] || die "rm requires host:port"
    aidc_egress_parse "$spec" || die "invalid destination: ${spec}"
    local host="$AIDC_EGRESS_HOST" want="$AIDC_EGRESS_PORT"
    row=$(relay_for "$host")
    [ -n "$row" ] || { info "${host}:${want} is not relayed (already gone?)"; return 0; }
    kind=$(printf '%s' "$row" | cut -d'|' -f2)
    ip=$(printf '%s' "$row" | cut -d'|' -f4)
    ports=$(printf '%s' "$row" | cut -d'|' -f5)
    for port in $ports; do
        if [ "$port" = "$want" ]; then found=1; else left="${left:+${left} }${port}"; fi
    done
    [ "$found" = 1 ] || { info "${host}:${want} is not relayed (already gone?)"; return 0; }
    if [ -n "$left" ]; then
        info "keeping ${host} port(s) ${left}: the relay restarts and its open connections will drop"
        # shellcheck disable=SC2086  # one port per word
        apply_relay "$host" "$ip" "$kind" $left
    else
        remove_relay "$host"
    fi
    names_now
    info "removed relay for ${host}:${want}"
}

do_ls() {
    local lines
    lines=$(k8s_relays_describe "$ns" "$NAME")
    [ -n "$lines" ] || { printf 'no TCP egress relays for session %s\n' "$NAME"; return 0; }
    printf '%-9s  %-40s  %s\n' KIND "REACH AS" "FORWARDS TO"
    printf '%s\n' "$lines"
}

do_clear() {
    local rows n=0 name kind host rest
    rows=$(k8s_relays "$ns" "$NAME") || die "cannot read ${NAME}'s relays: the cluster did not answer (${rows})"
    while IFS='|' read -r name kind host rest; do
        [ -n "$name" ] || continue
        remove_relay "$host"
        n=$((n + 1))
        : "$kind" "$rest"
    done <<<"$rows"
    [ "$n" -gt 0 ] || { printf 'no relays to clear for session %s\n' "$NAME"; return 0; }
    names_now
    info "removed ${n} relay(s) for session ${NAME}"
}

case "$SUBVERB" in
    add) do_add "$@" ;;
    rm) do_rm "$@" ;;
    ls) do_ls ;;
    clear) do_clear ;;
    -h|--help) usage ;;
    *) err "unknown subverb: ${SUBVERB}"; usage >&2; exit 2 ;;
esac
