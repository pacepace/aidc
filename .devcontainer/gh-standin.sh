#!/usr/bin/env bash
# gh in an aidc session: a stand-in, not GitHub's CLI. Sessions hold no GitHub login and cannot
# reach GitHub to push. The user's git container can, on either backend (owner rulings
# 2026-11-24): this stand-in turns `gh pr create` (with the push before it), `gh pr merge` and
# the pull request reads into requests, small JSON files in the request folder on the user's
# disk ($AIDC_GIT_REQUESTS), waits up to about a minute for the git container's result, and
# prints it the way gh would. In "ask" mode the user approves first; then this says the request
# is waiting, with its id, and exits 0.
#
#   gh pr create [-t T] [-b B | -F FILE] [-B BASE] [-H BRANCH] [-f]   push the branch, open the PR
#   gh pr merge [<number>|<branch>] [--merge]                         merge commit only
#   gh pr view [<number>|<branch>] [--json F] [-q EXPR]
#   gh pr list [-H BRANCH] [-s STATE] [--json F] [-q EXPR]
#   gh pr status                                                      this session's requests
#   gh repo view [--json F] [-q EXPR]                                 from the working copy
#   gh aidc push [<branch>]                                           push only
#   gh aidc request <id> | gh aidc requests                           a request's result; the list
#
# The request folder belongs to the git container (uid 2000): a session can drop a request into
# requests/ and read a result by its id, nothing else. Ids are random, so one session cannot
# guess another's.
set -u

AGENT_UID="${AIDC_GIT_AGENT_UID:-2000}"
WAIT="${AIDC_GH_WAIT:-60}"
REQ="${AIDC_GIT_REQUESTS:-}"
STATE="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/aidc-gh"
PR_FIELDS=number,title,body,state,url,headRefName,headRefOid,baseRefName,isDraft,mergedAt,reviewDecision,statusCheckRollup

die() { printf 'gh: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '/^#   gh /s/^#   //p' "$0"; }
printable() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

unsupported() {
    die "${1}: not available in an aidc session. This gh is a stand-in that asks your git container; it does: pr create (pushes too), pr merge (merge commit), pr view, pr list, pr status, repo view, aidc push, aidc request <id> (gh --help)"
}

# The request folder: set when the user has a git container (on Docker, for sessions created
# after aidc git setup), the git container's, and ready.
need_folder() {
    if [ -z "$REQ" ]; then
        die "no git container is set up for this session, so nothing here can push or reach GitHub. On the Docker backend, push and open pull requests from your own machine, or have the user run aidc git setup and create this session again."
    fi
    { [ -d "$REQ/requests" ] && [ "$(stat -c %u "$REQ" 2>/dev/null)" = "$AGENT_UID" ]; } \
        || die "the git container's request folder (${REQ}) is not set up, or is not the git container's: ask the user to run aidc git setup"
}

# The working copy this session is in: REPO (the main working copy), WORKTREE (this checkout).
need_repo() {
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not in a git working copy"
    case "$common" in */.git) REPO="${common%/.git}" ;; *) die "${common}: not a working copy's .git folder" ;; esac
    WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null) || WORKTREE="$REPO"
    git -C "$REPO" config --get remote.origin.url 2>/dev/null | grep -Eq '^https://github\.com/[^/]+/[^/]+$' \
        || die "origin is not a GitHub repo (https://github.com/<owner>/<name>); the git container works only with those"
}

