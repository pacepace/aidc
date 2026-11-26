#!/usr/bin/env bash
# Unit tests for the Claude account broker (broker/claude-broker.sh; K8S-16, K8S-17): accounts
# added by Claude's own login, renewed by Claude Code near expiry, the active account's
# credentials written into each session's folder without the refresh token, and switching on
# weekly usage or a rate limit, automatically or waiting for the user, around the cycle.
#
# Claude Code is a PATH stub (no network, no real login). Needs jq; skips without it.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/claude-broker-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}
assert_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (no '$needle' in: $(printf '%s' "$hay" | tail -5))"; FAIL=$((FAIL + 1)) ;;
    esac
}
assert_not_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  FAIL: $desc ('$needle' present in: $(printf '%s' "$hay" | tail -5))"; FAIL=$((FAIL + 1)) ;;
        *) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
    esac
}

# The claude stub: logs each call (with its CLAUDE_CONFIG_DIR) to $C_LOG.
#   auth login   writes a login for the account (its folder's name): access token at-<name>-1,
#                refresh token rt-<name>, expiring in $C_LOGIN_EXP_S seconds (default 8 hours);
#                C_NO_REFRESH=1 leaves the refresh token out
#   -p ...       a refresh, as Claude does before a call: the access token's number goes up and
#                it expires in 8 hours; C_RENEW_FAIL=1 fails without writing
#   auth logout  nothing
cat > "$SCRATCH/bin/claude" <<'STUB_CLAUDE_BROKER_r7'
#!/bin/sh
printf '%s|%s\n' "$(basename "$CLAUDE_CONFIG_DIR")" "$*" >> "$C_LOG"
f="$CLAUDE_CONFIG_DIR/.credentials.json"
name=$(basename "$CLAUDE_CONFIG_DIR")
case "$*" in
    "auth login"*)
        exp=$(( ($(date +%s) + ${C_LOGIN_EXP_S:-28800}) * 1000 ))
        if [ "${C_NO_REFRESH:-}" = 1 ]; then
            printf '{"claudeAiOauth":{"accessToken":"at-%s-1","expiresAt":%s,"scopes":["user:inference"],"subscriptionType":"max"}}\n' "$name" "$exp" > "$f"
        else
            printf '{"claudeAiOauth":{"accessToken":"at-%s-1","refreshToken":"rt-%s","expiresAt":%s,"scopes":["user:inference"],"subscriptionType":"max"}}\n' "$name" "$name" "$exp" > "$f"
        fi ;;
    "-p "*)
        [ "${C_RENEW_FAIL:-}" = 1 ] && { echo "OAuth token refresh failed: invalid_grant" >&2; exit 1; }
        n=$(jq -r '.claudeAiOauth.accessToken | split("-") | last | tonumber' "$f")
        exp=$(( ($(date +%s) + 28800) * 1000 ))
        jq -c --arg t "at-${name}-$((n + 1))" --argjson e "$exp" '.claudeAiOauth.accessToken = $t | .claudeAiOauth.expiresAt = $e' "$f" > "$f.new" && mv "$f.new" "$f"
        echo ok ;;
    "auth logout"*) : ;;
esac
STUB_CLAUDE_BROKER_r7
chmod +x "$SCRATCH/bin/claude"

# fresh: a new broker world (claims, config) for one case.
fresh() {
    W="$SCRATCH/w$1"
    rm -rf "$W"
    mkdir -p "$W/home" "$W/access" "$W/etc"
    export BROKER_HOME="$W/home" BROKER_ACCESS="$W/access" \
        BROKER_CONFIG="$W/etc/config.json" BROKER_CLAUDE="$SCRATCH/bin/claude" C_LOG="$W/claude.log"
    : > "$C_LOG"
    printf '%s' "${2:-{\}}" > "$BROKER_CONFIG"
}

broker() { bash "$AIDC_ROOT/broker/claude-broker.sh" "$@"; }

# usage <session> <account> <percent> [<resets_at epoch>]: the session's statusline report (the
# account is the one the broker gave it: checked, since the report is about that one).
usage() {
    assert_eq "(the session $1 is on $2)" "$2" "$(cat "$BROKER_ACCESS/$1/.aidc-account")"
    jq -n -c --argjson p "$3" --argjson r "${4:-null}" --argjson t "$(date +%s)" \
        '{seven_day: $p, resets_at: $r, at_s: $t}' > "$BROKER_ACCESS/$1/.aidc-usage.json"
}

