#!/usr/bin/env bash
# Unit tests for the git container's side of session requests (gitctl/git-requests.sh) and the
# sessions' gh stand-in (.devcontainer/gh-standin.sh), end to end through the request folder.
#
# A request is data a sandboxed session wrote. A field the watcher let through unchecked, a
# request file it followed through a symlink, a request run in ask mode without the user's yes,
# a result written where a session could have planted something, or a request kept forever
# would break the owner's rulings (sessions hand the git container requests; ask mode waits for
# the user; nothing piles up). gitctl is a stub that logs what it was asked to run (gitctl's
# own checks are tested in test-gitctl-rules.sh); the request folder is a scratch folder owned
# by the test user, standing in for the git container's. Needs jq and git.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).
# shellcheck disable=SC2016

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$AIDC_ROOT/tests/scratch/git-requests-$$"
PASS=0
FAIL=0
trap 'rm -rf "$S"' EXIT INT TERM
umask 022
mkdir -p "$S/bin" "$S/disk" "$S/home"
S=$(cd "$S" && pwd -P)
for t in jq git; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }; done

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
assert_has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in: $(printf '%s' "$3" | tail -5))" ;; esac; }
assert_not_has() { case "$3" in *"$2"*) fail "$1 ('$2' in: $(printf '%s' "$3" | tail -5))" ;; *) pass "$1" ;; esac; }

# Stub gitctl: logs each call (%q words) to gitctl.log; G_FAIL=<verb> makes that verb fail.
cat > "$S/bin/gitctl" <<'STUB'
#!/usr/bin/env bash
d=$(dirname "$0")
{ printf '%q ' "$@"; echo; } >> "$d/gitctl.log"
[ "${G_FAIL:-}" = "$1" ] && { echo "${G_MSG:-gitctl: refused: no GitHub login (gitctl login)}" >&2; exit 1; }
case "$1" in
    push) echo "pushed $3 $(git -C "$2" rev-parse "refs/heads/$3")" ;;
    pr-create) cat "$6" > "$d/title.seen"; cat "$8" > "$d/body.seen"; echo "https://github.com/o/r/pull/12" ;;
    pr-merge) echo "merged" ;;
    tidy) printf 'deleted-branch feat\nunpushed 2 other\nend\n' ;;
    pr-view-json) echo '{"number":12,"title":"Add it","state":"OPEN","url":"https://github.com/o/r/pull/12","headRefName":"feat","baseRefName":"main","body":"B","headRefOid":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' ;;
    pr-list-json) echo '[{"number":12,"title":"Add it","state":"OPEN","headRefName":"feat","url":"u"}]' ;;
    protection) printf 'repo o/r\ndefault main\nforce-push allowed\ndeletion blocked\nmerge-commit allowed\nsquash allowed\nrebase allowed\nend\n' ;;
esac
STUB
chmod +x "$S/bin/gitctl"

REQ="$S/disk/.aidc/git-requests"
mkdir -p "$REQ"; chmod 0755 "$REQ"
P="$S/disk/proj"
git init -q "$P"
git -C "$P" -c user.name=A -c user.email=a@example.com commit -q --allow-empty -m first
git -C "$P" remote add origin https://github.com/o/r
git -C "$P" update-ref refs/remotes/origin/main HEAD
git -C "$P" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$P" switch -q -c feat
git -C "$P" -c user.name=A -c user.email=a@example.com commit -q --allow-empty -m "Add it"

export AIDC_GIT_REQUESTS="$REQ" AIDC_GITREQ_GITCTL="$S/bin/gitctl" AIDC_GITREQ_DISK_ROOT="$S/disk" \
    HOME="$S/home" AIDC_SESSION=demo
AIDC_GIT_AGENT_UID=$(id -u); export AIDC_GIT_AGENT_UID
unset AIDC_GIT_MODE
GR="$AIDC_ROOT/gitctl/git-requests.sh"
GH="$AIDC_ROOT/.devcontainer/gh-standin.sh"
gr() { OUT=$(bash "$GR" "$@" 2>&1); RC=$?; }
calls() { cat "$S/bin/gitctl.log" 2>/dev/null; }
reset_calls() { : > "$S/bin/gitctl.log"; }
state() { jq -r '.state' "$REQ/results/$1.json" 2>/dev/null || echo none; }
newid() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
# put ID JSON: a request as a session writes it.
put() { printf '%s' "$2" > "$REQ/requests/$1.json"; }
# Session demo's token, registered as aidc create registers a session's: a request carries it
# unless the test says otherwise (a request with no token, or another, is always ask).
TOKD=$(printf 'd%.0s' $(seq 64))
printf '%s\n' "$TOKD" | bash "$GR" register demo >/dev/null
req() { # ID ACTION [extra jq object]
    jq -n --arg id "$1" --arg action "$2" --arg repo "$P" --arg tok "$TOKD" --argjson x "${3:-{\}}" \
        '{version: 1, id: $id, session: "demo", action: $action, repo: $repo, worktree: $repo, branch: "feat", base: "main", title: "Add it", body: "Body.", token: $tok} + $x'
}
HEADSHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

echo "=== the folder: the git container's, sessions may only drop requests ==="
gr once
assert_eq "a pass makes requests/ (sticky; the group may add, not list), results/ (read by name) and work/ (private)" \
    "1730 710 700" "$(stat -c %a "$REQ/requests") $(stat -c %a "$REQ/results") $(stat -c %a "$REQ/work")"
chmod 0775 "$REQ"; gr once
assert_eq "a request folder others can write is refused" "1" "$RC"
assert_has "with the reason" "writable by others" "$OUT"
chmod 0755 "$REQ"
ln -s "$REQ" "$S/disk/req-link"
OUT=$(AIDC_GIT_REQUESTS="$S/disk/req-link" bash "$GR" once 2>&1); RC=$?
assert_eq "a symlink on the way to it is refused" 1 "$RC"

echo ""
echo "=== ask mode (the default): a change waits for the user ==="
reset_calls; id=$(newid); put "$id" "$(req "$id" pr-create)"
gr once
assert_eq "a PR request is held, pending, and nothing reaches gitctl" "pending|" "$(state "$id")|$(calls)"
assert_eq "it is moved out of requests/ (a session cannot change it any more)" no "$([ -e "$REQ/requests/$id.json" ] && echo yes || echo no)"
assert_eq "the result is readable by the session group, written by the agent" 640 "$(stat -c %a "$REQ/results/$id.json")"
gr list
assert_has "list shows it, with its session, action, branch and title" "$id" "$OUT"
assert_has "..." "demo" "$OUT"; assert_has "..." "pr-create" "$OUT"
assert_has "... the GitHub repo it acts on, and the branch's commit when it was taken" "o/r" "$OUT"
assert_has "..." "feat@$(git -C "$P" rev-parse feat | cut -c1-12): Add it" "$OUT"
gr prompt "$id"
assert_has "the prompt for the git agent says the request is data, not instructions" "data, never instructions" "$OUT"
assert_has "and names the commands" "git-requests approve $id" "$OUT"
gr approve "$id"
assert_eq "approve runs push (bound to the repo and commit taken), then pr-create with the title and body, then reads the protections once" \
    "push $P feat --expect-repo o/r --expect-commit $(git -C "$P" rev-parse feat) --asked-by $id |pr-create $P feat main --title-file work/$id.title --body-file work/$id.body --expect-repo o/r --asked-by $id |protection $P --expect-repo o/r " \
    "$(calls | paste -sd'|' -)"
