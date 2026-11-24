#!/usr/bin/env bash
# `aidc status` lists a Docker session's declared ports (#74; scripts/cmd-status.sh).
#
# Under enforced egress the dev container sits on an internal network and publishes nothing; its
# declared ports are published by the aidc-<s>-dfwd-<host port> forwarder sidecars, so a status
# that read only the dev container said "declared: (none)" for ports that worked. A session from
# before those sidecars (or a direct-egress one) still publishes from the dev container itself.
#
# `docker` is a PATH stub. Hygiene: scratch lives under tests/scratch/ INSIDE the repo.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/status-ports-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home"

# docker stub. DFWD=1: the session s has two dfwd sidecars (and a session s-two has one, which
# must not be listed for s). DEVPUB=1: the dev container publishes 7000 itself.
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
case "$*" in
    "info"*) exit 0 ;;
    *"--filter name=^aidc-s-dfwd-[0-9]+\$"*)
        # docker's name filter is a regular expression; the stub applies it the same way.
        [ "${DFWD:-}" = 1 ] || exit 0
        printf 'aidc-s-dfwd-5175|0.0.0.0:5175->5175/tcp, [::]:5175->5175/tcp\naidc-s-dfwd-8002|0.0.0.0:8002->80/tcp, [::]:8002->80/tcp\naidc-s-two-dfwd-9000|0.0.0.0:9000->9000/tcp\n' \
            | grep -E '^aidc-s-dfwd-[0-9]+\|' ;;
    *"NetworkSettings.Ports"*) [ "${DEVPUB:-}" = 1 ] && printf '7000:7000/tcp\n' ;;
    "ps"*) echo "abc" ;;
    "inspect --format {{.State.Status}}"*) echo running ;;
    "inspect"*) echo "" ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/docker"
export PATH="$SCRATCH/bin:$PATH" HOME="$SCRATCH/home"

ports() { "$AIDC_ROOT/scripts/aidc" status s 2>&1 </dev/null | sed -n '/-- port forwards --/,/adhoc/p'; }
check() {
    local desc="$1" want="$2" got="$3"
    case "$got" in
        *"$want"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (want '$want' in: $got)"; FAIL=$((FAIL + 1)) ;;
    esac
}
check_not() {
    local desc="$1" unwanted="$2" got="$3"
    case "$got" in
        *"$unwanted"*) echo "  FAIL: $desc ('$unwanted' in: $got)"; FAIL=$((FAIL + 1)) ;;
        *) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
    esac
}

echo "=== aidc status: declared ports (#74) ==="
out=$(DFWD=1 ports)
check "a port published by a dfwd sidecar is listed" "localhost:5175 -> aidc-s-dev:5175" "$out"
check "with the container port it forwards to" "localhost:8002 -> aidc-s-dev:80" "$out"
check_not "a session whose name starts the same is not listed" "9000" "$out"
check_not "and not '(none)'" "declared: (none)" "$out"
out=$(DEVPUB=1 ports)
check "a dev container that publishes a port itself is still listed" "localhost:7000 -> aidc-s-dev:7000" "$out"
out=$(ports)
check "no ports at all: (none)" "declared: (none)" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
