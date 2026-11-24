#!/usr/bin/env bash
# desc: Your git container on the Kubernetes backend (holds your GitHub login).
#
# Usage: aidc git <setup|attach|status>
#
# Sessions in the cluster cannot push; one git container per user does (docs/design-12-kubernetes.md,
# "Git"). Each subcommand is scripts/k8s/git-<name>.sh.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"

usage() {
    cat <<'USAGE'
aidc git <subcommand>

  setup    Start your git container in your namespace of the `kubernetes:` config (after
           `aidc user add`). It is the only thing that pushes, and it keeps your GitHub login
           on its own volume, where its agent cannot read it. Safe to run again.
  attach   Open its terminal (tmux). Log in to GitHub there with `gitctl login` (a device
           code you approve in your browser): you add your own login, the admin never
           handles it. Detach with Ctrl-b d.
  status   Whether it is running, logged in to GitHub, and has an SSH key. Says "unknown"
           when the cluster or the container cannot be asked.
USAGE
}

case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac
SUB="$1"
shift
SCRIPT="$AIDC_SCRIPTS/k8s/git-${SUB}.sh"
if [ ! -f "$SCRIPT" ]; then
    printf '[aidc] error: unknown git subcommand: %s\n' "$SUB" >&2
    usage >&2
    exit 2
fi
exec bash "$SCRIPT" "$@"
