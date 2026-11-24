#!/usr/bin/env bash
# One sweep of the audit sidecar (proxy/audit/aggregate.sh --once) on scratch folders laid out
# as a session mounts them: what reaches the audit trail.
#
# SEC-07 / NET-08: the audit must hold squid's log, the shell history and the Claude
# transcripts, and record when the session was tainted. Two of these never reached it: the
# sidecar read the taint flag from a folder nothing mounts and the transcripts from a path
# nothing mounts, so a sweep copied neither, on both backends.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/audit-aggregate-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

assert() {
    local desc="$1"; shift
    if eval "$*" >/dev/null 2>&1; then echo "  PASS: $desc"; PASS=$((PASS + 1))
    else echo "  FAIL: $desc"; FAIL=$((FAIL + 1)); fi
}

mkdir -p "$SCRATCH"/{audit,squid,log,state,home/.claude/projects/-home-u-repo}
echo '{"session":"s","created_at":"2026-11-24T00:00:00Z"}' > "$SCRATCH/audit/meta.json"
echo "1795494688.439 0 10.0.0.1 TCP_DENIED/403 GET http://example.org/" > "$SCRATCH/squid/access.log"
echo '{"outcome":"tainted"}' > "$SCRATCH/log/policy-events.log"
printf 'ls\ncurl example.org\n' > "$SCRATCH/home/.bash_history"
echo '{"type":"user"}' > "$SCRATCH/home/.claude/projects/-home-u-repo/conv.jsonl"
echo '{"tainted_at":"2026-11-24T04:31:28Z","trigger":"malware_domains","domain":"example.org"}' \
    > "$SCRATCH/state/tainted"

AIDC_AUDIT_OUT_DIR="$SCRATCH/audit" AIDC_AUDIT_SQUID_DIR="$SCRATCH/squid" \
AIDC_AUDIT_LOG_DIR="$SCRATCH/log" AIDC_AUDIT_HOME_DIR="$SCRATCH/home" \
AIDC_AUDIT_STATE_DIR="$SCRATCH/state" AIDC_SESSION=s \
    bash "$AIDC_ROOT/proxy/audit/aggregate.sh" --once >/dev/null 2>&1

A="$SCRATCH/audit"
echo "=== one audit sweep ==="
assert "squid's access log is copied" "grep -q TCP_DENIED '$A/squid-access.log'"
assert "the policy events are copied" "grep -q tainted '$A/policy-events.log'"
assert "the shell history is copied" "grep -q 'curl example.org' '$A/dev-bash-history'"
assert "the Claude transcripts are copied from the session home" \
    "test -s '$A/claude-transcript/-home-u-repo/conv.jsonl'"
assert "the taint flag is copied" "test -s '$A/tainted'"
assert "meta.json records when the session was tainted, from the flag's own field" \
    "[ \"\$(jq -r .tainted_at '$A/meta.json')\" = 2026-11-24T04:31:28Z ]"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
