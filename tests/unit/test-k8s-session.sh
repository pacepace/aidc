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
assert_not_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  FAIL: $desc ('$needle' present in:"; printf '%s\n' "$hay" | tail -15 | sed 's/^/      /'
           echo "    )"; FAIL=$((FAIL + 1)) ;;
        *) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
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
    *"get pvc disk"*) [ "${K_READ_FAIL:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        [ -n "${K_DISK_PHASE:-}" ] && { printf '%s' "$K_DISK_PHASE"; exit 0; }
        [ "${K_NO_DISK:-}" = 1 ] || printf 'Bound' ;;
    *"get deployment,statefulset -l aidc/session=git"*) [ "${K_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        [ "${K_GIT:-}" = 1 ] && echo "deployment.apps/git" ;;
    *"get deployment,statefulset -l"*) [ "${K_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        [ "${K_EXISTS:-}" = 1 ] && echo "deployment.apps/demo-proxy" ;;
    *"get deployment -l app=git,aidc/session=git"*) [ "${K_GIT:-}" = 1 ] && printf '1\t2026-11-24T03:00:00Z\n' ;;
    *"get pod -l app=git"*) echo '{"items":[{"metadata":{"name":"git-7d9f-abc"}}]}' ;;
    *"get deployment "*"-proxy"*) [ "${K_READ_FAIL:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        [ "${K_EXISTS:-}" = 1 ] && echo "deployment.apps/demo-proxy" ;;
    *"get service"*"clusterIP"*) printf '10.45.9.9' ;;
    *"logs "*"-c dev"*) echo '[aidc-user-main] ready (tmux running, sleeping forever)' ;;
    *"get pvc -l"*"aidc/kept=audit"*) echo "persistentvolumeclaim/demo-audit-20261124050000" ;;
    *"get statefulset demo-dev -o json"*) [ "${K_EXISTS:-}" = 1 ] || exit 1
        if [ "${K_SIZED:-}" = 1 ]; then
            echo '{"metadata":{"annotations":{"aidc/repo":"/home/alice/code/proj"}},"spec":{"template":{"spec":{"containers":[{"name":"dev","resources":{"requests":{"cpu":"4","memory":"12Gi"},"limits":{"cpu":"16","memory":"32Gi"}}}]}}}}'
        else
            echo '{"metadata":{"annotations":{"aidc/repo":"/home/alice/code/proj","aidc/profile":"multi","aidc/audit":"demo-audit-20261124050000"}}}'
        fi ;;
    *"get statefulset -l app=dev"*) [ "${K_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        [ "${K_EXISTS:-}" = 1 ] && printf 'demo\t1\tmulti\t2026-11-24T04:00:00Z\n' ;;
    *"get pod demo-dev-0 --ignore-not-found -o jsonpath={.metadata.uid}"*)
        # The dev pod's uid: "old" until the pod is deleted or rolled, then "new" (K_UID_FILE).
        cat "$K_UID_FILE" 2>/dev/null || printf 'old' ;;
    *"delete pod demo-dev-0"*|*"rollout restart statefulset/demo-dev"*) [ "${K_NEVER_BACK:-}" = 1 ] || printf 'new' > "$K_UID_FILE" ;;
    *"get pod demo-dev-0 -o jsonpath={.spec.containers"*) printf '%s' "${K_POD_IMAGE:-localhost:5000/aidc/dev-base:$(head -n1 "$AIDC_ROOT_FOR_STUB/VERSION")}" ;;
    *"get statefulset demo-dev"*"jsonpath"*) printf 'localhost:5000/aidc/dev-base:v0.0.1' ;;
    *"exec pod/demo-proxy-abc -c refresher -- /usr/local/bin/refresh.sh"*) echo "refreshed: 9 entries from urlhaus=4 hagezi=5 additions=0 (took 1s)" ;;
    *"exec -i demo-dev-0 -c dev -- sudo -u vscode -H env HOME=/home/vscode sh -c"*) : ;;
    *"get pod demo-dev-0 -o jsonpath"*) printf 'Running' ;;
    *"get pod -l"*"app=proxy"*) echo "pod/demo-proxy-abc" ;;
    *"exec pod/demo-proxy-abc -c policy -- sh -c"*)
        [ "${K_POLICY_DOWN:-}" = 1 ] && { echo 'error: container not found' >&2; exit 1; }
        if [ "${K_TAINTED:-}" = 1 ]; then echo 'yes {"trigger":"malware_domains"}'; else echo no; fi ;;
    *"exec pod/demo-proxy-abc -c audit -- /usr/local/bin/finalize.sh"*) : ;;
    *"exec pod/demo-proxy-abc -c audit -- sh -c du -sk /var/aidc/audit"*) printf '2048\nyes\n' ;;
    *"get networkpolicy default-deny"*) [ "${K_READ_FAIL:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        [ "${K_NO_DENY:-}" = 1 ] || echo "networkpolicy.networking.k8s.io/default-deny" ;;
    *"get pods -l"*) [ "${K_STATUS_READS_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        printf '  NAME   READY   STATUS\n  demo-dev-0   true   Running\n' ;;
    *"get networkpolicy -o name"*) [ "${K_STATUS_READS_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        printf 'networkpolicy.networking.k8s.io/default-deny\nnetworkpolicy.networking.k8s.io/demo-dev-only-to-its-proxy\nnetworkpolicy.networking.k8s.io/demo-proxy-public-only\n' ;;
    *"create configmap"*) printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: demo-audit-seed}\ndata: {meta.json: "{}"}\n' ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"

