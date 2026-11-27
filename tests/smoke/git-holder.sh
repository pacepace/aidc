#!/usr/bin/env bash
# The git container's request holder, live on Docker, touching nothing of the user's: an
# aidc/gitctl image with a test tag, built from its staged context as every builder builds it
# (aidc_build_context: gitctl/ with the sessions' scripts beside it; `--build` does that here),
# a container and volumes of their own names, no network. It checks what unit tests cannot: the
# real users, sudo rules and process layout. The agent's Claude Code hooks land in the mirror
# (SessionStart, UserPromptSubmit; a turn's Stop needs a real Claude login), the watcher runs as
# gitreq started through its sudo rule (a second one waits on the lock), a session's request is
# handed to the agent's window, the agent is refused approve, deny, mode, push, merge, issue
# writes and logout (by gitctl and by sudo), the holder's approve runs it, rules mode runs at
# once, and an issue call is answered in under half a second. GitHub is never reached.
#
# Usage: bash tests/smoke/git-holder.sh [--build] <tag>
#   --build   build aidc/gitctl:<tag> first, from the staged context (then run the check)
set -u
BUILD=0
[ "${1:-}" != --build ] || { BUILD=1; shift; }
TAG="${1:?usage: tests/smoke/git-holder.sh [--build] <image tag of aidc/gitctl>}"
IMG="aidc/gitctl:${TAG}"
N="gitreq-live-$$"
AIDC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$AIDC_ROOT/tests/scratch/${N}"
PASS=0 FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
cleanup() {
    docker rm -f "$N" >/dev/null 2>&1
    for v in home cred run req tr; do docker volume rm "${N}-${v}" >/dev/null 2>&1; done
    rm -rf "$S"
}
trap cleanup EXIT

# git_holder_build <root> <image>: build the image from the context aidc_build_context stages
# (gitctl/Dockerfile copies the sessions' scripts, which gitctl/ alone does not hold).
git_holder_build() {
    local rc=0
    # shellcheck source=../../scripts/lib/common.sh
    . "$1/scripts/lib/common.sh"
    aidc_build_context "aidc/gitctl:t" "$1/gitctl" || return 1
    docker build -t "$2" -f "$AIDC_BUILD_CONTEXT/Dockerfile" "$AIDC_BUILD_CONTEXT" || rc=$?
    [ -z "$AIDC_BUILD_STAGE" ] || rm -rf "$AIDC_BUILD_STAGE"
    return "$rc"
}
if [ "$BUILD" = 1 ]; then
    git_holder_build "$AIDC_ROOT" "$IMG" || { echo "FAIL: could not build ${IMG}"; exit 1; }
fi

mkdir -p "$S/disk" "$S/settings" "$S/added"
printf 'requests=/var/aidc/git-requests\ndisk=/home/tester\nmode=ask\n' > "$S/settings/settings"
printf 'octocat/hello-world\n' > "$S/added/repos"
P="$S/disk/proj"
git init -q "$P" && git -C "$P" -c user.name=T -c user.email=t@example.com commit -q --allow-empty -m first
git -C "$P" remote add origin https://github.com/octocat/Hello-World
git -C "$P" switch -q -c feat && git -C "$P" -c user.name=T -c user.email=t@example.com commit -q --allow-empty -m feat

# The home seeded from the image, its Claude set up as a user's would be (first-run screens
# done, this folder trusted, the test key accepted), and the transcript mirror the agent's, as
# aidc git setup makes them.
KEY=sk-ant-api03-test-only-000000000000000000000000
docker run --rm --network none -u 0:0 -v "${N}-home:/home/git" -v "${N}-tr:/t" --entrypoint /bin/sh "$IMG" -c \
    "chown 2000:2000 /t && chmod 0750 /t && printf '%s' '{\"hasCompletedOnboarding\":true,\"customApiKeyResponses\":{\"approved\":[\"${KEY: -20}\"],\"rejected\":[]},\"projects\":{\"/home/git/work\":{\"hasTrustDialogAccepted\":true}}}' > /home/git/.claude.json && chown 2000:2000 /home/git/.claude.json" \
    || { echo "could not seed"; exit 1; }
docker run -d --name "$N" --network none \
    --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add AUDIT_WRITE \
    -e HOME=/home/git -e AIDC_SESSION=git -e AIDC_GIT_REQUESTS=/var/aidc/git-requests -e AIDC_GIT_WATCH_HERE=1 \
    -e ANTHROPIC_API_KEY="$KEY" -v "${N}-tr:/var/aidc/transcript-out" \
    -v "${N}-home:/home/git" -v "${N}-cred:/var/lib/gitctl/gitcred" -v "${N}-run:/var/lib/gitctl/gitrun" \
    -v "${N}-req:/var/aidc/git-requests" -v "$S/disk:/home/tester" \
    -v "$S/settings:/etc/aidc/git-settings:ro" -v "$S/added:/etc/aidc/git-repos:ro" \
    "$IMG" >/dev/null || { echo "could not start"; exit 1; }
