#!/usr/bin/env bash
# aidc k8s setup: make the cluster-wide pieces aidc needs (the system namespace and the
# image registry). Idempotent: `kubectl apply` leaves what is already right alone.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
aidc k8s setup

Makes, in the cluster of the `kubernetes:` config, the namespace <prefix>-system and a
private image registry in it, on the node(s) sessions run on. The registry is where
`aidc k8s build` puts aidc's images; nothing is pushed to a public registry. Safe to run
again.
EOF
        exit 0 ;;
    "") ;;
    *) die "aidc k8s setup takes no arguments (got: $1)" ;;
esac

k8s_require || exit 1

sel=$(k8s_node_selector)
ns=$(k8s_system_ns)
info "applying ${ns} and its registry (node selector ${sel})"
k8s_render_system "$sel" | k8s_kubectl apply -f - >&2
info "waiting for the registry to be ready"
if ! k8s_kubectl -n "$ns" rollout status deployment/registry --timeout=300s >&2; then
    die "the registry did not become ready; see: kubectl -n ${ns} describe pod -l app=registry"
fi
info "registry ready: push ${AIDC_K8S_REGISTRY_PUSH}, pull ${AIDC_K8S_REGISTRY_PULL}"
info "next: aidc k8s build"
