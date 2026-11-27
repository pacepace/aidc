# shellcheck shell=bash
# The git container's part of the smokes (docs/design-12-kubernetes.md, "Git"), shared by
# tests/smoke/k8s.sh and tests/smoke/run.sh. Sourced; the smoke that sources it defines:
#
#   assert <desc> <command>   eval the command, count PASS/FAIL (both smokes have one)
#   SG_BACKEND                docker or kubernetes (passed to every aidc command as --backend)
#   SG_SESSION                a session created AFTER `aidc git setup` (so it has the request
#                             folder), on a workspace from which SG_WC is reachable
#   SG_WC                     the working copy the git container works on, at the path both the
#                             session and the git container see (a public GitHub repo's clone)
#   sg_in <script>            run bash script <script> in the session as its user (vscode)
#   sg_git <args...>          run a command in the git container as its agent (git)
#
# Three parts:
#
#   sg_part_requests   always: the request flow with no GitHub login needed. Nothing reaches
#                      GitHub but fetches of the public repo; steps that would push (approve,
#                      rules mode, tidy) run only while the git container is NOT logged in, so
#                      they can only fail for the login and never touch the public repo.
#   sg_part_github     only when the git container is logged in AND AIDC_SMOKE_GIT_REPO names a
#                      scratch repo the user owns (owner/name): a real push and PR, a merge
#                      with a merge commit, the branch deleted and the worktree tidied, the
#                      protections read (turned on only with AIDC_SMOKE_GIT_PROTECT=1), the
#                      commit identity. It touches no other repo. Its PR is merged (adding one
#                      file under aidc-smoke/ to the scratch repo) and its branch deleted; when
#                      a step fails it says what it left.
#   sg_part_claude     only when AIDC_SMOKE_GIT_CLAUDE=1 and the git agent's Claude is set up
#                      (a key and its first-run screens done, as git-notify requires): an
#                      ask-mode request reaches the agent's Claude, which asks with its question
#                      tool (seen in its transcript, where aidc's MCP server reads questions).
#                      Answering that question from an orchestrator is checked by hand
#                      (tests/smoke/README.md, "The git container").
#
# Works under set -e (run.sh): a command whose failure is a result is in an assert or ends in
# || true. Every aidc call runs with </dev/null: `aidc git protect` asks, and the answer is then no.

SG_WAIT_DONE=120   # a request run at once (rules mode, logged in) may take a while: push and PR
SG_LOGGED_IN=""    # yes / no / unknown, from aidc git status
SG_REQUEST=""      # the last request id gh pr create printed
SG_PR=""           # the scratch repo's PR the GitHub part opened (for cleanup)
SG_GH_WC=""        # the scratch repo's working copy (for cleanup)
SG_IDENT=""        # this machine's git identity, "<name> <<email>>", which sessions commit as

sg_aidc() { "$AIDC" "$@" --backend "$SG_BACKEND" </dev/null 2>&1; }
# sg_has <text> <aidc args...>: the command's output contains <text> (captured first, so the
# command's exit code does not matter: refusals exit non-zero on purpose).
sg_has() { local want="$1" out; shift; out=$(sg_aidc "$@"); case "$out" in *"$want"*) return 0 ;; esac; return 1; }
# sg_in_has <text> <script>: the same for a script run in the session (stdout and stderr).
sg_in_has() { local out; out=$(sg_in "$2" 2>&1); case "$out" in *"$1"*) return 0 ;; esac; return 1; }

sg_logged_in() {
    local line
    line=$(sg_aidc git status | grep -E '^github:' || true)
    case "$line" in
        *"not logged in"*) SG_LOGGED_IN=no ;;
        *"logged in"*) SG_LOGGED_IN=yes ;;
        *) SG_LOGGED_IN=unknown ;;
    esac
}

# sg_request <extra env> <gh args...>: gh pr create (or another stand-in command) in the
# session's worktree; sets SG_REQUEST to the request id it printed, SG_OUT to its output.
SG_OUT=""
sg_request() {
    local envs="$1"; shift
    SG_OUT=$(sg_in "cd '${SG_WT}' && ${envs} gh $(printf '%q ' "$@")" 2>&1 || true)
    SG_REQUEST=$(printf '%s\n' "$SG_OUT" | grep -Eo '[0-9a-f]{32}' | head -n1) || SG_REQUEST=""
}

