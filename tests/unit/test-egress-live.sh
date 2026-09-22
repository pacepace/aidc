#!/usr/bin/env bash
# Unit tests for `aidc egress` replacing a live relay (scripts/cmd-egress.sh, NET-15).
#
# Adding or removing a port re-makes the host's live relay, and the old one has to go
# first (one relay per host name). What must hold when that goes wrong:
#   - anything checkable beforehand (the audit dir) is checked BEFORE the old relay is
#     removed, so a failure there changes nothing;
#   - if the new relay still fails to start, the error names the ports that were
#     relayed and are now lost, and passes docker's own error through.
# A real daemon cannot be made to fail on cue, so docker is a fake on PATH that answers
# the few calls cmd-egress makes and logs each one.
#
# Hygiene: scratch under tests/scratch, removed on exit. No Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/egress-live-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home"

eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}
has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (no '$needle' in: $hay)"; FAIL=$((FAIL + 1)) ;;
    esac
}
hasnt() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  FAIL: $desc ('$needle' in: $hay)"; FAIL=$((FAIL + 1)) ;;
        *) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
    esac
}

# The fake: session s1 exists, its host 10.1.2.3 has a live relay on $FAKE_PORTS, the audit
# dir is $FAKE_AUDIT (empty = cannot be found), and `network connect` fails.
cat > "$SCRATCH/bin/docker" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
    info) exit 0 ;;
    ps)
        case "$*" in
            *label=aidc.egress*) printf 'aidc-s1-egressx-10-1-2-3|adhoc|10.1.2.3|10.1.2.3|%s|running\n' "$FAKE_PORTS" ;;
            *) printf 'abc123\n' ;;
        esac ;;
    inspect)
        case "$*" in
            *aidc-s1-audit*) printf '%s' "$FAKE_AUDIT" ;;
            *aidc-mcp*) exit 1 ;;
            *) exit 0 ;;
        esac ;;
    image) exit 0 ;;
    run) printf 'newid\n' ;;
    rm) exit 0 ;;
    network)
        printf 'Error response from daemon: fake join failure\n' >&2
        exit 1 ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "$SCRATCH/bin/docker"

egress() {
    # $1 = audit dir the fake reports; the rest = aidc egress args. Prints "rc|output".
    local audit="$1" out rc=0
    shift
    : > "$SCRATCH/log"
    out=$(env -i PATH="$SCRATCH/bin:/usr/bin:/bin" HOME="$SCRATCH/home" \
        AIDC_ROOT="$AIDC_ROOT" AIDC_SCRIPTS="$AIDC_ROOT/scripts" AIDC_VERSION_TAG=v0.0.0 \
        FAKE_LOG="$SCRATCH/log" FAKE_AUDIT="$audit" FAKE_PORTS="${FAKE_PORTS:-5432}" \
        bash "$AIDC_ROOT/scripts/cmd-egress.sh" "$@" 2>&1) || rc=$?
    printf '%s|%s' "$rc" "$out"
}

echo "=== aidc egress: replacing a live relay ==="

got=$(egress "" s1 add 10.1.2.3:6379)
eq "no audit dir: the add fails" "1" "${got%%|*}"
has "and says nothing changed" "nothing changed" "$got"
hasnt "and the old relay was not removed" "rm -f aidc-s1-egressx-10-1-2-3" "$(cat "$SCRATCH/log")"

got=$(egress /audit s1 add 10.1.2.3:6379)
eq "a failed start: the add fails" "1" "${got%%|*}"
has "docker's own error is shown" "fake join failure" "$got"
has "the port that was relayed and is now lost is named" "port(s) 5432 are no longer relayed" "$got"
# The old relay's removal logs the same line, so look only after the failed join.
eq "the half-made relay is removed after the failed join" "1" \
    "$(awk '/^network connect/ { after = 1; next } after && /^rm -f aidc-s1-egressx-10-1-2-3/ { n++ } END { print n + 0 }' "$SCRATCH/log")"

# Removing 5432 from a relay that also carries 6379: only 6379 was meant to stay.
got=$(FAKE_PORTS="5432 6379" egress /audit s1 rm 10.1.2.3:5432)
eq "a failed rm restart fails" "1" "${got%%|*}"
has "and names only the port meant to stay" "port(s) 6379 are no longer relayed" "$got"

echo
echo "egress live: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
