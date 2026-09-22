#!/usr/bin/env bash
# Unit tests for squid's malware-blocklist helper (proxy/squid/aidc-blocklist-helper.pl,
# NET-16), and for the refresher writing the list the way the helper needs it.
#
# Squid used to load the list itself and had to reload for every new one; a reload is
# a restart, and squid refused all connections for ~20 s (issue #34). The helper is
# what lets it stop: it must find domains by binary search on the sorted file, block
# subdomains of a listed domain, pick up a swapped-in list without being restarted,
# and fail closed when there is no list. Driven exactly as squid drives it: one
# process, "<channel> <host>" lines in, "<channel> OK|ERR|BH" lines out.
#
# Hygiene: scratch under tests/scratch, removed on exit. Needs perl (every CI runner
# and the squid image have it). No Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$AIDC_ROOT/proxy/squid/aidc-blocklist-helper.pl"
SCRATCH="$AIDC_ROOT/tests/scratch/blocklist-helper-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH"

eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

# A list the way the refresher writes it: lower-case, byte-sorted, one per line.
printf '%s\n' evil.example bad-actor.test 0day.example xn--80ak6aa92e.example \
    | LC_ALL=C sort -u > "$SCRATCH/blocklist.txt"

# Ask the helper about each host, one process for all of them, like squid does.
ask() {   # $1 = list path; then hosts. Prints the answers, space-separated.
    local list="$1" i=0 host
    shift
    for host in "$@"; do i=$((i + 1)); printf '%s %s -\n' "$i" "$host"; done \
        | perl "$HELPER" "$list" | awk '{ printf "%s%s", sep, $2; sep = " " }'
}

echo "=== blocklist helper: lookups ==="
# Squid's actual line is "<channel> <host> -" (measured on squid 7.2: the "-" is its
# placeholder for acl values). The first cut read "evil.example -" as the host and
# answered ERR for every listed domain, while every by-hand test, sent without the
# dash, passed. So the test sends squid's line, dash included.
eq "a listed domain is blocked (OK), echoing the channel id" "1 OK" \
    "$(printf '1 evil.example -\n' | perl "$HELPER" "$SCRATCH/blocklist.txt")"
eq "exact, subdomains at any depth, case and a trailing dot" "OK OK OK OK OK" \
    "$(ask "$SCRATCH/blocklist.txt" evil.example www.evil.example a.b.c.evil.example EVIL.Example evil.example.)"
eq "unlisted hosts pass (ERR): a sibling, a parent, a lookalike, another TLD" "ERR ERR ERR ERR" \
    "$(ask "$SCRATCH/blocklist.txt" good.example example notevil.example evil.example.com)"
eq "the first and last entries of the sorted file are found" "OK OK" \
    "$(ask "$SCRATCH/blocklist.txt" 0day.example xn--80ak6aa92e.example)"
# An address is looked up whole: with "0.1" on the list, 10.0.0.1 must not match it
# as a "parent domain".
printf '%s\n' 0.1 10.9.9.9 | LC_ALL=C sort -u > "$SCRATCH/ips.txt"
eq "an IP address is looked up as written, never split into 'parent domains'" "ERR OK" \
    "$(ask "$SCRATCH/ips.txt" 10.0.0.1 10.9.9.9)"

echo "=== blocklist helper: a new list, no restart ==="
# One helper process across an atomic swap, as the refresher does it (write, rename).
{
    printf '1 fresh.example\n'
    sleep 1
    printf '%s\n' evil.example fresh.example | LC_ALL=C sort -u > "$SCRATCH/blocklist.txt.new"
    mv -f "$SCRATCH/blocklist.txt.new" "$SCRATCH/blocklist.txt"
    printf '2 fresh.example\n3 bad-actor.test\n'
} | perl "$HELPER" "$SCRATCH/blocklist.txt" > "$SCRATCH/swap.out"
eq "before the swap: not listed; after it: listed, and dropped entries are gone" \
    "1 ERR|2 OK|3 ERR" "$(paste -sd'|' "$SCRATCH/swap.out")"

# If the list vanishes after it was opened, the last good one stays in service
# (the refresher never leaves it missing, NET-11, but the helper must not fail open).
{
    printf '1 evil.example\n'
    sleep 1
    rm -f "$SCRATCH/blocklist.txt"
    printf '2 evil.example\n'
} | perl "$HELPER" "$SCRATCH/blocklist.txt" > "$SCRATCH/gone.out"
eq "a list removed mid-run: the open one keeps answering" "1 OK|2 OK" \
    "$(paste -sd'|' "$SCRATCH/gone.out")"

echo "=== blocklist helper: no list fails closed ==="
got=$(printf '7 evil.example\n' | perl "$HELPER" "$SCRATCH/does-not-exist.txt")
eq "no list at all answers BH (squid treats the check as failed, not as 'not listed')" \
    "7 BH" "${got%% message=*}"

echo "=== the refresher writes what the helper needs ==="
REFRESH="$AIDC_ROOT/proxy/refresher/refresh.sh"
eq "the list is sorted in byte order (LC_ALL=C sort)" "1" "$(grep -c 'LC_ALL=C sort -u' "$REFRESH")"
eq "and lower-cased before sorting" "1" "$(grep -c "tr '\[:upper:\]' '\[:lower:\]'" "$REFRESH")"
eq "and squid is no longer signalled to reload" "0" "$(grep -cE '^[^#]*kill -HUP' "$REFRESH")"
eq "the image's seed list, too, is in byte order" "sorted" \
    "$(LC_ALL=C sort -c "$AIDC_ROOT/proxy/squid/blocklist.txt" 2>/dev/null && echo sorted || echo unsorted)"
eq "squid asks the helper instead of loading the list" "1|0" \
    "$(grep -c '^acl malware_domains external aidc_blocklist' "$AIDC_ROOT/proxy/squid/squid.conf")|$(grep -c 'dstdomain "/etc/squid/blocklist.txt"' "$AIDC_ROOT/proxy/squid/squid.conf")"

echo
echo "blocklist helper: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
