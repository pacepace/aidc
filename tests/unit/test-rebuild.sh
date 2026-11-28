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
    build) printf '%s\n' "\$*" >> "$TMP/builds.log"
        # What testament/ holds in the context it was handed (dev-base's alone has one).
        ctx="\${*: -1}"
        [ -d "\$ctx/testament" ] && printf 'testament-folder %s %s\n' "\$ctx" "\$(ls "\$ctx/testament" | paste -sd, -)" >> "$TMP/contexts.log"
        exit 0 ;;
    *) echo "unexpected docker \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/docker"

# HOME is the test's: no testament configured (the user's own config is never read here).
mkdir -p "$TMP/home"

echo "-- aidc rebuild over the full inventory --"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" bash "$AIDC_SCRIPTS/cmd-rebuild.sh" >"$TMP/out.log" 2>&1
eq "rebuild exits 0 with the stub docker" "0" "$?"

eq "one docker build per inventory image Docker runs (not gitctl with no git container set up, nor the account broker with none set up)" "7" "$(wc -l < "$TMP/builds.log" | tr -d ' ')"
eq "the account broker is not built where it is not set up" "0" "$(grep -c -- '-t aidc/broker:' "$TMP/builds.log")"

echo
echo "-- with the account broker set up here (its accounts' volume), its image is rebuilt too --"
sed 's|^    info) exit 0 ;;|    info) exit 0 ;;\n    volume) [ "\$3" = aidc-claude-accounts ] \&\& exit 0; exit 1 ;;|' "$TMP/bin/docker" > "$TMP/docker2"
mkdir -p "$TMP/bin2"; mv "$TMP/docker2" "$TMP/bin2/docker"; chmod +x "$TMP/bin2/docker"
: > "$TMP/builds.log"
HOME="$TMP/home" PATH="$TMP/bin2:$PATH" bash "$AIDC_SCRIPTS/cmd-rebuild.sh" >"$TMP/out2.log" 2>&1
eq "the broker is built, refreshing its Claude Code (its logins and renewals are Claude Code's)" "1" \
   "$(grep -c -- '--build-arg CLAUDE_CODE_REFRESH=[0-9][0-9]* .*-t aidc/broker:vtest ' "$TMP/builds.log")"
# The cases below read the run with no broker set up.
: > "$TMP/builds.log"; : > "$TMP/contexts.log"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" bash "$AIDC_SCRIPTS/cmd-rebuild.sh" >"$TMP/out.log" 2>&1

echo
echo "-- CLAUDE_CODE_REFRESH goes to dev-base and only dev-base --"
eq "dev-base build carries the refresh arg" "1" \
   "$(grep -c -- '--build-arg CLAUDE_CODE_REFRESH=[0-9][0-9]* .*-t aidc/dev-base:vtest ' "$TMP/builds.log")"
eq "no other build carries the refresh arg" "1" \
   "$(grep -c -- 'CLAUDE_CODE_REFRESH' "$TMP/builds.log")"
eq "every build is tagged at the version" "7" \
   "$(grep -c -- '-t aidc/[a-z-]*:vtest ' "$TMP/builds.log")"


echo
echo "-- dev-base builds from a staged copy of its context (testament, K8S-25) --"
eq "only dev-base's context has a testament folder, and it is a staged copy, not the install's" "1 no" \
   "$(grep -c '^testament-folder ' "$TMP/contexts.log" 2>/dev/null) $(grep -q "testament-folder ${AIDC_ROOT}/.devcontainer " "$TMP/contexts.log" && echo yes || echo no)"
eq "with no testament configured it holds no wheel" "" \
   "$(grep '^testament-folder ' "$TMP/contexts.log" | awk '{ print $3 }' | tr ',' '\n' | grep '\.whl$')"
grep -q 'testament: not configured' "$TMP/out.log"; eq "and the rebuild says so in a line" 0 "$?"
eq "the staged copy is removed after the build" "" \
   "$(grep '^testament-folder ' "$TMP/contexts.log" | awk '{ print $2 }' | while read -r d; do [ -e "$d" ] && echo "$d"; done)"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
