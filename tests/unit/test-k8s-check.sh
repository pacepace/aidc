#!/usr/bin/env bash
# Unit tests for the Kubernetes backend's settings (scripts/k8s/lib.sh) and `aidc k8s check`.
#
# The settings decide which cluster, runtime class, storage class and registry every
# Kubernetes verb uses; a default read wrong sends sessions to the wrong place or leaves
# them Pending. The check is what a user runs first, so each fault must be named.
#
# kubectl is a PATH stub driven by environment variables; HOME is a scratch dir holding
# the config. Needs yq (the backend requires it); skips when it is absent.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-check-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/aidc"

if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not installed"
    exit 0
fi

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}
assert_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (no '$needle' in:"; printf '%s\n' "$hay" | sed 's/^/      /'
           echo "    )"; FAIL=$((FAIL + 1)) ;;
    esac
}

# kubectl stub. Every call is logged. Answers:
#   get --raw /version        {"gitVersion":"v1.35.5"} unless K_DOWN=1
#   get runtimeclass X        handler sysbox-runc (or JSON with a node selector) unless K_NO_RC=1
#   get storageclass X        provisioner zfs.csi.openebs.io unless K_NO_SC=1
#   get nodes                 "$K_NODES" (name<space>Ready-status lines)
#   create -f - -o json       a SelfSubjectRulesReview: "$K_RULES" when set, else every right
#                             (or every right but creating pods when K_CANI=no)
#   auth can-i ...            namespaces ${K_CANI_NS:-yes}, nodes ${K_CANI_NODES:-yes},
#                             deployments (the registry's) ${K_CANI_REG:-yes}
#   get deployment registry   ${K_REGISTRY_READY} or fails when unset
#   api-resources             lists validatingadmissionpolicies unless K_NO_VAP=1
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
case "$*" in
    *"get --raw /version"*)
        [ "${K_DOWN:-}" = 1 ] && { echo "Unable to connect to the server: dial tcp: refused" >&2; exit 1; }
        echo '{"gitVersion":"v1.35.5"}' ;;
    *"get runtimeclass"*"-o json"*)
        [ "${K_NO_RC:-}" = 1 ] && exit 1
        echo '{"handler":"sysbox-runc","scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"get runtimeclass"*)
        [ "${K_NO_RC:-}" = 1 ] && { echo 'not found' >&2; exit 1; }
        printf 'sysbox-runc' ;;
    *"get storageclass"*)
        [ "${K_NO_SC:-}" = 1 ] && { echo 'not found' >&2; exit 1; }
        printf 'zfs.csi.openebs.io' ;;
    *"get nodes"*)
        [ "${K_CANI_NODES:-yes}" = no ] && { echo 'nodes is forbidden' >&2; exit 1; }
        printf '%b' "${K_NODES:-}" ;;
    *"auth can-i create namespaces"*) echo "${K_CANI_NS:-yes}" ;;
    *"create --validate=false -f - -o json"*)
        cat >/dev/null
        if [ -n "${K_RULES:-}" ]; then printf '%s' "$K_RULES"
        elif [ "${K_CANI:-yes}" = no ]; then
            # Every right but creating pods (and a create named for one pod only, which is not it).
            echo '{"status":{"resourceRules":[{"apiGroups":["*"],"resources":["*"],"verbs":["get","list","watch","patch","update","delete"]},{"apiGroups":["*"],"resources":["pods"],"verbs":["create"],"resourceNames":["only-this"]},{"apiGroups":["*"],"resources":["services","configmaps","persistentvolumeclaims","events","serviceaccounts/token","pods/exec","pods/portforward","secrets","deployments","statefulsets","networkpolicies","ingresses","middlewares"],"verbs":["create"]}]}}'
        else echo '{"status":{"resourceRules":[{"apiGroups":["*"],"resources":["*"],"verbs":["*"]}]}}'; fi ;;
    *"auth whoami"*) printf 'system:admin' ;;
    *"api-resources"*) [ "${K_NO_VAP:-}" = 1 ] || echo validatingadmissionpolicies.admissionregistration.k8s.io ;;
    *"auth can-i list nodes"*) echo "${K_CANI_NODES:-yes}" ;;
    *"auth can-i get deployments"*) echo "${K_CANI_REG:-yes}" ;;
    *"get deployment registry"*)
        [ -n "${K_REGISTRY_READY:-}" ] || { echo 'not found' >&2; exit 1; }
        printf '%s' "$K_REGISTRY_READY" ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"

export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" K_LOG="$SCRATCH/kubectl.log"
export PATH="$SCRATCH/bin:$PATH"
CFG="$HOME/.config/aidc/config.yaml"

