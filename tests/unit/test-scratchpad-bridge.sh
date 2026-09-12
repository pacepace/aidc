#!/usr/bin/env bash
# Unit test for the Claude scratchpad bridge (share_scratchpad).
#
# What this protects:
#
#   1. Source == target. The bridge only works because the host path and the
#      container path are the SAME string: Claude Code derives its scratchpad
#      location from the uid and the launch directory, so a session resumed on
#      the other side of the container boundary only finds its own files if
#      both sides compute the identical path. Break that symmetry and the
#      feature fails silently -- each side quietly gets its own empty dir.
#
#   2. Only this repo's subdir is bridged, never the whole /tmp/claude-<uid>
#      root. The root holds every other project's scratchpad; mounting it would
#      hand the sandbox what the README explicitly refuses to share.
#
#   3. A host uid that is not the container's suppresses the mount entirely.
#      The host dirs are mode 0700, so such a mount lands unwritable and Claude
#      cannot create its scratchpad at all -- strictly worse than not bridging.
#
#   4. The compose placeholder survives rendering. compose-render.sh restricts
#      envsubst to an explicit allowlist, so a placeholder added to the template
#      but not the allowlist renders LITERALLY into the YAML. That is invisible
#      in review and fatal at `docker compose up`.
#
# No Docker required: sources the exact helpers `aidc create` calls and runs the
# real render script, so this exercises shipped code rather than a copy that
# could drift from it.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/common.sh
. "$AIDC_ROOT/scripts/lib/common.sh"

RUN_ID="scratchpad-unit-$$"
SCRATCH="$AIDC_ROOT/tests/scratch/${RUN_ID}"
PASS=0
FAIL=0

cleanup() { rm -rf "$SCRATCH" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

mkdir -p "$SCRATCH"

assert() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "        want: $want"
        echo "        got:  $got"
        FAIL=$((FAIL + 1))
    fi
}

ENC="-home-someone-work-myrepo"

echo "== mount line shape =="

MOUNT=$(aidc_scratchpad_mount "$AIDC_CONTAINER_UID" "$ENC")
assert_eq "emits the compose volume line for a matching uid" \
    "- /tmp/claude-${AIDC_CONTAINER_UID}/${ENC}:/tmp/claude-${AIDC_CONTAINER_UID}/${ENC}:rw" \
    "$MOUNT"

# Strip the leading "- " and the trailing ":rw", then split on ":".
SPEC=${MOUNT#- }
SPEC=${SPEC%:rw}
SRC=${SPEC%%:*}
DST=${SPEC#*:}

assert_eq "host source and container target are the identical path" "$SRC" "$DST"

assert_eq "host dir helper agrees with the mount's source" \
    "$(aidc_scratchpad_host_dir "$AIDC_CONTAINER_UID" "$ENC")" "$SRC"

assert "the bridged path is the per-repo subdir, not the scratchpad root" \
    "[ \"\$SRC\" != \"/tmp/claude-${AIDC_CONTAINER_UID}\" ]"

assert "the bridged path carries the encoded repo segment" \
    "case \"\$SRC\" in */${ENC}) true ;; *) false ;; esac"

assert "the mount is read-write (the point is popping back in)" \
    "case \"\$MOUNT\" in *:rw) true ;; *) false ;; esac"

echo "== uid mismatch suppresses the mount =="

MISMATCH_UID=$((AIDC_CONTAINER_UID + 501))
OUT=$(aidc_scratchpad_mount "$MISMATCH_UID" "$ENC")
RC=$?

assert_eq "non-zero return for a host uid the container cannot write as" "1" "$RC"
assert_eq "emits nothing, so the compose line collapses" "" "$OUT"

echo "== the placeholder survives compose rendering =="

render() {
    # Minimal environment for a standalone render; the scratchpad mount is
    # whatever the caller exported.
    AIDC_VERSION_TAG=test-tag \
    SESSION=probe PROFILE=python \
    REPO_PATH=/home/someone/work/myrepo WORKSPACE_PATH=/home/someone/work/myrepo \
    AUDIT_DIR=/home/someone/aidc-audit/probe \
    HOST_CLAUDE_PROJECT_DIR="/home/someone/.claude/projects/${ENC}" \
    ENCODED_REPO="$ENC" \
    bash "$AIDC_ROOT/proxy/compose-render.sh" < "$AIDC_ROOT/proxy/compose.yaml.template"
}

CLAUDE_SCRATCHPAD_MOUNT="$MOUNT" render > "$SCRATCH/with.yaml" 2>"$SCRATCH/with.err"
assert "render succeeds with the bridge enabled" "[ -s \"$SCRATCH/with.yaml\" ]"

assert "the mount's path reaches the rendered YAML" \
    "grep -q '${SRC}:${DST}:rw' \"$SCRATCH/with.yaml\""

# The regression this pins: a template placeholder missing from the envsubst
# allowlist renders as its own literal text instead of its value.
assert "no literal placeholder survives the render" \
    "! grep -q 'CLAUDE_SCRATCHPAD_MOUNT' \"$SCRATCH/with.yaml\""

render > "$SCRATCH/without.yaml" 2>"$SCRATCH/without.err"
assert "render succeeds with the bridge disabled" "[ -s \"$SCRATCH/without.yaml\" ]"

assert "an unset bridge leaves no scratchpad mount behind" \
    "! grep -q '/tmp/claude-' \"$SCRATCH/without.yaml\""

assert "an unset bridge leaves no literal placeholder either" \
    "! grep -q 'CLAUDE_SCRATCHPAD_MOUNT' \"$SCRATCH/without.yaml\""

# The bridged and unbridged renders must differ by exactly the one mount line:
# proof the placeholder is self-contained and collapses without disturbing the
# surrounding YAML.
DIFF_LINES=$(diff "$SCRATCH/without.yaml" "$SCRATCH/with.yaml" | grep -c '^>')
assert_eq "enabling the bridge adds exactly one line to the compose file" "1" "$DIFF_LINES"

echo "== the toggle reaches subprocesses =="

# load_config exports the other share_* toggles, so anything reading config in
# a child process sees them. A toggle left off that list still works for the
# in-shell reader in cmd-create.sh and silently reverts to its default
# everywhere else -- re-enabling a bridge the user turned off, which is the
# wrong direction to fail for a mount that writes to the host.
CFG_HOME="$SCRATCH/home"
mkdir -p "$CFG_HOME/repo"
EXPORTED=$(
    HOME="$CFG_HOME" bash -c '
        . "$1/scripts/lib/config.sh"
        load_config "$2" "$2" >/dev/null 2>&1
        export -p | grep -c "AIDC_SHARE_SCRATCHPAD"
    ' _ "$AIDC_ROOT" "$CFG_HOME/repo" 2>/dev/null
)
assert_eq "load_config exports AIDC_SHARE_SCRATCHPAD" "1" "$EXPORTED"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