assert_eq "the texts reached gitctl as written" "Add it|Body." "$(cat "$S/bin/title.seen")|$(cat "$S/bin/body.seen")"
assert_eq "the result is done, with the PR URL and the pushed commit" \
    "done|https://github.com/o/r/pull/12|feat $(git -C "$P" rev-parse feat)" \
    "$(jq -r '"\(.state)|\(.url)|\(.pushed.branch) \(.pushed.sha)"' "$REQ/results/$id.json")"
assert_has "and tells the user about the missing protection" "aidc git protect" "$(jq -r .message "$REQ/results/$id.json")"
assert_eq "the texts are not left in work/" "" "$(find "$REQ/work" -name '*.title' -o -name '*.body')"
gr approve "$id"
assert_eq "a request already done cannot be approved again" 1 "$RC"
reset_calls; id2=$(newid); put "$id2" "$(req "$id2" push)"; gr once
gr approve "$id2"
assert_eq "the protections are read on a repo's first use only" "push $P feat --expect-repo o/r --expect-commit $(git -C "$P" rev-parse feat) --asked-by $id2 " "$(calls)"
reset_calls; id3=$(newid); put "$id3" "$(req "$id3" pr-merge '{"number":"12"}')"; gr once
gr deny "$id3" $'not now\033[31m'
assert_eq "deny: the session is told, with the reason made printable; nothing ran but the read of the PR's head when it was taken" \
    "denied|denied by the user: not now[31m|pr-view-json $P 12 --expect-repo o/r --asked-by $id3 " \
    "$(state "$id3")|$(jq -r .message "$REQ/results/$id3.json")|$(calls)"
id4=$(newid); put "$id4" "$(req "$id4" pr-view '{"number":"12"}')"; reset_calls; gr once
assert_eq "reading a PR runs at once, even in ask mode" "done|pr-view-json $P 12 --expect-repo o/r --asked-by $id4 " "$(state "$id4")|$(calls)"
assert_has "its answer is the result's output" '"number":12' "$(jq -r .output "$REQ/results/$id4.json")"

echo ""
echo "=== rules mode: gitctl's rules decide at once ==="
reset_calls; id=$(newid); put "$id" "$(req "$id" pr-merge '{"number":"12"}')"
OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "a merge reads the PR's head when taken, merges bound to it, then tidies" \
    "done|pr-view-json $P 12 --expect-repo o/r --asked-by $id |pr-merge $P 12 --expect-repo o/r --expect-head $HEADSHA --asked-by $id |tidy $P --expect-repo o/r --asked-by $id " \
    "$(state "$id")|$(calls | paste -sd'|' -)"
