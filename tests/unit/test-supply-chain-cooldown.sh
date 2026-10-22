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

# stale_exceptions <pyproject> <now-epoch> <cooldown-days>: the packages whose
# exclude-newer-package cutoff is more than <cooldown-days> before <now>, one per line.
# Reads the inline-table form under [tool.uv] and the [tool.uv.exclude-newer-package]
# table form. A cutoff it cannot parse is reported too, so a format change fails loudly.
stale_exceptions() {
    local file="$1" now="$2" limit="$3" pkg cutoff epoch
    awk '
        /^\[tool\.uv\.exclude-newer-package\]/ { in_tbl = 1; next }
        /^\[/ { in_tbl = 0; in_uv = ($0 ~ /^\[tool\.uv\]/); next }
        in_uv && /^exclude-newer-package[[:space:]]*=/ {
            s = $0; sub(/^[^{]*\{/, "", s); sub(/\}.*$/, "", s)
            n = split(s, parts, ",")
            for (i = 1; i <= n; i++) if (parts[i] ~ /=/) print parts[i]
            next
        }
        in_tbl && /=/ { print }
    ' "$file" | while IFS='=' read -r pkg cutoff; do
        pkg=$(printf '%s' "$pkg" | tr -d ' "')
        cutoff=$(printf '%s' "$cutoff" | tr -d ' "')
        if ! epoch=$(date -u -d "$cutoff" +%s 2>/dev/null); then
            echo "${pkg}(unparsed:${cutoff})"
        elif [ $((now - epoch)) -gt $((limit * 86400)) ]; then
            echo "$pkg"
        fi
    done
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

# A per-package exception (`exclude-newer-package`) is a fixed date. Once that date is
# more than the cooldown in the past, it no longer admits anything early; it only holds
# the package back, so a later fix for it (a CA-root removal in certifi, say) would
# never reach the lock. Each such exception must go once it has served.
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT
day=86400
now=${COOLDOWN_NOW:-$(date -u +%s)}  # COOLDOWN_NOW (epoch) previews a later day
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
cat > "$FIXTURES/old.toml" <<EOF
[tool.uv]
exclude-newer = "14 days"
exclude-newer-package = { certifi = "$(iso $((now - 20 * day)))", idna = "$(iso $((now - 2 * day)))" }
EOF
cat > "$FIXTURES/old-table.toml" <<EOF
[tool.uv]
exclude-newer = "14 days"

[tool.uv.exclude-newer-package]
pyjwt = "$(iso $((now - 30 * day)))"
EOF
cat > "$FIXTURES/fresh.toml" <<EOF
[tool.uv]
exclude-newer = "14 days"
exclude-newer-package = { certifi = "$(iso $((now - 2 * day)))" }
EOF
check "fixture: a cutoff 20 days old is reported, a 2-day one is not (got: '$(stale_exceptions "$FIXTURES/old.toml" "$now" 14)')" \
    "$([ "$(stale_exceptions "$FIXTURES/old.toml" "$now" 14)" = "certifi" ] && echo yes || echo no)"
check "fixture: the [tool.uv.exclude-newer-package] table form is read too" \
    "$([ "$(stale_exceptions "$FIXTURES/old-table.toml" "$now" 14)" = "pyjwt" ] && echo yes || echo no)"
check "fixture: a cutoff inside the cooldown is not reported" \
    "$([ -z "$(stale_exceptions "$FIXTURES/fresh.toml" "$now" 14)" ] && echo yes || echo no)"

stale=$(stale_exceptions "$AIDC_ROOT/mcp/pyproject.toml" "$now" "${days:-14}")
check "mcp/pyproject.toml has no exclude-newer-package cutoff older than the cooldown${stale:+ (expired: ${stale}: the release it admitted is past the cooldown now, and the version floor under constraint-dependencies holds it; delete the exception and its comment)}" \
    "$([ -z "$stale" ] && echo yes || echo no)"

echo
echo "cooldown: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
