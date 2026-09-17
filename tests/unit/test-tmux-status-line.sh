#!/usr/bin/env bash
# Unit test for the tmux status line that tells a person an orchestrator prompt is
# waiting on their unsent text (.devcontainer/tmux-start.sh, set by aidc-mcp's
# @aidc_waiting option).
#
# It renders the REAL status line: tmux-start.sh builds the session on a private tmux
# server, and a client attached from inside a pane of a second private server, 80
# columns wide, draws it where capture-pane can read it. The first version cut the
# start of the message off on terminals narrower than about 130 columns.
#
# Skipped when tmux is not installed. The sockets live under a short mktemp dir in
# /tmp: a unix socket path longer than 108 bytes cannot be used.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0

if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux status line: SKIPPED (tmux not installed)"
    exit 0
fi

SOCKETS="$(mktemp -d /tmp/aidc-tmux-test.XXXXXX)"
export LANG=C.UTF-8
inner() { env -u TMUX TMUX_TMPDIR="$SOCKETS/inner" tmux "$@"; }
outer() { env -u TMUX TMUX_TMPDIR="$SOCKETS/outer" tmux "$@"; }
cleanup() {
    outer kill-server 2>/dev/null
    inner kill-server 2>/dev/null
    rm -rf "$SOCKETS"
}
trap cleanup EXIT INT TERM
mkdir -p "$SOCKETS/inner" "$SOCKETS/outer" "$SOCKETS/bin"

assert_contains() {
    local desc="$1" want="$2" got="$3"
    if [[ "$got" == *"$want"* ]]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want' in '$got')"; FAIL=$((FAIL + 1))
    fi
}
assert_not_contains() {
    local desc="$1" unwanted="$2" got="$3"
    if [[ "$got" != *"$unwanted"* ]]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc ('$unwanted' in '$got')"; FAIL=$((FAIL + 1))
    fi
}

# The message is the one aidc-mcp sets, read from its source.
MESSAGE="$(python3 -c '
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
for node in tree.body:
    if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "_WAITING_ON_INPUT_TEXT":
        print(ast.literal_eval(node.value))
' "$AIDC_ROOT/mcp/src/aidc_mcp/tools.py")"
if [ -z "$MESSAGE" ]; then
    echo "  FAIL: could not read _WAITING_ON_INPUT_TEXT from tools.py"
    exit 1
fi

# tmux-start.sh launches aidc-claude in the claude window; a stand-in keeps it alive.
printf '#!/bin/sh\nexec sleep 600\n' > "$SOCKETS/bin/aidc-claude"
chmod +x "$SOCKETS/bin/aidc-claude"
env -u TMUX TMUX_TMPDIR="$SOCKETS/inner" PATH="$SOCKETS/bin:$PATH" AIDC_REPO_PATH="$SOCKETS" \
    bash "$AIDC_ROOT/.devcontainer/tmux-start.sh"

outer new-session -d -s view -x 80 -y 10 \
    "env -u TMUX TMUX_TMPDIR='$SOCKETS/inner' tmux attach -t main"

status_line() {
    inner refresh-client -S 2>/dev/null
    sleep 0.5
    outer capture-pane -p -t view | tail -1
}

inner set-option -t main @aidc_waiting "$MESSAGE"
line="$(status_line)"
assert_contains "the whole waiting message shows at 80 columns" "$MESSAGE" "$line"
assert_not_contains "the clock steps aside while it shows" "$(date +%d-%b-%y)" "$line"

inner set-option -t main -u @aidc_waiting
line="$(status_line)"
assert_not_contains "the message goes when the option is unset" "orchestrator" "$line"
assert_contains "the clock is back" "$(date +%d-%b-%y)" "$line"

echo
echo "tmux status line: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
