#!/usr/bin/env bash
# `aidc status` says a session is clean only when the policy sidecar says so
# (scripts/cmd-status.sh, taint detail).
#
# `docker exec <policy> test -f /var/state/tainted` exits 1 both for "no flag" and for a policy
# container that is gone, stopped or paused; only the second writes to stderr. A status that read
# the second as clean would report a possibly tainted session as clean.
#
# `docker` is a PATH stub. Hygiene: scratch lives under tests/scratch/ INSIDE the repo.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/status-taint-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home"

# docker stub: the session exists and is running; the taint probe answers per $TAINT_MODE:
#   flag    test -f succeeds, cat prints the flag
#   none    test -f exits 1, silently
#   gone    exits 1 with docker's "No such container" on stderr
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
case "$*" in
    "info"*) exit 0 ;;
    *"test -f /var/state/tainted"*)
        case "$TAINT_MODE" in
            flag) exit 0 ;;
            none) exit 1 ;;
            gone) echo "Error response from daemon: No such container: aidc-s-policy" >&2; exit 1 ;;
        esac ;;
    *"cat /var/state/tainted"*) echo '{"trigger":"malware_domains"}' ;;
    "ps"*) echo "abc" ;;
    "inspect --format {{.State.Status}}"*) echo running ;;
    "inspect"*) echo "" ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/docker"
export PATH="$SCRATCH/bin:$PATH" HOME="$SCRATCH/home"

check() {
    local desc="$1" mode="$2" want="$3" out
    out=$(TAINT_MODE="$mode" "$AIDC_ROOT/scripts/aidc" status s 2>&1 </dev/null | sed -n '/-- taint status --/,/^$/p')
    case "$out" in
        *"$want"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (want '$want' in: $out)"; FAIL=$((FAIL + 1)) ;;
    esac
}

echo "=== aidc status: taint ==="
check "a flag is reported tainted" flag "TAINTED."
check "no flag, policy answering: clean" none "clean."
check "the policy container not answering is unknown, never clean" gone "unknown: the policy sidecar did not answer (Error response from daemon: No such container"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
