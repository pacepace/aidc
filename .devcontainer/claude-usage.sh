#!/usr/bin/env bash
# aidc-claude-usage: what a cluster session's Claude tells the user's Claude account broker
# (K8S-17; docs/design-12-kubernetes.md, "Switching accounts mid-work").
#
#   aidc-claude-usage statusline     Claude Code's statusLine command (managed settings, in a
#                                    cluster session): reads the status JSON on stdin, leaves the
#                                    weekly usage in the Claude config dir (.aidc-usage.json:
#                                    {account, seven_day, resets_at, at_s}), and prints the user's own
#                                    status line (their settings.json statusLine, run with the
#                                    same input) or a short one, and the broker's notice if any.
#                                    It also leaves the account and the notice in the session's
#                                    transcript mirror folder (claude-account.json: {account,
#                                    notice, at}), where the user's MCP server reads them for
#                                    session_status.
#   aidc-claude-usage rate-limited   Claude Code's StopFailure hook, matcher rate_limit: leaves
#                                    .aidc-limit.json ({account, at_s, kind}) there; kind is
#                                    weekly when Claude's words say the weekly limit was
#                                    reached, else rate.
#
# The broker reads both from the session's Claude config dir, its folder of the user's
# claude-config (a claim in a cluster, a volume on Docker). Only where a broker manages the session (it wrote .aidc-account) is anything written. It
# never fails and never holds Claude up: every path exits 0.
set -u

dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
# Where a status line synced from a laptop lives: the user's shared Claude folder in a cluster
# session (AIDC_SHARED_CLAUDE, on the user's disk), else the Claude config dir.
shared="${AIDC_SHARED_CLAUDE:-$dir}"
mirror="${AIDC_TRANSCRIPT_OUT:-/var/aidc/transcript-out}"

# write_json <name> <json>: into the Claude config dir by temp then rename.
write_json() {
    local tmp
    tmp=$(mktemp "${dir}/.${1}.XXXXXX" 2>/dev/null) || return 0
    if printf '%s\n' "$2" > "$tmp" 2>/dev/null; then
        mv -fT -- "$tmp" "${dir}/${1}" 2>/dev/null || rm -f -- "$tmp"
    else
        rm -f -- "$tmp"
    fi
}

managed() { [ -f "${dir}/.aidc-account" ] && [ ! -L "${dir}/.aidc-account" ]; }

# account_now: the account the broker last gave this session ("" when none).
account_now() { managed && head -n1 -- "${dir}/.aidc-account" 2>/dev/null; }

# user_statusline: the user's own statusLine command from the session's settings.json, its
# ~/.claude/ or /Users/<name>/.claude/ path (a status line from a laptop) made the shared
# Claude folder's; "" when there is none or it is this one.
user_statusline() {
    local cmd
    cmd=$(jq -r '.statusLine.command // empty | select(type == "string")' "${dir}/settings.json" 2>/dev/null) || return 0
    case "$cmd" in ""|*aidc-claude-usage*) return 0 ;; esac
    # shellcheck disable=SC2016  # the literal $HOME a settings file may hold
    cmd=$(printf '%s' "$cmd" | sed -e "s#~/\\.claude/#${shared}/#g" -e "s#\\\$HOME/\\.claude/#${shared}/#g" \
        -e "s#\\\${HOME}/\\.claude/#${shared}/#g" -e "s#/Users/[^/ ]*/\\.claude/#${shared}/#g")
    printf '%s' "$cmd"
}

# last_call_s <status-json>: when Claude's last API call answered (its transcript's newest
# assistant entry, a failed call's error included), epoch seconds; "" when that cannot be read.
last_call_s() {
    local tp
    tp=$(printf '%s' "$1" | jq -r '.transcript_path // empty | select(type == "string")' 2>/dev/null) || return 0
    [ -n "$tp" ] && [ -f "$tp" ] || return 0
    tail -n 50 -- "$tp" 2>/dev/null | jq -R -r -s '
        [split("\n")[] | fromjson? | select(type == "object" and .type == "assistant" and (.timestamp | type) == "string")
         | .timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601?] | last // empty' 2>/dev/null
}

