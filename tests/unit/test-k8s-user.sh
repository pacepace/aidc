#!/usr/bin/env bash
# Unit tests for `aidc user add` (scripts/k8s/user-add.sh, k8s_render_user).
#
# A user's disk holds every repo they work on; it must be on the configured (shared) storage
# class, writable by the session user, and a second run must never touch a disk already in
# use. kubectl is a PATH stub; HOME holds the config. Needs yq; skips without it.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-user-$$"
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
        *) echo "  FAIL: $desc (no '$needle' in:"; printf '%s\n' "$hay" | tail -15 | sed 's/^/      /'
           echo "    )"; FAIL=$((FAIL + 1)) ;;
    esac
}

# kubectl stub. Logs calls to $K_LOG; `apply -f -` appends stdin to $K_APPLIED.
#   get pvc disk     phase "$K_PVC_PHASE" before the init pod ran, "Bound" after (unless
#                    K_NEVER_BINDS=1)
#   wait ... disk-init   fails when K_NEVER_BINDS=1
#   api-resources    lists validatingadmissionpolicies unless K_NO_VAP=1
#   create token     a JWT expiring 2030-01-01 (exp 1893456000); fails when K_NO_SA=1
#   config view      a cluster with a server and CA data; current-context "${K_CTX:-admin}"
#   get namespace <n>   "namespace/<n>" unless K_NO_NS=1;  -l aidc/role=user: "$K_USERS_LEFT"
#   get statefulset -l aidc/session   "$K_SESSIONS";  get pv -o json: "$K_PVS" (default none)
#   get clusterrolebinding   "$K_CRBS"
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
case "$*" in
    *"get runtimeclass"*"-o json"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"apply -f -"*) printf '\n---\n' >> "$K_APPLIED"; cat >> "$K_APPLIED" ;;
    *"api-resources"*) echo mutatingwebhookconfigurations.admissionregistration.k8s.io
        [ "${K_NO_VAP:-}" = 1 ] || echo validatingadmissionpolicies.admissionregistration.k8s.io ;;
    *"create token"*)
        [ "${K_NO_SA:-}" = 1 ] && { echo 'error: failed to create token: serviceaccounts "aidc-user" not found' >&2; exit 1; }
        printf 'eyJhbGciOiJSUzI1NiJ9.%s.c2lnbmF0dXJl\n' "$(printf '{"exp":1893456000}' | base64 | tr -d '=\n' | tr '/+' '_-')" ;;
    *"config view"*) echo '{"clusters":[{"name":"c","cluster":{"server":"https://k.example:6443","certificate-authority-data":"Q0EtREFUQQ=="}}]}' ;;
    *"config current-context"*) echo "${K_CTX:-admin}" ;;
    *"get namespace -l aidc/role=user"*) printf '%s' "${K_USERS_LEFT:-}" ;;
    *"get namespace "*) [ "${K_NO_NS:-}" = 1 ] || echo "namespace/aidc-u-alice" ;;
    *"get statefulset -l aidc/session"*) printf '%s' "${K_SESSIONS:-}" ;;
    *"get pv -o json"*) if [ -n "${K_PVS:-}" ]; then printf '%s' "$K_PVS"; else echo '{"items":[]}'; fi ;;
    *"get clusterrolebinding"*) printf '%s' "${K_CRBS:-}" ;;
    *"get pvc disk"*)
        if [ -f "$K_RAN" ] && [ "${K_NEVER_BINDS:-}" != 1 ]; then printf 'Bound'
        else printf '%s' "${K_PVC_PHASE:-}"; fi ;;
    *"wait --for=jsonpath"*"disk-init"*)
        [ "${K_NEVER_BINDS:-}" = 1 ] && exit 1
        : > "$K_RAN" ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"

export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" K_LOG="$SCRATCH/kubectl.log" \
    K_APPLIED="$SCRATCH/applied.yaml" K_RAN="$SCRATCH/ran" PATH="$SCRATCH/bin:$PATH"
cat > "$HOME/.config/aidc/config.yaml" <<'EOF'
kubernetes:
  context: lab
  storage_class: shared-disk
  user_disk_size: 250Gi
  tolerations:
    - {key: role, operator: Equal, value: dev, effect: NoSchedule}
EOF
add() { rm -f "$K_RAN"; : > "$K_APPLIED"; : > "$K_LOG"; "$AIDC_ROOT/scripts/aidc" user add "$@" 2>&1 </dev/null; echo "exit=$?"; }

