#!/usr/bin/env bash
# Unit test: the dev image carries what Playwright's Chromium needs to launch.
#
# Without these packages `npx playwright install chromium` downloads the browser but
# launch fails with "Host system is missing dependencies to run browsers", and a
# session can only fix that with sudo (seen live in a metallm session, 2026-10-15).
# The list is Playwright 1.63's for ubuntu26.04, `tools` plus `chromium`: what
# `npx playwright install-deps chromium` installs on the image's Ubuntu.
#
# Static: reads the apt lists out of .devcontainer/Dockerfile. No Docker, so CI's
# no-daemon job runs it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DF="$AIDC_ROOT/.devcontainer/Dockerfile"
PASS=0
FAIL=0

TOOLS="xvfb fonts-noto-color-emoji fonts-unifont libfontconfig1 libfreetype6
       xfonts-cyrillic xfonts-scalable fonts-liberation fonts-ipafont-gothic
       fonts-wqy-zenhei fonts-tlwg-loma-otf fonts-freefont-ttf"
CHROMIUM="libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64
          libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64
          libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1
          libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2"

echo "=== dev image browser deps ==="

# Every package named in an `apt-get install` of the Dockerfile, one per line.
installed=$(awk '/apt-get install/ { f = 1 } f { print } f && !/\\$/ { f = 0 }' "$DF" \
    | grep -v '^[[:space:]]*#' \
    | sed 's/\\$//' | tr -s ' ' '\n' \
    | grep -E '^[a-z0-9][a-z0-9.+-]+$' | sort -u)

base=$(sed -nE 's/^FROM (ubuntu:[^[:space:]]+).*/\1/p' "$DF" | head -1)
if [ "$base" = "ubuntu:26.04" ]; then
    echo "  PASS: the image is ubuntu:26.04, the release this list is for"; PASS=$((PASS + 1))
else
    echo "  FAIL: the image is '${base}'; take the list for it from Playwright's nativeDeps"
    FAIL=$((FAIL + 1))
fi

for pkg in $TOOLS $CHROMIUM; do
    if printf '%s\n' "$installed" | grep -qxF "$pkg"; then
        echo "  PASS: ${pkg}"; PASS=$((PASS + 1))
    else
        echo "  FAIL: ${pkg} is NOT installed in .devcontainer/Dockerfile"; FAIL=$((FAIL + 1))
    fi
done

# The browser stays a per-project download, matching each project's Playwright.
if grep -v '^[[:space:]]*#' "$DF" | grep -q 'playwright install'; then
    echo "  FAIL: the Dockerfile installs a Playwright browser; leave that to the project"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no browser is baked into the image"; PASS=$((PASS + 1))
fi

echo
echo "browser deps: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
