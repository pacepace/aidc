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
#   gitctl pr-create <repo> <head> <base> --title-file F --body-file F   (F may be -: stdin)
#   gitctl pr-comment <repo> <number> --body-file F
#   gitctl pr-merge <repo> <number>                      always a merge commit
#   gitctl pr-view <repo> <number> | pr-list <repo>
#   gitctl status | login | logout                       the GitHub login (gitcred's)
#   gitctl storage                                       bytes in gitrun's copies and the bundles
#   gitctl remove-copy <owner/name>                      delete gitrun's private copy of a repo
#
# <repo> is a working copy (or a worktree of one) whose origin is
# https://github.com/<owner>/<name>.
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
fi
ulimit -c 0 2>/dev/null || true

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
    clone|fetch|push|unpushed|storage|remove-copy) VERB_ROLE=run ;;
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
        -c http.proxy= -c http.sslVerify=true -c core.sshCommand= -c core.gitProxy= \
        -c core.askPass= -c push.followTags=false -c push.gpgSign=false \
        -c maintenance.auto=false "${helper[@]}" "$@"
}

# enter_copy OWNER/NAME: enter gitrun's private bare copy of the repo, making it when missing,
# and bring it up to date with origin's branches. The store is gitrun's and open to no one
# else (checked), so nothing in it was written by anyone but gitrun; each step down is entered
# with cd -P and checked with pwd -P. Sets ORIGIN_URL.
enter_copy() {
    local slug="${1,,}" owner name store head
    owner="${slug%/*}" name="${slug#*/}"
    [ -n "$RUN_STORE" ] || die "no private store for gitrun"
    cd -P -- "$RUN_STORE" 2>/dev/null || die "${RUN_STORE}: gitrun's store is missing"
    store=$(pwd -P)
    [ "$(stat -c %u .)" = "$(id -u)" ] || die "${RUN_STORE} is not gitrun's"
    (( 8#$(stat -c %a .) & 8#077 )) && die "${RUN_STORE} is open to others: gitrun keeps its copies where only it can go"
    umask 077
    { mkdir -p -- "$owner" && cd -P -- "$owner" && [ "$(pwd -P)" = "${store}/${owner}" ]; } \
        || die "${RUN_STORE}/${owner}: cannot enter it"
    if [ ! -e "${name}.git" ]; then
        env -i PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            "$REAL_GIT" init -q --bare --template= -- "${name}.git" || die "cannot make the private copy of ${1}"
    fi
    { cd -P -- "${name}.git" && [ "$(pwd -P)" = "${store}/${owner}/${name}.git" ]; } \
        || die "${RUN_STORE}/${owner}/${name}.git: cannot enter it"
    ORIGIN_URL=$(forge_url "$1")
    g fetch -q --prune --no-tags --no-recurse-submodules --no-write-fetch-head "$ORIGIN_URL" \
        '+refs/heads/*:refs/heads/*' || die "cannot fetch ${ORIGIN_URL}"
    # HEAD names origin's default branch, so a clone checks that one out.
    head=$(g ls-remote --symref "$ORIGIN_URL" HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" { print $2; exit }')
    case "$head" in refs/heads/?*) g symbolic-ref HEAD "$head" 2>/dev/null || true ;; esac
    g gc --auto --quiet >/dev/null 2>&1 || true
}

# fetch (and clone's first half): origin's branches, as a bundle on stdout for the agent to
# import into the working copy. gitrun writes it; the agent only reads it.
run_fetch() {
    nargs $# 1; no_options "$@"
    gitctl_slug_ok "$1" || die "$GITCTL_REASON"
    enter_copy "$1"
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
    g push --no-recurse-submodules --no-follow-tags "$ORIGIN_URL" "${local_sha}:refs/heads/${branch}"
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

# as_run VERB ARGS...: the gitrun side of a verb, returning here (stdin and stdout passed on).
as_run() {
    if [ "$INSTALLED" = 1 ]; then sudo -n -u gitrun -- "$self" "$@"; return; fi
    AIDC_GITCTL_ROLE=run bash "$self" "$@"
}

# The agent's own git, in a working copy anyone in the session group may have written. It runs
# as the agent, never as gitrun, so the copy's config cannot reach the login; still, the
# settings that run a program on the steps gitctl takes (hooks, fsmonitor, auto gc) are pinned
# off, and no transport is allowed: bundles are imported with `bundle unbundle`, never fetched.
ag() {
    env -i HOME="${HOME:-/}" PATH=/usr/bin:/bin LANG=C.UTF-8 GIT_CONFIG_GLOBAL=/dev/null \
        GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 \
        "$REAL_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c gc.auto=0 \
        -c maintenance.auto=false -c protocol.allow=never -c credential.helper= "$@"
}

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

# The repo's slug, read as the agent from the working copy's origin.
agent_slug() {
    local url
    url=$(ag -C "$1" remote get-url origin 2>/dev/null) || die "${1}: no origin remote"
    url_slug "$url" || die "$GITCTL_REASON"
    SLUG="$GITCTL_SLUG"
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
    gitctl_slug_ok "$slug" || die "$GITCTL_REASON"
    clone_path_ok "$path" || die "$GITCTL_REASON"
    cd -P -- "$path" 2>/dev/null || die "${path}: no such folder (aidc repo add makes it)"
    [ "$(pwd -P)" = "$path" ] || die "${path}: a symlink on the way (it is $(pwd -P))"
    [ -z "$(ls -A .)" ] || die "${path} is not empty"
    [ -w . ] || die "${path}: the git container cannot write it"
    new_bundle
    as_run fetch "$slug" > "$BUNDLE" || exit 1
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
# Read with the agent's own git (no login). Submodules are not entered (their config would be
# read), no lock is taken, and a worktree whose folder is gone (prunable) holds nothing. Any
# step that fails ends the verb with an error: "cannot tell" is never "nothing unpushed".
agent_unpushed() {
    nargs $# 1; no_options "$@"
    local wt line n b rows=() list
    working_copy "$1"; agent_slug "$WC"
    new_bundle
    as_run fetch "$SLUG" > "$BUNDLE" || exit 1
    import_bundle "$WC"
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
        remove-copy) nargs $# 1; no_options "$@"; switch_to run remove-copy "$1" ;;
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
        sweep_store
        case "$verb" in
            fetch) run_fetch "$@" ;; push) run_push "$@" ;;
            storage) run_storage "$@" ;; remove-copy) run_remove_copy "$@" ;;
            *) die "${verb} does not run as gitrun" ;;
        esac ;;
    cred)
        [ "$VERB_ROLE" = cred ] || die "${verb} does not run as gitcred"
        run_cred "$@" ;;
esac
