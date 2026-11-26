#!/usr/bin/env bash
# gh in an aidc session: a stand-in, not GitHub's CLI. Sessions hold no GitHub login and cannot
# reach GitHub to push. The user's git container can, on either backend (owner rulings
# 2026-11-24): this stand-in turns `gh pr create` (with the push before it), `gh pr merge` and
# the pull request reads into requests, small JSON files in the request folder on the user's
# disk ($AIDC_GIT_REQUESTS), waits up to about a minute for the git container's result, and
# prints it the way gh would. In "ask" mode the user approves first; then this says the request
# is waiting, with its id, and exits 0. A request the git container has not taken at all (it is
# not running, or refuses its request folder) is said so, never as waiting for approval.
#
#   gh pr create [-t T] [-b B | -F FILE] [-B BASE] [-H BRANCH] [-f]   push the branch, open the PR
#   gh pr merge [<number>|<branch>] [--merge]                         merge commit only
#   gh pr view [<number>|<branch>] [--json F] [-q EXPR]
#   gh pr list [-H BRANCH] [-s STATE] [--json F] [-q EXPR]
#   gh pr status                                                      this session's requests
#   gh repo view [--json F] [-q EXPR]                                 from the working copy
#   gh aidc push [<branch>]                                           push only
#   gh aidc request <id> | gh aidc requests                           a request's result; the list
#   gh api <path> [--method M] [--input F|-] [-i] [-H "If-None-Match: <etag>"]
#                                   an issue call (the git container passes on only its table of
#                                   issue endpoints: gitctl api); GitHub's answer, messages and exit
#   gh issue list [-s S] [-l L] [-a A] [-L N] [--json F] [-q E] [-R owner/name]
#   gh issue view <n> [--json F] [-q E] [-R owner/name]
#   gh issue create -t T [-b B | -F FILE] [-l L] [-a A] [-m <number>] [-R owner/name]
#   gh issue edit <n> [-t T] [-b B | -F FILE] [--add-label L] [--remove-label L]
#                     [--add-assignee A] [--remove-assignee A] [-m <number>] [-R owner/name]
#   gh issue comment <n> (-b B | -F FILE) [-R owner/name]
#   gh issue close <n> [-c COMMENT] [-r completed|"not planned"] [-R owner/name]
#   gh issue reopen <n> [-R owner/name]
#
# The request folder belongs to the git container's request holder (gitreq, uid 2003): a session
# (or the git agent, whose gh is this same stand-in) can drop a request into
# requests/ and read a result by its id, nothing else. Ids are random, so one session cannot
# guess another's.
set -u

HOLDER_UID="${AIDC_GIT_HOLDER_UID:-2003}"
WAIT="${AIDC_GH_WAIT:-60}"
REQ="${AIDC_GIT_REQUESTS:-}"
STATE="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/aidc-gh"
PR_FIELDS=number,title,body,state,url,headRefName,headRefOid,baseRefName,isDraft,mergedAt,reviewDecision,statusCheckRollup

