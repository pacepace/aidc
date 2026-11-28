#!/usr/bin/env bash
# Unit tests for one Claude history per repo across machines (K8S-18): the conversation lease
# (.devcontainer/claude-lease.sh), and this machine's side (scripts/lib/claude-sync.sh): the
# folder's ignore list, the Mac's alias folders, synced symlinks removed, the hooks added to a
# machine's own settings.
#
# Needs jq; skips without it. Hygiene: scratch under tests/scratch/ (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/claude-sync-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH"
# docker and kubectl first on PATH are stubs, or the test refuses to run (the aidc cases write
# their own kubectl into the same folder).
# shellcheck source=lib/stub-tools.sh
. "$SCRIPT_DIR/lib/stub-tools.sh"
stub_tools "$SCRATCH/dbin"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}
assert_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (no '$needle' in: $hay)"; FAIL=$((FAIL + 1)) ;;
    esac
}

L="$AIDC_ROOT/.devcontainer/claude-lease.sh"
P="$SCRATCH/projects/-home-alice-code-proj"
mkdir -p "$P"
SID=0b5c7e9a-1111-2222-3333-444455556666
T="$P/$SID.jsonl"
printf '{"type":"user","message":"hi"}\n' > "$T"
hook() { jq -n -c --arg e "$1" --arg s "$SID" --arg t "$T" '{hook_event_name: $e, session_id: $s, transcript_path: $t}' \
    | AIDC_LEASE_MACHINE="$2" bash "$L" hook; }

echo "== the lease: one machine at a time"
out=$(hook SessionStart mac 2>&1; echo "|$?")
assert_eq "a session start takes the lease, exit 0" "|0" "$out"
assert_eq "...for its machine" "mac" "$(jq -r .machine "$P/$SID.aidc-lease")"
out=$(hook UserPromptSubmit cluster/s1 2>&1; echo "|$?")
assert_has "a prompt from another machine is blocked (exit 2)" "|2" "$out"
assert_has "...saying where the conversation is open" "open on mac right now" "$out"
assert_eq "...and the lease stays the holder's" "mac" "$(jq -r .machine "$P/$SID.aidc-lease")"
out=$(hook UserPromptSubmit mac 2>&1; echo "|$?")
assert_eq "the holder's own prompt goes through" "|0" "$out"
until_before=$(jq -r .until_s "$P/$SID.aidc-lease")
jq '.until_s = 1' "$P/$SID.aidc-lease" > "$P/x" && mv "$P/x" "$P/$SID.aidc-lease"
out=$(hook UserPromptSubmit cluster/s1 2>&1; echo "|$?")
assert_eq "a lease past its time is free: the other machine takes it" "|0 cluster/s1" "$out $(jq -r .machine "$P/$SID.aidc-lease")"
assert_eq "...for the lease time" "yes" "$([ "$(jq -r .until_s "$P/$SID.aidc-lease")" -ge "$until_before" ] && echo yes)"
hook SessionEnd mac >/dev/null 2>&1
assert_eq "a session end does not let go of another machine's lease" "cluster/s1" "$(jq -r .machine "$P/$SID.aidc-lease")"
hook SessionEnd cluster/s1
assert_eq "the holder's session end lets it go" "no" "$([ -e "$P/$SID.aidc-lease" ] && echo yes || echo no)"
printf 'not json' > "$P/$SID.aidc-lease"
out=$(hook UserPromptSubmit mac 2>&1; echo "|$?")
assert_eq "an unreadable lease is free" "|0" "$out"
out=$(printf 'garbage' | bash "$L" hook; echo "|$?")
assert_eq "input that is not a hook's: exit 0, nothing" "|0" "$out"

