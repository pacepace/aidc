#!/usr/bin/env bash
# Unit tests for what `aidc status` says about a session's malware feeds (issue #60), on both
# backends: scripts/lib/feeds.sh reads the refresher's state file (proxy/refresher/refresh.sh);
# cmd-status.sh (Docker) and scripts/k8s/session-status.sh (Kubernetes) ask the refresher
# sidecar for it. A lost feed (0 entries), a failed refresh and a stale list are said; a
# refresher that cannot be asked is unknown, never fine.
#
# docker and kubectl are PATH stubs. Hygiene: scratch under tests/scratch/ (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$AIDC_ROOT/tests/scratch/feeds-status-$$"
PASS=0
FAIL=0
trap 'rm -rf "$S"' EXIT INT TERM
mkdir -p "$S/bin" "$S/home/.config/aidc"
# shellcheck source=lib/stub-tools.sh
. "$SCRIPT_DIR/lib/stub-tools.sh"
stub_tools "$S/bin"

assert_eq() { if [ "$2" = "$3" ]; then echo "  PASS: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1 (want '$2', got '$3')"; FAIL=$((FAIL + 1)); fi; }
assert_has() { case "$3" in *"$2"*) echo "  PASS: $1"; PASS=$((PASS + 1)) ;; *) echo "  FAIL: $1 (no '$2' in: $3)"; FAIL=$((FAIL + 1)) ;; esac; }
assert_not_has() { case "$3" in *"$2"*) echo "  FAIL: $1 ('$2' in: $3)"; FAIL=$((FAIL + 1)) ;; *) echo "  PASS: $1"; PASS=$((PASS + 1)) ;; esac; }

# shellcheck source=../../scripts/lib/feeds.sh
. "$AIDC_ROOT/scripts/lib/feeds.sh"
NOW=1800000000
state() { # <result> <published-ago-seconds|""> <urlhaus> <hagezi> [interval]
    local pub=""
    [ -n "$2" ] && pub=$((NOW - $2))
    printf 'result=%s\nattempted_at=%s\npublished_at=%s\ninterval=%s\nfeed_urlhaus=%s\nfeed_hagezi=%s\n' \
        "$1" "$((NOW - 60))" "$pub" "${5:-21600}" "$3" "$4"
}

echo "=== reading the state ==="
out=$(aidc_feeds_describe "$(state ok 7200 2156 1103819)" "$NOW"); rc=$?
assert_eq "every feed with entries and a fresh list: fine" 0 "$rc"
assert_eq "one line with each feed's count and the list's age" "urlhaus 2156, hagezi 1103819 entries; list published 2h ago (refreshed every 6h)" "$out"
out=$(aidc_feeds_describe "$(state ok 600 0 1103819)" "$NOW"); rc=$?
assert_eq "a feed at 0 entries is a problem" 1 "$rc"
assert_has "named as lost" "LOST: urlhaus gave 0 entries at the last refresh" "$out"
assert_not_has "the feed that has entries is not named lost" "LOST: urlhaus, hagezi" "$out"
out=$(aidc_feeds_describe "$(state failed 50000 2156 1103819)" "$NOW"); rc=$?
assert_eq "a failed refresh and a list older than two intervals: a problem" 1 "$rc"
assert_has "the failed refresh is said" "the last refresh (1m ago) failed; the previous list still serves" "$out"
assert_has "and the stale list" "STALE: no list published for more than twice the refresh interval" "$out"
out=$(aidc_feeds_describe "$(state ok 1300 5 5 600)" "$NOW"); rc=$?
assert_eq "stale is measured against the interval the refresher runs at" "1 yes" "$rc $(printf '%s' "$out" | grep -q STALE && echo yes)"
out=$(aidc_feeds_describe "$(state ok 43000 5 5)" "$NOW"); rc=$?
assert_eq "just under two intervals is not stale" "0 no" "$rc $(printf '%s' "$out" | grep -q STALE && echo yes || echo no)"
out=$(aidc_feeds_describe "" "$NOW"); rc=$?
assert_eq "no state yet: unknown, never fine" 2 "$rc"
assert_has "and says why" "unknown: no refresh recorded yet" "$out"