# The git container is set up and answers; the session made after it has what requests need.
sg_part_setup() {
    echo "[git] the git container"
    assert "aidc git setup starts it (again: setup is idempotent)" "sg_aidc git setup"
    assert "aidc git status reports it running" "sg_has running git status"
    assert "aidc git status shows the git mode and waiting requests" \
        "sg_has 'mode:' git status && sg_has 'requests:' git status"
    sg_logged_in
    echo "  note: GitHub login: ${SG_LOGGED_IN}"
}

# gitctl's user switch as the installed image has it (the unit tests run gitctl from a checkout,
# with no sudo): gitwc, the user's uid on Docker, runs the agent's working-copy verbs there and
# nowhere else. Needs SG_WC (a working copy the git container sees).
sg_part_gitwc() {
    local ctl=/opt/aidc/lib/gitctl/gitctl.sh out
    echo "[git] gitctl's switch to gitwc, in the image"
    if [ "$SG_BACKEND" = kubernetes ]; then
        out=$(sg_git sudo -n -u gitwc "$ctl" unpushed "$SG_WC" 2>&1 || true)
        assert "gitwc is refused off Docker (${out:0:80})" \
            "printf '%s' \"\$out\" | grep -q 'gitwc works only in a Docker git container'"
    else
        assert "the sudo rule lets the agent run gitctl as gitwc, which takes a working-copy verb" \
            "sg_git sudo -n -u gitwc '$ctl' unpushed '${SG_WC}'"
        out=$(sg_git sudo -n -u gitwc "$ctl" push "$SG_WC" main 2>&1 || true)
        assert "and refuses any other verb as gitwc (${out:0:80})" \
            "printf '%s' \"\$out\" | grep -q 'does not run as gitwc'"
        assert "the agent's own gitctl unpushed switches to gitwc and works" "sg_git gitctl unpushed '${SG_WC}'"
    fi
    out=$(sg_git sudo -n -u gitwc /bin/sh -c id 2>&1 || true)
    assert "the sudo rule allows gitctl only, nothing else as gitwc" \
        "! printf '%s' \"\$out\" | grep -q 'uid='"
}