current_branch() { git symbolic-ref -q --short HEAD 2>/dev/null || die "not on a branch (detached HEAD): name one with --head"; }
default_base() { git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'; }

new_id() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# submit ACTION [jq --arg pairs...]: write the request (whole, then renamed into place) and
# keep its id for gh pr status. Sets ID. The session's token (AIDC_GIT_TOKEN, in its pod only)
# goes with it, so a git mode the user gave this session applies to its requests alone.
submit() {
    local action="$1" tmp
    shift
    ID=$(new_id)
    [[ "$ID" =~ ^[0-9a-f]{32}$ ]] || die "cannot make a request id"
    tmp="$REQ/requests/.${ID}.tmp"
    if ! ( umask 027
      jq -n --arg id "$ID" --arg session "${AIDC_SESSION:-session}" --arg action "$action" \
        --arg repo "$REPO" --arg worktree "$WORKTREE" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg token "${AIDC_GIT_TOKEN:-}" "$@" \
        '{version: 1, id: $id, session: $session, action: $action, repo: $repo, worktree: $worktree, created: $created}
         + ($ARGS.named | del(.id, .session, .action, .repo, .worktree, .created) | with_entries(select(.value != "")))' \
        > "$tmp" ) || ! mv -f -- "$tmp" "$REQ/requests/${ID}.json"; then
        rm -f -- "$tmp" 2>/dev/null; die "cannot write the request into ${REQ}/requests"
    fi
    mkdir -p "$STATE" 2>/dev/null && printf '%s %s %s\n' "$action" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BRANCH_NOTE:-}" > "$STATE/$ID" 2>/dev/null
    find "$STATE" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null || true
}

# await ID SECONDS: wait for a final result (done, failed or denied). Returns 0 with RESULT set,
# or 1 when none came in time (RESULT holds the last one read, if any).
await() {
    local f="$REQ/results/${1}.json" i=0 s
    RESULT=""
    while :; do
        if [ -r "$f" ]; then
            RESULT=$(cat -- "$f" 2>/dev/null)
            s=$(printf '%s' "$RESULT" | jq -r '.state // ""' 2>/dev/null)
            case "$s" in done|failed|denied) return 0 ;; esac
        fi
        [ "$i" -lt "$2" ] || return 1
        sleep 1; i=$((i + 1))
    done
}

field() { printf '%s' "$RESULT" | jq -r --arg k "$1" '.[$k] // ""' 2>/dev/null | printable; }

# finish ID: print a request's result as gh would, or say it waits. Mutating requests that wait
# exit 0 (the request stands); a read that got no answer exits 1 (the caller has no data).
finish() {
    local id="$1" kind="$2" state
    if ! await "$id" "$WAIT"; then
        state=$(field state)
        if [ "$kind" = read ]; then
            die "no answer from the git container yet (request ${id}${state:+, $state}); try again, or: gh aidc request ${id}"
        fi
        echo "requested; waiting for approval (request ${id}). Check it with: gh aidc request ${id}  (or gh pr status)"
        return 0
    fi
    state=$(field state)
    if [ "$state" != "done" ]; then
        printf 'gh: the git container %s request %s: %s\n' "$state" "$id" "$(field message)" >&2
        [ -z "$(field output)" ] || field output | tail -n 20 | sed 's/^/  /' >&2
        exit 1
    fi
    upstream
    return 0
}

# upstream: after a push, this working copy learns what origin now has (the session cannot fetch),
# and the branch tracks it, as `git push -u` would leave it.
upstream() {
    local b sha
    b=$(printf '%s' "$RESULT" | jq -r '.pushed.branch // ""' 2>/dev/null)
    sha=$(printf '%s' "$RESULT" | jq -r '.pushed.sha // ""' 2>/dev/null)
    [[ "$sha" =~ ^[0-9a-f]{40,64}$ ]] && [ -n "$b" ] || return 0
    git check-ref-format --branch "$b" >/dev/null 2>&1 || return 0
    git update-ref "refs/remotes/origin/${b}" "$sha" 2>/dev/null || return 0
    if git rev-parse -q --verify "refs/heads/${b}" >/dev/null && [ -z "$(git config --get "branch.${b}.remote" 2>/dev/null)" ]; then
        git config "branch.${b}.remote" origin && git config "branch.${b}.merge" "refs/heads/${b}"
    fi
}

# select_json OUTPUT FIELDS EXPR: gh's --json and --jq on the git container's answer.
select_json() {
    local out="$1" fields="$2" expr="$3" f
    if [ -n "$fields" ]; then
        for f in ${fields//,/ }; do
            case ",${PR_FIELDS}," in *",${f},"*) ;; *) die "--json ${f}: not available here (available: ${PR_FIELDS})" ;; esac
        done
        out=$(printf '%s' "$out" | jq --arg f "$fields" '($f | split(",")) as $k
            | def pick: with_entries(select(.key as $x | $k | index($x)));
            if type == "array" then map(pick) else pick end') || die "the git container's answer is not JSON"
    fi
    if [ -n "$expr" ]; then printf '%s' "$out" | jq -r "$expr" | printable
    else printf '%s\n' "$out" | printable; fi
}

