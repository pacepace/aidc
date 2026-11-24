#!/usr/bin/env bash
# Unit tests for the git container (k8s_render_git, `aidc git setup|attach|status`).
#
# The git container holds the user's SSH key and GitHub login, so its manifest is a security
# boundary: a privileged pod, an API token, cluster DNS or a route to private addresses would
# let a key be walked to the cluster; a recreated home claim would lose the user's login.
# Status must never say "no" when the cluster or the container could not be asked. kubectl is
# a PATH stub; HOME holds the config. Needs yq; skips without it.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-git-$$"
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
assert_not_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  FAIL: $desc ('$needle' present in:"; printf '%s\n' "$hay" | tail -15 | sed 's/^/      /'
           echo "    )"; FAIL=$((FAIL + 1)) ;;
        *) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
    esac
}

# kubectl stub: logs calls; apply appends stdin to $K_APPLIED.
#   K_DOWN=1         every call fails as an unreachable cluster does
#   K_NO_DISK=1      the user has no disk claim
#   K_NO_POD=1       no running git pod (the Deployment exists unless K_NO_DEP=1)
#   K_EXEC_FAIL=1    exec into the git pod fails (container not ready, exec refused)
#   K_GH=yes|stored|no   what gh says inside (default no)
#   K_KEYS="id_ed25519"  the SSH keys in ~/.ssh (default none)
#   K_NO_GIT_POLICY=1    the git-egress policy is missing
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
[ "${K_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server: dial tcp: i/o timeout' >&2; exit 1; }
case "$*" in
    *"get runtimeclass"*"-o json"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"apply -f -"*) cat >> "$K_APPLIED" ;;
    *"rollout status"*) [ "${K_ROLLOUT_FAIL:-}" = 1 ] && { echo 'timed out' >&2; exit 1; } ;;
    *"get pvc disk"*)
        [ "${K_PVC_WARN:-}" = 1 ] && echo "Warning: client version skew" >&2
        [ "${K_NO_DISK:-}" = 1 ] || printf 'Bound' ;;
    *"get pod -l app=git"*)
        if [ "${K_NO_POD:-}" = 1 ]; then echo '{"items":[]}'
        else echo '{"items":[{"metadata":{"name":"git-old","deletionTimestamp":"2026-11-24T00:00:00Z"}},{"metadata":{"name":"git-7d9f-abc"}}]}'; fi ;;
    *"get deployment git"*) [ "${K_NO_DEP:-}" = 1 ] || echo "deployment.apps/git" ;;
    *"exec git-7d9f-abc -c git -- sh -c"*)
        [ "${K_EXEC_FAIL:-}" = 1 ] && { echo 'error: unable to upgrade connection' >&2; exit 1; }
        echo "github=${K_GH:-no}"; echo "ssh=${K_KEYS:-none}" ;;
    *"get networkpolicy -o name"*)
        echo "networkpolicy.networking.k8s.io/default-deny"
        [ "${K_NO_GIT_POLICY:-}" = 1 ] || echo "networkpolicy.networking.k8s.io/git-egress" ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"

export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" K_LOG="$SCRATCH/kubectl.log" \
    K_APPLIED="$SCRATCH/applied.yaml" PATH="$SCRATCH/bin:$PATH" TERM=xterm-test
cat > "$HOME/.config/aidc/config.yaml" <<'EOF'
kubernetes:
  context: lab
  user: alice
  storage_class: shared-disk
  session_storage_class: scratch
  tolerations:
    - {key: role, operator: Equal, value: dev, effect: NoSchedule}
EOF
run() { : > "$K_APPLIED"; : > "$K_LOG"; "$AIDC_ROOT/scripts/aidc" "$@" 2>&1 </dev/null; echo "exit=$?"; }
q() { yq -N ea "$1" -o=json -I=0 "$K_APPLIED"; }
VERSION_TAG=$(head -n1 "$AIDC_ROOT/VERSION" | tr '+' '_')

echo "=== aidc git setup: the manifest ==="
out=$(run git setup)
assert_has "setup reports the container ready" "the git container is ready" "$out"
assert_has "and exits 0" "exit=0" "$out"
assert_has "and points the user at attach to add their own secrets" "aidc git attach" "$out"
assert_eq "it applies the egress policy, the home claim and the Deployment, nothing else" \
    "NetworkPolicy/git-egress PersistentVolumeClaim/git-home Deployment/git" \
    "$(yq -N e '[.kind, .metadata.name] | join("/")' "$K_APPLIED" | paste -sd' ' -)"
assert_eq "everything goes in the user's namespace" "aidc-u-alice" "$(q '.metadata.namespace' | sort -u | tr -d '"')"
assert_has "it waits for the Deployment to be ready" "rollout status deployment/git" "$(cat "$K_LOG")"
dep() { q "select(.kind == \"Deployment\") | $1" | tail -1; }
pod() { dep ".spec.template.spec | $1"; }
assert_eq "one replica, replaced not rolled (two would share one home and race on repos)" '[1,"Recreate"]' \
    "$(dep '[.spec.replicas, .spec.strategy.type]')"
