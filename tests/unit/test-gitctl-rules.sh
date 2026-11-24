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
# stand-in forge, gitrun's store and the bundle folder from AIDC_GITCTL_TEST_FORGE,
# AIDC_GITCTL_RUN_STORE and AIDC_GITCTL_BUNDLE_DIR; installed, it ignores them. Needs jq.
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
# The user adds the repo (aidc repo add: gitctl clone), which gives gitrun its private copy;
# gitctl reaches GitHub for no repo the user has not added.
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

printf '{"title":"Add it","body":"Clean.","commits":[{"messageHeadline":"Add it","messageBody":"","authors":[{"name":"Someone","email":"someone@example.com"}]}]}' > "$S/bin/prview.json"
ctl pr-merge "$H" 5
assert_eq "pr-merge reads the PR, then merges with a merge commit, nothing else" \
    "pr view 5 --repo o/r --json title\\,body\\,commits 
pr merge 5 --repo o/r --merge " "$CALLS"
for extra in --squash "--squash=t" "--merge=0" --rebase -s; do
    ctl pr-merge "$H" 5 "$extra"; refused "pr-merge takes no '$extra'"
done
ctl pr-merge "$H" "5;x"; refused "a PR number must be a number"
printf '{"title":"Add it","body":"","commits":[{"messageHeadline":"Fix","messageBody":"Co-Authored-By: Claude <noreply@anthropic.com>","authors":[]}]}' > "$S/bin/prview.json"
ctl pr-merge "$H" 5
assert_eq "a PR carrying an attributed commit is not merged" "pr view 5 --repo o/r --json title\\,body\\,commits " "$CALLS"
printf '{"title":"Add it","body":"","commits":[{"messageHeadline":"Fix","messageBody":"","authors":[{"name":"Copilot","email":"copilot@users.noreply.github.com"}]}]}' > "$S/bin/prview.json"
ctl pr-merge "$H" 5
assert_eq "a PR with a commit authored as an AI tool is not merged" "pr view 5 --repo o/r --json title\\,body\\,commits " "$CALLS"

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
assert_has "/opt/aidc/bin (gitctl, and a gh that points to it) comes first on PATH" 'ENV PATH="/opt/aidc/bin:' "$df"
assert_has "gitctl is installed" "ln -s /opt/aidc/lib/gitctl/gitctl.sh /opt/aidc/bin/gitctl" "$df"
assert_has "plain gh points to gitctl (a gh login as the agent would be readable by it)" "ln -s /opt/aidc/lib/gitctl/gh-shim.sh /opt/aidc/bin/gh" "$df"
assert_has "the sudo rules are root's, 0440" "chmod 0440 /etc/sudoers.d/aidc-gitctl" "$df"
assert_has "and checked at build" "visudo -c -f /etc/sudoers.d/aidc-gitctl" "$df"
assert_has "the managed settings are installed" "COPY managed-settings.json /etc/claude-code/managed-settings.json" "$df"
assert_eq "the sudo rules are exactly: the agent to gitctl (gitwc for working-copy writes on Docker), gitrun to the credential helper" \
"git ALL=(gitrun,gitcred,gitwc) NOPASSWD: /opt/aidc/lib/gitctl/gitctl.sh
gitwc ALL=(gitrun,gitcred) NOPASSWD: /opt/aidc/lib/gitctl/gitctl.sh
gitrun ALL=(gitcred) NOPASSWD: /opt/aidc/lib/gitctl/cred-helper.sh" \
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
    "$(git -C "$T" rev-parse -q --verify d-hidden >/dev/null && echo yes || echo no) $(ls "$T/.git/worktrees" | grep -q d-hidden && echo yes || echo no)"
mv "$S/d-hidden-on-host" "$S/disk/d-hidden"
mkdir -p "$S/disk/dclone"; AIDC_GITCTL_DOCKER=1 ctl clone o/r "$S/disk/dclone"
refused "clone is refused on Docker (the git container works on the user's own working copies)"
assert_has "and says to add the user's own" "aidc repo add <path>" "$OUT"
# adopt: an existing working copy's repo becomes one the user added; the copy is only read.
A="$S/forge/o/adopted.git"; G init -q --bare "$A"
AW="$S/disk/adopted"; G clone -q "$A" "$AW" 2>/dev/null; G -C "$AW" commit -q --allow-empty -m "first"; G -C "$AW" push -q origin HEAD:main 2>/dev/null
ctl fetch "$AW"; refused "before adopt, the repo is not one the user added: fetch is refused"
cfg=$(md5sum < "$AW/.git/config")
ctl adopt "$AW"
assert_eq "adopt makes gitrun's private copy" "0 yes" "$RC $([ -d "$STORE/o/adopted.git" ] && echo yes || echo no)"
assert_has "and says which repo" "added o/adopted" "$OUT"
assert_eq "the working copy's config is not changed" "$cfg" "$(md5sum < "$AW/.git/config")"
assert_eq "no bundle left behind" "" "$(ls -A "$BUNDLES")"
ctl fetch "$AW"; assert_eq "after it, fetch works" 0 "$RC"
H2="$S/disk/notgh"; G init -q "$H2"; git -C "$H2" remote add origin git@github.com:o/x.git
ctl adopt "$H2"; refused "adopt refuses an origin that is not https://github.com/<owner>/<name>"
ctl adopt "$AW" extra; refused "adopt takes one argument"
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
TC="$S/disk/trunked"; mkdir -p "$TC"; ctl clone o/t "$TC"
assert_eq "a repo whose default branch is trunk is added, on trunk" "0 trunk" "$RC $(git -C "$TC" branch --show-current)"
G -C "$TC" commit -q --allow-empty -m "Straight to trunk"
tbefore=$(git --git-dir="$F/o/t.git" rev-parse trunk)
ctl push "$TC" trunk; refused "pushing to the default branch trunk directly is refused"
assert_has "with the reason" "origin's default branch" "$OUT"
assert_eq "and trunk on GitHub is unchanged" "$tbefore" "$(git --git-dir="$F/o/t.git" rev-parse trunk)"
G -C "$TC" switch -q -c topic; ctl push "$TC" topic
assert_eq "another branch of that repo still pushes" 0 "$RC"

echo ""
echo "=== removing a guard is caught (these tests are not vacuous) ==="
mut() { rm -rf "$S/mut"; cp -r "$GITCTL" "$S/mut"; sed -i "$1" "$S/mut/gitctl.sh" "$S/mut/gitctl-rules.sh"; }
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
mut "s/trap 'rm -f \"\$RUN_BUNDLE\"; /trap '/"
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
mut 's/if ! removable "$wt"; then/if false; then/'
bash "$S/mut/gitctl.sh" tidy "$T" >/dev/null 2>&1
assert_eq "with tidy's folder check removed, the planted request folder is deleted (so the tidy test would fail)" no \
    "$([ -d "$REQS" ] && echo yes || echo no)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
