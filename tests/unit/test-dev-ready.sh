#!/usr/bin/env bash
# Unit test for how the CLI repeats a dev container's "Claude cannot write its
# transcripts" lines: relay_transcript_warnings, and wait_for_dev_ready (create,
# upgrade) which calls it, in scripts/lib/common.sh.
#
# Why it matters: a session whose memory dir it cannot write comes up looking
# healthy. Claude says so only in its own status bar, and the orchestrator waits on
# replies the MCP can never read from a transcript that is never written. On
# 2026-10-19 that went unnoticed for half an hour after `aidc create` said nothing.
# The container diagnoses it (entrypoint.sh, user-main.sh); the CLI must repeat that
# diagnosis, and must still succeed when there is nothing to say.
#
# The log lines are produced by the container's own functions
# (.devcontainer/claude-state-install.sh), not typed here, so rewording them cannot
# leave this test green while the CLI goes quiet.
#
# `docker` is a PATH stub that prints a canned log, so no daemon is needed.
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/dev-ready-$$"
PASS=0
FAIL=0
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin"

eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

# shellcheck source=../../.devcontainer/claude-state-install.sh
. "$AIDC_ROOT/.devcontainer/claude-state-install.sh"

# The producers' real lines. A failed claim comes from a chown stub that refuses; an
# unwritable dir is a real 0555 dir (which root could still write, hence the check).
cat > "$SCRATCH/bin/chown" <<'STUB'
#!/bin/sh
exit 1
STUB
cat > "$SCRATCH/bin/stat" <<'STUB'
#!/bin/sh
echo 0
STUB
chmod +x "$SCRATCH/bin/chown" "$SCRATCH/bin/stat"
mkdir -p "$SCRATCH/projects/-work-repo"
CLAIM_LINE=$(PATH="$SCRATCH/bin:$PATH" aidc_claim_docker_made_dirs vscode:vscode - "$SCRATCH/projects" | tail -1)
chmod 0555 "$SCRATCH/projects/-work-repo"
if [ -w "$SCRATCH/projects/-work-repo" ]; then
    echo "  SKIP: running as root, a 0555 dir is still writable; using a claim line instead"
    WARN_LINE="$CLAIM_LINE"
else
    WARN_LINE=$(aidc_transcript_dir_warning "$SCRATCH/projects/-work-repo")
fi
eq "the producers did produce a line to test with" "yes" \
    "$([ -n "$CLAIM_LINE" ] && [ -n "$WARN_LINE" ] && echo yes || echo no)"

cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
[ "$1" = logs ] && cat "$DEV_LOG"
exit 0
STUB
chmod +x "$SCRATCH/bin/docker"

# Runs wait_for_dev_ready under `set -euo pipefail`, as create and upgrade do.
ready() {
    # shellcheck disable=SC2016  # expansions are for the inner shell, on purpose
    PATH="$SCRATCH/bin:$PATH" DEV_LOG="$SCRATCH/log" AIDC_ROOT="$AIDC_ROOT" bash -c '
        set -euo pipefail
        . "$AIDC_ROOT/scripts/lib/common.sh"
        wait_for_dev_ready sess 4
        echo "rc=$?" >&2' 2>&1
}

# Laid out as entrypoint.sh and user-main.sh log them.
{
    echo "[aidc-entrypoint] claude scratchpad root ready at /tmp/claude-1000"
    echo "[aidc-entrypoint] memory/scratchpad mount: ${CLAIM_LINE}"
    echo "[aidc-user-main] WARN: ${WARN_LINE}"
    echo "[aidc-user-main] WARN: tmux-start exited non-zero"
    echo "[aidc-user-main] ready (tmux running, sleeping forever)"
} > "$SCRATCH/log"
out=$(ready)
eq "an unwritable memory dir is repeated to the operator" "1" \
    "$(printf '%s\n' "$out" | grep -cF "[aidc] WARNING: [aidc-user-main] WARN: ${WARN_LINE}")"
eq "and so is a claim the entrypoint could not make" "1" \
    "$(printf '%s\n' "$out" | grep -cF "[aidc] WARNING: [aidc-entrypoint] memory/scratchpad mount: ${CLAIM_LINE}")"
eq "other warnings are not swept up with them" "0" \
    "$(printf '%s\n' "$out" | grep -c 'WARNING: .*tmux-start')"
eq "the wait still succeeds: the session is up, just impaired" "rc=0" \
    "$(printf '%s\n' "$out" | tail -1)"

{
    echo "[aidc-entrypoint] memory/scratchpad mount: claimed /home/vscode/.claude/projects/-work-repo"
    echo "[aidc-user-main] ready (tmux running, sleeping forever)"
} > "$SCRATCH/log"
out=$(ready)
eq "a repaired dir is not a warning" "0" "$(printf '%s\n' "$out" | grep -c 'WARNING')"
eq "and a quiet log does not trip set -e" "rc=0" "$(printf '%s\n' "$out" | tail -1)"

# cmd-restart.sh calls the relay directly, under set -e, with this start's log only.
# shellcheck disable=SC2016  # expansions are for the inner shell, on purpose
out=$(AIDC_ROOT="$AIDC_ROOT" bash -c '
    set -euo pipefail
    . "$AIDC_ROOT/scripts/lib/common.sh"
    relay_transcript_warnings ""
    echo "rc=$?"' 2>&1)
eq "restart: an empty log relays nothing and returns 0" "rc=0" "$out"
grep -q 'relay_transcript_warnings' "$AIDC_ROOT/scripts/cmd-restart.sh"
eq "restart relays the warnings too" "0" "$?"

echo
echo "dev ready: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
