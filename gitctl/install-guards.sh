#!/usr/bin/env bash
# Build-time step of the git container image (gitctl/Dockerfile): make the exec path real git
# is given (GIT_EXEC_PATH), a copy of git-core in which `git` and every git builtin
# (git-push, git-commit, git-receive-pack: links to the git binary) are the wrapper, and every
# other program (git-remote-https, git-sh-setup) is the real one. git puts its exec path first
# on PATH for everything it starts, so without this a shell alias, a pager or `submodule
# foreach` calling `git` would get the real git and skip the rules.
#
#   install-guards.sh REAL_EXEC_DIR SHADOW_DIR WRAPPER
set -eu
real="$1" shadow="$2" wrapper="$3"
mkdir -p "$shadow"
for f in "$real"/*; do
    n="${f##*/}"
    if [ "$n" = git ] || [ "$f" -ef "$real/git" ]; then
        ln -sfn "$wrapper" "$shadow/$n"
    else
        ln -sfn "$f" "$shadow/$n"
    fi
done
