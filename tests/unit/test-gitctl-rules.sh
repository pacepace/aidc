#!/usr/bin/env bash
# Unit tests for the git container's hard rules: gitctl (gitctl/gitctl.sh), the only way to the
# GitHub login, its shared rules (gitctl/gitctl-rules.sh) and Claude Code's PreToolUse hook.
#
# The agent holds no credential; gitctl's verbs are the only things that push, open, comment on
# or merge a pull request, so a verb that lets a caller's text through as an option, pushes an
# attributed or forced commit, trusts a ref a session can move, or reads a file as gitcred
# breaks the owner's rules on GitHub or hands out the token. gitrun never runs git in a working
# copy: commits travel as bundles between it and its private copy, so a bundle it would take
# from a path, leave behind, or import without the checks, and config planted in a working copy
# that ran on gitctl's steps, are tested too. Each refusal is checked against the real outcome:
# the forge's refs for pushes (real git, a folder of bare repos standing in for GitHub), and a
# stub gh that records what it was asked to run. The last section removes guards and shows
# these tests notice.
#
# Run from a checkout, gitctl skips sudo (the role is named in AIDC_GITCTL_ROLE) and takes the
# stand-in forge, gitrun's store, the bundle folder and the mount list from
# AIDC_GITCTL_TEST_FORGE, AIDC_GITCTL_RUN_STORE, AIDC_GITCTL_BUNDLE_DIR and
# AIDC_GITCTL_MOUNTINFO; installed, it ignores them. Needs jq.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).
#
# Single quotes hold text that is checked, not run (SC2016).
# shellcheck disable=SC2016

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GITCTL="$AIDC_ROOT/gitctl"
S="$AIDC_ROOT/tests/scratch/gitctl-rules-$$"
PASS=0
FAIL=0
trap 'rm -rf "$S"' EXIT INT TERM
umask 022
mkdir -p "$S/bin"

if ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq not installed"; exit 0; fi

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
assert_has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in: $(printf '%s' "$3" | tail -3))" ;; esac; }

# Stub gh: logs each call (%q words) to calls.log; answers `pr view --json` from prview.json and
# `auth status` from authstatus.rc / authstatus.out.
cat > "$S/bin/gh" <<'STUB'
#!/usr/bin/env bash
d=$(dirname "$0")
{ printf '%q ' "$@"; echo; } >> "$d/calls.log"
case "$1 $2" in
    "pr view") case " $* " in *" --json "*) cat "$d/prview.json"; exit 0 ;; esac ;;
    "auth status") cat "$d/authstatus.out" 2>/dev/null; exit "$(cat "$d/authstatus.rc" 2>/dev/null || echo 0)" ;;
    "auth login") exit "$(cat "$d/login.rc" 2>/dev/null || echo 0)" ;;
esac
# gh api <path>: the answer in api/<path, / as _>, or its .err text and a failure.
if [ "$1" = api ]; then
    shift
    while [ $# -gt 0 ]; do case "$1" in --method|-F|--input) shift 2 ;; -*) shift ;; *) break ;; esac; done
    f="$d/api/$(printf '%s' "$1" | tr / _)"
    [ -e "$f" ] && { cat "$f"; exit 0; }
    cat "$f.err" 2>/dev/null || echo "gh: Not Found (HTTP 404)"
    exit 1
fi
exit 0
STUB
chmod +x "$S/bin/gh"
AIDC_GITCTL_REAL_GIT=$(command -v git)
export AIDC_GITCTL_REAL_GH="$S/bin/gh" AIDC_GITCTL_REAL_GIT
unset AIDC_GITCTL_ROLE AIDC_GITCTL_TEST_FORGE
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# gitcred's home (its login, identity and action log): a folder of the test's, never the tester's.
CRED="$S/cred"; mkdir -p "$CRED"; export AIDC_GITCTL_CRED_HOME="$CRED"
G() { git -c user.name=Someone -c user.email=someone@example.com -c init.defaultBranch=main "$@"; }

ctl() { : > "$S/bin/calls.log"; OUT=$(bash "$GITCTL/gitctl.sh" "$@" 2>&1); RC=$?; CALLS=$(cat "$S/bin/calls.log"); }
ctl_in() { local in="$1"; shift; : > "$S/bin/calls.log"; OUT=$(printf '%s' "$in" | bash "$GITCTL/gitctl.sh" "$@" 2>&1); RC=$?; CALLS=$(cat "$S/bin/calls.log"); }
refused() { # DESC (after ctl): refused with a reason, and gh never ran
    if [ "$RC" != 0 ] && [ -z "$CALLS" ]; then
        case "$OUT" in *"gitctl: refused:"*) pass "$1" ;; *) fail "$1 (no refusal line: $OUT)" ;; esac
    else fail "$1 (rc=$RC; gh ran: ${CALLS:-nothing}; out: $OUT)"; fi
}

echo "=== attribution, anywhere in the text ==="
# shellcheck source=gitctl/gitctl-rules.sh
. "$GITCTL/gitctl-rules.sh"
for t in "Co-Authored-By: Claude <noreply@anthropic.com>" \
         "Thanks for the review. Co-Authored-By: Claude Opus" \
         "co-authored-by: GitHub Copilot <copilot@github.com>" \
         "Signed-off-by: Claude <noreply@anthropic.com>" \
         "Generated with [Claude Code](https://claude.com/claude-code)" \
         "see: made by ChatGPT" \
         $'Fix it \360\237\244\226' \
         "https://claude.ai/code/session_x"; do
    if gitctl_attribution "$t"; then pass "attribution: $t"; else fail "attribution missed: $t"; fi
done
for t in "Fix the Claude Code transcript reader" "Signed-off-by: A Person <a@example.com>" \
         "We made the change with care" "Build Claude Code into the git image"; do
    if gitctl_attribution "$t"; then fail "a false hit: $t"; else pass "not attribution: $t"; fi
done


echo "=== attribution in files: by shape (a trailer, a Generated-with footer) ==="
# The lines a push adds to files are checked by shape, so a file may state the policy, credit a
# person or link to Claude Code. Attribution text is built from parts, so this file adds none.
CAB="Co-Authored""-By:" SOB="Signed""-off-by:" GW="Generated"" with" ROB=$(printf '\360\237\244\226')
fscan() { gitctl_file_attribution_stream < <(printf '%s\n' "$1"); }
for t in "$CAB Cla""ude <noreply@anthropic.com>" \
         "    # ${CAB,,} GitHub Copi""lot <copilot@github.com>" \
         "$SOB cla""ude-bot <x@example.com>" \
         "// $CAB Cody <cody@sourcegraph.com>" \
         "$CAB Devin AI <158243242+devin-ai-integration[bot]@users.noreply.github.com>" \
         "co-authored-by:Someone <noreply@open""ai.com>" \
         "$ROB $GW [Cla""ude Code](https://example.invalid/x)" \
         "$GW Cla""ude Code" \
         "<!-- $GW [Cla""ude Code](https://example.invalid/x) -->" \
         "> $ROB $GW Cla""ude Code" \
         "<!-- Generated by GitHub Copi""lot -->" \
         "$GW Cla""ude Code."; do
    if fscan "$t"; then pass "file attribution refused: $t"; else fail "file attribution missed: $t"; fi
done
for t in "- **No \`${CAB}\` trailers** naming Claude, Anthropic, or any AI tool in" \
         "- No AI attribution anywhere: no \`${CAB%:}\` naming an AI, no \"Generated with\" lines, no" \
         "- **No \"$GW …\" / \"Created with …\" footers** in pull request bodies," \
         "$CAB Cody Jones <cody@example.com>" \
         "$SOB Devin Smith <devin@example.org>" \
         "$CAB Aider Lee <aider.lee@example.net>" \
         "Read more at https://claude.ai/code and [the docs](https://claude.com/claude-code)" \
         "done $ROB" \
         "We made the change with care, as Claude Code's docs suggest" \
         "                # Written by Claude Code on the user's behalf (hook feedback, skill" \
         "$GW Cla""ude Code in mind, the parser keeps every field"; do
    if fscan "$t"; then fail "a false hit in a file: $t (${GITCTL_HIT})"; else pass "not file attribution: $t"; fi
done
# The policy prose this project and the git agent are given, and the guard's own comments, pass
# whole: the scan must never refuse the files that state the rule.
for f in "$AIDC_ROOT/CLAUDE.md" "$GITCTL/CLAUDE.md" "$GITCTL/gitctl-rules.sh" "$GITCTL/gitctl-run.sh" \
         "$AIDC_ROOT/mcp/src/aidc_mcp/transcript.py"; do
    if gitctl_file_attribution_stream < "$f"; then fail "${f#"$AIDC_ROOT"/} is refused (${GITCTL_HIT})"; else pass "${f#"$AIDC_ROOT"/} passes whole"; fi
done

echo ""
echo "=== push: a folder of bare repos stands in for GitHub ==="
# gitrun keeps its private copies in a store only it can enter; the agent's bundles go in their
# own folder. Run from a checkout, gitctl takes all three from the environment.
F="$S/forge" R="$S/forge/o/r.git" W="$S/work" STORE="$S/store" BUNDLES="$S/bundles"
mkdir -p "$S/forge/o"; mkdir -m 0700 "$STORE"
export AIDC_GITCTL_TEST_FORGE="$F" AIDC_GITCTL_RUN_STORE="$STORE" AIDC_GITCTL_BUNDLE_DIR="$BUNDLES"
G init -q --bare "$R"
G clone -q "$R" "$W" 2>/dev/null
G -C "$W" commit -q --allow-empty -m "first"
G -C "$W" push -q origin HEAD:main 2>/dev/null
# The user adds the repo: aidc repo add, on the laptop, puts it on the list of added repos
# (mounted read-only in the git container; here a file the test writes, AIDC_GITCTL_ADDED_LIST),
# then gitctl clone gives gitrun its private copy. gitctl reaches GitHub for no repo off the list.
LIST="$S/added-repos"; export AIDC_GITCTL_ADDED_LIST="$LIST"
list_add() { printf '%s\n' "$1" >> "$LIST"; }
list_del() { { grep -vixF -- "$1" "$LIST" || true; } > "$LIST.tmp"; mv -f "$LIST.tmp" "$LIST"; }
list_add o/r
mkdir -p "$S/added"; ctl clone o/r "$S/added"
assert_eq "the user adds o/r: gitrun now holds its private copy" "0 yes" "$RC $([ -d "$STORE/o/r.git" ] && echo yes || echo no)"
G -C "$W" switch -q -c feature
G -C "$W" commit -q --allow-empty -m "Add the thing"
remote_sha() { git -C "$R" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || echo none; }

ctl push "$W" feature
assert_eq "a clean branch is pushed" "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
G -C "$W" commit -q --allow-empty -m "More of the thing"
ctl push "$W" feature
assert_eq "a fast-forward is pushed" "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
before=$(remote_sha feature)

G -C "$W" commit -q --allow-empty -m "Fix it" -m "Thanks. Co-Authored-By: Claude <noreply@anthropic.com>"
ctl push "$W" feature
assert_eq "a commit with attribution mid-line is not pushed" "$before" "$(remote_sha feature)"
assert_has "and the reason names the commit" "carries AI attribution" "$OUT"
G -C "$W" reset -q --hard HEAD~1

G -C "$W" switch -q -c fake main
G -C "$W" commit -q --allow-empty -m "x" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git -C "$W" update-ref refs/remotes/origin/fake HEAD
ctl push "$W" fake
assert_eq "a planted refs/remotes/origin/* does not hide an attributed commit (origin is asked)" none "$(remote_sha fake)"

ct=$(printf 'x\n\nGenerated with Claude Code\n' | G -C "$W" commit-tree "main^{tree}" -p main)
git -C "$W" update-ref refs/heads/ct "$ct"
ctl push "$W" ct
assert_eq "a commit made with commit-tree is scanned like any other" none "$(remote_sha ct)"

G -C "$W" switch -q -c bot main
git -C "$W" -c user.name=Claude -c user.email=noreply@anthropic.com commit -q --allow-empty -m "Plain message"
ctl push "$W" bot
assert_eq "a commit authored as an AI tool is not pushed" none "$(remote_sha bot)"

G -C "$W" switch -q main
G -C "$W" commit -q --allow-empty -m "Straight to main"
ctl push "$W" main
assert_eq "pushing to main directly is refused (main changes by PR merges)" "$(git -C "$R" rev-parse main)" "$(remote_sha main)"
assert_has "with the reason" "pull request merges" "$OUT"
G -C "$W" reset -q --hard HEAD~1

G -C "$W" switch -q feature
G -C "$W" reset -q --hard HEAD~1
G -C "$W" commit -q --allow-empty -m "Diverged"
ctl push "$W" feature
assert_eq "a branch that is not a fast-forward of origin's is not pushed (never force)" "$before" "$(remote_sha feature)"
assert_has "with the reason" "not a fast-forward" "$OUT"
G -C "$W" reset -q --hard "$before"

G -C "$W" tag -a v1 -m "A tag"
G -C "$W" commit -q --allow-empty -m "Again"
ctl push "$W" feature
assert_eq "the push still works" "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
assert_eq "and never carries tags" "" "$(git -C "$R" tag)"

