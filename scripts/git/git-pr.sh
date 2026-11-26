#!/usr/bin/env bash
# aidc git pr <repo> <branch> [--base B] --title T --body-file F: the git container pushes the
# branch and opens a pull request for it (gitctl push, then gitctl pr-create: the title and body
# are checked for attribution). The user running the command is the approval. The base is
# origin's default branch unless given, settled before anything is pushed; the body file is read
# here and handed over on stdin.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=backend.sh
. "$AIDC_SCRIPTS/git/backend.sh"
REPO="" BRANCH="" BASE="" TITLE="" BODY_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base) [ $# -ge 2 ] || die "--base needs a branch"; BASE="$2"; shift 2 ;;
        --title) [ $# -ge 2 ] || die "--title needs a value"; TITLE="$2"; shift 2 ;;
        --body-file) [ $# -ge 2 ] || die "--body-file needs a file"; BODY_FILE="$2"; shift 2 ;;
        -*) die "aidc git pr: unknown option $1" ;;
        *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$BRANCH" ]; then BRANCH="$1"; else die "too many arguments: $1"; fi; shift ;;
    esac
done
{ [ -n "$REPO" ] && [ -n "$BRANCH" ] && [ -n "$TITLE" ] && [ -n "$BODY_FILE" ]; } \
    || die "usage: aidc git pr <repo> <branch> [--base B] --title T --body-file F"
{ [ -f "$BODY_FILE" ] && [ -r "$BODY_FILE" ]; } || die "${BODY_FILE}: no such file"
case "$TITLE" in *$'\n'*) die "the title is one line" ;; esac
gb_require
repo=$(gb_repo_arg "$REPO") || exit 1
gb_target
# The base is settled before anything is pushed, by the request watcher's own rule (git-requests
# pr-base, which a session's pull request goes through too): no base, nothing pushed.
base=$(gb_exec_req git-requests pr-base "$repo" ${BASE:+"$BASE"} | aidc_printable) || base=""
case "$base" in
    ""|*$'\n'*|*" "*) die "no base branch for the pull request: nothing pushed (give --base, or fetch the working copy so origin's default branch is known)" ;;
esac
gb_exec_req gitctl push "$repo" "$BRANCH" | aidc_printable || die "the git container did not push ${BRANCH}"
# The title goes through a file the request holder writes (gitctl reads texts from files or stdin).
# shellcheck disable=SC2016  # expanded by the container's shell
head -c 65536 -- "$BODY_FILE" | gb_exec_req_in bash -c '
    base="$3"
    t=$(mktemp) || exit 1
    trap "rm -f \"\$t\"" EXIT
    printf "%s" "$4" > "$t"
    gitctl pr-create "$1" "$2" "$base" --title-file "$t" --body-file -' \
    bash "$repo" "$BRANCH" "$base" "$TITLE" | aidc_printable || die "the git container did not open the pull request"
report=$(gb_exec_req git-requests first-use "$repo" 2>/dev/null | aidc_printable || true)
if [ -n "$report" ] && ! printf '%s\n' "$report" | aidc_git_print_protection; then
    info "this repo is missing protections; turn them on with: aidc git protect ${REPO}"
fi
