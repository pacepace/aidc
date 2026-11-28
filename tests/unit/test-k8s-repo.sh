#!/usr/bin/env bash
# Unit tests for repos on the Kubernetes backend: `aidc repo add|list|remove`, and `aidc create`
# taking no --repo there (sessions make their own worktrees).
#
# The folder step runs as root on the user's disk, so a symlink it followed or a capability too
# many would hand a session someone else's files, and a delete that was not asked for would lose
# the sessions' work; an add that guessed "nothing there" when the git container could not be
# asked would clone over a repo; a remove that kept gitrun's copy would let copies pile up.
# kubectl is a PATH stub; HOME holds the config. The script the folder pod runs is run here for
# real, with chown, chmod and rm stubbed (they need root or would delete). gitctl itself is
# tested with real git in test-gitctl-rules.sh. Needs yq and jq.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-repo-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/aidc"

for t in yq jq; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }
done

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
assert_has() {
    case "$3" in *"$2"*) pass "$1" ;;
        *) fail "$1 (no '$2' in:"; printf '%s\n' "$3" | tail -12 | sed 's/^/      /'; echo "    )" ;; esac
}
assert_not_has() {
    case "$3" in *"$2"*) fail "$1 ('$2' present in:"; printf '%s\n' "$3" | tail -12 | sed 's/^/      /'; echo "    )" ;;
        *) pass "$1" ;; esac
}

# kubectl stub: logs calls; apply appends stdin to $K_APPLIED.
#   K_DOWN=1          every call fails as an unreachable cluster does
#   K_NO_POD=1        no running git pod
#   K_STATE=empty|repo|other|folder   what is at a path (default empty; repo: octo/hello's)
#   K_EXEC_FAIL=1     exec into the git pod fails
#   K_FAIL_STEP=make|own|delete   that folder step's pod fails (K_DIR_LOG its log)
#   K_CLONE_FAIL=1 / K_RM_FAIL=1  gitctl clone / remove-copy fail
#   K_LIST="rows"     repo list rows (tab-separated), K_LIST_CUT=1 drops the end marker
#   K_LIST_REAL=dir   repo list runs its real scan script over dir (with host git)
#   K_UNPUSHED="lines" what gitctl unpushed reports before its end line (printf %b);
#   K_EXEC_FAIL_UNPUSHED=1 gitctl unpushed fails (a fetch that failed)
#   K_CM (a file)     the ConfigMap git-repos (the list of added repos) as the cluster holds it:
#                     get prints it, create/replace write it (a stale resourceVersion is a conflict)
#   K_CM_FAIL=1       reading it fails as an unreachable cluster does
#   K_LIST_STALE=1    the git pod does not see the list (its mounted file is missing)
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$K_LOG"
[ "${K_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server: dial tcp: i/o timeout' >&2; exit 1; }
case "$*" in
    *"get runtimeclass"*"-o json"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"apply -f -"*) { echo ---; cat; } >> "$K_APPLIED" ;;
    *"get configmap git-repos"*)
        [ "${K_CM_FAIL:-}" = 1 ] && { echo 'Unable to connect to the server: dial tcp: i/o timeout' >&2; exit 1; }
        [ -s "$K_CM" ] && cat "$K_CM"; exit 0 ;;
    *"create -f -"*|*"replace -f -"*)
        j=$(cat); old=$(jq -r '.metadata.resourceVersion // "0"' "$K_CM" 2>/dev/null || echo 0)
        case "$*" in
            *create*) [ -s "$K_CM" ] && { echo 'Error from server (AlreadyExists)' >&2; exit 1; } ;;
            *) [ "$(printf '%s' "$j" | jq -r '.metadata.resourceVersion')" = "$old" ] || { echo 'Error from server (Conflict)' >&2; exit 1; } ;;
        esac
        printf '%s' "$j" | jq -c --arg rv "$((old + 1))" '.metadata.resourceVersion = $rv' > "$K_CM" ;;
    *"exec git-7d9f-abc -c git -- cat /etc/aidc/git-repos/repos"*)
        [ "${K_LIST_STALE:-}" = 1 ] && exit 1
        [ -s "$K_CM" ] && jq -r '.data.repos' "$K_CM"; exit 0 ;;
    *"get pod -l app=git"*)
        if [ "${K_NO_POD:-}" = 1 ]; then echo '{"items":[]}'
        else echo '{"items":[{"metadata":{"name":"git-7d9f-abc"}}]}'; fi ;;
    *"exec git-7d9f-abc -c git -- bash -c"*"find "*)
        [ "${K_EXEC_FAIL:-}" = 1 ] && { echo 'error: unable to upgrade connection' >&2; exit 1; }
        if [ -n "${K_LIST_REAL:-}" ]; then
            while [ "$1" != -- ]; do shift; done
            exec bash -c "$4" bash "$K_LIST_REAL"
        fi
        [ -n "${K_LIST:-}" ] && printf '%s\n' "$K_LIST" | sed 's/^/repo=/'
        [ "${K_LIST_CUT:-}" = 1 ] || echo end ;;
    *"exec git-7d9f-abc -c git -- sh -c"*"state=repo"*)
        [ "${K_EXEC_FAIL:-}" = 1 ] && { echo 'error: unable to upgrade connection' >&2; exit 1; }
        case "${K_STATE:-empty}" in
            repo) echo "state=repo https://github.com/octo/hello" ;;
            other) echo "state=repo https://github.com/someone/else" ;;
            *) echo "state=${K_STATE:-empty}" ;;
        esac ;;
    *"exec git-7d9f-abc -c git -- gitctl clone"*)
        [ "${K_CLONE_FAIL:-}" = 1 ] && { echo 'gitctl: refused: cannot fetch https://github.com/o/r' >&2; exit 1; }
        echo "cloned" ;;
    *"exec git-7d9f-abc -c git -- gitctl unpushed"*)
        [ "${K_EXEC_FAIL_UNPUSHED:-}" = 1 ] && { echo 'gitctl: refused: cannot fetch https://github.com/octo/hello' >&2; exit 1; }
        [ -n "${K_UNPUSHED:-}" ] && printf '%b\n' "$K_UNPUSHED"
        echo end ;;
    *"exec git-7d9f-abc -c git -- gitctl remove-copy"*) [ "${K_RM_FAIL:-}" = 1 ] && exit 1; echo "removed" ;;
    *"get pod repo-dir-"*"jsonpath"*)
        case "$*" in *"repo-dir-${K_FAIL_STEP:-none}-"*) printf Failed ;; *) printf Succeeded ;; esac ;;
    *"logs repo-dir-"*) echo "${K_DIR_LOG:-ready: /home/alice/x}" ;;
    *"get pvc disk"*) printf 'Bound' ;;
    *"get networkpolicy default-deny"*) echo "networkpolicy.networking.k8s.io/default-deny" ;;
    *"get deployment "*"-proxy"*) case "$*" in *--ignore-not-found*) : ;; *) exit 1 ;; esac ;;
    *"get service"*"clusterIP"*) printf '10.45.9.9' ;;
    *"get pod "*"-dev-0 -o jsonpath={.metadata.uid}"*) printf 'u1|' ;;
    *"logs "*"-c dev"*) echo '[aidc-user-main] ready (tmux running, sleeping forever)' ;;
    *"create configmap"*) printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: demo-audit-seed}\ndata: {meta.json: "{}"}\n' ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"

