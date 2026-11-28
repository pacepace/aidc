#!/usr/bin/env bash
# Unit tests for the user's Claude accounts in the cluster: `aidc claude account|broker` with the
# kubernetes backend (scripts/k8s/claude.sh, broker.sh) and the broker's manifests
# (scripts/k8s/manifests.sh, k8s_render_broker, k8s_render_broker_config, the two claims).
# The broker's own logic is tests/unit/test-claude-broker.sh.
#
# kubectl is a PATH stub; HOME holds the config. Needs yq and jq; skips without them.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-claude-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/aidc"

for t in yq jq; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }
done

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

# kubectl stub: logs each call's argv (one line) to $K_LOG; apply -f - appends its stdin to
# $K_APPLIED.
#   get deployment claude-broker   "claude-broker|1" when K_RUNNING=1; K_DOWN=1: no answer
#   get pvc claude-config|claude-accounts  there unless K_NO_CLAIMS=1
#   exec ... claude-broker list    a list
#   apply -f -                     says the Deployment configured, or unchanged when K_UNCHANGED=1
cat > "$SCRATCH/bin/kubectl" <<'STUB_K8S_CLAUDE_m3'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
case "$*" in
    *"get runtimeclass"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"get deployment claude-broker"*)
        [ "${K_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        [ "${K_RUNNING:-}" = 1 ] && printf 'claude-broker|1' ;;
    *"get pvc claude-config"*|*"get pvc claude-accounts"*) [ "${K_NO_CLAIMS:-}" = 1 ] || echo "persistentvolumeclaim/x" ;;
    *"apply -f -"*)
        { echo '---'; cat; } >> "$K_APPLIED"
        if [ "${K_UNCHANGED:-}" = 1 ]; then echo "deployment.apps/claude-broker unchanged"; else echo "deployment.apps/claude-broker configured"; fi ;;
    *"rollout status"*) [ "${K_ROLLOUT_FAIL:-}" = 1 ] && { echo 'timed out' >&2; exit 1; } ;;
    *"claude-broker list"*) echo "* work  switch at 90%" ;;
esac
exit 0
STUB_K8S_CLAUDE_m3
chmod +x "$SCRATCH/bin/kubectl"

# A docker that answers nothing, so no case reaches this machine's real daemon (the Docker
# backend's broker would otherwise be built and started for real).
printf '#!/bin/sh\necho "Cannot connect to the Docker daemon" >&2\nexit 1\n' > "$SCRATCH/bin/docker"; chmod +x "$SCRATCH/bin/docker"

export HOME="$SCRATCH/home" K_LOG="$SCRATCH/kubectl.log" K_APPLIED="$SCRATCH/applied.yaml"
# shellcheck source=lib/stub-tools.sh
. "$SCRIPT_DIR/lib/stub-tools.sh"
stub_tools "$SCRATCH/bin"
CFG="$HOME/.config/aidc/config.yaml"
cat > "$CFG" <<'CFG_K8S_CLAUDE_m3'
backend: kubernetes
kubernetes:
  context: lab
  user: alice
  storage_class: shared-disk
  session_storage_class: scratch
claude_accounts:
  - {name: work, switch_at: 85}
  - {name: personal}
claude_account_switch: wait
CFG_K8S_CLAUDE_m3
run() { : > "$K_APPLIED"; : > "$K_LOG"; ("$AIDC_ROOT/scripts/aidc" claude "$@" 2>&1 </dev/null); echo "exit=$?"; }
q() { yq -N ea "$1" -o=json -I=0 "$K_APPLIED"; }
dep() { q "[select(.kind == \"Deployment\")] | .[-1] | $1"; }

echo "=== account add with no broker running: it is started, then Claude's own login runs in it ==="
out=$(K_NO_CLAIMS=1 run account add work)
log=$(cat "$K_LOG")
assert_has "exit 0" "exit=0" "$out"
assert_has "it says it starts the broker" "starting your Claude account broker in aidc-u-alice" "$out"
assert_eq "it applies the two claims, the settings, the policy and the Deployment" \
    "PersistentVolumeClaim/claude-config PersistentVolumeClaim/claude-accounts ConfigMap/claude-broker-config NetworkPolicy/claude-broker Deployment/claude-broker" \
    "$(yq -N e 'select(.kind != null) | [.kind, .metadata.name] | join("/")' "$K_APPLIED" | paste -sd' ' -)"
