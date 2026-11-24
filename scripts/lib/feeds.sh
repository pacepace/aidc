# shellcheck shell=bash
# The malware feeds a session's blocklist is built from, as `aidc status` reports them on both
# backends (issue #60). The refresher writes its state file (/etc/squid/aidc-feeds.state,
# proxy/refresher/refresh.sh) after every refresh; each backend reads it from the refresher
# sidecar its own way and hands the text here. A lost feed or a refresh that stopped would
# otherwise show only as a WARN line in the refresher's log, and the blocklist would quietly be
# missing that feed's entries.
#
# Reads text only: no docker, no kubectl, no helper from another library.

# aidc_feeds_describe <state-text> <now-epoch>: lines for status, and a return code:
# 0 every feed has entries and the list is fresh; 1 a feed is lost or the list is stale;
# 2 nothing is known yet (no state: the first refresh has not finished, or the refresher
# predates this file).
aidc_feeds_describe() {
    local state="$1" now="$2"
    if ! printf '%s\n' "$state" | grep -q '^feed_[a-z0-9]*='; then
        printf 'unknown: no refresh recorded yet (the first one may still be running)\n'
        return 2
    fi
    printf '%s\n' "$state" | awk -F= -v now="$now" '
        function ago(s) { if (s < 0) s = 0; if (s >= 86400) return int(s / 86400) "d"; if (s >= 3600) return int(s / 3600) "h"; if (s >= 60) return int(s / 60) "m"; return s "s" }
        /^feed_[a-z0-9]+=/ { name = substr($1, 6); n = $2 + 0; feeds = feeds (feeds == "" ? "" : ", ") name " " n; if (n == 0) lost = lost (lost == "" ? "" : ", ") name; next }
        $1 == "published_at" { pub = $2 } $1 == "attempted_at" { att = $2 } $1 == "interval" { iv = $2 + 0 } $1 == "result" { res = $2 }
        END {
            if (iv <= 0) iv = 21600
            line = feeds " entries"
            if (pub != "") line = line "; list published " ago(now - pub) " ago"
            else line = line "; no list published yet"
            print line " (refreshed every " ago(iv) ")"
            bad = 0
            if (lost != "") { print "LOST: " lost " gave 0 entries at the last refresh (failed or gone): the blocklist is missing it"; bad = 1 }
            if (res == "failed") { print "the last refresh (" ago(now - att) " ago) failed; the previous list still serves"; bad = 1 }
            if (pub == "" || now - pub > 2 * iv) { print "STALE: no list published for more than twice the refresh interval"; bad = 1 }
            exit bad
        }'
}