export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" K_LOG="$SCRATCH/kubectl.log" \
    K_APPLIED="$SCRATCH/applied.yaml" K_CM="$SCRATCH/configmap.json" AIDC_K8S_GIT_REPOS_WAIT=2
# shellcheck source=lib/stub-tools.sh
. "$SCRIPT_DIR/lib/stub-tools.sh"
stub_tools "$SCRATCH/bin"
# backend: kubernetes: the cluster is this user's default (aidc_default_backend), so aidc git and
# aidc repo talk to its git container; a kubernetes: block alone would leave them on Docker.
cat > "$HOME/.config/aidc/config.yaml" <<'EOF'
backend: kubernetes
kubernetes:
  context: lab
  user: alice
  storage_class: shared-disk
  tolerations:
    - {key: role, operator: Equal, value: dev, effect: NoSchedule}
EOF
mkdir -p "$HOME/code"
run() { : > "$K_APPLIED"; : > "$K_LOG"; (cd "$HOME/code" && "$AIDC_ROOT/scripts/aidc" "$@" 2>&1 </dev/null); echo "exit=$?"; }
q() { yq -N ea "$1" -o=json -I=0 "$K_APPLIED"; }
execs() { grep ' exec ' "$K_LOG" || true; }

echo "=== aidc repo add ==="
pods() { yq -N ea 'select(.kind == "Pod") | .spec.containers[0].command[6]' "$K_APPLIED" | paste -sd' ' -; }
out=$(run repo add octo/hello)
assert_has "a repo is added" "added octo/hello at /home/alice/hello" "$out"
assert_has "exit 0" "exit=0" "$out"
assert_has "the default place is /home/<user>/<name>" "gitctl clone octo/hello /home/alice/hello" "$(execs)"
assert_eq "the folder is made for the agent, then given to the session user after the clone" "make own" "$(pods)"
make_line=$(grep -n "apply -f -" "$K_LOG" | head -1 | cut -d: -f1); clone_line=$(grep -n "gitctl clone" "$K_LOG" | cut -d: -f1)
own_line=$(grep -n "apply -f -" "$K_LOG" | tail -1 | cut -d: -f1)
assert_eq "in that order: make, clone, own" yes "$([ "$make_line" -lt "$clone_line" ] && [ "$clone_line" -lt "$own_line" ] && echo yes || echo no)"
pod() { q "select(.kind == \"Pod\" and .spec.containers[0].command[6] == \"make\") | .spec | $1"; }
assert_eq "the folder pod runs as root with only the capabilities a chown and chmod on the user's disk need" \
    '{"runAsUser":0,"runAsGroup":0,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"],"add":["CHOWN","DAC_OVERRIDE","FOWNER","FSETID"]}}' \
    "$(pod '.containers[0].securityContext')"
