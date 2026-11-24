#!/usr/bin/env bash
# Unit test for the squid entrypoint wrapper (proxy/squid/aidc-entrypoint.sh).
#
# MCP-12: dev containers must not reach aidc-mcp. The session's squid allows every
# destination for local sources, so the entrypoint turns AIDC_MCP_DENY ("addr:port")
# into a deny rule that must land BEFORE `http_access allow localnet` (squid is
# first-match). This runs the shipped script with its squid paths redirected and the
# base image's entrypoint replaced by a stub that records its arguments, so no Docker
# or squid is needed. It also checks the DNS-override rewrite still works alone and
# combined with the deny rule, since both derive the same config copy.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENTRY="$AIDC_ROOT/proxy/squid/aidc-entrypoint.sh"

SCRATCH="$AIDC_ROOT/tests/scratch/squid-entry-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH"

assert() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL + 1))
    fi
}

# The squid image (a 7.x Rock) has only these of the usual commands. Run the
# entrypoint with exactly them on PATH, so a script that reaches for cp, cut, head
# or sed fails here instead of in a freshly built image.
IMAGE_BIN="$SCRATCH/image-bin"
mkdir -p "$IMAGE_BIN"
for c in sh cat grep awk perl; do
    ln -s "$(command -v "$c")" "$IMAGE_BIN/$c"
done

# Stub for the base image's entrypoint: records the -f config path it was given.
cat > "$SCRATCH/stub.sh" <<'STUB'
#!/bin/sh
printf '%s\n' "$2" > "$STUB_OUT"
STUB
# The stub is called by absolute path, so it needs no PATH of its own.
chmod +x "$SCRATCH/stub.sh"

run_entry() {   # env assignments..., then runs the entrypoint; sets CONF_USED
    local case_dir="$SCRATCH/$1"; shift
    mkdir -p "$case_dir"
    cp "$AIDC_ROOT/proxy/squid/squid.conf" "$case_dir/squid.conf"
    env AIDC_SQUID_CONF="$case_dir/squid.conf" AIDC_SQUID_DERIVED="$case_dir/derived.conf" \
        AIDC_SQUID_ENTRYPOINT="$SCRATCH/stub.sh" STUB_OUT="$case_dir/used" \
        AIDC_DNS_SERVERS="" AIDC_MCP_DENY="" PATH="$IMAGE_BIN" "$@" \
        "$IMAGE_BIN/sh" "$ENTRY" >"$case_dir/log" 2>&1
    RC=$?
    CONF_USED=$(cat "$case_dir/used" 2>/dev/null || true)
}

line_of() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }

echo "== no overrides: the baked config is used unchanged"
run_entry plain
assert "exits 0" "[ $RC -eq 0 ]"
assert "squid started from the baked config" "[ '$CONF_USED' = '$SCRATCH/plain/squid.conf' ]"
assert "no derived copy written" "[ ! -e '$SCRATCH/plain/derived.conf' ]"

echo "== AIDC_MCP_DENY with a specific address"
run_entry mcp AIDC_MCP_DENY=10.0.0.16:7878
D="$SCRATCH/mcp/derived.conf"
assert "exits 0" "[ $RC -eq 0 ]"
assert "squid started from the derived config" "[ '$CONF_USED' = '$D' ]"
assert "port acl present" "grep -qx 'acl aidc_mcp_port port 7878' '$D'"
assert "dst acl present" "grep -qx 'acl aidc_mcp_dst dst 10.0.0.16' '$D'"
assert "deny rule present" "grep -qx 'http_access deny aidc_mcp_dst aidc_mcp_port' '$D'"
assert "deny comes before allow localnet" \
    "[ \$(line_of '$D' '^http_access deny aidc_mcp') -lt \$(line_of '$D' '^http_access allow localnet') ]"
assert "acls come before the deny that uses them" \
    "[ \$(line_of '$D' '^acl aidc_mcp_dst') -lt \$(line_of '$D' '^http_access deny aidc_mcp') ]"
assert "inserted exactly once" "[ \$(grep -c '^http_access deny aidc_mcp' '$D') -eq 1 ]"
assert "baked config left untouched" "! grep -q aidc_mcp '$SCRATCH/mcp/squid.conf'"
assert "dns_nameservers kept (no DNS override)" "grep -q '^dns_nameservers ' '$D'"

echo "== AIDC_MCP_DENY bound to all interfaces denies the port everywhere"
run_entry all AIDC_MCP_DENY=0.0.0.0:7878
D="$SCRATCH/all/derived.conf"
assert "exits 0" "[ $RC -eq 0 ]"
assert "port-only deny rule" "grep -qx 'http_access deny aidc_mcp_port' '$D'"
assert "no dst acl" "! grep -q '^acl aidc_mcp_dst' '$D'"

echo "== DNS override and MCP deny together"
run_entry both AIDC_DNS_SERVERS="10.0.0.1 9.9.9.9" AIDC_MCP_DENY=10.0.0.16:7878
D="$SCRATCH/both/derived.conf"
assert "exits 0" "[ $RC -eq 0 ]"
assert "dns_nameservers removed" "! grep -q '^dns_nameservers ' '$D'"
assert "deny rule present before allow" \
    "[ \$(line_of '$D' '^http_access deny aidc_mcp') -lt \$(line_of '$D' '^http_access allow localnet') ]"

echo "== DNS override alone still works"
run_entry dns AIDC_DNS_SERVERS="10.0.0.1"
assert "exits 0" "[ $RC -eq 0 ]"
assert "dns_nameservers removed" "! grep -q '^dns_nameservers ' '$SCRATCH/dns/derived.conf'"

