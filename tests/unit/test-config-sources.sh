#!/usr/bin/env bash
# Unit test for where load_config reads the global config from
# (scripts/lib/config.sh).
#
# aidc-mcp runs this CLI for session_create inside its own container, where HOME is
# /root and the host's config is mounted at /aidc-config. Reading only
# ~/.config/aidc/config.yaml there meant every session the MCP created silently used
# the defaults instead of the host's settings.
#
# Pure function calls: no Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/config-sources-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/host/.config/aidc" "$SCRATCH/mount" "$SCRATCH/empty"

eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

printf 'profile: solo\ntaint_response: kill\n' > "$SCRATCH/host/.config/aidc/config.yaml"
printf 'profile: multi\ntaint_response: log\n' > "$SCRATCH/mount/config.yaml"

profile_with() {
    # $1 = HOME, $2 = AIDC_MCP_CONFIG_MOUNT
    # shellcheck disable=SC2016  # $AIDC_ROOT expands in the inner shell, on purpose
    env -i PATH="/usr/bin:/bin" HOME="$1" AIDC_MCP_CONFIG_MOUNT="$2" \
        AIDC_ROOT="$AIDC_ROOT" bash -c '
            . "$AIDC_ROOT/scripts/lib/config.sh"
            load_config >/dev/null 2>&1
            printf "%s %s" "$AIDC_PROFILE" "$AIDC_TAINT_RESPONSE"'
}

echo "=== config sources ==="

eq "the host config wins when it is there" "solo kill" \
    "$(profile_with "$SCRATCH/host" "$SCRATCH/mount")"
eq "the mounted config is read when there is no host config (inside aidc-mcp)" \
    "multi log" "$(profile_with "$SCRATCH/empty" "$SCRATCH/mount")"
eq "neither present falls back to the defaults" "multi freeze" \
    "$(profile_with "$SCRATCH/empty" "$SCRATCH/empty")"

echo
echo "config sources: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