assert_eq "no API token, no service links, never restarted" '[false,false,"Never"]' \
    "$(pod '[.automountServiceAccountToken, .enableServiceLinks, .restartPolicy]')"
assert_eq "it mounts only the user's disk, at /home/<user>" \
    '[[{"name":"disk","mountPath":"/home/alice"}],[{"name":"disk","persistentVolumeClaim":{"claimName":"disk"}}]]' \
    "$(pod '[.containers[0].volumeMounts, .volumes]')"
assert_eq "its arguments are the folder, the disk, the mode, the agent's uid and the request holder's" '["repo-dir","/home/alice/hello","/home/alice","make","2000","2003"]' \
    "$(pod '.containers[0].command[3:]')"
assert_eq "it lands where sessions land" '[{"kubernetes.io/hostname":"n1"},[{"key":"role","operator":"Equal","value":"dev","effect":"NoSchedule"}]]' \
    "$(pod '[.nodeSelector, .tolerations]')"
assert_eq "both folder pods are deleted afterwards" 2 "$(grep -c "delete pod repo-dir-" "$K_LOG")"

for src in https://github.com/octo/hello https://github.com/octo/hello.git https://github.com/octo/hello/ git@github.com:octo/hello.git ssh://git@github.com/octo/hello.git; do
    out=$(run repo add "$src")
    assert_has "$src is octo/hello" "gitctl clone octo/hello /home/alice/hello" "$(execs)"
done
for src in http://github.com/o/r https://gitlab.com/o/r git@gitlab.com:o/r "o/r/x" "-x" "o/.." "o" "ext::sh -c x" "o/r;x"; do
    out=$(run repo add "$src")
    if [ -z "$(cat "$K_APPLIED")" ] && ! grep -q "gitctl clone" "$K_LOG" && printf '%s' "$out" | grep -q "exit=[12]"; then
        pass "'$src' is refused before anything is made"
    else fail "'$src' was not refused cleanly ($out)"; fi
done

out=$(run repo add octo/hello --path "$HOME/code/hello2")
assert_has "--path under this machine's home maps onto the disk" "gitctl clone octo/hello /home/alice/code/hello2" "$(execs)"
out=$(run repo add octo/hello --path=/home/alice/work/h)
assert_has "--path=/home/<user>/... is taken as it is" "gitctl clone octo/hello /home/alice/work/h" "$(execs)"
for p in /etc/x "/home/alice/a b" "/home/alice/a/../b" /home/alice /home/bob/x '/home/alice/x"y'; do
    out=$(run repo add octo/hello --path "$p")
    if [ -z "$(cat "$K_APPLIED")" ] && printf '%s' "$out" | grep -q "exit=1"; then pass "--path '$p' is refused"
    else fail "--path '$p' was not refused ($out)"; fi
done

out=$(K_STATE=repo run repo add octo/hello)
assert_has "a working copy of the same repo already there is said so" "already a working copy of octo/hello" "$out"
assert_has "and is not an error" "exit=0" "$out"
assert_eq "and nothing is made again" "" "$(cat "$K_APPLIED")$(grep 'gitctl clone' "$K_LOG")"
out=$(K_STATE=other run repo add octo/hello)
assert_has "a working copy of another repo there is refused" "already a git working copy, of https://github.com/someone/else" "$out"
out=$(K_STATE=folder run repo add octo/hello)
assert_has "a folder that is not empty is refused" "is not empty" "$out"
assert_eq "and nothing is made" "" "$(cat "$K_APPLIED")"
out=$(K_EXEC_FAIL=1 run repo add octo/hello)
assert_has "a git container that cannot be asked stops the add" "cannot tell what is at /home/alice/hello" "$out"
assert_eq "and nothing is made" "" "$(cat "$K_APPLIED")"
out=$(K_NO_POD=1 run repo add octo/hello)
assert_has "no git container: says to set it up" "run \`aidc git setup\` first" "$out"
out=$(K_DOWN=1 run repo add octo/hello)
assert_has "a cluster that does not answer is said so" "the cluster did not answer" "$out"
out=$(K_FAIL_STEP=make K_DIR_LOG="refused: /home/alice/hello is not empty" run repo add octo/hello)
assert_has "a folder step that fails is reported with its reason" "is not empty" "$out"
assert_not_has "and nothing is cloned" "gitctl clone" "$(cat "$K_LOG")"
assert_has "and its pod is still deleted" "delete pod repo-dir-make-" "$(cat "$K_LOG")"
out=$(K_CLONE_FAIL=1 run repo add octo/hello)
assert_has "a clone that fails is reported, naming the login private repos need" "gitctl login" "$out"
assert_has "and exits 1" "exit=1" "$out"
assert_eq "and the empty folder still goes back to the session user" "make own" "$(pods)"
out=$(K_FAIL_STEP=own run repo add octo/hello)
assert_has "a clone that cannot be given to the session user says so, with how to retry" "could not be given to the session user" "$out"

