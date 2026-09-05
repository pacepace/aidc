#!/usr/bin/env bash
# Unit tests for the attached-network library (scripts/lib/network.sh, NET-13).
#
# Covers the Docker-free half: name validation, reserved-network refusal, and
# compose block rendering. CI's `unit` job runs with no Docker daemon, so the
# Docker-facing helpers (aidc_network_exists, aidc_assert_attachable, the
# capability probes) are exercised by tests/smoke instead.
#
# The rendering assertions are the load-bearing ones. Two properties matter:
#
#   1. With no attachments the dev `networks:` block renders the pre-NET-13
#      sequence form byte-for-byte. Every existing session must keep producing
#      the compose file it produced before, so sessions that never asked for a
#      foreign network neither change behaviour nor start requiring a compose
#      new enough to know `gw_priority`.
#
#   2. With attachments, gw_priority is present and the session's own network
#      outranks every attached one. Measured on Docker/Compose 29.1.3/2.40.3:
#      compose's `priority` orders the connect sequence but does NOT pick the
#      default gateway -- only `gw_priority` does. Drop it and every attached
#      session silently routes ALL its egress, squid-proxied traffic included,
#      out through the foreign network's gateway. That regression is invisible
#      in normal use, which is exactly why it is pinned by a test.
#
# Hygiene: no scratch files, no Docker, no network. Pure function calls.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/network.sh
. "$AIDC_ROOT/scripts/lib/network.sh"

PASS=0
FAIL=0

ok() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL + 1))
    fi
}

notok() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  FAIL: $desc"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    fi
}

eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL + 1))
        echo "        want: [$want]"
        echo "        got:  [$got]"
    fi
}

contains() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc"; FAIL=$((FAIL + 1))
           echo "        missing: [$needle]"
           echo "        in:      [$hay]" ;;
    esac
}

echo "=== network-attach unit test ==="
echo

# --- 1: session network naming ----------------------------------------------
echo "-- session network naming --"
eq "session network name" "aidc-metallm-net" "$(aidc_session_network metallm)"

# --- 2: network name validation ---------------------------------------------
echo
echo "-- name validation --"
ok    "plain name"                    aidc_valid_network_name "metallm_default"
ok    "dashes"                        aidc_valid_network_name "my-stack-net"
ok    "dots"                          aidc_valid_network_name "stack.v2_default"
ok    "digits only"                   aidc_valid_network_name "123"
notok "empty"                         aidc_valid_network_name ""
notok "leading dash"                  aidc_valid_network_name "-bad"
notok "leading dot"                   aidc_valid_network_name ".bad"
notok "leading underscore"            aidc_valid_network_name "_bad"
notok "shell metacharacter"           aidc_valid_network_name 'net;rm -rf /'
notok "space"                         aidc_valid_network_name "two words"
notok "slash"                         aidc_valid_network_name "a/b"
notok "over 128 chars"                aidc_valid_network_name "$(printf 'a%.0s' $(seq 1 129))"
ok    "exactly 128 chars"             aidc_valid_network_name "$(printf 'a%.0s' $(seq 1 128))"

# --- 3: reserved networks ----------------------------------------------------
#
# `host` is the one that matters: attaching it shares the host network
# namespace outright, which is a total sandbox bypass, not a widening.
echo
echo "-- reserved networks --"
ok    "host is reserved"              aidc_is_reserved_network "host"
ok    "none is reserved"              aidc_is_reserved_network "none"
ok    "default bridge is reserved"    aidc_is_reserved_network "bridge"
notok "a compose net is not"          aidc_is_reserved_network "metallm_default"
notok "'bridged' is not 'bridge'"     aidc_is_reserved_network "bridged"
notok "empty is not reserved"         aidc_is_reserved_network ""

# --- 4: rendering with no attachments ---------------------------------------
#
# Byte-for-byte backward compatibility. If this fails, every session on the
# host re-renders differently on its next upgrade.
echo
echo "-- rendering: no attachments --"
EXTNET_DECLARATIONS="sentinel"; DEV_NETWORKS_BLOCK="sentinel"
aidc_render_extnet_blocks ""
eq "empty list -> no declarations"    ""                "$EXTNET_DECLARATIONS"
eq "empty list -> bare sequence form" "      - default" "$DEV_NETWORKS_BLOCK"

EXTNET_DECLARATIONS="sentinel"; DEV_NETWORKS_BLOCK="sentinel"
aidc_render_extnet_blocks "$(printf '\n\n')"
eq "blank lines -> no declarations"    ""                "$EXTNET_DECLARATIONS"
eq "blank lines -> bare sequence form" "      - default" "$DEV_NETWORKS_BLOCK"