asgit() { docker exec -u git "$N" "$@" </dev/null; }
asreq() { docker exec -u gitreq -e HOME=/var/lib/gitctl/gitreq "$N" "$@" </dev/null; }
assess() { docker exec -u 1000:1000 -w /home/tester/proj -e HOME=/tmp -e AIDC_GIT_REQUESTS=/var/aidc/git-requests \
    -e AIDC_GH_WAIT="${WAIT:-3}" "$@"; }
for _ in $(seq 30); do asgit tmux has-session -t main 2>/dev/null && break; sleep 1; done

echo "=== the git agent's Claude Code hooks land in the mirror the MCP reads ==="
ev() { asgit sh -c 'cat /var/aidc/transcript-out/hook-events/*.json 2>/dev/null' | jq -r .event 2>/dev/null; }
for _ in $(seq 40); do ev | grep -qx SessionStart && break; sleep 1; done
check "SessionStart is written when the agent's Claude starts" "ev | grep -qx SessionStart"
check "as the agent, in /var/aidc/transcript-out/hook-events" \
    "[ \"\$(docker exec $N sh -c 'stat -c %U /var/aidc/transcript-out/hook-events/*.json | sort -u')\" = git ]"
sleep 5
asgit tmux send-keys -t main:claude -l 'say ok'; sleep 1; asgit tmux send-keys -t main:claude Enter
for i in $(seq 30); do ev | grep -qx UserPromptSubmit && break; [ $((i % 4)) = 0 ] && asgit tmux send-keys -t main:claude Enter; sleep 1; done
check "UserPromptSubmit is written when a prompt goes in" "ev | grep -qx UserPromptSubmit"
ev | grep -qx UserPromptSubmit || { echo "  pane:"; asgit tmux capture-pane -p -t main:claude | grep -v "^$" | tail -15 | sed "s/^/    /"; }
for _ in $(seq 30); do ev | grep -qxE 'Stop|StopFailure' && break; sleep 1; done
echo "  note: turn end with no network and a test key: $(ev | grep -xE 'Stop|StopFailure|Notification' | paste -sd' ' - || true) (a Stop needs a real Claude login)"

# Now the agent's Claude stands in as cat (a set-up Claude, not a shell), so the paste shows.
asgit tmux respawn-window -k -t main:claude cat
sleep 3

echo "=== the watcher: gitreq's, started through the sudo rule ==="
check "the watcher runs as gitreq" "docker exec $N ps -eo user:12,args | grep -E '^gitreq .*git-requests.sh watch'"
check "started by git's main process through sudo" "docker exec $N ps -eo user:12,args | grep -E '^root .*sudo -n -u gitreq /opt/aidc/lib/gitctl/git-requests.sh watch'"
check "the request folder is gitreq's" "[ \"\$(docker exec $N stat -c %U /var/aidc/git-requests)\" = gitreq ]"
check "its work folder is closed to git" "! asgit ls /var/aidc/git-requests/work"
docker exec -d -u git "$N" sudo -n -u gitreq /opt/aidc/lib/gitctl/git-requests.sh watch
sleep 3
check "a second watcher (the agent's, through the rule) waits on the lock (two watch processes, no restart loop in the log)" \
    "[ \"\$(docker exec $N ps -eo user:12,args | grep -cE '^gitreq .*git-requests.sh watch')\" -ge 2 ] && ! asgit grep -q 'already runs' /home/git/.cache/gitctl/requests.log"

echo "=== a session's push request waits, and is handed to the agent's Claude ==="
out=$(assess -e AIDC_SESSION=sess1 "$N" bash /opt/aidc/lib/gitctl/gh-standin.sh aidc push feat 2>&1)
id=$(printf '%s' "$out" | grep -Eo '[0-9a-f]{32}' | head -n1)
check "gh aidc push: waiting for approval (${id})" "[ -n '$id' ] && printf '%s' \"\$out\" | grep -q 'waiting for approval'"
check "it says the user approves with aidc git approve" "printf '%s' \"\$out\" | grep -q 'aidc git approve $id'"
pasted=""
for _ in $(seq 15); do asgit tmux capture-pane -p -t main:claude | grep -q "git request $id waits" && { pasted=1; break; }; sleep 1; done
check "the handoff loop pasted the id into the agent's window" "[ -n '$pasted' ]"
check "and the holder recorded it as handed" "asreq test -e /var/aidc/git-requests/work/$id.handed"
check "the agent can list it (through the rule)" "asgit git-requests list | grep -q $id"
check "and read its prompt, which names aidc git approve" "asgit git-requests prompt $id | grep -q 'aidc git approve $id'"

