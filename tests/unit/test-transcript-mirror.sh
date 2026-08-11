#!/usr/bin/env bash
# Unit test for the transcript copy-forward mirror (.devcontainer/transcript-mirror.sh).
#
# Regression test for the 2026-07-18 duplicate-delivery incident: the mirror
# used to `cp` straight into the destination filename, which is not atomic --
# on a multi-MB transcript the MCP server's reconnect re-anchor could read the
# destination mid-write, see a torn/truncated file, and rewind its delivery
# watermark backward. The next drain then replayed already-delivered turns to
# the orchestrator. See docs/done/design-09-callback-delivery.md and
# mcp/src/aidc_mcp/tools.py's _baseline_watermark for the downstream defense;
# this test verifies the fix at the source -- the mirror itself never exposes
# a partial file to a reader.
#
# No Docker required: sources the exact function user-main.sh runs inside the
# container, so this exercises the shipped code, not a re-implementation that
# could drift from it.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../.devcontainer/transcript-mirror.sh
. "$AIDC_ROOT/.devcontainer/transcript-mirror.sh"

RUN_ID="mirror-unit-$$"
SCRATCH="$AIDC_ROOT/tests/scratch/${RUN_ID}"
SRC="$SCRATCH/src"
DEST="$SCRATCH/dest"
PASS=0
FAIL=0

cleanup() {
    local watcher_pid="${WATCHER_PID:-}"
    [ -n "$watcher_pid" ] && kill "$watcher_pid" >/dev/null 2>&1
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$SRC" "$DEST"

# Portable mtime (epoch seconds). GNU stat first: `-c %Y` is GNU-only and
# fails cleanly on BSD/macOS stat, so the fallback only fires there. The
# reverse order is a trap -- BSD's `-f` flag means "custom format" but GNU's
# `-f` means "filesystem status" (statvfs, not the file), so `stat -f %m` on
# Linux doesn't error, it silently prints filesystem info instead of the
# file's mtime, and the fallback never triggers.
_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

assert() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "        cmd: $cmd"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== transcript-mirror unit test ==="
echo "scratch: $SCRATCH"
echo

# --- 1: basic copy ----------------------------------------------------------
echo "[1/5] first pass copies a new file"
echo '{"uuid":"1"}' > "$SRC/sess.jsonl"
aidc_mirror_copy_forward_pass "$SRC" "$DEST"
assert "destination file exists" \
    "test -f '$DEST/sess.jsonl'"
assert "destination content matches source" \
    "diff -q '$SRC/sess.jsonl' '$DEST/sess.jsonl'"
assert "no leftover temp files after a clean pass" \
    "[ -z \"\$(find '$DEST' -maxdepth 1 -name '.*.tmp' -print -quit)\" ]"
echo

# --- 2: unchanged source is skipped (cp -u equivalent) ----------------------
echo "[2/5] unchanged source is not re-copied"
before_mtime=$(_mtime "$DEST/sess.jsonl")
sleep 1
aidc_mirror_copy_forward_pass "$SRC" "$DEST"
after_mtime=$(_mtime "$DEST/sess.jsonl")
assert "destination mtime unchanged when source didn't change" \
    "[ '$before_mtime' = '$after_mtime' ]"
echo

# --- 3: changed source IS re-copied -----------------------------------------
echo "[3/5] changed source is re-copied"
sleep 1
echo '{"uuid":"1"}
{"uuid":"2"}' > "$SRC/sess.jsonl"
touch "$SRC/sess.jsonl"
aidc_mirror_copy_forward_pass "$SRC" "$DEST"
assert "destination content updated after source changed" \
    "diff -q '$SRC/sess.jsonl' '$DEST/sess.jsonl'"
echo

# --- 4: symlinks are never mirrored -----------------------------------------
echo "[4/5] symlinks are skipped, not dereferenced"
ln -s "$SRC/sess.jsonl" "$SRC/evil.jsonl"
aidc_mirror_copy_forward_pass "$SRC" "$DEST"
assert "symlinked source is not copied to destination" \
    "[ ! -e '$DEST/evil.jsonl' ]"
rm -f "$SRC/evil.jsonl"
echo

# --- 5: the regression -- no torn reads under a growing file ---------------
echo "[5/5] no torn reads while a large file is copy-forwarded"
# Build a big source file (~a few MB, well beyond a single filesystem write
# buffer) so the copy has a real, measurable duration.
python3 -c "
import json
with open('$SRC/sess.jsonl', 'w') as f:
    for i in range(200000):
        f.write(json.dumps({'uuid': str(i), 'pad': 'x' * 200}) + chr(10))
"
touch "$SRC/sess.jsonl"

TORN_FLAG="$SCRATCH/torn_reads"
: > "$TORN_FLAG"
(
    # Poll the destination while the copy-forward below is (re)writing it.
    # A torn/partial write would show up as a tail line that isn't a
    # complete JSON object and isn't simply an empty read (empty/absent is
    # fine -- that's "hasn't started" or "between old and new complete
    # files", never a partial one under an atomic rename).
    for _ in $(seq 1 400); do
        tail_bytes=$(tail -c 50 "$DEST/sess.jsonl" 2>/dev/null || true)
        case "$tail_bytes" in
            *'}'|'') : ;;  # complete-looking tail, or file not present/empty
            *) echo "torn" >> "$TORN_FLAG" ;;
        esac
    done
) &
WATCHER_PID=$!

aidc_mirror_copy_forward_pass "$SRC" "$DEST"
wait "$WATCHER_PID"
WATCHER_PID=""

torn_count=$(wc -l < "$TORN_FLAG" | tr -d ' ')
assert "zero torn reads observed by a concurrent reader (got: $torn_count)" \
    "[ '$torn_count' = '0' ]"
assert "final destination matches final source" \
    "diff -q '$SRC/sess.jsonl' '$DEST/sess.jsonl'"
echo

# --- summary ------------------------------------------------------------
echo "=== summary ==="
echo "passed: $PASS"
echo "failed: $FAIL"
exit $((FAIL == 0 ? 0 : 1))
