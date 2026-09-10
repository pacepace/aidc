#!/usr/bin/env bash
# Unit tests for `aidc update` (scripts/cmd-update.sh + scripts/lib/update.sh).
#
# Pins, with no network and no Docker:
#
#   1. Install-kind detection from the tree's path/contents: git checkout,
#      Homebrew keg (plain and versioned formula), install.sh layout, unknown.
#   2. Tag comparison without GNU `sort -V` (macOS sort lacks it).
#   3. Dispatch: each kind invokes its own updater and nothing else, --check
#      changes nothing, an up-to-date copy is left alone, and an unknown
#      layout refuses rather than guessing.
#
# The command is run for real with stub curl/brew/git on PATH. The curl stub
# answers the releases API with a canned tag and serves a fake install.sh
# that logs its argv, so the installer path is exercised end to end.
#
# Hygiene: everything under one mktemp dir, removed on exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT_REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
AIDC_SCRIPTS="$AIDC_ROOT_REAL/scripts"

# shellcheck source=../../scripts/lib/update.sh
. "$AIDC_SCRIPTS/lib/update.sh"

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

# --- 1. install-kind detection ----------------------------------------------
echo "-- install kind --"
mkdir -p "$TMP/clone/.git" "$TMP/wt" \
         "$TMP/Cellar/aidc/1.3.1/libexec" "$TMP/Cellar/aidc@1.3/1.3.1/libexec" \
         "$TMP/share/aidc/aidc-1.3.1" "$TMP/share/aidc/aidc-2.0.0-rc1" \
         "$TMP/opt/aidc-tools" "$TMP/random/aidc-1.3.1"
printf 'gitdir: /elsewhere\n' > "$TMP/wt/.git"
eq "git clone"                 git       "$(aidc_install_kind "$TMP/clone")"
eq "git worktree (.git file)"  git       "$(aidc_install_kind "$TMP/wt")"
eq "brew keg"                  brew      "$(aidc_install_kind "$TMP/Cellar/aidc/1.3.1/libexec")"
eq "brew versioned keg"        brew      "$(aidc_install_kind "$TMP/Cellar/aidc@1.3/1.3.1/libexec")"
eq "install.sh layout"         installer "$(aidc_install_kind "$TMP/share/aidc/aidc-1.3.1")"
eq "install.sh pre-release"    installer "$(aidc_install_kind "$TMP/share/aidc/aidc-2.0.0-rc1")"
eq "aidc-<ver> outside share/aidc is unknown" unknown "$(aidc_install_kind "$TMP/random/aidc-1.3.1")"
eq "arbitrary dir is unknown"  unknown   "$(aidc_install_kind "$TMP/opt/aidc-tools")"

# --- 2. tag comparison --------------------------------------------------------
echo
echo "-- semver compare --"
eq "equal"                 0  "$(aidc_semver_cmp v1.3.1 v1.3.1)"
eq "patch older"           -1 "$(aidc_semver_cmp v1.3.0 v1.3.1)"
eq "minor newer"           1  "$(aidc_semver_cmp v1.4.0 v1.3.9)"
eq "major beats minor"     1  "$(aidc_semver_cmp v2.0.0 v1.99.99)"
eq "numeric, not lexical"  1  "$(aidc_semver_cmp v1.10.0 v1.9.0)"
eq "suffix ignored"        0  "$(aidc_semver_cmp v1.3.1-rc1 v1.3.1+build5)"
eq "missing v prefix ok"   -1 "$(aidc_semver_cmp 1.2.3 v1.2.4)"

# --- 3. dispatch ----------------------------------------------------------------
# Stubs. curl answers the releases API with $LATEST_TAG and serves a fake
# install.sh; brew and git log their argv. Each records to $TMP/calls.log.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        http*) url="\$1"; shift ;;
        *) shift ;;
    esac
done
echo "curl \$url" >> "$TMP/calls.log"
case "\$url" in
    *releases/latest/download/install.sh)
        printf '%s\n' '#!/usr/bin/env bash' 'echo "install.sh \$*" >> "$TMP/calls.log"' > "\$out" ;;
    *releases/latest)
        printf '{"tag_name": "%s"}\n' "\${LATEST_TAG}" ;;
    *) exit 22 ;;
esac
STUB
for s in brew git; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$s" "$TMP/calls.log" > "$TMP/bin/$s"
done
chmod +x "$TMP/bin/"*

# Run cmd-update.sh against a fake root of the given kind. Args after the
# latest tag go to the command. Combined output lands in $TMP/out.log, the
# exit code in $RC (set in this shell, so never call this in a subshell).
run_update() { # root current_version latest_tag args...
    local root="$1" cur="$2" latest="$3"; shift 3
    : > "$TMP/calls.log"
    mkdir -p "$root"
    printf '%s\n' "$cur" > "$root/VERSION"
    local cmd="$AIDC_SCRIPTS/cmd-update.sh"
    PATH="$TMP/bin:$PATH" LATEST_TAG="$latest" \
        AIDC_ROOT="$root" AIDC_SCRIPTS="$AIDC_SCRIPTS" AIDC_VERSION="$cur" \
        bash "$cmd" "$@" > "$TMP/out.log" 2>&1
    RC=$?
}
calls() { grep -v '^curl ' "$TMP/calls.log" | tr '\n' ';'; }
said() { grep -c -- "$1" "$TMP/out.log"; }

echo
echo "-- dispatch: installer --"
run_update "$TMP/share/aidc/aidc-1.3.0" v1.3.0 v1.3.1
eq "exit 0" 0 "$RC"
eq "runs the downloaded install.sh with no args" "install.sh ;" "$(calls)"
run_update "$TMP/share/aidc/aidc-1.3.0" v1.3.0 v1.3.1 --version v1.3.1
eq "--version is passed through" "install.sh --version v1.3.1;" "$(calls)"

echo
echo "-- dispatch: brew --"
run_update "$TMP/Cellar/aidc/1.3.0/libexec" v1.3.0 v1.3.1
eq "exit 0" 0 "$RC"
eq "runs brew upgrade aidc" "brew upgrade aidc;" "$(calls)"
run_update "$TMP/Cellar/aidc/1.3.0/libexec" v1.3.0 v1.3.1 --version v1.3.1
eq "--version refused for brew" 1 "$RC"
eq "and nothing ran" "" "$(calls)"

echo
echo "-- dispatch: git --"
run_update "$TMP/clone" v1.3.0 v1.3.1
eq "exit 0" 0 "$RC"
eq "status check then ff-only pull" "git -C $TMP/clone status --porcelain;git -C $TMP/clone pull --ff-only;" "$(calls)"

echo
echo "-- --check and up-to-date --"
run_update "$TMP/share/aidc/aidc-1.3.0" v1.3.0 v1.3.1 --check
eq "--check exits 0" 0 "$RC"
eq "--check reports an update" 1 "$(said 'update available')"
eq "--check runs no updater" "" "$(calls)"
run_update "$TMP/share/aidc/aidc-1.3.1" v1.3.1 v1.3.1
eq "current copy exits 0" 0 "$RC"
eq "current copy is left alone" "" "$(calls)"
eq "and says so" 1 "$(said 'already up to date')"

echo
echo "-- unknown layout --"
run_update "$TMP/opt/aidc-tools" v1.3.0 v1.3.1
eq "refuses" 1 "$RC"
eq "says why" 1 "$(said 'cannot tell how aidc was installed')"
eq "runs nothing" "" "$(calls)"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
