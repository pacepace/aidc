# shellcheck shell=bash
# gitctl's gitcred side (sourced by gitctl.sh, from the same root-owned folder: sudo's one rule
# still names gitctl.sh alone). Uses gitctl.sh's settings and helpers (die, nargs, the paths,
# the action log); defines only functions and the constants they read.
# shellcheck disable=SC2154  # set by gitctl.sh, which sources this

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

# cred_added OWNER/NAME: gitcred's own check that the user added the repo, asked of gitrun (the
# one that holds the private copies) through the one rule gitcred has to it: has-copy, read only
# (gitctl/sudoers). A caller who reaches gitcred directly through sudo cannot skip it.
cred_added() {
    local out rc=0 why
    if [ "$INSTALLED" = 1 ]; then out=$(sudo -n -u gitrun -- "$self" has-copy "$1" 2>&1 </dev/null) || rc=$?
    else out=$(AIDC_GITCTL_ROLE=run bash "$self" has-copy "$1" 2>&1 </dev/null) || rc=$?; fi
    # The answer is gitrun's "yes" line and its exit status; anything else sudo printed (a
    # warning) is neither the answer nor the reason.
    if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx yes; then return 0; fi
    why=$(printf '%s\n' "$out" | sed -n 's/^gitctl: refused: //p' | tail -n1)
    [ -n "$why" ] || why="cannot tell whether ${1} is one of the user's repos (gitrun did not answer): nothing done"
    die "$why"
}

run_cred() {
    # Every verb that names a repo reaches GitHub only for one the user added, checked here as
    # gitcred, whoever called.
    case "$verb" in
        status|login|logout|log) ;;
        *) [ $# -ge 1 ] || die "${verb} needs <owner/name>"
           gitctl_slug_ok "$1" || die "$GITCTL_REASON"
           cred_added "$1" ;;
    esac
    case "$verb" in
        log) nargs $# 0; print_actions ;;
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
            if ! ( apply_protection "$1" ); then action protect "$1" - - failed; exit 1; fi
            action protect "$1" - - ok
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
            local out
            if ! out=$(gh_ pr create --repo "$1" --head "$2" --base "$3" --title "$TITLE" --body "$BODY"); then
                action pr-create "$1" "${2}->${3}" - failed; exit 1
            fi
            printf '%s\n' "$out"
            action pr-create "$1" "${2}->${3}" - "ok $(printf '%s\n' "$out" | grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' | tail -n1)" ;;
        pr-comment)
            nargs $# 2; gitctl_slug_ok "$1" || die "$GITCTL_REASON"; gitctl_number_ok "$2" || die "$GITCTL_REASON"
            read_texts untitled
            [ -n "$BODY" ] || die "pr-comment needs a body"
            gitctl_check_text "$BODY" "the comment" || die "$GITCTL_REASON"
            if ! gh_ pr comment "$2" --repo "$1" --body "$BODY"; then action pr-comment "$1" "#$2" - failed; exit 1; fi
            action pr-comment "$1" "#$2" - ok ;;
        pr-merge)
            # pr-merge <repo> <number> [<head sha>]: with a head sha (what the user approved), only
            # while the pull request's head is still that commit.
            { [ $# = 2 ] || [ $# = 3 ]; } || die "pr-merge takes 2 or 3 arguments"
            no_options "$@"
            gitctl_slug_ok "$1" || die "$GITCTL_REASON"; gitctl_number_ok "$2" || die "$GITCTL_REASON"
            if [ $# = 3 ]; then [[ "$3" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "${3}: not a full commit id"; fi
            # The merge commit's message is GitHub's, carrying the PR's title; the PR's commits
            # land on the base branch. All of it is checked first, whoever wrote it, and the merge
            # is bound to the head that was checked (--match-head-commit): a head moved on GitHub
            # since is refused by GitHub, not merged unchecked.
            local pr text head
            pr=$(gh_ pr view "$2" --repo "$1" --json title,body,commits,headRefOid) || die "cannot read pull request ${2}"
            text=$(printf '%s' "$pr" | jq -r '.title, .body, (.commits[]? | .messageHeadline, .messageBody)') \
                || die "cannot read pull request ${2}"
            head=$(printf '%s' "$pr" | jq -r '.headRefOid // ""')
            [[ "$head" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "GitHub gave no head commit for pull request ${2}"
            [ $# = 2 ] || [ "$head" = "$3" ] \
                || die "pull request ${2} moved since it was approved (approved ${3:0:12}, now ${head:0:12}): nothing merged; ask again"
            gitctl_check_text "$text" "pull request ${2}" || die "$GITCTL_REASON"
            own_identity
            ids=$(printf '%s' "$pr" | jq -r '.commits[]? | .authors[]? | "\(.name) <\(.email)>"')
            gitctl_ai_identity "$ids" && die "pull request ${2} has a commit authored as an AI tool or bot"
            if ! gh_ pr merge "$2" --repo "$1" --merge --match-head-commit "$head"; then
                action pr-merge "$1" "#$2" "$head" failed; exit 1
            fi
            action pr-merge "$1" "#$2" "$head" ok ;;
    esac
}