echo "== malformed AIDC_MCP_DENY fails loudly instead of starting an open proxy"
run_entry badport AIDC_MCP_DENY=10.0.0.16:78x8
assert "bad port exits non-zero" "[ $RC -ne 0 ]"
assert "squid not started" "[ -z '$CONF_USED' ]"
run_entry badaddr "AIDC_MCP_DENY=10.0.0.16;rm:7878"
assert "bad address exits non-zero" "[ $RC -ne 0 ]"

echo "== a config with no 'allow localnet' line cannot silently skip the deny"
run_entry noallow AIDC_MCP_DENY=10.0.0.16:7878
cp "$AIDC_ROOT/proxy/squid/squid.conf" "$SCRATCH/noallow/squid.conf"
sed -i '/^http_access allow localnet/d' "$SCRATCH/noallow/squid.conf"
rm -f "$SCRATCH/noallow/used"
env AIDC_SQUID_CONF="$SCRATCH/noallow/squid.conf" AIDC_SQUID_DERIVED="$SCRATCH/noallow/derived.conf" \
    AIDC_SQUID_ENTRYPOINT="$SCRATCH/stub.sh" STUB_OUT="$SCRATCH/noallow/used" \
    AIDC_MCP_DENY=10.0.0.16:7878 PATH="$IMAGE_BIN" "$IMAGE_BIN/sh" "$ENTRY" >/dev/null 2>&1
assert "exits non-zero" "[ $? -ne 0 ]"
assert "squid not started" "[ ! -e '$SCRATCH/noallow/used' ]"

echo "== AIDC_PUBLIC_ONLY (the git container's proxy on Docker): private destinations refused"
run_entry public AIDC_PUBLIC_ONLY=1
D="$SCRATCH/public/derived.conf"
assert "exits 0" "[ $RC -eq 0 ]"
assert "squid started from the derived config" "[ '$CONF_USED' = '$D' ]"
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10 ::1 fc00::/7 fe80::/10 64:ff9b::/96 64:ff9b:1::/48 2002::/16; do
    assert "refuses $net" "grep '^acl aidc_not_public dst' '$D' | grep -qF ' $net'"
done
assert "deny comes before allow localnet" \
    "[ \$(line_of '$D' '^http_access deny aidc_not_public') -lt \$(line_of '$D' '^http_access allow localnet') ]"
assert "baked config left untouched" "! grep -q aidc_not_public '$SCRATCH/public/squid.conf'"
# squid holds IPv4 addresses as ::ffff:a.b.c.d, so the IPv4 ranges already refuse mapped private
# addresses, and a ::ffff:0:0/96 range would refuse every IPv4 destination (seen live).
assert "no ::ffff:0:0/96 range (it would match every IPv4 address)" "! grep '^acl aidc_not_public dst' '$D' | grep -qi '::ffff'"
assert "resolves through Quad9 (the baked dns_nameservers kept)" "grep -qx 'dns_nameservers 9.9.9.9 149.112.112.112' '$D'"
run_entry public-dns AIDC_PUBLIC_ONLY=1 AIDC_DNS_SERVERS=192.0.2.53
assert "a DNS override is refused for the public-only proxy" "[ $RC -ne 0 ] && [ ! -e '$SCRATCH/public-dns/used' ]"
mkdir -p "$SCRATCH/public-nodns"
grep -v '^dns_nameservers ' "$AIDC_ROOT/proxy/squid/squid.conf" > "$SCRATCH/public-nodns/squid.conf"
env AIDC_SQUID_CONF="$SCRATCH/public-nodns/squid.conf" AIDC_SQUID_DERIVED="$SCRATCH/public-nodns/derived.conf" \
    AIDC_SQUID_ENTRYPOINT="$SCRATCH/stub.sh" STUB_OUT="$SCRATCH/public-nodns/used" \
    AIDC_PUBLIC_ONLY=1 PATH="$IMAGE_BIN" "$IMAGE_BIN/sh" "$ENTRY" >/dev/null 2>&1
assert "a config without the Quad9 resolvers does not start as the public-only proxy" "[ ! -e '$SCRATCH/public-nodns/used' ]"
run_entry public-mcp AIDC_PUBLIC_ONLY=1 AIDC_MCP_DENY=192.0.2.10:7878
assert "with the MCP deny too, both land before the allow" \
    "[ \$(line_of '$SCRATCH/public-mcp/derived.conf' '^http_access deny aidc_not_public') -lt \$(line_of '$SCRATCH/public-mcp/derived.conf' '^http_access allow localnet') ]"
run_entry public-off AIDC_PUBLIC_ONLY=0
assert "off unless exactly 1: no derived config" "[ ! -e '$SCRATCH/public-off/derived.conf' ]"
rm -f "$SCRATCH/noallow/used"
env AIDC_SQUID_CONF="$SCRATCH/noallow/squid.conf" AIDC_SQUID_DERIVED="$SCRATCH/noallow/derived2.conf" \
    AIDC_SQUID_ENTRYPOINT="$SCRATCH/stub.sh" STUB_OUT="$SCRATCH/noallow/used" \
    AIDC_PUBLIC_ONLY=1 PATH="$IMAGE_BIN" "$IMAGE_BIN/sh" "$ENTRY" >/dev/null 2>&1
assert "a config with no 'allow localnet' cannot skip the public-only rule" "[ ! -e '$SCRATCH/noallow/used' ]"

echo
echo "squid entrypoint: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
