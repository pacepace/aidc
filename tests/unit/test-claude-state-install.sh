#!/usr/bin/env bash
# Unit test for the container's first-start Claude state install
# (.devcontainer/claude-state-install.sh): the empty-placeholder sweep and the
# onboarding-seed install that user-main.sh runs before launching Claude.
#
# No Docker required: sources the exact functions user-main.sh runs inside the
# container. Scratch lives under tests/scratch/ (gitignored).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../.devcontainer/claude-state-install.sh
. "$AIDC_ROOT/.devcontainer/claude-state-install.sh"

SCRATCH="$AIDC_ROOT/tests/scratch/claude-state-install-unit-$$"
HOMEDIR="$SCRATCH/home"
CFG="$HOMEDIR/.claude"
PASS=0
FAIL=0
cleanup() { rm -rf "$SCRATCH" 2>/dev/null || true; }
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

echo "[1/3] aidc_clear_mount_placeholders"
assert "nothing present is a silent no-op" \
    "[ -z \"\$(aidc_clear_mount_placeholders '$CFG' '$HOMEDIR')\" ]"
: > "$CFG/.credentials.json"
: > "$HOMEDIR/.claude.json"
# shellcheck disable=SC2034  # read inside the eval'd assert string below
OUT=$(aidc_clear_mount_placeholders "$CFG" "$HOMEDIR")
assert "both empty placeholders are removed" \
    "[ ! -e '$CFG/.credentials.json' ] && [ ! -e '$HOMEDIR/.claude.json' ]"
assert "each removal is reported by path" \
    "printf '%s' \"\$OUT\" | grep -q '.credentials.json' && printf '%s' \"\$OUT\" | grep -q '/.claude.json'"
printf '{"claudeAiOauth":{"accessToken":"x"}}' > "$CFG/.credentials.json"
printf '{"hasCompletedOnboarding":true}' > "$HOMEDIR/.claude.json"
assert "files with content are never touched" \
    "[ -z \"\$(aidc_clear_mount_placeholders '$CFG' '$HOMEDIR')\" ] && [ -s '$CFG/.credentials.json' ] && [ -s '$HOMEDIR/.claude.json' ]"
rm -f "$CFG/.credentials.json" "$HOMEDIR/.claude.json"
echo

echo "[2/3] aidc_install_claude_state_seed"
SEED="$SCRATCH/claude-state-seed.json"
assert "no seed file -> nothing to do (1)" \
    "aidc_install_claude_state_seed '$CFG' '$SEED'; [ \$? -eq 1 ] && [ ! -e '$CFG/.claude.json' ]"
printf '{"hasCompletedOnboarding":true,"theme":"dark"}' > "$SEED"
assert "seed installs into an empty config dir (0)" \
    "aidc_install_claude_state_seed '$CFG' '$SEED' && grep -q hasCompletedOnboarding '$CFG/.claude.json'"
assert "installed file is private (0600)" \
    "[ \"\$(stat -c %a '$CFG/.claude.json' 2>/dev/null || stat -f %Lp '$CFG/.claude.json')\" = 600 ]"
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"me@example.com"}}' > "$CFG/.claude.json"
assert "an existing .claude.json (a login lives in it) is never overwritten (1)" \
    "aidc_install_claude_state_seed '$CFG' '$SEED'; [ \$? -eq 1 ] && grep -q me@example.com '$CFG/.claude.json'"
rm -rf "$CFG"
assert "a missing config dir is created on the way (0)" \
    "aidc_install_claude_state_seed '$CFG' '$SEED' && [ -s '$CFG/.claude.json' ]"
: > "$SCRATCH/empty-seed.json"
rm -f "$CFG/.claude.json"
assert "an empty seed is treated as absent (1)" \
    "aidc_install_claude_state_seed '$CFG' '$SCRATCH/empty-seed.json'; [ \$? -eq 1 ] && [ ! -e '$CFG/.claude.json' ]"
echo

echo "[3/3] the order user-main.sh runs them in"
: > "$HOMEDIR/.claude.json"
: > "$CFG/.credentials.json"
aidc_clear_mount_placeholders "$CFG" "$HOMEDIR" >/dev/null
assert "after a legacy upgrade: placeholders gone, then the seed lands" \
    "aidc_install_claude_state_seed '$CFG' '$SEED' && [ -s '$CFG/.claude.json' ] && [ ! -e '$CFG/.credentials.json' ] && [ ! -e '$HOMEDIR/.claude.json' ]"
echo

echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
