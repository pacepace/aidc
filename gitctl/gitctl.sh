#!/usr/bin/env bash
# gitctl: the git container's only way to the GitHub login (docs/design-12-kubernetes.md, "Git").
#
# The agent (uid 2000) runs ordinary git as itself, with no credential: it cannot reach GitHub
# with it. What needs the login is a small set of fixed verbs. Each builds its own git or gh
# command line from arguments it validates; no option the caller writes is ever passed on, so
# there is no flag spelling, prefix or attached form to get past. The verbs run as gitrun (git
# with the credential helper: fetch, push) or gitcred (gh: pull requests, the login), reached
# through the one sudo rule that names this file. sudo resets the environment, so nothing the
# caller exports reaches them. Called through sudo directly, the same checks apply: the
# arguments are re-validated as the target user, and that side opens no file the caller names
# (texts come on stdin).
#
#   gitctl fetch <repo>                                  git fetch origin
#   gitctl push <repo> <branch>                          push that branch, fast-forward only
#   gitctl pr-create <repo> <head> <base> --title-file F --body-file F   (F may be -: stdin)
#   gitctl pr-comment <repo> <number> --body-file F
#   gitctl pr-merge <repo> <number>                      always a merge commit
#   gitctl pr-view <repo> <number> | pr-list <repo>
#   gitctl status | login | logout                       the GitHub login (gitcred's)
#
# <repo> is the main checkout of a repo the git container owns (gitctl_enter_repo), with
# origin https://github.com/<owner>/<name>.
set -u

self=$(readlink -f "${BASH_SOURCE[0]}")
GITCTL_LIB=$(dirname "$self")
# shellcheck source=gitctl-rules.sh
. "$GITCTL_LIB/gitctl-rules.sh"

die() { printf 'gitctl: refused: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '/^#   gitctl/s/^#   //p' "$self"; }

PROTECTED_BRANCHES="main master develop"

if [ "$GITCTL_LIB" = /opt/aidc/lib/gitctl ]; then
    INSTALLED=1
    REAL_GIT=/usr/bin/git REAL_GH=/usr/local/bin/gh
    RUN_HOME=/home/gitrun CRED_HOME=/var/lib/gitctl/gitcred
    HELPER='!sudo -n -u gitcred /opt/aidc/lib/gitctl/cred-helper.sh'
    case "$(id -un)" in gitrun) ROLE=run ;; gitcred) ROLE=cred ;; *) ROLE=agent ;; esac
    ALLOW_LOCAL_ORIGIN=0
else
    # Run from a checkout (the unit tests): no sudo; the role is named, stubs may stand in, and
    # a local-path origin may be allowed so a push can be tested against a bare repo.
    INSTALLED=0
    REAL_GIT="${AIDC_GITCTL_REAL_GIT:-$(command -v git)}" REAL_GH="${AIDC_GITCTL_REAL_GH:-$(command -v gh || echo gh)}"
    RUN_HOME="${HOME:-/}" CRED_HOME="${AIDC_GITCTL_CRED_HOME:-${HOME:-/}}"
    HELPER=""
    ROLE="${AIDC_GITCTL_ROLE:-agent}"
    ALLOW_LOCAL_ORIGIN="${AIDC_GITCTL_ALLOW_LOCAL_ORIGIN:-0}"
fi
ulimit -c 0 2>/dev/null || true

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
    fetch|push) VERB_ROLE=run ;;
    pr-create|pr-comment|pr-merge|pr-view|pr-list|status|login|logout) VERB_ROLE=cred ;;
    ""|-h|--help|help) usage; exit 0 ;;
    *) die "${verb}: not a gitctl verb (gitctl --help)" ;;
esac

# No verb takes a free-form option: anything that looks like one is refused, whatever it says.
nargs() { [ "$1" = "$2" ] || die "${verb} takes ${2} argument(s), got ${1} (gitctl --help)"; }
no_options() {
    local a
    for a in "$@"; do case "$a" in -*) die "${verb}: ${a}: gitctl takes no options here" ;; esac; done
}

# --- gitrun: git with the login's credential helper ----------------------------------------