die() { printf 'gh: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '/^#   gh /s/^#   //p' "$0"; }
printable() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

unsupported() {
    die "${1}: not available in an aidc session. This gh is a stand-in that asks your git container; it does: pr create (pushes too), pr merge (merge commit), pr view, pr list, pr status, repo view, api (issue calls), issue list|view|create|edit|comment|close|reopen, aidc push, aidc request <id> (gh --help)"
}

# The request folder: set when the user has a git container (on Docker, for sessions created
# after aidc git setup), the git container's, and ready.
need_folder() {
    if [ -z "$REQ" ]; then
        die "no git container is set up for this session, so nothing here can push or reach GitHub. On the Docker backend, push and open pull requests from your own machine, or have the user run aidc git setup and create this session again."
    fi
    { [ -d "$REQ/requests" ] && [ "$(stat -c %u "$REQ" 2>/dev/null)" = "$HOLDER_UID" ]; } \
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

# untaken ID: 0 when the request still sits in requests/ with no result: the git container has
# not taken it (a session can test its own request by name, not list the folder).
untaken() { [ ! -e "$REQ/results/${1}.json" ] && [ -e "$REQ/requests/${1}.json" ]; }
not_taken_msg() {
    printf 'the git container has not taken request %s: it is not running, or it cannot use its request folder (the user sees why with: aidc git status). The request stays and is taken once it can be; check it with: gh aidc request %s' "$1" "$1"
}

# gone_state ID: where a request stands when neither its request file nor its result is there.
# The git container takes a request by moving it out of requests/ before it writes any result,
# so a request just taken looks like this too; only the 30-day sweep (git-requests' expire)
# removes both for good. So it is "expired" only when this session's own record says it was
# sent more than 30 days ago; within that it is taken and not answered yet. With no record (not
# sent from this session, or its record already swept) neither can be told.
gone_state() {
    local sent t
    sent=$(cut -d' ' -f2 "$STATE/$1" 2>/dev/null) || sent=""
    if [ -z "$sent" ] || ! t=$(date -u -d "$sent" +%s 2>/dev/null); then
        printf 'unknown: no request or result is there, and this session has no record of sending it (another session'"'"'s, or expired: the git container keeps them 30 days)'
    elif [ $(( $(date -u +%s) - t )) -gt $(( 30 * 86400 )) ]; then
        printf 'expired: no request or result is kept for it any more (the git container keeps them 30 days)'
    else
        printf 'taken, not answered yet: the git container took it and has not written a result; check again shortly'
    fi
}

# finish ID: print a request's result as gh would, or say where it stands. A change waiting for
# the user's approval, or being run, exits 0 (the request stands); one the git container has not
# taken exits 1, saying so; a read that got no answer exits 1 (the caller has no data).
finish() {
    local id="$1" kind="$2" state
    if ! await "$id" "$WAIT"; then
        state=$(field state)
        untaken "$id" && die "$(not_taken_msg "$id")"
        if [ "$kind" = read ]; then
            die "no answer from the git container yet (request ${id}${state:+, $state}); try again, or: gh aidc request ${id}"
        fi
        case "$state" in
            pending) echo "requested; waiting for approval (request ${id}): the user approves it with aidc git approve ${id} on their own machine. Check it with: gh aidc request ${id}  (or gh pr status)" ;;
            running) echo "requested; the git container is running it (request ${id}). Check it with: gh aidc request ${id}" ;;
            *) echo "requested; the git container took it and has not answered yet (request ${id}). Check it with: gh aidc request ${id}" ;;
        esac
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

# select_json OUTPUT FIELDS EXPR [AVAILABLE]: gh's --json and --jq on the git container's answer
# (AVAILABLE: the fields there are, PR_FIELDS unless named).
select_json() {
    local out="$1" fields="$2" expr="$3" avail="${4:-$PR_FIELDS}" f
    if [ -n "$fields" ]; then
        for f in ${fields//,/ }; do
            case ",${avail}," in *",${f},"*) ;; *) die "--json ${f}: not available here (available: ${avail})" ;; esac
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

# This session's requests, newest first, with their state: the result when there is one; "sent,
# not taken yet" while the request itself still waits in the folder; and when neither is there,
# gone_state's answer: "taken, not answered yet" within 30 days of sending, "expired" after
# (the git container deletes requests and results after 30 days). Never "not taken" for a
# request that has left the folder.
pr_status() {
    local f id s
    need_folder
    [ -d "$STATE" ] || { echo "no requests from this session"; return 0; }
    while IFS= read -r f; do
        id="$f"
        [[ "$id" =~ ^[0-9a-f]{32}$ ]] || continue
        s=$(jq -r '"\(.state): \(.message)"' "$REQ/results/${id}.json" 2>/dev/null | printable) || s=""
        if [ -z "$s" ]; then
            if untaken "$id"; then s="sent, not taken yet"
            else s=$(gone_state "$id"); fi
        fi
        printf '%s  %s  %s\n' "$id" "$(cut -d' ' -f1,3 "$STATE/$f" | printable)" "$s"
    done < <(find "$STATE" -maxdepth 1 -type f -printf '%T@ %f\n' 2>/dev/null | sort -rn | cut -d' ' -f2)
}

