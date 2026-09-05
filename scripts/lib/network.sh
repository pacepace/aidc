#!/usr/bin/env bash
# aidc attached-network library (NET-13).
#
# Bash 3.2 compatible -- no `declare -A`, no `mapfile`, no `${var,,}`.
#
# Shared by:
#   cmd-network.sh  adhoc attach/detach on a RUNNING session
#   cmd-create.sh   declarative --network / config `networks:` at create time
#   cmd-status.sh   reporting which foreign bridges a session is on
#
# Split into two halves so the pure ones are unit-testable without Docker
# (tests/unit/test-network-attach.sh, run by CI's no-Docker `unit` job):
#
#   PURE    aidc_valid_network_name, aidc_is_reserved_network,
#           aidc_session_network, aidc_render_extnet_blocks
#   DOCKER  aidc_network_exists, aidc_network_driver, aidc_assert_attachable,
#           aidc_container_networks, aidc_compose_supports_gw_priority
#
# ---- why gw_priority, and why it is not optional -----------------------------
#
# A container on two bridges has two candidate default gateways. Docker picks
# one. Measured on Docker/Compose 29.1.3 / 2.40.3:
#
#   docker network connect ext dev            -> default route MOVES to ext
#   compose `priority: 100` on the aidc net   -> default route STILL moves to ext
#   compose `gw_priority: 100` / CLI --gw-priority  -> aidc net KEEPS the gateway
#
# Compose's `priority` only orders the connect sequence; it does NOT choose the
# gateway. So without gw_priority, attaching a foreign bridge silently reroutes
# ALL of the session's egress -- including its squid-proxied traffic -- out
# through someone else's network. Every attach path here pins the gateway.
#
# (Reaching services on the attached network does not depend on the default
# route: Docker installs a subnet route per attachment. Pinning the gateway
# costs nothing and keeps egress where it belongs.)

# ---- naming ------------------------------------------------------------------

# The network compose creates and owns for a session. Always the gateway holder.
aidc_session_network() { printf 'aidc-%s-net' "$1"; }

# Docker's own network-name charset. Deliberately a shade stricter than the
# daemon (no leading punctuation) so a typo fails here with a readable message
# instead of deep inside `docker network connect`.
# Returns 0 when valid; does NOT die -- callers decide.
aidc_valid_network_name() {
    local name="${1:-}"
    [ -n "$name" ] || return 1
    printf '%s' "$name" | grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$'
}

# Networks that must never be attached:
#   host  -- shares the host netns outright; total sandbox bypass
#   none  -- meaningless here
#   bridge -- Docker's default bridge: reaches every container started without
#             an explicit network, on any port, and offers no DNS anyway
# Returns 0 when the name is one of these.
aidc_is_reserved_network() {
    case "${1:-}" in
        host|none|bridge) return 0 ;;
        *) return 1 ;;
    esac
}

# ---- compose block rendering (PURE) ------------------------------------------
#
# aidc_render_extnet_blocks <newline-separated-network-names>
#
# Sets two globals consumed by proxy/compose-render.sh:
#
#   EXTNET_DECLARATIONS   top-level `networks:` additions
#   DEV_NETWORKS_BLOCK    the dev service's `networks:` value
#
# Compose keys are generated (extnet0, extnet1, ...) rather than taken from the
# network name: real network names may contain dots and dashes that are awkward
# as YAML keys, and `name:` carries the truth regardless.
#
# With an EMPTY list this renders the pre-NET-13 sequence form verbatim:
#
#       - default
#
# That is deliberate. Sessions with no attached network produce a byte-identical
# dev `networks:` block to older aidc, so they neither change behaviour nor
# require a compose new enough to know `gw_priority`.
aidc_render_extnet_blocks() {
    local list="${1:-}"
    EXTNET_DECLARATIONS=""
    DEV_NETWORKS_BLOCK="      - default"

    [ -n "$list" ] || return 0

    local decls="" devs="" name idx=0
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        decls="${decls}  extnet${idx}:
    name: ${name}
    external: true
"
        devs="${devs}      extnet${idx}:
        priority: 0
        gw_priority: -100
"
        idx=$((idx + 1))
    done <<EOF
${list}
EOF

    [ "$idx" -gt 0 ] || return 0

    # Command substitution strips the single trailing newline, which is what we
    # want -- the template supplies the surrounding line breaks.
    #
    # SC2034: both are out-parameters read by cmd-create.sh and exported to
    # compose-render.sh; shellcheck cannot see across the source boundary.
    # shellcheck disable=SC2034
    EXTNET_DECLARATIONS=$(printf '%s' "$decls")
    # shellcheck disable=SC2034
    DEV_NETWORKS_BLOCK="      default:
        priority: 100
        gw_priority: 100
$(printf '%s' "$devs")"
}

# ---- Docker-facing helpers ---------------------------------------------------

aidc_network_exists() {
    docker network inspect "$1" >/dev/null 2>&1
}

# Print the driver of a network ("bridge", "overlay", ...). Empty when absent.
aidc_network_driver() {
    docker network inspect -f '{{.Driver}}' "$1" 2>/dev/null || printf ''
}

