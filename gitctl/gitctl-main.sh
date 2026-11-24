#!/bin/sh
# The git container's main process: keeps a tmux session "main" running for the user to attach
# to (`aidc git attach`). A user who types `exit` in its last window ends the session; it comes
# back within seconds, so the next attach finds it instead of an error.
set -u
cd "${HOME:-/home/git}" || exit 1
while :; do
    tmux has-session -t main 2>/dev/null || tmux new-session -d -s main -x 200 -y 50
    sleep 5
done