echo "=== the list of added repos: written from here, read-only in the git pod ==="
# gitctl takes "added" from that list alone (the agent can ask gitrun for a copy of anything,
# and run gitctl clone itself), so aidc repo add puts the repo on it, from the user's kubectl,
# and the git pod must see it there before the clone; a failed add takes it off again.
cm_repos() { jq -r '.data.repos' "$K_CM" 2>/dev/null | grep . || true; }
rm -f "$K_CM"
out=$(run repo add Octo/Hello)
assert_has "a repo is added" "exit=0" "$out"
assert_eq "it is on the list, lower-case" "octo/hello" "$(cm_repos)"
assert_eq "the list is the git-repos ConfigMap in the user's namespace, labelled as aidc's" \
    '{"name":"git-repos","namespace":"aidc-u-alice","labels":{"app.kubernetes.io/managed-by":"aidc","aidc/user":"alice","app":"git"}}' \
    "$(jq -c '.metadata | del(.resourceVersion)' "$K_CM")"
w_line=$(grep -nE "(create|replace) -f -" "$K_LOG" | head -1 | cut -d: -f1)
seen_line=$(grep -n "cat /etc/aidc/git-repos/repos" "$K_LOG" | head -1 | cut -d: -f1)
clone_line=$(grep -n "gitctl clone" "$K_LOG" | cut -d: -f1)
assert_eq "written, then seen by the git pod, then cloned" yes \
    "$([ "${w_line:-99}" -lt "${seen_line:-0}" ] && [ "${seen_line:-99}" -lt "${clone_line:-0}" ] && echo yes || echo no)"
out=$(run repo add octo/other --path /home/alice/other)
assert_eq "a second repo joins it; the first stays (replace at the version read)" $'octo/hello\nocto/other' "$(cm_repos)"
assert_has "by replace" "replace -f -" "$(cat "$K_LOG")"
out=$(K_LIST_STALE=1 run repo add octo/stale --path /home/alice/stale)
assert_has "a git pod that never sees the entry stops the add" "does not see octo/stale on the list of added repos" "$out"
assert_has "exit 1" "exit=1" "$out"
assert_not_has "before any folder is made or anything cloned" "gitctl clone" "$(cat "$K_LOG")"
assert_eq "and no folder pod" "" "$(cat "$K_APPLIED")"
assert_eq "and the entry is taken off again" $'octo/hello\nocto/other' "$(cm_repos)"
out=$(K_CLONE_FAIL=1 run repo add octo/broken --path /home/alice/broken)
assert_has "a clone that fails" "exit=1" "$out"
assert_eq "takes its new entry off the list" $'octo/hello\nocto/other' "$(cm_repos)"
out=$(K_CLONE_FAIL=1 run repo add octo/hello --path /home/alice/hello3)
assert_eq "but not an entry that was there before (another working copy of it)" $'octo/hello\nocto/other' "$(cm_repos)"
out=$(K_CM_FAIL=1 run repo add octo/third --path /home/alice/third)
assert_has "a list that cannot be read stops the add" "cannot read the list of added repos" "$out"
assert_not_has "before anything is cloned" "gitctl clone" "$(cat "$K_LOG")"
rm -f "$K_CM"
out=$(K_STATE=repo run repo add octo/hello)
assert_has "a working copy already there (added before the list existed) is put on the list" "exit=0" "$out"
assert_eq "it is" "octo/hello" "$(cm_repos)"
assert_has "and gitrun gets its copy from it (gitctl adopt: it changes nothing there)" "gitctl adopt /home/alice/hello" "$(execs)"
assert_not_has "nothing is cloned" "gitctl clone" "$(cat "$K_LOG")"
out=$(K_STATE=repo run repo remove /home/alice/hello)
assert_eq "repo remove takes it off the list" "" "$(cm_repos)"
off_line=$(grep -n "replace -f -" "$K_LOG" | tail -1 | cut -d: -f1); rm_line=$(grep -n "gitctl remove-copy" "$K_LOG" | cut -d: -f1)
assert_eq "before gitrun's copy is removed" yes "$([ "${off_line:-99}" -lt "${rm_line:-0}" ] && echo yes || echo no)"
out=$(K_STATE=repo K_CM_FAIL=1 run repo remove /home/alice/hello)
assert_has "a list that cannot be changed stops the remove, saying so" "nothing was removed" "$out"
assert_not_has "before the copy is removed" "remove-copy" "$(cat "$K_LOG")"
rm -f "$K_CM"