assert_eq "no API token, no service links, Quad9 DNS only" '[false,false,"None",["9.9.9.9","149.112.112.112"]]' \
    "$(pod '[.automountServiceAccountToken, .enableServiceLinks, .dnsPolicy, .dnsConfig.nameservers]')"
assert_eq "the git container runs as uid 2000, its own group, unprivileged, no capabilities" \
    '{"runAsUser":2000,"runAsGroup":2000,"runAsNonRoot":true,"privileged":false,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}' \
    "$(pod '.containers[] | select(.name == "git") | .securityContext')"
assert_eq "the pod adds the session group (1000) and the runtime's seccomp profile" \
    '{"supplementalGroups":[1000],"seccompProfile":{"type":"RuntimeDefault"}}' "$(pod '.securityContext')"
assert_eq "no container or init container is privileged" "[]" \
    "$(pod '[(.containers[], .initContainers[]) | select(.securityContext.privileged == true)]')"
assert_eq "the root init step keeps only the capabilities a copy and chown need" \
    '{"runAsUser":0,"runAsGroup":0,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"],"add":["CHOWN","FOWNER","DAC_OVERRIDE"]}}' \
    "$(pod '.initContainers[] | select(.name == "seed-home") | .securityContext')"
assert_has "a new home is seeded from the image only once, owned by the git user, private" \
    "[ -e /seed/.profile ] || cp -a /home/git/. /seed/; chown 2000:2000 /seed && chmod 0700 /seed" \
    "$(pod '.initContainers[] | select(.name == "seed-home") | .command')"
assert_eq "it lands where sessions land, with their tolerations" \
    '[{"kubernetes.io/hostname":"n1"},[{"key":"role","operator":"Equal","value":"dev","effect":"NoSchedule"}]]' \
    "$(pod '[.nodeSelector, .tolerations]')"
assert_eq "its image is aidc's gitctl from the in-cluster registry, pulled every time" \
    "[\"localhost:5000/aidc/gitctl:${VERSION_TAG}\",\"Always\"]" \
    "$(pod '.containers[] | select(.name == "git") | [.image, .imagePullPolicy]')"
assert_eq "every aidc image in it is pulled every time" "[]" \
    "$(pod '[(.containers[], .initContainers[]) | select(.imagePullPolicy != "Always")]')"
assert_eq "the user's disk at /home/<user> (one path everywhere), its own home at /home/git" \
    '[{"name":"disk","mountPath":"/home/alice"},{"name":"home","mountPath":"/home/git"}]' \
    "$(pod '.containers[] | select(.name == "git") | .volumeMounts')"
assert_eq "the volumes are the user's disk claim and the git-home claim" \
    '[{"name":"disk","persistentVolumeClaim":{"claimName":"disk"}},{"name":"home","persistentVolumeClaim":{"claimName":"git-home"}}]' \
    "$(pod '.volumes')"
assert_eq "the home claim (the user's secrets) is on the user's retained class, not the session one" \
    '"shared-disk"' "$(q 'select(.kind == "PersistentVolumeClaim") | .spec.storageClassName')"
assert_eq "it is ready only when its tmux session is up" '["tmux","has-session","-t","main"]' \
    "$(pod '.containers[] | select(.name == "git") | .readinessProbe.exec.command')"
assert_eq "the egress policy, exactly: no ingress; Quad9 DNS; public addresses only" \
    '{"podSelector":{"matchLabels":{"app":"git"}},"policyTypes":["Ingress","Egress"],"egress":[{"to":[{"ipBlock":{"cidr":"9.9.9.9/32"}},{"ipBlock":{"cidr":"149.112.112.112/32"}}],"ports":[{"protocol":"UDP","port":53},{"protocol":"TCP","port":53}]},{"to":[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","127.0.0.0/8"]}}]}]}' \
    "$(q 'select(.kind == "NetworkPolicy") | .spec')"
assert_eq "the policy selects exactly the pods the Deployment makes" '"git"' \
    "$(dep '.spec.template.metadata.labels.app')"
assert_has "every kubectl call uses the configured context" "--context lab apply" "$(cat "$K_LOG")"

echo "=== aidc git setup: run again ==="
first=$(cat "$K_APPLIED")
out=$(run git setup)
assert_has "a second setup succeeds" "exit=0" "$out"
assert_eq "it applies the same manifests (apply leaves what is right alone)" "$first" "$(cat "$K_APPLIED")"
assert_not_has "and deletes nothing (the home claim holds the user's secrets)" " delete " "$(cat "$K_LOG")"