settings() {
    # shellcheck disable=SC1091
    ( . "$AIDC_ROOT/scripts/k8s/lib.sh"; k8s_load_settings
      printf '%s|' "$AIDC_K8S_CONFIGURED" "$AIDC_K8S_CONTEXT" "$AIDC_K8S_KUBECONFIG" \
          "$AIDC_K8S_PREFIX" "$AIDC_K8S_USER" "$AIDC_K8S_RUNTIME_CLASS" "$AIDC_K8S_STORAGE_CLASS" \
          "$AIDC_K8S_NODE_SELECTOR" "$AIDC_K8S_TOLERATIONS" "$AIDC_K8S_REGISTRY_PUSH" \
          "$AIDC_K8S_REGISTRY_PULL" )
}

echo "=== settings ==="
: > "$CFG"
me=$(id -un)
assert_eq "no kubernetes block: unconfigured, every default" \
    "false|||aidc|${me}|sysbox-runc||{}|[]|registry.aidc-system.svc.cluster.local:5000|localhost:5000|" "$(settings)"

cat > "$CFG" <<'EOF'
kubernetes:
  context: lab
  kubeconfig: ~/kube/lab.yaml
  namespace_prefix: dev
  user: alice
  runtime_class: sysbox
  storage_class: shared-zfs
  node_selector: {gpu: "yes"}
  tolerations:
    - {key: role, operator: Equal, value: dev, effect: NoSchedule}
  registry: {port: 5001}
EOF
assert_eq "every key read; ~/ expanded; registry names follow the prefix and port" \
    "true|lab|${HOME}/kube/lab.yaml|dev|alice|sysbox|shared-zfs|{\"gpu\":\"yes\"}|[{\"key\":\"role\",\"operator\":\"Equal\",\"value\":\"dev\",\"effect\":\"NoSchedule\"}]|registry.dev-system.svc.cluster.local:5001|localhost:5001|" \
    "$(settings)"

cat > "$CFG" <<'EOF'
kubernetes:
  storage_class: s
  registry: {push: "reg.example:443", pull: "reg.example:443"}
EOF
assert_eq "explicit registry addresses win over the defaults" \
    "reg.example:443|reg.example:443" "$(settings | cut -d'|' -f10,11)"

echo "=== names ==="
names=$( . "$AIDC_ROOT/scripts/k8s/lib.sh"; k8s_load_settings; AIDC_K8S_USER=alice
         printf '%s %s' "$(k8s_system_ns)" "$(k8s_user_ns "$AIDC_K8S_USER")")
assert_eq "namespaces: system, and the user's (sessions live in it)" "aidc-system aidc-u-alice" "$names"

echo "=== aidc k8s check ==="
run_check() { "$AIDC_ROOT/scripts/aidc" k8s check 2>&1; echo "exit=$?"; }

: > "$CFG"
out=$(run_check)
assert_has "no kubernetes block: says so" "no kubernetes block" "$out"
assert_has "no kubernetes block: exit 1" "exit=1" "$out"

printf 'kubernetes:\n  context: lab\n' > "$CFG"
out=$(run_check)
assert_has "no storage class: says which key" "kubernetes.storage_class is not set" "$out"

printf 'kubernetes:\n  context: lab\n  storage_class: s\n' > "$CFG"
out=$(AIDC_NO_YQ=1 run_check)
assert_has "without yq: says it needs yq" "yq not found" "$out"

out=$(K_DOWN=1 run_check)
assert_has "cluster down: named, with kubectl's own reason" "the cluster does not answer (context lab)" "$out"
assert_has "cluster down: kubectl's reason" "dial tcp: refused" "$out"

: > "$K_LOG"
out=$(K_NODES='n1 True\n' run_check)
assert_has "healthy: every check ok" "This cluster can run aidc sessions." "$out"
assert_has "healthy: exit 0" "exit=0" "$out"
assert_has "nodes are filtered by the runtime class's own node selector" "kubernetes.io/hostname=n1" "$(cat "$K_LOG")"
assert_has "every kubectl call carries the configured context" "--context lab get --raw /version" "$(cat "$K_LOG")"
assert_has "no registry yet is a note, not a fault" "note:    no registry in aidc-system" "$out"

out=$(K_NODES='n1 True\n' K_REGISTRY_READY=1 run_check)
assert_has "a ready registry is reported" "ok:      registry in aidc-system is ready" "$out"

out=$(K_NODES='n1 True\n' K_NO_RC=1 run_check)
assert_has "no runtime class: missing, with why" "missing: runtime class sysbox-runc" "$out"
assert_has "no runtime class: exit 1" "exit=1" "$out"

out=$(K_NODES='n1 True\n' K_NO_SC=1 run_check)
assert_has "no storage class: missing" "missing: storage class s" "$out"

