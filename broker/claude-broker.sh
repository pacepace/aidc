#!/usr/bin/env bash
# claude-broker: a user's Claude account broker (K8S-16, K8S-17; docs/design-12-kubernetes.md,
# "Claude: logins, account switching, history").
#
# One pod per user, in the user's namespace. It holds each Claude account the user added, in a
# folder of its own on a claim only this pod mounts (BROKER_HOME/accounts/<name>/, Claude Code's
# own config dir for that account, refresh token included). Each session's Claude config dir is
# its own folder of the user's claude-config claim (BROKER_ACCESS/<session>/, mounted whole at
# /home/vscode/.claude by that session's pod alone; this pod mounts the claim whole). Into it the
# broker writes the active account's credentials with the refresh token left out, by rename (a
# real file: Claude Code refuses a .credentials.json that is a symlink), so the session's Claude
# uses them on its next message and never refreshes (sessions never race each other over a
# rotating refresh token).
#
# All token handling is Claude Code's own: an account is added by Claude's normal login run
# here (`login`), and renewed by running Claude Code in the account's folder when its access
# token is near expiry (`renew`), which refreshes as Claude does before any call. This program
# only copies what Claude wrote, without the refresh token.
#
# Switching (K8S-17): each session's statusline wrapper (aidc-claude-usage) leaves its weekly
# usage in its Claude config dir (.aidc-usage.json), and its StopFailure rate_limit hook a
# .aidc-limit.json there. When the active account's weekly usage reaches its threshold
# (switch_at), or a session hit its rate limit, the broker moves to the next account of the
# cycle that is not known to be at its own threshold: at once in `auto` mode, or, in `wait`
# mode, it records the switch as waiting for the user (`claude-broker use <name>`).
#
# Verbs (run in the pod; the user's CLI reaches them with kubectl exec, aidc claude account):
#   serve                 a pass every BROKER_INTERVAL seconds, for ever
#   pass                  one pass: renew what is near expiry, decide the active account,
#                         write every session's credentials
#   login <account>       Claude's own login, for a new account or to log one in again
#   remove <account>      Claude's logout for it, and its folder removed
#   list [--json]         the accounts: order, threshold, state, usage seen, expiry, last renewal
#   use <account>         make it the active account now (and clear a waiting switch)
#   session <name>        ready a session's folder and write its credentials now
#   forget <name>         remove a session's Claude config dir (aidc kill)
#
# Files are written by temp then rename in the same folder; state.json is the broker's own
# record (active, waiting switch, per account: renewal, usage seen, rate limit).
set -uo pipefail

BROKER_HOME="${BROKER_HOME:-/var/lib/claude-broker}"
BROKER_ACCESS="${BROKER_ACCESS:-/var/aidc/claude-config}"
BROKER_CONFIG="${BROKER_CONFIG:-/etc/claude-broker/config.json}"
BROKER_CLAUDE="${BROKER_CLAUDE:-claude}"
BROKER_INTERVAL="${BROKER_INTERVAL:-60}"
# The git agent's Claude (uid 2000, a member of group 1000) reads its credentials through their
# group.
BROKER_GIT_SESSION="${BROKER_GIT_SESSION:-git}"
# Usage reported longer ago than this says nothing about the account now.
BROKER_USAGE_FRESH_S="${BROKER_USAGE_FRESH_S:-1800}"
# A rate limit with no reset time is taken to last this long.
BROKER_LIMIT_S="${BROKER_LIMIT_S:-3600}"

ACCOUNTS="${BROKER_HOME}/accounts"
STATE="${BROKER_HOME}/state.json"