# Git as gitrun, inside the repo's .git, which gitctl_enter_repo entered and checked: GIT_DIR=.
# names the directory this process is in, not a path, so swapping .git or a folder above it
# after the check changes nothing. No system or global config; the repo's own config passed an
# allowlist of keys (gitctl_enter_repo); and every setting that could send git elsewhere, run a
# program or hand the token over is pinned on the command line as well. Replace refs are off:
# the scan must read the commits a push sends, not their stand-ins.
g() {
    local helper=(-c credential.helper=) proto=(-c protocol.allow=never -c protocol.https.allow=always)
    [ -n "$HELPER" ] && helper+=(-c "credential.helper=$HELPER")
    [ "$ALLOW_LOCAL_ORIGIN" = 1 ] && proto+=(-c protocol.file.allow=always)
    env -i HOME="$RUN_HOME" PATH=/usr/bin:/bin LANG=C.UTF-8 GIT_DIR=. GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 \
        "$REAL_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false "${proto[@]}" \
        -c http.proxy= -c http.sslVerify=true -c core.sshCommand= -c core.gitProxy= \
        -c core.askPass= -c push.followTags=false -c push.gpgSign=false "${helper[@]}" "$@"
}

# A test-only pause between the checks and the first git call, to swap things under gitctl.
after_check() {
    if [ "$INSTALLED" = 0 ] && [ -n "${AIDC_GITCTL_TEST_AFTER_CHECK:-}" ]; then
        bash -c "$AIDC_GITCTL_TEST_AFTER_CHECK"
    fi
}

# origin_url: the one URL git is given (by value, never the remote's name, so no remote.*
# setting applies): origin's url, and any pushurl, all one GitHub repo over https.
origin_url() {
    local urls u slug=""
    urls=$(env -i PATH=/usr/bin:/bin "$REAL_GIT" config --file ./config --get-all remote.origin.url 2>/dev/null)
    [ -n "$urls" ] || die "${GITCTL_REPO}: no origin remote"
    [ "$(printf '%s\n' "$urls" | wc -l)" = 1 ] || die "${GITCTL_REPO}: origin has more than one url"
    ORIGIN_URL="$urls"
    urls="$urls"$'\n'$(env -i PATH=/usr/bin:/bin "$REAL_GIT" config --file ./config --get-all remote.origin.pushurl 2>/dev/null)
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        if [ "$ALLOW_LOCAL_ORIGIN" = 1 ] && [ "${u#/}" != "$u" ]; then GITCTL_SLUG="local/test"
        else gitctl_slug_from_url "$u" || die "$GITCTL_REASON"; fi
        [ -z "$slug" ] || [ "$slug" = "$GITCTL_SLUG" ] || die "origin's URLs name two repos (${slug}, ${GITCTL_SLUG})"
        slug="$GITCTL_SLUG"
    done <<<"$urls"
}

run_fetch() {
    nargs $# 1; no_options "$@"
    gitctl_enter_repo "$REAL_GIT" "$1" || die "$GITCTL_REASON"
    origin_url
    after_check
    g fetch --prune --no-tags --no-recurse-submodules "$ORIGIN_URL" '+refs/heads/*:refs/remotes/origin/*'
}

# push: the one branch, by the exact commit that was checked, never forced, never deleting.
# What a push carries is decided from what origin says it has (ls-remote), never from the
# repo's refs/remotes/*, which a session can move. Each commit is read whole (cat-file), on
# its own: author, committer, any other header and the message.
run_push() {
    nargs $# 2; no_options "$@"
    local branch="$2" b local_sha heads remote_sha sha ref nots=() raw ids
    gitctl_branch_ok "$REAL_GIT" "$branch" || die "$GITCTL_REASON"
    for b in $PROTECTED_BRANCHES; do
        [ "$branch" = "$b" ] && die "pushing to ${branch} directly is refused: it changes by pull request merges (gitctl pr-merge)"
    done
    gitctl_enter_repo "$REAL_GIT" "$1" || die "$GITCTL_REASON"
    origin_url
    after_check
    local_sha=$(g rev-parse -q --verify "refs/heads/${branch}^{commit}") || die "no local branch ${branch}"
    heads=$(g ls-remote --heads "$ORIGIN_URL") || die "origin did not answer"
    remote_sha=""
    while read -r sha ref; do
        [ -n "$sha" ] || continue
        [ "$ref" = "refs/heads/${branch}" ] && remote_sha="$sha"
        g cat-file -e "${sha}^{commit}" 2>/dev/null && nots+=("^${sha}")
    done <<<"$heads"
    if [ -n "$remote_sha" ]; then
        g cat-file -e "${remote_sha}^{commit}" 2>/dev/null \
            || die "origin's ${branch} has commits this repo lacks: gitctl fetch, merge, then push"
        g merge-base --is-ancestor "$remote_sha" "$local_sha" \
            || die "${branch} is not a fast-forward of origin's: never force-push; merge origin's first"
    fi
    while read -r sha; do
        [ -n "$sha" ] || continue
        raw=$(g cat-file commit "$sha") || die "cannot read commit ${sha:0:12}"
        gitctl_check_text "$raw" "commit ${sha:0:12}" || die "$GITCTL_REASON; reword it before pushing"
        ids=$(printf '%s\n' "$raw" | sed -n '/^$/q; /^\(author\|committer\) /p')
        gitctl_ai_identity "$ids" && die "commit ${sha:0:12} is authored or committed as an AI tool or bot"
    done < <(g rev-list "$local_sha" "${nots[@]}" --)
    g push --no-recurse-submodules --no-follow-tags "$ORIGIN_URL" "${local_sha}:refs/heads/${branch}"
}