export K_UID_FILE="$SCRATCH/dev-uid" AIDC_ROOT_FOR_STUB="$AIDC_ROOT" AIDC_K8S_READY_WAIT=4
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
# A mount naming a volume the pod does not declare makes the API server reject the whole pod,
# so every session create would fail.
assert_eq "every volume mount in every rendered pod names a volume the pod declares" "" \
    "$(yq -N ea 'select(.kind == "Deployment" or .kind == "Pod" or .kind == "StatefulSet") | (.spec.template.spec // .spec) as $p | ([($p.containers[], $p.initContainers[]?) | .volumeMounts[]?.name] - [$p.volumes[]?.name]) | .[]' "$K_APPLIED" | sort -u | paste -sd' ' -)"
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
pvc() { q "select(.kind == \"PersistentVolumeClaim\" and .metadata.name == \"$1\") | .spec.storageClassName" | tail -1; }
assert_eq "the home volume is on the session storage class (deleted with the session)" '"scratch"' "$(pvc demo-home)"
assert_eq "the taint flag's volume outlives the proxy pod, on the session class" '"scratch"' "$(pvc demo-state)"
assert_eq "the proxy pod keeps the taint flag on that volume, not in pod scratch space" \
    '{"name":"state","persistentVolumeClaim":{"claimName":"demo-state"}}' \
    "$(q 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "state")' | tail -1)"
assert_has "the audit sidecar reads the session home (shell history, Claude transcripts)" \
    '{"name":"home","mountPath":"/var/aidc/dev-home","readOnly":true}' \
    "$(q 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "audit") | .volumeMounts' | tail -1)"
assert_has "the audit record starts with meta.json and the config snapshot" "seed-audit" \
    "$(q 'select(.kind == "Deployment") | [.spec.template.spec.initContainers[].name]' | tail -1)"
audit_claim=$(q 'select(.kind == "PersistentVolumeClaim" and .metadata.labels["aidc/kept"] == "audit") | .metadata.name' | tail -1 | tr -d '"')
case "$audit_claim" in
    demo-audit-[0-9]*) echo "  PASS: the audit claim is named for its creation time ($audit_claim)"; PASS=$((PASS + 1)) ;;
    *) echo "  FAIL: the audit claim is named for its creation time (got '$audit_claim')"; FAIL=$((FAIL + 1)) ;;
esac
assert_has "the session's squid refuses private destinations itself, as its NetworkPolicy does" \
    '{"name":"AIDC_PUBLIC_ONLY","value":"1"}' \
    "$(q 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "squid") | .env' | tail -1)"
assert_has "and resolves through squid.conf's Quad9 pair (no DNS override, which public-only refuses)" \
    '{"name":"AIDC_DNS_SERVERS","value":""}' \
    "$(q 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "squid") | .env' | tail -1)"
assert_eq "the proxy pod has resource requests (not first in line for eviction)" '{"cpu":"100m","memory":"256Mi"}' \
    "$(q 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "squid") | .resources.requests' | tail -1)"