assert_has "it waits for the broker" "rollout status deployment/claude-broker" "$log"
assert_has "then runs the login in the broker's pod, on this terminal" \
    "exec -it deployment/claude-broker -c broker -- claude-broker login work" "$log"
login_line=$(grep -n 'claude-broker login' "$K_LOG" | cut -d: -f1)
rollout_line=$(grep -n 'rollout status' "$K_LOG" | cut -d: -f1)
assert_eq "...once it is ready" "yes" "$([ "${rollout_line:-99}" -lt "${login_line:-0}" ] && echo yes)"

echo "=== the claims ==="
pvc() { q "select(.kind == \"PersistentVolumeClaim\" and .metadata.name == \"$1\") | [.spec.storageClassName, .metadata.labels]"; }
assert_eq "the accounts' logins are on the user's retained class (a lost claim is lost logins)" \
    '["shared-disk",{"app.kubernetes.io/managed-by":"aidc","aidc/user":"alice","app":"claude-broker"}]' "$(pvc claude-accounts)"
assert_eq "the sessions' Claude config dirs are on the session class, the user's (no session label)" \
    '["scratch",{"app.kubernetes.io/managed-by":"aidc","aidc/user":"alice"}]' "$(pvc claude-config)"

echo "=== the broker's pod ==="
pod() { dep ".spec.template.spec | $1"; }
assert_eq "no API token, no service links: it needs no cluster API" "[false,false]" \
    "$(pod '[.automountServiceAccountToken, .enableServiceLinks]')"
assert_eq "one at a time (one writer of the logins)" '"Recreate"' "$(dep '.spec.strategy.type')"
assert_eq "it runs as uid 1000 (the session user's, whose Claude reads what it writes), read-only, with nothing" \
    '{"runAsUser":1000,"runAsGroup":1000,"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}' \
    "$(pod '.containers[0].securityContext')"
assert_eq "it mounts the accounts' claim, claude-config whole, its settings, a scratch /tmp" \
    '[{"name":"accounts","mountPath":"/var/lib/claude-broker"},{"name":"claude-config","mountPath":"/var/aidc/claude-config"},{"name":"config","mountPath":"/etc/claude-broker","readOnly":true},{"name":"tmp","mountPath":"/tmp"}]' \
    "$(pod '.containers[0].volumeMounts')"
assert_has "it runs the broker image of this version" '"localhost:5000/aidc/broker:' "$(pod '.containers[0].image | tojson')"
assert_has "Claude Code never updates itself into an account's folder" '{"name":"DISABLE_AUTOUPDATER","value":"1"}' "$(pod '.containers[0].env')"
assert_eq "it lands where sessions do (their claims are on that node)" '[{"kubernetes.io/hostname":"n1"}]' "$(pod '[.nodeSelector]')"
assert_eq "Quad9 is its only DNS" '["None",["9.9.9.9","149.112.112.112"]]' "$(pod '[.dnsPolicy, .dnsConfig.nameservers]')"
assert_eq "a root step gives the accounts' claim to it alone" 'chown 1000:1000 /accounts && chmod 0700 /accounts' \
    "$(pod '.initContainers[] | select(.name == "accounts-dir") | .command[2]' | tr -d '"')"

echo "=== the broker's network policy: no way in; out to Quad9 and public addresses on 443 only ==="
pol() { q "[select(.kind == \"NetworkPolicy\")] | .[-1] | $1"; }
assert_eq "it selects the broker's pods" '{"matchLabels":{"app":"claude-broker"}}' "$(pol '.spec.podSelector')"
assert_eq "nothing may connect to it" "[]" "$(pol '.spec.ingress')"
assert_eq "out: Quad9 DNS, then public addresses on 443" \
    '[[["9.9.9.9/32","149.112.112.112/32"],[53,53]],[["0.0.0.0/0"],[443]]]' \
    "$(pol '[.spec.egress[] | [[.to[].ipBlock.cidr], [.ports[].port]]]')"
assert_eq "no private, shared, link-local or loopback address" \
    '["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","127.0.0.0/8"]' \
    "$(pol '.spec.egress[1].to[0].ipBlock.except')"

echo "=== its settings come from the user's config ==="
assert_eq "the order, each account's threshold (90 unless set) and the switch mode" \
    '{"accounts":[{"name":"work","switch_at":85},{"name":"personal","switch_at":90}],"switch":"wait"}' \
    "$(q 'select(.kind == "ConfigMap") | .data."config.json"' | jq -r . | jq -c .)"

