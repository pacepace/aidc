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
#                                                        (on the user's list, and gitrun has its copy)
#   gitctl log [<lines>]                                 what gitctl changed on GitHub (gitrun's and
#                                                        gitcred's own records), oldest first
#   gitctl adopt <repo>                                  add an existing working copy's repo (Docker:
#                                                        the user's own; gitrun makes its private copy)
#
# <repo> is a working copy (or a worktree of one) whose origin is
# https://github.com/<owner>/<name>, a repo the user added: `aidc repo add`, run on the user's
# laptop, writes it into the list of added repos (ADDED_LIST, mounted read-only here), then has
# gitctl clone or adopt give gitrun its private copy. gitrun makes a copy of, and acts on, no repo
# missing from that list, whoever asks; every verb that reaches GitHub refuses any other repo,
# reads included. A private copy alone is not "added": the agent can ask gitrun for one. A verb on a <repo> may end with `--expect-repo <owner/name>`: it is refused unless
# the working copy's origin is that repo (the request watcher passes what the user approved).
# push may also end with `--expect-commit <sha>`: refused unless that is the branch's commit;
# pr-merge with `--expect-head <sha>`: refused unless that is the pull request's head now, and the
# merge is GitHub's only while it still is (--match-head-commit). Any verb may end with
# `--asked-by <request id>` (the request watcher's), which goes into the action log.
#
# The gitrun and gitcred sides each keep an action log of what they changed on GitHub (push,
# delete-branch; pr-create, pr-comment, pr-merge, protect), in their own storage, which the agent
# cannot write or read but through `gitctl log`: time, verb, repo, branch or PR, commit, who
# asked (a request id, or "direct") and the calling user. Each log is capped (ACTION_LOG_BYTES,
# then one older file), so nothing piles up.
#
# On Docker, gitwc (the user's uid, which can write their working copies) runs only fetch, tidy
# and unpushed, and only on a working copy Docker mounted here; every other verb refuses it.
set -u

self=$(readlink -f "${BASH_SOURCE[0]}")
GITCTL_LIB=$(dirname "$self")
# shellcheck source=gitctl-rules.sh
. "$GITCTL_LIB/gitctl-rules.sh"