echo "=== aidc repo list ==="
out=$(K_LIST=$'/home/alice/hello\thttps://github.com/octo/hello\tmain\n/home/alice/old\thttps://github.com/octo/old\tfeature' run repo list)
assert_has "each working copy is listed with its origin and branch" "/home/alice/hello" "$out"
assert_has "the origin" "https://github.com/octo/hello" "$out"
assert_has "the branch" "feature" "$out"
assert_has "the search is under the user's disk" "bash /home/alice" "$(cat "$K_LOG")"
out=$(run repo list)
assert_has "no repos says so, with the command" "no repos yet (aidc repo add" "$out"
out=$(K_LIST=$'/home/alice/hello\thttps://github.com/octo/hello\tmain' K_LIST_CUT=1 run repo list)
assert_has "a list cut short is unknown, not a short list" "unknown: the git container did not answer" "$out"
out=$(K_EXEC_FAIL=1 run repo list)
assert_has "a container that cannot be asked is unknown" "unknown" "$out"
assert_not_has "never 'no repos'" "no repos yet" "$out"
out=$(K_NO_POD=1 run repo list)
assert_has "no git container: repos are unknown until it runs" "repos are unknown until it runs" "$out"
# Folder names, origins and branches are the sessions' to write: escape sequences, tabs and
# newlines in them must not reach the terminal, shift a column or forge a row.
LD="$SCRATCH/listdisk"
mkrepo() { mkdir -p "$1/.git"; printf '[remote "origin"]\n\turl = %s\n' "$2" > "$1/.git/config"; printf 'ref: refs/heads/%s\n' "$3" > "$1/.git/HEAD"; }
mkrepo "$LD/plain" https://github.com/octo/hello main
mkrepo "$LD/red"$'\e'"[31mx" $'https://github.com/octo/\e]0;title\a' $'br\ranch'
mkrepo "$LD/a"$'\n'"repo=/forged"$'\t'"https://github.com/evil/x"$'\t'"main" https://github.com/octo/nl main
out=$(K_LIST_REAL="$LD" run repo list)
assert_eq "no control character reaches the terminal" no "$(printf '%s' "$out" | LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f\x7f]' && echo yes || echo no)"
assert_eq "a newline in a folder name cannot forge a row (one row per working copy)" 3 \
    "$(printf '%s\n' "$out" | grep -c '^/')"
assert_not_has "and no row starts at the forged path" $'\n/forged' "$out"
assert_has "the names are still shown, without the control characters" "$LD/red[31mx" "$out"
out=$(run repo frobnicate); assert_has "an unknown subcommand is refused" "unknown repo subcommand" "$out"

echo "=== aidc repo remove ==="
out=$(K_STATE=repo run repo remove /home/alice/hello)
assert_has "gitrun's private copy is always removed" "gitctl remove-copy octo/hello" "$(execs)"
assert_has "the working copy is kept unless the user says so" "is kept, with the sessions' work in it" "$out"
assert_eq "and no folder pod runs" "" "$(cat "$K_APPLIED")"
out=$(K_STATE=repo run repo remove "$HOME/hello" --delete-working-copy)
assert_has "with --delete-working-copy, the working copy goes too" "deleted the working copy /home/alice/hello" "$out"
assert_eq "by the folder pod in delete mode, after the copy" "delete" "$(pods)"
rm_line=$(grep -n "gitctl remove-copy" "$K_LOG" | cut -d: -f1); del_line=$(grep -n "apply -f -" "$K_LOG" | cut -d: -f1)
assert_eq "the private copy goes first" yes "$([ "$rm_line" -lt "$del_line" ] && echo yes || echo no)"
# A delete that took a session's unpushed commits or uncommitted changes with it loses work for
# good: gitctl unpushed is asked first, and anything it names refuses the delete.
out=$(K_STATE=repo K_UNPUSHED='branch 2 feat-x\nworktree /home/alice/hello/s1\nuncommitted /home/alice/hello/s1\nworktree /home/alice/hello/s2\nstash 1' \
    run repo remove /home/alice/hello --delete-working-copy)