log() { printf '%s claude-broker: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
say() { printf '%s\n' "$*" >&2; }

now_s() { date -u +%s; }

# valid_name <name>: an account or session name: lower-case letters, digits and dashes, as a
# Kubernetes name is (it is a folder name here, so nothing that could leave the folder).
valid_name() {
    printf '%s' "$1" | grep -Eqx '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
}

# write_file <path> <mode> : stdin to <path> by temp then rename in its folder.
write_file() {
    local path="$1" mode="$2" dir tmp
    dir=$(dirname -- "$path")
    tmp=$(mktemp "${dir}/.$(basename -- "$path").XXXXXX") || return 1
    # -T: a name a session made a folder is refused, never written into.
    if cat > "$tmp" && chmod "$mode" "$tmp" && mv -fT -- "$tmp" "$path"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# --- configuration --------------------------------------------------------------------------

# config_json: the user's settings ({accounts: [{name, switch_at}], switch, renew_margin_s});
# {} when there are none.
config_json() {
    if [ -s "$BROKER_CONFIG" ] && jq -e 'type == "object"' "$BROKER_CONFIG" >/dev/null 2>&1; then
        cat "$BROKER_CONFIG"
    else
        printf '{}'
    fi
}

# switch_mode: auto (the default) or wait.
switch_mode() {
    local m
    m=$(config_json | jq -r '.switch // "auto"')
    case "$m" in wait) printf 'wait' ;; *) printf 'auto' ;; esac
}

# renew_margin_s: renew an access token this long before it expires (default an hour).
renew_margin_s() {
    local m
    m=$(config_json | jq -r '.renew_margin_s // 3600')
    case "$m" in ''|*[!0-9]*) m=3600 ;; esac
    printf '%s' "$m"
}