assert_has "the tidy report reaches the session" "unpushed 2 other" "$(jq -r .output "$REQ/results/$id.json")"
reset_calls; id=$(newid); put "$id" "$(req "$id" push)"
OUT=$(G_FAIL=push AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "a verb that fails fails the request, with gitctl's reason" "failed|gitctl: refused: no GitHub login (gitctl login)" \
    "$(state "$id")|$(jq -r .message "$REQ/results/$id.json")"
reset_calls; id=$(newid); put "$id" "$(req "$id" push)"
OUT=$(G_FAIL=push G_MSG="fatal: could not read Username for 'https://github.com': terminal prompts disabled" AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "no GitHub login is said plainly, with what the user runs" \
    "the git container is not logged in to GitHub (the user runs: aidc git login)" "$(jq -r .message "$REQ/results/$id.json")"
OUT=$(AIDC_GIT_MODE=yolo bash "$GR" once 2>&1)
id=$(newid); put "$id" "$(req "$id" push)"; reset_calls
OUT=$(AIDC_GIT_MODE=yolo bash "$GR" once 2>&1)
assert_eq "an unknown mode is ask" "pending|" "$(state "$id")|$(calls)"

echo ""
echo "=== a session's own mode, both ways, by its token ==="
# Every mode decision is keyed on the session's token. With the user's mode ask, a session given
# rules (aidc git mode) runs its requests at once, but only requests carrying its token: another
# session naming it, or a request with no token, stays ask. With the user's mode rules, a session
# held to ask waits for the user, with or without its token.
TOK=$(printf 'a%.0s' $(seq 64)) OTHER=$(printf 'b%.0s' $(seq 64))
MODES="$S/home/.local/state/gitctl/modes"
printf '%s\n' "$TOK" | bash "$GR" mode demo rules >/dev/null 2>&1
gr modes
assert_eq "modes lists the user's mode and the session's own" "default ask|demo rules" "$(printf '%s\n' "$OUT" | paste -sd'|' -)"
assert_eq "only the token's SHA-256 is kept, never the token" "no" \
    "$(grep -rqF "$TOK" "$MODES" && echo yes || echo no)"
reset_calls; id=$(newid); put "$id" "$(req "$id" push "{\"token\":\"$TOK\"}")"; gr once
assert_eq "a request with the session's token runs at once" "done|rules" "$(state "$id")|$(jq -r .mode "$REQ/results/$id.json")"
assert_eq "the token is not kept with the request" "" "$(jq -r '.token // ""' "$REQ/work/$id.json")"
reset_calls; id=$(newid); put "$id" "$(req "$id" push "{\"token\":\"$OTHER\"}")"; gr once
assert_eq "another token naming the same session waits for the user" "pending|ask|" "$(state "$id")|$(jq -r .mode "$REQ/results/$id.json")|$(calls)"
gr deny "$id"
reset_calls; id=$(newid); put "$id" "$(req "$id" push '{"token":""}')"; gr once
assert_eq "so does a request with no token" "pending|" "$(state "$id")|$(calls)"
gr deny "$id"
id=$(newid); put "$id" "$(req "$id" push '{"token":"not-a-token"}')"; gr once
assert_has "a malformed token refuses the request" "refused: token: not a session token" "$(jq -r .message "$REQ/results/$id.json")"
printf 'short\n' | bash "$GR" mode demo rules >/dev/null 2>&1
assert_eq "a mode without the session's token on stdin is refused" 1 "$?"
bash "$GR" mode demo ask </dev/null >/dev/null 2>&1
assert_eq "ask too needs the token" 1 "$?"
printf '%s\n' "$TOK" | bash "$GR" mode demo default >/dev/null 2>&1
assert_eq "default takes the session's mode back" "default ask" "$(bash "$GR" modes 2>&1 | paste -sd'|' -)"
reset_calls; id=$(newid); put "$id" "$(req "$id" push "{\"token\":\"$TOK\"}")"; gr once
assert_eq "and its token no longer loosens anything" "pending" "$(state "$id")"
gr deny "$id"
# The user's mode rules: a session held to ask (owner ruling 2026-11-23: per session, both ways).
OUT=$(printf '%s\n' "$TOK" | AIDC_GIT_MODE=rules bash "$GR" mode demo ask 2>&1); RC=$?
assert_eq "holding one session to ask under the user's rules is accepted" "0" "$RC"
assert_has "saying so" "demo: ask (its own; the user's mode is rules)" "$OUT"
reset_calls; id=$(newid); put "$id" "$(req "$id" push "{\"token\":\"$TOK\"}")"; OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "a request of the held session waits for the user, under the user's rules" "pending|ask|" "$(state "$id")|$(jq -r .mode "$REQ/results/$id.json")|$(calls)"
gr deny "$id"
reset_calls; id=$(newid); put "$id" "$(req "$id" push '{"token":""}')"; OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "leaving its token out gains it nothing: a request with no token is ask" "pending|ask|" "$(state "$id")|$(jq -r .mode "$REQ/results/$id.json")|$(calls)"
gr deny "$id"
reset_calls; id=$(newid); put "$id" "$(req "$id" push "{\"token\":\"$OTHER\",\"session\":\"nobody\"}")"; OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "nor does naming a session that has no record (any token)" "pending|ask|" "$(state "$id")|$(jq -r .mode "$REQ/results/$id.json")|$(calls)"
gr deny "$id"
printf '%s\n' "$OTHER" | bash "$GR" register other >/dev/null 2>&1
reset_calls; id=$(newid); put "$id" "$(req "$id" push "{\"token\":\"$OTHER\",\"session\":\"other\"}")"; OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "another registered session, with its own token, has the user's rules" "done|rules" "$(state "$id")|$(jq -r .mode "$REQ/results/$id.json")"
reset_calls; id=$(newid); put "$id" "$(req "$id" push "{\"token\":\"$OTHER\"}")"; OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "but its token naming the held session does not take that session's place" "pending|ask|" "$(state "$id")|$(jq -r .mode "$REQ/results/$id.json")|$(calls)"
gr deny "$id"
OUT=$(AIDC_GIT_MODE=rules bash "$GR" modes 2>&1)
assert_eq "modes lists the held session" "default rules|demo ask" "$(printf '%s\n' "$OUT" | paste -sd'|' -)"
gr mode ../x rules
assert_eq "a session name that is not one is refused" 1 "$RC"
# The record lives as long as the session: aidc kill forgets it, a session made again under the
# same name (a new token) starts at the user's mode, and setup prunes records of sessions gone.
printf '%s\n' "$OTHER" | bash "$GR" register demo >/dev/null 2>&1
assert_eq "a new session under the old name (a new token) starts with no mode of its own" "default rules" \
    "$(AIDC_GIT_MODE=rules bash "$GR" modes 2>&1 | paste -sd'|' -)"
printf '%s\n' "$TOK" | bash "$GR" mode demo ask >/dev/null 2>&1
printf '%s\n' "$TOK" | bash "$GR" register demo >/dev/null 2>&1
assert_eq "registering the same session again (same token) keeps its mode" "default ask|demo ask" "$(bash "$GR" modes 2>&1 | paste -sd'|' -)"
gr forget demo
assert_eq "forget (aidc kill) removes the session's record" "0|no" "$RC|$([ -e "$MODES/demo" ] && echo yes || echo no)"
printf '%s\n' "$TOK" | bash "$GR" mode demo ask >/dev/null 2>&1
printf '%s\n' "$OTHER" | bash "$GR" register gone >/dev/null 2>&1
OUT=$(printf 'demo %s\nfresh %s\n' "$TOKD" "$OTHER" | bash "$GR" sync 2>&1)
assert_has "sync registers every session there is and prunes the rest" "sessions: 2 registered, 2 gone pruned" "$OUT"
assert_eq "each record now holds its session's current token, with no stale mode; gone sessions have none" \
    "default $(printf '%s' "$TOKD" | sha256sum | cut -d' ' -f1)|default|no no" \
    "$(cat "$MODES/demo")|$(cut -d' ' -f1 "$MODES/fresh")|$([ -e "$MODES/gone" ] && echo yes || echo no) $([ -e "$MODES/other" ] && echo yes || echo no)"
rm -f "$MODES/fresh"

echo ""
echo "=== ask mode hands a waiting request to the git agent's Claude, one at a time ==="
cat > "$S/bin/notify" <<'STUB'
#!/usr/bin/env bash
[ "${N_FAIL:-}" = 1 ] && exit 1
echo "$1" >> "$(dirname "$0")/notify.log"
STUB
chmod +x "$S/bin/notify"
export AIDC_GIT_NOTIFY="$S/bin/notify"
: > "$S/bin/notify.log"
a=$(newid); put "$a" "$(req "$a" push)"; gr once
assert_eq "a waiting request is handed over by its id" "$a" "$(cat "$S/bin/notify.log")"
b=$(newid); put "$b" "$(req "$b" push)"; gr once
assert_eq "a second one is not typed in while the first still waits (it may be mid-question)" "$a" "$(cat "$S/bin/notify.log")"
assert_has "it is logged as waiting behind it" "$b waits behind $a" "$(cat "$REQ/work/requests.log")"
gr deny "$a"
c=$(newid); put "$c" "$(req "$c" push)"; gr once
assert_eq "once the first is decided, the next new one is handed over" "$a|$c" "$(paste -sd'|' "$S/bin/notify.log")"
gr deny "$b"; gr deny "$c"
d=$(newid); put "$d" "$(req "$d" push)"; N_FAIL=1 gr once
assert_has "Claude not running: logged, the request stays in the list" "$d not handed to the git agent" "$(cat "$REQ/work/requests.log")"
e=$(newid); put "$e" "$(req "$e" push)"; gr once
assert_eq "and the next one is handed over (nothing marked as handed)" "$e" "$(tail -n1 "$S/bin/notify.log")"
gr deny "$d"; gr deny "$e"
# Requests left waiting by the sections above are decided, so only this section's count.
gr list; for w in $(printf '%s\n' "$OUT" | awk 'NR > 1 {print $1}'); do gr deny "$w"; done
# The agent also takes requests from the list (after each decision, and when it starts): the one
# it runs `prompt` for is the one it is asking about, so nothing is typed in until it is decided.
: > "$S/bin/notify.log"
a=$(newid); put "$a" "$(req "$a" push)"; gr once
b=$(newid); put "$b" "$(req "$b" push)"; gr once
gr deny "$a"; gr prompt "$b"
assert_eq "prompt marks the request the agent is asking about" "$b" "$(cat "$REQ/work/notified")"
c=$(newid); put "$c" "$(req "$c" push)"; gr once
assert_eq "a request taken from the list and prompted holds the next one back (its Enter would answer the question)" \
    "$a" "$(paste -sd'|' "$S/bin/notify.log")"
assert_has "which is logged as waiting behind it" "$c waits behind $b" "$(cat "$REQ/work/requests.log")"
gr prompt "$(newid)"
assert_eq "prompt for a request that is not there marks nothing" "$b" "$(cat "$REQ/work/notified")"
gr deny "$b"
f=$(newid); put "$f" "$(req "$f" push)"; gr once
assert_eq "once that one is decided, the next new one is handed over" "$a|$f" "$(paste -sd'|' "$S/bin/notify.log")"
# A restart cannot know which waiting request, if any, Claude is asking about: all of them count.
: > "$S/bin/notify.log"; rm -f "$REQ/work/notified"
( cd "$REQ" && timeout 3 bash "$GR" watch >/dev/null 2>&1 ) || true
assert_eq "a restart marks every waiting request as possibly asked about" "$(printf '%s\n' "$c" "$f" | sort | paste -sd' ')" \
    "$(sort "$REQ/work/notified" | paste -sd' ')"
g=$(newid); put "$g" "$(req "$g" push)"; gr once
assert_eq "after a restart, a new request is not typed into a question that may be open" "" "$(cat "$S/bin/notify.log")"
gr deny "$c"; h=$(newid); put "$h" "$(req "$h" push)"; gr once
assert_eq "nor while any request waiting at the restart still waits" "" "$(cat "$S/bin/notify.log")"
gr deny "$f"; gr deny "$g"; gr deny "$h"
i=$(newid); put "$i" "$(req "$i" push)"; gr once
assert_eq "once those are decided, new requests are handed over again" "$i" "$(cat "$S/bin/notify.log")"
gr deny "$i"
( cd "$REQ" && timeout 3 bash "$GR" watch >/dev/null 2>&1 ) || true
assert_eq "a restart with nothing waiting clears the marker" no "$([ -e "$REQ/work/notified" ] && echo yes || echo no)"
unset AIDC_GIT_NOTIFY

echo ""
echo "=== an approval acts on the repo and commit the user saw ==="
feat_sha=$(git -C "$P" rev-parse feat)
reset_calls; id=$(newid); put "$id" "$(req "$id" push)"; gr once
gr show "$id"
assert_has "show names the GitHub repo recorded when the request was taken" "github:   o/r" "$OUT"
assert_has "and the branch's commit then" "commit:   $feat_sha" "$OUT"
gr prompt "$id"
assert_has "the git agent's prompt names both" "on GitHub repo o/r, commit $feat_sha" "$OUT"
git -C "$P" remote set-url origin https://github.com/evil/x
gr approve "$id"
assert_eq "origin changed after the request was taken: the approval runs nothing" "1|failed|" "$RC|$(state "$id")|$(calls)"
assert_has "and the result says why" "origin is now evil/x, not o/r as approved: nothing done" "$(jq -r .message "$REQ/results/$id.json")"
git -C "$P" remote set-url origin https://github.com/o/r
reset_calls; id=$(newid); put "$id" "$(req "$id" pr-create)"; gr once
git -C "$P" -c user.name=A -c user.email=a@example.com commit -q --allow-empty -m "Slipped in after the request"
gr approve "$id"
assert_eq "the branch moved after the request was taken: the approval pushes nothing" "1|failed|" "$RC|$(state "$id")|$(calls)"
assert_has "and the result says why" "feat moved since it was approved (approved ${feat_sha:0:12}" "$(jq -r .message "$REQ/results/$id.json")"
git -C "$P" reset -q --hard "$feat_sha"
reset_calls; id=$(newid); put "$id" "$(req "$id" push)"; gr once
jq 'del(.slug)' "$REQ/work/$id.json" > "$S/w.json" && cp "$S/w.json" "$REQ/work/$id.json"
gr approve "$id"
assert_eq "a request kept without its recorded repo (taken by an older watcher) is not run" "failed|" "$(state "$id")|$(calls)"
# The default base is read with gitctl's own agent-side git, which keeps the system config (in
# the git container, /etc/gitconfig's safe.directory is what lets the agent read a working copy
# the session user owns). A git on PATH records how the watcher calls it.
mkdir -p "$S/gitwrap"
printf '#!/bin/sh
case " $* " in *" symbolic-ref "*) echo "NOSYSTEM=${GIT_CONFIG_NOSYSTEM:-unset} HOME=${HOME:-unset}" >> "%s/gitwrap.log" ;; esac
exec "%s" "$@"
' \
    "$S" "$(command -v git)" > "$S/gitwrap/git"; chmod +x "$S/gitwrap/git"
reset_calls; : > "$S/gitwrap.log"; id=$(newid); put "$id" "$(req "$id" pr-create '{"base":""}')"
OUT=$(PATH="$S/gitwrap:$PATH" AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_has "no base in the request: origin's default (origin/HEAD) is the base" "pr-create $P feat main " "$(calls)"
assert_eq "read with the system config kept (no GIT_CONFIG_NOSYSTEM), as gitctl reads working copies" \
    "NOSYSTEM=unset HOME=$HOME" "$(sort -u "$S/gitwrap.log")"

echo ""
echo "=== every field is checked; a bad request is refused, never run ==="
bad() { # DESC JSON-PATCH (jq object merged in) [WANT-IN-MESSAGE]
    local id; id=$(newid); reset_calls
    put "$id" "$(req "$id" push "$2")"
    OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
    if [ "$(state "$id")" = failed ] && [ -z "$(calls)" ]; then pass "refused: $1"
    else fail "not refused: $1 ($(state "$id"); calls: $(calls))"; fi
    [ -z "${3:-}" ] || assert_has "  with the reason" "$3" "$(jq -r .message "$REQ/results/$id.json")"
}
bad "an unknown field" '{"command":"rm -rf /"}' "known"
bad "a field that is not text" '{"branch":["a"]}'
bad "another version" '{"version":2}'
bad "an id that is not its file's" '{"id":"00000000000000000000000000000000"}' "id"
bad "an unknown action" '{"action":"force-push"}' "action"
bad "a repo outside the user's disk" "{\"repo\":\"$S/home\"}" "repo"
bad "a repo path with .." "{\"repo\":\"$S/disk/proj/../proj\"}" "repo"
ln -s "$P" "$S/disk/proj-link"
bad "a repo reached through a symlink" "{\"repo\":\"$S/disk/proj-link\"}" "repo"
mkdir -p "$S/disk/notrepo"
bad "a folder that is not a working copy" "{\"repo\":\"$S/disk/notrepo\"}" "working copy"
git init -q "$S/disk/gl"; git -C "$S/disk/gl" remote add origin https://gitlab.com/o/r
bad "a working copy whose origin is not GitHub" "{\"repo\":\"$S/disk/gl\"}" "origin"
bad "a branch that reads as an option" '{"branch":"--upload-pack=x"}' "branch"
bad "a refspec as branch" '{"branch":"+feat:main"}' "branch"
bad "main" '{"branch":"main"}' "pull request merges"
bad "a branch the working copy does not have" '{"branch":"nosuch"}' "no local branch nosuch"
bad "a control character in the branch" '{"branch":"fe\u001bat"}' "control"
bad "a session name that is not one" '{"session":"../x"}' "session"
id=$(newid); reset_calls; put "$id" "$(req "$id" pr-create '{"title":"Fix","body":"Thanks. Co-Authored-By: Claude <noreply@anthropic.com>"}')"
OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "a body with AI attribution is refused before anything runs" "failed|" "$(state "$id")|$(calls)"
id=$(newid); reset_calls; put "$id" "$(req "$id" pr-create '{"title":"a\nb"}')"
OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "a two-line title is refused" "failed|" "$(state "$id")|$(calls)"
id=$(newid); reset_calls; put "$id" "$(req "$id" pr-merge '{"number":"12; rm -rf /"}')"
OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "a PR number that is not one is refused" "failed|" "$(state "$id")|$(calls)"
id=$(newid); reset_calls; put "$id" 'not json'
OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "a file that is not JSON is refused" "failed|" "$(state "$id")|$(calls)"
id=$(newid); reset_calls; printf 'SECRET-CONTENT\n' > "$S/home/secret"; ln -s "$S/home/secret" "$REQ/requests/$id.json"
OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "a symlink dropped in as a request is refused, and what it points at is not read into the result" \
    "failed|refused: not a plain file|SECRET-CONTENT" "$(state "$id")|$(jq -r .message "$REQ/results/$id.json")|$(cat "$S/home/secret")"
assert_not_has "  nor anywhere in the result" "SECRET" "$(cat "$REQ/results/$id.json")"
id=$(newid); reset_calls; head -c 300000 /dev/zero | tr '\0' ' ' > "$REQ/requests/$id.json"
OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "an oversized request is refused" "failed" "$(state "$id")"
reset_calls; printf '{}' > "$REQ/requests/not-an-id.json"; printf '{}' > "$REQ/requests/.abc.tmp"
gr once
assert_eq "files not named <32 hex>.json are left alone (a session's half-written temp file)" "yes yes" \
    "$([ -e "$REQ/requests/not-an-id.json" ] && echo yes) $([ -e "$REQ/requests/.abc.tmp" ] && echo yes)"
id=$(newid); put "$id" "$(req "$id" push)"; gr once
put "$id" "$(req "$id" push)"; reset_calls; OUT=$(AIDC_GIT_MODE=rules bash "$GR" once 2>&1)
assert_eq "a request reusing a known id is dropped, not run" "pending||no" \
    "$(state "$id")|$(calls)|$([ -e "$REQ/requests/$id.json" ] && echo yes || echo no)"

echo ""
echo "=== nothing piles up: 30 days, then gone; an interrupted run is said so ==="
old=$(newid); put "$old" "$(req "$old" push)"; gr once
touch -d '31 days ago' "$REQ/work/$old.json" "$REQ/results/$old.json"
orph=$(newid); printf '{}' > "$REQ/results/$orph.json"; touch -d '31 days ago' "$REQ/results/$orph.json"
printf '{}' > "$REQ/requests/.stale.tmp"; touch -d '31 days ago' "$REQ/requests/.stale.tmp"
fresh=$(newid); put "$fresh" "$(req "$fresh" push)"; gr once
assert_eq "a request and its result older than 30 days are deleted together" "no no" \
    "$([ -e "$REQ/work/$old.json" ] && echo yes || echo no) $([ -e "$REQ/results/$old.json" ] && echo yes || echo no)"
assert_eq "so are an old result alone and an old file left in requests/" "no no" \
    "$([ -e "$REQ/results/$orph.json" ] && echo yes || echo no) $([ -e "$REQ/requests/.stale.tmp" ] && echo yes || echo no)"
assert_eq "a fresh one is kept" pending "$(state "$fresh")"
head -c 1100000 /dev/zero | tr '\0' 'x' | fold -w 100 > "$REQ/work/requests.log"
gr once
assert_eq "the request log is trimmed to its last 2000 lines once it passes 1 MiB" yes \
    "$([ "$(wc -l < "$REQ/work/requests.log")" -le 2000 ] && [ "$(stat -c %s "$REQ/work/requests.log")" -lt 300000 ] && echo yes || echo no)"
jq '.state = "running"' "$REQ/results/$fresh.json" > "$S/r.json" && cp "$S/r.json" "$REQ/results/$fresh.json"
reset_calls
timeout 4 bash "$GR" watch >/dev/null 2>&1
assert_eq "a request left running when the watcher stopped is failed as interrupted, not run again" \
    "failed|interrupted (the git container restarted); ask again|" \
    "$(state "$fresh")|$(jq -r .message "$REQ/results/$fresh.json")|$(calls)"
# A crashed take or save leaves <id>.req or <id>.json.tmp in work/: swept after an hour. A request
# that waited 30 days is logged as expired when it goes.
w1=$(newid); w2=$(newid); printf x > "$REQ/work/$w1.req"; printf x > "$REQ/work/$w2.json.tmp"
w3=$(newid); printf x > "$REQ/work/$w3.req"
touch -d '2 hours ago' "$REQ/work/$w1.req" "$REQ/work/$w2.json.tmp"
exp=$(newid); put "$exp" "$(req "$exp" push)"; gr once
touch -d '31 days ago' "$REQ/work/$exp.json" "$REQ/results/$exp.json"
gr once
assert_eq "a crashed take's .req and a save's .json.tmp older than an hour are swept; a fresh one is kept" "no no yes" \
    "$([ -e "$REQ/work/$w1.req" ] && echo yes || echo no) $([ -e "$REQ/work/$w2.json.tmp" ] && echo yes || echo no) $([ -e "$REQ/work/$w3.req" ] && echo yes || echo no)"
rm -f "$REQ/work/$w3.req"
assert_has "a request that waited 30 days is logged as expired" "$exp expired: it waited 30 days" "$(cat "$REQ/work/requests.log")"
# A request folder the watcher refuses: it says why in its log (once per reason), never silently.
chmod 0775 "$REQ"
OUT=$( (timeout 3 bash "$GR" watch) 2>&1 >/dev/null )
chmod 0755 "$REQ"
assert_has "the watcher logs why it cannot use the request folder" "waiting for the request folder: ${REQ} is writable by others" "$OUT"
assert_eq "once, not every try" 1 "$(printf '%s\n' "$OUT" | grep -c 'writable by others')"

echo ""
echo "=== the session's gh stand-in ==="
cd "$P" || exit 1
ghs() { OUT=$(bash "$GH" "$@" 2>&1); RC=$?; }
OUT=$(env -u AIDC_GIT_REQUESTS bash "$GH" pr create --title T --body B 2>&1); RC=$?
assert_eq "on Docker (no request folder) it says no git container is set up, and fails" 1 "$RC"
assert_has "..." "no git container is set up" "$OUT"
OUT=$(AIDC_GIT_AGENT_UID=4242 bash "$GH" pr create --title T --body B 2>&1); RC=$?
assert_eq "a request folder that is not the git container's is not used" 1 "$RC"
assert_has "..." "is not the git container's" "$OUT"
ls "$REQ/requests" > "$S/before"
OUT=$(AIDC_GH_WAIT=1 bash "$GH" pr create --title "Add it" --body-file - <<<"From stdin." 2>&1); RC=$?
assert_eq "a request the git container has not taken (no watcher ran): said so, exit 1" 1 "$RC"
assert_has "never as waiting for approval, but as not taken, and where the user sees why" "has not taken request" "$OUT"
assert_not_has "..." "waiting for approval" "$OUT"
assert_has "with the request id and how to check it" "gh aidc request" "$OUT"
new=$(comm -13 "$S/before" <(ls "$REQ/requests") | head -1); nid="${new%.json}"
assert_eq "the request it wrote: the branch, base, title, body, repo and worktree, as data" \
    "pr-create|demo|$P|$P|feat|main|Add it|From stdin." \
    "$(jq -r '[.action, .session, .repo, .worktree, .branch, .base, .title, .body] | join("|")' "$REQ/requests/$new")"
assert_eq "the session cannot list the requests (no read on requests/ for the group)" 1730 "$(stat -c %a "$REQ/requests")"
assert_eq "a session with no token sends none" "" "$(jq -r '.token // ""' "$REQ/requests/$new")"
ls "$REQ/requests" > "$S/before"
OUT=$(AIDC_GIT_TOKEN="$(printf 'c%.0s' $(seq 64))" AIDC_GH_WAIT=1 bash "$GH" pr create --title "Add it" --body B 2>&1)
new2=$(comm -13 "$S/before" <(ls "$REQ/requests") | head -1)
assert_eq "a session's token goes with its request" "$(printf 'c%.0s' $(seq 64))" "$(jq -r '.token // ""' "$REQ/requests/$new2")"
rm -f -- "$REQ/requests/${new2:?}"
# Taken and held for the user (ask): that one is waiting for approval, exit 0.
export AIDC_GIT_TOKEN="$TOKD"
( sleep 1; bash "$GR" once >/dev/null 2>&1 ) &
OUT=$(AIDC_GH_WAIT=4 bash "$GH" aidc push 2>&1); RC=$?
wait
assert_eq "a request taken and held for the user: 'requested; waiting for approval', exit 0" 0 "$RC"
assert_has "..." "waiting for approval (request " "$OUT"
pid=$(printf '%s' "$OUT" | grep -Eo '[0-9a-f]{32}' | head -n1); gr deny "$pid"
# The watcher takes it (rules) while the stand-in waits: end to end.
( sleep 2; AIDC_GIT_MODE=rules bash "$GR" once >/dev/null 2>&1 ) &
reset_calls
OUT=$(AIDC_GH_WAIT=20 bash "$GH" pr create --title "Add it" --body "Body." 2>&1); RC=$?
wait
assert_eq "end to end in rules mode: the stand-in prints the PR URL, exit 0" "0|https://github.com/o/r/pull/12" "$RC|$(printf '%s\n' "$OUT" | head -n1)"
assert_eq "and the branch now tracks origin's, at the pushed commit (as git push -u leaves it)" \
    "origin|$(git rev-parse feat)" \
    "$(git config branch.feat.remote)|$(git rev-parse refs/remotes/origin/feat)"
( sleep 2; G_FAIL=pr-create AIDC_GIT_MODE=rules bash "$GR" once >/dev/null 2>&1 ) &
OUT=$(AIDC_GH_WAIT=20 bash "$GH" pr create --title "Add it" --body "Body." 2>&1); RC=$?
wait
assert_eq "a failed request: gh exits 1 with the git container's reason" 1 "$RC"
assert_has "..." "no GitHub login" "$OUT"
ghs pr create --title T --draft; assert_eq "--draft is refused clearly" 1 "$RC"; assert_has "..." "draft" "$OUT"
ghs pr create --title T --reviewer x; assert_eq "an unsupported flag is refused" 1 "$RC"; assert_has "..." "not available in an aidc session" "$OUT"
ghs pr create; assert_eq "no title and no --fill: refused (nothing prompts)" 1 "$RC"
ghs pr create --title $'a\nb'; assert_eq "a two-line title is refused here already" 1 "$RC"
ghs pr merge 12 --squash; assert_eq "squash merges are refused" 1 "$RC"; assert_has "..." "only merge commits" "$OUT"
ghs pr merge 12 --rebase; assert_eq "rebase merges are refused" 1 "$RC"
ghs issue list; assert_eq "other gh commands are refused, saying what works" 1 "$RC"; assert_has "..." "pr create" "$OUT"
ghs api user; assert_eq "gh api is refused" 1 "$RC"
( sleep 2; bash "$GR" once >/dev/null 2>&1 ) &
OUT=$(AIDC_GH_WAIT=20 bash "$GH" pr view 12 --json number,title -q '.title' 2>&1); RC=$?
wait
assert_eq "pr view --json --jq answers from the git container's read" "0|Add it" "$RC|$OUT"
( sleep 2; bash "$GR" once >/dev/null 2>&1 ) &
OUT=$(AIDC_GH_WAIT=20 bash "$GH" pr list --head feat --json number,state 2>&1); RC=$?
wait
assert_eq "pr list --head --json keeps only the fields asked for" '0|[{"number":12,"state":"OPEN"}]' "$RC|$(printf '%s' "$OUT" | jq -c .)"
ghs pr view 12 --json number,secretField; assert_eq "a --json field the git container does not read is refused" 1 "$RC"
OUT=$(AIDC_GH_WAIT=1 bash "$GH" pr view 12 2>&1); RC=$?
assert_eq "a read with no answer in time fails (the caller has no data)" 1 "$RC"
ghs repo view --json defaultBranchRef -q .defaultBranchRef.name
assert_eq "repo view answers from the working copy (origin/HEAD), no request" "0|main" "$RC|$OUT"
ghs pr status
assert_has "pr status lists this session's requests with their state" "pr-create" "$OUT"
ghs aidc request "$nid"
assert_has "gh aidc request <id> shows a request's result" "request $nid: " "$OUT"
ghs aidc request "../x"; assert_eq "an id that is not one is refused" 1 "$RC"
uid=$(newid); put "$uid" "$(req "$uid" push)"
ghs aidc request "$uid"
assert_has "a request still sitting untaken is said so, with where the user sees why" "not taken yet: the git container has not taken request $uid" "$OUT"
# gh pr status, for a request whose files are gone: the git container's 30-day sweep took
# both, so it is expired, not "sent, not taken yet" (only a request still in the folder is).
gst="$S/home/.local/state/aidc-gh"; mkdir -p "$gst"
printf 'push 2026-10-01T00:00:00Z feat\n' > "$gst/$uid"
ghs pr status
assert_has "pr status: a request still in the folder with no result is not taken yet" "$uid  push feat  sent, not taken yet" "$OUT"
rm -f "$REQ/requests/$uid.json"
ghs pr status
assert_has "pr status: one whose request and result are both gone is expired, honestly" "$uid  push feat  expired: no request or result is kept" "$OUT"
assert_not_has "  (never 'not taken' for it)" "$uid  push feat  sent, not taken yet" "$OUT"
ghs aidc request "$uid"
assert_has "gh aidc request says the same" "request $uid: expired" "$OUT"
# Sent moments ago, and taken: take() moves the request out of requests/ before it writes any
# result, so both are absent for a while. That is not expired: the session's own record says
# it was sent within the 30 days.
printf 'push %s feat\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$gst/$uid"
ghs pr status
assert_has "pr status: a request just taken, with no result yet, is taken and not answered" "$uid  push feat  taken, not answered yet" "$OUT"
assert_not_has "  (never 'expired' for it)" "$uid  push feat  expired" "$OUT"
ghs aidc request "$uid"
assert_has "gh aidc request says the same" "request $uid: taken, not answered yet" "$OUT"
printf 'push %s feat\n' "$(date -u -d '29 days ago' +%Y-%m-%dT%H:%M:%SZ)" > "$gst/$uid"
ghs aidc request "$uid"
assert_has "29 days after sending it is still not called expired" "request $uid: taken, not answered yet" "$OUT"
printf 'push %s feat\n' "$(date -u -d '31 days ago' +%Y-%m-%dT%H:%M:%SZ)" > "$gst/$uid"
ghs aidc request "$uid"
assert_has "31 days after, it is" "request $uid: expired" "$OUT"
rm -f "$gst/$uid"
ghs aidc request "$uid"
assert_has "with no record of sending it, neither is claimed" "request $uid: unknown: no request or result is there, and this session has no record of sending it" "$OUT"
mkdir -p "$S/elsewhere"; git init -q "$S/elsewhere"; git -C "$S/elsewhere" remote add origin https://gitlab.com/o/r
OUT=$(cd "$S/elsewhere" && bash "$GH" pr create --title T --body B 2>&1); RC=$?
assert_eq "a working copy whose origin is not GitHub is refused here" 1 "$RC"
git switch -q --detach
ghs aidc push; assert_eq "a detached HEAD needs a branch named" 1 "$RC"
git switch -q feat

echo ""
echo "=== the session image ==="
df=$(cat "$AIDC_ROOT/.devcontainer/Dockerfile")
assert_has "the stand-in is installed as gh" "COPY gh-standin.sh         /usr/local/bin/gh" "$df"
hook=$(AIDC_GIT_REQUESTS="$REQ" bash "$AIDC_ROOT/.devcontainer/pre-push-hook.sh" 2>&1); rc=$?
assert_eq "git push in a session still fails" 1 "$rc"
assert_has "and on Kubernetes says how to ask the git container instead" "gh pr create" "$hook"
# The image's system config, as its Dockerfile writes it, with the helper on PATH.
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$AIDC_ROOT/.devcontainer/git-remote-aidc.sh" > "$S/bin/git-remote-aidc"; chmod +x "$S/bin/git-remote-aidc"
: > "$S/sysgit"
grep -o 'git config --system --add url[^\\&]*' "$AIDC_ROOT/.devcontainer/Dockerfile" | while read -r cmd; do
    eval "GIT_CONFIG_SYSTEM=\"\$S/sysgit\" $cmd"
done
assert_eq "the image rewrites GitHub push URLs (https, git@, ssh://) to the aidc helper" 3 "$(grep -c pushInsteadOf "$S/sysgit")"
OUT=$(cd "$P" && PATH="$S/bin:$PATH" GIT_CONFIG_SYSTEM="$S/sysgit" GIT_TERMINAL_PROMPT=0 \
    timeout 20 git push origin feat 2>&1); rc=$?
assert_eq "git push to GitHub in a session fails at once, without contacting GitHub" "failed no" \
    "$([ "$rc" != 0 ] && echo failed || echo ok) $(printf '%s' "$OUT" | grep -qi 'could not\|username\|resolve' && echo yes || echo no)"
assert_has "and explains the request flow on Kubernetes" "gh pr create" "$OUT"
OUT=$(cd "$P" && env -u AIDC_GIT_REQUESTS PATH="$S/bin:$PATH" GIT_CONFIG_SYSTEM="$S/sysgit" timeout 20 git push origin feat 2>&1)
assert_has "or, on Docker, to push from the host" "push from the host machine" "$OUT"
assert_eq "fetch URLs are not rewritten" "https://github.com/o/r" \
    "$(cd "$P" && GIT_CONFIG_SYSTEM="$S/sysgit" git remote get-url origin)"
um=$(grep -n 'umask 002' "$AIDC_ROOT/.devcontainer/user-main.sh")
assert_has "sessions on Kubernetes make group-writable files (the git container tidies them)" '[ "${AIDC_BACKEND:-}" = kubernetes ] && umask 002' "$um"
assert_eq "set before tmux and Claude start (they inherit it)" yes \
    "$([ "${um%%:*}" -lt "$(grep -n 'aidc-tmux-start.sh ||' "$AIDC_ROOT/.devcontainer/user-main.sh" | cut -d: -f1)" ] && echo yes || echo no)"

echo ""
echo "=== approve and deny race: exactly one happens, and each says what it did ==="
# The hooks (run from a checkout only) run a command at a point in approve: before it takes the
# request's lock, or once it holds it.
printf '#!/bin/sh\nbash "%s" deny "$1" "changed my mind" > "%s/race.out" 2>&1; echo "rc=$?" >> "%s/race.out"\n' "$GR" "$S" "$S" > "$S/bin/deny-now"
chmod +x "$S/bin/deny-now"
id=$(newid); put "$id" "$(req "$id" push)"; gr once; reset_calls
OUT=$(AIDC_GITREQ_TEST_BEFORE_LOCK="$S/bin/deny-now" bash "$GR" approve "$id" 2>&1); RC=$?
assert_eq "a deny that lands first: the request is denied, and nothing is pushed" "denied|" "$(state "$id")|$(calls)"
assert_has "the deny says it denied" "denied $id" "$(cat "$S/race.out")"
assert_eq "the approval fails" 1 "$RC"
assert_has "saying it did not approve, and why" "was not approved: it is denied now" "$OUT"
id=$(newid); put "$id" "$(req "$id" push)"; gr once; reset_calls
OUT=$(AIDC_GITREQ_TEST_AFTER_LOCK="$S/bin/deny-now" bash "$GR" approve "$id" 2>&1); RC=$?
assert_eq "a deny that lands while the approval holds the request: the push runs, and the request is done" "0|done" "$RC|$(state "$id")"
assert_has "..." "push $P feat" "$(calls)"
assert_has "the deny says it did not deny" "being approved or run now: not denied" "$(cat "$S/race.out")"
assert_has "and fails" "rc=1" "$(cat "$S/race.out")"
id=$(newid); put "$id" "$(req "$id" push)"; gr once; reset_calls
printf '#!/bin/sh\nbash "%s" approve "$1" > "%s/race.out" 2>&1; echo "rc=$?" >> "%s/race.out"\n' "$GR" "$S" "$S" > "$S/bin/approve-now"
chmod +x "$S/bin/approve-now"
OUT=$(AIDC_GITREQ_TEST_AFTER_LOCK="$S/bin/approve-now" bash "$GR" approve "$id" 2>&1); RC=$?
assert_eq "two approvals at once: the push runs once" "0|1" "$RC|$(calls | grep -c '^push ')"
assert_has "the second says it did not run it" "rc=1" "$(cat "$S/race.out")"
id=$(newid); put "$id" "$(req "$id" push)"; gr once; reset_calls
mkdir "$REQ/work/$id.lock"; touch -d '10 minutes ago' "$REQ/work/$id.lock"
gr deny "$id"
assert_eq "a lock left by a killed approver on a pending request (older than 5 minutes) does not block it forever" "0|denied" "$RC|$(state "$id")"

echo ""
echo "=== removing a guard is caught (these tests are not vacuous) ==="
cp "$GR" "$S/mut.sh"; cp "$AIDC_ROOT/gitctl/gitctl-rules.sh" "$S/"
sed -i 's/if \[ "\$Q_mode" = rules \]; then run "\$id"/if :; then run "$id"/' "$S/mut.sh"
id=$(newid); put "$id" "$(req "$id" push)"; reset_calls
bash "$S/mut.sh" once >/dev/null 2>&1
assert_eq "with the ask-mode hold removed, a push runs without approval (so the ask test would fail)" "done" "$(state "$id")"
cp "$GR" "$S/mut.sh"; sed -i 's/if \[ -L "work\/\${id}.req" \] || \[ ! -f "work\/\${id}.req" \]; then/if false; then/' "$S/mut.sh"
id=$(newid); ln -s "$S/home/secret" "$REQ/requests/$id.json"
AIDC_GIT_MODE=rules bash "$S/mut.sh" once >/dev/null 2>&1
assert_eq "with the symlink check removed, the symlink is followed (so the symlink test would fail)" yes \
    "$(grep -q SECRET "$REQ/results/$id.json" 2>/dev/null || [ "$(jq -r .message "$REQ/results/$id.json")" != "refused: not a plain file" ] && echo yes || echo no)"
cp "$GR" "$S/mut.sh"; sed -i 's/\[ "\$h" = "\$(sha256 "\$2")" \] || { printf ask; return; }/:/' "$S/mut.sh"
grep -q 'printf ask; return; }$' "$S/mut.sh" && grep -q '^    :$' "$S/mut.sh" || fail "mutation did not apply (token hash)"
printf '%s\n' "$TOK" | bash "$GR" mode demo rules >/dev/null 2>&1
id=$(newid); put "$id" "$(req "$id" push "{\"token\":\"$OTHER\"}")"; reset_calls
bash "$S/mut.sh" once >/dev/null 2>&1
assert_eq "with the token's hash check removed, another token takes the session's mode (so the token test would fail)" "done" "$(state "$id")"
printf '%s\n' "$TOKD" | bash "$GR" mode demo default >/dev/null 2>&1
cp "$GR" "$S/mut.sh"; sed -i 's/if ! bound; then/if false; then/' "$S/mut.sh"
id=$(newid); put "$id" "$(req "$id" push)"; bash "$S/mut.sh" once >/dev/null 2>&1
git -C "$P" remote set-url origin https://github.com/evil/x; reset_calls
bash "$S/mut.sh" approve "$id" >/dev/null 2>&1
git -C "$P" remote set-url origin https://github.com/o/r
assert_has "with the watcher's run-time binding check removed, the approval reaches gitctl (so the binding test would fail without gitctl's own check)" \
    "push $P feat" "$(calls)"

cp "$GR" "$S/mut.sh"
sed -i 's/if waiting "\$1"; then mark_open "\$1"; fi/:/' "$S/mut.sh"
grep -q 'if waiting "$1"; then mark_open "$1"; fi' "$S/mut.sh" && fail "mutation did not apply (prompt's marker)"
export AIDC_GIT_NOTIFY="$S/bin/notify"; : > "$S/bin/notify.log"; rm -f "$REQ/work/notified"
a=$(newid); put "$a" "$(req "$a" push)"; bash "$S/mut.sh" once >/dev/null 2>&1
b=$(newid); put "$b" "$(req "$b" push)"; bash "$S/mut.sh" once >/dev/null 2>&1
bash "$S/mut.sh" deny "$a" >/dev/null 2>&1; bash "$S/mut.sh" prompt "$b" >/dev/null 2>&1
c=$(newid); put "$c" "$(req "$c" push)"; bash "$S/mut.sh" once >/dev/null 2>&1
assert_eq "with prompt's marker removed, a request is typed into the open question (so the prompt test would fail)" \
    "$a|$c" "$(paste -sd'|' "$S/bin/notify.log")"
bash "$GR" deny "$b" >/dev/null 2>&1; bash "$GR" deny "$c" >/dev/null 2>&1
cp "$GR" "$S/mut.sh"
sed -i 's/if \[ "\${#waits\[@\]}" -gt 0 \]; then mark_open "\${waits\[@\]}"; else rm -f work\/notified; fi/rm -f work\/notified/' "$S/mut.sh"
grep -q 'mark_open "${waits' "$S/mut.sh" && fail "mutation did not apply (restart's marker)"
: > "$S/bin/notify.log"
a=$(newid); put "$a" "$(req "$a" push)"; bash "$S/mut.sh" once >/dev/null 2>&1
( cd "$REQ" && timeout 3 bash "$S/mut.sh" watch >/dev/null 2>&1 ) || true
b=$(newid); put "$b" "$(req "$b" push)"; bash "$S/mut.sh" once >/dev/null 2>&1
assert_eq "with the restart's marker removed, a new request is typed in after a restart (so the restart test would fail)" \
    "$a|$b" "$(paste -sd'|' "$S/bin/notify.log")"
bash "$GR" deny "$a" >/dev/null 2>&1; bash "$GR" deny "$b" >/dev/null 2>&1
unset AIDC_GIT_NOTIFY

cp "$GR" "$S/mut.sh"; sed -i 's/    if \[ "\$now_state" != "\$want" \]; then/    if false; then/' "$S/mut.sh"
grep -q 'if false; then' "$S/mut.sh" || fail "mutation did not apply (state re-check)"
reset_calls; id=$(newid); put "$id" "$(req "$id" push)"; gr once
AIDC_GITREQ_TEST_BEFORE_LOCK="$S/bin/deny-now" bash "$S/mut.sh" approve "$id" >/dev/null 2>&1
assert_has "with the state re-check under the lock removed, a denied request is pushed (so the race test would fail)" "push $P feat" "$(calls)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
