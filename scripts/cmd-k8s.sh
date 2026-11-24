#!/usr/bin/env bash
# desc: Set up and check a Kubernetes cluster for aidc sessions.
#
# Usage: aidc k8s <check|setup|build> [args]
#
# The cluster comes from the `kubernetes:` block of ~/.config/aidc/config.yaml (README,
# "Kubernetes backend"). Each subcommand is scripts/k8s/k8s-<name>.sh.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"

usage() {
    cat <<'EOF'
aidc k8s <subcommand>

  check    Say whether the configured cluster can run aidc sessions, and what is missing.
  setup    Make the system namespace and the private image registry (once per cluster).
  build    Build aidc's images in the cluster and push them to that registry.

The cluster, the runtime class, the storage class and the rest come from the
`kubernetes:` block of ~/.config/aidc/config.yaml (see the README, "Kubernetes backend").
EOF
}

case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac
SUB="$1"
shift
SCRIPT="$AIDC_SCRIPTS/k8s/k8s-${SUB}.sh"
if [ ! -f "$SCRIPT" ]; then
    printf '[aidc] error: unknown k8s subcommand: %s\n' "$SUB" >&2
    usage >&2
    exit 2
fi
exec bash "$SCRIPT" "$@"