# The stubs serve the state file from $FEEDS_STATE (empty: none yet); REFRESHER_DOWN=1 makes the
# refresher sidecar not answer.
cat > "$S/bin/docker" <<'STUB'
#!/bin/sh
case "$*" in
    "info"*) exit 0 ;;
    *"aidc-s-refresher sh -c cat /etc/squid/aidc-feeds.state"*)
        [ "${REFRESHER_DOWN:-}" = 1 ] && { echo "Error response from daemon: container is not running" >&2; exit 1; }
        printf '%s' "$FEEDS_STATE" ;;
    *"test -f /var/state/tainted"*) exit 1 ;;
    "ps"*) echo "abc" ;;
    "inspect --format {{.State.Status}}"*) echo running ;;
    "inspect"*) echo "" ;;
esac
exit 0
STUB
cat > "$S/bin/kubectl" <<'STUB'
#!/bin/sh
# pick: print the rows ("<app> <kind/name>" on stdin) whose app the -l selector's
# `app in (...)` clause admits (every row when it has none), as the API does.
pick() {
    apps=$(printf '%s\n' "$ARGS" | sed -n 's/.*,app in (\([^)]*\)).*/\1/p' | tr ',' ' ')
    while read -r a n; do
        [ -n "$n" ] || continue
        if [ -z "$apps" ]; then echo "$n"; else case " $apps " in *" $a "*) echo "$n" ;; esac; fi
    done
}
ARGS="$*"
case "$*" in
    *"get deployment,statefulset -l aidc/session=s"*) echo "proxy deployment.apps/s-proxy" | pick ;;
    *"get statefulset s-dev -o json"*) echo '{"metadata":{"annotations":{}}}' ;;
    *"get pod -l aidc/session=s,app=proxy"*) echo "pod/s-proxy-abc" ;;
    *"exec pod/s-proxy-abc -c refresher"*"aidc-feeds.state"*)
        [ "${REFRESHER_DOWN:-}" = 1 ] && { echo 'error: unable to upgrade connection' >&2; exit 1; }
        printf '%s' "$FEEDS_STATE" ;;
    *"exec pod/s-proxy-abc -c policy"*) echo no ;;
    *"get networkpolicy -o name"*) printf 'networkpolicy.networking.k8s.io/default-deny\n' ;;
esac
exit 0
STUB
chmod +x "$S/bin/docker" "$S/bin/kubectl"
export PATH="$S/bin:$PATH" HOME="$S/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts"
stub_tools_check

echo "=== aidc status, Docker ==="
dstatus() { "$AIDC_ROOT/scripts/aidc" status s --backend docker 2>&1 </dev/null | sed -n '/-- malware feeds --/,/^$/p'; }
out=$(FEEDS_STATE="$(state ok 600 0 1103819)" dstatus)
assert_has "a lost feed shows in aidc status" "LOST: urlhaus gave 0 entries" "$out"
out=$(FEEDS_STATE="$(state ok "$(( $(date +%s) - NOW + 600 ))" 2156 1103819)" dstatus)
assert_has "healthy feeds show their counts" "urlhaus 2156, hagezi 1103819 entries" "$out"
assert_not_has "and nothing alarming" "LOST" "$out"
out=$(FEEDS_STATE="" dstatus)
assert_has "no state yet: unknown" "unknown: no refresh recorded yet" "$out"
out=$(REFRESHER_DOWN=1 FEEDS_STATE="" dstatus)
assert_has "a refresher that does not answer: unknown, never fine" "unknown: the refresher sidecar did not answer" "$out"

echo "=== aidc status, Kubernetes ==="
cat > "$HOME/.config/aidc/config.yaml" <<'EOF2'
kubernetes:
  user: alice
  storage_class: shared-disk
EOF2
kstatus() { "$AIDC_ROOT/scripts/aidc" status s --backend kubernetes 2>&1 </dev/null; }
out=$(FEEDS_STATE="$(state ok 600 0 1103819)" kstatus)
assert_has "a lost feed shows in aidc status" "feeds:    urlhaus 0, hagezi 1103819 entries" "$out"
assert_has "with the LOST line under it" "          LOST: urlhaus gave 0 entries" "$out"
out=$(REFRESHER_DOWN=1 kstatus)
assert_has "a refresher that does not answer: unknown, never fine" "feeds:    unknown: the refresher sidecar did not answer" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
