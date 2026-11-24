#!/usr/bin/env bash
# Unit tests for Kubernetes sessions: k8s_render_session, `aidc create/kill --backend kubernetes`
# (scripts/k8s/session-*.sh) and the dispatcher's --backend switch.
#
# The rendered lockdown is the sandbox: a dev pod that could open anything but its own proxy,
# resolve names, reach the API or another session, or run privileged would escape it. kubectl
# is a PATH stub; HOME holds the config. Needs yq; skips without it.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-session-$$"
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

# kubectl stub: logs calls; apply appends stdin to $K_APPLIED.
#   get pvc disk            Bound unless K_NO_DISK=1
#   get deployment <s>-proxy  exists when K_EXISTS=1
#   get service ... clusterIP 10.45.9.9
#   logs ... -c dev           the ready marker
#   get deployment,statefulset -l   a row when K_EXISTS=1
#   get pvc -l                the session's home and audit claims
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
case "$*" in
    *"get runtimeclass"*"-o json"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"apply -f -"*) cat >> "$K_APPLIED" ;;
    *"get pvc disk"*) [ "${K_NO_DISK:-}" = 1 ] || printf 'Bound' ;;
    *"get deployment,statefulset -l"*) [ "${K_EXISTS:-}" = 1 ] && echo "deployment.apps/demo-proxy" ;;
    *"get deployment "*"-proxy"*) [ "${K_EXISTS:-}" = 1 ] || exit 1 ;;
    *"get service"*"clusterIP"*) printf '10.45.9.9' ;;
    *"logs "*"-c dev"*) echo '[aidc-user-main] ready (tmux running, sleeping forever)' ;;
    *"get pvc -l"*) printf 'persistentvolumeclaim/home-demo-dev-0\npersistentvolumeclaim/demo-audit\n' ;;
    *"get statefulset demo-dev -o json"*) [ "${K_EXISTS:-}" = 1 ] || exit 1
        echo '{"metadata":{"annotations":{"aidc/repo":"/home/alice/code/proj","aidc/profile":"multi"}}}' ;;
    *"get statefulset -l app=dev"*) [ "${K_EXISTS:-}" = 1 ] && printf 'demo\t1\tmulti\t2026-11-24T04:00:00Z\n' ;;
    *"get pod demo-dev-0 -o jsonpath"*) printf 'Running' ;;
    *"get pod -l"*"app=proxy"*) echo "pod/demo-proxy-abc" ;;
    *"exec pod/demo-proxy-abc -c policy -- cat /var/state/tainted"*) [ "${K_TAINTED:-}" = 1 ] && echo '{"trigger":"malware_domains"}' || exit 1 ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"

export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" K_LOG="$SCRATCH/kubectl.log" \
    K_APPLIED="$SCRATCH/applied.yaml" PATH="$SCRATCH/bin:$PATH"
cat > "$HOME/.config/aidc/config.yaml" <<'EOF'
kubernetes:
  context: lab
  user: alice
  storage_class: shared-disk
  session_storage_class: scratch
  memory_limit: 64Gi
  tolerations:
    - {key: role, operator: Equal, value: dev, effect: NoSchedule}
EOF
mkdir -p "$HOME/code/proj"
run() { : > "$K_APPLIED"; : > "$K_LOG"; (cd "$HOME/code/proj" && "$AIDC_ROOT/scripts/aidc" "$@" 2>&1 </dev/null); echo "exit=$?"; }
q() { yq -N ea "$1" -o=json -I=0 "$K_APPLIED"; }

echo "=== aidc create --backend kubernetes ==="
out=$(run create demo --backend kubernetes)
assert_has "a session is created and reported ready" "session demo is ready" "$out"
assert_has "exit 0" "exit=0" "$out"
assert_has "the repo under this machine's home maps to /home/<user> on the disk" \
    "repo /home/alice/code/proj" "$out"
assert_eq "everything goes in the user's namespace" "aidc-u-alice" \
    "$(q '.metadata.namespace' | sort -u | tr -d '"')"
assert_eq "every object carries the session label" "demo" \
    "$(q '.metadata.labels["aidc/session"]' | sort -u | tr -d '"')"

dev() { q "select(.kind == \"StatefulSet\") | $1" | tail -1; }
assert_eq "the dev pod runs under the runtime class, in a user namespace, with no API token" \
    '["sysbox-runc",false,false]' \
    "$(dev '.spec.template.spec | [.runtimeClassName, .hostUsers, .automountServiceAccountToken]')"
assert_eq "the dev pod has no cluster DNS" '["None",["192.0.2.1"]]' \
    "$(dev '.spec.template.spec | [.dnsPolicy, .dnsConfig.nameservers]')"
