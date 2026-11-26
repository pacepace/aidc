#!/usr/bin/env bash
# MCP-46: a session's Claude Code hooks write each event as a file aidc-mcp reads, and the
# session's managed settings install them (keeping the shared plugins).
#
# Runs the shipped scripts (.devcontainer/hook-event.sh, .devcontainer/managed-settings.sh)
# against a temp dir. No Docker. Needs jq.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$AIDC_ROOT/.devcontainer/hook-event.sh"
PASS=0
FAIL=0
check() {
    if [ "$2" = "yes" ]; then echo "  PASS: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1"; FAIL=$((FAIL + 1)); fi
}
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
OUT="$S/transcript-out"
mkdir -p "$OUT"
export AIDC_HOOK_EVENTS_DIR="$OUT/hook-events"
# a stand-in tmux: the pane's window is whatever $FAKE_WINDOW says (main:claude by default)
mkdir -p "$S/bin"
cat > "$S/bin/tmux" <<'TMUXSTUB'
#!/usr/bin/env bash
[ "$1" = display-message ] && printf '%s\n' "${FAKE_WINDOW:-main:claude}"
TMUXSTUB
chmod +x "$S/bin/tmux"
export PATH="$S/bin:$PATH" TMUX_PANE="%0"

run_hook() {   # run_hook <json>: the hook's exit code and what it printed
    local out rc
    out=$(printf '%s' "$1" | bash "$HOOK" 2>&1); rc=$?
    printf '%s|%s' "$rc" "$out"
}

echo "=== the writer: one file per event, Claude's input with event and at ==="
r=$(run_hook '{"hook_event_name":"Stop","session_id":"sid-1","last_assistant_message":"done.","stop_hook_active":false}')
check "a Stop event exits 0 and prints nothing (a Stop hook's output can be read as a decision)" \
    "$([ "$r" = "0|" ] && echo yes || echo no)"