echo "=== aidc git setup: failures ==="
out=$(K_NO_DISK=1 run git setup)
assert_has "no disk: says to add the user first" "run \`aidc user add alice\` first" "$out"
assert_has "and exits 1" "exit=1" "$out"
assert_not_has "and applies nothing" "apply" "$(cat "$K_LOG")"
out=$(K_DOWN=1 run git setup)
assert_has "a cluster that does not answer is said so, not 'no disk'" "the cluster did not answer" "$out"
assert_not_has "and is not reported as a missing user" "aidc user add" "$out"
out=$(K_PVC_WARN=1 run git setup)
assert_has "a kubectl warning on a disk read that worked is not 'no disk'" "exit=0" "$out"
assert_not_has "and does not send the user to add a disk" "aidc user add" "$out"
out=$(K_ROLLOUT_FAIL=1 run git setup)
assert_has "a container that never gets ready is reported with where to look" "did not become ready" "$out"
assert_has "and exits 1" "exit=1" "$out"
out=$(run git setup extra)
assert_has "setup takes no arguments" "takes no arguments" "$out"
out=$("$AIDC_ROOT/scripts/aidc" git frobnicate 2>&1 </dev/null); rc=$?
assert_eq "an unknown subcommand exits 2" "2" "$rc"

echo "=== aidc git attach ==="
out=$(run git attach)
assert_has "attach opens the running pod's tmux as the container's own user, with the caller's terminal" \
    "--context lab -n aidc-u-alice exec -it git-7d9f-abc -c git -- env TERM=xterm-test tmux attach -d -t main" "$(cat "$K_LOG")"
assert_not_has "it never attaches to a pod that is being replaced" "git-old" "$(grep ' exec ' "$K_LOG")"
out=$(K_NO_POD=1 run git attach)
assert_has "no running container: says to set it up" "run \`aidc git setup\`" "$out"
assert_has "and exits 1" "exit=1" "$out"
out=$(K_DOWN=1 run git attach)
assert_has "a cluster that does not answer is said so" "the cluster did not answer" "$out"

echo "=== aidc git status ==="
out=$(K_GH=yes K_KEYS="id_ed25519" run git status)
assert_has "the running pod is named" "pod:      git-7d9f-abc, running" "$out"
assert_has "a confirmed GitHub login is yes" "github:   logged in" "$out"
assert_has "an SSH key is named" "ssh key:  yes (id_ed25519)" "$out"
assert_has "the egress policy is reported enforced" "egress:   enforced" "$out"
out=$(run git status)
assert_has "no login is no, with what to do" "github:   not logged in (aidc git attach" "$out"
assert_has "no key is none, with what to do" "ssh key:  none (aidc git attach" "$out"
out=$(K_GH=stored run git status)
assert_has "a stored login GitHub did not confirm is unknown, not no" \
    "github:   unknown (a login is stored, but GitHub did not confirm it)" "$out"
out=$(K_EXEC_FAIL=1 run git status)
assert_has "a container that cannot be asked: login unknown" "github:   unknown" "$out"
assert_has "a container that cannot be asked: key unknown" "ssh key:  unknown" "$out"
assert_not_has "and never 'not logged in'" "not logged in" "$out"
assert_not_has "and never 'none'" "ssh key:  none" "$out"
out=$(K_DOWN=1 run git status)
assert_has "a cluster that does not answer: pod unknown" "pod:      unknown" "$out"
assert_has "login unknown" "github:   unknown" "$out"
assert_has "key unknown" "ssh key:  unknown" "$out"
assert_has "egress unknown, not 'not enforced'" "egress:   unknown" "$out"
assert_not_has "never 'not set up'" "not set up" "$out"
out=$(K_NO_POD=1 run git status)
assert_has "a Deployment with no running pod says not running" "pod:      not running" "$out"
out=$(K_NO_POD=1 K_NO_DEP=1 run git status)
assert_has "no Deployment says not set up, with the command" "pod:      not set up (run: aidc git setup)" "$out"
out=$(K_NO_GIT_POLICY=1 run git status)
assert_has "a missing egress policy is reported loudly" "NOT ENFORCED: NetworkPolicy missing: git-egress" "$out"

echo "=== aidc user add offers it ==="
out=$(run user add bob)
assert_has "user add ends with the git setup hint" "runs \`aidc git setup\`" "$out"

echo "=== the image ==="
inv=$(AIDC_ROOT="$AIDC_ROOT" AIDC_VERSION_TAG=vtest bash -c '. "$AIDC_ROOT/scripts/lib/common.sh"; aidc_image_inventory')
assert_has "gitctl is in the image inventory, so aidc k8s build builds it" \
    "aidc/gitctl:vtest|$AIDC_ROOT/gitctl|$AIDC_ROOT/gitctl/Dockerfile" "$inv"
df="$AIDC_ROOT/gitctl/Dockerfile"
assert_eq "the gh download is checked against a pinned checksum" "1" "$(grep -c 'sha256sum -c' "$df")"
assert_eq "gh is pinned to a version, not latest" "1" "$(grep -cE '^ARG GH_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$df")"
assert_has "the git user is uid 2000, own group, in the session group" \
    "useradd -m -u 2000 -g 2000 -G session" "$(cat "$df")"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
