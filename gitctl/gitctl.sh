#!/usr/bin/env bash
# gitctl: the git container's only way to the GitHub login (docs/design-12-kubernetes.md, "Git").
#
# The agent (uid 2000) runs ordinary git as itself, with no credential: it cannot reach GitHub
# with it. What needs the login is a small set of fixed verbs. Each builds its own git or gh
# command line from arguments it validates; no option the caller writes is ever passed on, so
# there is no flag spelling, prefix or attached form to get past. The verbs run as gitrun (git
# with the credential helper) or gitcred (gh: pull requests, the login), reached through the
# one sudo rule that names this file. sudo resets the environment, so nothing the caller
# exports reaches them. Called through sudo directly, the same checks apply: the arguments are
# re-validated as the target user, and that side opens no file the caller names (texts and
# bundles come on stdin).
#
# gitrun never runs git in a repo anyone else can write. It keeps a private bare copy of each
# GitHub repo in its own storage, which only it can enter, and moves commits between that copy
# and the user's working copies as git bundles: data, read on stdin or written to stdout. The
# working copies are ordinary repos (the sessions' and the agent's); the agent's side of each
# verb runs git there as itself.
#
#   gitctl clone <owner/name> <path>                     a new working copy at <path> (empty)
#   gitctl fetch <repo>                                  origin's branches into refs/remotes/origin/*
#   gitctl push <repo> <branch>                          push that branch, fast-forward only
#   gitctl unpushed <repo>                               after a fetch, the work on no origin branch
#   gitctl tidy <repo>                                   after merges: delete merged branches and
#                                                        their worktrees, report every leftover
#   gitctl delete-branch <repo> <branch>                 delete a branch on GitHub, if merged there
#   gitctl pr-create <repo> <head> <base> --title-file F --body-file F   (F may be -: stdin)
#   gitctl pr-comment <repo> <number> --body-file F
#   gitctl pr-merge <repo> <number>                      always a merge commit
#   gitctl pr-view <repo> <number> | pr-list <repo>
#   gitctl pr-view-json <repo> <number|branch>           one PR as JSON (fixed fields)
#   gitctl pr-list-json <repo> <open|closed|merged|all> [<head>]
#   gitctl protection <repo>                             what protects origin's default branch
#   gitctl protect <repo>                                turn missing protections on (never off)
#   gitctl status | login | logout                       the GitHub login (gitcred's)
#   gitctl storage                                       bytes in gitrun's copies and the bundles
#   gitctl remove-copy <owner/name>                      delete gitrun's private copy of a repo
#   gitctl has-copy <owner/name>                         yes when the repo is one the user added
#   gitctl adopt <repo>                                  add an existing working copy's repo (Docker:
#                                                        the user's own; gitrun makes its private copy)
#
# <repo> is a working copy (or a worktree of one) whose origin is
# https://github.com/<owner>/<name>, a repo the user added (aidc repo add: gitctl clone, which
# gives gitrun its private copy); every verb that reaches GitHub refuses any other repo, reads
# included. A verb on a <repo> may end with `--expect-repo <owner/name>`: it is refused unless
# the working copy's origin is that repo (the request watcher passes what the user approved).
# push may also end with `--expect-commit <sha>`: refused unless that is the branch's commit.
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
    RUN_HOME=/home/gitrun CRED_HOME=/var/lib/gitctl/gitcred RUN_STORE=/var/lib/gitctl/gitrun
    HELPER='!sudo -n -u gitcred /opt/aidc/lib/gitctl/cred-helper.sh'
    case "$(id -un)" in gitrun) ROLE=run ;; gitcred) ROLE=cred ;; *) ROLE=agent ;; esac
    FORGE=""
    # Docker made this container (/.dockerenv is root's, made by Docker, not by anything inside).
    ON_DOCKER=0; [ -e /.dockerenv ] && ON_DOCKER=1
    # gitwc (uid 1000, the sessions' and the user's own uid on Docker) runs the agent's verbs
    # that write a working copy, on Docker only: there the working copies are the user's own,
    # not group-writable, and stay as they are (owner ruling 2026-11-24).
    if [ "$(id -un)" = gitwc ] && [ "$ON_DOCKER" != 1 ]; then
        printf 'gitctl: refused: gitwc works only in a Docker git container\n' >&2; exit 1
    fi
else
    # Run from a checkout (the unit tests): no sudo; the role is named, stubs may stand in, and
    # a folder of bare repos (<forge>/<owner>/<name>.git) may stand in for GitHub.
    INSTALLED=0
    REAL_GIT="${AIDC_GITCTL_REAL_GIT:-$(command -v git)}" REAL_GH="${AIDC_GITCTL_REAL_GH:-$(command -v gh || echo gh)}"
    RUN_HOME="${HOME:-/}" CRED_HOME="${AIDC_GITCTL_CRED_HOME:-${HOME:-/}}"
    RUN_STORE="${AIDC_GITCTL_RUN_STORE:-}"
    HELPER=""
    ROLE="${AIDC_GITCTL_ROLE:-agent}"
    FORGE="${AIDC_GITCTL_TEST_FORGE:-}"
    ON_DOCKER="${AIDC_GITCTL_DOCKER:-0}"
fi
ulimit -c 0 2>/dev/null || true

# On the Docker backend the git container has no route out but its own proxy: aidc-proxy on its
# internal network, a Squid that reaches public addresses only (as the Kubernetes NetworkPolicy
# allows). gitrun's git and gitcred's gh go through it. The address is fixed here, never taken
# from the caller or the environment (sudo drops that anyway).
GITCTL_PROXY=""
if [ "$INSTALLED" = 1 ]; then [ "$ON_DOCKER" = 1 ] && GITCTL_PROXY="http://aidc-proxy:3128"
else GITCTL_PROXY="${AIDC_GITCTL_TEST_PROXY:-}"; fi

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
    clone|fetch|push|unpushed|tidy|delete-branch|storage|remove-copy|has-copy|add-copy|adopt) VERB_ROLE=run ;;
    pr-create|pr-comment|pr-merge|pr-view|pr-list|pr-view-json|pr-list-json|status|login|logout|protection|protect) VERB_ROLE=cred ;;
    ""|-h|--help|help) usage; exit 0 ;;
    *) die "${verb}: not a gitctl verb (gitctl --help)" ;;
esac

# No verb takes a free-form option: anything that looks like one is refused, whatever it says.
nargs() { [ "$1" = "$2" ] || die "${verb} takes ${2} argument(s), got ${1} (gitctl --help)"; }
no_options() {
    local a
    for a in "$@"; do case "$a" in -*) die "${verb}: ${a}: gitctl takes no options here" ;; esac; done
}

# forge_url OWNER/NAME: the one URL gitrun's git is ever given, by value.
forge_url() {
    if [ -n "$FORGE" ]; then printf '%s/%s.git' "$FORGE" "$1"; else printf 'https://github.com/%s' "$1"; fi
}

# url_slug URL: owner/name (in GITCTL_SLUG) of a GitHub URL, or of the test forge's.
url_slug() {
    if [ -n "$FORGE" ] && [ "${1#"$FORGE"/}" != "$1" ]; then
        GITCTL_SLUG="${1#"$FORGE"/}"; GITCTL_SLUG="${GITCTL_SLUG%.git}"
        gitctl_slug_ok "$GITCTL_SLUG"; return
    fi
    gitctl_slug_from_url "$1"
}

# --- gitrun: its private copies, git with the login's credential helper --------------------

