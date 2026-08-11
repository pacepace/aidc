#!/usr/bin/env bash
# aidc refresher — one-shot refresh of Squid's malware blocklist.
#
# Fetches URLhaus, ThreatFox, and HaGeZi-TIF feeds, normalizes each to one
# domain per line, merges with per-project additions, dedupes/sorts, and
# atomically writes /etc/squid/blocklist.txt.
#
# Failure semantics (NET-11):
#   - Per-feed failures are logged and tolerated; the others still feed in.
#   - If the merged result is empty (every feed failed and no additions),
#     EXIT 1 WITHOUT TOUCHING the existing blocklist.
#
# Feed URLs are baked in (NET-12) — do not parameterize.

set -euo pipefail

# ---- hard-coded feeds (NET-12) ------------------------------------------------
URLHAUS_URL="https://urlhaus.abuse.ch/downloads/hostfile/"
THREATFOX_URL="https://threatfox.abuse.ch/export/csv/recent/"
HAGEZI_TIF_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.txt"

# ---- paths --------------------------------------------------------------------
SQUID_DIR="/etc/squid"
TARGET="${SQUID_DIR}/blocklist.txt"
TARGET_NEW="${SQUID_DIR}/blocklist.txt.new"
ADDITIONS="${SQUID_DIR}/blocklist-additions.conf"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

URLHAUS_RAW="${WORK}/urlhaus.raw"
THREATFOX_RAW="${WORK}/threatfox.raw"
HAGEZI_RAW="${WORK}/hagezi.raw"

URLHAUS_OUT="${WORK}/urlhaus.domains"
THREATFOX_OUT="${WORK}/threatfox.domains"
HAGEZI_OUT="${WORK}/hagezi.domains"
ADDITIONS_OUT="${WORK}/additions.domains"

: > "$URLHAUS_OUT"
: > "$THREATFOX_OUT"
: > "$HAGEZI_OUT"
: > "$ADDITIONS_OUT"

start_ts=$(date +%s)

log()  { echo "aidc-refresher: $*" >&2; }

fetch() {
    # fetch <url> <out>  -> 0 on success, non-zero on failure
    local url="$1" out="$2"
    if curl -fsSL --max-time 60 -o "$out" "$url"; then
        return 0
    else
        return 1
    fi
}

# ---- URLhaus ------------------------------------------------------------------
# Format: "0.0.0.0 some-domain.example" per line; comments start with '#'.
if fetch "$URLHAUS_URL" "$URLHAUS_RAW"; then
    gawk '$1 == "0.0.0.0" && $2 != "" && $2 !~ /^#/ { print tolower($2) }' \
        "$URLHAUS_RAW" > "$URLHAUS_OUT" || true
    log "urlhaus: $(wc -l < "$URLHAUS_OUT") entries"
else
    log "urlhaus: FETCH FAILED ($URLHAUS_URL)"
fi

# ---- ThreatFox ----------------------------------------------------------------
# Format: CSV with a multi-line '#'-prefixed header, then quoted fields:
#   "first_seen_utc","ioc_id","ioc_value","ioc_type","threat_type",...
# We only want ioc_value (col 3) when ioc_type (col 4) == "domain".
# gawk with FPAT handles quoted CSV correctly: a field is either a non-comma
# run, or a double-quoted string (which may contain commas).
if fetch "$THREATFOX_URL" "$THREATFOX_RAW"; then
    gawk '
        BEGIN {
            FPAT = "([^,]+)|(\"[^\"]*\")"
        }
        # skip comment / blank lines
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            v = $3
            t = $4
            # strip surrounding double quotes if present
            gsub(/^"|"$/, "", v)
            gsub(/^"|"$/, "", t)
            # strip leading/trailing whitespace
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
            if (t == "domain" && v != "") {
                print tolower(v)
            }
        }
    ' "$THREATFOX_RAW" > "$THREATFOX_OUT" || true
    log "threatfox: $(wc -l < "$THREATFOX_OUT") entries"
else
    log "threatfox: FETCH FAILED ($THREATFOX_URL)"
fi

# ---- HaGeZi TIF (wildcard) ----------------------------------------------------
# Format: lines like "*.evil.example"; also has '#' comments and blanks.
if fetch "$HAGEZI_TIF_URL" "$HAGEZI_RAW"; then
    gawk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^\*\./ {
            d = substr($0, 3)
            gsub(/[[:space:]]/, "", d)
            if (d != "") print tolower(d)
        }
    ' "$HAGEZI_RAW" > "$HAGEZI_OUT" || true
    log "hagezi: $(wc -l < "$HAGEZI_OUT") entries"
else
    log "hagezi: FETCH FAILED ($HAGEZI_TIF_URL)"
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
threatfox_n=$(wc -l < "$THREATFOX_OUT" | tr -d ' ')
hagezi_n=$(wc -l < "$HAGEZI_OUT" | tr -d ' ')
additions_n=$(wc -l < "$ADDITIONS_OUT" | tr -d ' ')

# ---- merge / dedupe / sort ----------------------------------------------------
MERGED="${WORK}/merged.domains"
cat "$URLHAUS_OUT" "$THREATFOX_OUT" "$HAGEZI_OUT" "$ADDITIONS_OUT" \
    | sed -e 's/[[:space:]]//g' \
    | grep -v '^$' \
    | grep -v '^#' \
    | sort -u > "$MERGED" || true

total=$(wc -l < "$MERGED" | tr -d ' ')

# ---- empty-result guard (NET-11) ----------------------------------------------
# If the merged result is empty, DO NOT touch the target. Previous file keeps
# serving until the next refresh.
if [[ "$total" -eq 0 ]]; then
    log "merged result is empty — refusing to overwrite ${TARGET} (NET-11)"
    exit 1
fi

# ---- atomic write -------------------------------------------------------------
mkdir -p "$SQUID_DIR"
cp "$MERGED" "$TARGET_NEW"
mv -f "$TARGET_NEW" "$TARGET"

end_ts=$(date +%s)
took=$(( end_ts - start_ts ))

echo "refreshed: ${total} entries from urlhaus=${urlhaus_n} threatfox=${threatfox_n} hagezi=${hagezi_n} additions=${additions_n} (took ${took}s)"

# ---- signal Squid -------------------------------------------------------------
# PID 1 in this container is the Squid master process because the compose
# template sets `pid: service:squid`. If the signal fails (Squid not yet up,
# different PID semantics, running standalone for tests), log but exit 0 —
# the refresh itself succeeded.
if kill -HUP 1 2>/dev/null; then
    log "signalled squid (kill -HUP 1)"
else
    log "could not signal pid 1 (Squid may not be up yet, or running standalone)"
fi

exit 0