# No attribution in code or docs: the lines each pushed commit adds are scanned too. The test
# builds such text from parts, so this file adds none of its own.
TRAILER="Co-Authored""-By: Cla""ude <noreply@example.com>"
ROBOT=$(printf '\360\237\244\226')
G -C "$W" switch -q -c diffscan main
printf 'notes\n%s\n' "$TRAILER" > "$W/NOTES.md"; G -C "$W" add NOTES.md; G -C "$W" commit -q -m "Add notes"
ctl push "$W" diffscan
assert_eq "a commit adding a file line with an attribution trailer is not pushed" none "$(remote_sha diffscan)"
assert_has "and the reason says it is in a file" "adds AI attribution to a file" "$OUT"
G -C "$W" reset -q --hard main
printf 'notes\n%s %s [Cla%s Code](https://example.invalid/x)\n' "$ROBOT" "Generated with" "ude" > "$W/STATUS.txt"; G -C "$W" add STATUS.txt; G -C "$W" commit -q -m "Add status"
ctl push "$W" diffscan
assert_eq "a file line that is the robot-emoji Generated-with footer is not pushed either" none "$(remote_sha diffscan)"
G -C "$W" switch -q -c policy main
sed -n '9p' "$AIDC_ROOT/CLAUDE.md" > "$W/POLICY.md"; sed -n '/No AI attribution anywhere/,+1p' "$GITCTL/CLAUDE.md" >> "$W/POLICY.md"
printf 'done %s\n' "$ROBOT" >> "$W/POLICY.md"
G -C "$W" add POLICY.md; G -C "$W" commit -q -m "State the policy"
ctl push "$W" policy
assert_eq "a commit adding this repo's own no-attribution policy lines (and a bare emoji) is pushed" "$(git -C "$W" rev-parse policy)" "$(remote_sha policy)"
assert_has "(it holds CLAUDE.md's trailer policy line)" "trailers" "$(cat "$W/POLICY.md")"
printf 'one more\n' > "$W/MORE.md"; G -C "$W" add MORE.md; G -C "$W" commit -q -m "More"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = diff-tree ] && { echo "fatal: unable to read tree" >&2; exit 128; }; done\nexec %s "$@"\n' \
    "$AIDC_GITCTL_REAL_GIT" > "$S/bin/git-nodiff"; chmod +x "$S/bin/git-nodiff"
OUT=$(AIDC_GITCTL_REAL_GIT="$S/bin/git-nodiff" bash "$GITCTL/gitctl.sh" push "$W" policy 2>&1); RC=$?
assert_eq "a diff that cannot be read refuses the push (fail closed)" "$(git -C "$W" rev-parse 'policy^')" "$(remote_sha policy)"
assert_has "saying why" "cannot be checked for attribution (git diff-tree: fatal: unable to read tree); nothing was pushed" "$OUT"
G -C "$W" switch -q diffscan
G -C "$W" reset -q --hard main
printf 'Fix the Claude Code transcript reader\n' > "$W/CHANGES.md"; G -C "$W" add CHANGES.md; G -C "$W" commit -q -m "Changes"
ctl push "$W" diffscan
assert_eq "a file that only talks about Claude is pushed" "$(git -C "$W" rev-parse diffscan)" "$(remote_sha diffscan)"
# On origin already (pushed some other way): moving it, or merging origin's branch in, adds none
# of its lines; a merge that writes one itself does.
O2="$S/elsewhere2"; G clone -q "$R" "$O2" 2>/dev/null; G -C "$O2" switch -q main
printf 'fixture\n%s\n' "$TRAILER" > "$O2/fixture.txt"; G -C "$O2" add fixture.txt; G -C "$O2" commit -q -m "A fixture"
G -C "$O2" push -q origin main 2>/dev/null
ctl fetch "$W"
G -C "$W" switch -q -c moved origin/main
G -C "$W" mv fixture.txt fixture-moved.txt; G -C "$W" commit -q -m "Move the fixture"
ctl push "$W" moved
assert_eq "a commit that only moves a file holding such a line is pushed (rename)" "$(git -C "$W" rev-parse moved)" "$(remote_sha moved)"
G -C "$W" switch -q diffscan
G -C "$W" merge -q --no-ff --no-edit origin/main
ctl push "$W" diffscan
assert_eq "a merge bringing in origin's lines is pushed (they are not the merge's own)" "$(git -C "$W" rev-parse diffscan)" "$(remote_sha diffscan)"
G -C "$W" switch -q -c evil "$(git -C "$W" rev-parse 'diffscan^1')"
G -C "$W" merge -q --no-ff --no-commit origin/main 2>/dev/null
printf 'merged\n%s\n' "$TRAILER" > "$W/MERGE.md"; G -C "$W" add MERGE.md; G -C "$W" commit -q --no-edit
ctl push "$W" evil
assert_eq "a merge that writes such a line itself is not pushed" none "$(remote_sha evil)"
G -C "$W" switch -q feature

# gitrun packs its private copies itself (git gc --auto at each verb; git's own automatic
# maintenance is off): loose objects a fetch left are packed, so a copy does not grow file by
# file. The copy's own config (gitrun's) here unpacks every fetch and asks for gc at once.
O3="$S/elsewhere3"; G clone -q "$R" "$O3" 2>/dev/null; G -C "$O3" switch -q main
mkdir -p "$O3/many"; for i in $(seq 600); do printf '%s\n' "$i" > "$O3/many/f$i"; done
G -C "$O3" add many; G -C "$O3" commit -q -m "Many files"; G -C "$O3" push -q origin main 2>/dev/null
git --git-dir="$STORE/o/r.git" config fetch.unpackLimit 100000
git --git-dir="$STORE/o/r.git" config gc.auto 1
loose() { find "$STORE/o/r.git/objects" -path '*/objects/[0-9a-f][0-9a-f]/*' -type f | wc -l | tr -d ' '; }
ctl fetch "$W"
for _ in $(seq 50); do [ "$(loose)" -lt 10 ] && break; sleep 0.2; done
assert_eq "gitrun's gc packs the loose objects a fetch left in its private copy" "0 yes" \
    "$RC $([ "$(loose)" -lt 10 ] && echo yes || echo "no: $(loose) loose")"
git --git-dir="$STORE/o/r.git" config --unset fetch.unpackLimit; git --git-dir="$STORE/o/r.git" config --unset gc.auto

# The working copy is anyone's in the session group: config planted there runs nothing on
# gitctl's steps (the agent's bundle and import pin hooks and fsmonitor off), and gitrun never
# runs git in it at all.
G -C "$W" commit -q --allow-empty -m "Before the hostile config"
mkdir -p "$S/evil-hooks"
for h in reference-transaction post-checkout post-merge pre-push pre-auto-gc; do
    printf '#!/bin/sh\ntouch "%s/PWNED-hook"\n' "$S" > "$S/evil-hooks/$h"; chmod +x "$S/evil-hooks/$h"
done
cp "$S/evil-hooks/"* "$W/.git/hooks/" 2>/dev/null || { mkdir -p "$W/.git/hooks"; cp "$S/evil-hooks/"* "$W/.git/hooks/"; }
git -C "$W" config core.hooksPath "$S/evil-hooks"
git -C "$W" config core.fsmonitor "touch $S/PWNED-fsmonitor"
git -C "$W" config remote.origin.uploadpack "touch $S/PWNED-uploadpack"
git -C "$W" config remote.origin.receivepack "touch $S/PWNED-receivepack"
git -C "$W" config core.sshCommand "touch $S/PWNED-ssh"
git -C "$W" config gc.auto 1
ctl push "$W" feature
assert_eq "a working copy with hostile config still pushes" "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
ctl fetch "$W"
assert_eq "and fetches" 0 "$RC"
assert_eq "and nothing planted in it ran" "" "$(find "$S" -maxdepth 1 -name 'PWNED*')"
for k in core.hooksPath core.fsmonitor remote.origin.uploadpack remote.origin.receivepack core.sshCommand gc.auto; do
    git -C "$W" config --unset "$k"
done
rm -f "$W/.git/hooks/"*

# Replace refs change what git log shows, not what a push sends.
G -C "$W" switch -q -c rp feature
G -C "$W" commit -q --allow-empty -m "Fix" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
clean=$(printf 'Fix\n' | G -C "$W" commit-tree "rp^{tree}" -p rp~1)
git -C "$W" replace rp "$clean"
ctl push "$W" rp
assert_eq "a replace ref cannot hide an attributed commit from the scan" none "$(remote_sha rp)"
git -C "$W" replace -d "$(git --no-replace-objects -C "$W" rev-parse rp)"

# A message carrying the bytes a one-stream log would be split on.
sep=$(printf 'Fix\036x\037Co-Authored-By: Claude\037clean\n' | G -C "$W" commit-tree "feature^{tree}" -p feature)
git -C "$W" update-ref refs/heads/sep "$sep"
ctl push "$W" sep
assert_eq "record-separator bytes in a message do not hide attribution" none "$(remote_sha sep)"
G -C "$W" switch -q feature

for b in -f +feature feature:main --force "a..b" "--upload-pa=x" "--templ=x" "--conf=x" "--outp=x" "--exe=x"; do
    ctl push "$W" "$b"
    if [ "$RC" != 0 ]; then pass "branch '$b' is refused"; else fail "branch '$b' was accepted ($OUT)"; fi
done
for extra in --force -f "--upload-pa=sh -c x" "--templ=/tmp/t" "--conf=core.pager=x" "--outp=/tmp/x" "--exe=x" \
             "-c" "core.sharedRepository=0666" "--show-token=true" "-Ftext=@/var/lib/gitctl/gitcred/gh/hosts.yml"; do
    ctl push "$W" feature "$extra"
    if [ "$RC" != 0 ]; then pass "push with an extra '$extra' is refused (no verb passes options on)"; else fail "push took '$extra'"; fi
    ctl fetch "$W" "$extra"
    if [ "$RC" != 0 ]; then pass "fetch with an extra '$extra' is refused"; else fail "fetch took '$extra'"; fi
done

echo ""
echo "=== fetch ==="
O="$S/other"
G clone -q "$R" "$O" 2>/dev/null && G -C "$O" switch -q main && G -C "$O" commit -q --allow-empty -m "From elsewhere" && G -C "$O" push -q origin main 2>/dev/null
G -C "$O" push -q origin main:refs/heads/doomed 2>/dev/null
ctl fetch "$W"
assert_eq "fetch brings origin's commits" "$(git -C "$R" rev-parse main)" "$(git -C "$W" rev-parse origin/main)"
assert_eq "and its new branches" "$(git -C "$R" rev-parse main)" "$(git -C "$W" rev-parse origin/doomed 2>/dev/null)"
git -C "$R" update-ref -d refs/heads/doomed
ctl fetch "$W"
assert_eq "a branch deleted on origin is pruned from the working copy" none "$(git -C "$W" rev-parse -q --verify origin/doomed || echo none)"
assert_eq "and from gitrun's private copy" none "$(git --git-dir="$STORE/o/r.git" rev-parse -q --verify refs/heads/doomed || echo none)"
# A working copy made with git init and git remote add has no origin/HEAD; gh pr create's base
# comes from it.
git -C "$W" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null && G -C "$W" symbolic-ref --delete refs/remotes/origin/HEAD
ctl fetch "$W"
assert_eq "a working copy with no origin/HEAD learns origin's default branch from a fetch" \
    "origin/main" "$(git -C "$W" symbolic-ref -q --short refs/remotes/origin/HEAD || echo none)"
git -C "$R" update-ref refs/heads/side "$(git -C "$R" rev-parse main)"
ctl fetch "$W"
G -C "$W" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/side
ctl fetch "$W"
assert_eq "one it already has is never changed by a fetch" \
    "origin/side" "$(git -C "$W" symbolic-ref -q --short refs/remotes/origin/HEAD || echo none)"
# One some other tool wrote as a plain ref (not symbolic) is left alone too.
G -C "$W" symbolic-ref --delete refs/remotes/origin/HEAD
G -C "$W" update-ref --no-deref refs/remotes/origin/HEAD "$(git -C "$W" rev-parse origin/side)"
ctl fetch "$W"
assert_eq "a plain-ref origin/HEAD is never replaced by a fetch" "plain $(git -C "$W" rev-parse origin/side)" \
    "$(git -C "$W" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null && echo symbolic || echo plain) $(git -C "$W" rev-parse refs/remotes/origin/HEAD)"
G -C "$W" update-ref -d --no-deref refs/remotes/origin/HEAD
G -C "$W" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$R" update-ref -d refs/heads/side
WT="$S/wt"; G -C "$W" worktree add -q "$WT" -b wtb 2>/dev/null
ctl fetch "$WT"; assert_eq "a worktree of the working copy can be fetched into" 0 "$RC"
ctl fetch "$S/nope"; refused "a missing folder is refused"
ctl fetch "$S"; refused "a folder that is no git working copy is refused"

echo ""
echo "=== bundles are data, read by gitrun on stdin and never left behind ==="
assert_eq "no bundle is left in the agent's folder" "" "$(ls -A "$BUNDLES")"
assert_eq "none in gitrun's store" "" "$(find "$STORE" -name 'incoming.*')"
G -C "$W" commit -q --allow-empty -m "Bad" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
ctl push "$W" feature; refused "a refused push is refused"
assert_eq "and leaves no bundle either side" "" "$(ls -A "$BUNDLES")$(find "$STORE" -name 'incoming.*')"
G -C "$W" reset -q --hard HEAD~1
touch -d '2 hours ago' "$BUNDLES/old.bundle" "$STORE/o/r.git/incoming.old"
touch "$BUNDLES/fresh.bundle"
ctl fetch "$W"
assert_eq "bundles over an hour old (a killed verb's) are swept by the next verb, a fresh one kept" "fresh.bundle no" \
    "$(ls -A "$BUNDLES") $([ -e "$STORE/o/r.git/incoming.old" ] && echo yes || echo no)"
