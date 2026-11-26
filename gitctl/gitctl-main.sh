#!/bin/sh
# The git container's main process: keeps a tmux session "main" running for the user to attach
# to (`aidc git attach`, `aidc attach git`), laid out as a session's is: window "claude" runs
# the git agent's Claude (git-claude), window "shell" is a plain shell. A user who types `exit`
# in its last window ends the tmux session; it comes back within seconds, Claude with it, so the
# next attach finds it instead of an error.
#
# The request watcher (git-requests watch) runs as gitreq, the request holder, out of the
# agent's reach (owner ruling 2026-11-26). On Docker (AIDC_GIT_WATCH_HERE=1) this process starts
# it through the one sudo rule that names it, and starts it again if it stops; its errors go to
# ~/.cache/gitctl/requests.log. On Kubernetes it is the main process of the pod's own gitreq
# container. Either way, this process hands waiting requests to the agent's Claude: the holder
# cannot type into this tmux (it is git's), so every 2 seconds it asks the holder which request
# to hand over (git-requests handoff), types its id in (git-notify), then says so (handed).
set -u
cd "${HOME:-/home/git}" || exit 1
mkdir -p "${HOME:-/home/git}/.cache/gitctl"
LOG="${HOME:-/home/git}/.cache/gitctl/requests.log"
GR=/opt/aidc/lib/gitctl/git-requests.sh
# Where the MCP server reads the agent's transcript and hook events (mounted on both backends), and
# the copy-forward that writes it; set otherwise only by the unit test.
OUT="${AIDC_TRANSCRIPT_OUT:-/var/aidc/transcript-out}"
MIRROR="${AIDC_MIRROR_LIB:-/opt/aidc/lib/gitctl/transcript-mirror.sh}"
start_tmux() {
    tmux new-session -d -s main -n claude -x 200 -y 50 -c "${HOME:-/home/git}" || return 1
    # Typed into the window's shell, as a session's tmux starts aidc-claude: when Claude exits,
    # the window stays, at a shell.
    tmux send-keys -t main:claude /opt/aidc/bin/git-claude C-m
    tmux new-window -d -t main: -n shell -c "${HOME:-/home/git}"
    tmux select-window -t main:claude
}
# The git agent's transcript is copied where aidc's MCP server reads every session's
# (/var/aidc/transcript-out: on Docker a folder of the MCP's state dir, on Kubernetes the agent's
# folder of the user's mirror claim, each mounted by aidc git setup), so an orchestrator sees its questions as
# it sees any session's. The same copy-forward as a session's: the dev image's
# transcript-mirror.sh, which the image's staged build context carries (aidc_build_context).
if [ -d "$OUT" ]; then
    # The agent's Claude Code hook events (MCP-46) start empty with the container, as a
    # session's do with aidc create: the MCP must not read this Claude's state from the
    # last event of the one before it (a rebuilt image, a restart).
    rm -rf -- "$OUT/hook-events"
    # shellcheck source=../.devcontainer/transcript-mirror.sh
    . "$MIRROR"
    proj="${HOME:-/home/git}/.claude/projects/$(printf '%s' "${HOME:-/home/git}" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g')"
    ( while :; do aidc_mirror_copy_forward_pass "$proj" "$OUT"; sleep 2; done ) &
fi
# handover: one waiting request, if the holder names one, typed into the agent's Claude.
handover() {
    id=$(sudo -n -u gitreq "$GR" handoff 2>/dev/null) || return 0
    case "$id" in "") return 0 ;; *[!0-9a-f]*) return 0 ;; esac
    [ "${#id}" = 32 ] || return 0
    if /opt/aidc/lib/gitctl/git-notify.sh "$id" </dev/null >/dev/null 2>&1; then
        sudo -n -u gitreq "$GR" handed "$id" >/dev/null 2>&1 || true
    fi
}
# alive PID: the watcher still runs. By its /proc entry, not kill -0: sudo runs as root, so a
# signal from git is refused either way; an exited child left unreaped shows state Z.
alive() {
    [ -n "$1" ] && [ -r "/proc/$1/stat" ] || return 1
    case "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null)" in Z*|"") return 1 ;; esac
}
watcher=""
while :; do
    tmux has-session -t main 2>/dev/null || start_tmux
    if [ "${AIDC_GIT_WATCH_HERE:-0}" = 1 ] && ! alive "$watcher"; then
        # The log is this process's (git's), opened here: the watcher's errors name no secret.
        # shellcheck disable=SC2024
        sudo -n -u gitreq "$GR" watch >> "$LOG" 2>&1 &
        watcher=$!
    fi
    handover
    # The watcher's error log keeps its last lines only.
    if [ -f "$LOG" ] && [ "$(stat -c %s -- "$LOG")" -gt 1048576 ]; then
        tail -n 2000 -- "$LOG" > "${LOG}.tmp" && mv -f -- "${LOG}.tmp" "$LOG"
    fi
    sleep 2
done