assert_has "the inner Docker uses overlay2 (Sysbox gives it a real /var/lib/docker)" \
    '{"name":"AIDC_DOCKER_STORAGE_DRIVER","value":"overlay2"}' "$(dev '.spec.template.spec.containers[0].env')"
assert_has "the session's gh stand-in is told the git container's request folder" \
    '{"name":"AIDC_GIT_REQUESTS","value":"/home/alice/.aidc/git-requests"}' "$(dev '.spec.template.spec.containers[0].env')"
assert_has "and the session knows it is on Kubernetes (group-writable files, for the git container's tidy)" \
    '{"name":"AIDC_BACKEND","value":"kubernetes"}' "$(dev '.spec.template.spec.containers[0].env')"
assert_has "a new session home starts as a copy of the image's (Claude Code lives there), owned by the session user" \
    "cp -a /home/vscode/. /seed/; chown 1000:1000 /seed" "$(dev '[.spec.template.spec.initContainers[] | select(.name == "seed-home") | .command]')"
assert_eq "the repo folder is made as the session user" '[{"runAsUser":1000,"runAsGroup":1000},["mkdir","-p","/home/alice/code/proj"]]' \
    "$(dev '.spec.template.spec.initContainers[] | select(.name == "repo-dir") | [.securityContext, .command]')"

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
assert_eq "the audit volume is on the user's (retained) storage class" '"shared-disk"' "$(pvc "$audit_claim")"
assert_has "the proxy pod seeds squid's folder before squid starts" "seed-squid-etc" \
    "$(q 'select(.kind == "Deployment") | .spec.template.spec.initContainers[].name' | tail -1)"
assert_has "images come from the cluster's registry at this version" "localhost:5000/aidc/dev-base:" \
    "$(dev '.spec.template.spec.containers[0].image')"

echo "=== session size at create (K8S-19) ==="
res() { dev '.spec.template.spec.containers[] | select(.name == "dev") | .resources'; }
out=$(run create demo --backend kubernetes --cpu 4 --memory 12Gi)
assert_eq "--cpu and --memory set what the session is guaranteed; the limits stay the configured ones" \
    '{"requests":{"cpu":"4","memory":"12Gi"},"limits":{"cpu":"16","memory":"64Gi"}}' "$(res)"
assert_has "create says the size" "size: 4 CPU / 12Gi guaranteed, up to 16 / 64Gi" "$out"
run create demo --backend kubernetes --cpu=500m --memory=512Mi --cpu-limit=2 --memory-limit=1Gi >/dev/null
assert_eq "every flag, in its --flag=value form too" \
    '{"requests":{"cpu":"500m","memory":"512Mi"},"limits":{"cpu":"2","memory":"1Gi"}}' "$(res)"
out=$(run create demo --backend kubernetes --cpu 24)
assert_eq "a request above the configured limit raises the limit to it" \
    '{"requests":{"cpu":"24","memory":"8Gi"},"limits":{"cpu":"24","memory":"64Gi"}}' "$(res)"
assert_has "and says so" "--cpu 24 is above the configured limit 16: the limit is 24 too" "$out"
out=$(run create demo --backend kubernetes --memory 2Gi --memory-limit 1Gi)
assert_has "a request above a limit given with it is refused" "the memory request (2Gi) is above its limit (1Gi)" "$out"
assert_eq "and nothing is applied" "" "$(cat "$K_APPLIED")"
for bad in "--cpu two" "--cpu 0" "--memory 8gb" "--memory -1" "--cpu-limit 1.23456" "--memory"; do
    # shellcheck disable=SC2086  # the flag and its value, split on purpose
    out=$(run create demo --backend kubernetes $bad)
    assert_has "'$bad' is refused before anything is made" "exit=1" "$out"
    assert_eq "  (nothing applied for '$bad')" "" "$(cat "$K_APPLIED")"
