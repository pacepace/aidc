# shellcheck shell=bash
# aidc Kubernetes backend: settings, kubectl, and the names of what aidc makes in a cluster.
#
# Everything cluster-specific comes from the `kubernetes:` block of the global config
# (~/.config/aidc/config.yaml), so the backend works on any cluster that has Sysbox (or
# another runtime that runs Docker without privileged mode) and a storage class several pods on
# one node can share. docs/design-12-kubernetes.md is the design; README "Kubernetes backend"
# shows the block.
#
# Sourced by scripts/k8s/*.sh and by the cmd-*.sh verbs that route to them. Sources the
# shared libraries itself, so it never calls a helper it has not loaded.

# shellcheck source=../lib/common.sh
. "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}/lib/common.sh"
# shellcheck source=../lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"

# _k8s_cfg <yq-path>: a scalar from the global config's kubernetes block, "" when unset.
_k8s_cfg() {
    local cfg v
    cfg=$(_aidc_global_config_file)
    [ -n "$cfg" ] || return 0
    v=$(aidc_yq "$1" "$cfg" 2>/dev/null || printf '')
    [ "$v" = "null" ] && v=""
    printf '%s' "$v"
}

# _k8s_cfg_json <yq-path> <empty>: a mapping or list from the kubernetes block as compact
# JSON, <empty> ("{}" or "[]") when unset.
_k8s_cfg_json() {
    local cfg v
    cfg=$(_aidc_global_config_file)
    if [ -n "$cfg" ]; then
        v=$(aidc_yq "$1" -o=json -I=0 "$cfg" 2>/dev/null || printf '')
    fi
    case "${v:-null}" in null|'') printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}

# k8s_load_settings: the kubernetes block into AIDC_K8S_* variables, with defaults.
#   AIDC_K8S_CONFIGURED     "true" when the block exists
#   AIDC_K8S_CONTEXT        kubeconfig context ("" = kubectl's current context)
#   AIDC_K8S_KUBECONFIG     kubeconfig file ("" = KUBECONFIG or ~/.kube/config)
#   AIDC_K8S_PREFIX         prefix of every namespace aidc makes (default "aidc")
#   AIDC_K8S_USER           whose sessions these are (default: the login name)
#   AIDC_K8S_RUNTIME_CLASS  runtime class of session pods (default "sysbox-runc")
#   AIDC_K8S_STORAGE_CLASS  storage class of the user's disk (required: no default fits
#                           every cluster, and it must let several pods on a node share it)
#   AIDC_K8S_NODE_SELECTOR  JSON mapping added to session pods (default {})
#   AIDC_K8S_TOLERATIONS    JSON list added to session pods (default [])
#   AIDC_K8S_REGISTRY_PORT  the registry's port (default 5000)
#   AIDC_K8S_REGISTRY_PUSH  where the builder pushes (default the registry Service)
#   AIDC_K8S_REGISTRY_STORAGE_CLASS / _SIZE  the registry's volume (default the user disk's
#                           class, 50Gi)
#   AIDC_K8S_REGISTRY_PULL  where the node pulls (default localhost:<port>, the registry's
#                           loopback host port: containerd pulls from localhost over plain HTTP
#                           with no node configuration)
k8s_load_settings() {
    local cfg
    cfg=$(_aidc_global_config_file)
    AIDC_K8S_CONFIGURED="false"
    if [ -n "$cfg" ] && [ "$(aidc_yq '.kubernetes | type' "$cfg" 2>/dev/null)" = "!!map" ]; then
        AIDC_K8S_CONFIGURED="true"
    fi
    AIDC_K8S_CONTEXT=$(_k8s_cfg '.kubernetes.context')
    AIDC_K8S_KUBECONFIG=$(_k8s_cfg '.kubernetes.kubeconfig')
    # shellcheck disable=SC2088  # the literal "~/" a user wrote in the config file
    case "$AIDC_K8S_KUBECONFIG" in "~/"*) AIDC_K8S_KUBECONFIG="${HOME}/${AIDC_K8S_KUBECONFIG#\~/}" ;; esac
    AIDC_K8S_PREFIX=$(_k8s_cfg '.kubernetes.namespace_prefix')
    AIDC_K8S_PREFIX="${AIDC_K8S_PREFIX:-aidc}"
    AIDC_K8S_USER=$(_k8s_cfg '.kubernetes.user')
    AIDC_K8S_USER="${AIDC_K8S_USER:-$(id -un)}"
    AIDC_K8S_RUNTIME_CLASS=$(_k8s_cfg '.kubernetes.runtime_class')
    AIDC_K8S_RUNTIME_CLASS="${AIDC_K8S_RUNTIME_CLASS:-sysbox-runc}"
    AIDC_K8S_STORAGE_CLASS=$(_k8s_cfg '.kubernetes.storage_class')
    AIDC_K8S_NODE_SELECTOR=$(_k8s_cfg_json '.kubernetes.node_selector' '{}')
    AIDC_K8S_TOLERATIONS=$(_k8s_cfg_json '.kubernetes.tolerations' '[]')
    AIDC_K8S_REGISTRY_PORT=$(_k8s_cfg '.kubernetes.registry.port')
    AIDC_K8S_REGISTRY_PORT="${AIDC_K8S_REGISTRY_PORT:-5000}"
    AIDC_K8S_REGISTRY_PUSH=$(_k8s_cfg '.kubernetes.registry.push')
    AIDC_K8S_REGISTRY_PUSH="${AIDC_K8S_REGISTRY_PUSH:-registry.${AIDC_K8S_PREFIX}-system.svc.cluster.local:${AIDC_K8S_REGISTRY_PORT}}"
    AIDC_K8S_REGISTRY_STORAGE_CLASS=$(_k8s_cfg '.kubernetes.registry.storage_class')
    AIDC_K8S_REGISTRY_STORAGE_CLASS="${AIDC_K8S_REGISTRY_STORAGE_CLASS:-$AIDC_K8S_STORAGE_CLASS}"
    AIDC_K8S_REGISTRY_SIZE=$(_k8s_cfg '.kubernetes.registry.size')
    AIDC_K8S_REGISTRY_SIZE="${AIDC_K8S_REGISTRY_SIZE:-50Gi}"
    AIDC_K8S_REGISTRY_PULL=$(_k8s_cfg '.kubernetes.registry.pull')
    AIDC_K8S_REGISTRY_PULL="${AIDC_K8S_REGISTRY_PULL:-localhost:${AIDC_K8S_REGISTRY_PORT}}"
    export AIDC_K8S_CONFIGURED AIDC_K8S_CONTEXT AIDC_K8S_KUBECONFIG AIDC_K8S_PREFIX AIDC_K8S_USER \
        AIDC_K8S_RUNTIME_CLASS AIDC_K8S_STORAGE_CLASS AIDC_K8S_NODE_SELECTOR AIDC_K8S_TOLERATIONS \
        AIDC_K8S_REGISTRY_PORT AIDC_K8S_REGISTRY_PUSH AIDC_K8S_REGISTRY_PULL \
        AIDC_K8S_REGISTRY_STORAGE_CLASS AIDC_K8S_REGISTRY_SIZE
}

