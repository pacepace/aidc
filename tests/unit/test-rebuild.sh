#!/usr/bin/env bash
# Unit test for `aidc rebuild` (scripts/cmd-rebuild.sh).
#
# Pins two properties with a stub `docker` on PATH (no daemon, no network):
#
#   1. The dev-base build gets `--build-arg CLAUDE_CODE_REFRESH=<epoch>` so the
#      Claude Code installer layer is never served from cache. Without it a
#      rebuild silently ships whatever release the layer fetched the first time
#      it was built.
#   2. No other image gets that build arg. Their Dockerfiles do not declare it,
#      and an unconsumed build arg makes docker print a warning on every rebuild.
#
# The build-args array is empty for six of the seven images, and bash 3.2 (the
# repo's floor; stock macOS) treats an empty array as unbound under `set -u`.
# Running the real command over the full inventory is what exercises that path.
#
# Hygiene: scratch dir under mktemp, removed on exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AIDC_SCRIPTS="$AIDC_ROOT/scripts"
AIDC_VERSION_TAG="vtest"
export AIDC_ROOT AIDC_SCRIPTS AIDC_VERSION_TAG

PASS=0
FAIL=0

eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; echo "    want: $want"; echo "    got:  $got"; FAIL=$((FAIL + 1))
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub docker: `docker info` succeeds (require_docker), `docker build` logs its
# argv one invocation per line and succeeds.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) exit 0 ;;
    build) printf '%s\n' "\$*" >> "$TMP/builds.log"; exit 0 ;;
    *) echo "unexpected docker \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/docker"

echo "-- aidc rebuild over the full inventory --"
PATH="$TMP/bin:$PATH" bash "$AIDC_SCRIPTS/cmd-rebuild.sh" >"$TMP/out.log" 2>&1
eq "rebuild exits 0 with the stub docker" "0" "$?"

eq "one docker build per inventory image" "7" "$(wc -l < "$TMP/builds.log" | tr -d ' ')"

echo
echo "-- CLAUDE_CODE_REFRESH goes to dev-base and only dev-base --"
eq "dev-base build carries the refresh arg" "1" \
   "$(grep -c -- '--build-arg CLAUDE_CODE_REFRESH=[0-9][0-9]* .*-t aidc/dev-base:vtest ' "$TMP/builds.log")"
eq "no other build carries the refresh arg" "1" \
   "$(grep -c -- 'CLAUDE_CODE_REFRESH' "$TMP/builds.log")"
eq "every build is tagged at the version" "7" \
   "$(grep -c -- '-t aidc/[a-z-]*:vtest ' "$TMP/builds.log")"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