echo "== --then: a prompt the lease lets through is handed on (a cluster session's event writer); a refused one is recorded nowhere"
NEXT="$SCRATCH/next.sh"; printf '#!/bin/sh\ncat >> "%s/handed-on"\n' "$SCRATCH" > "$NEXT"; chmod +x "$NEXT"
rm -f "$P"/*.aidc-lease "$SCRATCH/handed-on"
hookthen() { jq -n -c --arg e "$1" --arg s "$SID" --arg t "$T" '{hook_event_name: $e, session_id: $s, transcript_path: $t}' \
    | AIDC_LEASE_MACHINE="$2" bash "$L" hook --then "$NEXT"; }
hookthen UserPromptSubmit cluster/s1 >/dev/null 2>&1
assert_has "a prompt that goes through is handed on, whole" '"hook_event_name":"UserPromptSubmit"' "$(cat "$SCRATCH/handed-on" 2>/dev/null)"
: > "$SCRATCH/handed-on"
out=$(hookthen UserPromptSubmit mac 2>&1; echo "|$?")
assert_has "a refused one is still refused" "|2" "$out"
assert_eq "...and handed on only as a PromptRefused event naming the holder (no turn follows it), in the event writer's own order" \
    '["PromptRefused","cluster/s1"]' "$(jq -c '[.hook_event_name, .holder]' "$SCRATCH/handed-on")"
: > "$SCRATCH/handed-on"
printf 'not json' | bash "$L" hook --then "$NEXT"
assert_eq "input it cannot read is handed on as it came (the event writer decides)" "not json" "$(cat "$SCRATCH/handed-on")"
rm -f "$P"/*.aidc-lease

echo "== a turn longer than the lease time keeps the lease (each tool call renews it)"
rm -f "$P"/*.aidc-lease
hook UserPromptSubmit cluster/s1 >/dev/null 2>&1
jq '.until_s = (now | floor) + 5' "$P/$SID.aidc-lease" > "$P/x" && mv "$P/x" "$P/$SID.aidc-lease"   # 15 minutes into the turn
hook PostToolUse cluster/s1
assert_eq "a tool call renews it for the lease time" "yes" "$([ "$(jq -r .until_s "$P/$SID.aidc-lease")" -gt "$(( $(date +%s) + 600 ))" ] && echo yes)"
out=$(hook UserPromptSubmit mac 2>&1; echo "|$?")
assert_has "...so the other machine is still refused" "|2" "$out"
hook PostToolUse mac
assert_eq "another machine's tool call takes nothing" "cluster/s1" "$(jq -r .machine "$P/$SID.aidc-lease")"
rm -f "$P"/*.aidc-lease

echo "== free-id: may aidc-claude resume this conversation here?"
rm -f "$P"/*.aidc-lease
assert_eq "with no lease, yes" "0" "$(AIDC_LEASE_MACHINE=cluster/s1 bash "$L" free-id "$P" "$SID" >/dev/null; echo $?)"
hook SessionStart mac
out=$(AIDC_LEASE_MACHINE=cluster/s1 bash "$L" free-id "$P" "$SID"; echo "|$?")
assert_eq "held by another machine: no, naming it" "mac|1" "$out"
assert_eq "held by this one: yes" "0" "$(AIDC_LEASE_MACHINE=mac bash "$L" free-id "$P" "$SID" >/dev/null; echo $?)"

echo "== synced symlinks inside a conversation's folder are removed at session start (#35)"
mkdir -p "$P/memory"
ln -s /etc/passwd "$P/memory/secrets.md"
hook SessionStart mac
assert_eq "the symlink is gone" "no" "$([ -L "$P/memory/secrets.md" ] && echo yes || echo no)"
assert_eq "its target is not touched" "yes" "$([ -e /etc/passwd ] && echo yes)"
ALIAS="$SCRATCH/projects/-Users-alice-code-proj"; ln -s -- -home-alice-code-proj "$ALIAS"
ln -s /etc/passwd "$P/memory/again.md"
jq -n -c --arg s "$SID" --arg t "$ALIAS/$SID.jsonl" '{hook_event_name: "SessionStart", session_id: $s, transcript_path: $t}' \
    | AIDC_LEASE_MACHINE=mac bash "$L" hook
assert_eq "...also when the session's folder is a Mac's alias of it" "no" "$([ -L "$P/memory/again.md" ] && echo yes || echo no)"
assert_eq "...the alias itself stays" "yes" "$([ -L "$ALIAS" ] && echo yes)"

# shellcheck source=../../scripts/lib/claude-sync.sh
. "$AIDC_ROOT/scripts/lib/claude-sync.sh"

echo "== two folders: conversations both ways; the Claude files a Claude loads from the machines only"
ig=$(aidc_sync_stignore_shared)
for n in /CLAUDE.md /rules /skills /agents /commands /keybindings.json; do
    assert_has "$n is in the shared folder" "!$n" "$ig"
done
assert_eq "everything else of ~/.claude is not (last line)" "*" "$(printf '%s\n' "$ig" | tail -1)"
for n in projects .credentials.json .claude.json settings.json sessions shell-snapshots; do
    assert_eq "$n is not in the shared folder" "0" "$(printf '%s\n' "$ig" | grep -c "^!/$n")"
done
pj=$(aidc_sync_stignore_projects)
assert_has "a Mac's alias folders are never synced (projects folder)" "/-Users-*" "$pj"
assert_eq "...and nothing else of projects is left out" "0" "$(printf '%s\n' "$pj" | grep -c '^\*$')"
assert_eq "the two folder ids" "aidc-claude-projects aidc-claude-shared" "$AIDC_SYNC_PROJECTS_ID $AIDC_SYNC_SHARED_ID"
mkdir -p "$SCRATCH/home/.claude/projects"
aidc_sync_write_ignore "$SCRATCH/home/.claude" shared
aidc_sync_write_ignore "$SCRATCH/home/.claude/projects" projects
assert_eq "each is written whole" "yes" "$([ "$(cat "$SCRATCH/home/.claude/.stignore")" = "$ig" ] && [ "$(cat "$SCRATCH/home/.claude/projects/.stignore")" = "$pj" ] && echo yes)"

echo "== a Mac's alias folders (history kept under the Linux name)"
PR="$SCRATCH/mac/projects"
mkdir -p "$PR/-home-alice-code-proj" "$PR/-Users-alice-code-new" "$PR/-Users-alice-code-both" "$PR/-home-alice-code-both"
ln -s -- -home-alice-code-gone "$PR/-Users-alice-code-gone"
out=$(aidc_sync_reconcile "$PR" /Users/alice /home/alice 2>&1)
assert_eq "a Linux-named folder gets its /Users alias" "-home-alice-code-proj" "$(readlink "$PR/-Users-alice-code-proj")"
assert_eq "a folder Claude made here moves to the Linux name (synced)" "yes" "$([ -d "$PR/-home-alice-code-new" ] && [ ! -L "$PR/-home-alice-code-new" ] && echo yes)"
assert_eq "...and is aliased" "-home-alice-code-new" "$(readlink "$PR/-Users-alice-code-new")"
assert_eq "a dangling alias is removed" "no" "$([ -L "$PR/-Users-alice-code-gone" ] && echo yes || echo no)"
assert_eq "a name both have is left as it is" "yes" "$([ -d "$PR/-Users-alice-code-both" ] && [ ! -L "$PR/-Users-alice-code-both" ] && echo yes)"
assert_has "...and said" "left -Users-alice-code-both as it is" "$out"
out=$(aidc_sync_reconcile "$PR" /Users/alice /home/alice 2>/dev/null)
assert_eq "run again, nothing to do" "" "$out"
out=$(aidc_sync_reconcile "$PR" /home/alice /home/alice)
assert_eq "on a machine whose home is the cluster's, nothing" "" "$out"
PR2="$SCRATCH/mac2/projects"; mkdir -p "$PR2/-Users-alice-x"
aidc_sync_reconcile "$PR2" /Users/al /home/al >/dev/null 2>&1
assert_eq "a home that is a prefix of another's name (/Users/al, -Users-alice-x) touches nothing of it" "yes" \
    "$([ -d "$PR2/-Users-alice-x" ] && [ ! -L "$PR2/-Users-alice-x" ] && [ ! -e "$PR2/-home-alice-x" ] && [ ! -e "$PR2/-home-al-ice-x" ] && echo yes)"
mkdir -p "$PR/-home-alice-code-proj/memory"; ln -s /etc/hosts "$PR/-home-alice-code-proj/memory/x"
out=$(aidc_sync_strip_links "$PR")
assert_has "symlinks inside a folder are removed and said" "removed a synced symlink" "$out"
assert_eq "...the top-level aliases stay" "-home-alice-code-proj" "$(readlink "$PR/-Users-alice-code-proj")"

echo "== the hooks added to a machine's own settings: a stable command, once, keeping the rest"
S="$SCRATCH/home/.claude/settings.json"
# an earlier install named a versioned path (aidc-1.9.10), since updated and pruned
printf '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-stop"}]},{"hooks":[{"type":"command","command":"/home/u/.local/share/aidc/aidc-1.9.10/.devcontainer/claude-lease.sh hook"}]}]}}' > "$S"
aidc_sync_install_hooks "$S" lease
aidc_sync_install_hooks "$S" lease
aidc_sync_install_hooks "$S" reconcile
assert_eq "each lease hook once, by the aidc on PATH (no versioned path left)" '[1,1,1,1,1,0]' \
    "$(jq -c '([.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.PostToolUse, .hooks.Stop, .hooks.SessionEnd] | map([.[].hooks[] | select(.command == "aidc sync lease-hook")] | length)) + [[.hooks[][].hooks[] | select(.command | test("aidc-1[.]9"))] | length]' "$S")"
assert_eq "the reconciler beside it at session start, once" "1" \
    "$(jq '[.hooks.SessionStart[].hooks[] | select(.command == "aidc sync reconcile --hook")] | length' "$S")"
aidc_sync_install_hooks "$S" lease
assert_eq "...re-running the lease's install keeps the reconciler" "1" \
    "$(jq '[.hooks.SessionStart[].hooks[] | select(.command == "aidc sync reconcile --hook")] | length' "$S")"
assert_eq "the user's own hook and settings are kept" '["opus","my-stop"]' "$(jq -c '[.model, .hooks.Stop[0].hooks[0].command]' "$S")"
printf 'not json' > "$S"
out=$(aidc_sync_install_hooks "$S" lease 2>&1; echo "|$?")
assert_has "a settings file that is not JSON is left alone, and said" "nothing changed" "$out"
assert_eq "...failing" "|1" "${out##*$'\n'}"
assert_eq "...unchanged" "not json" "$(cat "$S")"

echo "== the lease's events are the same on a machine and in a cluster session"
S2="$SCRATCH/home/.claude/settings-fresh.json"
aidc_sync_install_hooks "$S2" lease
machine_events=$(jq -c '[.hooks | to_entries[] | select(any(.value[].hooks[]; .command == "aidc sync lease-hook")) | .key] | sort' "$S2")
cluster_events=$( (. "$AIDC_ROOT/.devcontainer/managed-settings.sh"
    aidc_managed_settings "$SCRATCH/no-registry" false cluster) \
    | jq -c --arg l /usr/local/bin/aidc-claude-lease '[.hooks | to_entries[] | select(any(.value[].hooks[]; .command | startswith($l + " hook"))) | .key] | sort')
assert_eq "machine (claude-sync.sh) and cluster (managed-settings.sh) run the lease at the same events" "$cluster_events" "$machine_events"
assert_eq "...which are these" '["PostToolUse","SessionEnd","SessionStart","Stop","UserPromptSubmit"]' "$machine_events"

echo "== the hook as Claude Code runs it on a machine: aidc sync lease-hook, through the aidc CLI"
DH="$SCRATCH/dhome"; mkdir -p "$DH/.config/aidc" "$SCRATCH/dbin"
printf 'backend: kubernetes\nkubernetes:\n  user: alice\n' > "$DH/.config/aidc/config.yaml"
printf '#!/bin/sh\necho "$*" >> "%s/kubectl-called"\nexit 1\n' "$SCRATCH" > "$SCRATCH/dbin/kubectl"
chmod +x "$SCRATCH/dbin/kubectl"
rm -f "$P"/*.aidc-lease "$SCRATCH/kubectl-called"
viaaidc() { jq -n -c --arg e "$1" --arg s "$SID" --arg t "$T" '{hook_event_name: $e, session_id: $s, transcript_path: $t}' \
    | HOME="$DH" PATH="$SCRATCH/dbin:$PATH" AIDC_LEASE_MACHINE="$2" "${3:-$AIDC_ROOT/scripts/aidc}" sync lease-hook; }
out=$(viaaidc SessionStart mac 2>&1; echo "|$?")
assert_eq "a session start takes the lease, exit 0, nothing said" "|0" "$out"
assert_eq "...for its machine" "mac" "$(jq -r .machine "$P/$SID.aidc-lease")"
out=$(viaaidc UserPromptSubmit cluster/s1 2>&1; echo "|$?")
assert_has "a prompt to a conversation held elsewhere is refused: exit 2" "|2" "$out"
assert_has "...saying where it is open" "open on mac right now" "$out"
out=$(viaaidc UserPromptSubmit mac 2>&1; echo "|$?")
assert_eq "the holder's own prompt goes through: exit 0" "|0" "$out"
out=$(viaaidc PostToolUse mac 2>&1; echo "|$?"); assert_eq "a tool call: exit 0" "|0" "$out"
out=$(viaaidc Stop mac 2>&1; echo "|$?"); assert_eq "a turn end: exit 0 (a Stop is never blocked)" "|0" "$out"
out=$(printf '{}' | HOME="$DH" PATH="$SCRATCH/dbin:$PATH" "$AIDC_ROOT/scripts/aidc" sync reconcile --hook 2>&1; echo "|$?")
assert_eq "the reconciler hook: exit 0, nothing said" "|0" "$out"
assert_eq "with backend: kubernetes configured, no hook calls the cluster (no audit check, nothing)" "no" \
    "$([ -e "$SCRATCH/kubectl-called" ] && echo yes || echo no)"
# An install whose lease script fails, with no VERSION file (the dispatcher would exit 2 on it):
# the hook says 1, an error Claude shows and moves past, never 2, which would refuse the prompt.
BR="$SCRATCH/broken-aidc"; mkdir -p "$BR/scripts" "$BR/.devcontainer"
cp "$AIDC_ROOT/scripts/aidc" "$BR/scripts/aidc"
printf '#!/bin/sh\necho "lease script broke" >&2\nexit 2\n' > "$BR/.devcontainer/claude-lease.sh.real"
printf 'exec sh "$(dirname "$0")/claude-lease.sh.real"; exit 7\n' > "$BR/.devcontainer/claude-lease.sh"
out=$(viaaidc UserPromptSubmit mac "$BR/scripts/aidc" 2>&1; echo "|$?")
assert_has "a lease script that exits 2 is the lease's refusal: kept" "|2" "$out"
printf 'exit 5\n' > "$BR/.devcontainer/claude-lease.sh"
out=$(viaaidc UserPromptSubmit mac "$BR/scripts/aidc" 2>&1; echo "|$?")
assert_has "any other failure of the hook is exit 1, never 2 (no VERSION file there either)" "|1" "$out"
rm -f "$BR/.devcontainer/claude-lease.sh"
out=$(viaaidc Stop mac "$BR/scripts/aidc" 2>&1; echo "|$?")
assert_has "...a missing lease script too" "|1" "$out"
rm -f "$P"/*.aidc-lease

echo
echo "claude-sync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