files=("$AIDC_HOOK_EVENTS_DIR"/*.json)
check "it wrote one file" "$([ "${#files[@]}" -eq 1 ] && [ -f "${files[0]}" ] && echo yes || echo no)"
ev="${files[0]}"
check "event names the hook" "$([ "$(jq -r .event "$ev")" = "Stop" ] && echo yes || echo no)"
check "at is UTC with milliseconds" \
    "$(jq -r .at "$ev" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$' && echo yes || echo no)"
check "the hook's own fields are kept: session_id and last_assistant_message" \
    "$([ "$(jq -r '.session_id + "|" + .last_assistant_message' "$ev")" = "sid-1|done." ] && echo yes || echo no)"

sleep 0.01
run_hook '{"hook_event_name":"Notification","session_id":"sid-1","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}' >/dev/null
sleep 0.01
run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sid-1","prompt":"run the tests"}' >/dev/null
order=$(for f in "$AIDC_HOOK_EVENTS_DIR"/*.json; do jq -r .event "$f"; done | paste -sd' ' -)
check "names sort in the order the events happened (got: $order)" \
    "$([ "$order" = "Stop Notification UserPromptSubmit" ] && echo yes || echo no)"
check "a Notification keeps its type" \
    "$(cat "$AIDC_HOOK_EVENTS_DIR"/*.json | jq -r 'select(.event=="Notification") | .notification_type' | grep -qx permission_prompt && echo yes || echo no)"
check "a UserPromptSubmit keeps the prompt" \
    "$(cat "$AIDC_HOOK_EVENTS_DIR"/*.json | jq -r 'select(.event=="UserPromptSubmit") | .prompt' | grep -qx 'run the tests' && echo yes || echo no)"
others=0; badname=0
for f in "$AIDC_HOOK_EVENTS_DIR"/* "$AIDC_HOOK_EVENTS_DIR"/.[!.]*; do
    [ -e "$f" ] || continue
    case "$f" in *.json) ;; *) others=$((others + 1)) ;; esac
    [[ "$(basename "$f")" =~ ^[0-9]{19}-[0-9]+\.json$ ]] || badname=$((badname + 1))
done
check "no temp file is left (written by rename)" "$([ "$others" -eq 0 ] && echo yes || echo no)"
check "file names are <epoch-ns>-<pid>.json, sorting in time order" \
    "$([ "$badname" -eq 0 ] && echo yes || echo no)"

echo "=== the writer never fails or blocks Claude ==="
count() { local n=0 f; for f in "$AIDC_HOOK_EVENTS_DIR"/*.json; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
before=$(count)
check "input that is not JSON exits 0 and writes nothing" \
    "$([ "$(run_hook 'not json')" = "0|" ] && [ "$(count)" -eq "$before" ] && echo yes || echo no)"
check "a JSON value that is not an object writes nothing" \
    "$([ "$(run_hook '[1,2]')" = "0|" ] && [ "$(count)" -eq "$before" ] && echo yes || echo no)"
r=$(printf '{}' | AIDC_HOOK_EVENTS_DIR="$S/no-mirror/hook-events" bash "$HOOK" 2>&1; echo "|$?")
check "a session without the mirror dir: exit 0, nothing created" \
    "$([ "$r" = "|0" ] && [ ! -e "$S/no-mirror" ] && echo yes || echo no)"
before=$(count)
r=$(printf '{"hook_event_name":"Stop"}' | env -u TMUX_PANE bash "$HOOK" 2>&1; echo "|$?")
check "a claude outside tmux (a headless --print run by docker exec): exit 0, nothing written" \
    "$([ "$r" = "|0" ] && [ "$(count)" -eq "$before" ] && echo yes || echo no)"
r=$(printf '{"hook_event_name":"Stop"}' | FAKE_WINDOW=main:shell bash "$HOOK" 2>&1; echo "|$?")
check "a claude in another tmux window: exit 0, nothing written" \
    "$([ "$r" = "|0" ] && [ "$(count)" -eq "$before" ] && echo yes || echo no)"
r=$(printf '{"hook_event_name":"Stop"}' | FAKE_WINDOW=other:claude bash "$HOOK" 2>&1; echo "|$?")
check "a claude in a window named claude of another tmux session: nothing written" \
    "$([ "$r" = "|0" ] && [ "$(count)" -eq "$before" ] && echo yes || echo no)"
chmod 0500 "$AIDC_HOOK_EVENTS_DIR"
r=$(printf '{"hook_event_name":"Stop"}' | bash "$HOOK" 2>&1; echo "|$?")
chmod 0700 "$AIDC_HOOK_EVENTS_DIR"
check "an unwritable events dir: exit 0, nothing printed" "$([ "$r" = "|0" ] && echo yes || echo no)"

echo "=== the managed settings install the hooks and keep the shared plugins ==="
# shellcheck source=../../.devcontainer/managed-settings.sh
. "$AIDC_ROOT/.devcontainer/managed-settings.sh"
reg="$S/installed_plugins.json"
printf '%s' '{"plugins":{"prawduct@prawduct":[{}],"other@market":[{}]}}' > "$reg"
root="$S/root"
check "the settings install (shared plugins on)" \
    "$(aidc_install_managed_settings "$root" "$reg" true && echo yes || echo no)"
ms="$root/etc/claude-code/managed-settings.json"
for e in SessionStart Stop Notification UserPromptSubmit; do
    check "the $e hook runs aidc-hook-event" \
        "$([ "$(jq -r ".hooks.${e}[0].hooks[0].command" "$ms")" = /usr/local/bin/aidc-hook-event ] && echo yes || echo no)"
done
check "the Notification hook has no matcher: every notification type" \
    "$([ "$(jq -r '.hooks.Notification[0] | has("matcher")' "$ms")" = false ] && echo yes || echo no)"
check "the shared plugins are still enabled" \
    "$([ "$(jq -c '.enabledPlugins' "$ms")" = '{"other@market":true,"prawduct@prawduct":true}' ] && echo yes || echo no)"
check "the file is 0644 and no temp is left" \
    "$([ "$(stat -c %a "$ms")" = 644 ] && [ "$(ls -A "$root/etc/claude-code")" = managed-settings.json ] && echo yes || echo no)"
aidc_install_managed_settings "$root" "$reg" false
check "share_plugins off: the hooks alone, no plugins enabled" \
    "$([ "$(jq -c 'keys' "$ms")" = '["hooks"]' ] && echo yes || echo no)"
aidc_install_managed_settings "$root" "$S/absent.json" true
check "share_plugins on with no registry: the hooks alone" \
    "$([ "$(jq -c 'keys' "$ms")" = '["hooks"]' ] && echo yes || echo no)"
mkdir -p "$S/ro/etc"; chmod 0500 "$S/ro/etc"
err=$(aidc_install_managed_settings "$S/ro" "$reg" true 2>&1; echo "|$?")
chmod 0700 "$S/ro/etc"
check "a settings dir that cannot be written fails non-zero and says why" \
    "$(printf '%s' "$err" | grep -q 'cannot create' && [ "${err##*|}" != 0 ] && echo yes || echo no)"

echo "=== the image installs both, executable ==="
DF="$AIDC_ROOT/.devcontainer/Dockerfile"
check "the hook is copied to /usr/local/bin/aidc-hook-event" \
    "$(grep -qE '^COPY hook-event\.sh +/usr/local/bin/aidc-hook-event$' "$DF" && echo yes || echo no)"
check "the settings library is copied" \
    "$(grep -qE '^COPY managed-settings\.sh +/usr/local/bin/aidc-managed-settings\.sh$' "$DF" && echo yes || echo no)"
check "the hook is made executable" "$(grep -q '/usr/local/bin/aidc-hook-event \\' "$DF" && echo yes || echo no)"
check "the entrypoint installs the managed settings" \
    "$(grep -q 'aidc_install_managed_settings / ' "$AIDC_ROOT/.devcontainer/entrypoint.sh" && echo yes || echo no)"
check "a failed install says what follows: sends refused as session_outdated, no screen fallback" \
    "$(grep -q 'refuses prompts to this session (session_outdated)' "$AIDC_ROOT/.devcontainer/entrypoint.sh" \
        && ! grep -qi 'falls back to reading the screen' "$AIDC_ROOT/.devcontainer/entrypoint.sh" && echo yes || echo no)"

check "aidc create starts the session's hook events empty (a recreated session reads none of the old one's)" \
    "$(grep -q 'rm -rf -- "${MCP_TRANSCRIPTS_WRITE}/hook-events"' "$AIDC_ROOT/scripts/cmd-create.sh" && echo yes || echo no)"

echo
echo "hook events: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
