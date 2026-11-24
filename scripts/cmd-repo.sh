#!/usr/bin/env bash
# desc: The repos your git container works on (cloned onto your cluster disk, or your own on Docker).
#
# Usage: aidc repo <add|list|remove>
#
# On the Kubernetes backend, sessions make their own worktrees in repos the git container cloned
# onto the user's disk; on Docker, the git container works on the user's own working copies
# (docs/design-12-kubernetes.md, "Git"). Each subcommand is scripts/k8s/repo-<name>.sh or
# scripts/docker/repo-<name>.sh: the two add a repo differently (a clone onto the cluster disk; the
# user's own working copy mounted on Docker). The backend is the one every command defaults to
# (lib/git-common.sh, aidc_default_backend).

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"

usage() {
    cat <<'USAGE'
aidc repo <subcommand>

  add <github-url|owner/name> [--path P]
           Your git container clones the GitHub repo onto your disk in the cluster
           (default /home/<user>/<name>; P as on your own machine, or /home/<user>/...):
           an ordinary working copy, yours and your sessions', shared with the git
           container. Private repos need its GitHub login (aidc git attach). Safe to run
           again.
  list     The GitHub working copies on your disk: path, origin and branch.
  remove <path|owner/name> [--delete-working-copy [--even-unpushed]]
           Deletes the git container's private copy of the repo. The working copy, with
           your sessions' work, is deleted only with --delete-working-copy, and not while it
           or a worktree in it holds commits on no GitHub branch, uncommitted changes or
           stashes (it lists them) unless --even-unpushed is given too.

Sessions see your whole disk. A session works on a repo in its own worktree, on a branch
it names: git -C <repo> worktree add -b <branch> <repo>/<folder> origin/HEAD

On Docker the git container works on your own working copies, never its own clones:
  add <path>         A working copy on this machine (under your home, origin
                     https://github.com/<owner>/<name>) becomes one the git container
                     pushes for: it keeps a private copy of the GitHub repo and sees the
                     working copy at the same path (the container restarts to mount it).
  list               The working copies added: path, origin, branch.
  remove <path|owner/name>
                     The git container forgets it (its private copy, its mount). Your
                     working copy is never deleted.
USAGE
}

case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac
SUB="$1"
shift
# shellcheck source=lib/git-common.sh
. "$AIDC_SCRIPTS/lib/git-common.sh"
BACKEND_DIR=k8s
AIDC_GIT_BACKEND=$(aidc_default_backend) || exit 2
case "$AIDC_GIT_BACKEND" in
    kubernetes) ;;
    docker) BACKEND_DIR=docker ;;
esac
export AIDC_GIT_BACKEND
SCRIPT="$AIDC_SCRIPTS/${BACKEND_DIR}/repo-${SUB}.sh"
if [ ! -f "$SCRIPT" ]; then
    printf '[aidc] error: unknown repo subcommand: %s\n' "$SUB" >&2
    usage >&2
    exit 2
fi
exec bash "$SCRIPT" "$@"