done
out=$(run create demo --backend kubernetes --cpu 2.5)
assert_eq "a fractional CPU count is taken as Kubernetes writes it" '"2.5"' "$(dev '.spec.template.spec.containers[] | select(.name == "dev") | .resources.requests.cpu')"
printf '  cpu: lots\n' >> "$HOME/.config/aidc/config.yaml"
out=$(run create demo --backend kubernetes)
assert_has "a bad size in the config is refused by name too" "cpu request lots is not a quantity" "$out"
sed -i '/^  cpu: lots$/d' "$HOME/.config/aidc/config.yaml"
out=$(K_EXISTS=1 K_SIZED=1 run status demo)
assert_has "status shows the session's size" "size:     4 CPU / 12Gi guaranteed, up to 16 / 32Gi" "$out"

printf 'claude_mode: safe\ntaint_response: notify\n' >> "$HOME/.config/aidc/config.yaml"
run create demo --backend kubernetes >/dev/null
assert_has "the user's config reaches the session (claude_mode)" '{"name":"AIDC_CLAUDE_MODE","value":"safe"}' \
    "$(dev '.spec.template.spec.containers[0].env')"
assert_has "and the policy sidecar (taint_response)" '{"name":"AIDC_TAINT_RESPONSE","value":"notify"}' \
    "$(q 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "policy") | .env' | tail -1)"
sed -i '/^claude_mode: safe$/d; /^taint_response: notify$/d' "$HOME/.config/aidc/config.yaml"

echo "=== create refusals ==="
out=$(K_NO_DENY=1 run create demo --backend kubernetes)
assert_has "a namespace without its default-deny is refused, with the fix" "run \`aidc user add alice\` again" "$out"
out=$(run create 9lives --backend kubernetes)
assert_has "a name a Kubernetes Service cannot take is refused" "starts with a letter" "$out"
assert_eq "and nothing was applied for it" "" "$(cat "$K_APPLIED")"
out=$(K_NO_DISK=1 run create demo --backend kubernetes)
assert_has "no user disk: says to run aidc user add" "run \`aidc user add alice\` first" "$out"
out=$(K_DISK_PHASE=Pending run create demo --backend kubernetes)
assert_has "a disk that is not bound yet is said as such, not as missing" "your disk in aidc-u-alice is Pending" "$out"
out=$(K_READ_FAIL=1 run create demo --backend kubernetes)
assert_has "a cluster that does not answer the disk read is said so, never 'no disk'" "cannot read your disk in aidc-u-alice: the cluster did not answer" "$out"
assert_not_has "and not taken for a missing disk" "aidc user add" "$out"
assert_has "and create stops" "exit=1" "$out"
assert_eq "applying nothing" "" "$(cat "$K_APPLIED")"
# The disk read answers, the next ones do not: each read is checked on its own.
cat > "$SCRATCH/bin/kubectl-wrap" <<'WRAP'
#!/bin/sh
case "$*" in *"get pvc disk"*) printf 'Bound'; exit 0 ;; esac
case "$*" in *"get ${K_FAIL_WHAT:-none} "*) echo 'Unable to connect to the server' >&2; exit 1 ;; esac
exec "$(dirname "$0")/kubectl.real" "$@"
WRAP
mv "$SCRATCH/bin/kubectl" "$SCRATCH/bin/kubectl.real"; mv "$SCRATCH/bin/kubectl-wrap" "$SCRATCH/bin/kubectl"; chmod +x "$SCRATCH/bin/kubectl"
out=$(K_FAIL_WHAT="networkpolicy default-deny" run create demo --backend kubernetes)
assert_has "a failed default-deny read is 'did not answer', never 'has no default-deny'" "cannot read the default-deny NetworkPolicy in aidc-u-alice: the cluster did not answer" "$out"
assert_not_has "(not the missing-policy advice)" "has no default-deny" "$out"
out=$(K_FAIL_WHAT="deployment demo-proxy" run create demo --backend kubernetes)
assert_has "a failed read of the session is 'did not answer', and creates nothing" "cannot read session 'demo' in aidc-u-alice: the cluster did not answer" "$out"
assert_eq "nothing applied" "" "$(cat "$K_APPLIED")"
mv "$SCRATCH/bin/kubectl.real" "$SCRATCH/bin/kubectl"
out=$(K_EXISTS=1 run create demo --backend kubernetes)
assert_has "an existing session is refused" "session 'demo' already exists" "$out"
out=$(: > "$K_APPLIED"; cd / && "$AIDC_ROOT/scripts/aidc" create demo --backend kubernetes 2>&1 </dev/null; echo "exit=$?")
assert_has "a create run outside the home directory is refused (the session starts at the same place on the disk)" \
    "run aidc create from under your home directory" "$out"