echo "=== the agent cannot approve, deny, push or log out ==="
check "git-requests approve as git is refused" "asgit git-requests approve $id 2>&1 | grep -q 'cannot approve'"
check "deny as git is refused" "asgit git-requests deny $id 2>&1 | grep -q 'cannot deny'"
check "sudo to gitreq for approve is refused by sudo" "! asgit sudo -n -u gitreq /opt/aidc/lib/gitctl/git-requests.sh approve $id"
check "sudo to gitreq for anything else is refused" "! asgit sudo -n -u gitreq /bin/sh -c id"
check "gitctl push as git is refused" "asgit gitctl push /home/tester/proj feat 2>&1 | grep -q 'runs only as a request'"
check "and sudo to gitrun's push is refused there (sudo names git)" \
    "asgit sh -c 'cd /home/tester/proj && git bundle create /tmp/b.bundle refs/heads/feat >/dev/null 2>&1; sudo -n -u gitrun /opt/aidc/lib/gitctl/gitctl.sh push octocat/hello-world feat < /tmp/b.bundle' 2>&1 | grep -q 'changes GitHub'"
check "gitctl pr-merge as git is refused" "asgit gitctl pr-merge /home/tester/proj 1 2>&1 | grep -q 'runs only as a request'"
check "gitctl logout as git is refused" "asgit gitctl logout 2>&1 | grep -q 'only the user does that'"
check "an issue write as git is refused" "printf '{\"title\":\"T\"}' | docker exec -i -u git $N gitctl api POST repos/octocat/hello-world/issues 2>&1 | grep -q 'runs only as a request'"
check "a mode change as git is refused" "printf '%064d' 0 | docker exec -i -u git $N git-requests mode sess1 rules 2>&1 | grep -q 'only the user'"
check "the request still waits" "asreq git-requests list | grep -q $id"

echo "=== the user's approve (exec as gitreq, as aidc git approve runs it) ==="
out=$(asreq git-requests approve "$id" 2>&1); rc=$?
check "approve runs it (it fails only for GitHub: no network, no login)" "[ $rc != 0 ] && ! printf '%s' \"\$out\" | grep -q 'cannot approve'"
check "it is no longer waiting: $(asreq sh -c "jq -r .state /var/aidc/git-requests/results/$id.json")" \
    "[ \"\$(asreq jq -r .state /var/aidc/git-requests/results/$id.json)\" = failed ]"
check "gitctl push ran for it, as gitreq (gitrun's log names the caller)" \
    "asgit gitctl log 5 | grep -q 'asked-by=$id caller=gitreq' || asreq cat /var/aidc/git-requests/work/requests.log | grep -q '$id push'"

echo "=== rules mode: a session given rules runs at once, no question ==="
tok=$(printf 'a%.0s' $(seq 64))
printf '%s\n' "$tok" | docker exec -i -u gitreq -e HOME=/var/lib/gitctl/gitreq "$N" git-requests register sess2 >/dev/null
printf '%s\n' "$tok" | docker exec -i -u gitreq -e HOME=/var/lib/gitctl/gitreq "$N" git-requests mode sess2 rules >/dev/null
out=$(WAIT=10 assess -e AIDC_SESSION=sess2 -e AIDC_GIT_TOKEN="$tok" "$N" bash /opt/aidc/lib/gitctl/gh-standin.sh aidc push feat 2>&1)
id2=$(printf '%s' "$out" | grep -Eo '[0-9a-f]{32}' | head -n1)
check "it ran at once (failed only for GitHub), never waiting: $(printf '%s' "$out" | tail -n1 | cut -c1-80)" \
    "! printf '%s' \"\$out\" | grep -q 'waiting for approval'"
check "in rules mode" "[ \"\$(asreq jq -r .mode /var/aidc/git-requests/results/${id2:-none}.json)\" = rules ]"
check "nothing of it waits to be asked about" "! asreq git-requests list | grep -q '${id2:-none}'"

echo "=== an issue call is answered fast ==="
t0=$(date +%s%N)
for _ in 1 2 3 4 5; do assess -e AIDC_SESSION=sess1 "$N" bash /opt/aidc/lib/gitctl/gh-standin.sh api repos/octocat/hello-world/issues/1 >/dev/null 2>&1; done
ms=$(( ($(date +%s%N) - t0) / 5000000 ))
check "five issue calls through the git container: ${ms} ms each (under 500)" "[ $ms -lt 500 ]"
out=$(assess -e AIDC_SESSION=sess1 "$N" bash /opt/aidc/lib/gitctl/gh-standin.sh api repos/octocat/hello-world/issues/1 2>&1)
check "each was answered by the holder (here: no copy of the repo yet, no network): ${out:0:90}" "printf '%s' \"\$out\" | grep -qi 'repo\|github\|login'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