json_flags() { # parse --json/-q/--jq out of the args into JSON_FIELDS, JQ_EXPR; the rest in ARGS
    JSON_FIELDS="" JQ_EXPR="" ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) [ $# -ge 2 ] || die "--json needs fields"; JSON_FIELDS="$2"; shift 2 ;;
            --json=*) JSON_FIELDS="${1#--json=}"; shift ;;
            -q|--jq) [ $# -ge 2 ] || die "$1 needs an expression"; JQ_EXPR="$2"; shift 2 ;;
            --jq=*) JQ_EXPR="${1#--jq=}"; shift ;;
            -t|--template|--template=*) unsupported "gh --template" ;;
            *) ARGS+=("$1"); shift ;;
        esac
    done
    [ -z "$JQ_EXPR" ] || [ -n "$JSON_FIELDS" ] || die "--jq needs --json"
}

pr_create() {
    local title="" body="" have_body=0 base="" head="" fill=0 f
    while [ $# -gt 0 ]; do
        case "$1" in
            -t|--title) [ $# -ge 2 ] || die "$1 needs a value"; title="$2"; shift 2 ;;
            --title=*) title="${1#--title=}"; shift ;;
            -b|--body) [ $# -ge 2 ] || die "$1 needs a value"; body="$2"; have_body=1; shift 2 ;;
            --body=*) body="${1#--body=}"; have_body=1; shift ;;
            -F|--body-file|--body-file=*)
                if [ "$1" = -F ] || [ "$1" = --body-file ]; then [ $# -ge 2 ] || die "$1 needs a file"; f="$2"; shift 2
                else f="${1#--body-file=}"; shift; fi
                if [ "$f" = - ]; then body=$(head -c 65537)
                else { [ -f "$f" ] && [ -r "$f" ]; } || die "${f}: no such file"; body=$(head -c 65537 -- "$f"); fi
                have_body=1 ;;
            -B|--base) [ $# -ge 2 ] || die "$1 needs a branch"; base="$2"; shift 2 ;;
            --base=*) base="${1#--base=}"; shift ;;
            -H|--head) [ $# -ge 2 ] || die "$1 needs a branch"; head="$2"; shift 2 ;;
            --head=*) head="${1#--head=}"; shift ;;
            -f|--fill|--fill-first|--fill-verbose) fill=1; shift ;;
            -d|--draft) die "draft pull requests are not supported through the git container; open it as ready" ;;
            *) unsupported "gh pr create $1" ;;
        esac
    done
    need_folder; need_repo
    [ -n "$head" ] || head=$(current_branch)
    case "$head" in *:*) die "--head ${head}: only a branch of this repo (no owner:branch)" ;; esac
    git rev-parse -q --verify "refs/heads/${head}^{commit}" >/dev/null || die "no local branch ${head}"
    [ -n "$base" ] || base=$(default_base)
    if [ "$fill" = 1 ]; then
        local range="refs/heads/${head}" n
        [ -z "$base" ] || ! git rev-parse -q --verify "refs/remotes/origin/${base}" >/dev/null || range="refs/remotes/origin/${base}..refs/heads/${head}"
        n=$(git rev-list --count "$range" 2>/dev/null || echo 0)
        if [ "$n" = 1 ]; then
            [ -n "$title" ] || title=$(git log -1 --format=%s "refs/heads/${head}")
            [ "$have_body" = 1 ] || body=$(git log -1 --format=%b "refs/heads/${head}")
        else
            [ -n "$title" ] || title="$head"
            [ "$have_body" = 1 ] || body=$(git log --reverse --format='- %s' "$range" 2>/dev/null)
        fi
    fi
    [ -n "$title" ] || die "a title is needed (--title, or --fill): nothing prompts here"
    case "$title" in *$'\n'*) die "the title is one line" ;; esac
    BRANCH_NOTE="$head"
    submit pr-create --arg branch "$head" --arg base "$base" --arg title "$title" --arg body "$body"
    finish "$ID" change || exit 1
    if [ "$(field state)" = "done" ]; then
        local url; url=$(field url)
        if [ -n "$url" ]; then printf '%s\n' "$url"; else field message; fi
        case "$(field message)" in *"aidc git protect"*) printf '%s\n' "$(field message)" >&2 ;; esac
    fi
}

