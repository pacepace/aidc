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
assert_eq "...and handed on to nothing: no turn follows it, so aidc-mcp must not see a prompt" "" "$(cat "$SCRATCH/handed-on")"
MOUT="$SCRATCH/mirror"; mkdir -p "$MOUT"
jq -n -c --arg s "$SID" --arg t "$T" '{hook_event_name: "UserPromptSubmit", session_id: $s, transcript_path: $t}' \
    | AIDC_TRANSCRIPT_OUT="$MOUT" AIDC_LEASE_MACHINE=mac bash "$L" hook --then "$NEXT" 2>/dev/null
assert_eq "a refusal tells aidc-mcp who holds it, until when (the session's mirror folder)" '["cluster/s1",true]' \
    "$(jq -c '[.holder, (.until_s > .at_s)]' "$MOUT/held-elsewhere.json")"
rm -f "$P"/*.aidc-lease
jq -n -c --arg s "$SID" --arg t "$T" '{hook_event_name: "UserPromptSubmit", session_id: $s, transcript_path: $t}' \
    | AIDC_TRANSCRIPT_OUT="$MOUT" AIDC_LEASE_MACHINE=mac bash "$L" hook --then "$NEXT" 2>/dev/null
assert_eq "a prompt that goes through removes the note" "no" "$([ -e "$MOUT/held-elsewhere.json" ] && echo yes || echo no)"
: > "$SCRATCH/handed-on"
printf 'not json' | bash "$L" hook --then "$NEXT"
assert_eq "input it cannot read is handed on as it came (the event writer decides)" "not json" "$(cat "$SCRATCH/handed-on")"
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

echo "== the folder's ignore list: the ruled sync set, exclusions first"
ig=$(aidc_sync_stignore)
for n in /projects /CLAUDE.md /rules /skills /agents /commands /keybindings.json; do
    assert_has "$n is synced" "!$n" "$ig"
done
assert_eq "everything else is not (last line)" "*" "$(printf '%s\n' "$ig" | tail -1)"
first_include=$(printf '%s\n' "$ig" | grep -n '^!' | head -1 | cut -d: -f1)
alias_line=$(printf '%s\n' "$ig" | grep -n '^/projects/-Users-\*$' | cut -d: -f1)
assert_eq "a Mac's alias folders are never synced, and that line comes before projects/ is let in" "yes" \
    "$([ -n "$alias_line" ] && [ "$alias_line" -lt "$first_include" ] && echo yes)"
for n in .credentials.json .claude.json settings.json sessions shell-snapshots; do
    assert_eq "$n is not let in" "0" "$(printf '%s\n' "$ig" | grep -c "^!/$n")"
done
mkdir -p "$SCRATCH/home/.claude"
aidc_sync_write_stignore "$SCRATCH/home/.claude"
assert_eq "it is written whole" "$ig" "$(cat "$SCRATCH/home/.claude/.stignore")"

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

echo "== the hooks added to a machine's own settings, once, keeping the rest"
S="$SCRATCH/home/.claude/settings.json"
printf '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-stop"}]}]}}' > "$S"
aidc_sync_install_hooks "$S" "/opt/aidc/.devcontainer/claude-lease.sh hook"
aidc_sync_install_hooks "$S" "/opt/aidc/.devcontainer/claude-lease.sh hook"
assert_eq "each of the four hooks once" '[1,1,1,1]' \
    "$(jq -c '[.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.Stop, .hooks.SessionEnd] | map([.[].hooks[] | select(.command | test("claude-lease"))] | length)' "$S")"
assert_eq "the user's own hook and settings are kept" '["opus","my-stop"]' "$(jq -c '[.model, .hooks.Stop[0].hooks[0].command]' "$S")"
printf 'not json' > "$S"
out=$(aidc_sync_install_hooks "$S" "x" 2>&1; echo "|$?")
assert_has "a settings file that is not JSON is left alone, and said" "nothing changed" "$out"
assert_eq "...failing" "|1" "${out##*$'\n'}"
assert_eq "...unchanged" "not json" "$(cat "$S")"

echo
echo "claude-sync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
