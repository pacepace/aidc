#!/usr/bin/env bash
# aidc refresher — one-shot refresh of Squid's malware blocklist.
#
# Fetches the URLhaus and HaGeZi-TIF feeds, normalizes each to one domain per
# line, merges with per-project additions, dedupes/sorts, and atomically writes
# /etc/squid/blocklist.txt.
#
# URLhaus data comes from the malware-filter project's keyless mirror (hosts
# format, rebuilt every 12 h; gitlab first, its github copy if that fails):
# abuse.ch's own exports answer 410 Gone without a per-user Auth-Key since
# 2026-10. ThreatFox was dropped for the same reason: it has no keyless source.
#
# Failure semantics (NET-11):
#   - Per-feed failures are logged and tolerated; the others still feed in.
#   - If the merged result is empty (every feed failed and no additions),
#     EXIT 1 WITHOUT TOUCHING the existing blocklist.
#
# Feed URLs are baked in (NET-12) — do not parameterize.

set -euo pipefail

# ---- hard-coded feeds (NET-12) ------------------------------------------------
URLHAUS_URL="https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts.txt"
URLHAUS_MIRROR_URL="https://curbengh.github.io/malware-filter/urlhaus-filter-hosts.txt"
HAGEZI_TIF_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.txt"

# ---- paths --------------------------------------------------------------------
SQUID_DIR="/etc/squid"
TARGET="${SQUID_DIR}/blocklist.txt"
TARGET_NEW="${SQUID_DIR}/blocklist.txt.new"
ADDITIONS="${SQUID_DIR}/blocklist-additions.conf"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

URLHAUS_RAW="${WORK}/urlhaus.raw"
HAGEZI_RAW="${WORK}/hagezi.raw"

URLHAUS_OUT="${WORK}/urlhaus.domains"
HAGEZI_OUT="${WORK}/hagezi.domains"
ADDITIONS_OUT="${WORK}/additions.domains"

: > "$URLHAUS_OUT"
: > "$HAGEZI_OUT"
: > "$ADDITIONS_OUT"

start_ts=$(date +%s)

log()  { echo "aidc-refresher: $*" >&2; }
# A feed that failed, or answered with nothing usable, is a WARN line naming it:
# the list still publishes from the other feeds (NET-11), so this line is the only
# sign that one is lost. Two abuse.ch feeds went quietly to 410 Gone that way.
warn() { log "WARN $*"; }
# feed_done <name> <domains-file>: log the feed's count, or warn when it is empty.
feed_done() {
    local n
    n=$(wc -l < "$2" | tr -d ' ')
    if [[ "$n" -eq 0 ]]; then
        warn "$1: fetched but yielded 0 entries"
    else
        log "$1: ${n} entries"
    fi
}

fetch() {
    # fetch <url> <out> [max-seconds]  -> 0 on success, non-zero on failure.
    # The whole-transfer limit defaults to 60 s; a large feed passes its own.
    local url="$1" out="$2" max="${3:-60}"
    if curl -fsSL --connect-timeout 15 --max-time "$max" -o "$out" "$url"; then
        return 0
    else
        return 1
    fi
}

# ---- URLhaus (malware-filter mirror) ------------------------------------------
# Format: "0.0.0.0 some-domain.example" per line; comments start with '#'.
urlhaus_ok=0
if fetch "$URLHAUS_URL" "$URLHAUS_RAW"; then
    urlhaus_ok=1
else
    warn "urlhaus: $URLHAUS_URL failed, trying $URLHAUS_MIRROR_URL"
    fetch "$URLHAUS_MIRROR_URL" "$URLHAUS_RAW" && urlhaus_ok=1
fi
if [[ "$urlhaus_ok" -eq 1 ]]; then
    gawk '$1 == "0.0.0.0" && $2 != "" && $2 !~ /^#/ { print tolower($2) }' \
        "$URLHAUS_RAW" > "$URLHAUS_OUT" || true
    feed_done urlhaus "$URLHAUS_OUT"
else
    warn "urlhaus: FETCH FAILED ($URLHAUS_URL, $URLHAUS_MIRROR_URL)"
fi

# ---- HaGeZi TIF (wildcard) ----------------------------------------------------
# Format: lines like "*.evil.example"; also has '#' comments and blanks.
# About 40 MB: 60 s ran out under load (31 of 39 MB received in a smoke run).
if fetch "$HAGEZI_TIF_URL" "$HAGEZI_RAW" 300; then
    gawk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^\*\./ {
            d = substr($0, 3)
            gsub(/[[:space:]]/, "", d)
            if (d != "") print tolower(d)
        }
    ' "$HAGEZI_RAW" > "$HAGEZI_OUT" || true
    feed_done hagezi "$HAGEZI_OUT"
else
    warn "hagezi: FETCH FAILED ($HAGEZI_TIF_URL)"
fi

# ---- per-project additions (NET-09) -------------------------------------------
# /etc/squid/blocklist-additions.conf is mounted in at runtime by the compose
# template. It may be empty, absent, or contain comments — handle gracefully.
if [[ -r "$ADDITIONS" ]]; then
    gawk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            d = $0
            gsub(/[[:space:]]/, "", d)
            if (d != "") print tolower(d)
        }
    ' "$ADDITIONS" > "$ADDITIONS_OUT" || true
fi

urlhaus_n=$(wc -l < "$URLHAUS_OUT" | tr -d ' ')
hagezi_n=$(wc -l < "$HAGEZI_OUT" | tr -d ' ')
additions_n=$(wc -l < "$ADDITIONS_OUT" | tr -d ' ')

# ---- merge / dedupe / sort ----------------------------------------------------
MERGED="${WORK}/merged.domains"
# Lower-case and sorted in BYTE order: squid's blocklist helper finds a domain by
# binary search on this file (NET-16), which is only correct in that order.
cat "$URLHAUS_OUT" "$HAGEZI_OUT" "$ADDITIONS_OUT" \
    | sed -e 's/[[:space:]]//g' \
    | grep -v '^$' \
    | grep -v '^#' \
    | tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sort -u > "$MERGED" || true

total=$(wc -l < "$MERGED" | tr -d ' ')

# ---- empty-result guard (NET-11) ----------------------------------------------
# If the merged result is empty, DO NOT touch the target. Previous file keeps
# serving until the next refresh.
if [[ "$total" -eq 0 ]]; then
    log "merged result is empty — refusing to overwrite ${TARGET} (NET-11)"
    exit 1
fi

# ---- sortedness guard (NET-16) ------------------------------------------------
# Squid's helper finds a domain by binary search, which is only correct on a
# byte-sorted file: an unsorted list would fail OPEN, silently. The sort above
# should make this impossible; a guard is cheap and refuses to publish otherwise.
if ! LC_ALL=C sort -c "$MERGED" 2>/dev/null; then
    log "merged list is not in byte order — refusing to publish it (squid's lookup would miss entries)"
    exit 1
fi

# ---- atomic write -------------------------------------------------------------
mkdir -p "$SQUID_DIR"
cp "$MERGED" "$TARGET_NEW"
mv -f "$TARGET_NEW" "$TARGET"

end_ts=$(date +%s)
took=$(( end_ts - start_ts ))

echo "refreshed: ${total} entries from urlhaus=${urlhaus_n} hagezi=${hagezi_n} additions=${additions_n} (took ${took}s)"

# No signal to squid: its blocklist helper sees the new file on its next lookup
# (NET-16). Reloading squid for it was a restart that refused connections for ~20 s.

exit 0
