#!/usr/bin/env bash
# policy.sh: real-time taint detector for the aidc proxy stack.
#
# Tails Squid's access.log, classifies TCP_DENIED hits as malware vs TLD by
# membership-checking the domain against the two blocklist files (Squid does
# NOT log which ACL fired), then applies the configured taint response.
#
# Forward-only: on startup, tail begins at the END of the log; existing
# entries are NOT re-evaluated. One session = one possible taint.
#
# Membership tests run directly against the on-disk files (`grep -Fxq`)
# rather than against an in-memory bash array. The URLhaus + ThreatFox
# + HaGeZi-TIF blocklist is ~1.3M lines — loading that into a bash
# associative array takes ~20s, which caused a race with the smoke test
# (a one-line append by the refresher would block reloads for that long).
# A single `grep -Fxq` against a 1.3M line file completes in <100ms, and
# the file IS the source of truth, so refresher updates take effect
# instantly with no reload machinery at all.
set -uo pipefail

# ---- Configuration ---------------------------------------------------------
AIDC_SESSION="${AIDC_SESSION:-unknown}"
AIDC_TAINT_RESPONSE="${AIDC_TAINT_RESPONSE:-notify}"   # log | notify | freeze
AIDC_TLD_TAINTS="${AIDC_TLD_TAINTS:-false}"            # true | false
AIDC_NOTIFY_WEBHOOK="${AIDC_NOTIFY_WEBHOOK:-}"

ACCESS_LOG="/var/log/squid/access.log"
BLOCKLIST_FILE="/etc/squid/blocklist.txt"
TLDS_FILE="/etc/squid/state-actor-tlds.txt"
STATE_DIR="/var/state"
TAINT_FLAG="${STATE_DIR}/tainted"
EVENTS_LOG="/var/log/aidc/policy-events.log"

mkdir -p "$STATE_DIR" "$(dirname "$EVENTS_LOG")"

log() {
    printf '[%s] [policy] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

# JSON-escape a string for embedding inside a "..." value: backslash, double
# quote, tab, CR. (Newlines can't occur -- these are single-line log fields.)
# Single home for what used to be copy-pasted in do_taint and append_event.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
                           -e 's/\t/\\t/g' -e 's/\r/\\r/g'
}

log "starting: session=${AIDC_SESSION} response=${AIDC_TAINT_RESPONSE} tld_taints=${AIDC_TLD_TAINTS}"

# Cheap startup sanity: report sizes once so logs show what we're matching against.
if [ -r "$BLOCKLIST_FILE" ]; then
    log "blocklist: $(wc -l < "$BLOCKLIST_FILE" | tr -d ' ') entries in ${BLOCKLIST_FILE}"
else
    log "blocklist: ${BLOCKLIST_FILE} not readable"
fi
if [ -r "$TLDS_FILE" ]; then
    log "tlds: $(wc -l < "$TLDS_FILE" | tr -d ' ') entries in ${TLDS_FILE}"
else
    log "tlds: ${TLDS_FILE} not readable"
fi

# ---- Domain extraction -----------------------------------------------------
# From a Squid URL field:
#   - http://host[:port]/path  -> host
#   - host:port (CONNECT)      -> host
#   - https://host[:port]/...  -> host
extract_domain() {
    local url="$1"
    url="${url#http://}"
    url="${url#https://}"
    url="${url%%/*}"      # strip path
    url="${url##*@}"      # strip userinfo
    url="${url%%:*}"      # strip :port
    # Lowercase for case-insensitive match.
    printf '%s' "$url" | tr '[:upper:]' '[:lower:]'
}

# ---- Classification --------------------------------------------------------
# Returns 0 with $CLASS=malware|tld|unknown set as a side effect.
#
# Squid's `dstdomain evil.com` ACL matches "evil.com" AND "x.evil.com" AND
# any deeper subdomain. We replicate that by iterating the candidate domain
# through every parent suffix and asking grep if any of them is in the file.
# One `grep -Fxq -e a -e b -e c` is a single scan of the file — much faster
# than four individual greps.
classify_domain() {
    local domain="$1"
    CLASS="unknown"
    [ -z "$domain" ] && return 0

    # 1. Malware blocklist: exact match OR any parent suffix match.
    #    Build candidate list, then one grep against the file.
    local probe="$domain"
    local -a candidates=()
    while [ -n "$probe" ]; do
        # Normalize: file entries may have a leading dot; classify both forms.
        candidates+=("-e" "$probe" "-e" ".${probe}")
        case "$probe" in
            *.*) probe="${probe#*.}" ;;
            *)   probe="" ;;
        esac
    done
    if [ -r "$BLOCKLIST_FILE" ] && grep -Fxq "${candidates[@]}" "$BLOCKLIST_FILE"; then
        CLASS="malware"
        return 0
    fi

    # 2. TLD suffix list. Tiny file (~10 entries), reread per-classification
    #    so refresher / human edits take effect with no reload machinery.
    if [ -r "$TLDS_FILE" ]; then
        local tld bare
        while IFS= read -r tld || [ -n "$tld" ]; do
            [ -z "$tld" ] && continue
            case "$tld" in \#*) continue ;; esac
            # Normalize entries to start with a dot for uniform suffix-match.
            case "$tld" in
                .*) ;;
                *)  tld=".${tld}" ;;
            esac
            bare="${tld#.}"
            if [ "$domain" = "$bare" ] || [ "${domain%"${tld}"}" != "$domain" ]; then
                CLASS="tld"
                return 0
            fi
        done < "$TLDS_FILE"
    fi

    return 0
}

