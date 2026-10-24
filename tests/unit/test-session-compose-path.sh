#!/usr/bin/env bash
# Unit test for where a session's rendered compose file lives (scripts/lib/common.sh):
#
#   aidc_session_compose_path  -- the state copy, under the host home, never /tmp: a
#       reboot or a disk cleanup emptied /tmp and left sessions impossible to upgrade.
#   aidc_session_compose_file  -- the file to read; a /tmp copy left by an older aidc
#       is moved into state first, and used where it is only if it cannot be moved.
#
# No Docker required. Scratch lives under tests/scratch/ (gitignored); the legacy
# copies are real /tmp paths, named for this run and removed on exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/common.sh
. "$AIDC_ROOT/scripts/lib/common.sh"

SCRATCH="$AIDC_ROOT/tests/scratch/session-compose-path-unit-$$"
N1="utcompose$$a"
N2="utcompose$$b"
N3="utcompose$$c"
PASS=0
FAIL=0
cleanup() {
    chmod -R u+w "$SCRATCH" 2>/dev/null || true
    rm -rf "$SCRATCH" 2>/dev/null || true
    rm -f "/tmp/aidc-${N1}.yaml" "/tmp/aidc-${N2}.yaml" "/tmp/aidc-${N3}.yaml"
}
trap cleanup EXIT INT TERM
mkdir -p "$SCRATCH/home"

assert() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; echo "        cmd: $cmd"; FAIL=$((FAIL + 1))
    fi
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

export AIDC_HOST_HOME="$SCRATCH/home"
STATE="$SCRATCH/home/.local/state/aidc/sessions"

echo "[1/7] the path is in state, under the host home"
assert "state path for a name" "[ \"\$(aidc_session_compose_path s1)\" = '$STATE/s1.yaml' ]"
assert "legacy path is the old /tmp one" "[ \"\$(aidc_legacy_compose_path s1)\" = /tmp/aidc-s1.yaml ]"
# aidc-mcp passes the host home; XDG_STATE_HOME from the host is not in its env, so the
# path must not depend on it.
assert "XDG_STATE_HOME does not move it" "[ \"\$(XDG_STATE_HOME=/elsewhere aidc_session_compose_path s1)\" = '$STATE/s1.yaml' ]"

echo "[2/7] no file anywhere: the state path, nothing created"
got=$(aidc_session_compose_file "$N1" 2>/dev/null)
assert "prints the state path" "[ '$got' = '$STATE/$N1.yaml' ]"
assert "creates no file" "[ ! -e '$STATE/$N1.yaml' ]"

echo "[3/7] a /tmp copy from an older aidc is moved into state"
printf 'services: {}\nsecret: x\n' > "/tmp/aidc-${N1}.yaml"
chmod 600 "/tmp/aidc-${N1}.yaml"
got=$(aidc_session_compose_file "$N1" 2>"$SCRATCH/err")
assert "prints the state path" "[ '$got' = '$STATE/$N1.yaml' ]"
assert "the state copy has the content" "grep -qx 'secret: x' '$STATE/$N1.yaml'"
assert "the state copy is 0600" "[ \"\$(mode_of '$STATE/$N1.yaml')\" = 600 ]"
assert "the sessions dir is private" "[ \"\$(mode_of '$STATE')\" = 700 ]"
assert "the /tmp copy is gone" "[ ! -e /tmp/aidc-${N1}.yaml ]"
assert "the move is reported" "grep -q 'moved session $N1 compose file' '$SCRATCH/err'"
# Both present: the state copy wins and the /tmp one is not touched.
printf 'stale\n' > "/tmp/aidc-${N1}.yaml"
got=$(aidc_session_compose_file "$N1" 2>/dev/null)
assert "with both, the state copy is read" "[ '$got' = '$STATE/$N1.yaml' ] && grep -qx 'secret: x' '$STATE/$N1.yaml'"
assert "with both, the /tmp copy is left alone" "grep -qx stale /tmp/aidc-${N1}.yaml"

echo "[4/7] a /tmp copy that cannot be moved is used where it is"
# A home whose state dir cannot be made.
export AIDC_HOST_HOME="$SCRATCH/rohome"
mkdir -p "$SCRATCH/rohome"
chmod 500 "$SCRATCH/rohome"
printf 'services: {}\n' > "/tmp/aidc-${N2}.yaml"
got=$(aidc_session_compose_file "$N2" 2>"$SCRATCH/err")
if [ "$(id -u)" = 0 ]; then
    echo "  SKIP: running as root, a read-only home is still writable"
