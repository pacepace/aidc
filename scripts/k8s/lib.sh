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
#   AIDC_K8S_USER_DISK_SIZE size of each user's disk (default 100Gi)
#   AIDC_K8S_SESSION_STORAGE_CLASS / _HOME_SIZE  each session's home volume, deleted with the
#                           session (default: storage_class, 50Gi)
#   AIDC_K8S_GIT_STORE_SIZE the git container's private copies of GitHub repos (git-run claim,
#                           on the session class; default 10Gi)
#   AIDC_K8S_GIT_STORAGE_WARN  `aidc git status` warns when those copies and its bundles take
#                           more (default 1Gi)
#   AIDC_K8S_CPU_REQUEST / _MEMORY_REQUEST / _CPU_LIMIT / _MEMORY_LIMIT  session size (2 / 8Gi
#                           guaranteed, up to 16 / 32Gi: K8S-19)
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
    AIDC_K8S_USER_DISK_SIZE=$(_k8s_cfg '.kubernetes.user_disk_size')
    AIDC_K8S_USER_DISK_SIZE="${AIDC_K8S_USER_DISK_SIZE:-100Gi}"
    AIDC_K8S_SESSION_STORAGE_CLASS=$(_k8s_cfg '.kubernetes.session_storage_class')
    AIDC_K8S_SESSION_STORAGE_CLASS="${AIDC_K8S_SESSION_STORAGE_CLASS:-$AIDC_K8S_STORAGE_CLASS}"
    AIDC_K8S_HOME_SIZE=$(_k8s_cfg '.kubernetes.home_size'); AIDC_K8S_HOME_SIZE="${AIDC_K8S_HOME_SIZE:-50Gi}"
    AIDC_K8S_GIT_STORE_SIZE=$(_k8s_cfg '.kubernetes.git_store_size'); AIDC_K8S_GIT_STORE_SIZE="${AIDC_K8S_GIT_STORE_SIZE:-10Gi}"
    AIDC_K8S_GIT_STORAGE_WARN=$(_k8s_cfg '.kubernetes.git_storage_warn'); AIDC_K8S_GIT_STORAGE_WARN="${AIDC_K8S_GIT_STORAGE_WARN:-1Gi}"
    AIDC_K8S_CPU_REQUEST=$(_k8s_cfg '.kubernetes.cpu'); AIDC_K8S_CPU_REQUEST="${AIDC_K8S_CPU_REQUEST:-2}"
    AIDC_K8S_MEMORY_REQUEST=$(_k8s_cfg '.kubernetes.memory'); AIDC_K8S_MEMORY_REQUEST="${AIDC_K8S_MEMORY_REQUEST:-8Gi}"
    AIDC_K8S_CPU_LIMIT=$(_k8s_cfg '.kubernetes.cpu_limit'); AIDC_K8S_CPU_LIMIT="${AIDC_K8S_CPU_LIMIT:-16}"
    AIDC_K8S_MEMORY_LIMIT=$(_k8s_cfg '.kubernetes.memory_limit'); AIDC_K8S_MEMORY_LIMIT="${AIDC_K8S_MEMORY_LIMIT:-32Gi}"
    AIDC_K8S_REGISTRY_PULL=$(_k8s_cfg '.kubernetes.registry.pull')
    AIDC_K8S_REGISTRY_PULL="${AIDC_K8S_REGISTRY_PULL:-localhost:${AIDC_K8S_REGISTRY_PORT}}"
    export AIDC_K8S_CONFIGURED AIDC_K8S_CONTEXT AIDC_K8S_KUBECONFIG AIDC_K8S_PREFIX AIDC_K8S_USER \
        AIDC_K8S_RUNTIME_CLASS AIDC_K8S_STORAGE_CLASS AIDC_K8S_NODE_SELECTOR AIDC_K8S_TOLERATIONS \
        AIDC_K8S_REGISTRY_PORT AIDC_K8S_REGISTRY_PUSH AIDC_K8S_REGISTRY_PULL \
        AIDC_K8S_REGISTRY_STORAGE_CLASS AIDC_K8S_REGISTRY_SIZE AIDC_K8S_USER_DISK_SIZE \
        AIDC_K8S_SESSION_STORAGE_CLASS AIDC_K8S_HOME_SIZE AIDC_K8S_GIT_STORE_SIZE AIDC_K8S_GIT_STORAGE_WARN \
        AIDC_K8S_CPU_REQUEST AIDC_K8S_MEMORY_REQUEST \
        AIDC_K8S_CPU_LIMIT AIDC_K8S_MEMORY_LIMIT
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