# Git as gitrun, inside its private bare copy (enter_copy): no system or global config, the
# copy's own config is gitrun's alone, and every setting that could send git elsewhere, run a
# program or hand the token over is pinned on the command line as well. Replace refs are off:
# the scan must read the commits a push sends, not their stand-ins. gc runs only when gitctl
# asks (enter_copy), not on its own.
g() {
    local helper=(-c credential.helper=) proto=(-c protocol.allow=never -c protocol.https.allow=always)
    [ -n "$HELPER" ] && helper+=(-c "credential.helper=$HELPER")
    [ -n "$FORGE" ] && proto+=(-c protocol.file.allow=always)
    env -i HOME="$RUN_HOME" PATH=/usr/bin:/bin LANG=C.UTF-8 GIT_DIR=. GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 \
        "$REAL_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false "${proto[@]}" \
        -c "http.proxy=${GITCTL_PROXY}" -c http.sslVerify=true -c core.sshCommand= -c core.gitProxy= \
        -c core.askPass= -c push.followTags=false -c push.gpgSign=false \
        -c maintenance.auto=false "${helper[@]}" "$@"
}

# enter_copy OWNER/NAME [new]: enter gitrun's private bare copy of the repo and bring it up to
# date with origin's branches. Only `new` (gitctl clone: aidc repo add) makes a missing copy;
# every other verb refuses a repo the user has not added. A copy made here whose fetch fails is
# removed again, so a failed add leaves no repo looking added. The store is gitrun's and open
# to no one else (checked), so nothing in it was written by anyone but gitrun; each step down
# is entered with cd -P and checked with pwd -P. Sets ORIGIN_URL, and ORIGIN_HEAD to origin's
# default branch as GitHub reports it (its HEAD), or the copy's when GitHub did not say.
enter_copy() {
    local slug="${1,,}" owner name store head made=0
    owner="${slug%/*}" name="${slug#*/}"
    [ -n "$RUN_STORE" ] || die "no private store for gitrun"
    cd -P -- "$RUN_STORE" 2>/dev/null || die "${RUN_STORE}: gitrun's store is missing"
    store=$(pwd -P)
    [ "$(stat -c %u .)" = "$(id -u)" ] || die "${RUN_STORE} is not gitrun's"
    (( 8#$(stat -c %a .) & 8#077 )) && die "${RUN_STORE} is open to others: gitrun keeps its copies where only it can go"
    umask 077
    if [ "${2:-}" != new ] && [ ! -d "${owner}/${name}.git" ]; then
        die "${1} is not one of the user's repos (the user adds it: aidc repo add ${1})"
    fi
    { mkdir -p -- "$owner" && cd -P -- "$owner" && [ "$(pwd -P)" = "${store}/${owner}" ]; } \
        || die "${RUN_STORE}/${owner}: cannot enter it"
    if [ ! -e "${name}.git" ]; then
        env -i PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            "$REAL_GIT" init -q --bare --template= -- "${name}.git" || die "cannot make the private copy of ${1}"
        made=1
    fi
    { cd -P -- "${name}.git" && [ "$(pwd -P)" = "${store}/${owner}/${name}.git" ]; } \
        || die "${RUN_STORE}/${owner}/${name}.git: cannot enter it"
    ORIGIN_URL=$(forge_url "$1")
    if ! g fetch -q --prune --no-tags --no-recurse-submodules --no-write-fetch-head "$ORIGIN_URL" \
            '+refs/heads/*:refs/heads/*'; then
        [ "$made" = 0 ] || { cd -P .. && rm -rf -- "${name}.git"; }
        die "cannot fetch ${ORIGIN_URL}"
    fi
    if [ "$made" = 1 ] && [ -z "$(g for-each-ref --count=1 refs/heads/)" ]; then
        cd -P .. && rm -rf -- "${name}.git"
        die "${ORIGIN_URL} has no branches"
    fi
    # HEAD names origin's default branch, so a clone checks that one out, and push never
    # moves it.
    head=$(g ls-remote --symref "$ORIGIN_URL" HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" { print $2; exit }')
    case "$head" in refs/heads/?*) g symbolic-ref HEAD "$head" 2>/dev/null || true ;; esac
    ORIGIN_HEAD=$(g symbolic-ref -q --short HEAD 2>/dev/null || true)
    g gc --auto --quiet >/dev/null 2>&1 || true
}

# fetch (and clone's first half): origin's branches, as a bundle on stdout for the agent to
# import into the working copy. gitrun writes it; the agent only reads it.
# add-copy is the same for gitctl clone (aidc repo add): the one verb that makes a copy.
run_fetch() {
    nargs $# 1; no_options "$@"
    gitctl_slug_ok "$1" || die "$GITCTL_REASON"
    if [ "$verb" = add-copy ]; then enter_copy "$1" new; else enter_copy "$1"; fi
    [ -n "$(g for-each-ref --count=1 refs/heads/)" ] || die "${ORIGIN_URL} has no branches"
    if g rev-parse -q --verify HEAD >/dev/null; then g bundle create -q - HEAD --branches || die "cannot bundle ${ORIGIN_URL}"
    else g bundle create -q - --branches || die "cannot bundle ${ORIGIN_URL}"; fi
}

# push: the one branch, from the bundle on stdin (the agent made it from the working copy), by
# the exact commit that was checked, never forced, never deleting. The bundle is data: it is
# saved in gitrun's store, verified (its prerequisites must already be in the private copy) and
# unbundled there, and only its refs/heads/<branch> is used. What a push carries is decided
# from what origin says it has (ls-remote). Each commit is read whole (cat-file), on its own:
# author, committer, any other header and the message.
run_push() {
    nargs $# 2; no_options "$@"
    local slug="$1" branch="$2" b local_sha heads remote_sha sha ref nots=() raw ids listed
    gitctl_slug_ok "$slug" || die "$GITCTL_REASON"
    gitctl_branch_ok "$REAL_GIT" "$branch" || die "$GITCTL_REASON"
    for b in $PROTECTED_BRANCHES; do
        [ "$branch" = "$b" ] && die "pushing to ${branch} directly is refused: it changes by pull request merges (gitctl pr-merge)"
    done
    enter_copy "$slug"
    # Origin's default branch, whatever its name (trunk, ...), changes only by merges too.
    [ -z "$ORIGIN_HEAD" ] || [ "$branch" != "$ORIGIN_HEAD" ] \
        || die "pushing to ${branch} directly is refused: it is origin's default branch, which changes by pull request merges (gitctl pr-merge)"
    # Deleted when the verb ends, whatever the outcome (RUN_BUNDLE is global: the trap runs
    # after this function has returned).
    RUN_BUNDLE=$(mktemp ./incoming.XXXXXX) || die "cannot save the bundle"
    # The bundle's branch is held under a ref of this push's own (its bundle's unique name), so
    # two pushes of one repo never set or delete each other's.
    RUN_REF="refs/incoming/${RUN_BUNDLE##*/}"
    trap 'rm -f "$RUN_BUNDLE"; g update-ref -d "$RUN_REF" >/dev/null 2>&1' EXIT
    # A push that was killed leaves its ref; its bundle is gone (or swept), so drop it. A push
    # still running has its bundle file, made before its ref.
    while IFS= read -r ref; do
        [ -e "./${ref#refs/incoming/}" ] || g update-ref -d "$ref" >/dev/null 2>&1 || true
    done < <(g for-each-ref --format='%(refname)' refs/incoming/)
    # Bounded: the store is a fixed-size claim every repo's copy shares, and stdin is the
    # agent's to fill. One byte past the limit is enough to know it is too big.
    head -c "$((MAX_BUNDLE_BYTES + 1))" > "$RUN_BUNDLE" || die "cannot save the bundle"
    [ "$(stat -c %s -- "$RUN_BUNDLE")" -le "$MAX_BUNDLE_BYTES" ] \
        || die "the bundle is larger than $((MAX_BUNDLE_BYTES / 1024 / 1024)) MiB: push a smaller branch"
    g bundle verify -q "$RUN_BUNDLE" >/dev/null 2>&1 \
        || die "the bundle is not one this copy can take (its base is not on origin: gitctl fetch, merge, then push)"
    listed=$(g bundle unbundle "$RUN_BUNDLE" </dev/null) || die "cannot unbundle it"
    local_sha=$(printf '%s\n' "$listed" | awk -v r="refs/heads/${branch}" '$2 == r { print $1; exit }')
    [ -n "$local_sha" ] || die "the bundle has no branch ${branch}"
    g update-ref "$RUN_REF" "$local_sha" 2>/dev/null || die "the bundle's ${branch} is not a commit"
    local_sha=$(g rev-parse -q --verify "${RUN_REF}^{commit}") || die "the bundle's ${branch} is not a commit"
    heads=$(g ls-remote --heads "$ORIGIN_URL") || die "origin did not answer"
    remote_sha=""
    while read -r sha ref; do
        [ -n "$sha" ] || continue
        [ "$ref" = "refs/heads/${branch}" ] && remote_sha="$sha"
        g cat-file -e "${sha}^{commit}" 2>/dev/null && nots+=("^${sha}")
    done <<<"$heads"
    if [ -n "$remote_sha" ]; then
        g cat-file -e "${remote_sha}^{commit}" 2>/dev/null \
            || die "origin's ${branch} has commits the private copy lacks: try again"
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
    g push --no-recurse-submodules --no-follow-tags "$ORIGIN_URL" "${local_sha}:refs/heads/${branch}" \
        || die "the push of ${branch} failed"
    # The one line a caller reads back (a session's request result, which sets its upstream).
    echo "pushed ${branch} ${local_sha}"
}

# delete-branch: delete a branch on GitHub after its pull request merged (gitctl tidy). Only a
# branch whose tip, as origin has it now, is already in origin's default branch or in main,
# master or develop: nothing is lost. Never those branches themselves. The delete is leased on
# the tip that was checked, so a branch someone moved since is left alone.
run_delete_branch() {
    nargs $# 2; no_options "$@"
    local slug="$1" branch="$2" sha def b into=""
    gitctl_slug_ok "$slug" || die "$GITCTL_REASON"
    gitctl_branch_ok "$REAL_GIT" "$branch" || die "$GITCTL_REASON"
    for b in $PROTECTED_BRANCHES; do
        [ "$branch" = "$b" ] && die "${branch} is never deleted"
    done
    enter_copy "$slug"
    sha=$(g rev-parse -q --verify "refs/heads/${branch}^{commit}") || { echo "gone ${branch}"; return 0; }
    def=$(g symbolic-ref -q --short HEAD 2>/dev/null || true)
    [ "$branch" != "$def" ] || die "${branch} is origin's default branch: never deleted"
    for b in $def $PROTECTED_BRANCHES; do
        [ "$b" != "$branch" ] || continue
        g rev-parse -q --verify "refs/heads/${b}^{commit}" >/dev/null || continue
        if g merge-base --is-ancestor "$sha" "refs/heads/${b}"; then into="$b"; break; fi
    done
    [ -n "$into" ] || die "${branch} is not merged on GitHub (into ${def:-the default branch}, main, master or develop): not deleted"
    g push --no-recurse-submodules --no-follow-tags "--force-with-lease=refs/heads/${branch}:${sha}" \
        "$ORIGIN_URL" ":refs/heads/${branch}" || die "the delete of ${branch} failed (moved on GitHub since?)"
    echo "deleted ${branch} ${into}"
}

# storage: the bytes gitrun's store holds (its private copies, and any bundle being imported).
run_storage() {
    nargs $# 0
    { [ -n "$RUN_STORE" ] && [ -d "$RUN_STORE" ]; } || die "no private store for gitrun"
    du -sb -- "$RUN_STORE" 2>/dev/null | awk '{ print $1 }'
}

# remove-copy: delete gitrun's private copy of one repo (aidc repo remove). Fixed argv: the
# owner/name, nothing else; the copy is found inside gitrun's own store only.
run_remove_copy() {
    nargs $# 1; no_options "$@"
    gitctl_slug_ok "$1" || die "$GITCTL_REASON"
    local slug="${1,,}" store
    cd -P -- "$RUN_STORE" 2>/dev/null || die "${RUN_STORE}: gitrun's store is missing"
    store=$(pwd -P)
    [ "$(stat -c %u .)" = "$(id -u)" ] || die "${RUN_STORE} is not gitrun's"
    if [ ! -e "${slug}.git" ]; then echo "no private copy of ${1}"; return 0; fi
    { cd -P -- "${slug}.git" && [ "$(pwd -P)" = "${store}/${slug}.git" ]; } || die "cannot enter the copy of ${1}"
    { cd -P .. && rm -rf -- "${slug#*/}.git"; } || die "cannot remove the copy of ${1}"
    echo "removed the private copy of ${1}"
}

# has-copy: whether gitrun holds a private copy of the repo, i.e. the user added it (aidc repo
# add). Read only; makes nothing.
run_has_copy() {
    nargs $# 1; no_options "$@"
    gitctl_slug_ok "$1" || die "$GITCTL_REASON"
    local slug="${1,,}"
    cd -P -- "$RUN_STORE" 2>/dev/null || die "${RUN_STORE}: gitrun's store is missing"
    [ "$(stat -c %u .)" = "$(id -u)" ] || die "${RUN_STORE} is not gitrun's"
    [ -d "${slug}.git" ] || die "${1} is not one of the user's repos (the user adds it: aidc repo add ${1})"
    echo yes
}

# The largest bundle gitrun takes for a push (2 GiB): far beyond a branch's worth of commits,
# well inside the store. A checkout (the unit tests) may set a smaller one.
MAX_BUNDLE_BYTES=$((2 * 1024 * 1024 * 1024))
if [ "$INSTALLED" = 0 ] && [ -n "${AIDC_GITCTL_MAX_BUNDLE_BYTES:-}" ]; then MAX_BUNDLE_BYTES="$AIDC_GITCTL_MAX_BUNDLE_BYTES"; fi

# A bundle older than this many minutes is a leftover (a verb that was killed): swept at the
# start of every verb, so none piles up.
BUNDLE_MAX_AGE_MIN=60

sweep_store() {
    [ -n "$RUN_STORE" ] && [ -d "$RUN_STORE" ] || return 0
    find "$RUN_STORE" -mindepth 3 -maxdepth 3 -type f -name 'incoming.*' -mmin +"$BUNDLE_MAX_AGE_MIN" -delete 2>/dev/null || true
}

# --- gitcred: gh with the login --------------------------------------------------------------

gh_() {
    (cd / && env -i HOME="$CRED_HOME" GH_CONFIG_DIR="$CRED_HOME/gh" PATH=/usr/bin:/bin LANG=C.UTF-8 \
        ${GITCTL_PROXY:+"HTTPS_PROXY=$GITCTL_PROXY"} TERM="${TERM:-dumb}" GH_PROMPT_DISABLED=1 GH_PAGER=cat GH_NO_UPDATE_NOTIFIER=1 \
        GH_SPINNER_DISABLED=1 GH_BROWSER=echo BROWSER=echo NO_COLOR=1 "$REAL_GH" "$@")
}

# Texts reach gitcred only on stdin: as gitcred, a file named by the caller could be the token.
# Format: the title on the first line (pr-create), the body after it.
read_texts() {
    TITLE="" BODY=""
    if [ "$1" = titled ]; then IFS= read -r TITLE || true; fi
    BODY=$(cat)
}

# The fields gitctl reads a pull request with: what a session's gh stand-in answers from.
PR_FIELDS=number,title,body,state,url,headRefName,headRefOid,baseRefName,isDraft,mergedAt,reviewDecision,statusCheckRollup

# write_identity: after a login, the author and committer every commit in the git container
# carries (/etc/gitconfig includes the file): the user's GitHub name and an email GitHub ties to
# their account. The public email when the account shows one (it is already public); otherwise
# GitHub's noreply address for the account (<id>+<login>@users.noreply.github.com), which
# GitHub attributes to the user and never exposes a private one. No signing.
write_identity() {
    local user login id name pub email tmp
    user=$(gh_ api user) || die "logged in, but GitHub did not say who you are (gh api user); run gitctl login again"
    login=$(printf '%s' "$user" | jq -r '.login // ""') || die "cannot read your GitHub account"
    id=$(printf '%s' "$user" | jq -r '.id // ""')
    name=$(printf '%s' "$user" | jq -r '.name // ""' | LC_ALL=C tr -d '\000-\037\177')
    pub=$(printf '%s' "$user" | jq -r '.email // ""')
    [[ "$login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || die "GitHub gave an account name that is not one (${login:0:40})"
    [[ "$id" =~ ^[0-9]{1,15}$ ]] || die "GitHub gave an account id that is not one"
    [ -n "$name" ] || name="$login"
    local email_re='^[^[:space:][:cntrl:]<>@"]+@[^[:space:][:cntrl:]<>@"]+$'
    if [[ "$pub" =~ $email_re ]]; then email="$pub"
    else email="${id}+${login}@users.noreply.github.com"; fi
    tmp=$(mktemp "$CRED_HOME/.git-identity.XXXXXX") || die "cannot write the identity"
    if ! { env -i PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME="$CRED_HOME" \
            "$REAL_GIT" config --file "$tmp" user.name "$name" \
        && env -i PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME="$CRED_HOME" \
            "$REAL_GIT" config --file "$tmp" user.email "$email" \
        && chmod 0644 -- "$tmp" && mv -f -- "$tmp" "$CRED_HOME/git-identity"; }; then
        rm -f -- "$tmp"; die "cannot write the identity"
    fi
    echo "commits made here show as: ${name} <${email}>"
}

# read_protection OWNER/NAME: what GitHub enforces on the repo's default branch, in P_* (each
# blocked, allowed or unknown; merge methods allowed, disallowed or unknown). Rulesets and
# classic branch protection both count. Read-only.
read_protection() {
    local repo rules out
    P_DEFAULT="" P_FORCE=unknown P_DELETE=unknown P_MERGE=unknown P_SQUASH=unknown P_REBASE=unknown
    repo=$(gh_ api "repos/${1}" 2>/dev/null) || die "cannot read ${1} on GitHub (is gitctl logged in? gitctl status)"
    P_DEFAULT=$(printf '%s' "$repo" | jq -r '.default_branch // ""')
    gitctl_branch_ok "$REAL_GIT" "$P_DEFAULT" || die "GitHub gave a default branch that is not one"
    tri() { case "$1" in true) echo allowed ;; false) echo disallowed ;; *) echo unknown ;; esac; }
    P_MERGE=$(tri "$(printf '%s' "$repo" | jq -r '.allow_merge_commit')")
    P_SQUASH=$(tri "$(printf '%s' "$repo" | jq -r '.allow_squash_merge')")
    P_REBASE=$(tri "$(printf '%s' "$repo" | jq -r '.allow_rebase_merge')")
    local f_rule=unknown d_rule=unknown f_classic=unknown d_classic=unknown
    if rules=$(gh_ api "repos/${1}/rules/branches/${P_DEFAULT}" 2>/dev/null); then
        f_rule=no d_rule=no
        printf '%s' "$rules" | jq -e 'any(.[]?; .type == "non_fast_forward")' >/dev/null && f_rule=yes
        printf '%s' "$rules" | jq -e 'any(.[]?; .type == "deletion")' >/dev/null && d_rule=yes
    fi
    if out=$(gh_ api "repos/${1}/branches/${P_DEFAULT}/protection" 2>&1); then
        # Classic protection blocks force pushes and deletion unless it allows them.
        f_classic=yes d_classic=yes
        [ "$(printf '%s' "$out" | jq -r '.allow_force_pushes.enabled // false')" = true ] && f_classic=no
        [ "$(printf '%s' "$out" | jq -r '.allow_deletions.enabled // false')" = true ] && d_classic=no
    else
        case "$out" in *"Branch not protected"*) f_classic=no d_classic=no ;; esac
    fi
    both() { if [ "$1" = yes ] || [ "$2" = yes ]; then echo blocked; elif [ "$1" = no ] && [ "$2" = no ]; then echo allowed; else echo unknown; fi; }
    P_FORCE=$(both "$f_rule" "$f_classic")
    P_DELETE=$(both "$d_rule" "$d_classic")
}

