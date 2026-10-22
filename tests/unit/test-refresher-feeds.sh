#!/usr/bin/env bash
# Unit tests for the refresher's malware feeds (proxy/refresher/refresh.sh, NET-10..12).
#
# abuse.ch's URLhaus and ThreatFox exports now answer 410 Gone without a per-user
# Auth-Key (2026-10-22). URLhaus data comes from the malware-filter project's keyless
# mirror instead, and ThreatFox is gone with no keyless source. HaGeZi TIF is about
# 40 MB and ran out of curl's 60 s under load in smoke, so it gets its own, longer
# limit.
#
# refresh.sh itself runs, against a curl stub on PATH that serves fixture bodies by
# URL and records how it was called. The only change to the copy under test is its
# squid directory, pointed at scratch.
#
# Hygiene: scratch under tests/scratch, removed on exit. Needs bash and gawk. No
# Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REFRESH="$AIDC_ROOT/proxy/refresher/refresh.sh"
SCRATCH="$AIDC_ROOT/tests/scratch/refresher-feeds-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/feeds" "$SCRATCH/squid"

ok() {
    local desc="$1"; shift
    if "$@"; then echo "  PASS: $desc"; PASS=$((PASS + 1))
    else echo "  FAIL: $desc"; FAIL=$((FAIL + 1)); fi
}

URLHAUS_PRIMARY="https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts.txt"
URLHAUS_MIRROR="https://curbengh.github.io/malware-filter/urlhaus-filter-hosts.txt"
HAGEZI="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.txt"

# Bodies as the feeds serve them (header lines as measured on 2026-10-22).
cat > "$SCRATCH/feeds/urlhaus" <<'EOF'
# Title: Malicious Hosts Blocklist
# Updated: 2026-10-21T12:25:27Z
# Source: https://urlhaus.abuse.ch/api/
0.0.0.0 02Teste.cc
0.0.0.0 0akw8w.com

0.0.0.0 10.185.202.64.host.secureserver.net
EOF
cat > "$SCRATCH/feeds/hagezi" <<'EOF'
# Title: HaGeZi's Threat Intelligence Feeds DNS Blocklist
*.evil-tif.example
*.Other-TIF.example
EOF

# curl stub: serves a feed by URL (FAIL_URLS lists URLs that fail like a 410/timeout)
# and logs every call's arguments, one call per line.
cat > "$SCRATCH/bin/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SCRATCH/curl.log"
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        http*) url="\$1"; shift ;;
        *) shift ;;
    esac
done
case " \${FAIL_URLS:-} " in *" \$url "*) exit 22 ;; esac
case "\$url" in
    $URLHAUS_PRIMARY|$URLHAUS_MIRROR) cp "$SCRATCH/feeds/urlhaus" "\$out" ;;
    $HAGEZI) cp "$SCRATCH/feeds/hagezi" "\$out" ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$SCRATCH/bin/curl"

sed "s#^SQUID_DIR=\"/etc/squid\"\$#SQUID_DIR=\"$SCRATCH/squid\"#" "$REFRESH" > "$SCRATCH/refresh.sh"
ok "the copy under test writes to scratch" grep -q "^SQUID_DIR=\"$SCRATCH/squid\"" "$SCRATCH/refresh.sh"

run_refresh() {   # env FAIL_URLS=... ; prints stdout+stderr to $SCRATCH/out
    rm -f "$SCRATCH/curl.log"
    PATH="$SCRATCH/bin:$PATH" bash "$SCRATCH/refresh.sh" > "$SCRATCH/out" 2>&1
}

echo "=== refresher: every feed answers ==="
run_refresh; rc=$?
LIST="$SCRATCH/squid/blocklist.txt"
ok "the refresh succeeds" [ "$rc" -eq 0 ]
ok "URLhaus domains come from the malware-filter mirror, lower-cased" \
    grep -qx '02teste.cc' "$LIST"
ok "a URLhaus host that looks like an IP-derived name is kept" \
    grep -qx '10.185.202.64.host.secureserver.net' "$LIST"