echo "== an account added by Claude's own login reaches a session without its refresh token"
fresh 1
out=$(broker login work 2>&1)
assert_has "login says the account was added" "account work added" "$out"
assert_has "Claude's own login ran in the account's folder" "work|auth login --claudeai" "$(cat "$C_LOG")"
broker session s1 2>/dev/null
creds=$(cat "$BROKER_ACCESS/s1/.credentials.json" 2>/dev/null)
assert_eq "the session's credentials carry the access token" "at-work-1" "$(printf '%s' "$creds" | jq -r .claudeAiOauth.accessToken)"
assert_not_has "the refresh token never reaches a session" "rt-work" "$creds"
assert_eq "the session's folder names the account" "work" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
assert_eq "the session's credentials are its own (0600)" "600" "$(stat -c %a "$BROKER_ACCESS/s1/.credentials.json")"
assert_eq "the session's folder is closed to others (0700)" "700" "$(stat -c %a "$BROKER_ACCESS/s1")"
assert_eq "the broker's copy keeps the refresh token" "rt-work" "$(jq -r .claudeAiOauth.refreshToken "$BROKER_HOME/accounts/work/.credentials.json")"

echo "== a login with no renewable token is refused"
fresh 2
out=$(C_NO_REFRESH=1 broker login work 2>&1); rc=$?
assert_eq "it fails" "1" "$rc"
assert_has "and says why" "no renewable login" "$out"

echo "== names that could leave their folder are refused"
fresh 3
out=$(broker login ../x 2>&1); rc=$?
assert_eq "an account named ../x is refused" "2" "$rc"
out=$(broker session ../x 2>&1); rc=$?
assert_eq "a session named ../x is refused" "2" "$rc"
assert_eq "nothing was made outside the claims" "" "$(find "$W" -mindepth 1 -maxdepth 1 ! -name home ! -name access ! -name etc ! -name claude.log)"

echo "== with no account, a session is told how to add one"
fresh 4
broker session s1 2>/dev/null
assert_has "its notice says aidc claude account add" "aidc claude account add" "$(cat "$BROKER_ACCESS/s1/.aidc-notice")"
assert_eq "and it gets no credentials" "no" "$([ -e "$BROKER_ACCESS/s1/.credentials.json" ] && echo yes || echo no)"
printf '{"claudeAiOauth":{"accessToken":"own"}}' > "$BROKER_ACCESS/s1/.credentials.json"
broker pass 2>/dev/null
assert_eq "a session's own login is left as it is" "own" "$(jq -r .claudeAiOauth.accessToken "$BROKER_ACCESS/s1/.credentials.json")"

echo "== renewal: only near expiry, by Claude Code itself"
fresh 5
broker login work >/dev/null 2>&1
: > "$C_LOG"
broker pass 2>/dev/null
assert_not_has "a token far from expiry is not renewed" "-p" "$(cat "$C_LOG")"
fresh 6
C_LOGIN_EXP_S=600 broker login work >/dev/null 2>&1
broker session s1 2>/dev/null
broker pass 2>/dev/null
assert_has "a token within the margin is renewed by running Claude in its folder" "work|-p --model haiku" "$(cat "$C_LOG")"
assert_eq "the session gets the renewed token" "at-work-2" "$(jq -r .claudeAiOauth.accessToken "$BROKER_ACCESS/s1/.credentials.json")"
assert_has "the renewal is recorded" "renewed_at" "$(cat "$BROKER_HOME/state.json")"

echo "== a failed renewal shows in the list and in the session's notice"
fresh 7
C_LOGIN_EXP_S=600 C_RENEW_FAIL=1 broker login work >/dev/null 2>&1
broker session s1 2>/dev/null
C_RENEW_FAIL=1 broker pass 2>/dev/null
list=$(broker list 2>/dev/null)
assert_has "the list says the renewal is failing, with Claude's words" "RENEWAL FAILING: OAuth token refresh failed: invalid_grant" "$list"
assert_eq "list --json carries it" "OAuth token refresh failed: invalid_grant" "$(broker list --json | jq -r '.accounts[0].renew_error')"
assert_has "the session's notice points to the list" "renewal failing" "$(cat "$BROKER_ACCESS/s1/.aidc-notice")"
broker pass 2>/dev/null
assert_eq "a later good renewal clears it" "null" "$(broker list --json | jq -r '.accounts[0].renew_error')"

