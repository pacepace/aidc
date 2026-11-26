#!/usr/bin/env bash
# aidc-claude-lease: one machine at a time appends to a Claude conversation that Syncthing
# carries between the cluster and the user's machines (K8S-18; docs/design-12-kubernetes.md,
# "One history per repo, on every machine").
#
# A conversation's lease is a file beside its transcript, synced with it:
#   <project dir>/<session id>.aidc-lease   {"machine": "...", "until_s": <epoch>}
# held while the machine's Claude works on it, renewed at each prompt and turn end, and let go
# when Claude exits. A lease past its time is free (a machine that went away does not hold a
# conversation for ever).
#
#   aidc-claude-lease hook [--then <command>]
#                                   Claude Code's SessionStart, UserPromptSubmit, Stop and
#                                   SessionEnd hook (the hook's input on stdin). A prompt to a
#                                   conversation another machine holds is blocked (exit 2, the
#                                   reason shown to the user); otherwise the lease is taken or
#                                   renewed. With --then, a prompt that goes through is handed
#                                   on to <command> with the same input (a cluster session's
#                                   aidc-hook-event): a refused prompt is recorded nowhere, since
#                                   no turn follows it, and aidc-mcp must not wait for one.
#                                   SessionStart also removes symlinks inside the project's
#                                   folder: a synced symlink would point at whatever that path
#                                   is on this machine (#35).
#   aidc-claude-lease free-id <project-dir> <session-id>
#                                   exit 0 when that conversation is free for this machine
#                                   (aidc-claude asks before it resumes one), 1 when another
#                                   machine holds it, printing which.
#
# The machine's name is AIDC_LEASE_MACHINE (a cluster session: cluster/<session>), else the host
# name. Never fails Claude: anything unreadable is free, and every path but a refusal exits 0.
set -u

TTL="${AIDC_LEASE_TTL_S:-900}"
case "$TTL" in ''|*[!0-9]*) TTL=900 ;; esac

machine() { printf '%s' "${AIDC_LEASE_MACHINE:-$(hostname 2>/dev/null || echo unknown)}"; }
now_s() { date -u +%s; }

# holder <lease-file>: the machine holding it now, "" when it is free (absent, past its time,
# unreadable).
holder() {
    local f="$1"
    [ -f "$f" ] && [ ! -L "$f" ] || return 0
    jq -r --argjson now "$(now_s)" 'select((.until_s | type) == "number" and .until_s > $now
                                           and (.machine | type) == "string") | .machine' "$f" 2>/dev/null
}

# take <lease-file>: the lease for this machine for TTL seconds, by temp then rename.
take() {
    local f="$1" tmp
    tmp=$(mktemp "$(dirname -- "$f")/.aidc-lease.XXXXXX" 2>/dev/null) || return 0
    if jq -n -c --arg m "$(machine)" --argjson u "$(( $(now_s) + TTL ))" '{machine: $m, until_s: $u}' > "$tmp" 2>/dev/null; then
        mv -f -- "$tmp" "$f" 2>/dev/null || rm -f -- "$tmp"
    else
        rm -f -- "$tmp"
    fi
}

# Where aidc-mcp reads a cluster session's state (its transcript mirror folder); a machine's
# own Claude has none.
MIRROR="${AIDC_TRANSCRIPT_OUT:-/var/aidc/transcript-out}"

# held_note <holder> <lease-file>: for aidc-mcp, that a prompt was refused because <holder>
# holds the conversation, until when (held-elsewhere.json in the mirror folder): it keeps a
# prompt it pasted queued, and pastes none until then.
held_note() {
    local until tmp
    [ -d "$MIRROR" ] || return 0
    until=$(jq -r '.until_s // 0' "$2" 2>/dev/null) || until=0
    tmp=$(mktemp "${MIRROR}/.held-elsewhere.XXXXXX" 2>/dev/null) || return 0
    if jq -n -c --arg h "$1" --argjson u "${until:-0}" --argjson a "$(now_s)" \
            '{holder: $h, until_s: $u, at_s: $a}' > "$tmp" 2>/dev/null; then
        mv -f -- "$tmp" "${MIRROR}/held-elsewhere.json" 2>/dev/null || rm -f -- "$tmp"
    else
        rm -f -- "$tmp"
    fi
}

do_hook() {
    local input event sid tpath dir lease other then=""
    [ "${1:-}" = --then ] && then="${2:-}"
    input=$(cat 2>/dev/null) || exit 0
    # A prompt that goes through is handed on (--then), whatever this hook makes of it.
    pass_on() { [ -z "$then" ] || printf '%s' "$input" | "$then" >/dev/null 2>&1 || true; }
    if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then pass_on; exit 0; fi
    event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
    sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
    tpath=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null) || exit 0
    if ! printf '%s' "$sid" | grep -Eqx '[A-Za-z0-9-]{1,80}' || [ -z "$tpath" ] \
        || [ ! -d "$(dirname -- "$tpath")" ]; then
        pass_on; exit 0
    fi
    dir=$(dirname -- "$tpath")
    lease="${dir}/${sid}.aidc-lease"
    other=$(holder "$lease")
    [ "$other" = "$(machine)" ] && other=""
    case "$event" in
        SessionStart)
            # -H: on a Mac the project's folder is itself an alias (a symlink to the Linux name).
            find -H "$dir" -mindepth 1 -type l -delete 2>/dev/null
            [ -n "$other" ] || take "$lease" ;;
        UserPromptSubmit)
            if [ -n "$other" ]; then
                printf 'aidc: this conversation is open on %s right now (it is synced between your machines, and two at once would both write it). Continue it there, or start a new one here (/clear).\n' "$other" >&2
                held_note "$other" "$lease"
                exit 2
            fi
            take "$lease"
            [ ! -f "${MIRROR}/held-elsewhere.json" ] || rm -f -- "${MIRROR}/held-elsewhere.json"
            pass_on ;;
        Stop)
            [ -n "$other" ] || take "$lease" ;;
        SessionEnd)
            [ -n "$other" ] || [ ! -f "$lease" ] || rm -f -- "$lease" ;;
    esac
    exit 0
}

# do_free_id <project-dir> <session-id>: whether that conversation is free here.
do_free_id() {
    local other
    printf '%s' "${2:-}" | grep -Eqx '[A-Za-z0-9-]{1,80}' || exit 0
    other=$(holder "${1:-}/${2}.aidc-lease")
    { [ -z "$other" ] || [ "$other" = "$(machine)" ]; } && exit 0
    printf '%s' "$other"
    exit 1
}

case "${1:-}" in
    hook) shift; do_hook "$@" ;;
    free-id) do_free_id "${2:-}" "${3:-}" ;;
esac
exit 0