sg_part_requests() {
    echo "[git] a repo, a session's worktree, and its requests"
    local wt_rel=".aidc-smoke-${SG_SESSION}" out
    SG_WT="${SG_WC}/${wt_rel}"
    SG_BRANCH="aidc-smoke-${SG_SESSION}"
    assert "aidc repo list shows the working copy" "sg_has '${SG_WC}' repo list"
    assert "the session has the request folder (AIDC_GIT_REQUESTS)" \
        "sg_in 'test -d \"\$AIDC_GIT_REQUESTS\"'"
    assert "and its own 64-hex git token" "sg_in '[[ \"\$AIDC_GIT_TOKEN\" =~ ^[0-9a-f]{64}\$ ]]'"
    assert "its gh is aidc's stand-in, not GitHub's CLI" "sg_in 'grep -q AIDC_GIT_REQUESTS \"\$(command -v gh)\"'"
    assert "it cannot list other sessions' requests" "! sg_in 'ls \"\$AIDC_GIT_REQUESTS/requests\"'"
    # Commits show as the user: aidc create gives the session this machine's git identity
    # (Docker and Kubernetes alike), so no identity is set here.
    SG_IDENT="$(git config --get user.name 2>/dev/null || true) <$(git config --get user.email 2>/dev/null || true)>"
    assert "the session's git identity is the user's own (${SG_IDENT})" \
        "[ \"\$SG_IDENT\" != ' <>' ] && [ \"\$(sg_in 'printf \"%s <%s>\" \"\$(git config --get user.name)\" \"\$(git config --get user.email)\"' | tail -n1)\" = \"\$SG_IDENT\" ]"
    assert "it makes its own worktree and branch in the working copy, and commits" \
        "sg_in \"cd '${SG_WC}' && git worktree add -q -b '${SG_BRANCH}' '${SG_WT}' HEAD && cd '${SG_WT}' && echo smoke > aidc-smoke.txt && git add aidc-smoke.txt && git commit -q -m 'aidc smoke'\""
    assert "git push explains: ask the git container with gh pr create" \
        "sg_in_has 'gh pr create' \"cd '${SG_WT}' && git push origin '${SG_BRANCH}'\""

    sg_request "AIDC_GH_WAIT=3" pr create --title "aidc smoke" --body "aidc smoke test"
    assert "gh pr create waits for approval in ask mode (request ${SG_REQUEST:-none})" \
        "[ -n '${SG_REQUEST}' ] && printf '%s' \"\$SG_OUT\" | grep -q 'requested; waiting for approval'"
    assert "aidc git requests lists it" "sg_has '${SG_REQUEST:-none}' git requests"
    assert "aidc git requests <id> shows it, with the session's branch" "sg_has '${SG_BRANCH}' git requests '${SG_REQUEST:-none}'"
    # Approvals are out of the agent's reach (owner ruling 2026-11-26): as git, git-requests
    # refuses to decide, sudo has no rule for it, and gitctl's GitHub writes refuse the agent.
    # The refusals exit 1, so their output is captured first: under pipefail a failing command
    # piped into grep fails the assertion even when grep finds the text.
    out=$(sg_git git-requests approve "${SG_REQUEST:-none}" 2>&1 || true)
    assert "the git agent cannot approve it" "printf '%s' \"\$out\" | grep -q 'cannot approve'"
    assert "nor through sudo as the request holder" \
        "! sg_git sudo -n -u gitreq /opt/aidc/lib/gitctl/git-requests.sh approve '${SG_REQUEST:-none}'"
    out=$(sg_git gitctl push "${SG_WC}" "${SG_BRANCH}" 2>&1 || true)
    assert "nor push the branch itself" "printf '%s' \"\$out\" | grep -q 'runs only as a request'"
    assert "and the request still waits" "sg_has '${SG_REQUEST:-none}' git requests"
    assert "aidc git deny refuses it" "sg_has denied git deny '${SG_REQUEST:-none}' 'smoke test'"
    assert "the session reads the denial and the reason" \
        "sg_in_has 'denied by the user: smoke test' \"cd '${SG_WT}' && gh aidc request '${SG_REQUEST:-none}'\""

    assert "aidc git mode <session> rules gives this session its own mode" "sg_aidc git mode '${SG_SESSION}' rules"
    assert "aidc git mode lists it" "sg_aidc git mode | grep -E '${SG_SESSION}.*rules'"
    if [ "$SG_LOGGED_IN" = no ]; then
        sg_request "AIDC_GH_WAIT=60" pr create --title "aidc smoke" --body "aidc smoke test"
        assert "in rules mode the request runs at once, failing only for the login" \
            "printf '%s' \"\$SG_OUT\" | grep -q 'not logged in to GitHub'"
        assert "aidc git mode <session> default takes it back" "sg_aidc git mode '${SG_SESSION}' default"
        sg_request "AIDC_GH_WAIT=3" pr create --title "aidc smoke" --body "aidc smoke test"
        assert "back in ask mode it waits (request ${SG_REQUEST:-none})" \
            "printf '%s' \"\$SG_OUT\" | grep -q 'requested; waiting for approval'"
        assert "aidc git approve runs it, failing only for the login" \
            "sg_has 'not logged in to GitHub' git approve '${SG_REQUEST:-none}'"
        assert "and the session reads that result" \
            "sg_in_has 'not logged in to GitHub' \"cd '${SG_WT}' && gh aidc request '${SG_REQUEST:-none}'\""
        assert "aidc git tidy reports the session's unpushed branch as left for the user" \
            "sg_aidc git tidy '${SG_WC}' | grep -E 'unpushed: ${SG_BRANCH}'"
    else
        sg_aidc git mode "$SG_SESSION" default >/dev/null || true
        echo "  note: the git container is logged in (${SG_LOGGED_IN}): approve, rules mode and tidy would"
        echo "        push to the public repo; they run in the GitHub part, on your scratch repo"
    fi

    echo "[git] the git agent is a session"
    assert "aidc list shows git as the git agent" "sg_aidc list | grep -E '^git +.*git-agent'"
    assert "aidc kill git is refused" "! sg_aidc kill git"
    assert "aidc create git is refused" "sg_has 'git agent' create git"
    sg_in "cd '${SG_WC}' && git worktree remove --force '${SG_WT}' && git branch -D '${SG_BRANCH}'" >/dev/null 2>&1 || true
}