# --- gitcred: gh with the login --------------------------------------------------------------

gh_() {
    (cd / && env -i HOME="$CRED_HOME" GH_CONFIG_DIR="$CRED_HOME/gh" PATH=/usr/bin:/bin LANG=C.UTF-8 \
        TERM="${TERM:-dumb}" GH_PROMPT_DISABLED=1 GH_PAGER=cat GH_NO_UPDATE_NOTIFIER=1 \
        GH_SPINNER_DISABLED=1 GH_BROWSER=echo BROWSER=echo NO_COLOR=1 "$REAL_GH" "$@")
}

# Texts reach gitcred only on stdin: as gitcred, a file named by the caller could be the token.
# Format: the title on the first line (pr-create), the body after it.
read_texts() {
    TITLE="" BODY=""
    if [ "$1" = titled ]; then IFS= read -r TITLE || true; fi
    BODY=$(cat)
}

run_cred() {
    case "$verb" in
        status)
            nargs $# 0
            local out
            if out=$(gh_ auth status --hostname github.com 2>&1); then echo yes
            else case "$out" in *"not logged in"*) echo no ;; *) echo unknown ;; esac; fi ;;
        login)
            nargs $# 0
            (cd / && env -i HOME="$CRED_HOME" GH_CONFIG_DIR="$CRED_HOME/gh" PATH=/usr/bin:/bin LANG=C.UTF-8 \
                TERM="${TERM:-dumb}" GH_PAGER=cat GH_NO_UPDATE_NOTIFIER=1 GH_BROWSER=echo BROWSER=echo \
                "$REAL_GH" auth login --hostname github.com --git-protocol https --web --skip-ssh-key) ;;
        logout)
            nargs $# 0
            gh_ auth logout --hostname github.com ;;
        pr-list)
            nargs $# 1; gitctl_slug_ok "$1" || die "$GITCTL_REASON"
            gh_ pr list --repo "$1" ;;
        pr-view)
            nargs $# 2; gitctl_slug_ok "$1" || die "$GITCTL_REASON"; gitctl_number_ok "$2" || die "$GITCTL_REASON"
            gh_ pr view "$2" --repo "$1" ;;
        pr-create)
            nargs $# 3; no_options "$@"
            gitctl_slug_ok "$1" || die "$GITCTL_REASON"
            gitctl_branch_ok "$REAL_GIT" "$2" || die "$GITCTL_REASON"
            gitctl_branch_ok "$REAL_GIT" "$3" || die "$GITCTL_REASON"
            read_texts titled
            [ -n "$TITLE" ] || die "pr-create needs a title"
            gitctl_check_text "$TITLE" "the title" || die "$GITCTL_REASON"
            gitctl_check_text "$BODY" "the body" || die "$GITCTL_REASON"
            gh_ pr create --repo "$1" --head "$2" --base "$3" --title "$TITLE" --body "$BODY" ;;
        pr-comment)
            nargs $# 2; gitctl_slug_ok "$1" || die "$GITCTL_REASON"; gitctl_number_ok "$2" || die "$GITCTL_REASON"
            read_texts untitled
            [ -n "$BODY" ] || die "pr-comment needs a body"
            gitctl_check_text "$BODY" "the comment" || die "$GITCTL_REASON"
            gh_ pr comment "$2" --repo "$1" --body "$BODY" ;;
        pr-merge)
            nargs $# 2; gitctl_slug_ok "$1" || die "$GITCTL_REASON"; gitctl_number_ok "$2" || die "$GITCTL_REASON"
            # The merge commit's message is GitHub's, carrying the PR's title; the PR's commits
            # land on the base branch. All of it is checked first, whoever wrote it.
            local pr text
            pr=$(gh_ pr view "$2" --repo "$1" --json title,body,commits) || die "cannot read pull request ${2}"
            text=$(printf '%s' "$pr" | jq -r '.title, .body, (.commits[]? | .messageHeadline, .messageBody)') \
                || die "cannot read pull request ${2}"
            gitctl_check_text "$text" "pull request ${2}" || die "$GITCTL_REASON"
            ids=$(printf '%s' "$pr" | jq -r '.commits[]? | .authors[]? | "\(.name) <\(.email)>"')
            gitctl_ai_identity "$ids" && die "pull request ${2} has a commit authored as an AI tool or bot"
            gh_ pr merge "$2" --repo "$1" --merge ;;
    esac
}

