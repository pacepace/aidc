#!/usr/bin/env bash
# aidc k8s check: whether the configured cluster can run aidc sessions.
#
# Read-only. Prints one line per check, "ok:", "missing:" or "note:", and exits 1 when
# anything is missing. A note is something a later step sets up (the registry, made by
# `aidc k8s setup`), not a fault in the cluster.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
aidc k8s check

Checks, read-only, that the cluster in the `kubernetes:` block of
~/.config/aidc/config.yaml can run aidc sessions: kubectl reaches it, the runtime
class and the storage class exist, a ready node can take session pods, and what the
credentials in use may and may not do: everything aidc does in your namespace (missing
otherwise), its cluster-wide reads (a note says what is skipped without them), and
whether they are an admin's. Exits 1 when something is missing.
EOF
        exit 0 ;;
esac

k8s_require || exit 1

MISSING=0
ok()      { printf 'ok:      %s\n' "$*"; }
missing() { printf 'missing: %s\n' "$*"; MISSING=$((MISSING + 1)); }
note()    { printf 'note:    %s\n' "$*"; }

where="context ${AIDC_K8S_CONTEXT:-(current)}"
[ -n "$AIDC_K8S_KUBECONFIG" ] && where="${where}, kubeconfig ${AIDC_K8S_KUBECONFIG}"

if ! version=$(k8s_kubectl get --raw /version 2>&1); then
    missing "the cluster does not answer (${where}): $(printf '%s' "$version" | tail -n1)"
    exit 1
fi
ok "cluster answers (${where}), Kubernetes $(printf '%s' "$version" | yq -p=json '.gitVersion' 2>/dev/null || printf '?')"

if handler=$(k8s_kubectl get runtimeclass "$AIDC_K8S_RUNTIME_CLASS" -o jsonpath='{.handler}' 2>/dev/null); then
    ok "runtime class ${AIDC_K8S_RUNTIME_CLASS} (handler ${handler})"
else
    missing "runtime class ${AIDC_K8S_RUNTIME_CLASS} (kubernetes.runtime_class): session pods need a runtime that runs Docker without privileged mode, such as Sysbox"
fi

if prov=$(k8s_kubectl get storageclass "$AIDC_K8S_STORAGE_CLASS" -o jsonpath='{.provisioner}' 2>/dev/null); then
    ok "storage class ${AIDC_K8S_STORAGE_CLASS} (provisioner ${prov})"
else
    missing "storage class ${AIDC_K8S_STORAGE_CLASS} (kubernetes.storage_class)"
fi

# Nodes a session pod can land on: ready, matching the configured node selector and the
# runtime class's own scheduling selector. Taints are the tolerations' business; a node
# that needs one the config lacks still shows here, and its pods stay Pending.
selector=$(printf '%s' "$AIDC_K8S_NODE_SELECTOR" | yq -p=json -o=json -I=0 '.' 2>/dev/null || printf '{}')
rc_selector=$(k8s_kubectl get runtimeclass "$AIDC_K8S_RUNTIME_CLASS" -o json 2>/dev/null \
    | yq -p=json -o=json -I=0 '.scheduling.nodeSelector // {}' 2>/dev/null || printf '{}')
labels=$(printf '%s\n%s\n' "$selector" "$rc_selector" \
    | yq -p=json -o=json -I=0 -N 'select(. != null) | to_entries | .[] | .key + "=" + .value' 2>/dev/null \
    | tr -d '"' | paste -sd, - || true)
if nodes=$(k8s_kubectl get nodes ${labels:+-l "$labels"} \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null); then
    ready=$(printf '%s\n' "$nodes" | awk '$2 == "True" {print $1}' | paste -sd' ' -)
    if [ -n "$ready" ]; then
        ok "ready node(s) for sessions: ${ready}${labels:+ (selected by ${labels})}"
    else
        missing "no ready node matches ${labels:-any selector} (kubernetes.node_selector and the runtime class's scheduling)"
    fi
elif [ "$(k8s_kubectl auth can-i list nodes 2>/dev/null || true)" = "no" ]; then
    note "your credentials may not list nodes: the ready-node check is skipped (an admin's aidc k8s check makes it)"
else
    missing "cannot list nodes"
fi