# The GitHub part. $1: a function that makes a working copy of the scratch repo for the git
# container, printing its path (each backend adds a repo its own way); its origin is
# https://github.com/$AIDC_SMOKE_GIT_REPO.
sg_part_github() {
    local repo="${AIDC_SMOKE_GIT_REPO:-}" make_wc="$1"
    if [ -z "$repo" ] || [ "$SG_LOGGED_IN" != yes ]; then
        echo "[git] GitHub part skipped: it needs the git container logged in (aidc git login; now: ${SG_LOGGED_IN})"
        echo "      and AIDC_SMOKE_GIT_REPO=<owner/name> naming a scratch repo you own"
        return 0
    fi
    printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' || {
        echo "  FAIL: AIDC_SMOKE_GIT_REPO=${repo} is not owner/name"; FAIL=$((FAIL + 1)); return 0; }
    echo "[git] GitHub: a real push, PR, merge and tidy on ${repo}"
    local wc def wt br sha parents out
    wc=$("$make_wc") || wc=""
    assert "a working copy of ${repo} is added (${wc:-none})" "[ -n '${wc}' ] && sg_has '${wc}' repo list"
    [ -n "$wc" ] || return 0
    SG_GH_WC="$wc"
    br="aidc-smoke-${SG_SESSION}-gh"
    wt="${wc}/.aidc-smoke-gh"
    # The working copy has origin's default branch checked out (each make_wc leaves it so).
    def=$(sg_in "git -C '${wc}' symbolic-ref -q --short HEAD" 2>/dev/null | tail -n1) || def=""
    assert "the session makes a worktree on a new branch from origin's ${def:-?}, and commits a file" \
        "sg_in \"cd '${wc}' && git worktree add -q -b '${br}' '${wt}' 'origin/${def}' && cd '${wt}' && mkdir -p aidc-smoke && date -u > 'aidc-smoke/${SG_SESSION}.txt' && git add aidc-smoke && git commit -q -m 'aidc smoke: ${SG_SESSION}'\""
    sg_aidc git mode "$SG_SESSION" rules >/dev/null || true
    SG_WT="$wt"
    sg_request "AIDC_GH_WAIT=${SG_WAIT_DONE}" pr create --title "aidc smoke ${SG_SESSION}" --body "aidc smoke test; merged and deleted by the smoke"
    SG_PR=$(printf '%s\n' "$SG_OUT" | grep -Eo "github.com/${repo}/pull/[0-9]+" | head -n1 | sed 's|.*/||') || SG_PR=""
    assert "gh pr create in rules mode pushed the branch and opened a PR (#${SG_PR:-none})" "[ -n '${SG_PR}' ]"
    if [ -z "$SG_PR" ]; then printf '%s\n' "$SG_OUT" | tail -n 8 | sed 's/^/        /'; return 0; fi
    assert "the session sees it open, on its branch" \
        "sg_in \"cd '${wt}' && gh pr view ${SG_PR} --json state,headRefName --jq '.state + \\\" \\\" + .headRefName'\" | grep -qx 'OPEN ${br}'"
    out=$(sg_aidc git merge "$wc" "$SG_PR") || true
    assert "aidc git merge merges it" "printf '%s' \"\$out\" | grep -q 'merged pull request ${SG_PR}'"
    assert "and tidies: the branch is deleted on GitHub" "printf '%s' \"\$out\" | grep -q 'deleted on GitHub: ${br}'"
    assert "and the session's worktree is removed" "printf '%s' \"\$out\" | grep -q 'removed worktree' && ! sg_in 'test -e \"${wt}\"'"
    assert "the session sees the PR merged" \
        "sg_in \"cd '${wc}' && gh pr view ${SG_PR} --json state --jq .state\" | grep -qx MERGED"
    sg_git gitctl fetch "$wc" >/dev/null 2>&1 || true
    sha=$(sg_in "cd '${wc}' && git rev-parse 'origin/${def}'" 2>/dev/null | tail -n1) || sha=""
    parents=$(sg_in "cd '${wc}' && git rev-list --parents -n1 'origin/${def}'" 2>/dev/null | tail -n1 | wc -w) || parents=0
    assert "origin's ${def} is a merge commit (${sha:0:12}, $((parents - 1)) parents)" "[ '${parents}' = 3 ]"
    assert "the branch is gone from origin after a fetch" "! sg_in \"cd '${wc}' && git rev-parse -q --verify 'refs/remotes/origin/${br}'\""
    assert "the commit the session made, now on origin's ${def}, carries the user's identity (${SG_IDENT:-?})" \
        "[ \"\$(sg_in \"cd '${wc}' && git log -1 --format='%an <%ae>' 'origin/${def}^2'\" | tail -n1)\" = \"\$SG_IDENT\" ]"
    SG_PR=""
    assert "the merge commit is the user's (the git container's identity: their GitHub name)" \
        "[ -n \"\$(sg_git git config --get user.name)\" ] && [ -n \"\$(sg_git git config --get user.email)\" ]"
    assert "aidc git protect reads the default branch's protections" "sg_has 'force' git protect '${wc}'"
    if [ "${AIDC_SMOKE_GIT_PROTECT:-0}" = 1 ]; then
        assert "and turns missing ones on when told yes" "printf 'y\\n' | '$AIDC' git protect '${wc}' --backend '${SG_BACKEND}'"
    fi
    sg_aidc git mode "$SG_SESSION" default >/dev/null || true
}

