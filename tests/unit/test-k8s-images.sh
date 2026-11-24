#!/usr/bin/env bash
# Unit tests for `aidc k8s setup` / `aidc k8s build` (scripts/k8s/manifests.sh, k8s-build.sh).
#
# The registry must listen on the node's loopback only and land where session pods land, or
# images are either exposed to the network or unpullable; the builder must run unprivileged
# and trust only aidc's own registry; a build must push every image to the configured
# registry under this version and never leave a builder pod behind.
#
# kubectl is a PATH stub that logs calls and plays the builder's `exec` commands; HOME is
# a scratch dir with the config. Needs yq; skips without it.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-images-$$"
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
        *) echo "  FAIL: $desc (no '$needle' in:"; printf '%s\n' "$hay" | tail -20 | sed 's/^/      /'
           echo "    )"; FAIL=$((FAIL + 1)) ;;
    esac
}
assert_not_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  FAIL: $desc ('$needle' present)"; FAIL=$((FAIL + 1)) ;;
        *) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
    esac
}

# kubectl stub. Logs every call to $K_LOG. Plays:
#   get runtimeclass -o json      a node selector {kubernetes.io/hostname: n1}
#   get deployment registry       readyReplicas ${K_REGISTRY_READY:-1} ("" = not found)
#   apply -f -                    stdin appended to $K_APPLIED
#   wait / rollout                succeed
#   exec ... -- wget ...manifests/<tag>   exit 0 when the image path is in $K_PRESENT
#   exec ... -- tar ...           drains stdin
#   exec ... -- <anything else>   succeeds
#   exec -i ...                   drains stdin, as the real kubectl does
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
case "$*" in
    *"get runtimeclass"*"-o json"*)
        echo '{"handler":"sysbox-runc","scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"get deployment registry"*)
        [ -n "${K_REGISTRY_READY-1}" ] || { echo 'not found' >&2; exit 1; }
        printf '%s' "${K_REGISTRY_READY-1}" ;;
    *"apply -f -"*) cat >> "$K_APPLIED" ;;
    *" exec "*"-- wget "*)
        for p in ${K_PRESENT:-}; do case "$*" in *"/v2/${p}"*) exit 0 ;; esac; done
        exit 1 ;;
    *" exec "*"-- tar "*) cat > /dev/null ;;
esac
# Like the real kubectl, `exec -i` reads all of stdin, whatever the command does with it: a
# caller looping over lines on stdin loses the rest of them to the first exec.
case "$*" in *" exec -i "*) cat > /dev/null ;; esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"

export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" K_LOG="$SCRATCH/kubectl.log" \
    K_APPLIED="$SCRATCH/applied.yaml" PATH="$SCRATCH/bin:$PATH"
cat > "$HOME/.config/aidc/config.yaml" <<'EOF'
kubernetes:
  context: lab
  storage_class: shared
  node_selector: {pool: dev}
  tolerations:
    - {key: role, operator: Equal, value: dev, effect: NoSchedule}
  registry: {port: 5050, size: 7Gi, storage_class: fast}
EOF
VERSION_TAG=$(head -n1 "$AIDC_ROOT/VERSION" | tr '+' '_')

echo "=== aidc k8s setup: the registry manifest ==="
: > "$K_APPLIED"; : > "$K_LOG"
"$AIDC_ROOT/scripts/aidc" k8s setup >/dev/null 2>&1
assert_eq "setup applies the namespace, the volume, the registry, its Service and its push fence" \
    "Namespace PersistentVolumeClaim Deployment Service NetworkPolicy" \
    "$(yq -N ea '.kind' "$K_APPLIED" | paste -sd' ' -)"
dep() { yq ea "select(.kind == \"Deployment\") | $1" -o=json -I=0 "$K_APPLIED"; }
assert_eq "the registry listens on the node's loopback only, on the configured port" \
    '[{"containerPort":5000,"hostPort":5050,"hostIP":"127.0.0.1"}]' "$(dep '.spec.template.spec.containers[0].ports')"
assert_eq "the registry lands where session pods land: runtime class selector merged with the config's" \
    '{"kubernetes.io/hostname":"n1","pool":"dev"}' "$(dep '.spec.template.spec.nodeSelector')"
assert_eq "the registry carries the configured tolerations" \
    '[{"key":"role","operator":"Equal","value":"dev","effect":"NoSchedule"}]' "$(dep '.spec.template.spec.tolerations')"
