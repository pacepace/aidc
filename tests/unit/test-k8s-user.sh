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
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
case "$*" in
    *"get runtimeclass"*"-o json"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"apply -f -"*) cat >> "$K_APPLIED" ;;
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
out=$("$AIDC_ROOT/scripts/aidc" user remove alice 2>&1 </dev/null); rc=$?
assert_eq "an unknown subcommand exits 2" "2" "$rc"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
