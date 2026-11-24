#!/usr/bin/env bash
# git's credential helper in the git container (/etc/gitconfig). git runs as gitrun, which
# cannot read the GitHub login; it runs this, as gitcred, through the sudo rule that is
# gitrun's alone, and gets the token for https://github.com only: never for another host, and
# never over plain http, where it would cross in the clear.
set -u
ulimit -c 0 2>/dev/null || true
umask 077
if [ "${1:-}" != get ]; then
    cat >/dev/null
    exit 0
fi
input=$(cat)
proto=$(printf '%s\n' "$input" | sed -n 's/^protocol=//p' | head -1)
host=$(printf '%s\n' "$input" | sed -n 's/^host=//p' | head -1)
[ "$proto" = https ] && [ "$host" = github.com ] || exit 0
export HOME=/var/lib/gitctl/gitcred GH_CONFIG_DIR=/var/lib/gitctl/gitcred/gh
unset GH_TOKEN GITHUB_TOKEN GH_HOST GH_DEBUG DEBUG
printf '%s\n' "$input" | /usr/local/bin/gh auth git-credential get
