#!/usr/bin/env bash
# Unit tests for aidc-claude-usage (.devcontainer/claude-usage.sh; K8S-17): a cluster session's
# status line leaves its weekly usage, and its StopFailure rate_limit hook a rate limit, in its
# Claude config dir for the account broker, only where a broker manages the session; the user's
# own status line still shows, its ~/.claude/ paths made the session's; it never fails.
#
# Needs jq; skips without it. Hygiene: scratch under tests/scratch/ (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/claude-usage-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}

U="$AIDC_ROOT/.devcontainer/claude-usage.sh"
fresh() { D="$SCRATCH/c$1"; rm -rf "$D"; mkdir -p "$D"; export CLAUDE_CONFIG_DIR="$D"; }
STATUS='{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":42.5,"resets_at":1790000000}}}'

echo "== a session no broker manages: nothing is written, a short status line shows"
fresh 1
out=$(printf '%s' "$STATUS" | bash "$U" statusline; echo "|$?")
assert_eq "it prints the model and the week, exit 0" "Opus  week 42%|0" "$(printf '%s' "$out" | tr -d '\n')"
assert_eq "no usage file" "no" "$([ -e "$D/.aidc-usage.json" ] && echo yes || echo no)"
printf '{}' | bash "$U" rate-limited
assert_eq "no rate-limit file" "no" "$([ -e "$D/.aidc-limit.json" ] && echo yes || echo no)"

echo "== a session the broker manages"
fresh 2
echo work > "$D/.aidc-account"
out=$(printf '%s' "$STATUS" | bash "$U" statusline)
assert_eq "the weekly usage and its reset are left for the broker" '[42.5,1790000000,true]' \
    "$(jq -c '[.seven_day, .resets_at, (.at_s | type == "number")]' "$D/.aidc-usage.json")"
assert_eq "the status line names the account" "Opus  week 42%  [work]" "$out"
echo "work at its threshold: aidc claude account use personal" > "$D/.aidc-notice"
out=$(printf '%s' "$STATUS" | bash "$U" statusline)
assert_eq "the broker's notice shows under it" "aidc: work at its threshold: aidc claude account use personal" "$(printf '%s\n' "$out" | tail -1)"
printf '{"error":"rate_limit"}' | bash "$U" rate-limited
assert_eq "a rate limit is left for the broker" "number" "$(jq -r '.at_s | type' "$D/.aidc-limit.json")"
printf '{"model":{"display_name":"Opus"}}' | bash "$U" statusline >/dev/null
assert_eq "a status with no weekly usage (an API-key login) leaves the last report" "42.5" "$(jq -r .seven_day "$D/.aidc-usage.json")"
assert_eq "no temp file is left" "" "$(find "$D" -name '.*.json.*')"

echo "== the user's own status line, with its paths made the session's"
fresh 3
echo work > "$D/.aidc-account"
printf '#!/bin/sh\njq -r ".model.display_name + \\" custom\\""\n' > "$D/statusline.sh"; chmod +x "$D/statusline.sh"
# shellcheck disable=SC2016  # the literal ~ a laptop's settings hold
printf '{"statusLine":{"type":"command","command":"~/.claude/statusline.sh"}}' > "$D/settings.json"
out=$(printf '%s' "$STATUS" | HOME=/nonexistent bash "$U" statusline)
assert_eq "it runs, from this Claude config dir, with the same input" "Opus custom  [work]" "$out"
printf '{"statusLine":{"type":"command","command":"/Users/alice/.claude/statusline.sh"}}' > "$D/settings.json"
out=$(printf '%s' "$STATUS" | bash "$U" statusline)
assert_eq "a Mac's path too" "Opus custom  [work]" "$out"
printf '{"statusLine":{"type":"command","command":"/usr/local/bin/aidc-claude-usage statusline"}}' > "$D/settings.json"
out=$(printf '%s' "$STATUS" | bash "$U" statusline)
assert_eq "itself is never run again (no loop)" "Opus  week 42%  [work]" "$out"

echo "== it never fails"
fresh 4
echo work > "$D/.aidc-account"
chmod 0500 "$D"
out=$(printf 'not json' | bash "$U" statusline; echo "|$?")
assert_eq "bad input in a dir it cannot write: exit 0" "|0" "$(printf '%s' "$out" | tail -c 2)"
chmod 0700 "$D"
mkdir "$D/.aidc-usage.json"
printf '%s' "$STATUS" | bash "$U" statusline >/dev/null
assert_eq "a usage name that is a folder is never written into" "" "$(ls -A "$D/.aidc-usage.json")"

echo
echo "claude-usage: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