# logged_in_accounts: the accounts with a login, one name a line, in name order.
logged_in_accounts() {
    local d n
    [ -d "$ACCOUNTS" ] || return 0
    for d in "$ACCOUNTS"/*/; do
        [ -d "$d" ] || continue
        n=$(basename -- "$d")
        valid_name "$n" || continue
        [ -s "${d}.credentials.json" ] && printf '%s\n' "$n"
    done | LC_ALL=C sort
}

# cycle: the order accounts are used in, one name a line: the configured order (claude_accounts)
# of the accounts that have a login, then any other logged-in account in name order.
cycle() {
    local have
    have=$(logged_in_accounts)
    [ -n "$have" ] || return 0
    config_json | jq -r --arg have "$have" '
        ($have | split("\n") | map(select(length > 0))) as $h
        | (reduce ((.accounts // [])[] | .name | select(type == "string")) as $x
             ([]; if any(.[]; . == $x) then . else . + [$x] end)) as $order
        | [$order[] | select(. as $x | any($h[]; . == $x))]
          + [$h[] | select(. as $x | any($order[]; . == $x) | not)]
        | .[]'
}

# switch_at <account>: the weekly usage (percent) at which the broker moves away from it.
switch_at() {
    local v
    v=$(config_json | jq -r --arg n "$1" '[(.accounts // [])[] | select(.name == $n) | .switch_at][0] // 90')
    case "$v" in ''|*[!0-9]*) v=90 ;; esac
    printf '%s' "$v"
}

# --- state ----------------------------------------------------------------------------------

state_json() {
    if [ -s "$STATE" ] && jq -e 'type == "object"' "$STATE" >/dev/null 2>&1; then
        cat "$STATE"
    else
        printf '{}'
    fi
}

# state_update <jq filter> [jq args...]: state.json changed by the filter, written whole. Says so
# in the log when it cannot be (a full or read-only claim), and returns 1: what follows a failed
# update must not be logged as done.
state_update() {
    local filter="$1" new
    shift
    if new=$(state_json | jq -c "$@" "$filter") && printf '%s\n' "$new" | write_file "$STATE" 0600; then
        return 0
    fi
    log "could not record the broker's state in ${STATE} (is its claim full or read-only?)"
    STATE_FAILED=1
    return 1
}

# --- credentials ----------------------------------------------------------------------------

account_creds() { printf '%s/%s/.credentials.json' "$ACCOUNTS" "$1"; }

# expires_s <account>: when the account's access token expires, epoch seconds (0 when unknown).
expires_s() {
    local ms
    ms=$(jq -r '.claudeAiOauth.expiresAt // 0' "$(account_creds "$1")" 2>/dev/null) || ms=0
    case "$ms" in ''|*[!0-9]*) ms=0 ;; esac
    printf '%s' $((ms / 1000))
}

# access_only <account>: the account's credentials with the refresh token left out, on stdout.
access_only() {
    jq -c '{claudeAiOauth: (.claudeAiOauth | del(.refreshToken))}
           | select(.claudeAiOauth.accessToken | type == "string" and length > 0)' \
        "$(account_creds "$1")" 2>/dev/null
}

# renew <account>: Claude Code refreshes the account's token when it is within the margin of
# expiring; recorded in state.json either way. Returns 1 when it is still near expiry after.
renew() {
    local name="$1" exp now margin out rc=0
    exp=$(expires_s "$name") now=$(now_s) margin=$(renew_margin_s)
    [ "$exp" -gt $((now + margin)) ] && return 0
    log "renewing ${name} (its access token expires at $(date -u -d "@${exp}" +%H:%M:%SZ 2>/dev/null || echo "${exp}"))"
    # The cheapest call that makes Claude Code refresh: `claude auth status` only reads the
    # stored login (Claude Code 2.1.332), so a one-word prompt to the smallest model, with no
    # tools, MCP servers, slash commands or session kept.
    out=$(CLAUDE_CONFIG_DIR="${ACCOUNTS}/${name}" HOME="${ACCOUNTS}/${name}" \
        timeout 120 "$BROKER_CLAUDE" -p --model haiku --tools "" --strict-mcp-config \
        --disable-slash-commands --no-session-persistence "Reply with the word ok." </dev/null 2>&1) || rc=$?
    exp=$(expires_s "$name") now=$(now_s)
    if [ "$rc" = 0 ] && [ "$exp" -gt $((now + margin)) ]; then
        state_update '.accounts[$n] = ((.accounts[$n] // {}) + {renewed_at: $at} | del(.renew_error))' \
            --arg n "$name" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
        log "renewed ${name}"
        return 0
    fi
    out=$(printf '%s' "$out" | tr -d '\r' | tail -n 3 | tr '\n' ' ' | head -c 300)
    state_update '.accounts[$n] = ((.accounts[$n] // {}) + {renew_error: $e, renew_failed_at: $at})' \
        --arg n "$name" --arg e "${out:-claude exited ${rc}}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "could not renew ${name}: ${out:-claude exited ${rc}}"
    return 1
}

# --- usage and switching --------------------------------------------------------------------

# usage_reports: every session's fresh usage report, one JSON object a line ({session, account,
# seven_day, resets_at, at_s}): what its statusline wrapper wrote, credited to the account the
# report names (the wrapper's, at the source); a report naming none is not counted.
usage_reports() {
    local d f now fresh n
    now=$(now_s) fresh="$BROKER_USAGE_FRESH_S"
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        d="${BROKER_ACCESS}/${n}" f="${BROKER_ACCESS}/${n}/.aidc-usage.json"
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        jq -c --arg s "$n" --argjson now "$now" --argjson fresh "$fresh" '
            select(type == "object" and (.at_s | type) == "number" and ($now - .at_s) <= $fresh
                   and (.seven_day | type) == "number" and (.account | type) == "string" and .account != "")
            | {session: $s, account, seven_day, resets_at: (.resets_at // null), at_s}' \
            "$f" 2>/dev/null
    done < <(sessions)
}

# rate_limited_since <epoch-s>: the sessions whose Claude hit its rate limit since then, one
# {session, account, at_s} a line (their StopFailure rate_limit hook's .aidc-limit.json, naming
# the account it was on).
rate_limited_since() {
    local since="$1" f n
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        f="${BROKER_ACCESS}/${n}/.aidc-limit.json"
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        jq -c --arg s "$n" --argjson since "$since" '
            select((.at_s | type) == "number" and .at_s > $since and (.account | type) == "string"
                   and .account != "") | {session: $s, account, at_s}' "$f" 2>/dev/null
    done < <(sessions)
}


# record_usage: what the sessions reported, into state.json per account (the newest report), and
# rate limits, which mark the account the session was on as at its limit.
record_usage() {
    local reports last limits line s acct t
    reports=$(usage_reports)
    if [ -n "$reports" ]; then
        state_update '
            reduce ($r | split("\n")[] | select(length > 0) | fromjson | select(.account != "")) as $x
              (.; if ((.accounts[$x.account].usage_at_s // 0) <= $x.at_s)
                  then .accounts[$x.account] = ((.accounts[$x.account] // {})
                       + {usage: $x.seven_day, usage_at_s: $x.at_s, resets_at: $x.resets_at})
                  else . end)' --arg r "$reports"
    fi
    last=$(state_json | jq -r '.limits_read_s // 0')
    limits=$(rate_limited_since "$last")
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        s=$(printf '%s' "$line" | jq -r .session) t=$(printf '%s' "$line" | jq -r .at_s)
        acct=$(printf '%s' "$line" | jq -r .account)
        log "session ${s} hit the rate limit of ${acct}"
        state_update '.accounts[$a] = ((.accounts[$a] // {}) + {limited_until_s: ($t + $d)})' \
            --arg a "$acct" --argjson t "$t" --argjson d "$BROKER_LIMIT_S"
    done <<<"$limits"
    state_update '.limits_read_s = $n' --argjson n "$(now_s)"
}

# spent_reason <account>: why the account cannot be used now, as far as the broker knows:
# login_ended (its access token expired and renewing it fails), rate_limited (a session hit its
# rate limit within the hour), threshold (its weekly usage is at its switch_at and its week has
# not reset); "" when it can be used (or nothing is known).
spent_reason() {
    local name="$1" at now
    at=$(switch_at "$name") now=$(now_s)
    if [ "$(expires_s "$name")" -le "$now" ] \
        && [ -n "$(state_json | jq -r --arg n "$name" '.accounts[$n].renew_error // ""')" ]; then
        printf 'login_ended'
        return 0
    fi
    state_json | jq -r --arg n "$name" --argjson at "$at" --argjson now "$now" '
        (.accounts[$n] // {}) as $a
        # resets_at as Claude Code gives it (epoch seconds), or an ISO time
        | ($a.resets_at | if type == "number" then .
                          elif type == "string" then (sub("\\.[0-9]+"; "") | fromdateiso8601? // 0)
                          else null end) as $reset
        | if ($a.limited_until_s // 0) > $now then "rate_limited"
          elif ($a.usage // -1) >= $at and ($reset == null or $reset > $now) then "threshold"
          else "" end' 2>/dev/null
}

# spent <account>: 0 when it cannot be used now (spent_reason), 1 when it can.
spent() { [ -n "$(spent_reason "$1")" ]; }

# reason_text <account> <reason>: the reason in words, for the list, the log and the notices.
reason_text() {
    case "$2" in
        login_ended) printf 'its login ended (renewal failing): aidc claude account add %s' "$1" ;;
        rate_limited) printf 'at its rate limit' ;;
        threshold) printf 'at its weekly threshold (%s%%)' "$(switch_at "$1")" ;;
    esac
}

# log_states: one log line per account whose state changed since the last one logged (usable,
# or why not), so the log says each change once.
log_states() {
    local n reason was
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        reason=$(spent_reason "$n")
        was=$(state_json | jq -r --arg n "$n" '.accounts[$n].state_logged // "none"')
        [ "${reason:-usable}" != "$was" ] || continue
        state_update '.accounts[$n] = ((.accounts[$n] // {}) + {state_logged: $r})' --arg n "$n" --arg r "${reason:-usable}" || continue
        if [ -n "$reason" ]; then log "${n}: $(reason_text "$n" "$reason")"; else log "${n}: usable"; fi
    done < <(cycle)
}

# next_account <after>: the first account after <after> in the cycle that is not spent; "" when
# every other one is.
next_account() {
    local after="$1" list n i count start
    mapfile -t list < <(cycle)
    count=${#list[@]}
    [ "$count" -gt 0 ] || return 0
    start=0
    for i in "${!list[@]}"; do [ "${list[$i]}" = "$after" ] && start=$((i + 1)); done
    for ((i = 0; i < count; i++)); do
        n=${list[$(((start + i) % count))]}
        [ "$n" = "$after" ] && continue
        spent "$n" || { printf '%s' "$n"; return 0; }
    done
}

# decide: the active account after this pass, into state.json (active; waiting in wait mode;
# none_usable when no account can be used: logins_ended when none has a login that works,
# limits when every one is at a limit).
decide() {
    local active next first reason n ended=1
    active=$(state_json | jq -r '.active // ""')
    first=$(cycle | head -n1)
    if [ -z "$active" ] || [ ! -s "$(account_creds "$active")" ]; then
        [ -n "$first" ] || { state_update 'del(.active, .waiting, .none_usable)'; return 0; }
        state_update '.active = $a | del(.waiting)' --arg a "$first" || return 1
        log "active account: ${first}"
        active="$first"
    fi
    reason=$(spent_reason "$active")
    [ -n "$reason" ] || { state_update 'del(.waiting, .none_usable)'; return 0; }
    next=$(next_account "$active")
    if [ -z "$next" ]; then
        while IFS= read -r n; do
            [ -n "$n" ] && [ "$(spent_reason "$n")" != login_ended ] && ended=0
        done < <(cycle)
        local what=limits
        [ "$ended" = 1 ] && what=logins_ended
        local was
        was=$(state_json | jq -r '.none_usable // ""')
        state_update '.none_usable = $w | del(.waiting)' --arg w "$what" || return 1
        [ "$was" = "$what" ] \
            || log "no account can be used ($( [ "$what" = logins_ended ] && echo "every login ended: aidc claude account add <name> again for each" || echo "every one at a limit" )): staying on ${active}"
        return 0
    fi
    # An account whose login ended serves nothing: the switch does not wait for the user.
    if [ "$(switch_mode)" = wait ] && [ "$reason" != login_ended ]; then
        local waited
        waited=$(state_json | jq -r '.waiting // ""')
        state_update '.waiting = $n | del(.none_usable)' --arg n "$next" || return 1
        [ "$waited" = "$next" ] \
            || log "${active} is $(reason_text "$active" "$reason"): switch to ${next} waiting for you (claude-broker use ${next})"
        return 0
    fi
    state_update '.active = $n | .switched_at = $at | .switched_from = $f | del(.waiting, .none_usable)' \
        --arg n "$next" --arg f "$active" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
    log "switched from ${active} ($(reason_text "$active" "$reason")) to ${next}"
}

# --- sessions -------------------------------------------------------------------------------

# session_folder <name>: the session's Claude config dir, made when missing (0700, the broker's
# uid being the session user's). The pod's own init step gives an existing one its owner and mode
# (the git agent's: uid 2000, group 1000), which this leaves as they are.
session_folder() {
    local dir="${BROKER_ACCESS}/$1"
    [ ! -L "$dir" ] || rm -f -- "$dir"
    if [ ! -d "$dir" ]; then
        mkdir -m 0700 -- "$dir" || return 1
    fi
    printf '%s' "$dir"
}

# write_session <name>: the active account's access-only credentials, its name and any notice,
# into the session's folder, each only when it changed (a rename Claude sees as a new file).
write_session() {
    local name="$1" dir active creds mode notice waiting
    dir=$(session_folder "$name") || { log "cannot ready ${name}'s folder"; return 1; }
    mode=0600
    [ "$name" = "$BROKER_GIT_SESSION" ] && mode=0640
    active=$(state_json | jq -r '.active // ""')
    if [ -z "$active" ]; then
        # Credentials the broker wrote go with its accounts; a session's own login stays.
        if [ -f "${dir}/.aidc-account" ]; then rm -f -- "${dir}/.credentials.json" "${dir}/.aidc-account"; fi
        printf 'no Claude account added: aidc claude account add <name>\n' | _write_if_changed "${dir}/.aidc-notice" "$mode"
        return 0
    fi
    creds=$(access_only "$active") || creds=""
    if [ -n "$creds" ]; then
        printf '%s\n' "$creds" | _write_if_changed "${dir}/.credentials.json" "$mode"  || return 1
    fi
    printf '%s\n' "$active" | _write_if_changed "${dir}/.aidc-account" "$mode" || return 1
    waiting=$(state_json | jq -r '.waiting // ""')
    notice=""
    case "$(state_json | jq -r '.none_usable // ""')" in
        logins_ended) notice="every Claude account's login has ended: aidc claude account add <name> again for each (aidc claude account list)" ;;
        limits) notice="every Claude account is at a limit: staying on ${active} (aidc claude account list)" ;;
    esac
    if [ -n "$notice" ]; then
        :
    elif [ -n "$waiting" ]; then
        notice="${active} at its threshold: aidc claude account use ${waiting}"
    elif [ -n "$(state_json | jq -r --arg a "$active" '.accounts[$a].renew_error // ""')" ]; then
        notice="${active}: renewal failing, see aidc claude account list"
    fi
    if [ -n "$notice" ]; then
        printf '%s\n' "$notice" | _write_if_changed "${dir}/.aidc-notice" "$mode"
    else
        rm -f -- "${dir}/.aidc-notice"
    fi
}

# _write_if_changed <path> <mode>: stdin to <path> by rename unless it holds that already.
_write_if_changed() {
    local path="$1" mode="$2" new
    new=$(cat)
    if [ -f "$path" ] && [ ! -L "$path" ] && [ "$(cat -- "$path" 2>/dev/null)" = "$new" ]; then
        return 0
    fi
    printf '%s\n' "$new" | write_file "$path" "$mode"
}

# sessions: every session folder there is, one name a line.
sessions() {
    local d n
    [ -d "$BROKER_ACCESS" ] || return 0
    for d in "$BROKER_ACCESS"/*/; do
        [ -d "$d" ] || continue
        n=$(basename -- "$d")
        valid_name "$n" && printf '%s\n' "$n"
    done
}