assert_has "the proxy settings carry its address, so inner containers can use them without DNS" \
    '{"name":"HTTPS_PROXY","value":"http://10.45.9.9:3128"}' "$(dev '.spec.template.spec.containers[0].env')"
assert_eq "every aidc image is pulled every time (a forced rebuild keeps its version tag)" "[]" \
    "$(q '[.. | select(has("image")) | select(.image | test("/aidc/")) | select(.imagePullPolicy != "Always")]' | sort -u | tail -1)"
assert_eq "the dev pod reaches its proxy by a fixed address, not by DNS" \
    '[{"ip":"10.45.9.9","hostnames":["aidc-proxy"]}]' "$(dev '.spec.template.spec.hostAliases')"
assert_eq "no container in the dev pod is privileged" "[]" \
    "$(dev '[.spec.template.spec.containers[] | select(.securityContext.privileged == true)]')"
assert_eq "session size: 2 CPU / 8Gi guaranteed, the configured ceiling" \
    '{"requests":{"cpu":"2","memory":"8Gi"},"limits":{"cpu":"16","memory":"64Gi"}}' \
    "$(dev '.spec.template.spec.containers[0].resources')"
assert_eq "the user's disk is mounted at /home/<user>, the home on its own volume" \
    '[{"name":"disk","mountPath":"/home/alice"},{"name":"home","mountPath":"/home/vscode"}]' \
    "$(dev '.spec.template.spec.containers[0].volumeMounts')"
assert_eq "the home volume is on the session storage class (deleted with the session)" '"scratch"' \
    "$(dev '.spec.volumeClaimTemplates[0].spec.storageClassName')"
assert_has "the inner Docker uses overlay2 (Sysbox gives it a real /var/lib/docker)" \
    '{"name":"AIDC_DOCKER_STORAGE_DRIVER","value":"overlay2"}' "$(dev '.spec.template.spec.containers[0].env')"
assert_eq "the repo folder is made as the session user" '[{"runAsUser":1000,"runAsGroup":1000},["mkdir","-p","/home/alice/code/proj"]]' \
    "$(dev '.spec.template.spec.initContainers[0] | [.securityContext, .command]')"

np() { q "select(.kind == \"NetworkPolicy\" and .metadata.name == \"$1\") | .spec" | tail -1; }
assert_eq "the dev pod may reach only its own session's proxy, on 3128" \
    '{"podSelector":{"matchLabels":{"aidc/session":"demo","app":"dev"}},"policyTypes":["Ingress","Egress"],"egress":[{"to":[{"podSelector":{"matchLabels":{"aidc/session":"demo","app":"proxy"}}}],"ports":[{"protocol":"TCP","port":3128}]}]}' \
    "$(np demo-dev-only-to-its-proxy)"
assert_eq "the proxy takes connections only from its own dev pod" \
    '[{"from":[{"podSelector":{"matchLabels":{"aidc/session":"demo","app":"dev"}}}],"ports":[{"protocol":"TCP","port":3128}]}]' \
    "$(np demo-proxy-public-only | yq -p=json -o=json -I=0 '.ingress')"
assert_eq "the proxy reaches public addresses only (no cluster, node, LAN or VPN range)" \
    '["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","127.0.0.0/8"]' \
    "$(np demo-proxy-public-only | yq -p=json -o=json -I=0 '.egress[1].to[0].ipBlock.except')"
assert_eq "the proxy's DNS is Quad9 only" '["9.9.9.9/32","149.112.112.112/32"]' \
    "$(np demo-proxy-public-only | yq -p=json -o=json -I=0 '[.egress[0].to[].ipBlock.cidr]')"
assert_eq "the proxy pod resolves through Quad9, the only DNS its policy allows (the refresher needs it for the blocklist feeds)" \
    '["None",["9.9.9.9","149.112.112.112"]]' \
    "$(q 'select(.kind == "Deployment") | .spec.template.spec | [.dnsPolicy, .dnsConfig.nameservers]' | tail -1)"
assert_eq "the audit volume is on the user's (retained) storage class" '"shared-disk"' \
    "$(q 'select(.kind == "PersistentVolumeClaim") | .spec.storageClassName' | tail -1)"
assert_has "the proxy pod seeds squid's folder before squid starts" "seed-squid-etc" \
    "$(q 'select(.kind == "Deployment") | .spec.template.spec.initContainers[].name' | tail -1)"
assert_has "images come from the cluster's registry at this version" "localhost:5000/aidc/dev-base:" \
    "$(dev '.spec.template.spec.containers[0].image')"

