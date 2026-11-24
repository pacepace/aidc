#!/usr/bin/env bash
# desc: Repos on your disk in the cluster, cloned by your git container.
#
# Usage: aidc repo <add|list|remove>
#
# On the Kubernetes backend, sessions make their own worktrees in repos the git container cloned
# onto the user's disk (docs/design-12-kubernetes.md, "Git"). Each subcommand is
# scripts/k8s/repo-<name>.sh.

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
  remove <path|owner/name> [--delete-working-copy]
           Deletes the git container's private copy of the repo. The working copy, with
           your sessions' work, is deleted only with --delete-working-copy.

Sessions see your whole disk. A session works on a repo in its own worktree, on a branch
it names: git -C <repo> worktree add -b <branch> <repo>/<folder> origin/HEAD
USAGE
}

case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac
SUB="$1"
shift
SCRIPT="$AIDC_SCRIPTS/k8s/repo-${SUB}.sh"
if [ ! -f "$SCRIPT" ]; then
    printf '[aidc] error: unknown repo subcommand: %s\n' "$SUB" >&2
    usage >&2
    exit 2
fi
exec bash "$SCRIPT" "$@"