print_protection() {
    printf 'repo %s\ndefault %s\nforce-push %s\ndeletion %s\nmerge-commit %s\nsquash %s\nrebase %s\nend\n' \
        "$1" "$P_DEFAULT" "$P_FORCE" "$P_DELETE" "$P_MERGE" "$P_SQUASH" "$P_REBASE"
}

# apply_protection OWNER/NAME: turn protections on, never off. A new ruleset that blocks force
# pushes and deletion of the default branch and of main, master and develop (a ruleset adds to
# whatever else protects the branch; changing classic protection would mean rewriting all of
# it), and merge commits allowed when they are not (gitctl merges only that way). Nothing
# here can turn any setting off: the body is fixed, and squash and rebase merges are left as
# they are.
apply_protection() {
    if [ "$P_FORCE" != blocked ] || [ "$P_DELETE" != blocked ]; then
        printf '%s' '{"name":"aidc: no force pushes or deletion","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH","refs/heads/main","refs/heads/master","refs/heads/develop"],"exclude":[]}},"rules":[{"type":"non_fast_forward"},{"type":"deletion"}]}' \
            | gh_ api --method POST "repos/${1}/rulesets" --input - >/dev/null \
            || die "GitHub refused the ruleset (it needs admin rights on ${1}; private repos need a paid plan for rulesets)"
        echo "added a ruleset: no force pushes or deletion of ${P_DEFAULT}, main, master, develop" >&2
    fi
    if [ "$P_MERGE" = disallowed ]; then
        gh_ api --method PATCH "repos/${1}" -F allow_merge_commit=true >/dev/null \
            || die "GitHub refused to allow merge commits on ${1}"
        echo "allowed merge commits" >&2
    fi
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
            # Device code: gh prints a one-time code and the address to enter it at; the user
            # approves in their own browser. git gets the token from gh (https), never a key.
            (cd / && env -i HOME="$CRED_HOME" GH_CONFIG_DIR="$CRED_HOME/gh" PATH=/usr/bin:/bin LANG=C.UTF-8 \
                ${GITCTL_PROXY:+"HTTPS_PROXY=$GITCTL_PROXY"} TERM="${TERM:-dumb}" GH_PAGER=cat GH_NO_UPDATE_NOTIFIER=1 GH_BROWSER=echo BROWSER=echo \
                "$REAL_GH" auth login --hostname github.com --git-protocol https --web --skip-ssh-key) \
                || die "the GitHub login did not complete"
            write_identity ;;
        logout)
            nargs $# 0
            # The identity goes with the login: commits made after a logout are not the user's.
            rm -f -- "$CRED_HOME/git-identity"
            gh_ auth logout --hostname github.com ;;
        pr-list)
            nargs $# 1; gitctl_slug_ok "$1" || die "$GITCTL_REASON"
            gh_ pr list --repo "$1" ;;
        pr-view)
            nargs $# 2; gitctl_slug_ok "$1" || die "$GITCTL_REASON"; gitctl_number_ok "$2" || die "$GITCTL_REASON"
            gh_ pr view "$2" --repo "$1" ;;
        pr-view-json)
            # One PR, by number or by its head branch, as JSON with a fixed set of fields.
            nargs $# 2; gitctl_slug_ok "$1" || die "$GITCTL_REASON"
            gitctl_number_ok "$2" || gitctl_branch_ok "$REAL_GIT" "$2" || die "${2}: not a pull request number or branch"
            gh_ pr view "$2" --repo "$1" --json "$PR_FIELDS" ;;
        pr-list-json)
            # pr-list-json <repo> <state> [<head branch>]: up to 100 PRs, as JSON.
            [ $# = 2 ] || [ $# = 3 ] || die "pr-list-json takes 2 or 3 arguments"
            no_options "$@"
            gitctl_slug_ok "$1" || die "$GITCTL_REASON"
            case "$2" in open|closed|merged|all) ;; *) die "${2}: not a pull request state (open, closed, merged, all)" ;; esac
            if [ $# = 3 ]; then
                gitctl_branch_ok "$REAL_GIT" "$3" || die "$GITCTL_REASON"
                gh_ pr list --repo "$1" --state "$2" --head "$3" --limit 100 --json "$PR_FIELDS"
            else
                gh_ pr list --repo "$1" --state "$2" --limit 100 --json "$PR_FIELDS"
            fi ;;
        protection)
            nargs $# 1; gitctl_slug_ok "$1" || die "$GITCTL_REASON"
            read_protection "$1"
            print_protection "$1" ;;
        protect)
            nargs $# 1; gitctl_slug_ok "$1" || die "$GITCTL_REASON"
            read_protection "$1"
            apply_protection "$1"
            read_protection "$1"
            print_protection "$1" ;;
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

