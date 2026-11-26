#!/usr/bin/env bash
# The policy sidecar's taint webhook (W-M4): on a session's first taint it pokes the user's MCP
# server, naming only the session; with no webhook configured (Docker) it pokes nothing; a
# server that does not answer is logged, never a failure of the taint.
#
# Runs the shipped proxy/policy/policy.sh against scratch files, with curl a PATH stub. No
# Docker, no network.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored); the policy process
# is stopped by its pid.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/policy-webhook-$$"
PASS=0
FAIL=0
POLICY_PID=""
cleanup() { [ -z "$POLICY_PID" ] || { pkill -P "$POLICY_PID" 2>/dev/null; kill "$POLICY_PID" 2>/dev/null; }; rm -rf "$SCRATCH"; }
trap cleanup EXIT INT TERM
mkdir -p "$SCRATCH/bin"

check() {
    if [ "$2" = "yes" ]; then echo "  PASS: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1"; FAIL=$((FAIL + 1)); fi
}

# curl: records its argv, one call per line; fails when CURL_FAIL is set.
cat > "$SCRATCH/bin/curl" <<'CURLSTUB_POLICY_x41'
#!/bin/sh
printf '%s\n' "$*" >> "$CURL_LOG"
[ -z "${CURL_FAIL:-}" ] || exit 7
exit 0
CURLSTUB_POLICY_x41
printf '#!/bin/sh\ncat >/dev/null\n' > "$SCRATCH/bin/notify"
chmod +x "$SCRATCH/bin/curl" "$SCRATCH/bin/notify"

# run_policy <dir> <webhook>: the sidecar against <dir>'s files, until it writes the flag after a
# blocklisted request is denied (or 10 s). Leaves its log in <dir>/policy.log.
run_policy() {
    local d="$1" hook="$2"
    mkdir -p "$d/state" "$d/log"
    printf 'evil.example\n' > "$d/blocklist.txt"
    : > "$d/tlds.txt"
    : > "$d/access.log"
    : > "$d/curl.log"
    PATH="$SCRATCH/bin:$PATH" CURL_LOG="$d/curl.log" AIDC_SESSION=demo AIDC_TAINT_RESPONSE=notify \
        AIDC_TAINT_WEBHOOK="$hook" AIDC_POLICY_ACCESS_LOG="$d/access.log" \
        AIDC_POLICY_BLOCKLIST="$d/blocklist.txt" AIDC_POLICY_TLDS="$d/tlds.txt" \
        AIDC_POLICY_STATE_DIR="$d/state" AIDC_POLICY_EVENTS_LOG="$d/log/events.log" \
        AIDC_POLICY_NOTIFY="$SCRATCH/bin/notify" \
        bash "$AIDC_ROOT/proxy/policy/policy.sh" > "$d/policy.log" 2>&1 &
    POLICY_PID=$!
    sleep 1
    printf '1700000000.000 5 10.0.0.2 TCP_DENIED/403 0 CONNECT evil.example:443 - HIER_NONE/- -\n' >> "$d/access.log"
    for _ in $(seq 50); do [ -e "$d/state/tainted" ] && break; sleep 0.2; done
    sleep 0.5
    pkill -P "$POLICY_PID" 2>/dev/null; kill "$POLICY_PID" 2>/dev/null; wait "$POLICY_PID" 2>/dev/null; POLICY_PID=""
}

echo "=== a taint pokes the user's MCP server ==="
D="$SCRATCH/k8s"
run_policy "$D" "http://10.43.7.7:7879/taint"
check "the session is tainted" "$([ -e "$D/state/tainted" ] && echo yes || echo no)"
check "the webhook is POSTed once, at its address" \
    "$([ "$(grep -c 'http://10.43.7.7:7879/taint' "$D/curl.log")" = 1 ] && echo yes || echo no)"
check "the poke names the session and nothing else (the server reads the flag itself)" \
    "$(grep -q -- '-d {"session":"demo"} http://10.43.7.7:7879/taint' "$D/curl.log" && echo yes || echo no)"
check "it does not wait long for the server" "$(grep -q -- '--max-time 5' "$D/curl.log" && echo yes || echo no)"
check "the log says the server was told" "$(grep -q 'taint webhook: told the MCP server' "$D/policy.log" && echo yes || echo no)"

echo "=== a server that does not answer ==="
D="$SCRATCH/down"
CURL_FAIL=1 run_policy "$D" "http://10.43.7.7:7879/taint"
check "the taint stands" "$([ -e "$D/state/tainted" ] && echo yes || echo no)"
check "the miss is logged, saying the server finds the flag on its own" \
    "$(grep -q 'the MCP server did not answer (it finds the flag on its own)' "$D/policy.log" && echo yes || echo no)"

echo "=== no webhook (Docker) ==="
D="$SCRATCH/docker"
run_policy "$D" ""
check "the session is tainted" "$([ -e "$D/state/tainted" ] && echo yes || echo no)"
check "nothing is posted to an MCP server" "$(grep -q '/taint' "$D/curl.log" && echo no || echo yes)"

echo
echo "policy webhook: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
