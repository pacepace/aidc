# shellcheck shell=bash
# gitctl's agent's side (sourced by gitctl.sh, from the same root-owned folder: sudo's one rule
# still names gitctl.sh alone). Uses gitctl.sh's settings and helpers (die, nargs, the paths,
# the action log); defines only functions and the constants they read.
# shellcheck disable=SC2154  # set by gitctl.sh, which sources this

# --- the agent's side: validate, read texts as the agent, switch user ----------------------

# Who asked goes with every switch (--asked-by, last), so the other side's action log has it.
switch_to() { # ROLE VERB ARGS... (stdin passed on)
    local role="$1"; shift
    if [ "$INSTALLED" = 1 ]; then
        local user=gitrun; [ "$role" = cred ] && user=gitcred
        exec sudo -n -u "$user" -- "$self" "$@" --asked-by "$ASKED_BY"
    fi
    AIDC_GITCTL_ROLE="$role" exec bash "$self" "$@" --asked-by "$ASKED_BY"
}

# as_run VERB ARGS...: the gitrun side of a verb, returning here (stdin and stdout passed on).
as_run() {
    if [ "$INSTALLED" = 1 ]; then sudo -n -u gitrun -- "$self" "$@" --asked-by "$ASKED_BY"; return; fi
    AIDC_GITCTL_ROLE=run bash "$self" "$@" --asked-by "$ASKED_BY"
}
# as_cred VERB ARGS...: the gitcred side, returning here.
as_cred() {
    if [ "$INSTALLED" = 1 ]; then sudo -n -u gitcred -- "$self" "$@" --asked-by "$ASKED_BY"; return; fi
    AIDC_GITCTL_ROLE=cred bash "$self" "$@" --asked-by "$ASKED_BY"
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

# docker_wc_ok PATH: on Docker, fetch, tidy and unpushed run as gitwc (the user's uid), which
# can write every mounted working copy. So they act only on a working copy Docker mounted (one
# the user added): PATH resolves at or inside a mount point (the kernel's mount list, which the
# agent cannot change; never /), whose .git is a real folder that gitwc owns, as is its config.
# Checked before any git runs there; working_copy then requires the repo's git dir to be that
# .git. Otherwise the agent could name a repo it made itself (its own config, filters included)
# and have gitwc run it. Sets WC_MOUNT.
docker_wc_ok() {
    local p="$1" m line f
    local -A mounts=()
    WC_MOUNT=""
    [ -r "$MOUNTINFO" ] || die "cannot read the mount list (${MOUNTINFO})"
    while IFS= read -r line; do
        # mountinfo: "id parent maj:min root mountpoint ...", the mount point octal-escaped.
        read -r _ _ _ _ m _ <<<"$line"
        [ -n "$m" ] && mounts["$m"]=1
    done < "$MOUNTINFO"
    while [ -n "$p" ] && [ "$p" != / ]; do
        m="${p//\\/\\134}"; m="${m// /\\040}"; m="${m//$'\t'/\\011}"; m="${m//$'\n'/\\012}"
        if [ -n "${mounts[$m]:-}" ]; then WC_MOUNT="$p"; break; fi
        p="${p%/*}"
    done
    [ -n "$WC_MOUNT" ] || die "${1}: not one of the working copies mounted here (aidc repo add)"
    for f in "$WC_MOUNT/.git" "$WC_MOUNT/.git/config"; do
        if [ -L "$f" ] || [ ! -e "$f" ] || [ "$(stat -c %u -- "$f" 2>/dev/null)" != "$WC_UID" ]; then
            die "${1}: ${f} is not a mounted working copy's own (owned by uid ${WC_UID}, no symlink)"
        fi
    done
    [ -d "$WC_MOUNT/.git" ] || die "${1}: ${WC_MOUNT}/.git is not a folder"
}

# working_copy PATH: the working copy (or worktree) at PATH, in WC.
working_copy() {
    local common
    WC=$(realpath -e -- "$1" 2>/dev/null) || die "${1}: no such folder"
    WC_MOUNT=""
    # gitwc acts on a mounted working copy only, whatever the verb; the agent's fetch, tidy and
    # unpushed are gitwc's on Docker, checked here too.
    if [ "$AS_WC" = 1 ]; then docker_wc_ok "$WC"
    elif [ "$ON_DOCKER" = 1 ]; then case "$verb" in fetch|tidy|unpushed) docker_wc_ok "$WC" ;; esac; fi
    ag -C "$WC" rev-parse --git-dir >/dev/null 2>&1 || die "${WC}: not a git working copy"
    if [ -n "$WC_MOUNT" ]; then
        common=$(ag -C "$WC" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
        common=$(realpath -e -- "${common:-/nonexistent}" 2>/dev/null) || common=""
        [ "$common" = "$WC_MOUNT/.git" ] \
            || die "${WC}: its repo is not the mounted working copy ${WC_MOUNT}'s (git dir ${common:-unknown})"
    fi
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
# branches share its commit). Only a repo on the user's list: gitrun's add-copy refuses any other
# (run_listed), so running clone is not a way to add a repo.
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

# adopt: gitrun makes its private copy of an existing working copy's repo (on Docker, the
# user's own), which every other verb then requires. Only for a repo already on the user's list
# (aidc repo add wrote it there first): gitrun's add-copy refuses any other, so an origin the
# agent set adds nothing. The working copy is only read (its origin), never changed.
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
    local line b tip n i wt base bases=() rows=() rel j ex dirty why
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
    merged_into() { # SHA: 0 when a base holds it
        local x
        for x in "${bases[@]}"; do
            if ag -C "$WC" merge-base --is-ancestor "$1" "refs/remotes/origin/${x}" 2>/dev/null; then return 0; fi
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

# read_file F: a text file named by the agent, read as the agent (uid 2000), never as gitwc,
# which could read the user's own files; - is stdin.
read_file() {
    [ "$AS_WC" = 0 ] || die "gitwc reads no file"
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
        log)
            # Both sides' records, merged in time order; the last <lines> (default 100).
            [ $# -le 1 ] || die "usage: gitctl log [<lines>]"
            local n="${1:-100}" r c
            [[ "$n" =~ ^[1-9][0-9]{0,5}$ ]] || die "${n}: not a number of lines"
            r=$(as_run log </dev/null) || exit 1
            c=$(as_cred log </dev/null) || exit 1
            printf '%s\n%s\n' "$r" "$c" | grep -v '^$' | LC_ALL=C sort -s -k1,1 | tail -n "$n" ;;
        pr-list|protection|protect) nargs $# 1; agent_slug "$1"; switch_to cred "$verb" "$SLUG" ;;
        pr-merge)
            nargs $# 2; agent_slug "$1"
            if [ -n "$EXPECT_HEAD" ]; then switch_to cred "$verb" "$SLUG" "$2" "$EXPECT_HEAD"; fi
            switch_to cred "$verb" "$SLUG" "$2" ;;
        pr-view|pr-view-json) nargs $# 2; agent_slug "$1"; switch_to cred "$verb" "$SLUG" "$2" ;;
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
EXPECT_SLUG="" EXPECT_SHA="" EXPECT_HEAD=""
expect_args() {
    ARGS=("$@")
    while [ ${#ARGS[@]} -ge 2 ]; do
        case "${ARGS[-2]}" in
            --expect-repo) [ -z "$EXPECT_SLUG" ] || die "--expect-repo given twice"; EXPECT_SLUG="${ARGS[-1]}"
                gitctl_slug_ok "$EXPECT_SLUG" || die "$GITCTL_REASON" ;;
            --expect-commit) [ -z "$EXPECT_SHA" ] || die "--expect-commit given twice"; EXPECT_SHA="${ARGS[-1]}"
                [[ "$EXPECT_SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "${EXPECT_SHA}: not a full commit id" ;;
            --expect-head) [ -z "$EXPECT_HEAD" ] || die "--expect-head given twice"; EXPECT_HEAD="${ARGS[-1]}"
                [[ "$EXPECT_HEAD" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "${EXPECT_HEAD}: not a full commit id" ;;
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
    [ -z "$EXPECT_HEAD" ] || [ "$verb" = pr-merge ] || die "only pr-merge takes --expect-head"
}