# The credentials in use, from one SelfSubjectRulesReview (anyone may ask what they may do),
# compared with what aidc's commands do (manifests.sh: K8S_USER_RULES, K8S_USER_CLUSTER_RULES;
# `aidc user add` grants exactly these). The namespace part is needed; without a cluster-wide
# read a command does less and says so.
user_ns=$(k8s_user_ns "$AIDC_K8S_USER")
# shellcheck disable=SC2016  # jq's variables
K8S_LACKING_JQ='
    def has_($xs; $x): ($xs // []) | (index($x) != null or index("*") != null);
    (.status.resourceRules // []) as $rr
    | [$rules | split("\n")[] | select(test("\\S")) | split(" ") | map(select(. != ""))
        | (if .[0] == "core" then "" else .[0] end) as $g | .[1] as $r | (.[3] // "") as $n
        | .[2] | split(",")[] as $v
        | select(any($rr[]; has_(.apiGroups; $g) and has_(.resources; $r) and has_(.verbs; $v)
            and (((.resourceNames // []) | length) == 0
                 or ($n != "" and ((.resourceNames // []) | index($n) != null)))) | not)
        | "\($v) \($r)"]
    | join(", ")'
# _k8s_lacking <rules> <review-json>: "<verb> <resource>" for each verb of <rules> the review
# does not grant, comma-separated; "" when it grants them all.
_k8s_lacking() { jq -r --arg rules "$1" "$K8S_LACKING_JQ" <<<"$2"; }
review=$(printf '{"apiVersion":"authorization.k8s.io/v1","kind":"SelfSubjectRulesReview","spec":{"namespace":"%s"}}' "$user_ns" \
    | k8s_kubectl create -f - -o json 2>/dev/null) || review=""
if [ -z "$review" ] || ! lack=$(_k8s_lacking "$K8S_USER_RULES" "$review" 2>/dev/null); then
    missing "cannot ask the cluster what your credentials may do in ${user_ns} (SelfSubjectRulesReview)"
else
    who=$(k8s_kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || true)
    if [ "$(printf '%s' "$review" | jq -r '.status.incomplete // false')" = true ]; then
        note "the cluster's answer about your credentials is incomplete (another authorizer decides too); a line below may be wrong"
    fi
    if [ -z "$lack" ]; then
        ok "your credentials${who:+ (${who})} may do everything aidc does in ${user_ns}"
    else
        missing "permission to ${lack} in ${user_ns} (your sessions, git container and repos live there; an admin runs aidc user add ${AIDC_K8S_USER})"
    fi
    clack=$(_k8s_lacking "$K8S_USER_CLUSTER_RULES" "$review" 2>/dev/null || printf '?')
    if [ -z "$clack" ]; then
        ok "cluster-wide you may read runtime classes, storage classes, nodes and volumes, and set your own volumes to Delete (aidc audit trim)"
    else
        note "cluster-wide you may not: ${clack}. Without them: no runtime class, no aidc create; no nodes, no ready-node check; no volumes, aidc audit leaves released trails unlisted and retained ones for an admin to trim"
    fi
fi
if [ "$(k8s_kubectl auth can-i create namespaces 2>/dev/null || true)" = "yes" ]; then
    ok "you may create namespaces: an admin here (aidc k8s setup, aidc k8s build, aidc user add|creds|remove)"
else
    note "you may not create namespaces: an admin runs \`aidc k8s setup\`, \`aidc k8s build\` and \`aidc user add\`"
fi

sys_ns=$(k8s_system_ns)
if ready=$(k8s_kubectl -n "$sys_ns" get deployment registry -o jsonpath='{.status.readyReplicas}' 2>/dev/null) \
        && [ "${ready:-0}" -ge 1 ]; then
    ok "registry in ${sys_ns} is ready (push ${AIDC_K8S_REGISTRY_PUSH}, pull ${AIDC_K8S_REGISTRY_PULL})"
elif [ "$(k8s_kubectl -n "$sys_ns" auth can-i get deployments 2>/dev/null || true)" = "no" ]; then
    note "the registry in ${sys_ns} is an admin's: your credentials cannot see it (sessions pull from it all the same)"
else
    note "no registry in ${sys_ns} yet: \`aidc k8s setup\` makes it"
fi

if [ "$MISSING" -gt 0 ]; then
    printf '\n%s missing: this cluster cannot run aidc sessions yet.\n' "$MISSING"
    exit 1
fi
printf '\nThis cluster can run aidc sessions.\n'
