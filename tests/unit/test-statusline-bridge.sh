#!/usr/bin/env bash
# The status-line script bridge (aidc_statusline_scripts in scripts/lib/claude-state.sh).
#
# settings.json is mounted into the session, so its statusLine command runs there;
# a script it names under ~/.claude must be bridged too or the line shows nothing.
# Only files under ~/.claude, only ones that exist, never a path that escapes.
#
# Hygiene: scratch under tests/scratch, removed on exit. No Docker.

# The settings.json bodies carry a literal $HOME on purpose (that is what the file says).
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/statusline-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/home/.claude/bin"

# shellcheck source=../../scripts/lib/claude-state.sh
. "$AIDC_ROOT/scripts/lib/claude-state.sh"

eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

H="$SCRATCH/home"
S="$H/.claude/settings.json"
: > "$H/.claude/statusline-command.sh"
: > "$H/.claude/bin/helper.py"
with() { printf '{"statusLine":{"type":"command","command":%s}}' "$1" > "$S"; aidc_statusline_scripts "$S" "$H" | paste -sd, -; }

echo "=== status-line script bridge ==="
eq 'the usual form, $HOME/.claude/<script>' "statusline-command.sh" \
    "$(with '"bash $HOME/.claude/statusline-command.sh"')"
eq 'the ~ form' "statusline-command.sh" "$(with '"~/.claude/statusline-command.sh"')"
eq 'an absolute host path, and a quoted one' "statusline-command.sh" \
    "$(with "\"bash '$H/.claude/statusline-command.sh'\"")"
eq 'two scripts, in a subdirectory too' "statusline-command.sh,bin/helper.py" \
    "$(with '"bash $HOME/.claude/statusline-command.sh | python3 ${HOME}/.claude/bin/helper.py"')"
eq 'a script that does not exist is not bridged' "" "$(with '"bash $HOME/.claude/missing.sh"')"
eq 'a path that escapes ~/.claude is not bridged' "" "$(with '"bash $HOME/.claude/../.ssh/id_rsa"')"
eq 'a script outside ~/.claude is not bridged (it is not ours to mount)' "" \
    "$(with '"bash /usr/local/bin/statusline"')"
eq 'a command with no script' "" "$(with '"echo hi"')"
printf '{"theme":"dark"}' > "$S"
eq 'no status line at all' "" "$(aidc_statusline_scripts "$S" "$H" | paste -sd, -)"
eq 'no settings file at all' "" "$(aidc_statusline_scripts "$SCRATCH/nope.json" "$H" | paste -sd, -)"

# aidc create must use it, and mount read-only.
eq "aidc create bridges what it finds, read-only" "1" \
    "$(grep -c '.claude/\${_sl}:/home/vscode/.claude/\${_sl}:ro' "$AIDC_ROOT/scripts/cmd-create.sh")"

echo
echo "status-line bridge: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
