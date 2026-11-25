#!/usr/bin/env bash
# aidc user allow-network <name> [<namespace>] [--remove]: let a user give their sessions another
# namespace (aidc create --network, aidc network add), or take it away. An admin runs it.
#
# A session given a namespace reaches its pods by a NetworkPolicy in the user's own namespace,
# and its Services by name through the session's names responder, which aidc fills from that
# namespace's Service list read with the user's credentials. A user's credentials read nothing
# outside their namespace, so the admin grants that one read per namespace: a RoleBinding there
# (<prefix>-u-<name>-network) to the shared ClusterRole <prefix>-network (list Services, nothing
# else), for the user and their MCP server. Never cluster-wide. aidc's own namespaces and the
# cluster's system namespaces are refused, as --network refuses them. With no namespace, lists
# the namespaces granted.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=net.sh
. "$AIDC_SCRIPTS/k8s/net.sh"

USAGE="aidc user allow-network <name> [<namespace>] [--remove]"
USER_NAME="" TARGET="" REMOVE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) exec bash "$AIDC_SCRIPTS/cmd-user.sh" --help ;;
        --remove) REMOVE=1; shift ;;
        -*) die "unknown option: $1 (${USAGE})" ;;
        *)
            if [ -z "$USER_NAME" ]; then USER_NAME="$1"
            elif [ -z "$TARGET" ]; then TARGET="$1"
            else die "too many arguments (${USAGE})"; fi
            shift ;;
    esac
done
[ -n "$USER_NAME" ] || die "usage: ${USAGE}"
k8s_valid_label "$USER_NAME" || die "user name '${USER_NAME}' must be lowercase letters, digits and dashes (a DNS label)"
[ -n "$TARGET" ] || [ -z "$REMOVE" ] || die "--remove needs a namespace (${USAGE})"
k8s_require || exit 1
ns=$(k8s_user_ns "$USER_NAME")
rb=$(k8s_network_rb "$USER_NAME")

if [ -z "$TARGET" ]; then
    out=$(k8s_kubectl get rolebinding -A -l "aidc/user=${USER_NAME},aidc/grant=network" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' --request-timeout=10s) \
        || die "the cluster did not answer"
    if [ -z "$out" ]; then
        printf '%s may give their sessions no other namespace\n' "$USER_NAME"
    else
        printf '%s\n' "$out" | sort -u
    fi
    exit 0
fi

if [ -n "$REMOVE" ]; then
    k8s_kubectl -n "$TARGET" delete rolebinding "$rb" --ignore-not-found >&2 \
        || die "the cluster did not remove ${rb} in ${TARGET}"
    info "${USER_NAME}'s sessions can no longer be given ${TARGET} (a session given it already keeps reaching its pods until aidc network <s> rm ${TARGET})"
    exit 0
fi

if why=$(k8s_network_refusal "$TARGET"); then die "refusing ${TARGET}: ${why}"; fi
have=$(k8s_kubectl get namespace "$TARGET" "$ns" --ignore-not-found -o name --request-timeout=10s) \
    || die "the cluster did not answer"
printf '%s\n' "$have" | grep -qx "namespace/${ns}" || die "${USER_NAME} is not a user here (no ${ns}): aidc user add ${USER_NAME}"
printf '%s\n' "$have" | grep -qx "namespace/${TARGET}" || die "there is no namespace ${TARGET}"
{ k8s_render_network_clusterrole; k8s_render_network_access "$USER_NAME" "$TARGET"; } | k8s_kubectl apply -f - >&2
info "${USER_NAME} may give their sessions ${TARGET}: aidc create --network ${TARGET}, aidc network <s> add ${TARGET}"
info "  (a RoleBinding ${rb} in ${TARGET}: list its Services, nothing else; aidc user allow-network ${USER_NAME} ${TARGET} --remove takes it back)"