# --- verbs ----------------------------------------------------------------------------------

# locked <function> [args...]: run it holding the broker's lock, so a pass, a login's pass, a
# use or a remove never run at once (two Claude Code processes refreshing one rotating refresh
# token, or one state update losing another's).
locked() {
    ( flock -w 900 9 || { log "the broker's lock stayed held: ${1} not run"; exit 1; }; "$@" ) 9>>"${BROKER_HOME}/.lock"
}

# do_pass: returns 1 when any state update or session write failed (serve says the pass failed).
do_pass() {
    local n bad=0
    STATE_FAILED=0
    while IFS= read -r n; do
        [ -n "$n" ] && renew "$n"
    done < <(logged_in_accounts)
    record_usage
    log_states
    decide || bad=1
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        write_session "$n" || { log "could not write ${n}'s credentials"; bad=1; }
    done < <(sessions)
    [ "$bad" = 0 ] && [ "$STATE_FAILED" = 0 ]
}

do_serve() {
    mkdir -p -- "$ACCOUNTS" "$BROKER_ACCESS" || { log "cannot make ${ACCOUNTS}"; exit 1; }
    chmod 0700 "$BROKER_HOME" "$ACCOUNTS" 2>/dev/null || true
    log "serving (accounts: $(logged_in_accounts | paste -sd' ' -))"
    while :; do
        locked do_pass || log "a pass failed; trying again in ${BROKER_INTERVAL}s"
        sleep "$BROKER_INTERVAL"
    done
}

