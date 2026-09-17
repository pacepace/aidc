#!/usr/bin/env bash
# Unit test: the aidc-mcp image carries every command the CLI requires.
#
# session_create runs the aidc CLI inside the aidc-mcp container. Anything the CLI
# calls require_cmd on must be installed there, or the tool fails at the door — which
# is what happened with envsubst: `aidc create` through the MCP died with "required
# commands missing: envsubst" in every released image.
#
# Static: reads the require_cmd lines out of scripts/ and the apk list out of
# mcp/Dockerfile. No Docker, so CI's no-daemon job runs it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0

# Commands whose alpine package is not named after them.
package_for() {
    case "$1" in
        envsubst) printf 'gettext' ;;
        docker)   printf 'docker-cli' ;;
        *)        printf '%s' "$1" ;;
    esac
}

# Only the subcommands the MCP itself runs (aidc create / list / kill / status / exec);
# `aidc update` requires brew and git, and nothing in the container runs it.
apk_list=$(awk '/^RUN apk add/{f=1} f{print} f && !/\\$/{exit}' "$AIDC_ROOT/mcp/Dockerfile")
mcp_scripts=""
for c in create list kill status exec; do
    [ -f "$AIDC_ROOT/scripts/cmd-${c}.sh" ] && mcp_scripts="${mcp_scripts} $AIDC_ROOT/scripts/cmd-${c}.sh"
done
# shellcheck disable=SC2086  # deliberate word splitting of the file list
required=$(grep -ho 'require_cmd [a-z0-9 _-]*' $mcp_scripts | sed 's/require_cmd //' | tr ' ' '\n' | sort -u)

echo "=== aidc-mcp image deps ==="

# `aidc create` and `aidc kill` drive the stack with `docker compose`, which is a
# separate alpine package from the docker CLI. Without it create dies at
# "unknown shorthand flag: 'p' in -p" after making the session's dirs.
case "$apk_list" in
    *docker-cli-compose*) echo "  PASS: docker compose is installed"; PASS=$((PASS + 1)) ;;
    *) echo "  FAIL: docker compose (apk docker-cli-compose) is NOT installed"; FAIL=$((FAIL + 1)) ;;
esac
for cmd in $required; do
    [ -n "$cmd" ] || continue
    pkg=$(package_for "$cmd")
    case "$apk_list" in
        *"$pkg"*) echo "  PASS: ${cmd} (apk ${pkg}) is installed"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: ${cmd} (apk ${pkg}) is NOT installed in mcp/Dockerfile"; FAIL=$((FAIL + 1)) ;;
    esac
done
if [ "$PASS" -eq 0 ]; then
    echo "  FAIL: found no require_cmd lines to check — has the CLI changed shape?"
    FAIL=$((FAIL + 1))
fi

echo
echo "aidc-mcp image deps: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
