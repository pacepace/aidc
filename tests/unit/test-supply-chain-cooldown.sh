#!/usr/bin/env bash
# REL-09: no package manager aidc runs takes a version published in the last 14 days:
# the MCP server's lock, and uv/pip/npm in the dev image (as system defaults). A malicious release (a hijacked maintainer account, a
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

# The dev image sets the same rule for every package manager, as a system default.
DF="$AIDC_ROOT/.devcontainer/Dockerfile"
check "dev image: uv waits 14 days (/etc/uv/uv.toml)" \
    "$(grep -F "exclude-newer = \"14 days\"" "$DF" | grep -qF "> /etc/uv/uv.toml" && echo yes || echo no)"
check "dev image: pip waits 14 days (/etc/pip.conf)" \
    "$(grep -q "uploaded-prior-to = P14D" "$DF" && grep -q "> /etc/pip.conf" "$DF" && echo yes || echo no)"
check "dev image: npm waits 14 days (/etc/npmrc, pinned as npm's global config)" \
    "$(grep -q "min-release-age=14" "$DF" && grep -q "^ENV NPM_CONFIG_GLOBALCONFIG=/etc/npmrc" "$DF" && echo yes || echo no)"
check "dev image: every interpreter's pip is checked for the option at build (pip 25.3 floor)" \
    "$(grep -q 'grep -q -- --uploaded-prior-to' "$DF" && grep -q "\-\-ignore-installed --quiet 'pip>=25.3'" "$DF" && echo yes || echo no)"
# The settings must exist before the first package-manager install in the build.
first_install=$(grep -nE "npm install|pip install|pipx install|uv tool install|uv pip" "$DF" \
    | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
settings_line=$(grep -n "> /etc/npmrc" "$DF" | head -1 | cut -d: -f1)
check "dev image: the settings come before the first package install (line ${settings_line:-?} < ${first_install:-?})" \
    "$([ -n "$settings_line" ] && [ -n "$first_install" ] && [ "$settings_line" -lt "$first_install" ] && echo yes || echo no)"

echo
echo "cooldown: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
