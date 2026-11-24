#!/bin/sh
# claude-refresh.sh <image-home> <home>: give the git agent's home the image's Claude Code when
# the home has none or an older one. Run as the git user by the git pod's refresh-claude init
# step, with the home claim at <home> and the image's own /home/git at <image-home>.
#
# Claude Code is copied into the home claim once, when a new claim is seeded; it updates itself
# after that, but a home whose Claude never ran (or cannot reach its update server) would keep
# the version of the day it was made. So: each start, the image's version file is copied into
# the home's versions folder when missing, and ~/.local/bin/claude is pointed at it when the
# home's current version is older. A newer version the home updated to itself is kept.
set -eu
img="$1" home="$2"
src=$(readlink "$img/.local/bin/claude" 2>/dev/null) || { echo "claude-refresh: the image has no Claude Code" >&2; exit 0; }
want=$(basename "$src")
case "$want" in *[!0-9.]*|"") echo "claude-refresh: unexpected version name ${want}" >&2; exit 0 ;; esac
[ -e "$home/.profile" ] || { echo "claude-refresh: the home is not seeded" >&2; exit 0; }
have=""
if cur=$(readlink "$home/.local/bin/claude" 2>/dev/null); then have=$(basename "$cur"); fi
if [ -n "$have" ] && [ -e "$home/.local/share/claude/versions/$have" ] \
    && [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | tail -n1)" = "$have" ]; then
    echo "claude-refresh: the home's Claude Code ${have} is current (image ${want})"
    exit 0
fi
mkdir -p "$home/.local/share/claude/versions" "$home/.local/bin"
if [ ! -e "$home/.local/share/claude/versions/$want" ]; then
    cp "$img/.local/share/claude/versions/$want" "$home/.local/share/claude/versions/.$want.tmp"
    chmod 0755 "$home/.local/share/claude/versions/.$want.tmp"
    mv -f "$home/.local/share/claude/versions/.$want.tmp" "$home/.local/share/claude/versions/$want"
fi
ln -sfn "/home/git/.local/share/claude/versions/$want" "$home/.local/bin/claude"
echo "claude-refresh: Claude Code ${have:-none} -> ${want}"
