#!/usr/bin/env bash
# Unit tests for the TCP egress relay library (scripts/lib/egress.sh, NET-15).
#
# Covers the Docker-free half: parsing and validation, the refusals (aidc-mcp,
# loopback), grouping destinations by host, and the rendered compose service. The
# relay actually carrying a connection, and logging it, is exercised by
# tests/smoke/test-egress-tcp.sh.
#
# The load-bearing assertions:
#   - one relay per HOST: Docker answers an alias with every container carrying it,
#     so two relays for one host would both answer and a client could reach the
#     relay for the wrong port;
#   - the relay forwards to the address resolved on the host, never to the name,
#     which on the session network is its own alias;
#   - aidc-mcp's address and port are refused (MCP-12).
#
# Hygiene: no Docker, no network. Pure function calls.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/egress.sh
. "$AIDC_ROOT/scripts/lib/egress.sh"

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
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (no '$needle' in: $hay)"; FAIL=$((FAIL + 1)) ;;
    esac
}

echo "=== egress_tcp: parsing ==="

parsed() { aidc_egress_parse "$1" 2>/dev/null && printf '%s|%s' "$AIDC_EGRESS_HOST" "$AIDC_EGRESS_PORT"; }
eq "host:port" "yuga.ranch.example.org|5433" "$(parsed yuga.ranch.example.org:5433)"
eq "the host is lower-cased (DNS is case-blind; the alias must match)" "db.example|5432" \
    "$(parsed DB.Example:5432)"
eq "an IPv4 host" "10.42.0.101|5433" "$(parsed 10.42.0.101:5433)"
notok "no port"                  aidc_egress_parse db.example
notok "empty port"               aidc_egress_parse db.example:
notok "empty host"               aidc_egress_parse :5432
notok "port 0"                   aidc_egress_parse db.example:0
notok "port 65536"               aidc_egress_parse db.example:65536
notok "a leading-zero port"      aidc_egress_parse db.example:05432
notok "a port range"             aidc_egress_parse db.example:5432-5433
notok "IPv6 (not supported)"     aidc_egress_parse ::1:5432
notok "a URL"                    aidc_egress_parse postgres://db.example:5432
notok "a label starting with -"  aidc_egress_parse -db.example:5432
notok "a double dot"             aidc_egress_parse db..example:5432
notok "a space"                  aidc_egress_parse 'db example:5432'
notok "shell metacharacters"     aidc_egress_parse 'db;rm:5432'
ok    "65535 is a port"          aidc_egress_valid_port 65535
notok "256.1.1.1 is not IPv4 (and not a name either)" aidc_egress_valid_host 256.1.1.1
ok    "a single-label name"      aidc_egress_valid_host postgres

echo "=== egress_tcp: refusals ==="

refused() { aidc_egress_refusal "$@" >/dev/null; }
ok    "aidc-mcp's own address and port"           refused 10.147.17.5 7878 10.147.17.5:7878
notok "the same address on another port is fine"  refused 10.147.17.5 5432 10.147.17.5:7878
notok "the same port on another address is fine"  refused 10.42.0.101 7878 10.147.17.5:7878
ok    "aidc-mcp on 0.0.0.0: its port on any address" refused 10.42.0.101 7878 0.0.0.0:7878
ok    "loopback"                                  refused 127.0.0.1 5432 ""
ok    "0.0.0.0"                                   refused 0.0.0.0 5432 ""
notok "an ordinary destination"                   refused 10.42.0.101 5433 127.0.0.1:7878
has   "the refusal says why" "aidc-mcp" "$(aidc_egress_refusal 10.1.1.1 7878 10.1.1.1:7878)"

echo "=== egress_tcp: one relay per host ==="

grouped=$(printf '%s\n' \
    "db.example 5432 10.0.0.5" \
    "yuga.example 5433 10.42.0.101" \
    "db.example 6432 10.0.0.5" \
    "db.example 5432 10.0.0.5" | aidc_egress_group)
eq "ports of one host share a line, deduped, in first-seen order" \
    "db.example 10.0.0.5 5432 6432
yuga.example 10.42.0.101 5433" "$grouped"