assert_eq "and applies nothing" "" "$(cat "$K_APPLIED")"
out=$(run create demo --backend kubernetes --port 3000:3000)
assert_has "an option the backend does not have yet is refused by name" "not supported on the kubernetes backend yet: --port" "$out"

echo "=== aidc kill --backend kubernetes ==="
out=$(K_EXISTS=1 run kill demo --backend kubernetes)
log=$(cat "$K_LOG")
assert_has "kill finalizes the audit first (last sweep, killed_at)" "exec pod/demo-proxy-abc -c audit -- /usr/local/bin/finalize.sh" "$log"
assert_has "kill removes the session's objects by its label" \
    "delete statefulset,deployment,service,networkpolicy,configmap -l aidc/session=demo" "$log"
assert_has "kill removes the session's volumes except the kept audit" "delete pvc -l aidc/session=demo,aidc/kept!=audit" "$log"
assert_has "and says where the audit is" "its audit trail is kept in demo-audit-20261124050000" "$out"
finalize_line=$(grep -n 'finalize.sh' "$K_LOG" | head -n1 | cut -d: -f1)
delete_line=$(grep -n 'delete statefulset' "$K_LOG" | head -n1 | cut -d: -f1)
assert_eq "the audit is finalized before anything is deleted" "yes" "$([ "${finalize_line:-99}" -lt "${delete_line:-0}" ] && echo yes)"
annotate=$(grep 'annotate persistentvolumeclaim/demo-audit-20261124050000' "$K_LOG")
assert_has "kill records the trail's size after the final sweep on the kept claim" "aidc/size-bytes=2097152" "$annotate"
assert_has "and whether the session was tainted" "aidc/tainted=yes" "$annotate"
assert_has "and when it was killed" "aidc/killed-at=20" "$annotate"
annotate_line=$(grep -n 'annotate persistentvolumeclaim' "$K_LOG" | head -n1 | cut -d: -f1)
assert_eq "the size is measured after the final sweep" "yes" "$([ "${finalize_line:-99}" -lt "${annotate_line:-0}" ] && echo yes)"
out=$(run kill demo --backend kubernetes)
assert_has "killing a session that does not exist says so" "no session 'demo'" "$out"

echo "=== restart, upgrade and refresh on Kubernetes ==="
rm -f "$K_UID_FILE"
out=$(K_EXISTS=1 run restart demo)
assert_has "restart finds a cluster session without the flag and replaces its dev pod" "delete pod demo-dev-0" "$(cat "$K_LOG")"
assert_has "and waits until a NEW pod says it is ready" "session demo is back" "$out"
assert_has "exit 0" "exit=0" "$out"
assert_not_has "the proxy is not touched" "proxy" "$(grep -E 'delete|rollout|set image' "$K_LOG")"
rm -f "$K_UID_FILE"
out=$(K_EXISTS=1 K_NEVER_BACK=1 run restart demo)
assert_has "a pod that never comes back is an error, with where to look" "did not come back ready in 4s; see: kubectl -n aidc-u-alice describe pod demo-dev-0" "$out"
assert_has "exit 1" "exit=1" "$out"
out=$(run restart demo --backend kubernetes)
assert_has "restart of a session that is not there says so" "no session 'demo'" "$out"
out=$(K_GIT=1 run restart git --backend kubernetes)
assert_has "the git agent is not restarted as a session" "not a session aidc restart manages" "$out"

rm -f "$K_UID_FILE"
ver=$(head -n1 "$AIDC_ROOT/VERSION")
out=$(K_EXISTS=1 run upgrade demo --yes)
log=$(cat "$K_LOG")
assert_has "upgrade points the dev pod and its init containers at this version's image" \
    "set image statefulset/demo-dev dev=localhost:5000/aidc/dev-base:${ver} seed-home=localhost:5000/aidc/dev-base:${ver} repo-dir=localhost:5000/aidc/dev-base:${ver}" "$log"