# ---- Taint action ----------------------------------------------------------
do_taint() {
    local trigger="$1" domain="$2" line="$3"

    # Idempotent guard: if the flag file exists, log and bail.
    if [ -e "$TAINT_FLAG" ]; then
        log "already tainted; skipping re-notify (domain=${domain})"
        # Still record the event.
        append_event "$trigger" "$domain" "$line" "suppressed"
        return 0
    fi

    local now
    now=$(date -u +%FT%TZ)

    # JSON-escape the squid log line + domain (backslash, quote, control chars).
    local esc_line esc_domain
    esc_line=$(json_escape "$line")
    esc_domain=$(json_escape "$domain")

    local payload
    payload=$(printf '{"tainted_at":"%s","trigger":"%s","domain":"%s","squid_log_line":"%s"}' \
        "$now" "$trigger" "$esc_domain" "$esc_line")

    # Atomic write: temp + rename.
    printf '%s\n' "$payload" > "${TAINT_FLAG}.new"
    mv -f "${TAINT_FLAG}.new" "$TAINT_FLAG"
    log "TAINTED: trigger=${trigger} domain=${domain}"

    # Always notify on first taint (notify.sh handles webhook + FIFO).
    printf '%s' "$payload" | /usr/local/bin/notify.sh || \
        log "notify.sh exited non-zero"

    # Response dispatch.
    case "$AIDC_TAINT_RESPONSE" in
        log)
            log "response=log: flag written only"
            ;;
        notify)
            log "response=notify: handled by notify.sh"
            ;;
        freeze)
            if [ -S /var/run/docker.sock ]; then
                local target="aidc-${AIDC_SESSION}-dev"
                log "response=freeze: pausing ${target}"
                if docker pause "$target" >/dev/null 2>&1; then
                    log "freeze: paused ${target}"
                else
                    log "freeze: docker pause failed for ${target}"
                fi
            else
                log "response=freeze requested but /var/run/docker.sock not mounted; skipping"
            fi
            ;;
        *)
            log "unknown response mode '${AIDC_TAINT_RESPONSE}'; treating as notify"
            ;;
    esac

    append_event "$trigger" "$domain" "$line" "tainted"
}

append_event() {
    local trigger="$1" domain="$2" line="$3" outcome="$4"
    local now
    now=$(date -u +%FT%TZ)
    local esc_line esc_domain
    esc_line=$(json_escape "$line")
    esc_domain=$(json_escape "$domain")
    printf '{"at":"%s","trigger":"%s","domain":"%s","outcome":"%s","squid_log_line":"%s"}\n' \
        "$now" "$trigger" "$esc_domain" "$outcome" "$esc_line" >> "$EVENTS_LOG"
}

# ---- Wait for the access log to exist --------------------------------------
while [ ! -f "$ACCESS_LOG" ]; do
    log "waiting for ${ACCESS_LOG} to appear..."
    sleep 1
done
log "tailing ${ACCESS_LOG}"

# ---- Main tail loop --------------------------------------------------------
# tail -F (capital F) survives log rotation by reopening on truncate/rename.
# -n 0: forward-only; do not evaluate pre-existing lines.
while IFS= read -r line; do
    # Squid native format columns (space-separated):
    #   ts elapsed client result/code bytes method url user hier_from content_type
    # We only care about TCP_DENIED.
    case "$line" in
        *TCP_DENIED*) ;;
        *) continue ;;
    esac

    # Field 7 = url (1-indexed). Use awk for whitespace-collapsing tokenization.
    url=$(printf '%s' "$line" | awk '{print $7}')
    [ -z "$url" ] && continue

    domain=$(extract_domain "$url")
    [ -z "$domain" ] && continue

    classify_domain "$domain"

    case "$CLASS" in
        malware)
            do_taint "malware_domains" "$domain" "$line"
            ;;
        tld)
            if [ "$AIDC_TLD_TAINTS" = "true" ]; then
                do_taint "state_actor_tld" "$domain" "$line"
            else
                log "TLD-only hit (no taint): domain=${domain}"
                append_event "state_actor_tld" "$domain" "$line" "logged"
            fi
            ;;
        *)
            log "unclassified DENY: domain=${domain}"
            append_event "unknown" "$domain" "$line" "logged"
            ;;
    esac
done < <(tail -F -n 0 "$ACCESS_LOG" 2>/dev/null)