# as_run VERB ARGS...: the gitrun side of a verb, returning here (stdin and stdout passed on).
as_run() {
    if [ "$INSTALLED" = 1 ]; then sudo -n -u gitrun -- "$self" "$@"; return; fi
    AIDC_GITCTL_ROLE=run bash "$self" "$@"
}

# The agent's own git in a working copy: gitctl_agent_git (gitctl-rules.sh), shared with the
# request watcher so both read working copies the same way.
ag() { gitctl_agent_git "$REAL_GIT" "$@"; }

# The agent's bundles, in its own folder; each is deleted when the verb ends, whatever the
# outcome, and any older than BUNDLE_MAX_AGE_MIN (a verb that was killed) at the next verb.
if [ "$INSTALLED" = 1 ]; then BUNDLE_DIR="${HOME:-/home/git}/.cache/gitctl"
else BUNDLE_DIR="${AIDC_GITCTL_BUNDLE_DIR:-${TMPDIR:-/tmp}/gitctl-bundles-$(id -u)}"; fi
BUNDLE=""
new_bundle() {
    { mkdir -p -- "$BUNDLE_DIR" && chmod 0700 -- "$BUNDLE_DIR"; } || die "cannot make ${BUNDLE_DIR}"
    find "$BUNDLE_DIR" -maxdepth 1 -type f -name '*.bundle' -mmin +"$BUNDLE_MAX_AGE_MIN" -delete 2>/dev/null || true
    BUNDLE=$(mktemp "${BUNDLE_DIR}/XXXXXXXX.bundle") || die "cannot make a bundle file"
    trap 'rm -f "$BUNDLE"' EXIT
}