aidc_push() {
    local b="${1:-}"
    [ $# -le 1 ] || die "usage: gh aidc push [<branch>]"
    need_folder; need_repo
    [ -n "$b" ] || b=$(current_branch)
    git rev-parse -q --verify "refs/heads/${b}^{commit}" >/dev/null || die "no local branch ${b}"
    BRANCH_NOTE="$b"
    submit push --arg branch "$b"
    finish "$ID" change || exit 1
    [ "$(field state)" != "done" ] || field message
}

# number_for ARG: a PR number for <number>, <branch> or nothing (the current branch).
number_for() {
    local a="${1:-}"
    if [[ "$a" =~ ^[1-9][0-9]{0,9}$ ]]; then printf '%s' "$a"; return; fi
    case "$a" in https://github.com/*/pull/*) a="${a##*/pull/}"; a="${a%%[!0-9]*}"; printf '%s' "$a"; return ;; esac
    [ -n "$a" ] || a=$(current_branch)
    submit pr-view --arg head "$a"
    finish "$ID" read >/dev/null
    field output | jq -r '.number // empty' 2>/dev/null | grep -E '^[0-9]+$' || die "no pull request for ${a}"
}

pr_merge() {
    local target="" n
    while [ $# -gt 0 ]; do
        case "$1" in
            -m|--merge) shift ;;
            -d|--delete-branch) shift ;;  # the git container tidies after every merge anyway
            -s|--squash|-r|--rebase) die "only merge commits: the git container never squashes or rebases a merge" ;;
            --auto|--admin|--disable-auto) die "$1: not available through the git container" ;;
            -*) unsupported "gh pr merge $1" ;;
            *) [ -z "$target" ] || die "one pull request at a time"; target="$1"; shift ;;
        esac
    done
    need_folder; need_repo
    n=$(number_for "$target") || exit 1
    BRANCH_NOTE="#${n}"
    submit pr-merge --arg number "$n"
    finish "$ID" change || exit 1
    if [ "$(field state)" = "done" ]; then field message; field output | sed -n '/^tidy:$/,$p'; fi
}

pr_view() {
    local target="" n out
    json_flags "$@"
    set -- ${ARGS[@]+"${ARGS[@]}"}
    while [ $# -gt 0 ]; do
        case "$1" in -*) unsupported "gh pr view $1" ;; *) [ -z "$target" ] || die "one pull request at a time"; target="$1"; shift ;; esac
    done
    need_folder; need_repo
    if [[ "$target" =~ ^[1-9][0-9]{0,9}$ ]]; then submit pr-view --arg number "$target"
    else [ -n "$target" ] || target=$(current_branch); submit pr-view --arg head "$target"; fi
    finish "$ID" read
    out=$(field output)
    if [ -n "$JSON_FIELDS" ]; then select_json "$out" "$JSON_FIELDS" "$JQ_EXPR"; return; fi
    printf '%s' "$out" | jq -r '"\(.title) #\(.number)\n\(.state) \(.headRefName) -> \(.baseRefName)  \(.url)\n\n\(.body)"' | printable
}

pr_list() {
    local head="" state=open out
    json_flags "$@"
    set -- ${ARGS[@]+"${ARGS[@]}"}
    while [ $# -gt 0 ]; do
        case "$1" in
            -H|--head) [ $# -ge 2 ] || die "$1 needs a branch"; head="$2"; shift 2 ;;
            --head=*) head="${1#--head=}"; shift ;;
            -s|--state) [ $# -ge 2 ] || die "$1 needs a state"; state="$2"; shift 2 ;;
            --state=*) state="${1#--state=}"; shift ;;
            -L|--limit) shift 2 ;;
            --limit=*) shift ;;
            *) unsupported "gh pr list $1" ;;
        esac
    done
    case "$state" in open|closed|merged|all) ;; *) die "--state ${state}: one of open, closed, merged, all" ;; esac
    need_folder; need_repo
    submit pr-list --arg state "$state" --arg head "$head"
    finish "$ID" read
    out=$(field output)
    if [ -n "$JSON_FIELDS" ]; then select_json "$out" "$JSON_FIELDS" "$JQ_EXPR"; return; fi
    printf '%s' "$out" | jq -r '.[] | "#\(.number)\t\(.title)\t\(.headRefName)\t\(.state)"' | printable
}