aidc_request() {
    { [ $# = 1 ] && [[ "$1" =~ ^[0-9a-f]{32}$ ]]; } || die "usage: gh aidc request <id>"
    need_folder
    if [ ! -r "$REQ/results/${1}.json" ]; then
        if untaken "$1"; then echo "request ${1}: sent, not taken yet: $(not_taken_msg "$1")"
        else echo "request ${1}: $(gone_state "$1")"; fi
        return 0
    fi
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

# --- issues (GIT-07): GitHub's issue API, through the git container ---------------------------

ISSUE_FIELDS=number,title,body,state,stateReason,url,labels,assignees,author,milestone,createdAt,updatedAt,closedAt
# gh issue's JSON for an issue as GitHub's REST API gives it.
ISSUE_JQ='{number, title, body: (.body // ""), state: (.state | ascii_upcase),
  stateReason: ((.state_reason // "") | ascii_upcase), url: .html_url,
  labels: [.labels[]? | {name}], assignees: [.assignees[]? | {login}], author: {login: .user.login},
  milestone: (if .milestone then {number: .milestone.number, title: .milestone.title} else null end),
  createdAt: .created_at, updatedAt: .updated_at, closedAt: .closed_at}'

# api_request METHOD PATH [BODY] [INCLUDE] [ETAG]: one api request, waited for; RESULT is its
# result. Returns 1, saying why, when the git container has not answered (not taken, or waiting
# for the user's approval: an api caller has no data then).
api_request() {
    local state
    REPO="" WORKTREE=""
    submit api --arg method "$1" --arg path "${2#/}" --arg input "${3:-}" --arg include "${4:-}" --arg etag "${5:-}"
    if ! await "$ID" "$WAIT"; then
        untaken "$ID" && die "$(not_taken_msg "$ID")"
        state=$(field state)
        case "$state" in
            pending) printf 'gh: requested; waiting for approval (request %s): the user approves it with aidc git approve %s on their own machine\n' "$ID" "$ID" >&2 ;;
            *) printf 'gh: no answer from the git container yet (request %s%s); try again, or: gh aidc request %s\n' "$ID" "${state:+, $state}" "$ID" >&2 ;;
        esac
        return 1
    fi
}

# issue_call METHOD PATH [BODY]: an api request whose answer the caller reads (API_OUT); dies with
# GitHub's or the git container's reason when it failed.
issue_call() {
    local why
    api_request "$@" || exit 1
    API_OUT=$(printf '%s' "$RESULT" | jq -r '.stdout // ""')
    if [ "$(field state)" != "done" ]; then
        why=$(printf '%s' "$RESULT" | jq -r 'if (.stderr // "") != "" then .stderr else .message // "" end' | printable)
        die "${why:-the git container failed request ${ID}}"
    fi
}

gh_api() {
    local method="" path="" input="" include="" etag="" f out err rc
    while [ $# -gt 0 ]; do
        case "$1" in
            -X|--method) [ $# -ge 2 ] || die "$1 needs a method"; method="$2"; shift 2 ;;
            --method=*) method="${1#--method=}"; shift ;;
            --input)
                [ $# -ge 2 ] || die "--input needs a file"; f="$2"; shift 2
                if [ "$f" = - ]; then input=$(head -c 65537)
                else { [ -f "$f" ] && [ -r "$f" ]; } || die "${f}: no such file"; input=$(head -c 65537 -- "$f"); fi ;;
            -i|--include) include=1; shift ;;
            -H|--header)
                [ $# -ge 2 ] || die "$1 needs a header"
                case "$2" in [Ii]f-[Nn]one-[Mm]atch:*) etag="${2#*:}"; etag="${etag# }"; include=1 ;;
                    *) die "--header ${2%%:*}: only If-None-Match passes through the git container" ;; esac
                shift 2 ;;
            -*) unsupported "gh api $1" ;;
            *) [ -z "$path" ] || die "one path at a time"; path="$1"; shift ;;
        esac
    done
    [ -n "$path" ] || die "usage: gh api <path> [--method M] [--input F|-] [-i] [-H 'If-None-Match: <etag>']"
    method=$(printf '%s' "${method:-GET}" | tr '[:lower:]' '[:upper:]')
    need_folder
    api_request "$method" "$path" "$input" "$include" "$etag" || exit 1
    out=$(printf '%s' "$RESULT" | jq -r '.stdout // ""')
    err=$(printf '%s' "$RESULT" | jq -r '.stderr // ""')
    rc=$(printf '%s' "$RESULT" | jq -r '.exit // ""')
    if [ -z "$rc" ]; then
        # Refused before it reached GitHub (the git container's checks): its reason, exit 1.
        printf 'gh: the git container %s request %s: %s\n' "$(field state)" "$ID" "$(field message)" >&2
        exit 1
    fi
    [ -z "$out" ] || printf '%s\n' "$out"
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    exit "$rc"
}