echo "=== egress_tcp: the relay ==="

script=$(aidc_egress_script yuga.example 10.42.0.101 5433 15433)
has "forwards to the resolved address, not the name" "TCP:10.42.0.101:5433" "$script"
case "$script" in
    *TCP:yuga*) echo "  FAIL: never to the name (its own alias)"; FAIL=$((FAIL + 1)) ;;
    *) echo "  PASS: never to the name (its own alias)"; PASS=$((PASS + 1)) ;;
esac
has "one listener per port" "TCP-LISTEN:15433,fork,reuseaddr TCP:10.42.0.101:15433" "$script"
has "each port logs to the audit dir" "-lf /var/aidc/audit/egress-yuga-example-5433.log" "$script"
has "a dead listener takes the container down, to be restarted" "wait -n; exit 1" "$script"

svc=$(aidc_egress_render_service s1 /home/u/aidc-audit/s1-x v9.9.9 yuga.example 10.42.0.101 5433)
has "service name"             "  egress-yuga-example:" "$svc"
has "container name"           "container_name: aidc-s1-egress-yuga-example" "$svc"
has "forwarder image"          "image: aidc/forwarder:v9.9.9" "$svc"
has "alias = the real name"    "        aliases:
          - yuga.example" "$svc"
has "on the egress network"    "      egress: {}" "$svc"
has "audit dir mounted"        "- /home/u/aidc-audit/s1-x:/var/aidc/audit:rw" "$svc"
has "labelled declared"        'aidc.egress: "declared"' "$svc"
case "$svc" in
    *"
    ports:"*) echo "  FAIL: publishes nothing on the host"; FAIL=$((FAIL + 1)) ;;
    *) echo "  PASS: publishes nothing on the host"; PASS=$((PASS + 1)) ;;
esac

ipsvc=$(aidc_egress_render_service s1 /a v1 10.42.0.101 10.42.0.101 5433)
case "$ipsvc" in
    *aliases:*) echo "  FAIL: an IPv4 destination gets no alias"; FAIL=$((FAIL + 1)) ;;
    *) echo "  PASS: an IPv4 destination gets no alias"; PASS=$((PASS + 1)) ;;
esac
eq "and is reached by the relay's name" "aidc-s1-egress-10-42-0-101" \
    "$(aidc_egress_reach_as s1 10.42.0.101)"
eq "a named destination is reached by its name" "yuga.example" \
    "$(aidc_egress_reach_as s1 yuga.example)"

echo "=== egress_tcp: the rendered compose file ==="

# The service text is spliced in by envsubst, so it must survive rendering intact
# and the whole file must still parse.
rendered=$(AIDC_VERSION_TAG=v9.9.9 SESSION=s1 NET_INTERNAL=true \
    EGRESS_RELAY_SERVICES="$svc" \
    bash "$AIDC_ROOT/proxy/compose-render.sh" < "$AIDC_ROOT/proxy/compose.yaml.template" 2>&1)
has "the relay survives rendering" "TCP-LISTEN:5433,fork,reuseaddr TCP:10.42.0.101:5433" "$rendered"
if python3 -c 'import yaml' 2>/dev/null; then
    got=$(printf '%s' "$rendered" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
s = d["services"]["egress-yuga-example"]
print(s["networks"]["default"]["aliases"][0], sorted(s["networks"]), s["entrypoint"])')
    eq "and parses as the service it should be" \
        "yuga.example ['default', 'egress'] ['/bin/sh', '-c']" "$got"
else
    echo "  SKIP: PyYAML not installed; YAML parse not checked"
fi
empty=$(AIDC_VERSION_TAG=v9.9.9 SESSION=s1 NET_INTERNAL=true \
    bash "$AIDC_ROOT/proxy/compose-render.sh" < "$AIDC_ROOT/proxy/compose.yaml.template" 2>&1)
case "$empty" in
    *egress-*:*) echo "  FAIL: no relays when none are declared"; FAIL=$((FAIL + 1)) ;;
    *) echo "  PASS: no relays when none are declared"; PASS=$((PASS + 1)) ;;
esac

echo
echo "egress_tcp: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