echo "== switching on weekly usage, automatically, in the configured order"
fresh 8 '{"accounts":[{"name":"work","switch_at":90},{"name":"personal","switch_at":70}],"switch":"auto"}'
broker login personal >/dev/null 2>&1
broker login work >/dev/null 2>&1
broker session s1 2>/dev/null; broker session s2 2>/dev/null
jq 'del(.active)' "$BROKER_HOME/state.json" > "$W/s" && mv "$W/s" "$BROKER_HOME/state.json"
broker pass 2>/dev/null
assert_eq "with none active, the first account of the configured order is (not of name order)" "work" "$(broker list --json | jq -r '.accounts[] | select(.active) | .name')"
usage s1 work 89
broker pass 2>/dev/null
assert_eq "below its threshold it stays" "work" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
usage s1 work 91
broker pass 2>/dev/null
assert_eq "at its threshold the broker moves to the next account" "personal" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
assert_eq "every session gets the new account's token" "at-personal-1" "$(jq -r .claudeAiOauth.accessToken "$BROKER_ACCESS/s2/.credentials.json")"
usage s1 personal 75 "$(( $(date +%s) + 86400 ))"
broker pass 2>/dev/null
assert_eq "when every other account is spent too, it stays" "personal" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
assert_has "and the list says why" "(at its weekly threshold (70%))" "$(broker list 2>/dev/null)"
assert_has "...and that no account is under its limit" "no account is under its limit" "$(broker list 2>/dev/null)"
assert_has "the sessions are told" "every Claude account is at a limit" "$(cat "$BROKER_ACCESS/s1/.aidc-notice")"

echo "== the order is a cycle; a usage past its reset time no longer counts"
fresh 9 '{"accounts":[{"name":"a","switch_at":50},{"name":"b","switch_at":50}]}'
broker login a >/dev/null 2>&1; broker login b >/dev/null 2>&1
broker session s1 2>/dev/null
usage s1 a 60 "$(( $(date +%s) - 10 ))"   # a's week was reset already
broker pass 2>/dev/null
assert_eq "usage from before its reset does not move it" "a" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
usage s1 a 60 "$(( $(date +%s) + 3600 ))"
broker pass 2>/dev/null
assert_eq "a -> b" "b" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
jq '.accounts.a.resets_at = 1' "$BROKER_HOME/state.json" > "$W/s" && mv "$W/s" "$BROKER_HOME/state.json"
usage s1 b 80 "$(( $(date +%s) + 3600 ))"
broker pass 2>/dev/null
assert_eq "b -> a again: after the last comes the first" "a" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"

echo "== wait mode: the switch waits for the user"
fresh 10 '{"accounts":[{"name":"work","switch_at":90},{"name":"personal","switch_at":90}],"switch":"wait"}'
broker login work >/dev/null 2>&1; broker login personal >/dev/null 2>&1
broker session s1 2>/dev/null
usage s1 work 95
broker pass 2>/dev/null
assert_eq "the active account stays" "work" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
assert_has "the session's notice names the command" "aidc claude account use personal" "$(cat "$BROKER_ACCESS/s1/.aidc-notice")"
assert_has "the list says it waits" "> waiting: aidc claude account use personal" "$(broker list 2>/dev/null)"
broker use personal 2>/dev/null
assert_eq "use switches at once" "at-personal-1" "$(jq -r .claudeAiOauth.accessToken "$BROKER_ACCESS/s1/.credentials.json")"
assert_eq "and clears the waiting switch" "no" "$([ -e "$BROKER_ACCESS/s1/.aidc-notice" ] && echo yes || echo no)"
out=$(broker use nosuch 2>&1); rc=$?
assert_eq "use refuses an account that has no login" "1" "$rc"

echo "== a session's rate limit moves the broker on (StopFailure rate_limit)"
fresh 11 '{"accounts":[{"name":"work"},{"name":"personal"}]}'
broker login work >/dev/null 2>&1; broker login personal >/dev/null 2>&1
broker session s1 2>/dev/null
broker pass 2>/dev/null
printf '{"at_s":%s}\n' "$(( $(date +%s) - 7200 ))" > "$BROKER_ACCESS/s1/.aidc-limit.json"
broker pass 2>/dev/null
assert_eq "a rate limit from before the last pass does not" "work" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
sleep 1
printf '{"at_s":%s}\n' "$(date +%s)" > "$BROKER_ACCESS/s1/.aidc-limit.json"
broker pass 2>/dev/null
assert_eq "a new one does" "personal" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
ln -s /etc/passwd "$BROKER_ACCESS/s1/.aidc-usage.json"
broker pass 2>/dev/null
assert_eq "a usage file that is a symlink is not read" "personal" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"