# This session's requests, newest first, with their state.
pr_status() {
    local f id s
    need_folder
    [ -d "$STATE" ] || { echo "no requests from this session"; return 0; }
    while IFS= read -r f; do
        id="$f"
        [[ "$id" =~ ^[0-9a-f]{32}$ ]] || continue
        s=$(jq -r '"\(.state): \(.message)"' "$REQ/results/${id}.json" 2>/dev/null | printable) || s=""
        printf '%s  %s  %s\n' "$id" "$(cut -d' ' -f1,3 "$STATE/$f" | printable)" "${s:-sent, not taken yet}"
    done < <(find "$STATE" -maxdepth 1 -type f -printf '%T@ %f\n' 2>/dev/null | sort -rn | cut -d' ' -f2)
}

aidc_request() {
    { [ $# = 1 ] && [[ "$1" =~ ^[0-9a-f]{32}$ ]]; } || die "usage: gh aidc request <id>"
    need_folder
    [ -r "$REQ/results/${1}.json" ] || { echo "request ${1}: sent, not taken yet"; return 0; }
    RESULT=$(cat -- "$REQ/results/${1}.json")
    printf 'request %s: %s: %s\n' "$1" "$(field state)" "$(field message)"
    [ -z "$(field url)" ] || field url
    [ -z "$(field output)" ] || field output | tail -n 40
    case "$(field state)" in failed|denied) return 1 ;; esac
}

repo_view() {
    local url slug def
    json_flags "$@"
    [ ${#ARGS[@]} = 0 ] || unsupported "gh repo view ${ARGS[0]}"
    need_repo
    url=$(git -C "$REPO" config --get remote.origin.url); slug="${url#https://github.com/}"; slug="${slug%.git}"
    def=$(default_base)
    local out
    out=$(jq -n --arg slug "$slug" --arg dflt "$def" --arg url "https://github.com/${slug}" \
        '{name: ($slug | split("/")[1]), owner: {login: ($slug | split("/")[0])}, nameWithOwner: $slug,
          url: $url, defaultBranchRef: {name: $dflt}}')
    if [ -n "$JSON_FIELDS" ]; then
        local f
        for f in ${JSON_FIELDS//,/ }; do
            case "$f" in name|owner|nameWithOwner|url|defaultBranchRef) ;; *) die "--json ${f}: not available here (name, owner, nameWithOwner, url, defaultBranchRef)" ;; esac
        done
        out=$(printf '%s' "$out" | jq --arg f "$JSON_FIELDS" '($f | split(",")) as $k | with_entries(select(.key as $x | $k | index($x)))')
        if [ -n "$JQ_EXPR" ]; then printf '%s' "$out" | jq -r "$JQ_EXPR"; else printf '%s\n' "$out"; fi
        return
    fi
    printf '%s\ndefault branch: %s\n' "https://github.com/${slug}" "${def:-unknown}"
}

case "${1:-} ${2:-}" in
    "pr create") shift 2; pr_create "$@" ;;
    "pr merge") shift 2; pr_merge "$@" ;;
    "pr view") shift 2; pr_view "$@" ;;
    "pr list") shift 2; pr_list "$@" ;;
    "pr status") shift 2; [ $# = 0 ] || unsupported "gh pr status $*"; pr_status ;;
    "repo view") shift 2; repo_view "$@" ;;
    "aidc push") shift 2; aidc_push "$@" ;;
    "aidc request") shift 2; aidc_request "$@" ;;
    "aidc requests") shift 2; pr_status ;;
    "auth status")
        echo "aidc session: there is no GitHub login here. Pull requests go through the user's git container (gh pr create, gh pr merge, gh pr view, gh pr list)."
        [ -n "$REQ" ] || exit 1 ;;
    "--version "*|"version "*) echo "gh (aidc session stand-in): requests to the user's git container" ;;
    " "|"-h "*|"--help "*|"help "*) usage ;;
    *) unsupported "gh $*" ;;
esac