assert_has "unpushed work refuses the delete" "holds work that is not on GitHub; nothing was removed" "$out"
assert_has "naming the unpushed branch" "branch feat-x: 2 commit(s) on no origin branch" "$out"
assert_has "the uncommitted worktree" "/home/alice/hello/s1: uncommitted changes" "$out"
assert_has "the stash" "1 stash(es)" "$out"
assert_has "and every worktree in it" "  /home/alice/hello/s2" "$out"
assert_has "and how to go ahead" "--even-unpushed" "$out"
assert_has "exit 1" "exit=1" "$out"
assert_eq "nothing is removed: no copy, no folder pod" "" "$(grep 'remove-copy' "$K_LOG")$(cat "$K_APPLIED")"
assert_has "the check is the agent's gitctl unpushed on that path" "gitctl unpushed /home/alice/hello" "$(execs)"
out=$(K_STATE=repo K_UNPUSHED='detached 1 /home/alice/hello/s3' run repo remove /home/alice/hello --delete-working-copy)
assert_has "a detached worktree's commits refuse it too" "/home/alice/hello/s3: 1 commit(s) on a detached HEAD" "$out"
out=$(K_STATE=repo K_UNPUSHED='branch 2 feat-x\nworktree /home/alice/hello/s1' run repo remove /home/alice/hello --delete-working-copy --even-unpushed)
assert_has "--even-unpushed deletes it anyway" "deleted the working copy /home/alice/hello" "$out"
assert_has "saying what is lost" "deleting work that is not on GitHub (--even-unpushed)" "$out"
assert_eq "by the folder pod" "delete" "$(pods)"
out=$(K_STATE=repo K_UNPUSHED='worktree /home/alice/hello/s1' run repo remove /home/alice/hello --delete-working-copy)
assert_has "clean worktrees do not refuse it, and are named" "the worktrees in it go too" "$out"
assert_has "and it is deleted" "deleted the working copy /home/alice/hello" "$out"
out=$(K_STATE=repo K_EXEC_FAIL_UNPUSHED=1 run repo remove /home/alice/hello --delete-working-copy)
assert_has "a check that cannot be made refuses it (cannot tell is not nothing)" "cannot tell whether /home/alice/hello holds unpushed work" "$out"
assert_eq "and nothing is removed" "" "$(grep 'remove-copy' "$K_LOG")$(cat "$K_APPLIED")"
out=$(K_STATE=repo K_EXEC_FAIL_UNPUSHED=1 run repo remove /home/alice/hello --delete-working-copy --even-unpushed)
assert_has "unless --even-unpushed is given" "deleted the working copy /home/alice/hello" "$out"
out=$(K_STATE=repo K_UNPUSHED='branch 1 x\e[2J\e]0;t\a' run repo remove /home/alice/hello --delete-working-copy)
assert_eq "names in the refusal reach the terminal without control characters" no \
    "$(printf '%s' "$out" | LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f\x7f]' && echo yes || echo no)"
# A retried delete: the first run removed gitrun's copy, then stopped. gitctl unpushed reports
# from what the working copy last fetched; the delete goes on, saying so.
out=$(K_STATE=repo K_UNPUSHED='not-fetched' run repo remove /home/alice/hello --delete-working-copy)
assert_has "a retry after the copy is gone deletes a working copy with nothing unpushed" "deleted the working copy /home/alice/hello" "$out"
assert_has "saying it was checked against what it last fetched" "checked against GitHub's branches as it last fetched them" "$out"
out=$(K_STATE=repo K_UNPUSHED='not-fetched\nbranch 1 feat-x' run repo remove /home/alice/hello --delete-working-copy)
assert_has "and still refuses one with unpushed work" "holds work that is not on GitHub; nothing was removed" "$out"
out=$(K_STATE=repo run repo remove /home/alice/hello --even-unpushed)
assert_has "--even-unpushed alone is refused" "goes with --delete-working-copy" "$out"
out=$(K_STATE=repo run repo remove /home/alice/hello)
assert_not_has "without --delete-working-copy nothing is checked (nothing is deleted)" "gitctl unpushed" "$(execs)"
out=$(run repo remove octo/hello)
assert_has "owner/name removes just the private copy (no working copy needed)" "gitctl remove-copy octo/hello" "$(execs)"
out=$(run repo remove octo/hello --delete-working-copy)
assert_has "owner/name with --delete-working-copy is refused (which copy?)" "needs the working copy's path" "$out"
out=$(K_STATE=empty run repo remove /home/alice/nothing)
assert_has "a path that is no working copy is refused" "is not a git working copy" "$out"
assert_not_has "and nothing is removed" "remove-copy" "$(cat "$K_LOG")"
out=$(K_STATE=repo K_RM_FAIL=1 run repo remove /home/alice/hello --delete-working-copy)
assert_has "a copy that cannot be removed stops the remove" "could not remove its copy" "$out"
assert_eq "and the working copy is not deleted" "" "$(cat "$K_APPLIED")"
out=$(K_EXEC_FAIL=1 run repo remove /home/alice/hello)
assert_has "a git container that cannot be asked stops it" "cannot tell what is at" "$out"
for p in /etc/x /home/alice "/home/alice/a/../b"; do
    out=$(run repo remove "$p" --delete-working-copy)
    assert_eq "remove '$p' is refused before anything runs" "" "$(cat "$K_APPLIED")$(grep 'remove-copy' "$K_LOG")"