echo "== an account whose login ended (expired, renewal failing) is moved away from"
fresh 14 '{"accounts":[{"name":"a"},{"name":"b"}]}'
broker login a >/dev/null 2>&1; broker login b >/dev/null 2>&1
broker session s1 2>/dev/null
assert_eq "(a is active)" "a" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
jq '.claudeAiOauth.expiresAt = 1000' "$BROKER_HOME/accounts/a/.credentials.json" > "$W/c" && mv "$W/c" "$BROKER_HOME/accounts/a/.credentials.json"
C_RENEW_FAIL=1 broker pass 2>"$W/log1"
assert_eq "its sessions move to the next healthy account" "b" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"
assert_eq "list says why, with the command" "its login ended (renewal failing): aidc claude account add a" \
    "$(broker list --json | jq -r '.accounts[] | select(.name == "a") | .why')"
assert_has "the log says the change and the switch" "a: its login ended (renewal failing)" "$(cat "$W/log1")"
C_RENEW_FAIL=1 broker pass 2>"$W/log2"
assert_eq "...once: a pass with no change logs nothing of it" "0" "$(grep -c 'a: its login ended' "$W/log2")"
jq '.claudeAiOauth.expiresAt = 1000' "$BROKER_HOME/accounts/b/.credentials.json" > "$W/c" && mv "$W/c" "$BROKER_HOME/accounts/b/.credentials.json"
C_RENEW_FAIL=1 broker pass 2>/dev/null
assert_has "with no account usable, the sessions are told every account needs adding again" \
    "every Claude account's login has ended: aidc claude account add <name> again for each" "$(cat "$BROKER_ACCESS/s1/.aidc-notice")"
assert_has "...and the list" "NO ACCOUNT CAN BE USED" "$(broker list 2>/dev/null)"
fresh 16 '{"accounts":[{"name":"a"},{"name":"b"}],"switch":"wait"}'
broker login a >/dev/null 2>&1; broker login b >/dev/null 2>&1
broker session s1 2>/dev/null
jq '.claudeAiOauth.expiresAt = 1000' "$BROKER_HOME/accounts/a/.credentials.json" > "$W/c" && mv "$W/c" "$BROKER_HOME/accounts/a/.credentials.json"
C_RENEW_FAIL=1 broker pass 2>/dev/null
assert_eq "in wait mode too: a login that ended does not wait for the user" "b" "$(cat "$BROKER_ACCESS/s1/.aidc-account")"

echo "== passes never run at once"
fresh 15
broker login work >/dev/null 2>&1
( exec 9>>"$BROKER_HOME/.lock"; flock 9; sleep 3 ) &
holder=$!
sleep 1
start=$(date +%s); broker pass 2>/dev/null; took=$(( $(date +%s) - start ))
wait "$holder"
assert_eq "a pass waits for the one holding the lock" "yes" "$([ "$took" -ge 1 ] && echo yes)"

echo "== the git agent reads its credentials through their group; forget removes a session's"
fresh 12
broker login work >/dev/null 2>&1
mkdir -m 0770 "$BROKER_ACCESS/git"
broker session git 2>/dev/null
assert_eq "git's folder keeps the mode its pod gave it" "770" "$(stat -c %a "$BROKER_ACCESS/git")"
assert_eq "git's credentials 0640" "640" "$(stat -c %a "$BROKER_ACCESS/git/.credentials.json")"
mkdir "$BROKER_ACCESS/s9" "$BROKER_ACCESS/s9/.credentials.json"
broker session s9 2>/dev/null
assert_eq "a .credentials.json a session made a folder is never written into" "" "$(ls -A "$BROKER_ACCESS/s9/.credentials.json")"
broker session s1 2>/dev/null
broker forget s1 2>/dev/null
assert_eq "forget removes the folder" "no" "$([ -e "$BROKER_ACCESS/s1" ] && echo yes || echo no)"

echo "== remove logs the account out and moves on"
fresh 13
broker login work >/dev/null 2>&1; broker login personal >/dev/null 2>&1
broker session s1 2>/dev/null
first=$(cat "$BROKER_ACCESS/s1/.aidc-account")
broker remove "$first" >/dev/null 2>&1
assert_has "Claude's logout ran for it" "${first}|auth logout" "$(cat "$C_LOG")"
assert_eq "its folder is gone" "no" "$([ -e "$BROKER_HOME/accounts/$first" ] && echo yes || echo no)"
assert_eq "the session is on the other account" "1" "$(cat "$BROKER_ACCESS/s1/.aidc-account" | grep -cvx "$first")"

echo
echo "claude-broker: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