# k8s_session_taint <namespace> <session>: "yes <flag json>", "no", or "unknown <why>", read
# from the session's policy sidecar. Only the flag file being absent is "no": a sidecar that
# cannot be asked is unknown, never clean.
k8s_session_taint() {
    local ns="$1" s="$2" proxy out
    proxy=$(k8s_kubectl -n "$ns" get pod -l "aidc/session=${s},app=proxy" -o name 2>/dev/null | head -n1)
    [ -n "$proxy" ] || { printf 'unknown (no proxy pod)\n'; return 0; }
    if out=$(k8s_kubectl -n "$ns" exec "$proxy" -c policy -- \
            sh -c 'if [ -e /var/state/tainted ]; then printf "yes "; cat /var/state/tainted; else echo no; fi' \
            </dev/null 2>&1); then
        printf '%s\n' "$out"
    else
        printf 'unknown (the policy sidecar did not answer)\n'
    fi
}

# k8s_session_lookup <namespace> <session>: prints "found", "absent" or "unknown <why>", and
# returns 0, 1 or 2 alike. A cluster that cannot be asked is never "no such session".
k8s_session_lookup() {
    local ns="$1" s="$2" out
    if ! out=$(k8s_kubectl -n "$ns" get deployment,statefulset -l "aidc/session=${s}" -o name \
            --request-timeout=10s 2>&1); then
        printf 'unknown (%s)\n' "$(printf '%s' "$out" | tail -n1)"
        return 2
    fi
    if [ -n "$out" ]; then printf 'found\n'; return 0; fi
    printf 'absent\n'
    return 1
}

# k8s_require_session <namespace> <session>: dies unless the session is there, saying which of
# "no such session" and "the cluster did not answer" it was.
k8s_require_session() {
    local where rc=0
    where=$(k8s_session_lookup "$1" "$2") || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) die "no session '$2' in $1" ;;
        *) die "cannot tell whether session '$2' exists: the cluster did not answer: ${where#unknown }" ;;
    esac
}

# k8s_git_pod <namespace>: the name of the user's git container pod (Running, not being
# deleted), and returns 0; prints "absent" and returns 1 when there is none; prints
# "unknown <why>" and returns 2 when the cluster cannot be asked. Never "absent" for a cluster
# that did not answer.
k8s_git_pod() {
    local ns="$1" out errf
    # stderr apart from the JSON: a kubectl warning on stdout's way would make it unreadable.
    errf=$(mktemp)
    if ! out=$(k8s_kubectl -n "$ns" get pod -l app=git --field-selector=status.phase=Running \
            -o json --request-timeout=10s 2>"$errf"); then
        printf 'unknown (%s)\n' "$(tail -n1 "$errf")"
        rm -f "$errf"
        return 2
    fi
    rm -f "$errf"
    # A pod being replaced (Recreate) is still Running until it is gone: skip it.
    out=$(printf '%s' "$out" | yq -p=json '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name' \
        2>/dev/null | grep -m1 . || true)
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
    printf 'absent\n'
    return 1
}