do_login() {
    local name="${1:-}" dir
    valid_name "$name" || { say "an account name is lower-case letters, digits and dashes (for example: work)"; return 2; }
    dir="${ACCOUNTS}/${name}"
    mkdir -p -- "$dir" && chmod 0700 "$dir" || { say "cannot make ${dir}"; return 1; }
    say "Logging in account ${name} with Claude's own login. Open the link it prints in your"
    say "browser, sign in to the Claude account you want as ${name}, and paste the code back here."
    CLAUDE_CONFIG_DIR="$dir" HOME="$dir" "$BROKER_CLAUDE" auth login --claudeai || {
        say "the login did not finish; nothing was changed for ${name}"; return 1; }
    if ! jq -e '.claudeAiOauth.refreshToken | type == "string" and length > 0' "${dir}/.credentials.json" >/dev/null 2>&1; then
        say "Claude logged in but left no renewable login in ${dir} (a token without a refresh token cannot be renewed here)"
        return 1
    fi
    locked state_update '.accounts[$n] = ((.accounts[$n] // {}) | del(.renew_error, .renew_failed_at))' --arg n "$name"
    say "account ${name} added"
    locked do_pass
}

do_remove() {
    local name="${1:-}"
    valid_name "$name" || { say "no such account: ${name}"; return 2; }
    [ -d "${ACCOUNTS}/${name}" ] || { say "no such account: ${name}"; return 1; }
    CLAUDE_CONFIG_DIR="${ACCOUNTS}/${name}" HOME="${ACCOUNTS}/${name}" timeout 60 "$BROKER_CLAUDE" auth logout </dev/null >/dev/null 2>&1 \
        || say "Claude's logout for ${name} did not finish (its login is removed here anyway)"
    rm -rf -- "${ACCOUNTS:?}/${name}"
    state_update 'del(.accounts[$n]) | if .active == $n then del(.active) else . end
                  | if .waiting == $n then del(.waiting) else . end' --arg n "$name"
    say "account ${name} removed"
    do_pass
}

