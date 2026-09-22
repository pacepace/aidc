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
eq 'the conventional script, $HOME/.claude/statusline-command.sh' "bridge statusline-command.sh" \
    "$(with '"bash $HOME/.claude/statusline-command.sh"')"
eq 'the ~ form' "bridge statusline-command.sh" "$(with '"~/.claude/statusline-command.sh"')"
eq 'an absolute host path, and a quoted one' "bridge statusline-command.sh" \
    "$(with "\"bash '$H/.claude/statusline-command.sh'\"")"
eq 'a script that does not exist is not bridged' "skip statusline-command.sh" \
    "$(rm -f "$H/.claude/statusline-command.sh"; with '"bash $HOME/.claude/statusline-command.sh"'; : > "$H/.claude/statusline-command.sh")"

# settings.json is writable from inside a session, so what it names must never choose
# a mount: a host secret, a history file, another project's memory, a planted symlink.
: > "$H/.claude/.credentials.json"; : > "$H/.claude/history.jsonl"
mkdir -p "$H/.claude/projects/-other"; : > "$H/.claude/projects/-other/x.sh"
eq 'the host credentials file is never bridged' "skip .credentials.json" \
    "$(with '"bash $HOME/.claude/.credentials.json"')"
eq 'nor the history, nor a file in a project memory dir (writable by a session)' \
    "skip history.jsonl,skip projects/-other/x.sh" \
    "$(with '"cat $HOME/.claude/history.jsonl; bash ~/.claude/projects/-other/x.sh"')"
eq 'nor any other script, even a real one' "skip bin/helper.py" "$(with '"python3 ${HOME}/.claude/bin/helper.py"')"
eq 'a path that escapes ~/.claude' "skip ../.ssh/id_rsa" "$(with '"bash $HOME/.claude/../.ssh/id_rsa"')"
ln -sf "$H/.claude/.credentials.json" "$H/.claude/link.sh"
mv "$H/.claude/statusline-command.sh" "$H/.claude/real.sh"; ln -s "$H/.claude/real.sh" "$H/.claude/statusline-command.sh"
eq 'the conventional name as a symlink is not bridged (docker would mount the target)' \
    "skip statusline-command.sh" "$(with '"bash $HOME/.claude/statusline-command.sh"')"
rm "$H/.claude/statusline-command.sh"; mv "$H/.claude/real.sh" "$H/.claude/statusline-command.sh"
eq 'a script outside ~/.claude is not ours to mount' "" "$(with '"bash /usr/local/bin/statusline"')"
eq 'a command with no script' "" "$(with '"echo hi"')"
printf '{"theme":"dark"}' > "$S"
eq 'no status line at all' "" "$(aidc_statusline_scripts "$S" "$H" | paste -sd, -)"
eq 'no settings file at all' "" "$(aidc_statusline_scripts "$SCRATCH/nope.json" "$H" | paste -sd, -)"

# settings.json itself is never mounted: a session could write hooks into it that the
# host's Claude Code runs. It is copied in at create.
eq "aidc create no longer mounts settings.json" "0" \
    "$(grep -c 'settings.json:/home/vscode/.claude/settings.json' "$AIDC_ROOT/scripts/cmd-create.sh")"
eq "and copies it next to the onboarding seed instead" "1" \
    "$(grep -c 'cp "$HOST_CLAUDE_SETTINGS" "${AUDIT_WRITE}/claude-settings-seed.json"' "$AIDC_ROOT/scripts/cmd-create.sh")"
eq "which the session installs on first start" "1" \
    "$(grep -c 'aidc_install_claude_settings_seed "$CLAUDE_CONFIG_DIR" /var/aidc/audit/claude-settings-seed.json' "$AIDC_ROOT/.devcontainer/user-main.sh")"

# aidc create must use it, and mount read-only.
eq "aidc create bridges what it finds, read-only" "1" \
    "$(grep -c '.claude/\${_sl}:/home/vscode/.claude/\${_sl}:ro' "$AIDC_ROOT/scripts/cmd-create.sh")"

echo
echo "status-line bridge: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
