#!/usr/bin/env bash
# REL-09: the MCP server's Python dependencies are never resolved to a version
# published in the last 14 days. A malicious release (a hijacked maintainer account, a
# typosquat) is usually found and pulled within days; the cooldown keeps it out of the
# lock until then. This pins the setting so it cannot be dropped or shortened quietly.
#
# Hygiene: reads files only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0

check() {
    if [ "$2" = "yes" ]; then echo "  PASS: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1"; FAIL=$((FAIL + 1)); fi
}

echo "=== supply-chain cooldown ==="

# The setting, as uv reads it: under [tool.uv], a duration of at least 14 days.
setting=$(awk '/^\[tool\.uv\]/ { in_uv = 1; next } /^\[/ { in_uv = 0 }
               in_uv && /^exclude-newer[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); print }' \
          "$AIDC_ROOT/mcp/pyproject.toml")
days=$(printf '%s' "$setting" | sed -nE 's/^([0-9]+) days?$/\1/p')
check "mcp/pyproject.toml sets exclude-newer under [tool.uv] (got: '${setting}')" \
    "$([ -n "$setting" ] && echo yes || echo no)"
check "and it is at least 14 days" "$([ -n "$days" ] && [ "$days" -ge 14 ] && echo yes || echo no)"

# The lock was resolved under it: uv records a relative cooldown as exclude-newer-span.
span=$(sed -nE 's/^exclude-newer-span = "P([0-9]+)D"$/\1/p' "$AIDC_ROOT/mcp/uv.lock")
check "mcp/uv.lock was resolved with the same cooldown (got: P${span:-none}D)" \
    "$([ -n "$span" ] && [ "$span" = "$days" ] && echo yes || echo no)"

echo
echo "cooldown: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