die() { printf 'gitctl: refused: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '/^#   gitctl/s/^#   //p' "$self"; }

# The settings below are read by the sides sourced further down (gitctl-run.sh, gitctl-cred.sh,
# gitctl-agent.sh), which shellcheck does not follow from here.
# shellcheck disable=SC2034
PROTECTED_BRANCHES="main master develop"

# shellcheck disable=SC2034  # read by the sourced sides
if [ "$GITCTL_LIB" = /opt/aidc/lib/gitctl ]; then
    INSTALLED=1
    REAL_GIT=/usr/bin/git REAL_GH=/usr/local/bin/gh
    RUN_HOME=/home/gitrun CRED_HOME=/var/lib/gitctl/gitcred RUN_STORE=/var/lib/gitctl/gitrun
    # The repos the user added (aidc repo add), one owner/name a line, written only from the
    # user's laptop and mounted read-only here: on Kubernetes the git-repos ConfigMap (the pod
    # holds no API token), on Docker ~/.config/aidc/git-added bind-mounted :ro. Nothing in this
    # container, gitrun included, can write it.
    ADDED_LIST=/etc/aidc/git-repos/repos
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
    AS_WC=0; [ "$(id -un)" = gitwc ] && AS_WC=1
    # Who ran gitctl through sudo (sudo sets it; it is not the caller's to choose), for the log.
    CALLER="${SUDO_USER:-$(id -un)}"
    # What Docker mounted here (docker_wc_ok): the kernel's list, nothing the caller names.
    MOUNTINFO=/proc/self/mountinfo
    WC_UID=$(id -u gitwc 2>/dev/null || echo 1000)
else
    # Run from a checkout (the unit tests): no sudo; the role is named, stubs may stand in, and
    # a folder of bare repos (<forge>/<owner>/<name>.git) may stand in for GitHub.
    INSTALLED=0
    REAL_GIT="${AIDC_GITCTL_REAL_GIT:-$(command -v git)}" REAL_GH="${AIDC_GITCTL_REAL_GH:-$(command -v gh || echo gh)}"
    RUN_HOME="${HOME:-/}" CRED_HOME="${AIDC_GITCTL_CRED_HOME:-${HOME:-/}}"
    RUN_STORE="${AIDC_GITCTL_RUN_STORE:-}"
    # Unset, no repo is listed (nothing is added), as an installed container without the list.
    ADDED_LIST="${AIDC_GITCTL_ADDED_LIST:-}"
    HELPER=""
    ROLE="${AIDC_GITCTL_ROLE:-agent}"
    FORGE="${AIDC_GITCTL_TEST_FORGE:-}"
    ON_DOCKER="${AIDC_GITCTL_DOCKER:-0}"
    # A stand-in for /proc/self/mountinfo, and the tester's uid for gitwc's. Honoured only here,
    # run from a checkout: INSTALLED comes from this file's own resolved location, sudo runs only
    # the installed file (and drops the environment), so a copy run with these set runs as its
    # caller, gaining nothing.
    MOUNTINFO="${AIDC_GITCTL_MOUNTINFO:-/proc/self/mountinfo}"
    WC_UID=$(id -u)
    # AIDC_GITCTL_AS_WC=1 stands for running as gitwc (id -un), as AIDC_GITCTL_DOCKER stands for
    # /.dockerenv.
    AS_WC="${AIDC_GITCTL_AS_WC:-0}"
    CALLER="${AIDC_GITCTL_CALLER:-$(id -un)}"
fi
ulimit -c 0 2>/dev/null || true

# On the Docker backend the git container has no route out but its own proxy: aidc-proxy on its
# internal network, a Squid that reaches public addresses only (as the Kubernetes NetworkPolicy
# allows). gitrun's git and gitcred's gh go through it. The address is fixed here, never taken
# from the caller or the environment (sudo drops that anyway).
GITCTL_PROXY=""
# shellcheck disable=SC2034  # read by the sourced sides
if [ "$INSTALLED" = 1 ]; then [ "$ON_DOCKER" = 1 ] && GITCTL_PROXY="http://aidc-proxy:3128"
else GITCTL_PROXY="${AIDC_GITCTL_TEST_PROXY:-}"; fi

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
    clone|fetch|push|unpushed|tidy|delete-branch|storage|remove-copy|has-copy|add-copy|adopt|log) VERB_ROLE=run ;;
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