do_statusline() {
    local input input_usage usage cmd line notice called switched prev stale=""
    input=$(cat 2>/dev/null) || input=""
    if managed; then
        # The report names the account it measured, and is credited only to the account whose
        # credentials produced it. Claude shows the usage of its last API call: right after the
        # broker switches accounts the status still carries the old account's numbers. So those
        # numbers are another account's (stale) when that call answered no later than the broker
        # named this account (.aidc-account's time; a session whose very first call hit a limit
        # and was switched has no earlier report to compare with), or, when the transcript
        # cannot tell, when they are the previous report's under a new account name; the new
        # account's first call brings its own (each account's week resets at its own time).
        # Stale numbers are neither reported nor shown: the status line would put the old
        # account's week under the new account's name.
        called=$(last_call_s "$input")
        switched=$(stat -c %Y -- "${dir}/.aidc-account" 2>/dev/null || stat -f %m -- "${dir}/.aidc-account" 2>/dev/null || true)
        case "$called" in ''|*[!0-9]*) called="" ;; esac
        case "$switched" in ''|*[!0-9]*) switched="" ;; esac
        if [ -n "$called" ] && [ -n "$switched" ] && [ "$called" -le "$switched" ]; then
            stale=1
        elif [ -z "$called" ]; then
            prev=$(cat "${dir}/.aidc-usage.json" 2>/dev/null) || prev=""
            printf '%s' "$input" | jq -e --arg a "$(account_now)" --argjson p "${prev:-null}" '
                .rate_limits.seven_day as $w
                | ($w.used_percentage | type) == "number" and ($p | type) == "object"
                  and ($p.account // $a) != $a and $p.seven_day == $w.used_percentage
                  and $p.resets_at == ($w.resets_at // null)' >/dev/null 2>&1 && stale=1
        fi
        if [ -n "$stale" ]; then
            input_usage=""
            input=$(printf '%s' "$input" | jq -c 'del(.rate_limits)' 2>/dev/null) || input=""
        else
            input_usage="$input"
        fi
        usage=$(printf '%s' "$input_usage" | jq -c --argjson t "$(date -u +%s)" --arg a "$(account_now)" '
            .rate_limits.seven_day as $w
            | select(($w.used_percentage | type) == "number" and $a != "")
            | {account: $a, seven_day: $w.used_percentage, resets_at: ($w.resets_at // null), at_s: $t}' 2>/dev/null) || usage=""
        [ -z "$usage" ] || write_json .aidc-usage.json "$usage"
    fi
    cmd=$(user_statusline)
    if [ -n "$cmd" ]; then
        line=$(printf '%s' "$input" | timeout 5 sh -c "$cmd" 2>/dev/null) || line=""
    else
        line=$(printf '%s' "$input" | jq -r '
            [(.model.display_name // empty),
             (.rate_limits.seven_day.used_percentage // empty | "week \(floor)%")] | join("  ")' 2>/dev/null) || line=""
    fi
    if managed; then
        line="${line}${line:+  }[$(head -n1 "${dir}/.aidc-account" 2>/dev/null)]"
    fi
    [ -z "$line" ] || printf '%s\n' "$line"
    notice=""
    if [ -f "${dir}/.aidc-notice" ] && [ ! -L "${dir}/.aidc-notice" ]; then
        notice=$(head -n1 "${dir}/.aidc-notice" 2>/dev/null) || notice=""
        [ -z "$notice" ] || printf 'aidc: %s\n' "$notice"
    fi
    # For the user's MCP server (session_status's claude_account): the same, in the mirror.
    if managed && [ -d "$mirror" ]; then
        local doc tmp
        doc=$(jq -n -c --arg a "$(head -n1 "${dir}/.aidc-account" 2>/dev/null)" --arg n "$notice" \
            --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{account: $a, notice: (if $n == "" then null else $n end), at: $at}' 2>/dev/null) || doc=""
        if [ -n "$doc" ] && tmp=$(mktemp "${mirror}/.claude-account.XXXXXX" 2>/dev/null); then
            if printf '%s\n' "$doc" > "$tmp" 2>/dev/null; then
                mv -fT -- "$tmp" "${mirror}/claude-account.json" 2>/dev/null || rm -f -- "$tmp"
            else
                rm -f -- "$tmp"
            fi
        fi
    fi
}

do_rate_limited() {
    local input kind=rate
    input=$(cat 2>/dev/null) || input=""
    managed || return 0
    # Claude's words for the limit it hit: the hook's error and message fields only (wherever
    # in its JSON they are), never its paths or ids (a repo folder named "weekly-report" says
    # nothing about the limit).
    printf '%s' "$input" | jq -r '[paths(strings) as $p
            | select(($p | last | tostring) | test("error|message|reason|detail"; "i"))
            | getpath($p)] | join(" ")' 2>/dev/null \
        | grep -Eqi 'weekly|seven[ _-]?day|7[ -]day' && kind=weekly
    write_json .aidc-limit.json "$(jq -n -c --arg a "$(account_now)" --argjson t "$(date -u +%s)" --arg k "$kind" \
        '{account: $a, at_s: $t, kind: $k}')"
}

case "${1:-}" in
    statusline) do_statusline ;;
    rate-limited) do_rate_limited ;;
esac
exit 0
