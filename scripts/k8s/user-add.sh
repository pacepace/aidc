#!/usr/bin/env bash
# aidc user add <name>: the user's namespace and disk. Idempotent: `kubectl apply` leaves what
# is already right alone, and a disk already set up is only checked.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

case "${1:-}" in
    -h|--help) exec bash "$AIDC_SCRIPTS/cmd-user.sh" --help ;;
esac
USER_NAME="${1:-}"
[ -n "$USER_NAME" ] || die "usage: aidc user add <name>"
[ $# -le 1 ] || die "aidc user add takes one name (got: $*)"
k8s_valid_label "$USER_NAME" || die "user name '${USER_NAME}' must be lowercase letters, digits and dashes (a DNS label)"
k8s_require || exit 1

ns=$(k8s_user_ns "$USER_NAME")
k8s_valid_label "$ns" || die "namespace '${ns}' would be longer than 63 characters"
sel=$(k8s_node_selector)
info "applying ${ns} and ${USER_NAME}'s disk (${AIDC_K8S_USER_DISK_SIZE} on ${AIDC_K8S_STORAGE_CLASS})"
if [ "$(k8s_kubectl -n "$ns" get pvc disk -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Bound" ]; then
    k8s_render_user "$USER_NAME" "$sel" | yq ea 'select(.kind != "Pod")' - | k8s_kubectl apply -f - >&2
    info "${USER_NAME}'s disk is already set up"
else
    k8s_kubectl -n "$ns" delete pod disk-init --ignore-not-found --wait=true >/dev/null 2>&1 || true
    k8s_render_user "$USER_NAME" "$sel" | k8s_kubectl apply -f - >&2
    info "binding the disk"
    if ! k8s_kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded pod/disk-init --timeout=300s >/dev/null; then
        die "the disk did not bind; see: kubectl -n ${ns} describe pvc disk; kubectl -n ${ns} describe pod disk-init"
    fi
    k8s_kubectl -n "$ns" delete pod disk-init --wait=false >/dev/null 2>&1 || true
fi
phase=$(k8s_kubectl -n "$ns" get pvc disk -o jsonpath='{.status.phase}' 2>/dev/null || true)
[ "$phase" = "Bound" ] || die "${USER_NAME}'s disk is ${phase:-missing}, not Bound"
info "${USER_NAME} is set up in ${ns}. They add their own SSH key, GitHub login and Claude accounts."