# --- 5: rendering with one attachment ---------------------------------------
echo
echo "-- rendering: one attachment --"
aidc_render_extnet_blocks "metallm_default"
eq "single declaration block" \
"  extnet0:
    name: metallm_default
    external: true" "$EXTNET_DECLARATIONS"
eq "single dev networks block" \
"      default:
        priority: 100
        gw_priority: 100
      extnet0:
        priority: 0
        gw_priority: -100" "$DEV_NETWORKS_BLOCK"

# --- 6: rendering with several attachments -----------------------------------
echo
echo "-- rendering: several attachments --"
aidc_render_extnet_blocks "$(printf 'metallm_default\nfaidh_default\nthird.net\n')"
contains "declares extnet0 by name" "name: metallm_default" "$EXTNET_DECLARATIONS"
contains "declares extnet1 by name" "name: faidh_default"   "$EXTNET_DECLARATIONS"
contains "declares extnet2 by name" "name: third.net"       "$EXTNET_DECLARATIONS"
contains "marks them external"      "external: true"        "$EXTNET_DECLARATIONS"
eq "one external: true per network" "3" \
   "$(printf '%s\n' "$EXTNET_DECLARATIONS" | grep -c 'external: true')"
eq "keys are generated, not derived from names" "3" \
   "$(printf '%s\n' "$EXTNET_DECLARATIONS" | grep -cE '^  extnet[0-9]+:$')"

# --- 7: the gateway pin (the regression this file exists for) ----------------
echo
echo "-- gateway pin --"
eq "own network gets gw_priority 100" "1" \
   "$(printf '%s\n' "$DEV_NETWORKS_BLOCK" | grep -c 'gw_priority: 100')"
eq "every attached network is outranked" "3" \
   "$(printf '%s\n' "$DEV_NETWORKS_BLOCK" | grep -c 'gw_priority: -100')"
eq "default is listed first" "      default:" \
   "$(printf '%s\n' "$DEV_NETWORKS_BLOCK" | head -1)"
# No attached network may carry a gw_priority >= the session network's.
eq "no attached network outranks the session network" "" \
   "$(printf '%s\n' "$DEV_NETWORKS_BLOCK" | awk '
        /^      extnet[0-9]+:$/ { inext=1; next }
        /^      default:$/      { inext=0; next }
        inext && /gw_priority:/ { v=$2+0; if (v >= 100) print "violation: " $0 }
     ')"

# --- 8: idempotence / no state leak ------------------------------------------
#
# The function assigns rather than appends: a second call with a shorter list
# must not carry entries over from the first.
echo
echo "-- no state leak between calls --"
aidc_render_extnet_blocks "$(printf 'a_net\nb_net\n')"
aidc_render_extnet_blocks "c_net"
eq "second call replaces the first" "1" \
   "$(printf '%s\n' "$EXTNET_DECLARATIONS" | grep -c 'external: true')"
contains "second call kept the new network" "name: c_net" "$EXTNET_DECLARATIONS"
notok "second call dropped the old ones" \
    grep -q 'a_net' <<<"$EXTNET_DECLARATIONS"

aidc_render_extnet_blocks "d_net"
aidc_render_extnet_blocks ""
eq "clearing resets declarations"  ""                "$EXTNET_DECLARATIONS"
eq "clearing resets dev block"     "      - default" "$DEV_NETWORKS_BLOCK"

# --- 9: rendered YAML indentation --------------------------------------------
#
# The blocks are spliced into compose.yaml.template by envsubst, so their
# indentation has to match the surrounding document exactly: top-level network
# keys at 2 spaces, the dev service's network keys at 6.
echo
echo "-- indentation contract --"
aidc_render_extnet_blocks "x_net"
eq "top-level network key at 2 spaces" "  extnet0:" \
   "$(printf '%s\n' "$EXTNET_DECLARATIONS" | sed -n '1p')"
eq "its fields at 4 spaces" "    name: x_net" \
   "$(printf '%s\n' "$EXTNET_DECLARATIONS" | sed -n '2p')"
eq "dev network key at 6 spaces" "      default:" \
   "$(printf '%s\n' "$DEV_NETWORKS_BLOCK" | sed -n '1p')"
eq "its fields at 8 spaces" "        priority: 100" \
   "$(printf '%s\n' "$DEV_NETWORKS_BLOCK" | sed -n '2p')"
eq "no trailing blank line in declarations" "  extnet0:
    name: x_net
    external: true" "$EXTNET_DECLARATIONS"

# --- summary -----------------------------------------------------------------
echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
