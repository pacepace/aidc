#!/usr/bin/env bash
# The dev container's inner dockerd takes the container's own MTU when it is below 1500
# (.devcontainer/dockerd-start.sh, inner_mtu_args).
#
# On a Kubernetes overlay (pod MTU 1450) an inner Docker left at 1500 stalls large transfers:
# a git clone from GitHub reset after 150 s. On a plain Docker host the container's MTU is
# 1500 and dockerd must be started exactly as before, with no --mtu.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/dockerd-mtu-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH"

# Only the function, not the script (which starts dockerd).
sed -n '/^iface_mtu() {$/,/^}$/p; /^inner_mtu_args() {$/,/^}$/p' "$AIDC_ROOT/.devcontainer/dockerd-start.sh" > "$SCRATCH/fn.sh"
# shellcheck disable=SC1091
. "$SCRATCH/fn.sh"
command -v inner_mtu_args >/dev/null || { echo "FAIL: inner_mtu_args not found"; exit 1; }

check() {
    local desc="$1" content="$2" want="$3" got
    mkdir -p "$SCRATCH/sys/eth9"
    if [ "$content" = "<missing>" ]; then rm -f "$SCRATCH/sys/eth9/mtu"; else printf '%s\n' "$content" > "$SCRATCH/sys/eth9/mtu"; fi
    got=$(AIDC_MTU_SYSFS="$SCRATCH/sys" AIDC_MTU_IFACE=eth9 inner_mtu_args)
    if [ "$got" = "$want" ]; then echo "  PASS: $desc"; PASS=$((PASS + 1))
    else echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1)); fi
}

echo "=== inner dockerd MTU ==="
check "an overlay's smaller MTU is passed on" "1450" "--mtu=1450"
check "a plain Docker host's 1500 passes nothing (dockerd started as before)" "1500" ""
check "a jumbo-frame MTU passes nothing (Docker's default is safe below it)" "9000" ""
check "an unreadable value passes nothing" "abc" ""
check "an interface that exists nowhere passes nothing" "<missing>" ""
# Under Sysbox /sys/class/net lists the node's interfaces, so the pod's eth0 is not there and
# the MTU comes from the kernel instead. The loopback interface exists everywhere.
got=$(AIDC_MTU_SYSFS="$SCRATCH/empty-sysfs" iface_mtu lo)
if [ -n "$got" ] && [ "$got" -ge 1500 ] 2>/dev/null; then
    echo "  PASS: with no sysfs entry the MTU is read from the kernel (lo: $got)"; PASS=$((PASS + 1))
else
    echo "  FAIL: with no sysfs entry the kernel read gave '$got' for lo"; FAIL=$((FAIL + 1))
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
