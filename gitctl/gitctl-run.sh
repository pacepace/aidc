# shellcheck shell=bash
# gitctl's gitrun side (sourced by gitctl.sh, from the same root-owned folder: sudo's one rule
# still names gitctl.sh alone). Uses gitctl.sh's settings and helpers (die, nargs, the paths,
# the action log); defines only functions and the constants they read.
# shellcheck disable=SC2154  # set by gitctl.sh, which sources this

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

# run_listed OWNER/NAME: whether the repo is on the user's list of added repos (ADDED_LIST,
# gitctl.sh), compared without case. The list is written from the user's laptop only and is
# mounted read-only here, so no one in this container can put a repo on it. No list, no repo.
run_listed() {
    local want="${1,,}" line
    { [ -n "$ADDED_LIST" ] && [ -f "$ADDED_LIST" ] && [ -r "$ADDED_LIST" ]; } || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [ "${line,,}" = "$want" ] && return 0
    done < <(head -c 1048576 -- "$ADDED_LIST" 2>/dev/null)
    return 1
}
not_added() { die "${1} is not one of the user's repos (the user adds it: aidc repo add ${1})"; }

# enter_copy OWNER/NAME [new]: enter gitrun's private bare copy of the repo and bring it up to
# date with origin's branches. A repo not on the user's list (run_listed) is refused first,
# `new` included, whoever called: the agent can reach gitrun's add-copy (sudo, gitctl clone,
# gitctl adopt), so the list, not the caller, decides. Only `new` (gitctl clone or adopt, which
# aidc repo add runs) makes a missing copy; every other verb refuses a repo with none. A copy made here whose fetch fails is
# removed again, so a failed add leaves no repo looking added. The store is gitrun's and open
# to no one else (checked), so nothing in it was written by anyone but gitrun; each step down
# is entered with cd -P and checked with pwd -P. Sets ORIGIN_URL, and ORIGIN_HEAD to origin's
# default branch as GitHub reports it (its HEAD), or the copy's when GitHub did not say.
enter_copy() {
    local slug="${1,,}" owner name store head made=0
    owner="${slug%/*}" name="${slug#*/}"
    run_listed "$1" || not_added "$1"
    [ -n "$RUN_STORE" ] || die "no private store for gitrun"
    cd -P -- "$RUN_STORE" 2>/dev/null || die "${RUN_STORE}: gitrun's store is missing"
    store=$(pwd -P)
    [ "$(stat -c %u .)" = "$(id -u)" ] || die "${RUN_STORE} is not gitrun's"
    (( 8#$(stat -c %a .) & 8#077 )) && die "${RUN_STORE} is open to others: gitrun keeps its copies where only it can go"
    umask 077
    if [ "${2:-}" != new ] && [ ! -d "${owner}/${name}.git" ]; then not_added "$1"; fi
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
    own_identity
    while read -r sha; do
        [ -n "$sha" ] || continue
        raw=$(g cat-file commit "$sha") || die "cannot read commit ${sha:0:12}"
        gitctl_check_text "$raw" "commit ${sha:0:12}" || die "$GITCTL_REASON; reword it before pushing"
        ids=$(printf '%s\n' "$raw" | sed -n '/^$/q; /^\(author\|committer\) /p')
        gitctl_ai_identity "$ids" && die "commit ${sha:0:12} is authored or committed as an AI tool or bot"
        # No attribution in code or docs either: the lines this commit adds, read as a stream.
        if gitctl_attribution_stream < <(added_lines "$sha"); then
            die "commit ${sha:0:12} adds AI attribution to a file (${GITCTL_HIT:0:120}); no attribution in code or docs. Take it out, or build such text from parts where it is test data"
        fi
    done < <(g rev-list "$local_sha" "${nots[@]}" --)
    if ! g push --no-recurse-submodules --no-follow-tags "$ORIGIN_URL" "${local_sha}:refs/heads/${branch}"; then
        action push "$slug" "$branch" "$local_sha" failed
        die "the push of ${branch} failed"
    fi
    action push "$slug" "$branch" "$local_sha" ok
    # The one line a caller reads back (a session's request result, which sets its upstream).
    echo "pushed ${branch} ${local_sha}"
}

# added_lines SHA: the lines commit SHA adds, without their diff prefix. A plain commit against
# its parent (or the empty tree); a merge as a combined diff, where only a line new against every
# parent counts (what the merge itself wrote; a line from a merged branch was that branch's,
# scanned when it was pushed, or origin's). Renames are followed, so a moved file adds nothing.
# No diff driver, text conversion or colour: what is compared is the bytes the push sends.
added_lines() {
    local n
    n=$(g rev-list --no-walk --parents "$1" | awk '{ print NF - 1 }')
    [ "${n:-0}" -ge 1 ] || n=1
    g diff-tree -p --cc -M --root --no-commit-id --no-color --no-ext-diff --no-textconv "$1" 2>/dev/null \
        | awk -v n="$n" 'BEGIN { p = ""; for (i = 0; i < n; i++) p = p "+" }
            /^diff --(git|cc|combined) / { h = 1; next }
            /^@@/ { h = 0; next }
            h { next }
            substr($0, 1, n) == p { print substr($0, n + 1) }'
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
    if ! g push --no-recurse-submodules --no-follow-tags "--force-with-lease=refs/heads/${branch}:${sha}" \
            "$ORIGIN_URL" ":refs/heads/${branch}"; then
        action delete-branch "$slug" "$branch" "$sha" failed
        die "the delete of ${branch} failed (moved on GitHub since?)"
    fi
    action delete-branch "$slug" "$branch" "$sha" ok
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

# has-copy: whether the user added the repo: it is on the user's list (run_listed) and gitrun
# holds its private copy. A copy of a repo not on the list (left over, or made some other way)
# answers no. Read only; makes nothing. gitcred asks this before every gh call on a repo.
run_has_copy() {
    nargs $# 1; no_options "$@"
    gitctl_slug_ok "$1" || die "$GITCTL_REASON"
    local slug="${1,,}"
    run_listed "$1" || not_added "$1"
    cd -P -- "$RUN_STORE" 2>/dev/null || die "${RUN_STORE}: gitrun's store is missing"
    [ "$(stat -c %u .)" = "$(id -u)" ] || die "${RUN_STORE} is not gitrun's"
    [ -d "${slug}.git" ] || not_added "$1"
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