rm -f "$BUNDLES/fresh.bundle"
AIDC_GITCTL_ROLE=run ctl_in "not a bundle" push o/r feature; refused "gitrun refuses stdin that is not a bundle"
AIDC_GITCTL_ROLE=run ctl push o/r feature "$W/.git"; refused "gitrun opens no bundle path the caller names (stdin only)"
git -C "$W" bundle create -q "$S/other.bundle" main 2>/dev/null
: > "$S/bin/calls.log"; OUT=$(AIDC_GITCTL_ROLE=run bash "$GITCTL/gitctl.sh" push o/r feature < "$S/other.bundle" 2>&1); RC=$?; CALLS=""
refused "a bundle without the branch is refused"
assert_has "for that reason" "the bundle has no branch feature" "$OUT"
# The store is one fixed-size claim: a bundle on stdin is capped, and one past the cap is
# refused and removed, not saved whole.
G -C "$W" commit -q --allow-empty -m "Small enough"
: > "$S/bin/calls.log"; OUT=$(AIDC_GITCTL_MAX_BUNDLE_BYTES=64 bash "$GITCTL/gitctl.sh" push "$W" feature 2>&1); RC=$?; CALLS=""
refused "a bundle larger than the cap is refused"
assert_has "for that reason" "the bundle is larger than" "$OUT"
assert_eq "and nothing of it is left in the store" "" "$(find "$STORE" -name 'incoming.*')"
assert_eq "and nothing reached origin" "$(git -C "$R" rev-parse feature)" "$(git -C "$W" rev-parse feature~1)"
ctl push "$W" feature
assert_eq "under the default cap the same push goes through" "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
# Each push holds its branch under a ref of its own, named after its bundle; a killed push's
# ref (its bundle gone) is dropped by the next, a running one's (bundle present) is not.
assert_eq "a push leaves no ref of its own behind" "" "$(git --git-dir="$STORE/o/r.git" for-each-ref refs/incoming/)"
git --git-dir="$STORE/o/r.git" update-ref refs/incoming/incoming.dead "$(git -C "$W" rev-parse main)"
git --git-dir="$STORE/o/r.git" update-ref refs/incoming/incoming.live "$(git -C "$W" rev-parse main)"
touch "$STORE/o/r.git/incoming.live"
G -C "$W" commit -q --allow-empty -m "Another"
ctl push "$W" feature
assert_eq "a killed push's ref is dropped; a running push's ref and bundle are left alone" "refs/incoming/incoming.live" \
    "$(git --git-dir="$STORE/o/r.git" for-each-ref --format='%(refname)' refs/incoming/)"
