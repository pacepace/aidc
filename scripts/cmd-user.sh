#!/usr/bin/env bash
# desc: Add a user's area on the Kubernetes backend (their namespace and disk).
#
# Usage: aidc user add <name>
#
# Users exist on the Kubernetes backend only (docs/design-12-kubernetes.md): each has a
# namespace and one disk shared by their sessions. Each subcommand is scripts/k8s/user-<name>.sh.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"

usage() {
    cat <<'USAGE'
aidc user add <name>

  add      Create <name>'s area in the cluster of the `kubernetes:` config: a namespace
           and a disk (on kubernetes.storage_class) that all of <name>'s sessions share.
           The new user then adds their own SSH key, GitHub login and Claude accounts;
           the admin never handles them. Safe to run again.
USAGE
}

case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac
SUB="$1"
shift
SCRIPT="$AIDC_SCRIPTS/k8s/user-${SUB}.sh"
if [ ! -f "$SCRIPT" ]; then
    printf '[aidc] error: unknown user subcommand: %s\n' "$SUB" >&2
    usage >&2
    exit 2
fi
exec bash "$SCRIPT" "$@"