assert_has "and rolls it, so the pod is new even under the same tag" "rollout restart statefulset/demo-dev" "$log"
assert_has "it shows the image it replaces" "current image: localhost:5000/aidc/dev-base:v0.0.1" "$out"
assert_has "and says it is done once the new pod is ready on that image" "upgraded demo to localhost:5000/aidc/dev-base:${ver}" "$out"
assert_has "testament: not configured is one line, and the upgrade goes on" "testament: not configured" "$out"
assert_has "exit 0" "exit=0" "$out"
rm -f "$K_UID_FILE"
out=$(K_EXISTS=1 K_POD_IMAGE=localhost:5000/aidc/dev-base:v0.0.1 run upgrade demo --yes)
assert_has "a pod that came back on another image is an error" "came back on localhost:5000/aidc/dev-base:v0.0.1" "$out"
rm -f "$K_UID_FILE"
out=$(: > "$K_APPLIED"; : > "$K_LOG"; cd "$HOME/code/proj" && printf 'n\n' | K_EXISTS=1 "$AIDC_ROOT/scripts/aidc" upgrade demo 2>&1; echo "exit=$?")
assert_has "without --yes it asks, and n aborts" "aborted" "$out"
assert_not_has "changing nothing" "set image" "$(cat "$K_LOG")"
out=$(K_GIT=1 run upgrade git --yes --backend kubernetes)
assert_has "the git agent is not upgraded as a session" "not a session aidc upgrade manages" "$out"

out=$(K_EXISTS=1 run refresh demo)
assert_has "refresh runs the refresher's one-shot refresh in the proxy pod" "exec pod/demo-proxy-abc -c refresher -- /usr/local/bin/refresh.sh" "$(cat "$K_LOG")"
assert_has "and shows what it loaded" "refreshed: 9 entries" "$out"
out=$(K_GIT=1 run refresh git --backend kubernetes)
assert_has "the git agent has no blocklist to refresh" "no proxy and no blocklist" "$out"

echo "=== the dispatcher's --backend switch ==="
out=$(run network demo --backend kubernetes)
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
out=$(K_EXISTS=1 run network demo)
assert_has "a cluster session's verb the backend lacks says so" "not available on the kubernetes backend yet" "$out"
out=$(K_EXISTS=1 run kill demo)
assert_has "kill finds a cluster session without the flag" "session demo removed" "$out"

: > "$D_LOG"; out=$(K_DOWN=1 run logs demo --component squid)
assert_has "an unreachable cluster is said, not taken for 'no such session'" "the configured cluster did not answer" "$out"
assert_has "and the verb falls back to Docker" "docker " "$(cat "$D_LOG")"
out=$(K_DOWN=1 run list --backend kubernetes)
assert_has "list says the cluster did not answer instead of 'no sessions'" "the cluster did not answer" "$out"

for verb in kill status attach; do
    out=$(K_DOWN=1 run "$verb" demo --backend kubernetes)
    assert_has "$verb: an unreachable cluster is said as such, never 'no such session'" \
        "the cluster did not answer" "$out"
done

echo "=== the git agent: a session under a reserved name ==="
out=$(run create git --backend kubernetes)
assert_has "no session may be named git (the git agent's name; its claims would collide)" "'git' is reserved for your git agent" "$out"
assert_eq "and nothing is applied" "" "$(cat "$K_APPLIED")"
out=$(run create demo --backend kubernetes)
tok=$(yq -N ea 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "dev") | .env[] | select(.name == "AIDC_GIT_TOKEN") | .value' "$K_APPLIED" | sort -u)
assert_eq "each session gets one token of its own (64 hex), the same in both renders" yes \
    "$(printf '%s' "$tok" | grep -Eqx '[0-9a-f]{64}' && echo yes || echo no)"
out=$(run create demo --backend kubernetes)
tok2=$(yq -N ea 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "dev") | .env[] | select(.name == "AIDC_GIT_TOKEN") | .value' "$K_APPLIED" | sort -u)
assert_eq "and a new session a new one" yes "$([ -n "$tok2" ] && [ "$tok" != "$tok2" ] && echo yes || echo no)"
assert_has "create registers the session's token with the git container, on stdin" \
    "exec -i git-7d9f-abc -c git -- git-requests register demo" "$(cat "$K_LOG")"