git --git-dir="$STORE/o/r.git" update-ref -d refs/incoming/incoming.live; rm -f "$STORE/o/r.git/incoming.live"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in refs/incoming/*) echo "$a" >> %s/refs.log ;; esac; done\nexec %s "$@"\n' \
    "$S" "$AIDC_GITCTL_REAL_GIT" > "$S/bin/git-logged"; chmod +x "$S/bin/git-logged"
G -C "$W" commit -q --allow-empty -m "Watched"
: > "$S/refs.log"; AIDC_GITCTL_REAL_GIT="$S/bin/git-logged" bash "$GITCTL/gitctl.sh" push "$W" feature >/dev/null 2>&1
assert_eq "the push's ref is named after its own bundle (two pushes never share one)" yes \
    "$(r=$(grep -v '^refs/incoming/$' "$S/refs.log" | sed 's/\^{commit}$//' | sort -u); case "$r" in refs/incoming/incoming.?*) [ "$(printf '%s\n' "$r" | wc -l)" = 1 ] && echo yes || echo "no: $r" ;; *) echo "no: $r" ;; esac)"
G -C "$W" switch -q -c direct feature
G -C "$W" commit -q --allow-empty -m "Direct" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git -C "$W" bundle create -q "$S/direct.bundle" refs/heads/direct --not feature 2>/dev/null
: > "$S/bin/calls.log"; OUT=$(AIDC_GITCTL_ROLE=run bash "$GITCTL/gitctl.sh" push o/r direct < "$S/direct.bundle" 2>&1); RC=$?
assert_eq "called as gitrun directly (as through sudo), an attributed commit in the bundle is still refused" "1 none" "$RC $(remote_sha direct)"
G -C "$W" switch -q feature
chmod 0755 "$STORE"; ctl fetch "$W"; refused "a store others can enter is refused"
chmod 0700 "$STORE"
ctl storage
assert_eq "storage says what the private copies and the bundles hold" yes \
    "$(printf '%s\n' "$OUT" | grep -Eq '^copies [0-9]+$' && printf '%s\n' "$OUT" | grep -Eq '^bundles [0-9]+$' && echo yes || echo "no: $OUT")"
ctl remove-copy o/r
assert_eq "remove-copy deletes gitrun's private copy" "0 no" "$RC $([ -e "$STORE/o/r.git" ] && echo yes || echo no)"
ctl fetch "$W"; refused "after it, the repo is no longer the user's: a fetch is refused"
assert_eq "and makes no copy" no "$([ -d "$STORE/o/r.git" ] && echo yes || echo no)"
rm -rf "$S/added"; mkdir -p "$S/added"; ctl clone o/r "$S/added"
ctl fetch "$W"; assert_eq "adding it again (gitctl clone) makes the copy, and fetch works again" "0 yes" "$RC $([ -d "$STORE/o/r.git" ] && echo yes || echo no)"
for a in ../x "o/r/../../x" -f "o/.."; do ctl remove-copy "$a"; refused "remove-copy '$a' is refused"; done

echo ""
echo "=== origin must be one GitHub repo ==="
H="$S/gh-shaped"; G init -q "$H"
for u in http://github.com/o/r.git git@github.com:o/r.git https://example.com/o/r.git 'ext::sh -c x' https://github.com/o; do
    git -C "$H" remote remove origin 2>/dev/null; git -C "$H" remote add origin "$u"
    ctl fetch "$H"; refused "origin $u is refused (https://github.com/<owner>/<name> only)"
done
git -C "$H" remote set-url origin https://github.com/o/r.git
git -C "$H" config url.https://example.com/.insteadOf https://github.com/
ctl fetch "$H"; refused "an insteadOf that sends origin elsewhere is refused"
git -C "$H" config --unset url.https://example.com/.insteadOf

echo ""
echo "=== pull requests: gh only ever runs with the command line gitctl builds ==="
printf 'Add the git container\n' > "$S/title"; printf 'It pushes.\n\nMore detail.\n' > "$S/body"
ctl pr-create "$H" feature main --title-file "$S/title" --body-file "$S/body"
assert_eq "pr-create runs exactly gh pr create --repo --head --base --title --body" \
    "pr create --repo o/r --head feature --base main --title Add\\ the\\ git\\ container --body $'It pushes.\\n\\nMore detail.' " "$CALLS"
ctl_in "A body from stdin." pr-create "$H" feature main --title-file "$S/title" --body-file -
assert_has "a body on stdin reaches gh" "--body A\\ body\\ from\\ stdin." "$CALLS"
printf 'Adds it.\n\nThanks! Co-Authored-By: Claude <noreply@anthropic.com>\n' > "$S/bad"
ctl pr-create "$H" feature main --title-file "$S/title" --body-file "$S/bad"; refused "a body with attribution mid-line is refused"
printf 'Generated with Claude Code\n' > "$S/badtitle"
ctl pr-create "$H" feature main --title-file "$S/badtitle" --body-file "$S/body"; refused "a title with attribution is refused"
ctl pr-create "$H" feature main --title-file "$S/missing" --body-file "$S/body"
refused "a title file the agent cannot read is refused"
case "$OUT" in *"needs a title"*) fail "the missing file stops the verb at once (it went on: $OUT)" ;;
    *) pass "the missing file stops the verb at once" ;; esac
ctl pr-create "$H" feature main --title-file "$S/title" --body-file "$S/body" "--body=Co-Authored-By: Claude"
refused "pr-create takes no extra option (--body=...)"
ctl pr-create "$H" feature main --body-file "$S/body" --title-file "$S/title"; refused "the options are fixed in place"
ctl pr-create "$H" -f main --title-file "$S/title" --body-file "$S/body"; refused "a head that reads as an option is refused"
AIDC_GITCTL_ROLE=cred ctl_in $'T\nBody. Co-Authored-By: Claude' pr-create o/r feature main
refused "called as gitcred directly (as through sudo), the text is checked again"
AIDC_GITCTL_ROLE=cred ctl pr-create o/r feature main "$S/title"
refused "as gitcred it opens no file the caller names"
AIDC_GITCTL_ROLE=cred ctl push "$W" feature; refused "gitcred runs no git verb"
AIDC_GITCTL_ROLE=run ctl pr-merge o/r 5; refused "gitrun runs no gh verb"

printf '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Add it","body":"Clean.","commits":[{"messageHeadline":"Add it","messageBody":"","authors":[{"name":"Someone","email":"someone@example.com"}]}]}' > "$S/bin/prview.json"
ctl pr-merge "$H" 5
assert_eq "pr-merge reads the PR, then merges with a merge commit bound to the head it checked, nothing else" \
    "pr view 5 --repo o/r --json title\\,body\\,commits\\,headRefOid 
pr merge 5 --repo o/r --merge --match-head-commit $(printf 'a%.0s' $(seq 40)) " "$CALLS"
for extra in --squash "--squash=t" "--merge=0" --rebase -s; do
    ctl pr-merge "$H" 5 "$extra"; refused "pr-merge takes no '$extra'"
done
ctl pr-merge "$H" "5;x"; refused "a PR number must be a number"
printf '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Add it","body":"","commits":[{"messageHeadline":"Fix","messageBody":"Co-Authored-By: Claude <noreply@anthropic.com>","authors":[]}]}' > "$S/bin/prview.json"
ctl pr-merge "$H" 5
assert_eq "a PR carrying an attributed commit is not merged" "pr view 5 --repo o/r --json title\\,body\\,commits\\,headRefOid " "$CALLS"
printf '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Add it","body":"","commits":[{"messageHeadline":"Fix","messageBody":"","authors":[{"name":"Copilot","email":"copilot@users.noreply.github.com"}]}]}' > "$S/bin/prview.json"
ctl pr-merge "$H" 5
assert_eq "a PR with a commit authored as an AI tool is not merged" "pr view 5 --repo o/r --json title\\,body\\,commits\\,headRefOid " "$CALLS"
printf '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Add it","body":"","commits":[{"messageHeadline":"Fix","messageBody":"","authors":[{"name":"Claude","email":"claude@example.invalid"}]}]}' > "$S/bin/prview.json"
ctl pr-merge "$H" 5
assert_eq "a PR with a commit authored as Claude at any email is not merged" "pr view 5 --repo o/r --json title\\,body\\,commits\\,headRefOid " "$CALLS"
printf '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Add it","body":"Clean.","commits":[{"messageHeadline":"Add it","messageBody":"","authors":[{"name":"Someone","email":"someone@example.com"}]}]}' > "$S/bin/prview.json"
ctl pr-merge "$H" 5 --expect-head "$(printf 'b%.0s' $(seq 40))"
assert_eq "a PR whose head moved since it was approved (--expect-head) is not merged" "pr view 5 --repo o/r --json title\\,body\\,commits\\,headRefOid " "$CALLS"
assert_has "saying so" "moved since it was approved" "$OUT"
ctl pr-merge "$H" 5 --expect-head "$(printf 'a%.0s' $(seq 40))"
assert_has "the approved head, unchanged, is merged, bound to it" "--match-head-commit $(printf 'a%.0s' $(seq 40))" "$CALLS"
ctl pr-view "$H" 5 --expect-head "$(printf 'a%.0s' $(seq 40))"; refused "only pr-merge takes --expect-head"
AIDC_GITCTL_ROLE=cred ctl pr-merge o/r 5 "abc"; refused "as gitcred, the head is a full commit id"

printf 'Looks good.\n' > "$S/comment"
ctl pr-comment "$H" 5 --body-file "$S/comment"
assert_eq "pr-comment runs exactly gh pr comment --repo --body" "pr comment 5 --repo o/r --body Looks\\ good. " "$CALLS"
printf 'Done. Generated with Claude Code\n' > "$S/comment"
ctl pr-comment "$H" 5 --body-file "$S/comment"; refused "a comment with attribution is refused"
ctl pr-view "$H" 5; assert_eq "pr-view" "pr view 5 --repo o/r " "$CALLS"
ctl pr-list "$H"; assert_eq "pr-list" "pr list --repo o/r " "$CALLS"

echo 0 > "$S/bin/authstatus.rc"; : > "$S/bin/authstatus.out"
ctl status; assert_eq "status: logged in is yes" yes "$OUT"
echo 1 > "$S/bin/authstatus.rc"; echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" > "$S/bin/authstatus.out"
ctl status; assert_eq "status: no login is no" no "$OUT"
echo "error connecting to api.github.com" > "$S/bin/authstatus.out"
ctl status; assert_eq "status: anything else is unknown, never no" unknown "$OUT"
ctl status --show-token=true; refused "status takes no options (--show-token=true)"
for v in api "auth token" credential "markdown -Ftext=@/var/lib/gitctl/gitcred/gh/hosts.yml" grep init clone; do
    # shellcheck disable=SC2086  # the verb and its words, split on purpose
    ctl $v; refused "'$v' is not a gitctl verb"
done

echo ""
echo "=== the PreToolUse hook (a courtesy; gitctl is the enforcement) ==="
hook() { # TOOL FIELD VALUE
    HOUT=$(jq -n --arg t "$1" --arg k "$2" --arg v "$3" '{tool_name: $t, tool_input: {($k): $v}}' \
        | bash "$GITCTL/claude-hook.sh" 2>&1); HRC=$?
}
blocked() { local d="$1"; shift; hook "$@"; if [ "$HRC" = 2 ]; then pass "hook blocks: $d"; else fail "hook let through: $d ($HOUT)"; fi; }
allowed() { local d="$1"; shift; hook "$@"; if [ "$HRC" = 0 ]; then pass "hook allows: $d"; else fail "hook blocked: $d ($HOUT)"; fi; }
blocked "sudo" Bash command "sudo -u gitcred /opt/aidc/lib/gitctl/gitctl.sh status"
blocked "su" Bash command "echo x | su gitcred -c id"
blocked "reading the login's home" Bash command "cat /var/lib/gitctl/gitcred/gh/hosts.yml"
blocked "reading the sudo rules" Bash command "cat /etc/sudoers.d/aidc-gitctl"
blocked "writing the managed settings" Bash command "echo '{}' > /etc/claude-code/managed-settings.json"
blocked "gh auth login as the agent" Bash command "/usr/local/bin/gh auth login --with-token < t"
blocked "a local commit with attribution" Bash command 'git commit -m "Fix. Co-Authored-By: Claude <noreply@anthropic.com>"'
blocked "Write to gitctl" Write file_path /opt/aidc/lib/gitctl/gitctl.sh
blocked "Edit the sudo rules" Edit file_path /etc/sudoers.d/aidc-gitctl
allowed "ordinary git" Bash command "git status && git log --oneline -3"
allowed "a gitctl verb" Bash command "gitctl push /home/alice/code/proj feature"
allowed "reading the managed settings" Bash command "cat /etc/claude-code/managed-settings.json"
allowed "a message that talks about Claude" Bash command 'git commit -m "Fix the Claude Code transcript reader"'
allowed "a read tool" Read file_path /etc/claude-code/managed-settings.json
HOUT=$(printf 'not json' | bash "$GITCTL/claude-hook.sh" 2>&1); HRC=$?
assert_eq "input it cannot read is blocked (the hook fails closed)" 2 "$HRC"

echo ""
echo "=== the image: one sudo rule for the agent, root's files ==="
df=$(cat "$GITCTL/Dockerfile")
case "$df" in *openssh*) fail "no ssh client in the image (pushes are HTTPS only)" ;; *) pass "no ssh client in the image (pushes are HTTPS only)" ;; esac
assert_has "/opt/aidc/bin (gitctl, and a gh that points to it) comes first on PATH" 'ENV PATH="/opt/aidc/bin:' "$df"
assert_has "gitctl is installed" "ln -s /opt/aidc/lib/gitctl/gitctl.sh /opt/aidc/bin/gitctl" "$df"
for f in gitctl-run.sh gitctl-cred.sh gitctl-agent.sh; do
    assert_has "the side it sources, ${f}, is installed beside it (root's, not executable)" "/opt/aidc/lib/gitctl/${f}" "$df"
    assert_has "..." "${f}" "$(grep '^COPY gitctl-rules.sh' "$GITCTL/Dockerfile")"
done
assert_has "plain gh points to gitctl (a gh login as the agent would be readable by it)" "ln -s /opt/aidc/lib/gitctl/gh-shim.sh /opt/aidc/bin/gh" "$df"
assert_has "the sudo rules are root's, 0440" "chmod 0440 /etc/sudoers.d/aidc-gitctl" "$df"
assert_has "and checked at build" "visudo -c -f /etc/sudoers.d/aidc-gitctl" "$df"
assert_has "the managed settings are installed" "COPY managed-settings.json /etc/claude-code/managed-settings.json" "$df"
assert_eq "the sudo rules are exactly: the agent to gitctl (gitwc for working-copy writes on Docker), gitrun to the credential helper, gitcred to gitrun's has-copy only" \
"git ALL=(gitrun,gitcred,gitwc) NOPASSWD: /opt/aidc/lib/gitctl/gitctl.sh
gitwc ALL=(gitrun,gitcred) NOPASSWD: /opt/aidc/lib/gitctl/gitctl.sh
gitrun ALL=(gitcred) NOPASSWD: /opt/aidc/lib/gitctl/cred-helper.sh
gitcred ALL=(gitrun) NOPASSWD: /opt/aidc/lib/gitctl/gitctl.sh has-copy *" \
    "$(grep -vE '^(#|Defaults|$)' "$GITCTL/sudoers" | tr -s ' ')"
assert_has "sudo resets the environment" "env_reset" "$(cat "$GITCTL/sudoers")"
ms="$GITCTL/managed-settings.json"
assert_eq "the hook runs before every tool" '"*"' "$(jq -c '.hooks.PreToolUse[0].matcher' "$ms")"
assert_eq "the hook is the shared checker" '"/opt/aidc/lib/gitctl/claude-hook.sh"' "$(jq -c '.hooks.PreToolUse[0].hooks[0].command' "$ms")"
assert_eq "only managed hooks run (a repo's own hooks would run as the agent)" true "$(jq -c '.allowManagedHooksOnly' "$ms")"
gc=$(cat "$GITCTL/gitconfig")
assert_has "the agent's git runs no repo hooks" "hooksPath = /dev/null" "$gc"
assert_has "nothing is signed" "gpgSign = false" "$gc"
case "$gc" in *"[credential"*|*helper*) fail "the agent's git config names no credential helper" ;; *) pass "the agent's git config names no credential helper" ;; esac

echo ""
echo "=== clone: a new working copy from gitrun's bundle ==="
printf 'hello\n' > "$O/README"; G -C "$O" add README; G -C "$O" commit -q -m "Add a file"; G -C "$O" push -q origin main 2>/dev/null
C="$S/disk/proj"; mkdir -p "$C"
ctl clone o/r "$C"
assert_eq "clone succeeds into an empty folder" 0 "$RC"
assert_eq "an ordinary checkout of origin's default branch" "main hello" "$(git -C "$C" branch --show-current) $(cat "$C/README" 2>/dev/null)"
assert_eq "origin is the GitHub URL (here the stand-in), and origin/HEAD is set" "$F/o/r.git refs/remotes/origin/main" \
    "$(git -C "$C" remote get-url origin) $(git -C "$C" symbolic-ref refs/remotes/origin/HEAD)"
assert_eq "shared with the session group (sessions and the agent both write it; 1 is git's spelling of group)" 1 "$(git -C "$C" config core.sharedRepository)"
assert_eq "every folder in its .git is group-writable and setgid" "" \
    "$(find "$C/.git" -type d ! -perm -2070 -print)"
assert_eq "no bundle left behind" "" "$(ls -A "$BUNDLES")"
G -C "$C" worktree add -q -b feat2 "$C/s1" origin/main 2>/dev/null
assert_eq "a session's own worktree on a new branch from origin/main works" feat2 "$(git -C "$C/s1" branch --show-current 2>/dev/null)"
ctl fetch "$C"; assert_eq "and the clone fetches like any working copy" 0 "$RC"
ctl clone o/r "$C"; refused "a folder that is not empty is refused"
E="$S/disk/e"; mkdir -p "$E"
ln -s "$E" "$S/disk/link"
ctl clone o/r "$S/disk/link"; refused "a symlink on the way is refused"
ctl clone o/r "$S/disk/missing"; refused "a folder that does not exist is refused (aidc repo add makes it)"
for p in disk/e "$S/disk/../disk/e" "$S/disk/e/." "$S/disk/a b" "$S/disk/e;x" ""; do
    ctl clone o/r "$p"; refused "path '$p' is refused (absolute, plain names, no . or ..)"
done
for src in "$R" -u "--upload-pack=touch $S/PWNED3" "o/r/x" "ext::sh -c x" "o/.." "https://github.com/o/r" "o"; do
    ctl clone "$src" "$E"; refused "source '$src' is refused (owner/name only; the URL is gitctl's)"
done
ctl clone o/nothere "$E"; refused "a repo origin does not have is refused"
assert_eq "and the folder is left empty" "" "$(ls -A "$E")"
assert_eq "and gitrun keeps no copy of it (a failed add leaves no repo looking added)" no "$([ -e "$STORE/o/nothere.git" ] && echo yes || echo no)"
ctl clone o/r "$E" extra; refused "clone takes exactly two arguments"
AIDC_GITCTL_ROLE=run ctl clone o/r "$E"; refused "gitrun has no clone: it never writes a working copy"
AIDC_GITCTL_ROLE=cred ctl clone o/r "$E"; refused "gitcred runs no clone"
assert_eq "no refused clone ran a command" no "$([ -e "$S/PWNED3" ] && echo yes || echo no)"

echo ""
echo "=== unpushed: the work a delete of the working copy would lose ==="
# aidc repo remove --delete-working-copy refuses while this reports anything: a report that
# missed a kind of work would let the delete take a session's commits or changes with it.
ctl unpushed "$C"
assert_eq "a clean clone with a worktree on a branch at origin's commit: only the worktree is named" \
    "0|worktree $C/s1|end" "$RC|$(printf '%s' "$OUT" | paste -sd'|' -)"
G -C "$C/s1" commit -q --allow-empty -m "Session work"
printf 'x\n' > "$C/s1/draft.txt"
G -C "$C" worktree add -q --detach "$C/s2" origin/main 2>/dev/null
G -C "$C/s2" commit -q --allow-empty -m "Detached work"
printf 'y\n' >> "$C/README"; G -C "$C" stash -q; printf 'z\n' >> "$C/README"
G -C "$C" branch local-only main
ctl unpushed "$C"
assert_eq "it names the unpushed branch, the detached commit, the uncommitted worktrees, the stash and every worktree" \
    "0|branch 1 feat2|uncommitted $C|worktree $C/s1|uncommitted $C/s1|worktree $C/s2|detached 1 $C/s2|stash 1|end" \
    "$RC|$(printf '%s' "$OUT" | paste -sd'|' -)"
assert_eq "a branch whose commits are all on origin (local-only, at main) is not unpushed" no \
    "$(printf '%s\n' "$OUT" | grep -q 'local-only' && echo yes || echo no)"
ctl unpushed "$C/s1"
assert_eq "asked from a worktree, it reports the same repo" "$(printf 'branch 1 feat2')" "$(printf '%s\n' "$OUT" | head -1)"
git -C "$C" push -q "$R" feat2 2>/dev/null
ctl unpushed "$C"
assert_eq "once origin has the branch, it is no longer unpushed (the fetch is what tells)" no \
    "$(printf '%s\n' "$OUT" | grep -q '^branch ' && echo yes || echo no)"
mv "$C/s2" "$S/s2-moved"
ctl unpushed "$C"
assert_has "a worktree whose folder is gone is named but holds nothing to read" "worktree $C/s2" "$OUT"
assert_eq "and does not fail the report" 0 "$RC"
mv "$S/s2-moved" "$C/s2"
# A fetch that fails: GitHub (the forge) does not answer for a repo gitrun has a copy of.
chmod 000 "$F/o/r.git"
ctl unpushed "$C"
chmod 755 "$F/o/r.git"
assert_eq "a fetch that fails ends with an error and no end line, never an empty report" "1 no" \
    "$RC $(printf '%s\n' "$OUT" | grep -qx end && echo yes || echo no)"
# A repo whose private copy is gone (aidc repo remove's first run took it, then stopped): no
# fetch (gitctl reaches GitHub only for added repos), a report from what the copy last fetched.
G -C "$C/s1" commit -q --allow-empty -m "More session work"
git -C "$C" config remote.origin.url "$F/o/nothere.git"
ctl unpushed "$C"
assert_eq "a repo with no private copy is still reported, marked not fetched, with its end line" "0 not-fetched yes" \
    "$RC $(printf '%s\n' "$OUT" | head -n1) $(printf '%s\n' "$OUT" | grep -qx end && echo yes || echo no)"
assert_has "and its unpushed work is still named" "branch 1 feat2" "$OUT"
assert_eq "and gitrun made no copy of it" no "$([ -e "$STORE/o/nothere.git" ] && echo yes || echo no)"
ctl unpushed "$C" --expect-repo o/other
refused "unpushed still holds the working copy to --expect-repo"
git -C "$C" config remote.origin.url "$F/o/r.git"
git -C "$C" config core.fsmonitor "touch $S/PWNED-fsm"
ctl unpushed "$C"
git -C "$C" config --unset core.fsmonitor
assert_eq "a planted fsmonitor in the working copy's config does not run" no "$([ -e "$S/PWNED-fsm" ] && echo yes || echo no)"
AIDC_GITCTL_ROLE=run ctl unpushed "$C"; refused "gitrun has no unpushed: it never reads a working copy"
ctl unpushed "$C" extra; refused "unpushed takes one argument"

echo ""
echo "=== a filter driver planted in a working copy never runs as the agent ==="
# The agent's git reads the working copy's config, which sessions write. A clean filter runs on
# any file git re-reads (status, worktree remove); every driver named there is overridden.
FC="$S/disk/filtered"; mkdir -p "$FC"
ctl clone o/r "$FC"
mkdir -p "$FC/.git/info"; printf '* filter=Ev.il\n' > "$FC/.git/info/attributes"
git -C "$FC" config filter.Ev.il.clean "sh -c 'touch $S/PWNED-clean; cat'"
git -C "$FC" config filter.Ev.il.smudge "sh -c 'touch $S/PWNED-smudge; cat'"
git -C "$FC" config filter.Ev.il.process "sh -c 'touch $S/PWNED-process'"
git -C "$FC" config filter.plain.clean "touch $S/PWNED-plain"
printf '* filter=plain\n' >> "$FC/.git/info/attributes"
touch -d '1 hour ago' "$FC/README"
ctl unpushed "$FC"
assert_eq "unpushed (git status in the copy) runs no planted clean, smudge or process filter" "0 none" \
    "$RC $(find "$S" -maxdepth 1 -name 'PWNED-*' | wc -l | sed 's/^0$/none/')"
G -C "$FC" switch -q -c filtered-b
G -C "$FC" commit -q --allow-empty -m "Filtered"
rm -f "$S"/PWNED-*   # the test's own git above ran them; gitctl's must not
touch -d '2 hours ago' "$FC/README"
ctl push "$FC" filtered-b
ctl tidy "$FC"
assert_eq "nor do push (bundle create) and tidy (status, worktree remove)" none \
    "$(find "$S" -maxdepth 1 -name 'PWNED-*' | wc -l | sed 's/^0$/none/')"
assert_has "push names the branch and the commit it pushed (a session's request result reads it)" \
    "pushed filtered-b $(git -C "$FC" rev-parse filtered-b)" "$(ctl push "$FC" filtered-b; printf '%s' "$OUT")"

echo ""
echo "=== delete-branch: only a branch merged on GitHub, never a base ==="
D="$S/del"; G clone -q "$R" "$D" 2>/dev/null
G -C "$D" switch -q -c merged-b origin/main; G -C "$D" commit -q --allow-empty -m "Merged work"
G -C "$D" push -q origin merged-b 2>/dev/null
G -C "$D" switch -q main; G -C "$D" pull -q origin main 2>/dev/null
G -C "$D" merge -q --no-ff -m "Merge merged-b" merged-b; G -C "$D" push -q origin main 2>/dev/null
G -C "$D" switch -q -c open-b origin/main; G -C "$D" commit -q --allow-empty -m "Open work"
G -C "$D" push -q origin open-b 2>/dev/null
ctl delete-branch "$D" merged-b
assert_eq "a branch merged into main on GitHub is deleted there" "0 none" "$RC $(remote_sha merged-b)"
ctl delete-branch "$D" merged-b
assert_eq "a branch already gone is not an error" 0 "$RC"
ctl delete-branch "$D" open-b
assert_eq "a branch not merged on GitHub is kept" "1 $(git -C "$D" rev-parse open-b)" "$RC $(remote_sha open-b)"
assert_has "with the reason" "not merged on GitHub" "$OUT"
for b in main master develop -f "a:b"; do
    ctl delete-branch "$D" "$b"
    if [ "$RC" != 0 ]; then pass "delete-branch '$b' is refused"; else fail "delete-branch '$b' went through"; fi
done
assert_eq "and main is still there" yes "$([ "$(remote_sha main)" != none ] && echo yes || echo no)"
ctl delete-branch "$D" open-b --force; refused "delete-branch takes no options"
AIDC_GITCTL_ROLE=cred ctl delete-branch o/r open-b; refused "gitcred has no delete-branch"

echo ""
echo "=== tidy: merged work goes, every leftover is named ==="
T="$S/disk/tidy"; mkdir -p "$T"
ctl clone o/r "$T"
umask 002
G -C "$T" worktree add -q -b t-merged "$T/wt-merged" origin/main 2>/dev/null
G -C "$T/wt-merged" commit -q --allow-empty -m "Will merge"
mkdir -p "$T/wt-merged/sub/dir"; printf 'x\n' > "$T/wt-merged/sub/dir/f"; G -C "$T/wt-merged" add sub; G -C "$T/wt-merged" commit -q -m "A file"
G -C "$T" worktree add -q -b t-dirty "$T/wt-dirty" origin/main 2>/dev/null
G -C "$T/wt-dirty" commit -q --allow-empty -m "Will merge too"
G -C "$T" worktree add -q -b t-locked-dir "$T/wt-ro" origin/main 2>/dev/null
G -C "$T/wt-ro" commit -q --allow-empty -m "Merged, folder not writable"
mkdir -p "$T/wt-ro/ro"; printf 'x\n' > "$T/wt-ro/ro/f"; G -C "$T/wt-ro" add ro; G -C "$T/wt-ro" commit -q -m "ro"
G -C "$T" worktree add -q -b t-unpushed "$T/wt-unpushed" origin/main 2>/dev/null
G -C "$T/wt-unpushed" commit -q --allow-empty -m "Never pushed"
G -C "$T" worktree add -q -b t-open "$T/wt-open" origin/main 2>/dev/null
G -C "$T/wt-open" commit -q --allow-empty -m "Pushed, PR open"
umask 022
for b in t-merged t-dirty t-locked-dir t-open; do ctl push "$T" "$b"; done
# GitHub merges three of them (merge commits on main), elsewhere.
G -C "$D" fetch -q origin 2>/dev/null; G -C "$D" switch -q main; G -C "$D" reset -q --hard origin/main
for b in t-merged t-dirty t-locked-dir; do G -C "$D" merge -q --no-ff -m "Merge $b" "origin/$b"; done
G -C "$D" push -q origin main 2>/dev/null
printf 'draft\n' > "$T/wt-dirty/draft.txt"
chmod 0555 "$T/wt-ro/ro"
# A folder that was a worktree, whose admin folder someone removed.
mkdir -p "$T/wt-orphan"; printf 'gitdir: %s/.git/worktrees/wt-orphan\n' "$T" > "$T/wt-orphan/.git"
ctl tidy "$T"
chmod 0755 "$T/wt-ro/ro"
row() { printf '%s\n' "$OUT" | grep -qxF "$1" && echo yes || echo "no"; }
assert_eq "the report ends with end" end "$(printf '%s\n' "$OUT" | tail -n1)"
assert_eq "a merged branch is deleted on GitHub" "yes none" "$(row 'deleted-remote t-merged') $(remote_sha t-merged)"
assert_eq "its clean worktree is removed, admin folder and all" "yes no no" \
    "$(row "removed-worktree $T/wt-merged") $([ -e "$T/wt-merged" ] && echo yes || echo no) $([ -e "$T/.git/worktrees/wt-merged" ] && echo yes || echo no)"
assert_eq "and the local branch goes" "yes none" "$(row 'deleted-branch t-merged') $(git -C "$T" rev-parse -q --verify t-merged || echo none)"
assert_eq "a merged branch whose worktree has uncommitted changes: deleted on GitHub, worktree and branch kept, reported" \
    "yes yes yes" "$(row "uncommitted $T/wt-dirty") $([ -f "$T/wt-dirty/draft.txt" ] && echo yes || echo no) $(git -C "$T" rev-parse -q --verify t-dirty >/dev/null && echo yes || echo no)"
assert_has "a worktree with a folder the agent cannot write is not touched, and named" "cannot-delete $T/wt-ro not writable" "$OUT"
assert_eq "and nothing of it was deleted" yes "$([ -f "$T/wt-ro/ro/f" ] && echo yes || echo no)"
assert_has "with how the user clears it (from a session)" "remove it from a session" "$OUT"
assert_eq "an unpushed branch is reported with its count, and kept" "yes yes" \
    "$(row 'unpushed 1 t-unpushed') $(git -C "$T" rev-parse -q --verify t-unpushed >/dev/null && echo yes || echo no)"
assert_eq "a pushed, unmerged branch is reported and kept, here and on GitHub" "yes yes" \
    "$(row 'unmerged t-open') $([ "$(remote_sha t-open)" != none ] && echo yes || echo no)"
assert_eq "an orphaned worktree folder is reported, not deleted" "yes yes" "$(row "orphaned $T/wt-orphan") $([ -d "$T/wt-orphan" ] && echo yes || echo no)"
assert_eq "main is never touched" yes "$(git -C "$T" rev-parse -q --verify main >/dev/null && [ "$(remote_sha main)" != none ] && echo yes || echo no)"
rm -rf "$T/wt-merged-gone"; G -C "$T" worktree add -q -b t-gone "$T/wt-gone" origin/main 2>/dev/null; rm -rf "$T/wt-gone"
ctl tidy "$T"
assert_eq "a worktree whose folder is gone has its record pruned" yes "$(row 'pruned wt-gone')"
# A worktree's path comes from its admin folder, which sessions write. Three merged worktrees
# whose records a session pointed elsewhere: into the git container's request folder, off the
# user's disk, and through a symlink. tidy removes none of them and names each.
umask 002
for w in plant out sym; do
    G -C "$T" worktree add -q -b "t-$w" "$T/wt-$w" origin/main 2>/dev/null
    G -C "$T/wt-$w" commit -q --allow-empty -m "Merged $w"
done
umask 022
for w in plant out sym; do ctl push "$T" "t-$w"; done
G -C "$D" fetch -q origin 2>/dev/null; G -C "$D" switch -q main; G -C "$D" reset -q --hard origin/main
for w in plant out sym; do G -C "$D" merge -q --no-ff -m "Merge t-$w" "origin/t-$w"; done
G -C "$D" push -q origin main 2>/dev/null
REQS="$S/disk/.aidc/git-requests"; mkdir -p "$S/disk/.aidc"
mv "$T/wt-plant" "$REQS"; printf '%s/.git\n' "$REQS" > "$T/.git/worktrees/wt-plant/gitdir"
mv "$T/wt-out" "$S/outside-wt"; printf '%s/.git\n' "$S/outside-wt" > "$T/.git/worktrees/wt-out/gitdir"
mv "$T/wt-sym" "$S/disk/sym-real"; ln -s "$S/disk/sym-real" "$T/wt-sym-link"
printf '%s/.git\n' "$T/wt-sym-link" > "$T/.git/worktrees/wt-sym/gitdir"
ctl tidy "$T"
assert_has "a record pointing at the request folder: named as a leftover" "cannot-delete $REQS not a folder tidy removes" "$OUT"
assert_has "a record pointing off the user's disk: the same" "cannot-delete $S/outside-wt not a folder tidy removes" "$OUT"
assert_has "a record reached through a symlink: the same" "cannot-delete $T/wt-sym-link not a folder tidy removes" "$OUT"
assert_eq "and none of the three folders is deleted" "yes yes yes" \
    "$([ -d "$REQS" ] && echo yes) $([ -d "$S/outside-wt" ] && echo yes) $([ -d "$S/disk/sym-real" ] && echo yes)"
AIDC_GITCTL_ROLE=run ctl tidy "$T"; refused "gitrun has no tidy: it never works in a working copy"
ctl tidy "$T" extra; refused "tidy takes one argument"

echo ""
echo "=== Docker: the user's own working copies (AIDC_GITCTL_DOCKER stands for /.dockerenv) ==="
# The git container's mount list (AIDC_GITCTL_MOUNTINFO stands for /proc/self/mountinfo, run
# from a checkout only): / and each working copy Docker mounted. mount_line PATH: one entry.
MI="$S/mountinfo"
mount_line() { printf '%s 1 0:1 / %s rw,relatime - ext4 /dev/x rw\n' "$((RANDOM + 100))" "$1"; }
{ mount_line /; mount_line "$T"; } > "$MI"
export AIDC_GITCTL_MOUNTINFO="$MI"
# On Docker only the repos the user added are mounted in the git container: tidy removes a
# merged worktree inside its working copy and names one anywhere else, even on the same disk.
umask 002
G -C "$T" worktree add -q -b d-in "$T/d-in" origin/main 2>/dev/null
G -C "$T" worktree add -q -b d-out "$S/disk/d-out" origin/main 2>/dev/null
G -C "$T/d-in" commit -q --allow-empty -m "Docker in"; G -C "$S/disk/d-out" commit -q --allow-empty -m "Docker out"
umask 022
for w in in out; do ctl push "$T" "d-$w"; done
G -C "$D" fetch -q origin 2>/dev/null; G -C "$D" switch -q main; G -C "$D" reset -q --hard origin/main
for w in in out; do G -C "$D" merge -q --no-ff -m "Merge d-$w" "origin/d-$w"; done
G -C "$D" push -q origin main 2>/dev/null
AIDC_GITCTL_DOCKER=1 ctl tidy "$T"
assert_eq "a merged worktree inside the working copy is removed" "yes no" "$(row "removed-worktree $T/d-in") $([ -e "$T/d-in" ] && echo yes || echo no)"
assert_has "one outside it (a sibling folder the git container does not see) is named, not removed" \
    "cannot-delete $S/disk/d-out not a folder tidy removes" "$OUT"
assert_eq "and stays" yes "$([ -d "$S/disk/d-out" ] && echo yes || echo no)"
# A worktree the user keeps beside the working copy is not mounted in the git container: there
# it looks gone. Its record and its branch must survive tidy (the folder is fine on the host).
umask 002
G -C "$T" worktree add -q -b d-hidden "$S/disk/d-hidden" origin/main 2>/dev/null
G -C "$S/disk/d-hidden" commit -q --allow-empty -m "Docker hidden"
umask 022
ctl push "$T" d-hidden
G -C "$D" fetch -q origin 2>/dev/null; G -C "$D" merge -q --no-ff -m "Merge d-hidden" origin/d-hidden; G -C "$D" push -q origin main 2>/dev/null
mv "$S/disk/d-hidden" "$S/d-hidden-on-host"
AIDC_GITCTL_DOCKER=1 ctl tidy "$T"
assert_has "a worktree outside the working copy that the container cannot see is named" "cannot-delete $S/disk/d-hidden not a folder tidy removes" "$OUT"
assert_eq "its branch and its record are kept (nothing is pruned)" "yes yes" \
    "$(git -C "$T" rev-parse -q --verify d-hidden >/dev/null && echo yes || echo no) $([ -d "$T/.git/worktrees/d-hidden" ] && echo yes || echo no)"
mv "$S/d-hidden-on-host" "$S/disk/d-hidden"
mkdir -p "$S/disk/dclone"; AIDC_GITCTL_DOCKER=1 ctl clone o/r "$S/disk/dclone"
refused "clone is refused on Docker (the git container works on the user's own working copies)"
assert_has "and says to add the user's own" "aidc repo add <path>" "$OUT"
# adopt: an existing working copy's repo becomes one the user added; the copy is only read.
A="$S/forge/o/adopted.git"; G init -q --bare "$A"
AW="$S/disk/adopted"; G clone -q "$A" "$AW" 2>/dev/null; G -C "$AW" commit -q --allow-empty -m "first"; G -C "$AW" push -q origin HEAD:main 2>/dev/null
ctl fetch "$AW"; refused "before adopt, the repo is not one the user added: fetch is refused"
cfg=$(md5sum < "$AW/.git/config")
ctl adopt "$AW"; refused "adopt of a repo not on the user's list is refused (aidc repo add lists it first)"
assert_eq "and gitrun makes no copy of it" no "$([ -d "$STORE/o/adopted.git" ] && echo yes || echo no)"
list_add o/adopted
ctl adopt "$AW"
assert_eq "adopt makes gitrun's private copy" "0 yes" "$RC $([ -d "$STORE/o/adopted.git" ] && echo yes || echo no)"
assert_has "and says which repo" "added o/adopted" "$OUT"
assert_eq "the working copy's config is not changed" "$cfg" "$(md5sum < "$AW/.git/config")"
assert_eq "no bundle left behind" "" "$(ls -A "$BUNDLES")"
ctl fetch "$AW"; assert_eq "after it, fetch works" 0 "$RC"
H2="$S/disk/notgh"; G init -q "$H2"; git -C "$H2" remote add origin git@github.com:o/x.git
ctl adopt "$H2"; refused "adopt refuses an origin that is not https://github.com/<owner>/<name>"
ctl adopt "$AW" extra; refused "adopt takes one argument"
# On Docker fetch, tidy and unpushed run as gitwc, the user's uid, which writes every mounted
# working copy: they take only a working copy Docker mounted. A repo the agent made itself
# (here outside any mount, with an added repo as origin and a filter of its own) is refused
# before any git runs in it; a mounted one works.
AR="$S/agent-made"; G clone -q "$A" "$AR" 2>/dev/null
git -C "$AR" config filter.x.clean "sh -c 'touch $S/PWNED-gitwc; cat'"; printf '* filter=x\n' > "$AR/.gitattributes"
touch -d '3 hours ago' "$AR/.gitattributes"
git -C "$AR" update-ref -d refs/remotes/origin/HEAD; git -C "$AR" update-ref -d refs/remotes/origin/main
ar_fetched() { git -C "$AR" rev-parse -q --verify refs/remotes/origin/main >/dev/null && echo yes || echo no; }
for v in fetch tidy unpushed; do
    AIDC_GITCTL_DOCKER=1 ctl "$v" "$AR"; refused "Docker: ${v} refuses a repo that is not a mounted working copy"
    assert_has "and says so" "not one of the working copies mounted here" "$OUT"
done
assert_eq "and nothing of that repo ran, nothing was fetched into it" "no no" "$([ -e "$S/PWNED-gitwc" ] && echo yes || echo no) $(ar_fetched)"
for v in fetch tidy unpushed; do
    AIDC_GITCTL_DOCKER=1 ctl "$v" "$AW"; refused "Docker: ${v} refuses an added repo's working copy that is not mounted"
done
mount_line "$AW" >> "$MI"
for v in fetch unpushed tidy; do
    AIDC_GITCTL_DOCKER=1 ctl "$v" "$AW"; assert_eq "Docker: ${v} works on a mounted working copy" "0 end" "$RC $([ "$v" = fetch ] && echo end || printf '%s\n' "$OUT" | tail -n1)"
done
G -C "$AW" worktree add -q -b d-wt "$AW/wt" main 2>/dev/null
AIDC_GITCTL_DOCKER=1 ctl unpushed "$AW/wt"; assert_eq "Docker: and on a worktree inside it" 0 "$RC"
G clone -q "$A" "$AW/nested" 2>/dev/null
AIDC_GITCTL_DOCKER=1 ctl fetch "$AW/nested"; refused "Docker: a repo of its own inside a mounted working copy is refused"
assert_has "and says why" "is not the mounted working copy" "$OUT"
rm -rf "$AW/nested" "$AW/wt"; G -C "$AW" worktree prune
mkdir -p "$S/disk/linked"; ln -s "$AW/.git" "$S/disk/linked/.git"; mount_line "$S/disk/linked" >> "$MI"
AIDC_GITCTL_DOCKER=1 ctl fetch "$S/disk/linked"; refused "Docker: a mount whose .git is a symlink is refused"
SP="$S/disk/with space"; G clone -q "$A" "$SP" 2>/dev/null; mount_line "$(printf '%s' "$SP" | sed 's/ /\\040/g')" >> "$MI"
AIDC_GITCTL_DOCKER=1 ctl fetch "$SP"; assert_eq "Docker: a mount point with a space (escaped in the mount list) is found" 0 "$RC"
AIDC_GITCTL_DOCKER=1 AIDC_GITCTL_MOUNTINFO="$S/no-such-file" ctl fetch "$AW"; refused "Docker: no mount list, no gitwc verb"
# gitwc (AIDC_GITCTL_AS_WC stands for running as it) can read and write the user's own files: it
# runs fetch, tidy and unpushed on a mounted working copy only, and nothing else, so no file of
# the user's reaches a pull request through it.
printf 'SECRET=1\n' > "$AW/.env"; chmod 0600 "$AW/.env"
for v in "pr-create $AW main main --title-file $AW/.env --body-file $AW/.env" "pr-comment $AW 5 --body-file $AW/.env" \
         "push $AW main" "adopt $AW" "pr-merge $AW 5" "pr-view $AW 5" "pr-list $AW" "protect $AW" "has-copy o/adopted" \
         "clone o/r $S/disk/wcclone" "log"; do
    # shellcheck disable=SC2086  # the verb and its words, split on purpose
    AIDC_GITCTL_DOCKER=1 AIDC_GITCTL_AS_WC=1 ctl $v; refused "as gitwc, '${v%% *}' is refused"
    assert_has "saying only fetch, tidy and unpushed run as gitwc" "does not run as gitwc" "$OUT"
done
AIDC_GITCTL_AS_WC=1 ctl fetch "$AR"; refused "as gitwc, a fetch of a repo that is not a mounted working copy is refused"
AIDC_GITCTL_AS_WC=1 ctl fetch "$AW"; assert_eq "as gitwc, a fetch of a mounted working copy works" 0 "$RC"
rm -f "$AW/.env"
# On Docker gitrun's git and gitcred's gh go through the git container's proxy, a fixed value.
cat > "$S/bin/git-logged" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$S/bin/git-args.log"
exec "$AIDC_GITCTL_REAL_GIT" "\$@"
STUB
chmod +x "$S/bin/git-logged"
: > "$S/bin/git-args.log"
AIDC_GITCTL_REAL_GIT="$S/bin/git-logged" AIDC_GITCTL_TEST_PROXY=http://proxy.test:3128 ctl fetch "$AW"
assert_has "gitrun's git is given the proxy by value" "-c http.proxy=http://proxy.test:3128" "$(cat "$S/bin/git-args.log")"
: > "$S/bin/git-args.log"
AIDC_GITCTL_REAL_GIT="$S/bin/git-logged" ctl fetch "$AW"
assert_has "and without one, proxies stay pinned off" "-c http.proxy= " "$(cat "$S/bin/git-args.log")"
cat > "$S/bin/gh-env" <<STUB
#!/bin/sh
printf 'HTTPS_PROXY=%s\n' "\${HTTPS_PROXY:-}" > "$S/bin/gh-env.log"
echo "not logged in" >&2; exit 1
STUB
chmod +x "$S/bin/gh-env"
AIDC_GITCTL_REAL_GH="$S/bin/gh-env" AIDC_GITCTL_TEST_PROXY=http://proxy.test:3128 ctl status
assert_eq "gitcred's gh is given the proxy" "HTTPS_PROXY=http://proxy.test:3128" "$(cat "$S/bin/gh-env.log")"
AIDC_GITCTL_REAL_GH="$S/bin/gh-env" ctl status
assert_eq "and none without it" "HTTPS_PROXY=" "$(cat "$S/bin/gh-env.log")"

echo ""
echo "=== login: the identity commits carry is the user's GitHub account ==="
CRED="$S/cred"; mkdir -p "$CRED"; export AIDC_GITCTL_CRED_HOME="$CRED"
mkdir -p "$S/bin/api"
printf '{"login":"octo","id":42,"name":"Octo Cat","email":null}' > "$S/bin/api/user"
ctl login
assert_eq "login runs gh's device-code login (https, no SSH key), then reads the account" \
    "auth login --hostname github.com --git-protocol https --web --skip-ssh-key 
api user " "$CALLS"
ident() { git config --file "$CRED/git-identity" "$1" 2>/dev/null; }
assert_eq "no public email: GitHub's noreply address for the account" "Octo Cat|42+octo@users.noreply.github.com" "$(ident user.name)|$(ident user.email)"
assert_eq "the identity file is readable by the agent's git (0644), written whole" 644 "$(stat -c %a "$CRED/git-identity")"
printf '{"login":"octo","id":42,"name":"Octo\\nCat\\u001b[31m","email":"octo@example.com"}' > "$S/bin/api/user"
ctl login
assert_eq "a public email is used; control characters in the name are dropped" "OctoCat[31m|octo@example.com" "$(ident user.name)|$(ident user.email)"
printf '{"login":"octo","id":42,"name":"","email":"x\\n[core]\\n\\tpager = sh"}' > "$S/bin/api/user"
ctl login
assert_eq "an email that is not one falls back to noreply; an empty name is the login" "octo|42+octo@users.noreply.github.com" "$(ident user.name)|$(ident user.email)"
assert_eq "and the file holds only the user section" "user.name user.email" "$(git config --file "$CRED/git-identity" --name-only --list | paste -sd' ' -)"
echo 1 > "$S/bin/login.rc"
rm -f "$CRED/git-identity"; ctl login
assert_eq "a login that did not complete writes no identity" "1 no" "$RC $([ -e "$CRED/git-identity" ] && echo yes || echo no)"
rm -f "$S/bin/login.rc"
ctl login; ctl logout
assert_eq "logout removes the identity with the login" "0 no" "$RC $([ -e "$CRED/git-identity" ] && echo yes || echo no)"
ctl login extra; refused "login takes no arguments"

echo ""
echo "=== protections: read, and only ever turned on ==="
printf '{"default_branch":"main","allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":false}' > "$S/bin/api/repos_o_r"
printf '[]' > "$S/bin/api/repos_o_r_rules_branches_main"
printf 'gh: Branch not protected (HTTP 404)\n' > "$S/bin/api/repos_o_r_branches_main_protection.err"
ctl protection "$H"
assert_eq "an unprotected default branch: force pushes and deletion allowed" \
    "repo o/r|default main|force-push allowed|deletion allowed|merge-commit allowed|squash allowed|rebase disallowed|end" \
    "$(printf '%s' "$OUT" | paste -sd'|' -)"
case "$CALLS" in *"--method"*) fail "protection only reads ($CALLS)" ;; *) pass "protection only reads" ;; esac
printf '[{"type":"non_fast_forward"},{"type":"deletion"}]' > "$S/bin/api/repos_o_r_rules_branches_main"
ctl protection "$H"
assert_eq "a ruleset blocking both counts as blocked" "force-push blocked deletion blocked" \
    "$(printf '%s\n' "$OUT" | grep -E '^(force-push|deletion) ' | paste -sd' ' -)"
printf '[]' > "$S/bin/api/repos_o_r_rules_branches_main"
printf '{"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":true}}' > "$S/bin/api/repos_o_r_branches_main_protection"
ctl protection "$H"
assert_eq "classic protection counts too (force pushes blocked unless allowed)" "force-push blocked deletion allowed" \
    "$(printf '%s\n' "$OUT" | grep -E '^(force-push|deletion) ' | paste -sd' ' -)"
rm -f "$S/bin/api/repos_o_r_branches_main_protection" "$S/bin/api/repos_o_r_rules_branches_main"
printf 'gh: Resource not accessible (HTTP 403)\n' > "$S/bin/api/repos_o_r_branches_main_protection.err"
ctl protection "$H"
assert_eq "what cannot be read is unknown, never allowed" "force-push unknown deletion unknown" \
    "$(printf '%s\n' "$OUT" | grep -E '^(force-push|deletion) ' | paste -sd' ' -)"
printf '[]' > "$S/bin/api/repos_o_r_rules_branches_main"
printf 'gh: Branch not protected (HTTP 404)\n' > "$S/bin/api/repos_o_r_branches_main_protection.err"
printf '{"default_branch":"main","allow_merge_commit":false,"allow_squash_merge":true,"allow_rebase_merge":true}' > "$S/bin/api/repos_o_r"
printf '{"id":1}' > "$S/bin/api/repos_o_r_rulesets"
ctl protect "$H"
assert_has "protect adds the fixed ruleset (force pushes and deletion of the default, main, master, develop)" \
    "api --method POST repos/o/r/rulesets --input -" "$CALLS"
assert_has "and allows merge commits where they were off" "api --method PATCH repos/o/r -F allow_merge_commit=true" "$CALLS"
case "$CALLS" in *squash*|*rebase*|*DELETE*|*PUT*|*"=false"*) fail "protect never turns anything off ($CALLS)" ;; *) pass "protect never turns anything off" ;; esac
printf '[{"type":"non_fast_forward"},{"type":"deletion"}]' > "$S/bin/api/repos_o_r_rules_branches_main"
printf '{"default_branch":"main","allow_merge_commit":true}' > "$S/bin/api/repos_o_r"
ctl protect "$H"
case "$CALLS" in *"--method"*) fail "protect changes nothing that is already on ($CALLS)" ;; *) pass "protect changes nothing that is already on" ;; esac
ctl protect "$H" --off; refused "protect takes no options"
AIDC_GITCTL_ROLE=cred ctl protect "o/r;x"; refused "as gitcred, protect checks owner/name again"

echo ""
echo "=== pull requests as JSON (a session's gh stand-in answers from these) ==="
ctl pr-view-json "$H" 7
assert_eq "pr-view-json by number: fixed fields" \
    "pr view 7 --repo o/r --json number\\,title\\,body\\,state\\,url\\,headRefName\\,headRefOid\\,baseRefName\\,isDraft\\,mergedAt\\,reviewDecision\\,statusCheckRollup " "$CALLS"
ctl pr-view-json "$H" feature
assert_has "or by its head branch" "pr view feature --repo o/r --json" "$CALLS"
ctl pr-list-json "$H" open feature
assert_has "pr-list-json with a state and a head" "pr list --repo o/r --state open --head feature --limit 100 --json" "$CALLS"
ctl pr-list-json "$H" sideways; refused "an unknown state is refused"
ctl pr-view-json "$H" "--web"; refused "a PR that reads as an option is refused"
ctl pr-list-json "$H" all "--jq=.x"; refused "a head that reads as an option is refused"

echo ""
echo "=== only repos the user added: every verb that reaches GitHub, reads included ==="
U="$S/disk/unadded"; G init -q "$U"; git -C "$U" remote add origin https://github.com/o/other
ctl pr-view-json "$U" 7; refused "a PR read of a repo the user did not add is refused, and gh never runs"
assert_has "with the reason" "not one of the user's repos" "$OUT"
for v in "pr-list-json $U open" "pr-view $U 7" "pr-list $U" "pr-merge $U 7" "protection $U"; do
    # shellcheck disable=SC2086  # the verb and its words, split on purpose
    ctl $v; refused "'${v%% *}' on a repo the user did not add is refused"
done
G init -q --bare "$F/o/other.git"; G -C "$W" push -q "$F/o/other.git" main 2>/dev/null
git -C "$U" remote set-url origin "$F/o/other.git"; G -C "$U" fetch -q origin 2>/dev/null
G -C "$U" switch -q -c sneak origin/main 2>/dev/null; G -C "$U" commit -q --allow-empty -m "Sneak"
ctl push "$U" sneak; refused "a push to a repo the user did not add is refused"
assert_eq "nothing reached it, and gitrun made no copy of it" "none no" \
    "$(git -C "$F/o/other.git" rev-parse -q --verify refs/heads/sneak || echo none) $([ -e "$STORE/o/other.git" ] && echo yes || echo no)"
ctl has-copy o/r; assert_eq "has-copy: yes for an added repo" "0 yes" "$RC $OUT"
ctl has-copy o/other; refused "has-copy: refused for one not added"
AIDC_GITCTL_ROLE=run ctl fetch o/other; refused "called as gitrun directly, fetch makes no copy of a repo not added"
assert_eq "none made" no "$([ -e "$STORE/o/other.git" ] && echo yes || echo no)"
# The same holds when gitcred is reached through sudo directly (the agent can run that): gitcred
# asks gitrun itself, every verb that names a repo, before gh runs.
for v in "pr-merge o/other 7" "pr-merge o/other 7 $(printf 'a%.0s' $(seq 40))" "pr-view o/other 7" "pr-list o/other" \
         "pr-view-json o/other 7" "pr-list-json o/other open" "protection o/other" "protect o/other"; do
    # shellcheck disable=SC2086  # the verb and its words, split on purpose
    AIDC_GITCTL_ROLE=cred ctl $v; refused "called as gitcred directly, '${v%% *}' on a repo the user did not add is refused"
    assert_has "with the reason" "not one of the user's repos" "$OUT"
done
AIDC_GITCTL_ROLE=cred ctl_in $'Title\nBody.' pr-create o/other feature main; refused "called as gitcred directly, 'pr-create' on a repo the user did not add is refused"
AIDC_GITCTL_ROLE=cred ctl_in "Body." pr-comment o/other 7; refused "called as gitcred directly, 'pr-comment' on a repo the user did not add is refused"
AIDC_GITCTL_ROLE=cred ctl pr-view o/r 7
assert_eq "an added repo still works as gitcred" "pr view 7 --repo o/r " "$CALLS"

echo ""
echo "=== added means on the user's list: the agent cannot make gitrun take a repo ==="
# The agent (uid git, or gitwc on Docker) reaches gitrun's add-copy through sudo directly, runs
# gitctl clone itself (the command aidc repo add runs), and can adopt a working copy whose origin
# it set. None of them adds a repo: gitrun refuses every repo off the list, and has-copy (what
# gitcred asks) answers no for one, even with a private copy in the store.
other_copy() { [ -d "$STORE/o/other.git" ] && echo yes || echo no; }
AIDC_GITCTL_ROLE=run AIDC_GITCTL_CALLER=git ctl add-copy o/other
refused "the agent's add-copy through sudo (as gitrun) of a repo off the list is refused"
assert_has "saying the user adds it" "aidc repo add o/other" "$OUT"
AIDC_GITCTL_ROLE=run AIDC_GITCTL_CALLER=gitwc ctl add-copy o/other; refused "gitwc's add-copy (as gitrun) of a repo off the list is refused"
mkdir -p "$S/disk/sneak-clone"; ctl clone o/other "$S/disk/sneak-clone"
refused "the agent's own gitctl clone of a repo off the list is refused"
assert_eq "and leaves the folder empty" "" "$(ls -A "$S/disk/sneak-clone")"
ctl adopt "$U"; refused "the agent's adopt of a working copy whose origin it set to a repo off the list is refused"
assert_eq "none of them made a copy" no "$(other_copy)"
ctl has-copy o/other; refused "has-copy then answers no"
AIDC_GITCTL_ROLE=cred ctl pr-merge o/other 7; refused "and gitcred's merge of it is refused before gh runs"
# A copy in the store is not "added": one left over (or made while the repo was listed) does not count.
list_add o/other
AIDC_GITCTL_ROLE=run AIDC_GITCTL_CALLER=git bash "$GITCTL/gitctl.sh" add-copy o/other >/dev/null 2>&1; RC=$?
assert_eq "once the user lists the repo, add-copy makes its copy" "0 yes" "$RC $(other_copy)"
ctl has-copy o/other; assert_eq "and has-copy answers yes" "0 yes" "$RC $OUT"
AIDC_GITCTL_ROLE=cred ctl pr-merge o/other 7
assert_has "and gitcred merges it" "pr merge 7 --repo o/other" "$CALLS"
list_del o/other
ctl has-copy o/other; refused "taken off the list, has-copy answers no though the copy is still there"
assert_eq "(it is)" yes "$(other_copy)"
AIDC_GITCTL_ROLE=cred ctl pr-merge o/other 7; refused "and gitcred's merge is refused"
AIDC_GITCTL_ROLE=run ctl fetch o/other; refused "and gitrun's fetch of it"
AIDC_GITCTL_ROLE=run ctl remove-copy o/other
assert_eq "remove-copy still deletes a copy off the list (aidc repo remove)" "0 no" "$RC $(other_copy)"
AIDC_GITCTL_ADDED_LIST="" ctl has-copy o/r; refused "with no list at all, nothing is added (has-copy answers no)"
AIDC_GITCTL_ADDED_LIST="$S/no-such-list" AIDC_GITCTL_ROLE=cred ctl pr-view o/r 7; refused "and gitcred acts on nothing"

echo ""
echo "=== an approved request acts on the repo and commit it was approved for ==="
ctl pr-view-json "$H" 7 --expect-repo o/r
assert_has "--expect-repo naming the working copy's repo: the verb runs" "pr view 7 --repo o/r --json" "$CALLS"
ctl pr-merge "$H" 5 --expect-repo o/elsewhere; refused "a working copy whose origin is not the approved repo: refused before gh runs"
assert_has "saying what changed" "origin is now o/r, not o/elsewhere as approved" "$OUT"
G -C "$W" switch -q feature; G -C "$W" commit -q --allow-empty -m "Approved"
approved=$(git -C "$W" rev-parse feature); before=$(remote_sha feature)
ctl push "$W" feature --expect-repo o/other; refused "a push whose working copy is not the approved repo is refused"
assert_eq "and nothing is pushed" "$before" "$(remote_sha feature)"
G -C "$W" commit -q --allow-empty -m "Added after approval"
ctl push "$W" feature --expect-repo o/r --expect-commit "$approved"; refused "a push whose branch moved since approval is refused"
assert_has "saying so" "moved since it was approved" "$OUT"
assert_eq "and nothing is pushed" "$before" "$(remote_sha feature)"
G -C "$W" reset -q --hard "$approved"
ctl push "$W" feature --expect-repo o/r --expect-commit "$approved"
assert_eq "the approved commit, unchanged, is pushed" "0 $approved" "$RC $(remote_sha feature)"
ctl push "$W" feature --expect-commit "abc"; refused "--expect-commit takes a full commit id"
ctl pr-view-json "$H" 7 --expect-commit "$approved"; refused "only push takes --expect-commit"
ctl storage --expect-repo o/r; refused "a verb on no working copy takes no --expect-repo"
ctl pr-view-json "$H" 7 --expect-repo "o/r;x"; refused "--expect-repo must be an owner/name"

echo ""
echo "=== push never moves origin's default branch, whatever its name ==="
G init -q --bare "$F/o/t.git"; git --git-dir="$F/o/t.git" symbolic-ref HEAD refs/heads/trunk
TT="$S/t-seed"; G clone -q "$F/o/t.git" "$TT" 2>/dev/null
G -C "$TT" switch -q -c trunk 2>/dev/null; G -C "$TT" commit -q --allow-empty -m "first"; G -C "$TT" push -q origin trunk 2>/dev/null
TC="$S/disk/trunked"; mkdir -p "$TC"; list_add O/T; ctl clone o/t "$TC"
assert_eq "a repo whose default branch is trunk is added, on trunk" "0 trunk" "$RC $(git -C "$TC" branch --show-current)"
G -C "$TC" commit -q --allow-empty -m "Straight to trunk"
tbefore=$(git --git-dir="$F/o/t.git" rev-parse trunk)
ctl push "$TC" trunk; refused "pushing to the default branch trunk directly is refused"
assert_has "with the reason" "origin's default branch" "$OUT"
assert_eq "and trunk on GitHub is unchanged" "$tbefore" "$(git --git-dir="$F/o/t.git" rev-parse trunk)"
G -C "$TC" switch -q -c topic; ctl push "$TC" topic
assert_eq "another branch of that repo still pushes" 0 "$RC"

echo ""
echo "=== an author or committer that is an AI tool, at any email ==="
for id in "Claude <x@example.invalid>" "author Claude <claude@example.invalid> 1700000000 +0000" "Gemini <x@y>" \
          "Someone <someone@anthropic.com>" "committer A <copilot@users.noreply.github.com> 1 +0000" "GPT-4 <a@example.com>" \
          "dependabot[bot] <1+dependabot[bot]@users.noreply.github.com>" "Dev <devin@cognition.ai>" "x <claude-code@example.com>" \
          "ChatGPT <a@example.com>" "Cursor Agent <cursoragent@cursor.com>" "Codeium <a@codeium.com>"; do
    if gitctl_ai_identity "$id"; then pass "AI identity: $id"; else fail "AI identity missed: $id"; fi
done
for id in "Someone <someone@example.com>" "Mark Claudel <m@example.com>" "Aiden Smith <aiden@example.com>" \
          "author Octo Cat <42+octo@users.noreply.github.com> 1 +0000"; do
    if gitctl_ai_identity "$id"; then fail "a false hit: $id"; else pass "a person: $id"; fi
done
GITCTL_OWN_NAME="Devin Jones" GITCTL_OWN_EMAIL="devin@example.com"
if gitctl_ai_identity "author Devin Jones <devin@example.com> 1 +0000"; then fail "the user's own identity is refused"
else pass "the user's own identity (a name on the list) is never refused"; fi
if gitctl_ai_identity "author Devin Jones <claude@example.invalid> 1 +0000"; then pass "but an AI email beside the user's name is"
else fail "an AI email beside the user's name passed"; fi
# shellcheck disable=SC2034  # read by gitctl_ai_identity (gitctl-rules.sh, sourced above)
GITCTL_OWN_NAME="" GITCTL_OWN_EMAIL=""
G -C "$W" switch -q feature
git -C "$W" -c user.name=Claude -c user.email=claude@example.invalid commit -q --allow-empty -m "Plain message"
before=$(remote_sha feature)
ctl push "$W" feature; refused "a commit authored as Claude <claude@example.invalid> is not pushed"
assert_eq "and nothing reached the remote" "$before" "$(remote_sha feature)"
G -C "$W" reset -q --hard HEAD~1
# The user's own identity comes from the login's identity file (gitctl login writes it).
printf '[user]\n\tname = Devin Jones\n\temail = devin@example.com\n' > "$CRED/git-identity"
git -C "$W" -c user.name="Devin Jones" -c user.email=devin@example.com commit -q --allow-empty -m "The user's own"
ctl push "$W" feature
assert_eq "a commit with the user's own identity is pushed, whatever the name" "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
rm -f "$CRED/git-identity"
G -C "$W" switch -q main

echo ""
echo "=== the action log: what changed GitHub, kept where the agent cannot write ==="
ctl log
assert_has "a push is recorded by gitrun: verb, repo, branch, commit, who asked, result" \
    "push o/r feature $(git -C "$W" rev-parse feature) asked-by=direct" "$OUT"
assert_has "pull request merges are recorded by gitcred" "pr-merge o/r #5 $(printf 'a%.0s' $(seq 40)) asked-by=direct" "$OUT"
assert_has "and pull requests opened" "pr-create o/r feature->main - asked-by=direct" "$OUT"
assert_has "and comments" "pr-comment o/r #5" "$OUT"
case "$OUT" in *" fetch "*|*" pr-view "*|*" has-copy "*) fail "reads are not recorded" ;; *) pass "reads are not recorded" ;; esac
assert_eq "in time order" "$(printf '%s\n' "$OUT" | LC_ALL=C sort -s -k1,1)" "$OUT"
assert_eq "gitrun's log is in its private store, gitcred's in its home" "yes yes" \
    "$([ -f "$STORE/.actions.log" ] && echo yes || echo no) $([ -f "$CRED/actions.log" ] && echo yes || echo no)"
id=0123456789abcdef0123456789abcdef
G -C "$W" switch -q feature; G -C "$W" commit -q --allow-empty -m "Asked for"
ctl push "$W" feature --asked-by "$id"
ctl log 1
assert_has "a request's id goes with the action (--asked-by)" "push o/r feature $(git -C "$W" rev-parse feature) asked-by=${id}" "$OUT"
ctl push "$W" feature --asked-by "not-an-id"; refused "--asked-by takes a request id or direct"
ctl log 3x; refused "log takes a number of lines"
: > "$STORE/.actions.log"; rm -f "$STORE/.actions.log.1"
for i in 1 2 3 4 5 6; do
    G -C "$W" commit -q --allow-empty -m "Capped $i"
    AIDC_GITCTL_ACTION_LOG_BYTES=300 ctl push "$W" feature
done
assert_eq "the log is capped: past the cap it moves to one older file, and no more are kept" "yes no" \
    "$([ -f "$STORE/.actions.log.1" ] && echo yes || echo no) $([ -e "$STORE/.actions.log.2" ] && echo yes || echo no)"
assert_eq "so neither file grows past the cap plus a line" yes \
    "$([ "$(stat -c %s "$STORE/.actions.log")" -lt 600 ] && [ "$(stat -c %s "$STORE/.actions.log.1")" -lt 600 ] && echo yes || echo no)"
ctl log 100
assert_has "and the log still shows the last push" "push o/r feature $(git -C "$W" rev-parse feature)" "$OUT"
G -C "$W" switch -q main

echo ""
echo "=== removing a guard is caught (these tests are not vacuous) ==="
# gitctl.sh and the files it sources (each trust side's, and the shared rules).
mut() { rm -rf "$S/mut"; cp -r "$GITCTL" "$S/mut"; sed -i "$1" "$S/mut"/gitctl*.sh; }
mut 's/gitctl_check_text "$raw" "commit ${sha:0:12}" || die/: || die/'
G -C "$W" switch -q feature
G -C "$W" commit -q --allow-empty -m "Fix" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
bash "$S/mut/gitctl.sh" push "$W" feature >/dev/null 2>&1
assert_eq "with the push scan removed, the attributed commit reaches the remote (so the test above would fail)" \
    "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
mut 's/\[ "$branch" = "$b" \] && die/[ "$branch" = "$b" ] \&\& :/; s/\[ "$branch" != "$ORIGIN_HEAD" \]/true/'
G -C "$W" switch -q main
ctl fetch "$W"
G -C "$W" reset -q --hard origin/main
G -C "$W" commit -q --allow-empty -m "Straight to main"
bash "$S/mut/gitctl.sh" push "$W" main >/dev/null 2>&1
assert_eq "with the protected-branch guards removed (the fixed names and origin's default), a push to main goes through" \
    "$(git -C "$W" rev-parse main)" "$(remote_sha main)"
mut 's/\[ "$branch" = "$b" \] && die/[ "$branch" = "$b" ] \&\& :/'
G -C "$W" switch -q -c develop main; G -C "$W" commit -q --allow-empty -m "Straight to develop"
ctl push "$W" develop; refused "pushing to develop (not origin's default) directly is refused"
bash "$S/mut/gitctl.sh" push "$W" develop >/dev/null 2>&1
assert_eq "with only the fixed-name guard removed, a push to develop goes through (so that guard is not covered by the default-branch one)" \
    "$(git -C "$W" rev-parse develop)" "$(remote_sha develop)"
G -C "$W" switch -q main

mut 's/"$git" -c core.hooksPath=\/dev\/null -c core.fsmonitor=false -c gc.auto=0/"$git" -c gc.auto=0/'
git -C "$W" config core.hooksPath "$S/evil-hooks"
bash "$S/mut/gitctl.sh" fetch "$W" >/dev/null 2>&1
git -C "$W" config --unset core.hooksPath
assert_eq "with the agent's hook pin removed, a hook planted in the working copy runs (so the hostile-config test would fail)" yes \
    "$([ -e "$S/PWNED-hook" ] && echo yes || echo no)"
rm -f "$S/PWNED-hook"
mut 's/GIT_CONFIG_COUNT="$n" ${envs\[@\]+"${envs\[@\]}"}/GIT_CONFIG_COUNT=0/'
touch -d '3 hours ago' "$FC/README"
bash "$S/mut/gitctl.sh" unpushed "$FC" >/dev/null 2>&1
assert_eq "with the filter override removed, the planted clean filter runs (so the filter test would fail)" yes \
    "$([ -n "$(find "$S" -maxdepth 1 -name 'PWNED-*')" ] && echo yes || echo no)"
rm -f "$S"/PWNED-*
mut "s/trap 'rm -f \"\$RUN_BUNDLE\" \"\${RUN_BUNDLE}.added\" \"\${RUN_BUNDLE}.err\"; /trap '/"
G -C "$W" commit -q --allow-empty -m "Left behind?"
bash "$S/mut/gitctl.sh" push "$W" feature >/dev/null 2>&1
assert_eq "with gitrun's bundle cleanup removed, the bundle stays (so the cleanup test would fail)" yes \
    "$([ -n "$(find "$STORE" -name 'incoming.*')" ] && echo yes || echo no)"
find "$STORE" -name 'incoming.*' -delete
mut 's/\[ "${SLUG,,}" != "${EXPECT_SLUG,,}" \]/false/'
G -C "$W" switch -q feature; G -C "$W" commit -q --allow-empty -m "Elsewhere?"
bash "$S/mut/gitctl.sh" push "$W" feature --expect-repo o/other >/dev/null 2>&1
assert_eq "with the approved-repo check removed, the push goes through (so the binding test would fail)" \
    "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
mut 's/\[ "$branch" != "$ORIGIN_HEAD" \]/true/'
bash "$S/mut/gitctl.sh" push "$TC" trunk >/dev/null 2>&1
assert_eq "with the default-branch guard removed, trunk is pushed (so the trunk test would fail)" \
    "$(git -C "$TC" rev-parse trunk)" "$(git --git-dir="$F/o/t.git" rev-parse trunk)"
mut 's/fetch|tidy|unpushed) docker_wc_ok "$WC" ;;/fetch|tidy|unpushed) : ;;/'
AIDC_GITCTL_DOCKER=1 bash "$S/mut/gitctl.sh" fetch "$AR" >/dev/null 2>&1
assert_eq "with the mounted-working-copy check removed, Docker's fetch takes a repo the agent made (so the gitwc test would fail)" \
    yes "$(ar_fetched)"
mut 's/if ! removable "$wt"; then/if false; then/'
bash "$S/mut/gitctl.sh" tidy "$T" >/dev/null 2>&1
assert_eq "with tidy's folder check removed, the planted request folder is deleted (so the tidy test would fail)" no \
    "$([ -d "$REQS" ] && echo yes || echo no)"

mut 's/^    { \[ -n "$ADDED_LIST" \] && \[ -f "$ADDED_LIST" \] && \[ -r "$ADDED_LIST" \]; } || return 1$/    return 0/'
grep -q '^    return 0$' "$S/mut/gitctl-run.sh" || fail "the list-check mutation did not apply"
: > "$S/bin/calls.log"
AIDC_GITCTL_ROLE=run bash "$S/mut/gitctl.sh" add-copy o/other >/dev/null 2>&1
AIDC_GITCTL_ROLE=cred bash "$S/mut/gitctl.sh" pr-merge o/other 7 >/dev/null 2>&1
assert_has "with gitrun's added-repos list check removed, the agent's add-copy makes a copy and gitcred merges a repo the user never added (so the list tests would fail)" \
    "pr merge 7 --repo o/other" "$(cat "$S/bin/calls.log")"
rm -rf "$STORE/o/other.git"
mut 's/           cred_added "$1" ;;/           : ;;/'
: > "$S/bin/calls.log"
AIDC_GITCTL_ROLE=cred bash "$S/mut/gitctl.sh" pr-merge o/other 7 >/dev/null 2>&1
assert_has "with gitcred's own added-repos check removed, a direct merge of a repo not added reaches gh (so the gitcred tests would fail)" \
    "pr merge 7 --repo o/other" "$(cat "$S/bin/calls.log")"
mut 's/case "$verb" in fetch|tidy|unpushed) ;; \*) die "${verb} does not run as gitwc/case "$verb" in *) ;; esac; case "" in x) die "${verb} does not run as gitwc/; s/\[ "$AS_WC" = 0 \] || die "gitwc reads no file"/:/'
printf 'SECRET=1\n' > "$AW/.env"
: > "$S/bin/calls.log"
AIDC_GITCTL_DOCKER=1 AIDC_GITCTL_AS_WC=1 bash "$S/mut/gitctl.sh" pr-create "$AW" main main --title-file "$AW/.env" --body-file "$AW/.env" >/dev/null 2>&1
assert_has "with the gitwc guards removed, gitwc reads the user's file into a pull request (so the gitwc tests would fail)" \
    "SECRET=1" "$(cat "$S/bin/calls.log")"
rm -f "$AW/.env"
mut 's/        if printf .%s.n. "$words" | LC_ALL=C tr/        if false \&\& printf "%s" "$words" | LC_ALL=C tr/'
G -C "$W" switch -q feature
git -C "$W" -c user.name=Claude -c user.email=claude@example.invalid commit -q --allow-empty -m "Plain message"
bash "$S/mut/gitctl.sh" push "$W" feature >/dev/null 2>&1
assert_eq "with the AI-identity match removed, a commit by Claude <claude@example.invalid> is pushed (so the identity test would fail)" \
    "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
G -C "$W" switch -q main
mut 's/            \[ $# = 2 \] || \[ "$head" = "$3" \] \\/            true \\/'
: > "$S/bin/calls.log"
bash "$S/mut/gitctl.sh" pr-merge "$H" 5 --expect-head "$(printf 'b%.0s' $(seq 40))" >/dev/null 2>&1
assert_has "with the approved-head check removed, a moved PR is merged (so the head test would fail)" "pr merge 5" "$(cat "$S/bin/calls.log")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