# --- the agent's side: validate, read texts as the agent, switch user ----------------------

switch_to() { # ROLE VERB ARGS... (stdin passed on)
    local role="$1"; shift
    if [ "$INSTALLED" = 1 ]; then
        local user=gitrun; [ "$role" = cred ] && user=gitcred
        exec sudo -n -u "$user" -- "$self" "$@"
    fi
    AIDC_GITCTL_ROLE="$role" exec bash "$self" "$@"
}

# The repo's slug, read as the agent (the agent's own git; the repo's config is not its to write).
agent_slug() {
    local url
    url=$("$REAL_GIT" -C "$1" remote get-url origin 2>/dev/null) || die "${1}: no origin remote"
    gitctl_slug_from_url "$url" || die "$GITCTL_REASON"
    SLUG="$GITCTL_SLUG"
}

# read_file F: a text file named by the agent, read as the agent; - is stdin.
read_file() {
    if [ "$1" = - ]; then cat; return; fi
    if [ ! -f "$1" ] || [ ! -r "$1" ]; then die "${1}: no such file"; fi
    cat -- "$1"
}

agent_side() {
    case "$verb" in
        fetch|push)
            local repo
            [ $# -ge 1 ] || die "${verb} needs a repo (gitctl --help)"
            repo=$(realpath -e -- "$1" 2>/dev/null) || die "${1}: no such folder"
            shift
            switch_to run "$verb" "$repo" "$@" ;;
        status|login|logout) switch_to cred "$verb" "$@" ;;
        pr-list) nargs $# 1; agent_slug "$1"; switch_to cred "$verb" "$SLUG" ;;
        pr-view|pr-merge) nargs $# 2; agent_slug "$1"; switch_to cred "$verb" "$SLUG" "$2" ;;
        pr-create)
            if [ $# -ne 7 ] || [ "$4" != --title-file ] || [ "$6" != --body-file ]; then
                die "usage: gitctl pr-create <repo> <head> <base> --title-file F --body-file F"
            fi
            [ "$5" != - ] || [ "$7" != - ] || die "only one of the title and body can come on stdin"
            local title body
            # read_file's die ends only its own subshell: stop here too.
            title=$(read_file "$5") || exit 1
            body=$(read_file "$7") || exit 1
            case "$title" in *$'\n'*) die "the title is one line" ;; esac
            gitctl_check_text "$title" "the title" || die "$GITCTL_REASON"
            gitctl_check_text "$body" "the body" || die "$GITCTL_REASON"
            agent_slug "$1"
            printf '%s\n%s' "$title" "$body" | switch_to cred "$verb" "$SLUG" "$2" "$3" ;;
        pr-comment)
            if [ $# -ne 4 ] || [ "$3" != --body-file ]; then
                die "usage: gitctl pr-comment <repo> <number> --body-file F"
            fi
            local body
            body=$(read_file "$4") || exit 1
            gitctl_check_text "$body" "the comment" || die "$GITCTL_REASON"
            agent_slug "$1"
            printf '%s' "$body" | switch_to cred "$verb" "$SLUG" "$2" ;;
    esac
}

case "$ROLE" in
    agent) agent_side "$@" ;;
    run)
        [ "$VERB_ROLE" = run ] || die "${verb} does not run as gitrun"
        case "$verb" in fetch) run_fetch "$@" ;; push) run_push "$@" ;; esac ;;
    cred)
        [ "$VERB_ROLE" = cred ] || die "${verb} does not run as gitcred"
        run_cred "$@" ;;
esac