done

echo "=== aidc create takes no --repo on kubernetes ==="
# Sessions see the whole disk and make their own worktrees in added repos (owner ruling
# 2026-11-24): a --repo that was quietly ignored would leave the user expecting a repo set up.
for form in "--repo hello" "--repo=/home/alice/hello"; do
    # shellcheck disable=SC2086  # the flag and its value, split on purpose
    out=$(run create demo --backend kubernetes $form)
    assert_has "create $form is refused, pointing at aidc repo add and the session's own worktree" \
        "the session makes its own worktree and branch in it (git worktree add)" "$out"
    assert_eq "and nothing is applied" "" "$(cat "$K_APPLIED")"
done
out=$(run create demo --backend kubernetes)
assert_has "without --repo the session is created, starting at this folder's place on the disk" "repo /home/alice/code" "$out"

echo "=== the repo folder step (chown, chmod and rm stubbed: they need root, or delete) ==="
mkdir -p "$SCRATCH/rbin" "$SCRATCH/rdisk"
for c in chown chmod rm; do
    # shellcheck disable=SC2016  # expanded by the stub when it runs
    printf '#!/bin/sh\necho "%s $* in $(pwd -P)" >> "%s/owner.log"\n' "$c" "$SCRATCH" > "$SCRATCH/rbin/$c"
    chmod +x "$SCRATCH/rbin/$c"
done
RD_SCRIPT=$(bash -c '. "$AIDC_SCRIPTS/k8s/lib.sh"; . "$AIDC_SCRIPTS/k8s/manifests.sh"; printf "%s" "$K8S_REPO_DIR_SCRIPT"')
assert_eq "the rendered folder pod runs exactly this script" "$RD_SCRIPT" "$(run repo add octo/hello >/dev/null; q 'select(.kind == "Pod") | .spec.containers[0].command[2]' | head -1 | jq -r .)"
rd() { : > "$SCRATCH/owner.log"; ROUT=$(PATH="$SCRATCH/rbin:$PATH" sh -c "$RD_SCRIPT" repo-dir "$1" "$SCRATCH/rdisk" "$2" 2000 2>&1); RRC=$?; OWN=$(cat "$SCRATCH/owner.log"); }
D="$SCRATCH/rdisk"
# The request folder (mode requests): the request holder's. The folder here is the tester's, so
# the tester's uid stands for whichever owner a case needs (the agent's, or the holder's).
me=$(id -u)
rq() { : > "$SCRATCH/owner.log"; ROUT=$(PATH="$SCRATCH/rbin:$PATH" sh -c "$RD_SCRIPT" repo-dir "$D/.aidc/git-requests" "$D" requests "$1" "$2" 2>&1); RRC=$?; OWN=$(cat "$SCRATCH/owner.log"); }
rq 2000 2003
assert_eq "a new request folder is made and given to the request holder, setgid" \
    "0|chown 2003:1000 . in $D/.aidc/git-requests|chmod 2755 . in $D/.aidc/git-requests" \
    "$RRC|$(printf '%s\n' "$OWN" | grep -F " in $D/.aidc/git-requests" | paste -sd'|')"
touch "$D/.aidc/git-requests/kept"
rq "$me" 2003
assert_eq "one the agent held (before requests moved out of its reach) is given over with its contents, no symlink followed" \
    "0|chown -R -h 2003 . in $D/.aidc/git-requests" "$RRC|$(printf '%s\n' "$OWN" | grep chown | paste -sd'|')"
