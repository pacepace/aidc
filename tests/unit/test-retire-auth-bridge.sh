#!/usr/bin/env bash
# Unit test for aidc_retire_auth_bridge (scripts/lib/common.sh).
#
# aidc < 1.5.0 ran a nohup-detached Keychain watcher on macOS whose only stop
# paths were commands that no longer exist. `aidc create` and `aidc kill` now
# retire whatever it left behind under ~/.config/aidc. This function kills a
# host process and deletes files, so its edges are pinned here: nothing to do
# is a silent no-op; a live watcher is stopped and its files removed; a stale
# pid file naming an unrelated process must NOT get that process killed; a
# second call is a no-op.
#
# No Docker required. HOME is pointed at a scratch dir under tests/scratch/
# (gitignored) so the real ~/.config/aidc is never touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/common.sh
. "$AIDC_ROOT/scripts/lib/common.sh"

SCRATCH="$AIDC_ROOT/tests/scratch/retire-bridge-unit-$$"
export HOME="$SCRATCH/home"
CFG="$HOME/.config/aidc"
PASS=0
FAIL=0
BG_PIDS=()
cleanup() {
    local p
    for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" >/dev/null 2>&1; done
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
mkdir -p "$CFG"

assert() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; echo "        cmd: $cmd"; FAIL=$((FAIL + 1))
    fi
}

echo "[1/4] nothing to retire"
assert "returns 0 with no watcher files" "aidc_retire_auth_bridge"
assert "creates nothing" "[ -z \"\$(ls -A '$CFG')\" ]"
echo

echo "[2/4] a live watcher"
# A background process whose command line names the watcher, like the real one.
WATCHER="$SCRATCH/aidc-auth-bridge-watcher.sh"
printf '#!/usr/bin/env bash\nwhile true; do sleep 1; done\n' > "$WATCHER"
chmod +x "$WATCHER"
bash "$WATCHER" & LIVE_PID=$!
BG_PIDS+=("$LIVE_PID")
printf '%s\n' "$LIVE_PID" > "$CFG/auth-bridge.pid"
printf 'old log\n' > "$CFG/auth-bridge.log"
touch "$CFG/auth-bridge.disabled"
assert "retire returns 0" "aidc_retire_auth_bridge"
sleep 0.5
assert "the watcher process is gone" "! kill -0 $LIVE_PID"
assert "pid, log and sentinel files are removed" \
    "[ ! -e '$CFG/auth-bridge.pid' ] && [ ! -e '$CFG/auth-bridge.log' ] && [ ! -e '$CFG/auth-bridge.disabled' ]"
echo

echo "[3/4] a stale pid file naming an unrelated process (pid reuse after reboot)"
sleep 300 & OTHER_PID=$!
BG_PIDS+=("$OTHER_PID")
printf '%s\n' "$OTHER_PID" > "$CFG/auth-bridge.pid"
assert "retire returns 0" "aidc_retire_auth_bridge"
assert "the unrelated process is NOT killed" "kill -0 $OTHER_PID"
assert "the stale pid file is still removed" "[ ! -e '$CFG/auth-bridge.pid' ]"
printf 'not-a-pid\n' > "$CFG/auth-bridge.pid"
assert "garbage in the pid file is tolerated and removed" \
    "aidc_retire_auth_bridge && [ ! -e '$CFG/auth-bridge.pid' ]"
printf '999999999\n' > "$CFG/auth-bridge.pid"
assert "a dead pid is tolerated and the file removed" \
    "aidc_retire_auth_bridge && [ ! -e '$CFG/auth-bridge.pid' ]"
echo

echo "[4/4] idempotent"
assert "a second call with nothing left is a no-op" "aidc_retire_auth_bridge"
assert "the config dir is untouched otherwise" "[ -z \"\$(ls -A '$CFG')\" ]"
echo

echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