# aidc_assert_attachable <session> <network>
#
# Every guard that must hold before a network is attached, in one place so the
# adhoc and declarative paths cannot drift. Dies with an actionable message.
aidc_assert_attachable() {
    local session="$1" name="$2" own driver
    own="$(aidc_session_network "$session")"

    aidc_valid_network_name "$name" || \
        die "invalid network name: '${name}' (must match ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$)"

    if aidc_is_reserved_network "$name"; then
        case "$name" in
            host) die "refusing to attach the 'host' network: it shares the host network namespace and defeats the sandbox entirely" ;;
            none) die "refusing to attach the 'none' network: it carries no connectivity" ;;
            *)    die "refusing to attach Docker's default 'bridge' network: it reaches every container started without an explicit network, on every port, and provides no DNS. Attach the specific compose network instead (docker network ls)" ;;
        esac
    fi

    [ "$name" != "$own" ] || \
        die "'${name}' is this session's own network; it is attached already"

    aidc_network_exists "$name" || \
        die "no such docker network: '${name}' (list them with: docker network ls)"

    driver="$(aidc_network_driver "$name")"
    case "$driver" in
        bridge) ;;
        "")     die "could not read the driver of network '${name}'" ;;
        *)      die "network '${name}' uses the '${driver}' driver; only bridge networks are supported" ;;
    esac
}

# Print every network a container is attached to, one per line. Empty when the
# container is absent.
aidc_container_networks() {
    docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' \
        "$1" 2>/dev/null | awk 'NF'
}

# Print the FOREIGN networks a session's dev container is on -- everything
# except the session's own compose network. Empty when there are none.
aidc_session_attached_networks() {
    local session="$1" own
    own="$(aidc_session_network "$session")"
    aidc_container_networks "$(container_name "$session" dev)" \
        | grep -vx "$own" || true
}

# ---- declared vs adhoc -------------------------------------------------------
#
# A network is "declared" when the session's rendered compose file lists it, i.e.
# it came from `aidc create --network` / the `networks:` config key and will be
# reattached by `aidc upgrade`. Anything else was attached by
# `aidc network <s> add` and will not survive a recreate.
#
# aidc_declared_networks <compose-file>
#   Prints the networks the compose file declares, one per line. Returns 1
#   (printing nothing) when the file is absent -- callers must distinguish
#   "nothing declared" from "cannot tell", because /tmp gets wiped and a session
#   created on another host has no rendered file here at all.
aidc_declared_networks() {
    local compose_file="$1"
    [ -f "$compose_file" ] || return 1
    if command -v yq >/dev/null 2>&1; then
        yq eval '.networks[] | select(.external == true) | .name' "$compose_file" 2>/dev/null \
            | awk 'NF'
        return 0
    fi
    # Fallback for hosts without yq. Scan ONLY the top-level `networks:` block:
    # the rendered file declares volumes with the same `    name: <x>` shape
    # (aidc-<session>-blocklist, aidc-pyenv-versions, ...), so a document-wide
    # match would report volumes as networks.
    awk '
        /^networks:[[:space:]]*$/ { in_nets = 1; next }
        /^[^[:space:]#]/          { in_nets = 0 }   # any other top-level key ends it
        in_nets && /^    name:/   { sub(/^    name:[[:space:]]*/, ""); print }
    ' "$compose_file" | awk 'NF'
}

# aidc_adhoc_networks <session> <compose-file>
#   Prints the attached networks that the compose file does NOT declare -- the
#   ones a recreate would drop. Prints nothing and returns 1 when the compose
#   file is missing, since every attachment is then unclassifiable.
aidc_adhoc_networks() {
    local session="$1" compose_file="$2" declared net
    declared="$(aidc_declared_networks "$compose_file")" || return 1
    aidc_session_attached_networks "$session" | while IFS= read -r net; do
        [ -z "$net" ] && continue
        printf '%s\n' "$declared" | grep -qx "$net" || printf '%s\n' "$net"
    done
}

# ---- egress posture (NET-14) -------------------------------------------------
#
# Prints "enforced" when the session bridge is a Docker internal network (no NAT,
# so squid is the only way out), "direct" when it is an ordinary NATed bridge,
# and "unknown" when the network is missing.
#
# A session created before v1.3.0 -- or with --egress direct -- reports "direct".
# `aidc upgrade` reuses the compose file rendered at create time, so upgrading
# such a session does NOT switch it to enforced; only kill + create does. That
# gap is worth surfacing rather than letting someone assume protection they do
# not have.
aidc_session_egress_mode() {
    local internal
    internal=$(docker network inspect "$(aidc_session_network "$1")" -f '{{.Internal}}' 2>/dev/null || printf '')
    case "$internal" in
        true)  printf 'enforced' ;;
        false) printf 'direct' ;;
        *)     printf 'unknown' ;;
    esac
}

# ---- capability probes -------------------------------------------------------
#
# Feature-detect rather than parse version strings: distro compose builds carry
# suffixes like "2.40.3+ds1-0ubuntu1" that no sane comparison handles.

# Does `docker network connect` accept --gw-priority? (Docker >= 28)
aidc_connect_supports_gw_priority() {
    docker network connect --help 2>&1 | grep -q -- '--gw-priority'
}

# Does this docker compose understand `gw_priority`? (Compose >= 2.34)
# Validates a throwaway document; creates nothing.
aidc_compose_supports_gw_priority() {
    docker compose -f - config -q >/dev/null 2>&1 <<'EOF'
name: aidc-gw-priority-probe
networks:
  default:
    name: aidc-gw-priority-probe-net
services:
  probe:
    image: alpine
    networks:
      default:
        gw_priority: 100
EOF
}