# The Claude part: the git agent asks about an ask-mode request with its question tool.
sg_part_claude() {
    if [ "${AIDC_SMOKE_GIT_CLAUDE:-0}" != 1 ]; then
        echo "[git] git agent's Claude part skipped: set AIDC_SMOKE_GIT_CLAUDE=1 once the git agent's Claude"
        echo "      is logged in (aidc git attach), with your git mode ask"
        return 0
    fi
    # shellcheck disable=SC2016  # run by the git container's shell
    if ! sg_git bash -c 'h=$HOME; { [ -s "$h/.claude/.credentials.json" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; } && [ "$(jq -r ".hasCompletedOnboarding // false" "$h/.claude.json")" = true ]' >/dev/null 2>&1; then
        echo "  FAIL: AIDC_SMOKE_GIT_CLAUDE=1 but the git agent's Claude is not set up (aidc git attach)"; FAIL=$((FAIL + 1)); return 0
    fi
    echo "[git] the git agent's Claude asks"
    local wt="${SG_WC}/.aidc-smoke-claude" br="aidc-smoke-${SG_SESSION}-claude" i found=""
    sg_in "cd '${SG_WC}' && git worktree add -q -b '${br}' '${wt}' HEAD && cd '${wt}' && echo q > aidc-q.txt && git add aidc-q.txt && git commit -q -m 'aidc smoke question'" >/dev/null 2>&1 || true
    SG_WT="$wt"
    sg_request "AIDC_GH_WAIT=3" pr create --title "aidc smoke question" --body "aidc smoke test: deny this"
    assert "the request waits (${SG_REQUEST:-none})" "[ -n '${SG_REQUEST}' ]"
    for i in $(seq 40); do
        # shellcheck disable=SC2016  # run by the git container's shell
        if sg_git bash -c 'grep -l "AskUserQuestion" "$HOME"/.claude/projects/-home-git-work/*.jsonl 2>/dev/null | xargs -r grep -l "$1"' _ "$SG_SESSION" >/dev/null 2>&1; then found=1; break; fi
        [ "$i" -lt 40 ] && sleep 3
    done
    assert "the git agent asks about it with its question tool (in its transcript, naming the session)" "[ -n '${found}' ]"
    assert "aidc git deny answers it from the terminal" "sg_has denied git deny '${SG_REQUEST:-none}' 'smoke test'"
    sg_in "cd '${SG_WC}' && git worktree remove --force '${wt}' && git branch -D '${br}'" >/dev/null 2>&1 || true
    echo "  note: answering the question from an orchestrator (session_send) is checked by hand: tests/smoke/README.md"
}

# Cleanup of the GitHub part when a step failed between the PR and its merge: merge it (the
# smoke's own PR, one file under aidc-smoke/) so the branch is deleted, or say what is left.
sg_cleanup_github() {
    [ -n "$SG_PR" ] && [ -n "$SG_GH_WC" ] || return 0
    if sg_aidc git merge "$SG_GH_WC" "$SG_PR" >/dev/null; then
        echo "[cleanup] merged the smoke's PR #${SG_PR} on ${AIDC_SMOKE_GIT_REPO} (its branch deleted)"
    else
        echo "[cleanup] LEFT on ${AIDC_SMOKE_GIT_REPO}: PR #${SG_PR} and its branch; close it on GitHub"
    fi
    SG_PR=""
}
