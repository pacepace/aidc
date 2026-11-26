#!/usr/bin/env bash
# aidc-hook-event: Claude Code's SessionStart, Stop, Notification and UserPromptSubmit hooks
# (MCP-46).
#
# Claude Code runs this with the hook's input as JSON on stdin. It writes that input, with
# `event` (the hook's name) and `at` (UTC, milliseconds) added, as one file under the
# session's MCP-readable state dir, where aidc-mcp reads it (the hook never reaches the MCP
# itself). That dir is the session's own folder of the transcript mirror, which a Docker session
# mounts from the MCP's state dir and a Kubernetes pod from the user's mirror claim:
#
#   /var/aidc/transcript-out/hook-events/<epoch-ns>-<pid>.json
#
# The name sorts in the order events happened. The file is written to a temp name in the
# same dir and renamed, so a reader sees the whole event or none of it.
#
# It never fails or holds up Claude: every path exits 0 and nothing is printed (a Stop
# hook's output could be read as a decision to keep the turn going). A missing state dir
# (a session created without the mirror), a Claude outside window main:claude, or input
# that is not JSON writes nothing.

set -u
exec 2>/dev/null   # nothing it does is said to Claude: a failed write is no event, not an error

# The events are the session's Claude's: the one in tmux window main:claude, the window
# aidc-mcp reads and types into. The managed settings reach every claude in the container,
# so a headless `claude --print` (session_invoke, run by docker exec, no tmux pane) or a
# claude someone starts in another window writes nothing; its Stop is not the session's.
[ -n "${TMUX_PANE:-}" ] || exit 0
window=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_name}' 2>/dev/null) \
    || exit 0
[ "$window" = "main:claude" ] || exit 0

dir="${AIDC_HOOK_EVENTS_DIR:-/var/aidc/transcript-out/hook-events}"
[ -d "$(dirname -- "$dir")" ] || exit 0
mkdir -p -- "$dir" 2>/dev/null || exit 0

payload=$(cat 2>/dev/null) || exit 0
at=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null) || exit 0
event=$(printf '%s' "$payload" | jq -c --arg at "$at" \
    'select(type == "object") | {event: (.hook_event_name // ""), at: $at} + .' 2>/dev/null) \
    || exit 0
[ -n "$event" ] || exit 0

name="$(date -u +%s%N)-$$"
tmp="${dir}/.${name}.tmp"
if printf '%s\n' "$event" > "$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "${dir}/${name}.json" 2>/dev/null
fi
rm -f -- "$tmp" 2>/dev/null
# The transcripts this Claude writes, by file name, a line each (own-transcripts beside the
# events): where a session's Claude history folder is shared with other sessions (a cluster
# session's, the user's disk's), the mirror copies only these, so the MCP and the audit trail
# see only this session's conversations.
own="$(dirname -- "$dir")/own-transcripts"
tname=$(printf '%s' "$event" | jq -r '.transcript_path // "" | split("/") | last' 2>/dev/null) || tname=""
if printf '%s' "$tname" | grep -Eqx '[A-Za-z0-9-]{1,100}\.jsonl' && ! grep -qxF -- "$tname" "$own" 2>/dev/null; then
    printf '%s\n' "$tname" >> "$own" 2>/dev/null
fi

# The dir stays small: only the newest AIDC_HOOK_EVENTS_KEPT (200) events are kept. The writer
# is the dir's one owner on both backends; the MCP only reads it (in the cluster its mount of
# the mirror is read-only). The MCP reads on from the last event it read and needs only the
# newest; after a long MCP outage the older ones it missed matter no more than the transcript,
# which it catches up from. Names sort in the order the events happened (fixed-width epoch ns).
keep="${AIDC_HOOK_EVENTS_KEPT:-200}"
case "$keep" in ''|*[!0-9]*) keep=200 ;; esac
LC_COLLATE=C
set -- "$dir"/*.json
if [ -e "${1:-}" ] && [ "$#" -gt "$keep" ]; then
    drop=$(( $# - keep ))
    for f in "$@"; do
        [ "$drop" -gt 0 ] || break
        rm -f -- "$f" 2>/dev/null
        drop=$(( drop - 1 ))
    done
fi
exit 0