echo "=== create refusals ==="
out=$(K_NO_DISK=1 run create demo --backend kubernetes)
assert_has "no user disk: says to run aidc user add" "run \`aidc user add alice\` first" "$out"
out=$(K_EXISTS=1 run create demo --backend kubernetes)
assert_has "an existing session is refused" "session 'demo' already exists" "$out"
out=$(run create demo --backend kubernetes --repo /etc)
assert_has "a repo outside the home directory is refused" "the repo must be under your home directory" "$out"
out=$(run create demo --backend kubernetes --port 3000:3000)
assert_has "an option the backend does not have yet is refused by name" "not supported on the kubernetes backend yet: --port" "$out"

echo "=== aidc kill --backend kubernetes ==="
out=$(K_EXISTS=1 run kill demo --backend kubernetes)
log=$(cat "$K_LOG")
assert_has "kill removes the session's objects by its label" \
    "delete statefulset,deployment,service,networkpolicy -l aidc/session=demo" "$log"
assert_has "kill removes the home volume" "delete persistentvolumeclaim/home-demo-dev-0" "$log"
case "$log" in
    *"delete persistentvolumeclaim/demo-audit"*) echo "  FAIL: kill must keep the audit volume"; FAIL=$((FAIL + 1)) ;;
    *) echo "  PASS: kill keeps the audit volume"; PASS=$((PASS + 1)) ;;
esac
assert_has "and says where the audit is" "audit kept in volume claim demo-audit" "$out"
out=$(run kill demo --backend kubernetes)
assert_has "killing a session that does not exist says so" "no session 'demo'" "$out"

echo "=== the dispatcher's --backend switch ==="
out=$(run restart demo --backend kubernetes)
assert_has "a verb the backend does not have yet is refused" "not available on the kubernetes backend yet" "$out"
# A Docker verb must get exactly the arguments it would get without the flag.
cat > "$SCRATCH/bin/docker" <<'DSTUB'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$D_LOG"
exit 0
DSTUB
chmod +x "$SCRATCH/bin/docker"
export D_LOG="$SCRATCH/docker.log"
: > "$D_LOG"; run logs demo --component squid >/dev/null; plain=$(cat "$D_LOG")
: > "$D_LOG"; run logs demo --backend docker --component squid >/dev/null; flagged=$(cat "$D_LOG")
: > "$D_LOG"; run logs --backend=docker demo --component squid >/dev/null; flagged2=$(cat "$D_LOG")
assert_eq "--backend docker leaves a Docker verb's arguments as they were" "$plain" "$flagged"
assert_eq "--backend=docker, anywhere on the line, too" "$plain" "$flagged2"
assert_has "and the Docker verb really ran" "docker " "$plain"
out=$(run list --backend nonesuch)
assert_has "an unknown backend is refused" "unknown backend: nonesuch" "$out"

echo "=== routing by where the session lives (no --backend) ==="
: > "$D_LOG"; out=$(K_EXISTS=1 run logs demo --component squid)
assert_has "a session in the cluster gets the Kubernetes verb" "logs deployment/demo-proxy -c squid" "$(cat "$K_LOG")"
assert_eq "and Docker is not asked" "" "$(cat "$D_LOG")"
: > "$D_LOG"; out=$(run logs demo --component squid)
assert_has "a session not in the cluster goes to Docker" "docker " "$(cat "$D_LOG")"
out=$(K_EXISTS=1 run restart demo)
assert_has "a cluster session's verb the backend lacks says so" "not available on the kubernetes backend yet" "$out"
out=$(K_EXISTS=1 run kill demo)
assert_has "kill finds a cluster session without the flag" "session demo removed" "$out"

echo "=== the config's default backend for create ==="
printf 'backend: kubernetes\n' >> "$HOME/.config/aidc/config.yaml"
out=$(run create demo)
assert_has "backend: kubernetes in the config makes create use the cluster" "session demo is ready" "$out"
out=$(run create demo --backend docker --help)
assert_has "--backend docker still wins over the config" "aidc create" "$out"
sed -i '/^backend: kubernetes$/d' "$HOME/.config/aidc/config.yaml"

echo "=== list, attach, status, logs ==="
out=$(K_EXISTS=1 run list)
assert_has "list shows cluster sessions with their backend" "kubernetes" "$out"
assert_has "the cluster row names the session" "demo" "$out"
: > "$K_LOG"; run attach demo --backend kubernetes >/dev/null
assert_has "attach runs tmux as the session user in the dev container" \
    "exec -it demo-dev-0 -c dev -- sudo -u vscode -H env" "$(cat "$K_LOG")"
out=$(K_EXISTS=1 run status demo)
assert_has "status names the repo" "repo:     /home/alice/code/proj" "$out"
assert_has "status says the session is clean" "taint:    clean" "$out"
out=$(K_EXISTS=1 K_TAINTED=1 run status demo)
assert_has "status shows a taint" "taint:    TAINTED" "$out"
out=$(K_EXISTS=1 run logs demo --component nonesuch)
assert_has "an unknown component is refused by name" "unknown component: nonesuch" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