echo "=== a new user ==="
out=$(add alice)
assert_has "a new user's area is made" "alice is set up in aidc-u-alice" "$out"
assert_has "and exits 0" "exit=0" "$out"
k() { yq -N ea "$1" -o=json -I=0 "$K_APPLIED"; }
assert_eq "the namespace says whose it is" '"aidc-u-alice" "user" "alice"' \
    "$(k 'select(.kind == "Namespace") | [.metadata.name, .metadata.labels["aidc/role"], .metadata.labels["aidc/user"]] | .[]' | paste -sd' ' -)"
assert_eq "the disk is on the configured storage class and size" '["shared-disk","250Gi"]' \
    "$(k 'select(.kind == "PersistentVolumeClaim") | [.spec.storageClassName, .spec.resources.requests.storage]')"
assert_has "the init pod gives the disk to the session user" "chown 1000:1000 /disk" \
    "$(k 'select(.kind == "Pod") | .spec.containers[0].command')"
assert_eq "the init pod lands where sessions land" '{"kubernetes.io/hostname":"n1"}' \
    "$(k 'select(.kind == "Pod") | .spec.nodeSelector')"
assert_eq "the init pod carries the configured tolerations" '[{"key":"role","operator":"Equal","value":"dev","effect":"NoSchedule"}]' \
    "$(k 'select(.kind == "Pod") | .spec.tolerations')"
assert_eq "the init pod has no API token" 'false' "$(k 'select(.kind == "Pod") | .spec.automountServiceAccountToken')"
assert_has "the init pod is removed after it ran" "delete pod disk-init --wait=false" "$(cat "$K_LOG")"
assert_eq "the user's namespace denies all traffic by default (sessions share it; each allows only its own)" \
    '[{"namespace":"aidc-u-alice","spec":{"podSelector":{},"policyTypes":["Ingress","Egress"]}}]' \
    "$(k '[select(.kind == "NetworkPolicy") | {"namespace": .metadata.namespace, "spec": .spec}]')"

echo "=== a user whose disk is already in use ==="
out=$(K_PVC_PHASE=Bound add alice)
assert_has "says the disk is set up already" "already set up" "$out"
assert_eq "no init pod touches a disk already bound" "0" \
    "$(yq -N ea 'select(.kind == "Pod")' "$K_APPLIED" | grep -c . || true)"

echo "=== failures ==="
out=$(K_NEVER_BINDS=1 add alice)
assert_has "a disk that never binds is reported with where to look" "the disk did not bind" "$out"
assert_has "and exits 1" "exit=1" "$out"
out=$(add Alice)
assert_has "a name that cannot be a namespace is refused" "must be lowercase letters" "$out"
out=$(add)
assert_has "no name: usage" "usage: aidc user add <name>" "$out"
out=$(add alice bob)
assert_has "two names refused" "takes one name" "$out"
out=$("$AIDC_ROOT/scripts/aidc" user frobnicate alice 2>&1 </dev/null); rc=$?
assert_eq "an unknown subcommand exits 2" "2" "$rc"

echo "=== a new user's credentials (Pod Security, Roles, bindings) ==="
KC="$HOME/.config/aidc/users/alice.kubeconfig"
rm -f "$KC"
out=$(add alice)
assert_has "exits 0" "exit=0" "$out"
assert_eq "the namespace enforces Pod Security baseline (audit and warn too)" '["baseline","latest","baseline","baseline"]' \
    "$(k 'select(.kind == "Namespace") | .metadata.labels | [.["pod-security.kubernetes.io/enforce"], .["pod-security.kubernetes.io/enforce-version"], .["pod-security.kubernetes.io/audit"], .["pod-security.kubernetes.io/warn"]]')"
# The exact rules: what aidc's commands do in the namespace (test-k8s-rbac.sh keeps them in step
# with the scripts), nothing more.
want_user='[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":[""],"resources":["pods/exec"],"verbs":["create","get"]},{"apiGroups":[""],"resources":["pods/log"],"verbs":["get"]},{"apiGroups":[""],"resources":["services"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":[""],"resources":["configmaps"],"verbs":["get","list","watch","create","patch","update","delete"]},{"apiGroups":[""],"resources":["persistentvolumeclaims"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":[""],"resources":["events"],"verbs":["get","list","watch"]},{"apiGroups":[""],"resources":["serviceaccounts/token"],"verbs":["create"],"resourceNames":["aidc-user"]},{"apiGroups":["apps"],"resources":["deployments"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":["apps"],"resources":["statefulsets"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":["networking.k8s.io"],"resources":["networkpolicies"],"verbs":["get","list","watch","create","patch","delete"]}]'
assert_eq "the user's Role in their namespace: exactly aidc's verbs" "$want_user" \
    "$(k 'select(.kind == "Role" and .metadata.name == "aidc-user" and .metadata.namespace == "aidc-u-alice") | .rules')"