# k8s_kubectl <args...>: kubectl against the configured cluster.
k8s_kubectl() {
    local opts=()
    [ -n "${AIDC_K8S_KUBECONFIG:-}" ] && opts+=(--kubeconfig "$AIDC_K8S_KUBECONFIG")
    [ -n "${AIDC_K8S_CONTEXT:-}" ] && opts+=(--context "$AIDC_K8S_CONTEXT")
    kubectl ${opts[@]+"${opts[@]}"} "$@"
}

# Names. A namespace name is a DNS label: at most 63 characters of [a-z0-9-].
k8s_system_ns()  { printf '%s-system' "$AIDC_K8S_PREFIX"; }
k8s_user_ns()    { printf '%s-u-%s' "$AIDC_K8S_PREFIX" "${1:-$AIDC_K8S_USER}"; }
k8s_session_ns() { printf '%s-%s-%s' "$AIDC_K8S_PREFIX" "$AIDC_K8S_USER" "$1"; }

# k8s_valid_label <value>: 0 when <value> can be part of a namespace name.
k8s_valid_label() {
    printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' && [ "${#1}" -le 63 ]
}

# k8s_require: the tools and settings every Kubernetes verb needs; prints what is missing
# to stderr and returns 1.
k8s_require() {
    local bad=0
    command -v kubectl >/dev/null 2>&1 || { err "kubectl not found on PATH"; bad=1; }
    _aidc_has_yq || { err "yq not found on PATH (the kubernetes backend reads its settings with it)"; bad=1; }
    [ "$bad" = 0 ] || return 1
    k8s_load_settings
    if [ "$AIDC_K8S_CONFIGURED" != "true" ]; then
        err "no kubernetes block in $(_aidc_global_config_file || true) (see README, Kubernetes backend)"
        return 1
    fi
    k8s_valid_label "$AIDC_K8S_PREFIX" || { err "kubernetes.namespace_prefix '${AIDC_K8S_PREFIX}' is not a DNS label"; bad=1; }
    k8s_valid_label "$AIDC_K8S_USER" || { err "kubernetes.user '${AIDC_K8S_USER}' is not a DNS label"; bad=1; }
    [ -n "$AIDC_K8S_STORAGE_CLASS" ] || { err "kubernetes.storage_class is not set"; bad=1; }
    [ "$bad" = 0 ]
}