else
    assert "prints the /tmp path" "[ '$got' = /tmp/aidc-${N2}.yaml ]"
    assert "the /tmp copy is kept" "[ -f /tmp/aidc-${N2}.yaml ]"
    assert "a warning says so" "grep -q 'could not move' '$SCRATCH/err'"
    # The state dir could not be made, so nothing was written under it.
    assert "no state file written" "[ ! -e '$SCRATCH/rohome/.local/state/aidc/sessions/$N2.yaml' ]"
fi

echo "[5/7] find and remove"
export AIDC_HOST_HOME="$SCRATCH/home"
printf 'old\n' > "/tmp/aidc-${N3}.yaml"
assert "find names a /tmp-only copy" "[ \"\$(aidc_session_compose_find $N3)\" = /tmp/aidc-${N3}.yaml ]"
assert "find does not move it" "[ -f /tmp/aidc-${N3}.yaml ] && [ ! -e '$STATE/$N3.yaml' ]"
cp "/tmp/aidc-${N3}.yaml" "$STATE/$N3.yaml"
assert "find prefers the state copy" "[ \"\$(aidc_session_compose_find $N3)\" = '$STATE/$N3.yaml' ]"
got=$(aidc_remove_session_compose "$N3")
assert "remove names both copies" "[ '$got' = '$STATE/$N3.yaml /tmp/aidc-${N3}.yaml' ]"
assert "both copies are gone" "[ ! -e '$STATE/$N3.yaml' ] && [ ! -e /tmp/aidc-${N3}.yaml ]"
assert "remove with nothing left prints nothing" "[ -z \"\$(aidc_remove_session_compose $N3)\" ]"

echo "[6/7] aidc kill on a session with no containers"
# docker stub: the daemon answers, no container carries the session's label or its
# dev container's name, and no network by its name exists.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
    info) exit 0 ;;
    ps) exit 0 ;;
    network|inspect) exit 1 ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/docker"
run_kill() {
    env -i PATH="$SCRATCH/bin:/usr/bin:/bin" HOME="$SCRATCH/home" \
        AIDC_HOST_HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" \
        bash "$AIDC_ROOT/scripts/cmd-kill.sh" "$1"
}
printf 'secret\n' > "$STATE/$N3.yaml"
printf 'secret\n' > "/tmp/aidc-${N3}.yaml"
out=$(run_kill "$N3" 2>&1); rc=$?
assert "kill exits 0 when only the compose file is left" "[ $rc -eq 0 ]"
assert "kill says it removed the leftover file" "printf '%s' \"\$out\" | grep -q 'removed its leftover compose file'"
assert "the state copy is gone" "[ ! -e '$STATE/$N3.yaml' ]"
assert "the /tmp copy is gone" "[ ! -e /tmp/aidc-${N3}.yaml ]"
out=$(run_kill "$N3" 2>&1); rc=$?
assert "with nothing left, kill still fails" "[ $rc -ne 0 ]"
assert "with nothing left, kill says no such session" "printf '%s' \"\$out\" | grep -q 'no such session'"

echo "[7/7] aidc upgrade on a session whose compose file is gone"
# docker stub: the session's containers exist; nothing else is reached before the check.
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
    info) exit 0 ;;
    ps) echo 0123456789ab; exit 0 ;;
esac
exit 0
STUB
out=$(env -i PATH="$SCRATCH/bin:/usr/bin:/bin" HOME="$SCRATCH/home" \
    AIDC_HOST_HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" AIDC_ROOT="$AIDC_ROOT" \
    bash "$AIDC_ROOT/scripts/cmd-upgrade.sh" "$N3" --yes 2>&1); rc=$?
assert "upgrade refuses" "[ $rc -ne 0 ]"
assert "it names the state path" "printf '%s' \"\$out\" | grep -qF '$STATE/$N3.yaml'"
assert "it names the /tmp path" "printf '%s' \"\$out\" | grep -qF /tmp/aidc-${N3}.yaml"
assert "it says to recreate" "printf '%s' \"\$out\" | grep -q 'aidc kill ${N3} && aidc create ${N3}'"

echo
echo "session-compose-path: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