want_mcp='[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list","watch","delete"]},{"apiGroups":[""],"resources":["pods/exec"],"verbs":["create","get"]},{"apiGroups":[""],"resources":["pods/log"],"verbs":["get"]},{"apiGroups":[""],"resources":["services"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":[""],"resources":["configmaps"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":[""],"resources":["persistentvolumeclaims"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":[""],"resources":["events"],"verbs":["get","list","watch"]},{"apiGroups":["apps"],"resources":["deployments"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":["apps"],"resources":["statefulsets"],"verbs":["get","list","watch","create","patch","delete"]},{"apiGroups":["networking.k8s.io"],"resources":["networkpolicies"],"verbs":["get","list","watch","create","patch","delete"]}]'
assert_eq "the MCP's Role: the session lifecycle only (no bare pods, no repo list, no tokens)" "$want_mcp" \
    "$(k 'select(.kind == "Role" and .metadata.name == "aidc-mcp") | .rules')"
assert_eq "each Role is bound to its own ServiceAccount, in the user's namespace only" \
    '[{"name":"aidc-user","role":"aidc-user","sa":"aidc-user","ns":"aidc-u-alice"},{"name":"aidc-mcp","role":"aidc-mcp","sa":"aidc-mcp","ns":"aidc-u-alice"}]' \
    "$(k '[select(.kind == "RoleBinding") | {"name": .metadata.name, "role": .roleRef.name, "sa": .subjects[0].name, "ns": .subjects[0].namespace}]')"
assert_eq "neither ServiceAccount's token is mounted into pods" '[false,false]' \
    "$(k '[select(.kind == "ServiceAccount") | .automountServiceAccountToken]')"
assert_eq "cluster-wide, each ServiceAccount is bound to its shared ClusterRole by a binding named for the user" \
    '[{"name":"aidc-u-alice","role":"aidc-user","sa":"aidc-user"},{"name":"aidc-u-alice-mcp","role":"aidc-mcp","sa":"aidc-mcp"}]' \
    "$(k '[select(.kind == "ClusterRoleBinding") | {"name": .metadata.name, "role": .roleRef.name, "sa": .subjects[0].name}]')"
assert_eq "the user's ClusterRole: reads aidc needs, and the volume patch audit trim needs" \
    '[{"apiGroups":["node.k8s.io"],"resources":["runtimeclasses"],"verbs":["get"]},{"apiGroups":["storage.k8s.io"],"resources":["storageclasses"],"verbs":["get"]},{"apiGroups":[""],"resources":["nodes"],"verbs":["list"]},{"apiGroups":[""],"resources":["persistentvolumes"],"verbs":["get","list","watch","patch"]}]' \
    "$(k 'select(.kind == "ClusterRole" and .metadata.name == "aidc-user") | .rules')"
assert_eq "the MCP's ClusterRole reads the runtime class only" \
    '[{"apiGroups":["node.k8s.io"],"resources":["runtimeclasses"],"verbs":["get"]}]' \
    "$(k 'select(.kind == "ClusterRole" and .metadata.name == "aidc-mcp") | .rules')"
vap=$(k 'select(.kind == "ValidatingAdmissionPolicy") | .spec')
assert_has "the volume patch is narrowed: only a user's own ServiceAccount is matched" \
    "startsWith('system:serviceaccount:aidc-u-') && request.userInfo.username.endsWith(':aidc-user')" "$vap"
assert_has "only volumes claimed in their own namespace" \
    "request.userInfo.username == 'system:serviceaccount:' + oldObject.spec.claimRef.namespace + ':aidc-user'" "$vap"
assert_has "only to Delete" "object.spec.persistentVolumeReclaimPolicy == 'Delete'" "$vap"
assert_has "never to another claim" "object.spec.claimRef == oldObject.spec.claimRef" "$vap"
assert_eq "and the policy denies" '["Deny"]' "$(k 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions')"