echo "=== with the broker running ==="
out=$(K_RUNNING=1 run account add personal)
assert_eq "account add applies nothing" "" "$(cat "$K_APPLIED")"
assert_has "...and runs the login" "claude-broker login personal" "$(cat "$K_LOG")"
out=$(K_RUNNING=1 run account list)
assert_has "account list asks the broker" "* work  switch at 90%" "$out"
out=$(K_RUNNING=1 run account use personal)
assert_has "account use goes to the broker, with no terminal" \
    "exec deployment/claude-broker -c broker -- claude-broker use personal" "$(cat "$K_LOG")"
out=$(K_RUNNING=1 run account remove work)
assert_has "account remove too" "claude-broker remove work" "$(cat "$K_LOG")"
out=$(K_RUNNING=1 run broker status)
assert_has "broker status shows the state and the accounts" "claude-broker (kubernetes, aidc-u-alice): RUNNING" "$out"
assert_has "..." "  * work" "$out"
out=$(K_RUNNING=1 run broker start)
assert_eq "broker start on a Deployment that applied changed lets it roll by itself: no restart" "" "$(grep 'rollout restart' "$K_LOG")"
out=$(K_RUNNING=1 K_UNCHANGED=1 run broker start)
assert_has "an unchanged Deployment (same tag, maybe a rebuilt image) is restarted, so the pod pulls the image again" \
    "rollout restart deployment/claude-broker" "$(cat "$K_LOG")"
assert_has "...saying so, and that the accounts are kept" "its accounts are kept" "$out"
assert_eq "...before it waits for it" "yes" \
    "$([ "$(grep -n 'rollout restart' "$K_LOG" | cut -d: -f1)" -lt "$(grep -n 'rollout status' "$K_LOG" | cut -d: -f1)" ] && echo yes || echo no)"
assert_eq "...and the accounts' claim is never touched" "" "$(grep -E 'delete.*(pvc|claude-accounts)' "$K_LOG")"
out=$(K_RUNNING=1 run broker stop)
assert_has "broker stop removes its Deployment and policy only (claims kept)" \
    "delete deployment,networkpolicy -l app=claude-broker" "$(cat "$K_LOG")"

echo "=== with no broker ==="
out=$(run account list)
assert_has "account list says how to start one" "aidc claude account add <name> starts it" "$out"
assert_has "...exit 0" "exit=0" "$out"
out=$(run account use work)
assert_has "account use refuses, saying how" "aidc claude broker start" "$out"
assert_not_has "...and asks no pod" "exec" "$(cat "$K_LOG")"
out=$(K_DOWN=1 run account add work)
assert_has "a cluster that does not answer stops add" "cannot tell whether your Claude account broker runs" "$out"
assert_eq "...applying nothing" "" "$(cat "$K_APPLIED")"
out=$(K_ROLLOUT_FAIL=1 run account add work)
assert_has "a broker that does not start says where to look" "aidc k8s build --only broker" "$out"
assert_not_has "...and no login is tried" "claude-broker login" "$(cat "$K_LOG")"

echo "=== --help on every verb is help, never an account name ==="
for v in "account use" "account remove" "account add" "account list" "broker start" "broker stop" "broker logs"; do
    # shellcheck disable=SC2086  # the verb's two words
    out=$(: > "$K_LOG"; K_RUNNING=1 run $v --help)
    assert_has "aidc claude ${v} --help prints the help" "account use <name>" "$out"
    assert_eq "...and asks the broker nothing" "" "$(grep -E 'exec|apply|delete|rollout' "$K_LOG")"
done
out=$(: > "$K_LOG"; K_RUNNING=1 run account use -h)
assert_has "-h too" "account use <name>" "$out"

echo "=== on Docker: the Docker broker, never the cluster ==="
out=$(: > "$K_LOG"; ("$AIDC_ROOT/scripts/aidc" claude account add work --backend docker 2>&1 </dev/null); echo "exit=$?")
assert_eq "--backend docker asks no cluster" "" "$(cat "$K_LOG")"
assert_not_has "...and is not refused as cluster-only" "is for sessions in a cluster" "$out"
assert_not_has "...it stops at the docker that does not answer" "exit=0" "$out"
out=$("$AIDC_ROOT/scripts/aidc" claude help --backend docker 2>&1 </dev/null)
assert_has "its help names the Docker broker" "aidc-claude-broker" "$out"

echo
echo "k8s claude: passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
