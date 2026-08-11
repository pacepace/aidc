#!/usr/bin/env bash
# Start the aidc dev container tmux session.
# Idempotent: if the session already exists, no-op.
#
# Three windows:
#   claude  - aidc-claude (yolo by default; survives detach)
#   shell   - bare bash in the repo
#   logs    - tail target for whatever the user wants to watch

set -euo pipefail

SESSION="main"
REPO="${AIDC_REPO_PATH:-$HOME}"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    exit 0
fi

# Create the session with the claude window. -c sets the window's start dir.
tmux new-session -d -s "$SESSION" -n claude -c "$REPO"
# Auto-launch aidc-claude. tmux keeps the process alive across detaches; the
# next `aidc attach` drops the user back into the same Claude conversation.
tmux send-keys -t "$SESSION:claude" "aidc-claude" C-m

tmux new-window -t "$SESSION:" -n shell -c "$REPO"

tmux new-window -t "$SESSION:" -n logs -c "$REPO"
tmux send-keys -t "$SESSION:logs" "echo 'Logs window. Tail what you need here.'" C-m

tmux select-window -t "$SESSION:claude"
