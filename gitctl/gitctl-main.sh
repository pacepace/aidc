#!/bin/sh
# The git container's main process: keeps a tmux session "main" running for the user to attach
# to (`aidc git attach`), and the request watcher (git-requests watch) that takes the sessions'
# push and pull request requests. A user who types `exit` in its last window ends the session;
# it comes back within seconds, so the next attach finds it instead of an error. A watcher that
# stopped is started again the same way; its log is ~/.cache/gitctl/requests.log.
set -u
cd "${HOME:-/home/git}" || exit 1
mkdir -p "${HOME:-/home/git}/.cache/gitctl"
watcher=""
while :; do
    tmux has-session -t main 2>/dev/null || tmux new-session -d -s main -x 200 -y 50
    if [ -z "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
        /opt/aidc/bin/git-requests watch >> "${HOME:-/home/git}/.cache/gitctl/requests.log" 2>&1 &
        watcher=$!
    fi
    sleep 5
done