# --asked-by <id|direct>, last on any command line: who asked for the action, for the action log.
# A request id (32 hex) or "direct"; never passed on as anything else.
ASKED_BY=direct
if [ $# -ge 2 ] && [ "${*: -2:1}" = --asked-by ]; then
    ASKED_BY="${*: -1}"
    [[ "$ASKED_BY" =~ ^([0-9a-f]{32}|direct)$ ]] || die "--asked-by takes a request id or direct"
    set -- "${@:1:$#-2}"
fi

# The action log of this side (gitrun's in its store, gitcred's in its home: neither is the
# agent's), capped at ACTION_LOG_BYTES; past that it becomes <log>.1 (one older file kept).
ACTION_LOG_BYTES=1048576
if [ "$INSTALLED" = 0 ] && [ -n "${AIDC_GITCTL_ACTION_LOG_BYTES:-}" ]; then ACTION_LOG_BYTES="$AIDC_GITCTL_ACTION_LOG_BYTES"; fi
action_log_file() {
    case "$ROLE" in
        run) [ -n "$RUN_STORE" ] && printf '%s/.actions.log' "$RUN_STORE" ;;
        # Run from a checkout, only into a cred home the tests name (never the tester's own).
        cred) { [ "$INSTALLED" = 1 ] || [ -n "${AIDC_GITCTL_CRED_HOME:-}" ]; } && printf '%s/actions.log' "$CRED_HOME" ;;
    esac
}
# action VERB REPO REF SHA RESULT: one line, appended (O_APPEND: lines never interleave).
action() {
    local f size
    f=$(action_log_file) || return 0
    [ -n "$f" ] || return 0
    size=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
    if [ "$size" -ge "$ACTION_LOG_BYTES" ]; then mv -f -- "$f" "${f}.1" 2>/dev/null || true; fi
    ( umask 077
      printf '%s %s %s %s %s asked-by=%s caller=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3:--}" "${4:--}" \
          "$ASKED_BY" "$CALLER" "$5" | LC_ALL=C tr -d '\000-\011\013-\037\177' >> "$f" ) 2>/dev/null || true
}
# print_actions: this side's log, the older file first.
print_actions() {
    local f
    f=$(action_log_file) || return 0
    [ -n "$f" ] || return 0
    cat -- "${f}.1" "$f" 2>/dev/null || true
}

# own_identity: the user's own name and email (the GitHub login's identity file, written by
# gitctl login; readable by every user here), so the AI-author check never refuses them.
# shellcheck disable=SC2034  # GITCTL_OWN_* are read by gitctl_ai_identity (gitctl-rules.sh)
own_identity() {
    local f="$CRED_HOME/git-identity"
    GITCTL_OWN_NAME="" GITCTL_OWN_EMAIL=""
    [ -f "$f" ] || return 0
    GITCTL_OWN_NAME=$(env -i PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME=/ \
        "$REAL_GIT" config --file "$f" --get user.name 2>/dev/null || true)
    GITCTL_OWN_EMAIL=$(env -i PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME=/ \
        "$REAL_GIT" config --file "$f" --get user.email 2>/dev/null || true)
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

# Each trust side's functions are in a file of its own, read from this file's own folder (root's,
# when installed), so each can be reviewed on its own while sudo still names one file.
# shellcheck source=gitctl-run.sh
. "$GITCTL_LIB/gitctl-run.sh"
# shellcheck source=gitctl-cred.sh
. "$GITCTL_LIB/gitctl-cred.sh"
# shellcheck source=gitctl-agent.sh
. "$GITCTL_LIB/gitctl-agent.sh"

case "$ROLE" in
    agent)
        # gitwc runs fetch, tidy and unpushed only (each on a mounted working copy: working_copy).
        # Nothing else: no push, adopt, pull request or file read as the user's uid.
        if [ "$AS_WC" = 1 ]; then
            case "$verb" in fetch|tidy|unpushed) ;; *) die "${verb} does not run as gitwc (only fetch, tidy and unpushed do)" ;; esac
        fi
        # On Docker the verbs that write a working copy run as gitwc, its owner's uid (sudo: the
        # one rule naming gitctl; the caller's environment is dropped).
        # The mount check runs here (a plain answer) and again as gitwc (the one that counts).
        if [ "$INSTALLED" = 1 ] && [ "$ON_DOCKER" = 1 ] && [ "$(id -un)" = git ]; then
            case "$verb" in
                fetch|tidy|unpushed)
                    p=$(realpath -e -- "${1:-}" 2>/dev/null) || die "${1:-}: no such folder"
                    docker_wc_ok "$p"
                    exec sudo -n -u gitwc -- "$self" "$verb" "$@" --asked-by "$ASKED_BY" ;;
            esac
        fi
        expect_args "$@"; agent_side ${ARGS[@]+"${ARGS[@]}"} ;;
    run)
        sweep_store
        case "$verb" in
            fetch|add-copy) run_fetch "$@" ;; push) run_push "$@" ;; delete-branch) run_delete_branch "$@" ;;
            storage) run_storage "$@" ;; remove-copy) run_remove_copy "$@" ;; has-copy) run_has_copy "$@" ;;
            log) nargs $# 0; print_actions ;;
            *) die "${verb} does not run as gitrun" ;;
        esac ;;
    cred)
        [ "$VERB_ROLE" = cred ] || [ "$verb" = log ] || die "${verb} does not run as gitcred"
        run_cred "$@" ;;
esac
