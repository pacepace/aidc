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
assert_eq "the weekly usage and its reset are left for the broker, naming the account" '["work",42.5,1790000000,true]' \
    "$(jq -c '[.account, .seven_day, .resets_at, (.at_s | type == "number")]' "$D/.aidc-usage.json")"
echo personal > "$D/.aidc-account"
printf '%s' "$STATUS" | bash "$U" statusline >/dev/null
assert_eq "right after a switch, the old account's numbers are not reported as the new one's" "work" "$(jq -r .account "$D/.aidc-usage.json")"
printf '%s' "$STATUS" | jq -c '.rate_limits.seven_day = {used_percentage: 3, resets_at: 1790500000}' | bash "$U" statusline >/dev/null
assert_eq "...the new account's own numbers are" '["personal",3]' "$(jq -c '[.account, .seven_day]' "$D/.aidc-usage.json")"
echo work > "$D/.aidc-account"
assert_eq "the status line names the account" "Opus  week 42%  [work]" "$out"
echo "work at its threshold: aidc claude account use personal" > "$D/.aidc-notice"
out=$(printf '%s' "$STATUS" | bash "$U" statusline)
assert_eq "the broker's notice shows under it" "aidc: work at its threshold: aidc claude account use personal" "$(printf '%s\n' "$out" | tail -1)"
printf '{"error":"rate_limit"}' | bash "$U" rate-limited
assert_eq "a rate limit is left for the broker, naming the account" '["work","number"]' "$(jq -c '[.account, (.at_s | type)]' "$D/.aidc-limit.json")"
printf '{"model":{"display_name":"Opus"}}' | bash "$U" statusline >/dev/null
assert_eq "a status with no weekly usage (an API-key login) leaves the last report" "42.5" "$(jq -r .seven_day "$D/.aidc-usage.json")"
assert_eq "no temp file is left" "" "$(find "$D" -name '.*.json.*')"

echo "== a new session switched by its first call's weekly limit: that call's week is not the new account's"
# Seen live: the first call hit main's weekly limit, the broker switched the session to second
# within seconds, and the status line, still showing that call's numbers, had no earlier report
# to compare with. The transcript says when the last call answered; .aidc-account when the
# broker named the account.
D2="$D"
fresh 5
T=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z; }
TP="$D/transcript.jsonl"
printf '{"type":"user","timestamp":"%s"}\n{"type":"assistant","timestamp":"%s","isApiErrorMessage":true}\n' "$(iso $((T - 60)))" "$(iso $((T - 50)))" > "$TP"
echo second > "$D/.aidc-account"; touch -d "@$((T - 10))" "$D/.aidc-account"
LIMITED=$(jq -n -c --arg tp "$TP" '{model: {display_name: "Opus"}, transcript_path: $tp,
    rate_limits: {seven_day: {used_percentage: 100, resets_at: 1790000000}}}')
printf '%s' "$LIMITED" | bash "$U" statusline >/dev/null
assert_eq "the limited call's numbers are not reported under the account named after it" "no" "$([ -e "$D/.aidc-usage.json" ] && echo yes || echo no)"
printf '{"type":"assistant","timestamp":"%s"}\n' "$(iso "$T")" >> "$TP"
printf '%s' "$LIMITED" | jq -c '.rate_limits.seven_day = {used_percentage: 5, resets_at: 1790400000}' | bash "$U" statusline >/dev/null
assert_eq "the first call made after the switch is reported as the new account's" '["second",5,1790400000]' \
    "$(jq -c '[.account, .seven_day, .resets_at]' "$D/.aidc-usage.json" 2>/dev/null)"
printf '{"error":"rate_limit","message":"You have reached your weekly limit. Resets Monday."}' | bash "$U" rate-limited
assert_eq "a weekly limit is reported as one" '["second","weekly"]' "$(jq -c '[.account, .kind]' "$D/.aidc-limit.json")"
printf '{"error":"rate_limit","message":"5-hour limit reached"}' | bash "$U" rate-limited
assert_eq "any other limit as a rate limit" "rate" "$(jq -r '.kind' "$D/.aidc-limit.json")"
printf '{"error":"rate_limit","message":"5-hour limit reached","cwd":"/home/u/weekly-report","transcript_path":"/home/u/.claude/projects/-home-u-weekly-report/x.jsonl"}' | bash "$U" rate-limited
assert_eq "...even in a repo whose path says weekly (only Claude's error and message are read)" "rate" "$(jq -r '.kind' "$D/.aidc-limit.json")"
printf '{"hook_event_name":"StopFailure","error":{"type":"rate_limit","details":"Weekly limit reached"}}' | bash "$U" rate-limited
assert_eq "...and a weekly limit named in a nested error detail is one" "weekly" "$(jq -r '.kind' "$D/.aidc-limit.json")"
D="$D2"; export CLAUDE_CONFIG_DIR="$D"

echo "== the account and its notice reach the user's MCP server (session_status)"
M="$SCRATCH/mirror2"; mkdir -p "$M"
printf '%s' "$STATUS" | AIDC_TRANSCRIPT_OUT="$M" bash "$U" statusline >/dev/null
assert_eq "claude-account.json in the session's mirror folder" '["work","work at its threshold: aidc claude account use personal",true]' \
    "$(jq -c '[.account, .notice, (.at | test("Z$"))]' "$M/claude-account.json")"
rm -f "$D/.aidc-notice"
printf '%s' "$STATUS" | AIDC_TRANSCRIPT_OUT="$M" bash "$U" statusline >/dev/null
assert_eq "...notice null when there is none" "null" "$(jq -r '.notice' "$M/claude-account.json")"

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