assert_not_has "never on a command line" "$tok2" "$(cat "$K_LOG")"
assert_has "and says so" "session demo registered" "$out"
out=$(K_EXISTS=1 run kill demo --backend kubernetes)
assert_has "kill has the git container forget the session (its token and mode)" \
    "exec git-7d9f-abc -c git -- git-requests forget demo" "$(cat "$K_LOG")"

echo "=== the session's git identity: the user's, as on Docker ==="
# The commits the git container pushes for a session show as the user: create bridges this
# machine's git identity (git config user.name and user.email), as Docker's aidc create does.
idenv() { yq -N ea 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "dev") | .env[] | select(.name == "'"$1"'") | .value' "$K_APPLIED" | sort -u; }
git config --global user.name "Alice \"Al\" O'Neil \\ Example"
git config --global user.email alice@example.com
out=$(run create demo --backend kubernetes)
assert_eq "the session pod gets the user's name, quoting and all" "Alice \"Al\" O'Neil \\ Example" "$(idenv AIDC_GIT_USER_NAME)"
assert_eq "and email" "alice@example.com" "$(idenv AIDC_GIT_USER_EMAIL)"
assert_has "and create says which identity" "git identity: Alice" "$out"
# The session's entrypoint (the same image on both backends) writes them with git config, so
# git reads back exactly that name: its function, run here on a file of the test's.
eval "$(sed -n '/^write_git_identity() {/,/^}/p' "$AIDC_ROOT/.devcontainer/entrypoint.sh")"
GC="$SCRATCH/session-gitconfig"
if write_git_identity "$GC" "Alice \"Al\" O'Neil \\ Example" alice@example.com; then
    assert_eq "the session's .gitconfig holds the name with its quote and backslash, as git reads it" \
        "Alice \"Al\" O'Neil \\ Example|alice@example.com|main" \
        "$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GC" git config --get user.name)|$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GC" git config --get user.email)|$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GC" git config --get init.defaultBranch)"
    assert_eq "and git in the session runs with it (no bad config line)" 0 \
        "$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GC" git config --list >/dev/null 2>&1; echo $?)"
    assert_eq "readable by the session user" 644 "$(stat -c %a "$GC")"
else
    assert_eq "write_git_identity writes the session's .gitconfig" 0 1
fi
# Shells opened from outside a Kubernetes session (kubectl exec, sudo) write group-writable
# files on the shared disk too, so the git container can tidy what they made.
eval "$(sed -n '/^group_write_shells() {/,/^}/p' "$AIDC_ROOT/.devcontainer/entrypoint.sh")"
GW="$SCRATCH/gwroot"; mkdir -p "$GW/etc"; printf '# distro bashrc\n' > "$GW/etc/bash.bashrc"
group_write_shells "$GW"; group_write_shells "$GW"
assert_eq "login shells get umask 002" "umask 002" "$(grep -x 'umask 002' "$GW/etc/profile.d/aidc-umask.sh")"
assert_eq "interactive bash too, once however often the entrypoint runs" 1 "$(grep -c '^umask 002  # aidc$' "$GW/etc/bash.bashrc")"
assert_eq "and sudo keeps it (its own 022 would be added otherwise)" "Defaults umask=0002|Defaults umask_override|440" \
    "$(paste -sd'|' "$GW/etc/sudoers.d/aidc-umask")|$(stat -c %a "$GW/etc/sudoers.d/aidc-umask")"
if command -v visudo >/dev/null 2>&1; then
    assert_eq "a sudoers file sudo accepts" 0 "$(visudo -c -f "$GW/etc/sudoers.d/aidc-umask" >/dev/null 2>&1; echo $?)"
fi
assert_has "the entrypoint does this on Kubernetes only (the Docker repo is the host's)" \
    'if [ "${AIDC_BACKEND:-}" = kubernetes ]; then' "$(grep -A1 'group_write_shells / ' "$AIDC_ROOT/.devcontainer/entrypoint.sh" | head -1; grep -B1 'group_write_shells / ' "$AIDC_ROOT/.devcontainer/entrypoint.sh" | head -1)"