echo "=== the kubeconfig ==="
TOKEN="eyJhbGciOiJSUzI1NiJ9.$(printf '{"exp":1893456000}' | base64 | tr -d '=\n' | tr '/+' '_-').c2lnbmF0dXJl"
assert_eq "written for the user, mode 0600" "600" "$(stat -c %a "$KC" 2>/dev/null || stat -f %Lp "$KC")"
assert_eq "its folder is the admin's alone" "700" "$(stat -c %a "$(dirname "$KC")" 2>/dev/null || stat -f %Lp "$(dirname "$KC")")"
assert_eq "it names the cluster's server and CA, the user's namespace and the ServiceAccount's token" \
    "https://k.example:6443|Q0EtREFUQQ==|aidc-u-alice|aidc-u-alice|${TOKEN}" \
    "$(yq -r '[.clusters[0].cluster.server, .clusters[0].cluster["certificate-authority-data"], .contexts[0].context.namespace, .["current-context"], .users[0].user.token] | join("|")' "$KC")"
assert_has "the token asked for is the ServiceAccount's, for the configured lifetime" \
    "-n aidc-u-alice create token aidc-user --duration 720h" "$(cat "$K_LOG")"
assert_has "the path is printed, and when it expires" "valid until 2030-01-01T00:00:00Z): ${KC}" "$out"
assert_eq "the token is nowhere in what aidc user add prints" "0" "$(printf '%s' "$out" | grep -c "c2lnbmF0dXJl" || true)"

creds() { : > "$K_LOG"; "$AIDC_ROOT/scripts/aidc" user creds "$@" </dev/null; }
umask 022
rm -f "$KC"
so=$(creds alice --duration 48h 2>"$SCRATCH/err"); rc=$?
assert_eq "creds: exits 0" "0" "$rc"
assert_eq "creds: nothing on stdout" "" "$so"
assert_eq "creds: no token on stderr either" "0" "$(grep -c c2lnbmF0dXJl "$SCRATCH/err" || true)"
assert_eq "creds: mode 0600 whatever the umask" "600" "$(stat -c %a "$KC" 2>/dev/null || stat -f %Lp "$KC")"
assert_has "creds: --duration is the lifetime asked for" "create token aidc-user --duration 48h" "$(cat "$K_LOG")"
so=$(creds alice --token 2>/dev/null); rc=$?
assert_eq "creds --token: the token alone, on stdout" "${TOKEN}|0" "${so}|${rc}"
out=$(creds alice --duration 3d 2>&1); rc=$?
assert_has "a lifetime that is not a duration is refused" "is not a duration" "$out"
mkdir -p "$SCRATCH/repo" && git -C "$SCRATCH/repo" init -q
out=$(creds alice --out "$SCRATCH/repo/kube/alice.kubeconfig" 2>&1); rc=$?
assert_has "a kubeconfig is never written into a repo" "is inside a git work tree" "$out"
assert_eq "nothing written there, exit 1" "absent|1" "$([ -e "$SCRATCH/repo/kube" ] && echo present || echo absent)|${rc}"
printf 'kube/\n' > "$SCRATCH/repo/.gitignore"
out=$(creds alice --out "$SCRATCH/repo/kube/alice.kubeconfig" 2>&1); rc=$?
assert_eq "a path the repo ignores is allowed" "0" "$rc"
out=$(K_NO_SA=1 creds alice 2>&1); rc=$?
assert_has "no ServiceAccount: says to add the user" "is alice added? aidc user add alice" "$out"
# The user renews their own: aidc's configured kubeconfig is theirs (its context is theirs).
cp "$KC" "$SCRATCH/mine.kubeconfig"
printf 'kubernetes:\n  storage_class: shared-disk\n  user: alice\n  kubeconfig: %s\n' "$SCRATCH/mine.kubeconfig" > "$HOME/.config/aidc/config.yaml"
rm -f "$KC"
out=$(K_CTX=aidc-u-alice creds alice 2>&1); rc=$?
assert_has "a user renewing with their own kubeconfig renews it in place" "): $SCRATCH/mine.kubeconfig" "$out"
assert_eq "and writes nothing else" "absent" "$([ -e "$KC" ] && echo present || echo absent)"
cat > "$HOME/.config/aidc/config.yaml" <<'EOF'
kubernetes:
  context: lab
  storage_class: shared-disk
EOF
out=$(creds alice --revoke 2>&1); rc=$?
log=$(cat "$K_LOG")
assert_has "--revoke replaces the ServiceAccount (every earlier token dies with it)" \
    "delete serviceaccount aidc-user --ignore-not-found --wait=true" "$log"
assert_eq "then applies the credentials again and issues a new token, in that order" "delete apply create" \
    "$(printf '%s\n' "$log" | grep -oE 'delete serviceaccount|apply -f -|create token' | awk '{print $1}' | paste -sd' ' -)"