out=$(K_NODES='n1 False\n' run_check)
assert_has "no ready node: missing" "missing: no ready node matches" "$out"

out=$(K_NODES='n1 True\n' K_CANI=no run_check)
assert_has "no permission for pods in your namespace: missing" "missing: permission to create pods in aidc-u-" "$out"
out=$(K_NODES='n1 True\n' K_CANI_NS=no run_check)
assert_has "no permission for namespaces is only a note (an admin can run setup and user add)" \
    "note:    you may not create namespaces" "$out"
assert_has "and the cluster can still run sessions" "This cluster can run aidc sessions." "$out"

echo "=== aidc k8s check with a user's own credentials (aidc user add's Role and ClusterRole) ==="
# The rules review a user's ServiceAccount gets: its Role in its namespace plus the shared
# ClusterRole, as rendered by aidc user add (and the review a cluster always allows).
granted() {
    # shellcheck disable=SC1091
    ( . "$AIDC_ROOT/scripts/k8s/lib.sh"; . "$AIDC_ROOT/scripts/k8s/manifests.sh"; k8s_load_settings
      { k8s_render_user_access alice "${K_ROLE_NOVAP:-}"; printf '%s\n' '---'; k8s_render_user_shared ""; } \
        | yq ea -o=json -I=0 "[select(.kind == \"Role\" and .metadata.name == \"aidc-user\") , select(.kind == \"ClusterRole\" and .metadata.name == \"aidc-user\") ${1:+| select(.kind == \"Role\")}] | {\"status\": {\"resourceRules\": ([.[].rules[]] + [{\"apiGroups\": [\"authorization.k8s.io\"], \"resources\": [\"selfsubjectrulesreviews\"], \"verbs\": [\"create\"]}])}}" - )
}
out=$(K_NODES='n1 True\n' K_RULES="$(granted)" K_CANI_NS=no K_CANI_REG=no run_check)
assert_has "the user's Role covers everything aidc does in their namespace" "ok:      your credentials (system:admin) may do everything aidc does in aidc-u-" "$out"
assert_has "and the shared ClusterRole its cluster-wide reads and the volume patch" "ok:      cluster-wide you may read runtime classes" "$out"
assert_has "the registry they cannot see is a note, not missing" "note:    the registry in aidc-system is an admin's" "$out"
assert_has "a user's credentials can run sessions" "This cluster can run aidc sessions." "$out"

# A user added on a cluster without ValidatingAdmissionPolicy makes no pages: their Role is all
# aidc needs there, and short of it where the policy exists.
out=$(K_NODES='n1 True\n' K_RULES="$(K_ROLE_NOVAP=1 granted)" K_NO_VAP=1 K_CANI_NS=no K_CANI_REG=no run_check)
assert_has "without ValidatingAdmissionPolicy: a Role that makes no pages is everything aidc does" \
    "ok:      your credentials (system:admin) may do everything aidc does in aidc-u-" "$out"
out=$(K_NODES='n1 True\n' K_RULES="$(K_ROLE_NOVAP=1 granted)" K_CANI_NS=no K_CANI_REG=no run_check)
assert_has "with it: the same Role lacks making pages" \
    "missing: permission to create secrets, create ingresses, patch ingresses, create middlewares" "$out"
out=$(K_NODES='n1 True\n' K_RULES="$(granted ns-only)" K_CANI_NS=no K_CANI_NODES=no run_check)
assert_has "without the ClusterRole: what is missing cluster-wide, as a note" \
    "note:    cluster-wide you may not: get runtimeclasses, get storageclasses, get ingressclasses, list nodes, get persistentvolumes, list persistentvolumes, watch persistentvolumes, patch persistentvolumes" "$out"
out=$(K_NODES='' K_RULES="$(granted ns-only)" K_CANI_NS=no K_CANI_NODES=no run_check)
assert_has "nodes they may not list: the ready-node check is skipped, said as a note" \
    "note:    your credentials may not list nodes" "$out"

out=$(K_NODES='n1 True\n' K_RULES='{"status":{"resourceRules":[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]}]}}' run_check)
assert_has "credentials short of the Role: each missing verb named" "missing: permission to watch pods, create pods, patch pods, delete pods, create pods/exec" "$out"
assert_has "and the check fails" "exit=1" "$out"
out=$(K_NODES='n1 True\n' K_RULES='{"status":{"resourceRules":[{"apiGroups":["*"],"resources":["*"],"verbs":["get","list","watch","create","patch","update","delete"],"resourceNames":["someone-else"]}]}}' run_check)
assert_has "a rule limited to other names grants nothing" "missing: permission to get pods" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