assert_eq "the entrypoint no longer writes the values into the file unquoted" 0 "$(grep -c 'name = ${AIDC_GIT_USER_NAME}' "$AIDC_ROOT/.devcontainer/entrypoint.sh")"
git config --global user.name $'Two\nlines'
out=$(run create demo --backend kubernetes)
assert_eq "an identity with a control character is not bridged (it would reach the .gitconfig)" "|" "$(idenv AIDC_GIT_USER_NAME)|$(idenv AIDC_GIT_USER_EMAIL)"
assert_has "and create says so" "git identity: NOT bridged" "$out"
git config --global --unset user.name; git config --global --unset user.email
out=$(run create demo --backend kubernetes)
assert_has "no identity on this machine: create says it is not bridged" "git identity: NOT bridged" "$out"
out=$(K_GIT=1 run kill git)
assert_has "aidc kill git (found in the cluster) refuses the git agent" "aidc kill does not remove it" "$out"
assert_has "and exits 1" "exit=1" "$out"
assert_not_has "removing nothing" "delete" "$(cat "$K_LOG")"
out=$(K_GIT=1 run list --backend kubernetes)
assert_has "aidc list shows the git agent" "git                  running         git-agent" "$out"
out=$(run list --backend kubernetes)
assert_not_has "only when it is there" "git-agent" "$out"
: > "$K_LOG"; K_GIT=1 run attach git >/dev/null
assert_has "aidc attach git opens the git container's tmux as its own user" \
    "exec -it git-7d9f-abc -c git -- env TERM=" "$(cat "$K_LOG")"
K_GIT=1 run logs git >/dev/null
assert_has "aidc logs git reads the git container's log" "logs deployment/git -c git" "$(cat "$K_LOG")"
out=$(K_GIT=1 run logs git --component squid)
assert_has "it has no proxy components" "has one component: git" "$out"
out=$(K_GIT=1 run status git)
assert_has "aidc status git names it as the git agent" "session:  git (your git agent" "$out"

echo "=== the config's default backend for create ==="
printf 'backend: kubernetes\n' >> "$HOME/.config/aidc/config.yaml"
out=$(run create demo)
assert_has "backend: kubernetes in the config makes create use the cluster" "session demo is ready" "$out"
sed -i 's/^backend: kubernetes$/backend: "kubernetes"/' "$HOME/.config/aidc/config.yaml"
out=$(run create demo)
assert_has "a quoted backend value counts too" "session demo is ready" "$out"
out=$(run create demo --backend docker --help)
assert_has "--backend docker still wins over the config" "aidc create" "$out"
sed -i '/^backend: /d' "$HOME/.config/aidc/config.yaml"

echo "=== list, attach, status, logs ==="
out=$(K_EXISTS=1 run list)
assert_has "list shows cluster sessions with their backend" "kubernetes" "$out"
assert_has "the cluster row names the session" "demo" "$out"
: > "$K_LOG"; K_EXISTS=1 run attach demo --backend kubernetes >/dev/null
assert_has "attach runs tmux as the session user in the dev container" \
    "exec -it demo-dev-0 -c dev -- sudo -u vscode -H env" "$(cat "$K_LOG")"
out=$(K_EXISTS=1 run status demo)
assert_has "status names the repo" "repo:     /home/alice/code/proj" "$out"
assert_has "status says the session is clean" "taint:    clean" "$out"
out=$(K_EXISTS=1 K_TAINTED=1 run status demo)
assert_has "status shows a taint" "taint:    TAINTED" "$out"
out=$(K_EXISTS=1 K_POLICY_DOWN=1 run status demo)
assert_has "a policy sidecar that does not answer is unknown, never clean" "taint:    unknown" "$out"
assert_has "status confirms the lockdown's policies are there" "egress:   enforced" "$(K_EXISTS=1 run status demo)"
assert_has "status names the kept audit claim" "audit:    volume claim demo-audit-20261124050000" "$out"
out=$(K_EXISTS=1 K_STATUS_READS_DOWN=1 run status demo)
assert_has "a failed policy read is unknown, never NOT ENFORCED" "egress:   unknown (the cluster did not answer)" "$out"
assert_not_has "(no false alarm)" "NOT ENFORCED" "$out"
assert_has "a failed pods read says so" "  unknown (the cluster did not answer)" "$out"
out=$(K_EXISTS=1 run logs demo --component nonesuch)
assert_has "an unknown component is refused by name" "unknown component: nonesuch" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
