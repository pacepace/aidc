#!/usr/bin/env bash
# aidc user add <name> [--out FILE] [--duration D]: the user's namespace (Pod Security
# "baseline"), disk, credentials (ServiceAccounts, Roles and bindings for the user and their MCP
# server) and a kubeconfig for them. An admin runs it. Idempotent: `kubectl apply` leaves what
# is already right alone, a disk already set up is only checked, and the kubeconfig is issued
# again (a new token; the old one stays valid until it expires).

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

USER_NAME="" CREDS_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) exec bash "$AIDC_SCRIPTS/cmd-user.sh" --help ;;
        --out|--duration)
            [ $# -ge 2 ] || die "$1 needs a value"
            CREDS_ARGS+=("$1" "$2"); shift 2 ;;
        -*) die "unknown option: $1 (aidc user add <name> [--out FILE] [--duration D])" ;;
        *)
            [ -z "$USER_NAME" ] || die "aidc user add takes one name (got: ${USER_NAME} $1)"
            USER_NAME="$1"; shift ;;
    esac
done
[ -n "$USER_NAME" ] || die "usage: aidc user add <name>"
k8s_valid_label "$USER_NAME" || die "user name '${USER_NAME}' must be lowercase letters, digits and dashes (a DNS label)"
k8s_require || exit 1

ns=$(k8s_user_ns "$USER_NAME")
k8s_valid_label "$ns" || die "namespace '${ns}' would be longer than 63 characters"
sel=$(k8s_node_selector)

# The cluster-wide pieces every user's bindings name. Without ValidatingAdmissionPolicy
# (Kubernetes before 1.30) the volume patch it narrows is not granted at all.
no_vap=""
if ! k8s_has_vap; then
    no_vap=1
    info "this cluster has no ValidatingAdmissionPolicy: users may not set their audit volumes to Delete; an admin trims retained ones (aidc audit trim)"
    info "  nor make pages (aidc create --expose): nothing would hold their Ingresses to their own names"
fi

# Page names are <session>-<user>.<domain>: a user whose name ends in -<another user's name>
# could make the other's page names (a-bob's session x and bob's session x-a are both x-a-bob),
# so such a name is refused. The admission policy then keeps every user to their own.
others=$(k8s_kubectl get namespace -l aidc/role=user -o name --request-timeout=10s) \
    || die "the cluster did not answer (listing the other users); nothing was made"
for o in $others; do
    o="${o#namespace/}"; o="${o#"${AIDC_K8S_PREFIX}-u-"}"
    [ "$o" != "$USER_NAME" ] || continue
    case "$USER_NAME" in *-"$o") die "user name '${USER_NAME}' ends in -${o}, another user's name: their page names would overlap (<session>-${USER_NAME} and <session>-${o}); pick another name" ;; esac
    case "$o" in *-"$USER_NAME") die "user '${o}' ends in -${USER_NAME}: their page names would overlap (<session>-${o} and <session>-${USER_NAME}); pick another name" ;; esac
done

info "applying ${ns} and ${USER_NAME}'s disk (${AIDC_K8S_USER_DISK_SIZE} on ${AIDC_K8S_STORAGE_CLASS})"
k8s_render_user_shared "${no_vap:+no-volume-patch}" | k8s_kubectl apply -f - >&2
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

info "applying ${USER_NAME}'s credentials: ServiceAccount ${K8S_USER_SA} (the user) and ${K8S_MCP_SA} (their MCP server), each with its Role in ${ns}"
k8s_render_user_access "$USER_NAME" "$no_vap" | k8s_kubectl apply -f - >&2
info "${USER_NAME} is set up in ${ns}. They add their own GitHub login (aidc git login) and Claude accounts."

bash "$AIDC_SCRIPTS/k8s/user-creds.sh" "$USER_NAME" ${CREDS_ARGS[@]+"${CREDS_ARGS[@]}"}
# Optional: a user who never pushes from the cluster needs no git container.
info "next, for pushes and PRs: ${USER_NAME} runs \`aidc git setup\` (with kubernetes.user: ${USER_NAME}), then \`aidc git attach\` to log in"