assert_eq "the registry image is pinned, not a moving tag" "true" \
    "$(dep '.spec.template.spec.containers[0].image' | grep -Eq ':[0-9]+\.[0-9]+\.[0-9]+"$' && echo true)"
assert_eq "the registry volume uses the configured class and size" '["fast","7Gi"]' \
    "$(yq -N ea 'select(.kind == "PersistentVolumeClaim") | [.spec.storageClassName, .spec.resources.requests.storage]' -o=json -I=0 "$K_APPLIED")"
assert_eq "the Service exposes the configured port in-cluster" "5050" \
    "$(yq ea 'select(.kind == "Service") | .spec.ports[0].port' "$K_APPLIED")"
assert_has "every kubectl call uses the configured context" "--context lab apply" "$(cat "$K_LOG")"
assert_eq "only builder pods of the system namespace may reach the registry (no session can replace an image)" \
    '{"podSelector":{"matchLabels":{"app":"registry"}},"policyTypes":["Ingress"],"ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"builder"}}}],"ports":[{"protocol":"TCP","port":5000}]}]}' \
    "$(yq -N ea 'select(.kind == "NetworkPolicy") | .spec' -o=json -I=0 "$K_APPLIED")"
assert_eq "the system namespace, and only it, allows the privileged builder" "privileged" \
    "$(yq -N ea 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$K_APPLIED")"

echo "=== aidc k8s build ==="
out=$(K_REGISTRY_READY="" "$AIDC_ROOT/scripts/aidc" k8s build 2>&1); rc=$?
assert_has "no registry: says to run setup" "run \`aidc k8s setup\` first" "$out"
assert_eq "no registry: exit 1" "1" "$rc"

out=$("$AIDC_ROOT/scripts/aidc" k8s build --only nonesuch 2>&1); rc=$?
assert_has "an unknown role is refused by name" "unknown role 'nonesuch'" "$out"

: > "$K_APPLIED"; : > "$K_LOG"
out=$(K_PRESENT="aidc/squid/manifests/${VERSION_TAG} aidc/refresher/manifests/${VERSION_TAG}" \
    "$AIDC_ROOT/scripts/aidc" k8s build 2>&1); rc=$?
log=$(cat "$K_LOG")
b() { yq -N ea "select(.kind == \"Pod\") | $1" -o=json -I=0 "$K_APPLIED"; }
assert_eq "a full build exits 0" "0" "$rc"
assert_has "images already in the registry for this version are skipped" "present: aidc/squid:${VERSION_TAG}" "$out"
assert_has "the rest are built" "built 5, already present 2" "$out"
assert_has "each image is pushed to the configured registry under this version" \
    "docker push -q registry.aidc-system.svc.cluster.local:5050/aidc/dev-base:${VERSION_TAG}" "$log"
assert_not_has "a skipped image is not built" "aidc/squid:${VERSION_TAG} -f" "$log"
assert_has "dev-base refreshes Claude Code, as aidc rebuild does" "--build-arg CLAUDE_CODE_REFRESH=" "$log"
assert_has "the Dockerfile path is the image's own, inside its streamed context" \
    "-f /build/dev-base/Dockerfile /build/dev-base" "$log"
assert_has "the builder pod is deleted when the build ends" "delete pod builder-" "$log"
assert_eq "the builder is privileged (the squid base needs UIDs no user namespace has) and has no API token" \
    '[true,false]' \
    "$(yq -N ea 'select(.kind == "Pod") | [.spec.containers[0].securityContext.privileged, .spec.automountServiceAccountToken]' -o=json -I=0 "$K_APPLIED")"
assert_eq "the builder's Docker listens on its unix socket only, never the pod network" \
    '["--host=unix:///var/run/docker.sock"]' "$(b '.spec.containers[0].args')"
assert_eq "the builder lands on the session nodes, so images match their CPU architecture" \
    '{"kubernetes.io/hostname":"n1","pool":"dev"}' "$(b '.spec.nodeSelector')"
assert_has "the builder trusts plain HTTP only for aidc's own registry" \
    "registry.aidc-system.svc.cluster.local:5050" "$(b '.spec.initContainers[0].command')"

: > "$K_LOG"
"$AIDC_ROOT/scripts/aidc" k8s build --force --only squid >/dev/null 2>&1
assert_has "--force builds an image even when it is present" "aidc/squid:${VERSION_TAG} -f /build/squid/Dockerfile" "$(cat "$K_LOG")"
assert_not_has "--only builds that role alone" "dev-base" "$(grep 'docker build' "$K_LOG")"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
