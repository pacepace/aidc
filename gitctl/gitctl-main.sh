#!/bin/sh
# The git container's main process: keeps a tmux session "main" running for the user to attach
# to (`aidc git attach`, `aidc attach git`), laid out as a session's is: window "claude" runs
# the git agent's Claude (git-claude), window "shell" is a plain shell. It also keeps the request
# watcher (git-requests watch) running, which takes the sessions' push and pull request
# requests. A user who types `exit` in its last window ends the tmux session; it comes back
# within seconds, Claude with it, so the next attach finds it instead of an error. A watcher
# that stopped is started again the same way; its log is ~/.cache/gitctl/requests.log.
set -u
cd "${HOME:-/home/git}" || exit 1
mkdir -p "${HOME:-/home/git}/.cache/gitctl"
start_tmux() {
    tmux new-session -d -s main -n claude -x 200 -y 50 -c "${HOME:-/home/git}" || return 1
    # Typed into the window's shell, as a session's tmux starts aidc-claude: when Claude exits,
    # the window stays, at a shell.
    tmux send-keys -t main:claude /opt/aidc/bin/git-claude C-m
    tmux new-window -d -t main: -n shell -c "${HOME:-/home/git}"
    tmux select-window -t main:claude
}
watcher=""
while :; do
    tmux has-session -t main 2>/dev/null || start_tmux
    if [ -z "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
        /opt/aidc/bin/git-requests watch >> "${HOME:-/home/git}/.cache/gitctl/requests.log" 2>&1 &
        watcher=$!
    fi
    sleep 5
done