# k8s_cluster_repo_path <path>: where <path> is on the user's disk. A path under this
# machine's home directory maps to /home/<user>/..., so a Mac's /Users/<name>/x and a Linux
# /home/<name>/x name the same repo and the same Claude history; /home/<user>/... is taken as
# it is. Returns 1 for anything else.
k8s_cluster_repo_path() {
    local p="$1" home="${HOME%/}"
    case "$p" in /*) ;; *) p="${PWD%/}/${p}" ;; esac
    case "$p" in
        "/home/${AIDC_K8S_USER}"|"/home/${AIDC_K8S_USER}/"*) printf '%s' "${p%/}" ;;
        "$home"|"$home/"*) printf '/home/%s%s' "$AIDC_K8S_USER" "${p#"$home"}" ;;
        *) return 1 ;;
    esac
}

# k8s_repo_path_ok <cluster-path>: a folder below /home/<user> named only with letters,
# digits, '.', '_' and '-', with no . or .. part: what gitctl clone accepts, and safe to put
# in a manifest.
k8s_repo_path_ok() {
    local p="$1" c parts
    case "$p" in "/home/${AIDC_K8S_USER}/"?*) ;; *) return 1 ;; esac
    printf '%s' "$p" | grep -Eq '^(/[A-Za-z0-9._-]+)+$' || return 1
    IFS=/ read -ra parts <<<"${p#/}"
    for c in "${parts[@]}"; do case "$c" in .|..) return 1 ;; esac; done
}

# The git container's agent user (gitctl/Dockerfile): it clones a new working copy, in a folder
# `aidc repo add` gives it, before the folder goes to the session user.
# shellcheck disable=SC2034  # read by manifests.sh
K8S_GIT_AGENT_UID=2000

# k8s_repo_state <namespace> <git-pod> <cluster-path>: what is at the path, asked of the git
# container: "repo <origin url>" (a git working copy), "folder" (a folder that is not empty),
# "empty" (missing or empty), or "unknown <why>" when the container cannot be asked. Never
# "empty" for a container that did not answer.
k8s_repo_state() {
    local ns="$1" pod="$2" p="$3" out
    # shellcheck disable=SC2016  # expanded by the container's shell
    out=$(k8s_kubectl -n "$ns" exec "$pod" -c git -- sh -c '
        if [ -d "$1/.git" ]; then echo "state=repo $(git config --file "$1/.git/config" --get remote.origin.url 2>/dev/null || echo "?")"
        elif [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; then echo "state=folder"
        else echo "state=empty"; fi' sh "$p" </dev/null 2>&1) || true
    case "$out" in
        *state=*) printf '%s\n' "${out##*state=}" ;;
        *) printf 'unknown (the git container did not answer: %s)\n' "$(printf '%s' "$out" | tail -n1)" ;;
    esac
}

# k8s_bytes <size>: a Kubernetes-style size (512Mi, 1Gi, 2G, 1500) in bytes; returns 1 when unreadable.
k8s_bytes() {
    local n="${1%%[!0-9]*}" u="${1##*[0-9]}"
    [ -n "$n" ] || return 1
    case "$u" in
        "") echo "$n" ;; Ki) echo $((n * 1024)) ;; Mi) echo $((n * 1024 ** 2)) ;; Gi) echo $((n * 1024 ** 3)) ;;
        Ti) echo $((n * 1024 ** 4)) ;; k|K) echo $((n * 1000)) ;; M) echo $((n * 1000 ** 2)) ;;
        G) echo $((n * 1000 ** 3)) ;; T) echo $((n * 1000 ** 4)) ;; *) return 1 ;;
    esac
}

# k8s_repo_dir_step <namespace> <cluster-path> <mode> <node-selector-json>: run the repo folder
# pod (manifests.sh, k8s_render_repo_dir; sourced by the caller) in <mode> and wait for it,
# up to three minutes. Prints the pod's last line; returns 1, with why on stderr, when it
# failed or did not finish. The pod is deleted either way.
k8s_repo_dir_step() {
    local ns="$1" path="$2" mode="$3" sel="$4" name phase="" logs
    name="repo-dir-${mode}-$(date -u +%Y%m%d%H%M%S)-$$"
    if ! k8s_render_repo_dir "$name" "$path" "$mode" "$sel" | k8s_kubectl apply -f - >/dev/null; then
        printf '[aidc] error: could not start the folder step for %s\n' "$path" >&2
        return 1
    fi
    for _ in $(seq 90); do
        phase=$(k8s_kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        case "$phase" in Succeeded|Failed) break ;; esac
        sleep 2
    done
    logs=$(k8s_kubectl -n "$ns" logs "$name" 2>&1 || true)
    k8s_kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    case "$phase" in
        Succeeded) printf '%s\n' "$logs" | tail -n1 ;;
        Failed) printf '[aidc] error: %s\n' "$(printf '%s' "$logs" | tail -n1)" >&2; return 1 ;;
        *) printf '[aidc] error: the folder step for %s did not finish (phase: %s)\n' "$path" "${phase:-unknown}" >&2; return 1 ;;
    esac
}
