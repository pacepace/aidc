#!/usr/bin/env bash
# aidc-claude-usage: what a cluster session's Claude tells the user's Claude account broker
# (K8S-17; docs/design-12-kubernetes.md, "Switching accounts mid-work").
#
#   aidc-claude-usage statusline     Claude Code's statusLine command (managed settings, in a
#                                    cluster session): reads the status JSON on stdin, leaves the
#                                    weekly usage in the Claude config dir (.aidc-usage.json:
#                                    {seven_day, resets_at, at_s}), and prints the user's own
#                                    status line (their settings.json statusLine, run with the
#                                    same input) or a short one, and the broker's notice if any.
#                                    It also leaves the account and the notice in the session's
#                                    transcript mirror folder (claude-account.json: {account,
#                                    notice, at}), where the user's MCP server reads them for
#                                    session_status.
#   aidc-claude-usage rate-limited   Claude Code's StopFailure hook, matcher rate_limit: leaves
#                                    .aidc-limit.json ({at_s}) there.
#
# The broker reads both from the session's folder of claude-config, which is this Claude config
# dir. Only where a broker manages the session (it wrote .aidc-account) is anything written. It
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

do_statusline() {
    local input usage cmd line notice
    input=$(cat 2>/dev/null) || input=""
    if managed; then
        usage=$(printf '%s' "$input" | jq -c --argjson t "$(date -u +%s)" '
            .rate_limits.seven_day as $w
            | select(($w.used_percentage | type) == "number")
            | {seven_day: $w.used_percentage, resets_at: ($w.resets_at // null), at_s: $t}' 2>/dev/null) || usage=""
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
    cat >/dev/null 2>&1 || true
    managed || return 0
    write_json .aidc-limit.json "{\"at_s\": $(date -u +%s)}"
}

case "${1:-}" in
    statusline) do_statusline ;;
    rate-limited) do_rate_limited ;;
esac
exit 0