rq 2000 "$me"
assert_eq "one the holder has is left as it is" "0|" "$RRC|$(printf '%s\n' "$OWN" | grep chown | paste -sd'|')"
rq 2000 2003
assert_eq "one that holds files and is neither's is refused" "3|" "$RRC|$(printf '%s\n' "$OWN" | grep chown | paste -sd'|')"
rm -rf "$D/.aidc"
rd "$D/a/b/proj" make
assert_eq "a new repo folder is made, with the folders on the way" "0 yes" "$RRC $([ -d "$D/a/b/proj" ] && echo yes)"
assert_eq "the folders on the way go to the session user; the repo folder to the agent, writable by it alone" \
"chown 1000:1000 . in $D/a
chmod 0755 . in $D/a
chown 1000:1000 . in $D/a/b
chmod 0755 . in $D/a/b
chown 2000:1000 . in $D/a/b/proj
chmod 0755 . in $D/a/b/proj" "$OWN"
rd "$D/a/b/proj" make
assert_eq "an empty folder already there is taken (a retry after a failed clone)" 0 "$RRC"
assert_eq "and folders that were there are left as they are" "chown 2000:1000 . in $D/a/b/proj
chmod 0755 . in $D/a/b/proj" "$OWN"
mkdir "$D/a/b/proj/.git"; touch "$D/a/b/proj/README"
rd "$D/a/b/proj" own
assert_eq "own: the working copy becomes the session user's, symlinks not followed, group-shared" \
"chown -R -h 1000:1000 . in $D/a/b/proj
chmod 2775 . in $D/a/b/proj" "$OWN"
rd "$D/a/b/proj" make
assert_eq "make: a folder that is not empty is refused, and nothing is changed" "3 " "$RRC $OWN"
mkdir -p "$D/a/b/proj/.git/objects" "$D/a/b/proj/wt/src" "$SCRATCH/outside"
touch "$D/a/b/proj/.hidden" "$D/a/b/proj/wt/src/x" "$SCRATCH/outside/keep"
ln -s "$SCRATCH/outside" "$D/a/b/proj/out"
rd "$D/a/b/proj" delete
assert_eq "delete: a working copy, dotfiles and nested folders included, is deleted (without rm -rf)" \
    "0  no" "$RRC $OWN $([ -e "$D/a/b/proj" ] && echo yes || echo no)"
assert_eq "and a symlink in it is removed, never followed" "keep" "$(ls "$SCRATCH/outside")"
mkdir -p "$D/a/b/proj"; touch "$D/a/b/proj/README"
rd "$D/a/b/proj" delete
assert_eq "delete: a folder that is not a git working copy is refused" "3 " "$RRC $OWN"

# A session swaps another folder in at the checked name between the check and the delete: the
# first delete step (find, or rm in a build that deletes by name) moves the checked folder aside
# and puts a folder with content at its name, then runs the real command. Root must delete only
# what it checked; the swapped-in folder survives and the delete reports the change.
mkdir -p "$SCRATCH/swapbin"
for c in find rm rmdir; do
    real=$(command -v "$c")
    cat > "$SCRATCH/swapbin/$c" <<STUB
#!/bin/sh
if [ ! -e "$SCRATCH/swapped" ]; then
    : > "$SCRATCH/swapped"
    mv "$D/s/proj" "$D/s/proj.moved"
    mkdir -p "$D/s/proj/precious"; echo work > "$D/s/proj/precious/file"
fi
exec "$real" "\$@"
STUB
    chmod +x "$SCRATCH/swapbin/$c"
done
mkdir -p "$D/s/proj/.git"; touch "$D/s/proj/tracked"
rm -f "$SCRATCH/swapped"
ROUT=$(PATH="$SCRATCH/swapbin:$PATH" sh -c "$RD_SCRIPT" repo-dir "$D/s/proj" "$D" delete 2000 2>&1); RRC=$?
assert_eq "a folder swapped in at the name after the check is not deleted" "work" "$(cat "$D/s/proj/precious/file" 2>/dev/null)"
assert_eq "the folder that was checked is the one emptied" "" "$(ls -A "$D/s/proj.moved" 2>/dev/null)"
assert_eq "and the delete fails, saying the folder changed" "3" "$RRC"
assert_has "with why" "changed while it was deleted" "$ROUT"
rd "$D/a/b/missing" delete
assert_eq "delete or own: a missing folder is refused, never made" "3  no" "$RRC $OWN $([ -e "$D/a/b/missing" ] && echo yes || echo no)"
mkdir -p "$SCRATCH/elsewhere/proj/.git"; ln -s "$SCRATCH/elsewhere" "$D/link"
for m in make own delete; do
    rd "$D/link/proj" "$m"
    assert_eq "$m: a symlink on the way is refused, never followed" "3 " "$RRC $OWN"
done
assert_has "with why" "is a symlink" "$ROUT"
ln -s "$SCRATCH/elsewhere/proj" "$D/leaf"
rd "$D/leaf" delete
assert_eq "a symlink as the repo folder is refused" "3 " "$RRC $OWN"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