echo "=== a cluster without ValidatingAdmissionPolicy ==="
out=$(K_NO_VAP=1 add alice)
assert_has "says users may not set volumes to Delete there" "no ValidatingAdmissionPolicy" "$out"
assert_eq "no policy, and no volume patch granted" '0|["get","list","watch"]' \
    "$(k 'select(.kind == "ValidatingAdmissionPolicy")' | grep -c . || true)|$(k 'select(.kind == "ClusterRole" and .metadata.name == "aidc-user") | .rules[] | select(.resources[0] == "persistentvolumes") | .verbs')"

echo "=== aidc user remove ==="
remove() { : > "$K_LOG"; "$AIDC_ROOT/scripts/aidc" user remove "$@" 2>&1 </dev/null; echo "exit=$?"; }
PVS='{"items":[{"metadata":{"name":"pv-disk"},"spec":{"claimRef":{"namespace":"aidc-u-alice","name":"disk"},"persistentVolumeReclaimPolicy":"Retain"},"status":{"phase":"Bound"}},{"metadata":{"name":"pv-old-audit"},"spec":{"claimRef":{"namespace":"aidc-u-alice","name":"s1-audit-20261101000000"},"persistentVolumeReclaimPolicy":"Retain"},"status":{"phase":"Released"}},{"metadata":{"name":"pv-home"},"spec":{"claimRef":{"namespace":"aidc-u-alice","name":"s1-home"},"persistentVolumeReclaimPolicy":"Delete"},"status":{"phase":"Bound"}},{"metadata":{"name":"pv-bob"},"spec":{"claimRef":{"namespace":"aidc-u-bob","name":"disk"},"persistentVolumeReclaimPolicy":"Retain"},"status":{"phase":"Bound"}}]}'
out=$(K_SESSIONS='s1 s2 ' K_PVS="$PVS" remove alice --yes)
assert_has "refused while sessions run, naming them" "alice has sessions running (s1 s2)" "$out"
assert_eq "and nothing is deleted or changed" "0" "$(grep -cE '^(.* )?(delete|patch) ' "$K_LOG" || true)"
out=$(K_PVS="$PVS" remove alice)
assert_has "without a terminal or --yes: refused" "pass --yes" "$out"
assert_has "after saying exactly what would go" "pv-old-audit (claim s1-audit-20261101000000, Retain, Released)" "$out"
assert_eq "nothing deleted" "0" "$(grep -cE '^(.* )?(delete|patch) ' "$K_LOG" || true)"
out=$(K_PVS="$PVS" K_CRBS='clusterrolebinding.rbac.authorization.k8s.io/aidc-u-alice' K_USERS_LEFT='namespace/aidc-u-bob' remove alice --yes)
log=$(cat "$K_LOG")
assert_has "removed" "alice is removed" "$out"
assert_eq "retained volumes of the namespace are set to Delete first, then the namespace goes, then the volumes are awaited" \
    "patch pv pv-disk|patch pv pv-old-audit|delete namespace aidc-u-alice|wait --for=delete pv/pv-disk|wait --for=delete pv/pv-old-audit|wait --for=delete pv/pv-home" \
    "$(printf '%s\n' "$log" | grep -oE 'patch pv [a-z-]+|delete namespace [a-z-]+|wait --for=delete pv/[a-z-]+' | paste -sd'|' -)"
assert_eq "another user's volume is not touched" "0" "$(grep -c pv-bob "$K_LOG" || true)"
assert_has "the user's ClusterRoleBindings go" "delete clusterrolebinding aidc-u-alice aidc-u-alice-mcp --ignore-not-found" "$log"
assert_eq "the shared ClusterRoles stay while another user is left" "0" "$(grep -c 'delete clusterrole ' "$K_LOG" || true)"
: > "$KC"
out=$(K_PVS="$PVS" K_USERS_LEFT='' remove alice --yes)
assert_has "with the last user, the shared ClusterRoles go" "delete clusterrole aidc-user aidc-mcp --ignore-not-found" "$(cat "$K_LOG")"
assert_has "and the admission policy" "delete validatingadmissionpolicybinding,validatingadmissionpolicy aidc-user-volumes" "$(cat "$K_LOG")"
assert_eq "the user's kubeconfig on this machine is removed" "absent" "$([ -e "$KC" ] && echo present || echo absent)"
out=$(K_NO_NS=1 remove alice --yes)
assert_has "nothing left: says so" "nothing of alice is in the cluster" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
