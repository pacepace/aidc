#!/usr/bin/env bash
# aidc user remove <name> [--yes]: remove a user and everything aidc made for them, so nothing
# piles up: their namespace (sessions' leftovers, the git container, the ServiceAccounts and
# Roles), their disk and kept audit trails with the volumes and data behind them (a retaining
# class keeps a volume whose claim is deleted: each is set to Delete first), their
# ClusterRoleBindings, and, with the last user, the shared ClusterRoles and admission policy.
# An admin runs it. It refuses while the user has sessions, and asks first (type the name)
# unless --yes.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

USER_NAME="" YES=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) exec bash "$AIDC_SCRIPTS/cmd-user.sh" --help ;;
        --yes|-y) YES=1; shift ;;
        -*) die "unknown option: $1 (aidc user remove <name> [--yes])" ;;
        *)
            [ -z "$USER_NAME" ] || die "aidc user remove takes one name (got: ${USER_NAME} $1)"
            USER_NAME="$1"; shift ;;
    esac
done
[ -n "$USER_NAME" ] || die "usage: aidc user remove <name> [--yes]"
k8s_valid_label "$USER_NAME" || die "user name '${USER_NAME}' must be lowercase letters, digits and dashes (a DNS label)"
k8s_require || exit 1
WAIT="${AIDC_USER_REMOVE_WAIT:-300s}"

ns=$(k8s_user_ns "$USER_NAME")
have_ns=$(k8s_kubectl get namespace "$ns" --ignore-not-found -o name --request-timeout=10s) \
    || die "the cluster did not answer; nothing removed"

if [ -n "$have_ns" ]; then
    sessions=$(k8s_kubectl -n "$ns" get statefulset -l aidc/session -o jsonpath='{range .items[*]}{.metadata.labels.aidc/session}{" "}{end}' \
        --request-timeout=10s) || die "the cluster did not answer; nothing removed"
    if [ -n "${sessions// /}" ]; then
        die "${USER_NAME} has sessions running (${sessions% }): ${USER_NAME} kills them first (aidc kill <name>); nothing removed"
    fi
fi

# Every volume claimed in the namespace, bound or left released by a claim deleted earlier.
pvs=$(k8s_kubectl get pv -o json --request-timeout=10s) || die "cannot read the cluster's volumes; nothing removed"
pvs=$(printf '%s' "$pvs" | jq -r --arg ns "$ns" '.items[] | select(.spec.claimRef.namespace == $ns)
    | "\(.metadata.name)\t\(.spec.claimRef.name)\t\(.spec.persistentVolumeReclaimPolicy)\t\(.status.phase)"')
crbs=$(k8s_kubectl get clusterrolebinding "$(k8s_user_crb "$USER_NAME")" "$(k8s_mcp_crb "$USER_NAME")" \
    --ignore-not-found -o name --request-timeout=10s) || die "the cluster did not answer; nothing removed"

if [ -z "$have_ns" ] && [ -z "$pvs" ] && [ -z "$crbs" ]; then
    info "nothing of ${USER_NAME} is in the cluster (no ${ns}, no volumes, no bindings)"
    exit 0
fi

{
    printf 'This removes %s for good:\n' "$USER_NAME"
    [ -z "$have_ns" ] || printf '  namespace %s and everything in it (the git container, its logins, credentials)\n' "$ns"
    if [ -n "$pvs" ]; then
        printf '  volumes and their data (each set to Delete first):\n'
        printf '%s\n' "$pvs" | awk -F'\t' '{ printf "    %s (claim %s, %s, %s)\n", $1, $2, $3, $4 }'
    fi
    [ -z "$crbs" ] || printf '%s\n' "$crbs" | sed 's/^/  /'
} >&2
if [ -z "$YES" ]; then
    [ -t 0 ] || die "not a terminal: pass --yes to remove ${USER_NAME} without being asked"
    printf 'Type %s to remove it: ' "$USER_NAME" >&2
    read -r answer || answer=""
    [ "$answer" = "$USER_NAME" ] || die "not removed"
fi

rc=0
# Volumes first: once the namespace is gone a retained volume's data would stay behind.
while IFS=$'\t' read -r pv _ policy _; do
    [ -n "$pv" ] || continue
    [ "$policy" = Delete ] && continue
    k8s_kubectl patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null \
        || { err "cannot set volume ${pv} to Delete: its data would stay; nothing more removed"; exit 1; }
done <<<"$pvs"

if [ -n "$have_ns" ]; then
    info "deleting namespace ${ns}"
    k8s_kubectl delete namespace "$ns" --wait=true --timeout="$WAIT" >&2 \
        || { err "namespace ${ns} is not gone after ${WAIT}: see kubectl get namespace ${ns} -o yaml"; rc=1; }
fi
while IFS=$'\t' read -r pv _; do
    [ -n "$pv" ] || continue
    if k8s_kubectl wait --for=delete "pv/${pv}" --timeout="$WAIT" >/dev/null 2>&1; then
        info "volume ${pv} and its data are deleted"
    else
        err "volume ${pv} is still there after ${WAIT}: its provisioner has not deleted it; see kubectl describe pv ${pv}"
        rc=1
    fi
done <<<"$pvs"

k8s_kubectl delete clusterrolebinding "$(k8s_user_crb "$USER_NAME")" "$(k8s_mcp_crb "$USER_NAME")" \
    --ignore-not-found >&2 || rc=1

# The shared pieces go with the last user of this prefix.
left=$(k8s_kubectl get namespace -l aidc/role=user -o name --request-timeout=10s) || left="?"
case "$left" in
    "")
        info "no users left: removing the shared ClusterRoles and admission policy"
        k8s_kubectl delete clusterrole "$(k8s_user_clusterrole)" "$(k8s_mcp_clusterrole)" --ignore-not-found >&2 || rc=1
        k8s_kubectl delete validatingadmissionpolicybinding,validatingadmissionpolicy "$(k8s_user_volume_policy)" \
            --ignore-not-found >/dev/null 2>&1 || true ;;
    "?") info "could not list the remaining users: the shared ClusterRoles stay" ;;
esac

kc="${XDG_CONFIG_HOME:-$HOME/.config}/aidc/users/${USER_NAME}.kubeconfig"
if [ -f "$kc" ]; then
    rm -f "$kc" && info "removed ${kc} (its token was already dead with the namespace)"
fi
[ "$rc" = 0 ] || die "${USER_NAME} is not completely removed (see above); run aidc user remove ${USER_NAME} again"
info "${USER_NAME} is removed"
