#!/usr/bin/env bash
# Every sourced library under scripts/lib reports its own failures.
#
# A library that calls die/err/info/warn without defining it depends on the caller
# having sourced common.sh first. When one has not, `cmd || die ...` is a
# command-not-found that the || swallows, and the failure it was meant to stop passes
# silently (aidc_mkdir_host's chown, 2026-09-17). Inside $(...) a die ends only that
# subshell even when it exists. So libraries print to stderr and return non-zero, and
# the command script decides to exit. common.sh, which defines the helpers, is exempt.
#
# Hygiene: reads files only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0

echo "=== libraries report their own failures ==="
for f in "$AIDC_ROOT"/scripts/lib/*.sh; do
    [ "$(basename "$f")" = common.sh ] && continue
    calls=""
    for h in die err info warn; do
        # Defined here? Then calling it is fine.
        grep -qE "^[[:space:]]*${h}[[:space:]]*\(\)" "$f" && continue
        # A call: the helper as a command word, outside comments.
        hits=$(grep -nE "(^|[;&|(){]|then|else|do)[[:space:]]*${h}[[:space:]]" "$f" \
            | grep -vE '^[0-9]+:[[:space:]]*#' || true)
        [ -n "$hits" ] && calls="${calls}${hits}
"
    done
    name="scripts/lib/$(basename "$f")"
    if [ -z "$calls" ]; then
        echo "  PASS: ${name}"; PASS=$((PASS + 1))
    else
        echo "  FAIL: ${name} calls a helper it does not define:"
        printf '%s' "$calls" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "libraries: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
