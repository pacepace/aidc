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
sed -n '/^inner_mtu_args() {$/,/^}$/p' "$AIDC_ROOT/.devcontainer/dockerd-start.sh" > "$SCRATCH/fn.sh"
# shellcheck disable=SC1091
. "$SCRATCH/fn.sh"
command -v inner_mtu_args >/dev/null || { echo "FAIL: inner_mtu_args not found"; exit 1; }

check() {
    local desc="$1" content="$2" want="$3" got
    if [ "$content" = "<missing>" ]; then rm -f "$SCRATCH/mtu"; else printf '%s\n' "$content" > "$SCRATCH/mtu"; fi
    got=$(AIDC_MTU_FILE="$SCRATCH/mtu" inner_mtu_args)
    if [ "$got" = "$want" ]; then echo "  PASS: $desc"; PASS=$((PASS + 1))
    else echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1)); fi
}

echo "=== inner dockerd MTU ==="
check "an overlay's smaller MTU is passed on" "1450" "--mtu=1450"
check "a plain Docker host's 1500 passes nothing (dockerd started as before)" "1500" ""
check "a jumbo-frame MTU passes nothing (Docker's default is safe below it)" "9000" ""
check "an unreadable value passes nothing" "abc" ""
check "a missing interface passes nothing" "<missing>" ""

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