# The repo's slug, read as the agent from the working copy's origin, once: every later step of
# the verb uses this value. It must be the repo the caller expects (--expect-repo, what the user
# approved), and one the user added: GitHub is reached for no other repo, reads included.
agent_slug() {
    local url
    url=$(ag -C "$1" remote get-url origin 2>/dev/null) || die "${1}: no origin remote"
    url_slug "$url" || die "$GITCTL_REASON"
    SLUG="$GITCTL_SLUG"
    if [ -n "$EXPECT_SLUG" ] && [ "${SLUG,,}" != "${EXPECT_SLUG,,}" ]; then
        die "${1}'s origin is now ${SLUG}, not ${EXPECT_SLUG} as approved: nothing done"
    fi
    as_run has-copy "$SLUG" >/dev/null || exit 1
}

# working_copy PATH: the working copy (or worktree) at PATH, in WC.
working_copy() {
    WC=$(realpath -e -- "$1" 2>/dev/null) || die "${1}: no such folder"
    ag -C "$WC" rev-parse --git-dir >/dev/null 2>&1 || die "${WC}: not a git working copy"
}

# import_bundle WC: origin's branches from $BUNDLE into WC's refs/remotes/origin/*, pruning the
# ones origin no longer has. Unbundled (no transport), then the refs set in one transaction.
import_bundle() {
    local wc="$1" listed sha ref have
    listed=$(ag -C "$wc" bundle unbundle "$BUNDLE" </dev/null) || die "cannot import the bundle"
    rm -f "$BUNDLE"
    {
        while read -r sha ref; do
            case "$ref" in refs/heads/*) printf 'update refs/remotes/origin/%s %s\n' "${ref#refs/heads/}" "$sha" ;; esac
        done <<<"$listed"
        while read -r have; do
            [ "$have" = refs/remotes/origin/HEAD ] && continue
            printf '%s\n' "$listed" | awk -v r="refs/heads/${have#refs/remotes/origin/}" '$2 == r { f = 1 } END { exit !f }' \
                || printf 'delete %s\n' "$have"
        done < <(ag -C "$wc" for-each-ref --format='%(refname)' refs/remotes/origin/)
    } | ag -C "$wc" update-ref --stdin || die "cannot update ${wc}'s origin branches"
    LISTED="$listed"
}

# clone_path_ok PATH: an absolute path of plain names (letters, digits, . _ -), none of them
# . or ..; installed, on the user's disk.
clone_path_ok() {
    local p="$1" c parts
    [[ "$p" =~ ^(/[A-Za-z0-9._-]+)+$ ]] \
        || { gitctl_refuse "${p}: not an absolute path of letters, digits, '.', '_' and '-'"; return 1; }
    IFS=/ read -ra parts <<<"${p#/}"
    for c in "${parts[@]}"; do
        case "$c" in .|..) gitctl_refuse "${p}: no . or .. in the path"; return 1 ;; esac
    done
    if [ "$INSTALLED" = 1 ]; then
        if [[ ! "$p" =~ ^/home/[a-z0-9]([a-z0-9-]*[a-z0-9])?/ ]] || [[ "$p" =~ ^/home/(git|gitrun)/ ]]; then
            gitctl_refuse "${p}: not on the user's disk (/home/<user>/...)"; return 1
        fi
    fi
}

# clone: a new, ordinary working copy at PATH (an empty folder the agent can write) from the
# bundle gitrun makes. Group-shared (umask 002, core.sharedRepository=group), so sessions and
# the agent can both work in it; origin is the GitHub URL, for the record (only gitctl reaches
# it). The default branch is the one origin's HEAD points at (main or master first when two
# branches share its commit).
agent_clone() {
    nargs $# 2; no_options "$@"
    local slug="$1" path="$2" head def sha ref
    [ "$ON_DOCKER" != 1 ] || die "on Docker the git container works on your own working copies: clone it yourself, then aidc repo add <path>"
    gitctl_slug_ok "$slug" || die "$GITCTL_REASON"
    clone_path_ok "$path" || die "$GITCTL_REASON"
    cd -P -- "$path" 2>/dev/null || die "${path}: no such folder (aidc repo add makes it)"
    [ "$(pwd -P)" = "$path" ] || die "${path}: a symlink on the way (it is $(pwd -P))"
    [ -z "$(ls -A .)" ] || die "${path} is not empty"
    [ -w . ] || die "${path}: the git container cannot write it"
    new_bundle
    as_run add-copy "$slug" > "$BUNDLE" || exit 1
    umask 002
    # --shared=group: every folder in .git setgid from the start, so what either side writes
    # later stays the session group's.
    { ag init -q --template= --shared=group . \
        && ag config remote.origin.url "$(forge_url "$slug")" \
        && ag config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; } || die "cannot make the working copy"
    head=$(ag bundle list-heads "$BUNDLE" | awk '$2 == "HEAD" { print $1 }')
    import_bundle .
    def=""
    while read -r sha ref; do
        [ "$sha" = "$head" ] || continue
        case "$ref" in refs/heads/main|refs/heads/master) def="${ref#refs/heads/}"; break ;;
            refs/heads/*) [ -n "$def" ] || def="${ref#refs/heads/}" ;; esac
    done <<<"$LISTED"
    [ -n "$def" ] || def=$(printf '%s\n' "$LISTED" | awk '$2 ~ /^refs\/heads\// { sub("refs/heads/", "", $2); print $2; exit }')
    { ag update-ref "refs/heads/${def}" "refs/remotes/origin/${def}" \
        && ag symbolic-ref HEAD "refs/heads/${def}" \
        && ag symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/${def}" \
        && ag config "branch.${def}.remote" origin && ag config "branch.${def}.merge" "refs/heads/${def}" \
        && ag reset -q --hard; } || die "cannot check out ${def}"
    echo "cloned $(forge_url "$slug") into ${path} (${def})"
}

# adopt: an existing working copy (on Docker, the user's own) becomes one of the user's repos:
# gitrun makes its private copy of origin's repo, which every other verb then requires. The
# working copy is only read (its origin), never changed.
agent_adopt() {
    nargs $# 1; no_options "$@"
    local url
    working_copy "$1"
    url=$(ag -C "$WC" remote get-url origin 2>/dev/null) || die "${WC}: no origin remote"
    url_slug "$url" || die "$GITCTL_REASON"
    SLUG="$GITCTL_SLUG"
    as_run add-copy "$SLUG" >/dev/null || exit 1
    echo "added ${SLUG} (${WC})"
}

agent_fetch() {
    nargs $# 1; no_options "$@"
    working_copy "$1"; agent_slug "$WC"
    new_bundle
    as_run fetch "$SLUG" > "$BUNDLE" || exit 1
    import_bundle "$WC"
}

# unpushed: after a fetch, the work in a working copy (and its worktrees) that a delete would
# lose, one line each, then "end" (a report without it is no report):
#   branch <n> <name>       a local branch with n commits on no origin branch
#   detached <n> <path>     a worktree on a detached HEAD with n such commits
#   uncommitted <path>      a worktree with changes not committed (untracked files count)
#   stash <n>               n stashed changes
#   worktree <path>         each worktree besides the working copy itself
#   not-fetched             gitrun holds no copy of the repo any more (aidc repo remove took it,
#                           and the delete of the working copy is being run again): compared
#                           with origin's branches as the working copy last fetched them
# Read with the agent's own git (no login). Submodules are not entered (their config would be
# read), no lock is taken, and a worktree whose folder is gone (prunable) holds nothing. Any
# step that fails ends the verb with an error: "cannot tell" is never "nothing unpushed".
# Only a repo the user added is fetched; one whose copy is gone is still reported, from what the
# working copy already has, so a retried `aidc repo remove --delete-working-copy` (its first run
# removed the copy, then stopped) is checked again rather than refused.
agent_unpushed() {
    nargs $# 1; no_options "$@"
    local wt line n b rows=() list url has
    working_copy "$1"
    url=$(ag -C "$WC" remote get-url origin 2>/dev/null) || die "${WC}: no origin remote"
    url_slug "$url" || die "$GITCTL_REASON"
    SLUG="$GITCTL_SLUG"
    if [ -n "$EXPECT_SLUG" ] && [ "${SLUG,,}" != "${EXPECT_SLUG,,}" ]; then
        die "${WC}'s origin is now ${SLUG}, not ${EXPECT_SLUG} as approved: nothing done"
    fi
    if has=$(as_run has-copy "$SLUG" 2>&1 </dev/null); then
        new_bundle
        as_run fetch "$SLUG" > "$BUNDLE" || exit 1
        import_bundle "$WC"
    else
        # Only "not one of the user's repos" means no copy; any other failure is no answer.
        case "$has" in *"is not one of the user's repos"*) rows+=("not-fetched") ;; *) die "${has#gitctl: refused: }" ;; esac
    fi
    list=$(ag -C "$WC" for-each-ref --format='%(refname)' refs/heads/) || die "cannot list ${WC}'s branches"
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        n=$(ag -C "$WC" rev-list --count "$b" --not --remotes=origin --) || die "cannot read ${b}"
        [ "$n" = 0 ] || rows+=("branch ${n} ${b#refs/heads/}")
    done <<<"$list"
    list=$(ag -C "$WC" worktree list --porcelain) || die "cannot list ${WC}'s worktrees"
    # One block per worktree, the main one first, each ended by an empty line.
    local wts=() heads=() dets=() gone=() i j rel ex
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) wts+=("${line#worktree }"); heads+=(""); dets+=(0); gone+=(0) ;;
            "HEAD "*) heads[-1]="${line#HEAD }" ;;
            detached) dets[-1]=1 ;;
            prunable*) gone[-1]=1 ;;
        esac
    done <<<"$list"
    for i in "${!wts[@]}"; do
        wt="${wts[$i]}"
        [ "$i" = 0 ] || rows+=("worktree ${wt}")
        [ "${gone[$i]}" = 0 ] || continue
        if [ "${dets[$i]}" = 1 ]; then
            n=$(ag -C "$wt" rev-list --count "${heads[$i]}" --not --remotes=origin --) || die "cannot read ${wt}'s HEAD"
            [ "$n" = 0 ] || rows+=("detached ${n} ${wt}")
        fi
        # A worktree inside this one is its own: it shows here as an untracked folder.
        ex=()
        for j in "${!wts[@]}"; do
            rel="${wts[$j]#"$wt"/}"
            [ "$j" != "$i" ] && [ "$rel" != "${wts[$j]}" ] && ex+=(":(exclude,literal)${rel}")
        done
        n=$(ag -C "$wt" --no-optional-locks status --porcelain --ignore-submodules=all -- . "${ex[@]}") \
            || die "cannot read ${wt}'s changes"
        [ -z "$n" ] || rows+=("uncommitted ${wt}")
    done
    if ag -C "$WC" rev-parse -q --verify refs/stash >/dev/null; then
        n=$(ag -C "$WC" rev-list --walk-reflogs --count refs/stash) || die "cannot read the stashes"
        rows+=("stash ${n}")
    fi
    [ ${#rows[@]} -eq 0 ] || printf '%s\n' "${rows[@]}"
    echo end
}

# tidy: after merges, the working copy's merged work goes and everything else is reported. One
# line each, then "end" (a report without it is no report):
#   deleted-remote <branch>            deleted on GitHub (delete-branch: merged there)
#   deleted-branch <branch>            the local branch, merged into a base on origin
#   removed-worktree <path>            a clean worktree of a merged branch, with its admin folder
#   pruned <name>                      a worktree admin folder whose worktree is gone
#   kept-remote <branch> <why>         a merged branch GitHub would not delete
#   unpushed <n> <branch>              a local branch with n commits on no origin branch
#   unmerged <branch>                  pushed, not merged yet
#   uncommitted <path>                 a merged branch's worktree with changes (kept)
#   checked-out <branch> <path>        a merged branch the working copy itself has checked out
#   detached <path>                    a worktree on a detached HEAD (kept)
#   locked <path>                      a locked worktree (kept)
#   orphaned <path>                    a folder that was a worktree, whose admin folder is gone
#   cannot-delete <path> <why>         what the agent may not delete (a folder only a session
#                                      can write: its umask was not 002), or a worktree record
#                                      naming a folder tidy never removes (outside the user's
#                                      disk, reached through a symlink, the git container's
#                                      request folder, or one holding the working copy)
# Bases are origin's default branch and main, master and develop where origin has them. Only
# branches that exist in this working copy are deleted on GitHub: a colleague's branch is not
# this working copy's to tidy. Runs as the agent (in the session group); gitrun only deletes on
# GitHub.
agent_tidy() {
    nargs $# 1; no_options "$@"
    local line b tip n i wt base bases=() rows=() into rel j ex dirty why
    working_copy "$1"; agent_slug "$WC"
    new_bundle
    as_run fetch "$SLUG" > "$BUNDLE" || exit 1
    import_bundle "$WC"
    base=$(ag -C "$WC" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
    for b in "${base#origin/}" $PROTECTED_BRANCHES; do
        [ -n "$b" ] || continue
        ag -C "$WC" rev-parse -q --verify "refs/remotes/origin/${b}^{commit}" >/dev/null || continue
        case " ${bases[*]} " in *" $b "*) ;; *) bases+=("$b") ;; esac
    done
    [ ${#bases[@]} -gt 0 ] || die "origin has no default branch, main, master or develop to tidy against"
    # A worktree's path comes from its admin folder, which sessions write: tidy removes one only
    # where it resolves, with no symlink on the way, inside the user's disk (/home/<user>; run
    # from a checkout, AIDC_GITCTL_DISK_ROOT or the working copy's parent), and never the git
    # container's folder there (.aidc: the request folder) nor a folder holding the working copy.
    local area=""
    if [ "$ON_DOCKER" = 1 ]; then
        # On Docker only the repos the user added are mounted here: a worktree is removed only
        # inside its working copy (set below, from the worktree list).
        area=docker
    elif [ "$INSTALLED" = 1 ]; then
        [[ "$WC" =~ ^(/home/[a-z0-9]([a-z0-9-]*[a-z0-9])?)/ ]] && area="${BASH_REMATCH[1]}"
        case "$area" in /home/git|/home/gitrun) area="" ;; esac
    else
        area=$(realpath -e -- "${AIDC_GITCTL_DISK_ROOT:-${WC%/*}}" 2>/dev/null || true)
    fi
    removable() { # PATH
        local r
        [ -n "$area" ] || return 1
        r=$(realpath -e -- "$1" 2>/dev/null) || return 1
        [ "$r" = "$1" ] || return 1
        case "$r/" in "$area"/?*) ;; *) return 1 ;; esac
        case "$r/" in "$area/.aidc/"*) return 1 ;; esac
        case "$WC/" in "$r/"*) return 1 ;; esac
        case "${wts[0]}/" in "$r/"*) return 1 ;; esac
        return 0
    }
    merged_into() { # SHA: the first base that holds it, in INTO
        local x
        INTO=""
        for x in "${bases[@]}"; do
            if ag -C "$WC" merge-base --is-ancestor "$1" "refs/remotes/origin/${x}" 2>/dev/null; then INTO="$x"; return 0; fi
        done
        return 1
    }
    # The worktrees, the working copy first.
    local wts=() wbr=() wdet=() wgone=() wlock=()
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) wts+=("${line#worktree }"); wbr+=(""); wdet+=(0); wgone+=(0); wlock+=(0) ;;
            "branch refs/heads/"*) wbr[-1]="${line#branch refs/heads/}" ;;
            detached) wdet[-1]=1 ;;
            prunable*) wgone[-1]=1 ;;
            locked*) wlock[-1]=1 ;;
        esac
    done < <(ag -C "$WC" worktree list --porcelain) || die "cannot list ${WC}'s worktrees"
    [ ${#wts[@]} -gt 0 ] || die "cannot list ${WC}'s worktrees"
    # On Docker a worktree recorded outside the working copy is one the git container does not
    # see (only the working copy is mounted), not one that is gone: it is never pruned and its
    # branch is kept, and it is named as a leftover. Pruning is skipped while there is one, as
    # git's prune would take its record too.
    local hidden=()
    if [ "$area" = docker ]; then
        area=$(realpath -e -- "${wts[0]}" 2>/dev/null || true)
        for i in "${!wts[@]}"; do
            hidden+=(0)
            [ "$i" != 0 ] || continue
            case "${wts[$i]}/" in "${area:-/nonexistent}"/?*) ;; *) hidden[i]=1; wgone[i]=0 ;; esac
        done
    fi
    while IFS= read -r -u 3 b; do
        [ -n "$b" ] || continue
        b="${b#refs/heads/}"
        case " ${bases[*]} $PROTECTED_BRANCHES " in *" $b "*) continue ;; esac
        tip=$(ag -C "$WC" rev-parse -q --verify "refs/heads/${b}^{commit}") || continue
        if ! merged_into "$tip"; then
            n=$(ag -C "$WC" rev-list --count "$tip" --not --remotes=origin --) || die "cannot read ${b}"
            if [ "$n" != 0 ]; then rows+=("unpushed ${n} ${b}"); else rows+=("unmerged ${b}"); fi
            continue
        fi
        into="$INTO"
        if ag -C "$WC" rev-parse -q --verify "refs/remotes/origin/${b}" >/dev/null; then
            if line=$(as_run delete-branch "$SLUG" "$b" 2>&1 </dev/null); then
                case "$line" in *"deleted ${b} "*|*"gone ${b}"*) rows+=("deleted-remote ${b}") ;; esac
            else
                rows+=("kept-remote ${b} $(printf '%s' "$line" | tail -n1 | sed 's/^gitctl: refused: //')")
            fi
        fi
        # The worktree that has it checked out, if any.
        wt="" i=""
        for j in "${!wts[@]}"; do
            [ "${wbr[$j]}" = "$b" ] && { wt="${wts[$j]}"; i="$j"; break; }
        done
        if [ -n "$wt" ]; then
            if [ "$i" = 0 ]; then rows+=("checked-out ${b} ${wt}"); continue; fi
            if [ "${hidden[$i]:-0}" = 1 ]; then
                rows+=("cannot-delete ${wt} not a folder tidy removes (outside the working copy, which is all the git container sees)")
                continue
            fi
            if [ "${wlock[$i]}" = 1 ]; then rows+=("locked ${wt}"); continue; fi
            if [ "${wgone[$i]}" = 0 ]; then
                if ! removable "$wt"; then
                    rows+=("cannot-delete ${wt} not a folder tidy removes (outside the user's disk, through a symlink, the git container's, or holding the working copy)")
                    continue
                fi
                ex=()
                for j in "${!wts[@]}"; do
                    rel="${wts[$j]#"$wt"/}"
                    [ "$j" != "$i" ] && [ "$rel" != "${wts[$j]}" ] && ex+=(":(exclude,literal)${rel}")
                done
                dirty=$(ag -C "$wt" --no-optional-locks status --porcelain --ignore-submodules=all -- . ${ex[@]+"${ex[@]}"}) \
                    || { rows+=("cannot-delete ${wt} its changes cannot be read"); continue; }
                if [ -n "$dirty" ]; then rows+=("uncommitted ${wt}"); continue; fi
                # Every folder in it must be one the agent may empty, or the remove would stop
                # half way: check first, delete nothing when one is not.
                why=$(find "$wt" -xdev -type d ! -writable -print -quit 2>/dev/null)
                if [ -n "$why" ]; then rows+=("cannot-delete ${wt} not writable by the git container: ${why}"); continue; fi
                if line=$(ag -C "$WC" worktree remove "$wt" 2>&1 </dev/null); then rows+=("removed-worktree ${wt}")
                else rows+=("cannot-delete ${wt} $(printf '%s' "$line" | tail -n1)"); continue; fi
            fi
        fi
        if ag -C "$WC" update-ref -d "refs/heads/${b}" "$tip" 2>/dev/null; then rows+=("deleted-branch ${b}")
        else rows+=("cannot-delete ${b} the branch moved or its ref cannot be written"); fi
    done 3< <(ag -C "$WC" for-each-ref --format='%(refname)' refs/heads/)
    for i in "${!wts[@]}"; do
        [ "$i" != 0 ] || continue
        [ "${wdet[$i]}" = 1 ] && [ "${wgone[$i]}" = 0 ] && rows+=("detached ${wts[$i]}")
    done
    case " ${hidden[*]} " in
        *" 1 "*) ;;
        *)
            while IFS= read -r line; do
                case "$line" in "Removing worktrees/"*) line="${line#Removing worktrees/}"; rows+=("pruned ${line%%:*}") ;; esac
            done < <(ag -C "$WC" worktree prune -v 2>&1) ;;
    esac
    # Folders inside the working copy that were worktrees: a .git file whose admin folder is gone.
    local gd main_git
    main_git=$(ag -C "$WC" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || main_git=""
    while IFS= read -r -d '' line; do
        { [ -f "$line" ] && [ ! -L "$line" ]; } || continue
        gd=$(timeout 5 head -c 4096 -- "$line" 2>/dev/null | sed -n '1s/^gitdir: //p')
        case "$gd" in "${main_git}/worktrees/"*) [ -d "$gd" ] || rows+=("orphaned ${line%/.git}") ;; esac
    done < <(find "$WC" -mindepth 2 -maxdepth 4 -name .git -type f -print0 2>/dev/null)
    [ ${#rows[@]} -eq 0 ] || printf '%s\n' "${rows[@]}"
    echo end
}

# push: the branch, bundled from the working copy (only what origin lacks, as far as the copy
# knows: the bundle's base must be in gitrun's copy or gitrun refuses it), handed to gitrun on
# stdin. gitrun decides; nothing here is trusted by it.
agent_push() {
    nargs $# 2; no_options "$@"
    local branch="$2" b
    gitctl_branch_ok "$REAL_GIT" "$branch" || die "$GITCTL_REASON"
    for b in $PROTECTED_BRANCHES; do
        [ "$branch" = "$b" ] && die "pushing to ${branch} directly is refused: it changes by pull request merges (gitctl pr-merge)"
    done
    working_copy "$1"; agent_slug "$WC"
    ag -C "$WC" rev-parse -q --verify "refs/heads/${branch}^{commit}" >/dev/null || die "no local branch ${branch}"
    new_bundle
    ag -C "$WC" bundle create -q "$BUNDLE" "refs/heads/${branch}" --not --remotes=origin 2>/dev/null \
        || ag -C "$WC" bundle create -q "$BUNDLE" "refs/heads/${branch}" --not "refs/heads/${branch}^@" 2>/dev/null \
        || ag -C "$WC" bundle create -q "$BUNDLE" "refs/heads/${branch}" 2>/dev/null \
        || die "cannot bundle ${branch}"
    # What gitrun pushes is the bundle's branch: checked here, after the bundle is made, so a
    # branch moved at any time before is caught.
    if [ -n "$EXPECT_SHA" ]; then
        b=$(ag -C "$WC" bundle list-heads "$BUNDLE" 2>/dev/null | awk -v r="refs/heads/${branch}" '$2 == r { print $1; exit }')
        [ "$b" = "$EXPECT_SHA" ] \
            || die "${branch} moved since it was approved (approved ${EXPECT_SHA:0:12}, now ${b:0:12}): nothing pushed; ask again"
    fi
    as_run push "$SLUG" "$branch" < "$BUNDLE"
}

# storage: what the git container keeps: gitrun's private copies and the agent's bundles.
agent_storage() {
    nargs $# 0
    local copies
    copies=$(as_run storage) || copies=unknown
    printf 'copies %s\n' "$copies"
    printf 'bundles %s\n' "$(du -sb -- "$BUNDLE_DIR" 2>/dev/null | awk '{ print $1 }' || true)"
}

# read_file F: a text file named by the agent, read as the agent; - is stdin.
read_file() {
    if [ "$1" = - ]; then cat; return; fi
    if [ ! -f "$1" ] || [ ! -r "$1" ]; then die "${1}: no such file"; fi
    cat -- "$1"
}

agent_side() {
    case "$verb" in
        clone) agent_clone "$@" ;;
        fetch) agent_fetch "$@" ;;
        push) agent_push "$@" ;;
        unpushed) agent_unpushed "$@" ;;
        storage) agent_storage "$@" ;;
        adopt) agent_adopt "$@" ;;
        remove-copy|has-copy) nargs $# 1; no_options "$@"; switch_to run "$verb" "$1" ;;
        add-copy) die "add-copy is gitrun's own step of gitctl clone (aidc repo add)" ;;
        status|login|logout) switch_to cred "$verb" "$@" ;;
        pr-list|protection|protect) nargs $# 1; agent_slug "$1"; switch_to cred "$verb" "$SLUG" ;;
        pr-view|pr-merge|pr-view-json) nargs $# 2; agent_slug "$1"; switch_to cred "$verb" "$SLUG" "$2" ;;
        pr-list-json)
            [ $# = 2 ] || [ $# = 3 ] || die "usage: gitctl pr-list-json <repo> <open|closed|merged|all> [<head>]"
            agent_slug "$1"; shift; switch_to cred "$verb" "$SLUG" "$@" ;;
        delete-branch)
            nargs $# 2; no_options "$@"
            gitctl_branch_ok "$REAL_GIT" "$2" || die "$GITCTL_REASON"
            agent_slug "$1"; switch_to run delete-branch "$SLUG" "$2" ;;
        tidy) agent_tidy "$@" ;;
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

# --expect-repo <owner/name> [--expect-commit <sha>], at the end of a verb on a working copy:
# what the caller (the request watcher) recorded and the user approved. Taken off here, checked
# against what the verb reads (agent_slug, agent_push); never passed on.
EXPECT_SLUG="" EXPECT_SHA=""
expect_args() {
    ARGS=("$@")
    while [ ${#ARGS[@]} -ge 2 ]; do
        case "${ARGS[-2]}" in
            --expect-repo) [ -z "$EXPECT_SLUG" ] || die "--expect-repo given twice"; EXPECT_SLUG="${ARGS[-1]}"
                gitctl_slug_ok "$EXPECT_SLUG" || die "$GITCTL_REASON" ;;
            --expect-commit) [ -z "$EXPECT_SHA" ] || die "--expect-commit given twice"; EXPECT_SHA="${ARGS[-1]}"
                [[ "$EXPECT_SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "${EXPECT_SHA}: not a full commit id" ;;
            *) break ;;
        esac
        unset 'ARGS[-1]'; unset 'ARGS[-1]'
    done
    if [ -n "$EXPECT_SLUG" ]; then
        case "$verb" in
            fetch|push|unpushed|tidy|delete-branch|pr-create|pr-comment|pr-merge|pr-view|pr-list|pr-view-json|pr-list-json|protection|protect) ;;
            *) die "${verb} takes no --expect-repo" ;;
        esac
    fi
    [ -z "$EXPECT_SHA" ] || [ "$verb" = push ] || die "only push takes --expect-commit"
}

case "$ROLE" in
    agent)
        # On Docker the verbs that write a working copy run as gitwc, its owner's uid (sudo: the
        # one rule naming gitctl; the caller's environment is dropped).
        if [ "$INSTALLED" = 1 ] && [ "$ON_DOCKER" = 1 ] && [ "$(id -un)" = git ]; then
            case "$verb" in fetch|tidy|unpushed) exec sudo -n -u gitwc -- "$self" "$verb" "$@" ;; esac
        fi
        expect_args "$@"; agent_side ${ARGS[@]+"${ARGS[@]}"} ;;
    run)
        sweep_store
        case "$verb" in
            fetch|add-copy) run_fetch "$@" ;; push) run_push "$@" ;; delete-branch) run_delete_branch "$@" ;;
            storage) run_storage "$@" ;; remove-copy) run_remove_copy "$@" ;; has-copy) run_has_copy "$@" ;;
            *) die "${verb} does not run as gitrun" ;;
        esac ;;
    cred)
        [ "$VERB_ROLE" = cred ] || die "${verb} does not run as gitcred"
        run_cred "$@" ;;
esac