do_use() {
    local name="${1:-}"
    valid_name "$name" && [ -s "$(account_creds "$name")" ] || { say "no such account: ${name:-}"; return 1; }
    state_update '.active = $n | .switched_at = $at | del(.waiting)' --arg n "$name" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || { say "could not record ${name} as the active account"; return 1; }
    say "active account: ${name}"
    while IFS= read -r n; do [ -n "$n" ] && write_session "$n"; done < <(sessions)
}

do_session() {
    local name="${1:-}"
    valid_name "$name" || { say "not a session name: ${name}"; return 2; }
    [ -n "$(state_json | jq -r '.active // ""')" ] || decide
    write_session "$name"
}

do_forget() {
    local name="${1:-}"
    valid_name "$name" || { say "not a session name: ${name}"; return 2; }
    rm -rf -- "${BROKER_ACCESS:?}/${name}"
}

# do_list [--json]: one row per account in the cycle's order.
do_list() {
    local json n rows="" st active waiting exp reason
    st=$(state_json)
    active=$(printf '%s' "$st" | jq -r '.active // ""')
    waiting=$(printf '%s' "$st" | jq -r '.waiting // ""')
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        exp=$(expires_s "$n")
        reason=$(spent_reason "$n")
        rows="${rows}$(printf '%s' "$st" | jq -c --arg n "$n" --arg active "$active" --arg waiting "$waiting" \
            --argjson at "$(switch_at "$n")" --argjson exp "$exp" --argjson spent "$([ -n "$reason" ] && echo true || echo false)" \
            --arg reason "$reason" --arg why "$(reason_text "$n" "$reason")" '
            (.accounts[$n] // {}) as $a
            | {name: $n, active: ($n == $active), next: ($n == $waiting), switch_at: $at,
               expires_at: (if $exp > 0 then ($exp | todateiso8601) else null end),
               usage: ($a.usage // null), resets_at: ($a.resets_at // null), spent: $spent,
               spent_reason: (if $reason == "" then null else $reason end),
               why: (if $why == "" then null else $why end),
               renewed_at: ($a.renewed_at // null), renew_error: ($a.renew_error // null)}')
"
    done < <(cycle)
    json=$(printf '%s' "$rows" | jq -s -c --arg mode "$(switch_mode)" --arg none "$(printf '%s' "$st" | jq -r '.none_usable // ""')" \
        '{switch: $mode, none_usable: (if $none == "" then null else $none end), accounts: .}')
    if [ "${1:-}" = --json ]; then
        printf '%s\n' "$json"
        return 0
    fi
    printf '%s' "$json" | jq -r '
        "switch: \(.switch)",
        (if (.accounts | length) == 0 then "no accounts: aidc claude account add <name>" else
          (.accounts[] | "\(if .active then "*" elif .next then ">" else " " end) \(.name)  switch at \(.switch_at)%  usage \(if .usage == null then "?" else "\(.usage)%" end)\(if .spent then " (\(.why))" else "" end)  expires \(.expires_at // "?")\(if .renew_error then "  RENEWAL FAILING: \(.renew_error)" else "" end)")
         end),
        (if .none_usable == "logins_ended" then "NO ACCOUNT CAN BE USED: every login ended; aidc claude account add <name> again for each"
         elif .none_usable == "limits" then "no account is under its limit: staying on the active one" else empty end),
        (if any(.accounts[]; .next) then "> waiting: aidc claude account use \([.accounts[] | select(.next) | .name][0])" else empty end)'
}

main() {
    local verb="${1:-}"
    shift || true
    case "$verb" in
        serve) do_serve ;;
        pass) locked do_pass ;;
        login) do_login "$@" ;;
        remove) locked do_remove "$@" ;;
        list) do_list "$@" ;;
        use) locked do_use "$@" ;;
        session) locked do_session "$@" ;;
        forget) locked do_forget "$@" ;;
        *) say "usage: claude-broker serve|pass|login <account>|remove <account>|list [--json]|use <account>|session <name>|forget <name>"; return 2 ;;
    esac
}

# Sourced by tests/unit/test-claude-broker.sh, which runs the functions that ship.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
