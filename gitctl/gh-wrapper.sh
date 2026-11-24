#!/usr/bin/env bash
# The git container's gh: /opt/aidc/bin/gh.
#
# Called by the agent (uid 2000), it switches to gitcred, the one user that can read the
# GitHub login (its home, /var/lib/gitctl/gitcred, is 0711 and gh's files in it 0600), through
# the sudo rule that names this file; sudo resets the environment, so GH_TOKEN, GH_HOST,
# GH_DEBUG, proxies and editors the caller exports never reach gh. As gitcred it applies the
# rules (gitctl-rules.sh): only the commands the git container needs, no command that prints
# the token or runs code (extensions, aliases, config set), bodies on stdin rather than from a
# file gh would open as gitcred, merge commits only, no attribution. The git that gh runs
# for itself goes through git-wrapper.sh, as gitrun.
set -u

self=$(readlink -f "${BASH_SOURCE[0]}")
GITCTL_LIB=$(dirname "$self")
# shellcheck source=gitctl-rules.sh
. "$GITCTL_LIB/gitctl-rules.sh"

gitctl_die() { printf 'aidc gitctl: refused: %s\n' "$1" >&2; exit 1; }

if [ "$GITCTL_LIB" = /opt/aidc/lib/gitctl ]; then
    REAL_GH=/usr/local/bin/gh
    if [ "$(id -un)" != gitcred ]; then
        exec sudo -n -u gitcred -- "$self" "$@"
    fi
    export HOME=/var/lib/gitctl/gitcred PATH=/opt/aidc/bin:/usr/local/bin:/usr/bin:/bin
    export GH_CONFIG_DIR=/var/lib/gitctl/gitcred/gh
else
    REAL_GH="${AIDC_GITCTL_REAL_GH:-/usr/local/bin/gh}"
fi

[ -x . ] 2>/dev/null || cd /
ulimit -c 0 2>/dev/null || true
umask 077

# A body on stdin is read here so it can be checked, then handed to gh.
reads_stdin=0
prev=""
for a in "$@"; do
    case "$prev:$a" in
        -F:-|--body-file:-|--notes-file:-|--input:-|-F:*=@-|--field:*=@-) reads_stdin=1 ;;
    esac
    case "$a" in --body-file=-|--notes-file=-|--input=-|--field=*=@-) reads_stdin=1 ;; esac
    prev="$a"
done
GITCTL_STDIN_TEXT=""
[ "$reads_stdin" = 1 ] && GITCTL_STDIN_TEXT=$(cat)

gitctl_check_gh "$@" || gitctl_die "$GITCTL_REASON"

unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_DEBUG DEBUG \
    GH_PATH HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy
# No editor, pager or browser runs: each is a program run as gitcred. GH_EDITOR only checks
# the text (msg-check.sh); a browser link is printed instead of opened.
export GH_PAGER=cat PAGER=cat GH_EDITOR="$GITCTL_LIB/msg-check.sh" AIDC_GITCTL_MSG_MODE=gh \
    GH_BROWSER=echo BROWSER=echo GH_NO_UPDATE_NOTIFIER=1 GH_SPINNER_DISABLED=1
# Only the login asks questions (the device code); everything else fails instead of prompting.
[ "${1:-} ${2:-}" = "auth login" ] || export GH_PROMPT_DISABLED=1

if [ "$reads_stdin" = 1 ]; then
    printf '%s\n' "$GITCTL_STDIN_TEXT" | "$REAL_GH" "$@"
    exit $?
fi
exec "$REAL_GH" "$@"
