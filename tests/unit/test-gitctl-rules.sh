#!/usr/bin/env bash
# Unit tests for the git container's hard rules: gitctl (gitctl/gitctl.sh), the only way to the
# GitHub login, its shared rules (gitctl/gitctl-rules.sh) and Claude Code's PreToolUse hook.
#
# The agent holds no credential; gitctl's verbs are the only things that push, open, comment on
# or merge a pull request, so a verb that lets a caller's text through as an option, pushes an
# attributed or forced commit, trusts a ref a session can move, or reads a file as gitcred
# breaks the owner's rules on GitHub or hands out the token. Each refusal is checked against
# the real outcome: the bare remote's refs for pushes (real git, a local bare repo standing in
# for GitHub), and a stub gh that records what it was asked to run. The last section removes
# two guards and shows these tests notice.
#
# Run from a checkout, gitctl skips sudo (the role is named in AIDC_GITCTL_ROLE) and may accept
# a local-path origin (AIDC_GITCTL_ALLOW_LOCAL_ORIGIN=1); installed, it ignores both. Needs jq.
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
esac
exit 0
STUB
chmod +x "$S/bin/gh"
AIDC_GITCTL_REAL_GIT=$(command -v git)
export AIDC_GITCTL_REAL_GH="$S/bin/gh" AIDC_GITCTL_REAL_GIT
unset AIDC_GITCTL_ROLE AIDC_GITCTL_ALLOW_LOCAL_ORIGIN
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
echo "=== push: a bare repo stands in for GitHub ==="
export AIDC_GITCTL_ALLOW_LOCAL_ORIGIN=1
R="$S/remote.git" W="$S/work"
G init -q --bare "$R"
G clone -q "$R" "$W" 2>/dev/null
G -C "$W" commit -q --allow-empty -m "first"
G -C "$W" push -q origin HEAD:main 2>/dev/null
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

G -C "$W" tag -a v1 -m "A tag" && git -C "$W" config push.followTags true
G -C "$W" commit -q --allow-empty -m "Again"
ctl push "$W" feature
assert_eq "the push still works" "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
assert_eq "and never carries tags, whatever the repo's config says" "" "$(git -C "$R" tag)"
git -C "$W" config --unset push.followTags

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
ctl fetch "$W"
assert_eq "fetch brings origin's commits" "$(git -C "$R" rev-parse main)" "$(git -C "$W" rev-parse origin/main)"

echo ""
echo "=== the repo must be one the git container owns, with config only it can change ==="
chmod g+w "$W/.git/config"; ctl fetch "$W"; refused "a group-writable .git/config is refused"; chmod g-w "$W/.git/config"
chmod g+w "$W/.git"; ctl fetch "$W"; refused "a group-writable .git is refused"; chmod g-w "$W/.git"
printf '[include]\n\tpath = /tmp/x\n' >> "$W/.git/config"; ctl fetch "$W"; refused "a config that includes another file is refused"
sed -i '/^\[include\]/,$d' "$W/.git/config"
L="$S/linked"; G init -q "$L"; mv "$L/.git/config" "$S/linked-config"; ln -s "$S/linked-config" "$L/.git/config"
ctl fetch "$L"; refused "a .git/config that is a symlink is refused"
WT="$S/wt"; G -C "$W" worktree add -q "$WT" -b wtb 2>/dev/null
ctl fetch "$WT"; refused "a worktree (a .git file, not the main checkout) is refused"
ctl fetch "$S/nope"; refused "a missing folder is refused"
unset AIDC_GITCTL_ALLOW_LOCAL_ORIGIN
ctl fetch "$W"; refused "a local-path origin is refused outside the tests"
H="$S/gh-shaped"; G init -q "$H"
for u in http://github.com/o/r.git git@github.com:o/r.git https://example.com/o/r.git 'ext::sh -c x' https://github.com/o; do
    git -C "$H" remote remove origin 2>/dev/null; git -C "$H" remote add origin "$u"
    ctl fetch "$H"; refused "origin $u is refused (https://github.com/<owner>/<name> only)"
done
git -C "$H" remote set-url origin https://github.com/o/r.git
git -C "$H" config url.https://example.com/.insteadOf https://github.com/
ctl fetch "$H"; refused "an insteadOf that sends origin elsewhere is refused"
git -C "$H" config --unset url.https://example.com/.insteadOf
git -C "$H" remote set-url --add --push origin https://github.com/someone/else.git
ctl fetch "$H"; refused "a push URL naming another repo is refused"
git -C "$H" remote set-url --delete --push origin https://github.com/someone/else.git

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
assert_eq "the sudo rules are exactly: the agent to gitctl, gitrun to the credential helper" \
"git ALL=(gitrun,gitcred) NOPASSWD: /opt/aidc/lib/gitctl/gitctl.sh
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
echo "=== removing a guard is caught (these tests are not vacuous) ==="
export AIDC_GITCTL_ALLOW_LOCAL_ORIGIN=1
mut() { rm -rf "$S/mut"; cp -r "$GITCTL" "$S/mut"; sed -i "$1" "$S/mut/gitctl.sh"; }
mut 's/gitctl_check_text "$body" "commit ${h:0:12}" || die/: || die/'
G -C "$W" switch -q feature
G -C "$W" commit -q --allow-empty -m "Fix" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
bash "$S/mut/gitctl.sh" push "$W" feature >/dev/null 2>&1
assert_eq "with the push scan removed, the attributed commit reaches the remote (so the test above would fail)" \
    "$(git -C "$W" rev-parse feature)" "$(remote_sha feature)"
mut 's/\[ "$branch" = "$b" \] && die/[ "$branch" = "$b" ] \&\& :/'
G -C "$W" switch -q main
G -C "$W" reset -q --hard origin/main
G -C "$W" commit -q --allow-empty -m "Straight to main"
bash "$S/mut/gitctl.sh" push "$W" main >/dev/null 2>&1
assert_eq "with the protected-branch guard removed, a push to main goes through" \
    "$(git -C "$W" rev-parse main)" "$(remote_sha main)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