# issue_args ARGS...: -R owner/name taken out (else the working copy's origin): SLUG; the rest in
# ARGS.
issue_args() {
    SLUG="" ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -R|--repo) [ $# -ge 2 ] || die "$1 needs owner/name"; SLUG="$2"; shift 2 ;;
            --repo=*) SLUG="${1#--repo=}"; shift ;;
            *) ARGS+=("$1"); shift ;;
        esac
    done
    need_folder
    if [ -z "$SLUG" ]; then
        need_repo
        SLUG=$(git -C "$REPO" config --get remote.origin.url); SLUG="${SLUG#https://github.com/}"; SLUG="${SLUG%.git}"
    fi
    [[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]] || die "${SLUG}: not owner/name"
}
issue_number() { [[ "${1:-}" =~ ^[1-9][0-9]{0,9}$ ]] || die "${1:-}: not an issue number"; printf '%s' "$1"; }
read_body_file() {
    if [ "$1" = - ]; then head -c 65537; return; fi
    { [ -f "$1" ] && [ -r "$1" ]; } || die "${1}: no such file"
    head -c 65537 -- "$1"
}

issue_list() {
    local state=open labels=() assignee="" limit=30 parts qs out
    json_flags "$@"; issue_args ${ARGS[@]+"${ARGS[@]}"}
    set -- ${ARGS[@]+"${ARGS[@]}"}
    while [ $# -gt 0 ]; do
        case "$1" in
            -s|--state) [ $# -ge 2 ] || die "$1 needs a state"; state="$2"; shift 2 ;;
            -l|--label) [ $# -ge 2 ] || die "$1 needs a label"; IFS=, read -ra parts <<<"$2"; labels+=("${parts[@]}"); shift 2 ;;
            -a|--assignee) [ $# -ge 2 ] || die "$1 needs a login"; assignee="$2"; shift 2 ;;
            -L|--limit) [ $# -ge 2 ] || die "$1 needs a number"; limit="$2"; shift 2 ;;
            *) unsupported "gh issue list $1" ;;
        esac
    done
    case "$state" in open|closed|all) ;; *) die "--state ${state}: one of open, closed, all" ;; esac
    if ! [[ "$limit" =~ ^[1-9][0-9]{0,2}$ ]] || [ "$limit" -gt 100 ]; then die "--limit ${limit}: 1 to 100 here"; fi
    qs="state=${state}&per_page=${limit}&page=1"
    [ ${#labels[@]} = 0 ] || qs+="&labels=$(jq -rn '$ARGS.positional | join(",") | @uri' --args "${labels[@]}")"
    [ -z "$assignee" ] || qs+="&assignee=$(jq -rn --arg a "$assignee" '$a | @uri')"
    issue_call GET "repos/${SLUG}/issues?${qs}"
    out=$(printf '%s' "$API_OUT" | jq "[.[] | select(has(\"pull_request\") | not) | ${ISSUE_JQ}]") || die "the git container's answer is not JSON"
    if [ -n "$JSON_FIELDS" ]; then select_json "$out" "$JSON_FIELDS" "$JQ_EXPR" "$ISSUE_FIELDS"; return; fi
    printf '%s' "$out" | jq -r '.[] | "#\(.number)\t\(.state)\t\(.title)\t\([.labels[].name] | join(", "))"' | printable
}

issue_view() {
    local n out
    json_flags "$@"; issue_args ${ARGS[@]+"${ARGS[@]}"}
    [ ${#ARGS[@]} = 1 ] || die "usage: gh issue view <number> [--json F] [-q E] [-R owner/name]"
    n=$(issue_number "${ARGS[0]}") || exit 1
    issue_call GET "repos/${SLUG}/issues/${n}"
    out=$(printf '%s' "$API_OUT" | jq "$ISSUE_JQ") || die "the git container's answer is not JSON"
    if [ -n "$JSON_FIELDS" ]; then select_json "$out" "$JSON_FIELDS" "$JQ_EXPR" "$ISSUE_FIELDS"; return; fi
    printf '%s' "$out" | jq -r '"\(.title) #\(.number)\n\(.state)  \(.url)\n\n\(.body)"' | printable
}

# issue_texts ARGS...: -t/-b/-F/-l/-a/-m of create and edit into I_* (the rest in ARGS).
issue_texts() {
    I_TITLE="" I_HAVE_TITLE=0 I_BODY="" I_HAVE_BODY=0 I_LABELS=() I_ASSIGNEES=() I_MILESTONE="" I_ADDL=() I_REML=() I_ADDA=() I_REMA=()
    local rest=() q
    while [ $# -gt 0 ]; do
        case "$1" in
            -t|--title) [ $# -ge 2 ] || die "$1 needs a value"; I_TITLE="$2"; I_HAVE_TITLE=1; shift 2 ;;
            -b|--body) [ $# -ge 2 ] || die "$1 needs a value"; I_BODY="$2"; I_HAVE_BODY=1; shift 2 ;;
            -F|--body-file) [ $# -ge 2 ] || die "$1 needs a file"; I_BODY=$(read_body_file "$2") || exit 1; I_HAVE_BODY=1; shift 2 ;;
            -l|--label) [ $# -ge 2 ] || die "$1 needs a label"; IFS=, read -ra q <<<"$2"; I_LABELS+=("${q[@]}"); shift 2 ;;
            -a|--assignee) [ $# -ge 2 ] || die "$1 needs a login"; IFS=, read -ra q <<<"$2"; I_ASSIGNEES+=("${q[@]}"); shift 2 ;;
            --add-label) [ $# -ge 2 ] || die "$1 needs a label"; IFS=, read -ra q <<<"$2"; I_ADDL+=("${q[@]}"); shift 2 ;;
            --remove-label) [ $# -ge 2 ] || die "$1 needs a label"; IFS=, read -ra q <<<"$2"; I_REML+=("${q[@]}"); shift 2 ;;
            --add-assignee) [ $# -ge 2 ] || die "$1 needs a login"; IFS=, read -ra q <<<"$2"; I_ADDA+=("${q[@]}"); shift 2 ;;
            --remove-assignee) [ $# -ge 2 ] || die "$1 needs a login"; IFS=, read -ra q <<<"$2"; I_REMA+=("${q[@]}"); shift 2 ;;
            -m|--milestone) [ $# -ge 2 ] || die "$1 needs a milestone number"
                [[ "$2" =~ ^[1-9][0-9]{0,9}$ ]] || die "--milestone ${2}: give the milestone's number here"; I_MILESTONE="$2"; shift 2 ;;
            *) rest+=("$1"); shift ;;
        esac
    done
    case "$I_TITLE" in *$'\n'*) die "the title is one line" ;; esac
    ARGS=(${rest[@]+"${rest[@]}"})
}

issue_create() {
    local json
    issue_args "$@"; issue_texts ${ARGS[@]+"${ARGS[@]}"}
    [ ${#ARGS[@]} = 0 ] || unsupported "gh issue create ${ARGS[0]}"
    [ -n "$I_TITLE" ] || die "a title is needed (--title): nothing prompts here"
    json=$(jq -cn --arg t "$I_TITLE" --arg b "$I_BODY" --arg m "$I_MILESTONE" \
        --argjson l "$(jq -cn '$ARGS.positional' --args ${I_LABELS[@]+"${I_LABELS[@]}"})" \
        --argjson a "$(jq -cn '$ARGS.positional' --args ${I_ASSIGNEES[@]+"${I_ASSIGNEES[@]}"})" \
        '{title: $t, body: $b} + (if ($l | length) > 0 then {labels: $l} else {} end)
         + (if ($a | length) > 0 then {assignees: $a} else {} end) + (if $m != "" then {milestone: ($m | tonumber)} else {} end)')
    issue_call POST "repos/${SLUG}/issues" "$json"
    printf '%s' "$API_OUT" | jq -r '.html_url // empty' | printable
}

issue_edit() {
    local n json cur
    issue_args "$@"; issue_texts ${ARGS[@]+"${ARGS[@]}"}
    [ ${#ARGS[@]} = 1 ] || die "usage: gh issue edit <number> [flags]"
    n=$(issue_number "${ARGS[0]}") || exit 1
    cur='{}'
    if [ $(( ${#I_ADDL[@]} + ${#I_REML[@]} + ${#I_ADDA[@]} + ${#I_REMA[@]} )) -gt 0 ]; then
        issue_call GET "repos/${SLUG}/issues/${n}"; cur="$API_OUT"
    fi
    json=$(printf '%s' "$cur" | jq -c --arg t "$I_TITLE" --arg ht "$I_HAVE_TITLE" --arg b "$I_BODY" --arg hb "$I_HAVE_BODY" --arg m "$I_MILESTONE" \
        --argjson al "$(jq -cn '$ARGS.positional' --args ${I_ADDL[@]+"${I_ADDL[@]}"})" \
        --argjson rl "$(jq -cn '$ARGS.positional' --args ${I_REML[@]+"${I_REML[@]}"})" \
        --argjson aa "$(jq -cn '$ARGS.positional' --args ${I_ADDA[@]+"${I_ADDA[@]}"})" \
        --argjson ra "$(jq -cn '$ARGS.positional' --args ${I_REMA[@]+"${I_REMA[@]}"})" '
        (if $ht == "1" then {title: $t} else {} end)
        + (if $hb == "1" then {body: $b} else {} end)
        + (if $m != "" then {milestone: ($m | tonumber)} else {} end)
        + (if ($al | length) + ($rl | length) > 0 then {labels: (([.labels[]?.name] + $al | unique) - $rl)} else {} end)
        + (if ($aa | length) + ($ra | length) > 0 then {assignees: (([.assignees[]?.login] + $aa | unique) - $ra)} else {} end)')
    [ "$json" != '{}' ] || die "nothing to edit"
    issue_call PATCH "repos/${SLUG}/issues/${n}" "$json"
    printf '%s' "$API_OUT" | jq -r '.html_url // empty' | printable
}

issue_comment() {
    local n
    issue_args "$@"; issue_texts ${ARGS[@]+"${ARGS[@]}"}
    [ ${#ARGS[@]} = 1 ] || die "usage: gh issue comment <number> (-b BODY | -F FILE)"
    n=$(issue_number "${ARGS[0]}") || exit 1
    [ -n "$I_BODY" ] || die "a body is needed (--body or --body-file): nothing prompts here"
    issue_call POST "repos/${SLUG}/issues/${n}/comments" "$(jq -cn --arg b "$I_BODY" '{body: $b}')"
    printf '%s' "$API_OUT" | jq -r '.html_url // empty' | printable
}

issue_state() { # close|reopen ARGS...
    local verb="$1" n comment="" reason="" rest=() json
    shift
    issue_args "$@"
    set -- ${ARGS[@]+"${ARGS[@]}"}
    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--comment) if [ "$verb" != close ] || [ $# -lt 2 ]; then unsupported "gh issue ${verb} $1"; fi; comment="$2"; shift 2 ;;
            -r|--reason) if [ "$verb" != close ] || [ $# -lt 2 ]; then unsupported "gh issue ${verb} $1"; fi
                case "$2" in completed) reason=completed ;; "not planned"|not_planned) reason=not_planned ;;
                    *) die "--reason ${2}: completed or \"not planned\"" ;; esac; shift 2 ;;
            -*) unsupported "gh issue ${verb} $1" ;;
            *) rest+=("$1"); shift ;;
        esac
    done
    [ ${#rest[@]} = 1 ] || die "usage: gh issue ${verb} <number>"
    n=$(issue_number "${rest[0]}") || exit 1
    [ -z "$comment" ] || issue_call POST "repos/${SLUG}/issues/${n}/comments" "$(jq -cn --arg b "$comment" '{body: $b}')"
    if [ "$verb" = close ]; then json=$(jq -cn --arg r "$reason" '{state: "closed"} + (if $r != "" then {state_reason: $r} else {} end)')
    else json='{"state":"open"}'; fi
    issue_call PATCH "repos/${SLUG}/issues/${n}" "$json"
    if [ "$verb" = close ]; then printf 'Closed issue %s#%s\n' "$SLUG" "$n"; else printf 'Reopened issue %s#%s\n' "$SLUG" "$n"; fi
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
    "issue list") shift 2; issue_list "$@" ;;
    "issue view") shift 2; issue_view "$@" ;;
    "issue create") shift 2; issue_create "$@" ;;
    "issue edit") shift 2; issue_edit "$@" ;;
    "issue comment") shift 2; issue_comment "$@" ;;
    "issue close") shift 2; issue_state close "$@" ;;
    "issue reopen") shift 2; issue_state reopen "$@" ;;
    "api "*) shift; gh_api "$@" ;;
    "auth status")
        echo "aidc session: there is no GitHub login here. Pull requests go through the user's git container (gh pr create, gh pr merge, gh pr view, gh pr list)."
        [ -n "$REQ" ] || exit 1 ;;
    "--version "*|"version "*) echo "gh (aidc session stand-in): requests to the user's git container" ;;
    " "|"-h "*|"--help "*|"help "*) usage ;;
    *) unsupported "gh $*" ;;
esac