ok "HaGeZi wildcard entries are listed by their domain" grep -qx 'other-tif.example' "$LIST"
ok "comment lines are not domains" bash -c "! grep -q '#\\|^0\\.0\\.0\\.0\$\\|^title' '$LIST'"
ok "the list is in byte order" bash -c "LC_ALL=C sort -c '$LIST'"
ok "the summary names only the feeds that exist" \
    grep -qE '^refreshed: 5 entries from urlhaus=3 hagezi=2 additions=0 \(took [0-9]+s\)$' "$SCRATCH/out"
ok "URLhaus is fetched from the malware-filter mirror" grep -qF "$URLHAUS_PRIMARY" "$SCRATCH/curl.log"
ok "nothing is fetched from abuse.ch (410 Gone without an Auth-Key)" \
    bash -c "! grep -q 'abuse.ch' '$SCRATCH/curl.log'"
ok "ThreatFox is gone from the log" bash -c "! grep -qi 'threatfox' '$SCRATCH/out'"
HAGEZI_CALL=$(grep -F "$HAGEZI" "$SCRATCH/curl.log")
HAGEZI_MAX=$(printf '%s\n' "$HAGEZI_CALL" | sed -n 's/.*--max-time \([0-9]*\).*/\1/p')
ok "HaGeZi TIF gets at least 300 s to download (~40 MB; 60 s ran out under load)" \
    [ "${HAGEZI_MAX:-0}" -ge 300 ]
ok "HaGeZi TIF still gives up early on a dead connection" \
    bash -c "printf '%s' '$HAGEZI_CALL' | grep -q -- '--connect-timeout'"

echo "=== refresher: the gitlab mirror is down ==="
FAIL_URLS="$URLHAUS_PRIMARY" run_refresh; rc=$?
ok "the refresh succeeds" [ "$rc" -eq 0 ]
ok "URLhaus domains come from the github mirror" grep -qx '0akw8w.com' "$SCRATCH/squid/blocklist.txt"
GITLAB_AT=$(grep -nF "$URLHAUS_PRIMARY" "$SCRATCH/curl.log" | cut -d: -f1 | head -1)
GITHUB_AT=$(grep -nF "$URLHAUS_MIRROR" "$SCRATCH/curl.log" | cut -d: -f1 | head -1)
ok "the github mirror was asked after gitlab" \
    bash -c "[ -n '$GITLAB_AT' ] && [ -n '$GITHUB_AT' ] && [ '$GITLAB_AT' -lt '$GITHUB_AT' ]"
ok "the log says the gitlab mirror failed" grep -q "urlhaus: $URLHAUS_PRIMARY failed" "$SCRATCH/out"

echo "=== refresher: every feed fails ==="
printf 'kept.example\n' > "$SCRATCH/squid/blocklist.txt"
FAIL_URLS="$URLHAUS_PRIMARY $URLHAUS_MIRROR $HAGEZI" run_refresh; rc=$?
ok "the refresh fails (NET-11)" [ "$rc" -ne 0 ]
ok "and leaves the last good list in place" \
    [ "$(cat "$SCRATCH/squid/blocklist.txt")" = "kept.example" ]
ok "each failed feed is named in the log" \
    bash -c "grep -q 'urlhaus: FETCH FAILED' '$SCRATCH/out' && grep -q 'hagezi: FETCH FAILED' '$SCRATCH/out'"
ok "a failed feed is a WARN line naming it" \
    bash -c "grep -q '^aidc-refresher: WARN urlhaus: ' '$SCRATCH/out' && grep -q '^aidc-refresher: WARN hagezi: ' '$SCRATCH/out'"

echo "=== refresher: a feed answers but lists nothing ==="
# How a feed is lost without a failed download: a changed format, or an error page
# served with 200. The list still publishes from the other feed (NET-11), so only
# the log can say so.
printf '# Title: Malicious Hosts Blocklist\n<html>moved</html>\n' > "$SCRATCH/feeds/urlhaus"
run_refresh; rc=$?
ok "the refresh still succeeds on the other feed" [ "$rc" -eq 0 ]
ok "the empty feed is a WARN line naming it" \
    grep -q '^aidc-refresher: WARN urlhaus: fetched but yielded 0 entries' "$SCRATCH/out"
ok "the summary shows its zero" grep -q 'urlhaus=0 hagezi=2 ' "$SCRATCH/out"
ok "a feed that yielded entries is not warned about" bash -c "! grep -q 'WARN hagezi' '$SCRATCH/out'"

echo
echo "refresher feeds: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
