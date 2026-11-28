#!/usr/bin/env bash
# Unit tests for the user's MCP server in the cluster: `aidc mcp start|stop|status|logs|token`
# with the kubernetes backend (scripts/k8s/mcp.sh) and its manifests (scripts/k8s/manifests.sh,
# k8s_render_mcp, k8s_render_mcp_state, k8s_render_mcp_token, k8s_mcp_config).
#
# kubectl and docker are PATH stubs; HOME holds the config. Needs yq and jq; skips without them.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-mcp-$$"
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

# kubectl stub: logs each call's argv (one line) to $K_LOG; apply and create -f - append their
# stdin to $K_APPLIED, each a document of its own.
#   config view               the kubeconfig's server: $K_SERVER (default https://192.0.2.10:6443)
#   get secret aidc-mcp-token  base64 of $K_TOKEN when set; K_SECRET_READ_FAIL=1: no answer
#   get pvc transcripts|aidc-mcp-state  there unless K_NO_TRANSCRIPTS / K_NO_STATE
#   get deployment aidc-mcp   "aidc-mcp|1" when K_RUNNING=1, "aidc-mcp|" when K_STARTING=1
#   exec ... printenv         the API server's in-cluster Service address, 10.43.0.1 / 443
#   exec ... tail             the access log's last line
#   get nodes -l ...control-plane  the control-plane nodes' InternalIPs: $K_CP_NODES, one a line
#   exec ... kubectl --server https://<ep>  the pod asking the API server there: fails for each
#                             <ep> in $K_UNREACHABLE (space-separated)
#                             (every one with K_EXEC_FAIL=1, as an exec that fails itself)
#   get configmap aidc-mcp-config  the running server's kubeconfig, at $K_HELD when set
#   get deployment aidc-mcp ... image-digest  the running pod template's image digest:
#                             $K_RUNNING_DIGEST (K_DIGEST_READ_FAIL=1: no answer)
cat > "$SCRATCH/bin/kubectl" <<'STUB_K8S_MCP_x41'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
case "$*" in
    *"config view"*) printf '%s' "${K_SERVER-https://192.0.2.10:6443}" ;;
    *"get runtimeclass"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"get secret aidc-mcp-token"*)
        [ "${K_SECRET_READ_FAIL:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        [ -z "${K_TOKEN:-}" ] || printf '%s' "$K_TOKEN" | base64 | tr -d '\n' ;;
    *"get pvc transcripts"*) [ "${K_NO_TRANSCRIPTS:-}" = 1 ] || echo "persistentvolumeclaim/transcripts" ;;
    *"get pvc aidc-mcp-state"*) [ "${K_NO_STATE:-}" = 1 ] || echo "persistentvolumeclaim/aidc-mcp-state" ;;
    *"get deployment aidc-mcp"*"image-digest"*)
        [ "${K_DIGEST_READ_FAIL:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        printf '%s' "${K_RUNNING_DIGEST:-}" ;;
    *"get deployment aidc-mcp"*)
        [ "${K_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        if [ "${K_RUNNING:-}" = 1 ]; then printf 'aidc-mcp|1'; elif [ "${K_STARTING:-}" = 1 ]; then printf 'aidc-mcp|'; fi ;;
    *"create configmap"*)
        jq -Rs '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: "aidc-mcp-config", namespace: "aidc-u-alice"}, data: {"config.yaml": .}}' ;;
    *"apply -f -"*|*"create -f -"*)
        [ "${K_CREATE_FAIL:-}" = 1 ] && case "$*" in *"create -f -"*) cat >/dev/null; exit 1 ;; esac
        { echo '---'; cat; } >> "$K_APPLIED" ;;
    *"rollout status"*) [ "${K_ROLLOUT_FAIL:-}" = 1 ] && { echo 'timed out' >&2; exit 1; } ;;
    *"exec deployment/aidc-mcp -c mcp -- printenv"*)
        [ "${K_PRINTENV_FAIL:-}" = 1 ] && { echo 'error: unable to upgrade connection: container not found ("mcp")' >&2; exit 1; }
        printf '%s\n%s\n' "${K_SVC_HOST:-10.43.0.1}" "${K_SVC_PORT:-443}" ;;
    *"get nodes -l node-role.kubernetes.io/control-plane"*) [ -z "${K_CP_NODES:-}" ] || printf '%s\n' $K_CP_NODES ;;
    *"exec deployment/aidc-mcp -c mcp -- kubectl --server"*)
        [ "${K_EXEC_FAIL:-}" = 1 ] && { echo 'error: unable to upgrade connection: container not found ("mcp")' >&2; exit 1; }
        for u in ${K_UNREACHABLE:-}; do
            case "$*" in *"--server https://$u "*) echo "Unable to connect to the server: dial tcp $u: i/o timeout" >&2; exit 1 ;; esac
        done ;;
    *"exec deployment/aidc-mcp -c mcp -- tail"*) echo '{"event": "tool_call", "tool": "session_list"}' ;;
    *"exec deployment/aidc-mcp -c mcp -- df"*) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 5000 4000 1000 %s%% /var/lib/aidc-mcp\n' "${K_DF:-12}" ;;
    *"get configmap aidc-mcp-config"*) [ -z "${K_HELD:-}" ] || printf 'clusters:\n  - cluster: {server: "https://%s"}\n' "$K_HELD" ;;
    *"get networkpolicy aidc-mcp"*)
        [ "${K_POLICY_READ_FAIL:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
        [ -z "${K_POLICY:-}" ] || printf '%s' "$K_POLICY" ;;
    *"get pod -l app=aidc-mcp"*) printf '%s' "${K_WAITING:-}" ;;
    *"get ingressclass"*) [ "${K_NO_IC:-}" = 1 ] && { echo 'Error from server (NotFound): ingressclasses.networking.k8s.io "web" not found' >&2; exit 1; }
        printf 'traefik.io/ingress-controller' ;;
    *"get ingress aidc-mcp"*) printf '%s' "${K_EXPOSED:-}" ;;
    *"get ingress -o json"*) printf '%s' "${K_INGRESSES:-{\"items\":[]\}}" ;;
    *"delete secret"*) [ "${K_DELETE_FAIL:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; } ;;
    *" logs "*) echo "the server's log" ;;
esac
exit 0
STUB_K8S_MCP_x41
printf '#!/bin/sh\nprintf "docker %%s\\n" "$*" >> "$K_LOG"\nexit 1\n' > "$SCRATCH/bin/docker"
# getent: api.cluster.test is 192.0.2.20, orchestrator.example.org 198.51.100.40, local.test
# 127.0.0.1; every other name has no address.
cat > "$SCRATCH/bin/getent" <<'GETENT_K8S_MCP_x41'
#!/bin/sh
case "$2" in
    api.cluster.test) echo "192.0.2.20      STREAM api.cluster.test" ;;
    orchestrator.example.org) echo "198.51.100.40   STREAM orchestrator.example.org" ;;
    local.test) echo "127.0.0.1       STREAM local.test" ;;
    mcp-alice.pages.example.org) [ "${K_MCP_IP:-192.168.1.50}" = none ] || echo "${K_MCP_IP:-192.168.1.50}   STREAM mcp-alice.pages.example.org" ;;
esac
GETENT_K8S_MCP_x41
chmod +x "$SCRATCH/bin/kubectl" "$SCRATCH/bin/docker" "$SCRATCH/bin/getent"

export HOME="$SCRATCH/home" K_LOG="$SCRATCH/kubectl.log" K_APPLIED="$SCRATCH/applied.yaml" \
    XDG_STATE_HOME="$SCRATCH/home/.local/state"
# docker and kubectl first on PATH are the stubs above, or the test refuses to run.
# shellcheck source=lib/stub-tools.sh
. "$SCRIPT_DIR/lib/stub-tools.sh"
stub_tools "$SCRATCH/bin"
CFG="$HOME/.config/aidc/config.yaml"
write_config() {
    cat > "$CFG" <<'CFG_K8S_MCP_x41'
backend: kubernetes
profile: multi
ports: ["8080:8080"]
kubernetes:
  context: lab
  kubeconfig: ~/.kube/alice.yaml
  user: alice
  storage_class: shared-disk
  session_storage_class: scratch
orchestrator:
  callback_url: "https://orchestrator.example.org:8443"
CFG_K8S_MCP_x41
    [ -z "${1:-}" ] || printf '%s\n' "$1" >> "$CFG"
}
write_config
TOKEN_FILE="$HOME/.config/aidc/mcp-token"
run() { : > "$K_APPLIED"; : > "$K_LOG"; ("$AIDC_ROOT/scripts/aidc" mcp "$@" 2>&1 </dev/null); echo "exit=$?"; }
q() { yq -N e "$1" -o=json -I=0 "$K_APPLIED"; }
dep() { q "select(.kind == \"Deployment\") | $1" | tail -1; }
# pols: each NetworkPolicy applied, its egress addresses, one line per apply.
pols() { q 'select(.kind == "NetworkPolicy" and .metadata.name == "aidc-mcp") | [.spec.egress[].to[0].ipBlock.cidr]' | grep -vx '\[\]'; }
# cpol: the callback's own policy's egress, as <cidr>:<port>.
cpol() { q 'select(.kind == "NetworkPolicy" and .metadata.name == "aidc-mcp-callback") | [.spec.egress[] | .to[0].ipBlock.cidr + ":" + (.ports[0].port | tostring)]' | grep -vx '\[\]' | tail -1; }
pod() { dep ".spec.template.spec | $1"; }
pod_meta() { dep ".spec.template.metadata | $1"; }
VERSION_TAG=$(head -n1 "$AIDC_ROOT/VERSION" | tr '+' '_')

echo "=== aidc mcp start: a first start ==="
rm -f "$TOKEN_FILE"
out=$(K_NO_STATE=1 run start)
assert_has "it starts and says so" "aidc-mcp (kubernetes, aidc-u-alice):" "$out"
assert_has "exit 0" "exit=0" "$out"
assert_eq "every object goes in the user's namespace" "aidc-u-alice" "$(q '.metadata.namespace' | sort -u | tr -d '"')"
secret_tok=$(q 'select(.kind == "Secret") | .stringData.token' | tr -d '"')
assert_eq "a token is made, as the Docker server's (32 random bytes, base64url)" yes \
    "$(printf '%s' "$secret_tok" | grep -Eq '^[A-Za-z0-9_-]{43}$' && echo yes || echo no)"
assert_eq "it is a Secret (MCP-05), labelled for the user's server" \
    '{"name":"aidc-mcp-token","namespace":"aidc-u-alice","labels":{"app.kubernetes.io/managed-by":"aidc","aidc/user":"alice","app":"aidc-mcp"}}' \
    "$(q 'select(.kind == "Secret") | .metadata')"
assert_not_has "the token is never on a command line" "$secret_tok" "$(cat "$K_LOG")"
assert_not_has "and never printed by start" "$secret_tok" "$out"
assert_eq "this machine has it at ~/.config/aidc/mcp-token, the Secret's own" "$secret_tok" "$(cat "$TOKEN_FILE")"
assert_eq "...mode 0600" 600 "$(stat -c %a "$TOKEN_FILE" 2>/dev/null || stat -f %Lp "$TOKEN_FILE")"
assert_eq "the token is in no ConfigMap" "" "$(q 'select(.kind == "ConfigMap") | .data[]' | grep -F "$secret_tok")"
cfg=$(q 'select(.kind == "ConfigMap" and .metadata.name == "aidc-mcp-config") | .data["config.yaml"]' | jq -r .)
assert_eq "the server's config is the user's, on the cluster backend, for this user" '["kubernetes","alice","shared-disk","https://orchestrator.example.org:8443"]' \
    "$(printf '%s' "$cfg" | yq -o=json -I=0 '[.backend, .kubernetes.user, .kubernetes.storage_class, .orchestrator.callback_url]')"
assert_eq "without this machine's kubeconfig and context (the pod uses its ServiceAccount) or tunnels" '[null,null,null]' \
    "$(printf '%s' "$cfg" | yq -o=json -I=0 '[.kubernetes.kubeconfig, .kubernetes.context, .ports]')"
kc=$(q 'select(.kind == "ConfigMap" and .metadata.name == "aidc-mcp-config") | .data.kubeconfig' | jq -r .)
assert_eq "the pod's kubectl goes to the API server address its policy allows (not the API Service, which balances over every control-plane node), with its ServiceAccount's token file and CA, checked for the Service's name" \
    '["https://192.0.2.10:6443","/var/run/secrets/kubernetes.io/serviceaccount/ca.crt","kubernetes.default.svc","/var/run/secrets/kubernetes.io/serviceaccount/token","aidc-u-alice","in-cluster"]' \
    "$(printf '%s' "$kc" | yq -o=json -I=0 '[.clusters[0].cluster.server, .clusters[0].cluster.certificate-authority, .clusters[0].cluster.tls-server-name, .users[0].user.tokenFile, .contexts[0].context.namespace, .current-context]')"
assert_not_has "...and holds no token itself" "token:" "$kc"
assert_eq "the state claim is made, on the user's retained class, 5Gi unless configured" 'shared-disk 5Gi' \
    "$(q 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "aidc-mcp-state") | .spec.storageClassName + " " + .spec.resources.requests.storage' | tr -d '"')"
assert_has "it waits for the server to be ready" "rollout status deployment/aidc-mcp" "$(cat "$K_LOG")"
assert_eq "every volume mount names a volume the pod declares" "" \
    "$(yq -N ea 'select(.kind == "Deployment") | .spec.template.spec as $p | ([($p.containers[], $p.initContainers[]?) | .volumeMounts[]?.name] - [$p.volumes[]?.name]) | .[]' "$K_APPLIED" | sort -u | paste -sd' ' -)"

echo "=== the server's Deployment ==="
assert_eq "one replica, replaced not rolled: one process per state store" '[1,"Recreate"]' \
    "$(dep '[.spec.replicas, .spec.strategy.type]')"
assert_eq "it runs as the MCP's ServiceAccount, with its token (kubectl needs it), and no service links" \
    '["aidc-mcp",true,false]' "$(pod '[.serviceAccountName, .automountServiceAccountToken, .enableServiceLinks]')"
assert_eq "the image is aidc's mcp from the in-cluster registry, pulled every time" \
    "[\"localhost:5000/aidc/mcp:$(head -n1 "$AIDC_ROOT/VERSION" | tr '+' '_')\",\"Always\"]" \
    "$(pod '.containers[0] | [.image, .imagePullPolicy]')"
assert_eq "it lands where sessions land (the mirror and the disk are on that node)" \
    '{"kubernetes.io/hostname":"n1"}' "$(pod '.nodeSelector')"
assert_eq "root with only DAC_OVERRIDE (to read the sessions' 0600 transcripts), read-only root, no escalation" \
    '{"runAsUser":0,"runAsGroup":0,"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"],"add":["DAC_OVERRIDE"]}}' \
    "$(pod '.containers[0].securityContext')"
envs=$(pod '.containers[0].env' | jq -c 'map({(.name): .value}) | add')
assert_eq "it serves the cluster backend in the user's namespace, on its port" \
    '["kubernetes","aidc-u-alice","7878"]' \
    "$(printf '%s' "$envs" | jq -c '[.AIDC_MCP_BACKEND, .AIDC_K8S_NAMESPACE, .AIDC_MCP_PORT]')"
assert_eq "its token is read from the projected Secret, its store and access log are on its claim, the mirror where it reads transcripts" \
    '["/aidc-config/mcp-token","/var/lib/aidc-mcp/access.log","/var/lib/aidc-mcp/watcher-state","/var/lib/aidc-mcp/transcripts"]' \
    "$(printf '%s' "$envs" | jq -c '[.AIDC_MCP_TOKEN_FILE, .AIDC_MCP_AUDIT_LOG, .AIDC_MCP_WATCHER_STATE, .AIDC_MCP_TRANSCRIPTS]')"
assert_eq "kubectl in the pod (the server's and its CLI's) reads that kubeconfig, from the projected config folder" \
    '"/aidc-config/kubeconfig"' "$(printf '%s' "$envs" | jq -c '.KUBECONFIG')"
assert_eq "the CLI it runs starts a session at /home/<user> (its home and working dir)" \
    '["/home/alice","/home/alice"]' "$(printf '%s' "$envs" | jq -c --argjson w "$(pod '.containers[0].workingDir')" '[.HOME, $w]')"
assert_eq "session_create is off unless mcp.session_create says so (MCP-38)" '"false"' \
    "$(printf '%s' "$envs" | jq -c '.AIDC_MCP_SESSION_CREATE')"
assert_eq "the mirror is mounted whole and read-only; config read-only; the state claim writable" \
    '[["config",true],["state",null],["transcripts",true],["home",null],["tmp",null]]' \
    "$(pod '[.containers[0].volumeMounts[] | [.name, .readOnly]]')"
assert_eq "the volumes: the token Secret (0400) and the config in one projected folder, the state and mirror claims" \
    '[{"secret":{"name":"aidc-mcp-token","items":[{"key":"token","path":"mcp-token","mode":256}]}},{"configMap":{"name":"aidc-mcp-config","items":[{"key":"config.yaml","path":"config.yaml"},{"key":"kubeconfig","path":"kubeconfig"}]}}] aidc-mcp-state transcripts' \
    "$(pod '.volumes[] | select(.name == "config") | .projected.sources') $(pod '.volumes[] | select(.name == "state") | .persistentVolumeClaim.claimName' | tr -d '"') $(pod '.volumes[] | select(.name == "transcripts") | .persistentVolumeClaim.claimName' | tr -d '"')"
assert_eq "no container is privileged" "[]" "$(pod '[.containers[] | select(.securityContext.privileged == true)]')"

echo "=== the server's network: nothing in, the API server only out ==="
pol() { q 'select(.kind == "NetworkPolicy" and .metadata.name == "aidc-mcp") | .spec' | tail -1; }
assert_eq "it selects the server's pods, both ways" \
    '[{"app":"aidc-mcp"},["Ingress","Egress"]]' "$(pol | jq -c '[.podSelector.matchLabels, .policyTypes]')"
assert_eq "it may reach the API server where the kubeconfig names it, and at its in-cluster address, on their ports only" \
    '[{"to":[{"ipBlock":{"cidr":"192.0.2.10/32"}}],"ports":[{"protocol":"TCP","port":6443}]},{"to":[{"ipBlock":{"cidr":"10.43.0.1/32"}}],"ports":[{"protocol":"TCP","port":443}]}]' \
    "$(pol | jq -c '.egress')"
assert_eq "the first policy, before the in-cluster address is read, allows the kubeconfig's only" \
    '[{"to":[{"ipBlock":{"cidr":"192.0.2.10/32"}}],"ports":[{"protocol":"TCP","port":6443}]}]' \
    "$(q 'select(.kind == "NetworkPolicy" and .metadata.name == "aidc-mcp") | .spec.egress' | head -1)"

echo "=== reaching the server: its Service, in the cluster ==="
assert_eq "a ClusterIP Service on the server's port and the taint webhook's (no node port, no external address)" \
    '{"type":null,"selector":{"app":"aidc-mcp"},"ports":[{"name":"mcp","port":7878,"targetPort":7878,"protocol":"TCP"},{"name":"taint","port":7879,"targetPort":7879,"protocol":"TCP"}]}' \
    "$(q 'select(.kind == "Service") | .spec | {"type": .type, "selector": .selector, "ports": .ports}' | tail -1)"
assert_eq "every namespace but the user's own may connect to the MCP port (no session of the user reaches it); the user's session proxies to the taint webhook's port only (K8S-13's one exception)" \
    '[{"from":[{"namespaceSelector":{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["aidc-u-alice"]}]}}],"ports":[{"protocol":"TCP","port":7878}]},{"from":[{"podSelector":{"matchLabels":{"app":"proxy"}}}],"ports":[{"protocol":"TCP","port":7879}]}]' \
    "$(pol | jq -c '.ingress')"
assert_eq "the server listens for the webhook on its own port" '["7879",[7878,7879]]' \
    "$(pod '.containers[0]' | jq -c '[(.env[] | select(.name == "AIDC_MCP_TAINT_PORT") | .value), [.ports[].containerPort]]')"
assert_eq "the readiness probe connects from inside the pod (the policy lets nothing in from the node)" \
    '["python","-c","import socket; socket.create_connection(('"'"'127.0.0.1'"'"', 7878), 2)"]' \
    "$(pod '.containers[0].readinessProbe.exec.command')"

echo "=== the callback: one host and port out, by name in the pod's hosts file ==="
assert_eq "the orchestrator's callback address and port are allowed, in a policy of their own" \
    '["198.51.100.40/32:8443"]' "$(cpol)"
assert_eq "...which selects the server's pods, for egress only" '[{"app":"aidc-mcp"},["Egress"]]' \
    "$(q 'select(.kind == "NetworkPolicy" and .metadata.name == "aidc-mcp-callback") | [.spec.podSelector.matchLabels, .spec.policyTypes]' | grep -vx '\[\]' | tail -1)"
assert_eq "the pod resolves the callback's name from its hosts file (it has no DNS)" \
    '[{"ip":"198.51.100.40","hostnames":["orchestrator.example.org"]}]' "$(pod '.hostAliases')"
yq -i '.mcp.kubernetes.callback_address = "10.20.30.40" | .orchestrator.callback_url = "http://orch.internal/cb"' "$CFG"
out=$(run start)
assert_eq "mcp.kubernetes.callback_address overrides the lookup; http is port 80" \
    '["10.20.30.40/32:80"] [{"ip":"10.20.30.40","hostnames":["orch.internal"]}]' "$(cpol) $(pod '.hostAliases')"
yq -i 'del(.mcp) | .orchestrator.callback_url = "https://192.0.2.99:9000/hook"' "$CFG"
out=$(run start)
assert_eq "a callback URL with an address needs no hosts entry" '[]' "$(pod '.hostAliases')"
yq -i '.orchestrator.callback_url = "https://nowhere.test/hook"' "$CFG"
out=$(run start)
assert_has "a callback host with no address is refused, saying what to set" "set mcp.kubernetes.callback_address" "$out"
assert_eq "...before anything is applied" "" "$(q 'select(.kind == "Deployment") | .metadata.name')"
yq -i '.orchestrator.callback_url = "https://local.test/hook"' "$CFG"
out=$(run start)
assert_has "a callback host that is loopback here is refused (the pod cannot reach it)" "which the server's pod cannot reach" "$out"
yq -i 'del(.orchestrator)' "$CFG"
out=$(run start)
assert_has "no callback_url: started, saying no replies are delivered until one is set" "no orchestrator.callback_url" "$out"
assert_eq "...and no callback egress: no callback policy applied" "" "$(cpol)"
assert_has "...and an old one removed" "delete networkpolicy aidc-mcp-callback --ignore-not-found" "$(cat "$K_LOG")"
write_config

echo "=== on the user's network: mcp.kubernetes.expose ingress ==="
assert_has "with expose off, any Ingress of the server is removed" "delete ingress aidc-mcp --ignore-not-found" "$(cat "$K_LOG")"
write_config "$(printf 'mcp:\n  kubernetes:\n    expose: ingress\n')"
yq -i '.kubernetes.ingress = {"domain": "pages.example.org", "class": "web", "tls_secret": "wildcard"}' "$CFG"
out=$(run start)
assert_has "exit 0" "exit=0" "$out"
ing() { q 'select(.kind == "Ingress")' | tail -1; }
assert_eq "an Ingress at mcp-<user>.<the pages' domain>, every path to the server's Service" \
    '{"host":"mcp-alice.pages.example.org","paths":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"aidc-mcp","port":{"number":7878}}}}]}' \
    "$(ing | jq -c '.spec.rules[0] | {"host": .host, "paths": .http.paths}')"
assert_eq "on the pages' class and wildcard certificate" \
    '["web",[{"hosts":["mcp-alice.pages.example.org"],"secretName":"wildcard"}]]' "$(ing | jq -c '[.spec.ingressClassName, .spec.tls]')"
assert_eq "labelled as the server's (stop removes it), in the user's namespace" \
    '["aidc-u-alice","aidc-mcp"]' "$(ing | jq -c '[.metadata.namespace, .metadata.labels.app]')"
assert_eq "a name the user's admission policy lets them serve (<x>-<user>.<domain>)" yes \
    "$(printf '%s' "$(ing | jq -r '.spec.rules[0].host')" | grep -Eq '^[a-z0-9-]+-alice[.]pages[.]example[.]org$' && echo yes || echo no)"
yq -i '.kubernetes.ingress = {"domain": "pages.example.org", "class": "web", "cluster_issuer": "letsencrypt"}' "$CFG"
out=$(run start)
assert_eq "with a cert-manager issuer instead: its annotation and a certificate of its own" \
    '[{"cert-manager.io/cluster-issuer":"letsencrypt"},[{"hosts":["mcp-alice.pages.example.org"],"secretName":"aidc-mcp-tls"}]]' \
    "$(ing | jq -c '[.metadata.annotations, .spec.tls]')"
out=$(K_NO_IC=1 run start)
assert_has "an ingress class the cluster does not have is refused (MCP-11), not skipped" "cannot read IngressClass web" "$out"
assert_eq "...before anything is applied" "" "$(q 'select(.kind == "Deployment") | .metadata.name')"
out=$(K_INGRESSES='{"items":[{"metadata":{"namespace":"aidc-u-alice","name":"other"},"spec":{"rules":[{"host":"mcp-alice.pages.example.org"}]}}]}' run start)
assert_has "a name another Ingress serves is refused" "mcp-alice.pages.example.org is already served by ingress aidc-u-alice/other" "$out"
out=$(K_INGRESSES='{"items":[{"metadata":{"namespace":"aidc-u-alice","name":"aidc-mcp"},"spec":{"rules":[{"host":"mcp-alice.pages.example.org"}]}}]}' run start)
assert_has "...but the server's own Ingress is not another" "exit=0" "$out"
out=$(K_MCP_IP=203.0.113.80 run start)
assert_has "a name that resolves to a public address is refused (every session's proxy could reach it there)" \
    "mcp-alice.pages.example.org resolves to 203.0.113.80, a public address" "$out"
assert_eq "...before anything is applied" "" "$(q 'select(.kind == "Deployment") | .metadata.name')"
out=$(K_MCP_IP=none run start)
assert_has "a name that does not resolve here is refused (aidc cannot tell it is private)" "cannot resolve mcp-alice.pages.example.org here" "$out"
for ip in 10.1.2.3 172.20.0.9 100.100.1.2; do
    out=$(K_MCP_IP=$ip run start)
    assert_has "a name on the VPN/LAN (${ip}) is served" "exit=0" "$out"
done
yq -i 'del(.kubernetes.ingress)' "$CFG"
out=$(run start)
assert_has "expose ingress with no pages domain is refused" "needs kubernetes.ingress.domain" "$out"
yq -i '.mcp.kubernetes.expose = "nodeport"' "$CFG"
out=$(run start)
assert_has "an exposure aidc does not make is refused" "expected ingress, or none" "$out"
write_config
out=$(K_RUNNING=1 K_EXPOSED=mcp-alice.pages.example.org run status)
assert_has "status gives the in-cluster address" "in cluster:  http://aidc-mcp.aidc-u-alice.svc:7878/mcp (from any namespace but aidc-u-alice)" "$out"
assert_has "...and the network one when exposed" "network:     https://mcp-alice.pages.example.org/mcp" "$out"

echo "=== the server's config, rendered in manifests.sh ==="
out=$(run start)
cm=$(q 'select(.kind == "ConfigMap" and .metadata.name == "aidc-mcp-config") | .metadata' | tail -1)
assert_eq "its ConfigMap carries the server's labels and namespace" \
    '{"name":"aidc-mcp-config","namespace":"aidc-u-alice","labels":{"app.kubernetes.io/managed-by":"aidc","aidc/user":"alice","app":"aidc-mcp"}}' "$cm"
assert_not_has "...made by the render, not by kubectl create --dry-run" "create configmap" "$(cat "$K_LOG")"
odd=$(HOME="$HOME" AIDC_SCRIPTS="$AIDC_ROOT/scripts" bash -c '. "$1/scripts/k8s/lib.sh"; . "$1/scripts/k8s/manifests.sh"; k8s_load_settings
    yq -i ".orchestrator.callback_url = \"https://x.example.org/\\\" | .kind = \\\"Secret\"" "$HOME/.config/aidc/config.yaml"
    k8s_render_mcp_config 192.0.2.10:6443' _ "$AIDC_ROOT")
assert_eq "a config value that looks like yq or YAML is data, not part of the program or the document" \
    'ConfigMap https://x.example.org/" | .kind = "Secret' \
    "$(printf '%s' "$odd" | yq -r '.kind + " " + (.data["config.yaml"] | from_yaml | .orchestrator.callback_url)')"
write_config

echo "=== aidc mcp start: again, with its token and claims there ==="
out=$(K_TOKEN=kept-token-1234567890abcdef1234567890abcdef run start)
assert_has "exit 0" "exit=0" "$out"
assert_eq "no token is made" "" "$(q 'select(.kind == "Secret") | .metadata.name')"
assert_eq "this machine's copy is the Secret's" "kept-token-1234567890abcdef1234567890abcdef" "$(cat "$TOKEN_FILE")"
assert_eq "no claim is applied over one that is there (a changed size is refused as a resize)" "" \
    "$(q 'select(.kind == "PersistentVolumeClaim") | .metadata.name')"

echo "=== aidc mcp start over a running server: its policy applied once, never narrowed ==="
out=$(K_RUNNING=1 K_TOKEN=kept-token run start)
assert_has "exit 0" "exit=0" "$out"
assert_eq "one policy, with the in-cluster address the running server reports, from the start" \
    '["192.0.2.10/32","10.43.0.1/32"]' "$(pols)"
out=$(K_RUNNING=1 K_TOKEN=kept-token K_PRINTENV_FAIL=1 \
    K_POLICY='{"spec":{"egress":[{"to":[{"ipBlock":{"cidr":"192.0.2.10/32"}}],"ports":[{"port":6443}]},{"to":[{"ipBlock":{"cidr":"10.43.0.9/32"}}],"ports":[{"port":443}]}]}}' run start)
assert_has "exit 0" "exit=0" "$out"
assert_eq "a server that does not answer keeps the in-cluster address its policy allows now" \
    '["192.0.2.10/32","10.43.0.9/32"]' "$(pols)"
out=$(K_RUNNING=1 K_TOKEN=kept-token K_PRINTENV_FAIL=1 K_POLICY_READ_FAIL=1 run start)
assert_has "with neither readable, start stops" "nothing was changed" "$out"
assert_eq "...and applies nothing" "" "$(cat "$K_APPLIED")"
out=$(K_NO_STATE=1 K_PRINTENV_FAIL=1 run start)
assert_has "a new server whose in-cluster address cannot be read is said to be cut off, with what to do" \
    "its in-cluster API address could not be read, so it may not reach the API server: run aidc mcp start again" "$out"
out=$(K_SVC_HOST=192.0.2.10 K_SVC_PORT=6443 run start)
assert_eq "an in-cluster address already allowed is not added twice (one apply)" '["192.0.2.10/32"]' "$(pols)"

echo "=== a first start and a second name the same API addresses: those the policy holds ==="
# A new server's in-cluster address is known only once it runs; it was left out of what a
# first start said (three addresses, then four on the next start, the policy holding four).
said() { printf '%s\n' "$1" | sed -n 's/.*may reach the API server at \(.*\) only$/\1/p'; }
held_eps() { pol | jq -r '[.egress[] | (.to[0].ipBlock.cidr | sub("/32$"; "")) + ":" + (.ports[0].port | tostring)] | join(" ")'; }
out=$(K_CP_NODES='192.0.2.11 192.0.2.10 192.0.2.12' K_TOKEN=kept-token run start)
first_said=$(said "$out") first_held=$(held_eps)
assert_has "exit 0" "exit=0" "$out"
assert_has "a first start names the in-cluster address too" "10.43.0.1:443" "$first_said"
assert_eq "...and exactly what its policy holds" "$first_held" "$first_said"
assert_eq "...said once" 1 "$(printf '%s\n' "$out" | grep -c 'may reach the API server at')"
out=$(K_CP_NODES='192.0.2.11 192.0.2.10 192.0.2.12' K_RUNNING=1 K_HELD=192.0.2.10:6443 K_TOKEN=kept-token run start)
assert_eq "a second start names the same addresses" "192.0.2.10:6443 192.0.2.11:6443 192.0.2.12:6443 10.43.0.1:443" "$(said "$out")"
assert_eq "...as the first did" "$first_said" "$(said "$out")"
assert_eq "...which its policy holds" "$(held_eps)" "$(said "$out")"

yq -i '.mcp.kubernetes.callback_address = "203.0.113.5"' "$CFG"
out=$(K_RUNNING=1 K_TOKEN=kept-token K_PRINTENV_FAIL=1 \
    K_POLICY='{"spec":{"egress":[{"to":[{"ipBlock":{"cidr":"192.0.2.10/32"}}],"ports":[{"port":6443}]},{"to":[{"ipBlock":{"cidr":"10.43.0.9/32"}}],"ports":[{"port":443}]}]}}' run start)
assert_eq "a changed callback over a server that does not answer: the API policy keeps exactly its API addresses" \
    '[{"to":[{"ipBlock":{"cidr":"192.0.2.10/32"}}],"ports":[{"protocol":"TCP","port":6443}]},{"to":[{"ipBlock":{"cidr":"10.43.0.9/32"}}],"ports":[{"protocol":"TCP","port":443}]}]' \
    "$(pol | jq -c '.egress')"
assert_eq "...and the callback policy holds the new callback only (the old one is gone)" '["203.0.113.5/32:8443"]' "$(cpol)"
write_config

echo "=== where the API server is: the kubeconfig's forms ==="
out=$(K_SERVER=https://api.cluster.test run start)
assert_has "exit 0" "exit=0" "$out"
assert_eq "a name is resolved on this machine; no port is 443" '{"cidr":"192.0.2.20/32","port":443}' \
    "$(q 'select(.kind == "NetworkPolicy") | .spec.egress[0] | {"cidr": .to[0].ipBlock.cidr, "port": .ports[0].port}' | head -1)"
out=$(K_SERVER=https://nowhere.test:6443 run start)
assert_has "a name with no address is refused, saying what to set" "set kubernetes.api_endpoints" "$out"
out=$(K_SERVER='https://[2001:db8::1]:6443' run start)
assert_has "an IPv6 address is refused (the policy here takes IPv4)" "is an IPv6 address" "$out"
assert_eq "...before anything is applied" "" "$(q 'select(.kind == "Deployment") | .metadata.name')"
out=$(K_CP_NODES='192.0.2.11 192.0.2.10 192.0.2.12' run start)
assert_has "exit 0" "exit=0" "$out"
assert_eq "a kubeconfig at a control-plane node's address: every control-plane node is allowed, at its port, the kubeconfig's first" \
    '["192.0.2.10/32","192.0.2.11/32","192.0.2.12/32","10.43.0.1/32"]' "$(pols | tail -1)"
assert_has "the pod is asked, with its own kubectl, whether it reaches the first" \
    "exec deployment/aidc-mcp -c mcp -- kubectl --server https://192.0.2.10:6443 --tls-server-name kubernetes.default.svc --request-timeout=5s get --raw /readyz" "$(cat "$K_LOG")"
assert_not_has "...and, as it does, no other is asked and the server is not restarted" "rollout restart" "$(cat "$K_LOG")"
out=$(K_CP_NODES='192.0.2.11 192.0.2.10 192.0.2.12' K_UNREACHABLE='192.0.2.10:6443' run start)
assert_has "a first address the pod does not reach is said" "does not reach the API server at 192.0.2.10:6443: it uses 192.0.2.11:6443" "$out"
assert_eq "...and its kubeconfig is rewritten to the next one it does reach" '"https://192.0.2.11:6443"' \
    "$(q 'select(.kind == "ConfigMap" and .metadata.name == "aidc-mcp-config") | .data.kubeconfig' | tail -1 | jq -r . | yq -o=json '.clusters[0].cluster.server')"
assert_has "...and the server restarted onto it" "rollout restart deployment/aidc-mcp" "$(cat "$K_LOG")"
cms() { q 'select(.kind == "ConfigMap" and .metadata.name == "aidc-mcp-config") | .data.kubeconfig' | jq -r . | yq -o=json '.clusters[0].cluster.server' | jq -sc .; }
out=$(K_RUNNING=1 K_TOKEN=kept-token K_HELD=192.0.2.11:6443 K_CP_NODES='192.0.2.11 192.0.2.10 192.0.2.12' K_UNREACHABLE='192.0.2.10:6443' run start)
assert_has "exit 0" "exit=0" "$out"
assert_eq "a running server is asked which address it reaches before its kubeconfig is written: written once, with that one" \
    '["https://192.0.2.11:6443"]' "$(cms)"
assert_not_has "...and, as it holds that one already, it is not restarted" "rollout restart" "$(cat "$K_LOG")"
out=$(K_RUNNING=1 K_TOKEN=kept-token K_HELD=192.0.2.10:6443 K_CP_NODES='192.0.2.11 192.0.2.10 192.0.2.12' K_UNREACHABLE='192.0.2.10:6443' run start)
assert_eq "a running server that holds an address it no longer reaches: its kubeconfig written once, with the one it reaches" \
    '["https://192.0.2.11:6443"]' "$(cms)"
assert_has "...and restarted onto it" "rollout restart deployment/aidc-mcp" "$(cat "$K_LOG")"
out=$(K_RUNNING=1 K_TOKEN=kept-token K_HELD=192.0.2.10:6443 K_CP_NODES='192.0.2.11 192.0.2.10 192.0.2.12' run start)
assert_not_has "a running server that reaches the address it holds is not restarted" "rollout restart" "$(cat "$K_LOG")"
assert_has "...and, with no record of the mcp image's build here, start says it keeps the image it runs" \
    "no record here of the aidc/mcp:${VERSION_TAG} image's last build (aidc k8s build on this machine makes one): your running MCP server keeps the image it runs; aidc mcp stop, then start" "$out"
assert_eq "...and its pod template carries no digest" "null" "$(pod_meta '.annotations')"

echo "=== aidc mcp start: the image's digest, as aidc k8s build recorded it ==="
RECORD="$XDG_STATE_HOME/aidc/k8s-images"
D1="sha256:$(printf '1%.0s' $(seq 64))" D2="sha256:$(printf '2%.0s' $(seq 64))" D0="sha256:$(printf '0%.0s' $(seq 64))"
mkdir -p "$(dirname "$RECORD")"
printf '%s\n' "https://192.0.2.99:6443 aidc/mcp:${VERSION_TAG} ${D0}" "https://192.0.2.10:6443 aidc/mcp:${VERSION_TAG} ${D1}" \
    "https://192.0.2.10:6443 aidc/broker:${VERSION_TAG} ${D2}" > "$RECORD"
running() { K_RUNNING=1 K_TOKEN=kept-token K_HELD=192.0.2.10:6443 run start; }
out=$(K_RUNNING_DIGEST="$D1" running)
assert_has "exit 0" "exit=0" "$out"
assert_eq "the pod template carries the digest recorded for this cluster's mcp image" "\"$D1\"" \
    "$(pod_meta '.annotations["aidc/image-digest"]')"
assert_not_has "a running server already on it is not restarted (the apply leaves it as it is)" "rollout restart" "$(cat "$K_LOG")"
assert_has "...and start says which image it runs" "image: aidc/mcp:${VERSION_TAG} at ${D1}" "$out"
out=$(K_RUNNING_DIGEST="$D2" running)
assert_eq "a running server on another digest: the template carries the new one, so the apply replaces the pod" "\"$D1\"" \
    "$(pod_meta '.annotations["aidc/image-digest"]')"
assert_has "...and start says it is restarted onto the rebuilt image" \
    "aidc/mcp:${VERSION_TAG} was rebuilt (now ${D1}): your MCP server is restarted onto it" "$out"
assert_has "...and waits for the new pod" "rollout status deployment/aidc-mcp" "$(cat "$K_LOG")"
out=$(running)
assert_eq "a running server whose template has no digest yet: the recorded one goes on it" "\"$D1\"" \
    "$(pod_meta '.annotations["aidc/image-digest"]')"
assert_has "...and start says it is restarted onto it" \
    "your MCP server is restarted onto aidc/mcp:${VERSION_TAG} at ${D1} (which build it runs is not known)" "$out"
out=$(run start)
assert_eq "a new server starts with the recorded digest on its template" "\"$D1\"" \
    "$(pod_meta '.annotations["aidc/image-digest"]')"
out=$(K_SERVER=https://192.0.2.11:6443 K_RUNNING_DIGEST="$D2" K_RUNNING=1 K_TOKEN=kept-token K_HELD=192.0.2.11:6443 run start)
assert_eq "a digest recorded for another cluster is not this one's: the running server's own is kept" "\"$D2\"" \
    "$(pod_meta '.annotations["aidc/image-digest"]')"
assert_has "...and start says there is no record" "no record here of the aidc/mcp:${VERSION_TAG} image's last build" "$out"
out=$(K_DIGEST_READ_FAIL=1 running)
assert_has "a running server whose image the cluster does not say: start stops, changing nothing" \
    "cannot read which image your MCP server runs: the cluster did not answer (Unable to connect to the server; nothing was changed)" "$out"
assert_has "...exit 1" "exit=1" "$out"
assert_eq "...and nothing is applied" "" "$(cat "$K_APPLIED")"
rm -f "$RECORD"
out=$(K_RUNNING_DIGEST="$D2" running)
assert_eq "no record here: the running server's digest is kept on its template, so the apply changes nothing" "\"$D2\"" \
    "$(pod_meta '.annotations["aidc/image-digest"]')"
assert_not_has "...and it is not restarted" "rollout restart" "$(cat "$K_LOG")"
out=$(K_CP_NODES='198.51.100.1 198.51.100.2' run start)
assert_eq "a kubeconfig address that is no control-plane node's (a load balancer, a tunnel): that address only" \
    '["192.0.2.10/32","10.43.0.1/32"]' "$(pols | tail -1)"
out=$(K_UNREACHABLE='192.0.2.10:6443' run start)
assert_has "an address the laptop resolved but the pod cannot reach is refused, saying what to set" \
    "your MCP server's pod reaches the API server at none of 192.0.2.10:6443 (Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout): set kubernetes.api_endpoints" "$out"
assert_has "...exit 1" "exit=1" "$out"
# The error comes on stderr, never as an address: a running server's first ask, which reached
# none, shows nothing; the check after it shows its error once, in the refusal.
out=$(K_RUNNING=1 K_TOKEN=kept-token K_HELD=192.0.2.10:6443 K_UNREACHABLE='192.0.2.10:6443' run start)
assert_eq "a running server that reaches none: the error is shown once, in the refusal" "1 1" \
    "$(printf '%s\n' "$out" | grep -c 'i/o timeout') $(printf '%s\n' "$out" | grep -c "reaches the API server at none of 192.0.2.10:6443 (Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout)")"
assert_not_has "...and its kubeconfig is never written with the error for an address" "Unable to connect" "$(cms)"
out=$(K_EXEC_FAIL=1 run start)
assert_has "an exec that fails for its own reason says so, not as an unreached address" \
    'reaches the API server at none of 192.0.2.10:6443 (error: unable to upgrade connection: container not found ("mcp"))' "$out"
yq -i '.kubernetes.mcp_state_size = "20Gi"' "$CFG"
out=$(K_NO_STATE=1 run start)
assert_eq "kubernetes.mcp_state_size sets the state claim's size" '"20Gi"' \
    "$(q 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "aidc-mcp-state") | .spec.resources.requests.storage')"
write_config

echo "=== aidc mcp start: refusals ==="
out=$(K_SECRET_READ_FAIL=1 run start)
assert_has "a cluster that does not say whether there is a token stops start" \
    "cannot read your MCP token in aidc-u-alice: the cluster did not answer" "$out"
assert_eq "...and nothing is made (a second token, say)" "" "$(cat "$K_APPLIED")"
out=$(K_SERVER=https://127.0.0.1:6443 run start)
assert_has "a kubeconfig that reaches the API server at loopback is refused: the pod could not" \
    "set kubernetes.api_endpoints" "$out"
assert_eq "...before the server is applied" "" "$(q 'select(.kind == "Deployment") | .metadata.name')"
out=$(K_ROLLOUT_FAIL=1 run start)
assert_has "a server that does not become ready says where to look" \
    "kubectl -n aidc-u-alice describe pod -l app=aidc-mcp" "$out"

echo "=== kubernetes.api_endpoints and mcp.session_create ==="
write_config "$(printf 'mcp:\n  session_create: true\n')"
yq -i '.kubernetes.api_endpoints = ["198.51.100.7:6443", "198.51.100.8:6443"]' "$CFG"
out=$(K_NO_STATE=1 run start)
assert_has "exit 0" "exit=0" "$out"
assert_eq "the configured API endpoints are used, not the kubeconfig's" \
    '["198.51.100.7/32","198.51.100.8/32","10.43.0.1/32"]' "$(pol | jq -c '[.egress[].to[0].ipBlock.cidr]')"
assert_eq "...and the pod's kubectl goes to the first of them" '"https://198.51.100.7:6443"' \
    "$(q 'select(.kind == "ConfigMap" and .metadata.name == "aidc-mcp-config") | .data.kubeconfig' | jq -r . | yq -o=json '.clusters[0].cluster.server')"
assert_not_has "...and the kubeconfig is not asked" "config view" "$(cat "$K_LOG")"
assert_eq "session_create is offered when mcp.session_create is true" '"true"' \
    "$(pod '.containers[0].env[] | select(.name == "AIDC_MCP_SESSION_CREATE") | .value')"
yq -i '.kubernetes.api_endpoints = ["api.example.org:6443"]' "$CFG"
out=$(K_NO_STATE=1 run start)
assert_has "an endpoint that is not <ipv4>:<port> is refused" "kubernetes.api_endpoints: api.example.org:6443 is not <ipv4>:<port>" "$out"
write_config

echo "=== aidc mcp stop, status, logs ==="
out=$(K_RUNNING=1 run stop)
assert_has "stop removes the server, its policies and Ingress" "delete deployment,networkpolicy,ingress -l app=aidc-mcp" "$(cat "$K_LOG")"
assert_not_has "...and keeps its Service: sessions' policy sidecars hold its address for the taint webhook" "service" \
    "$(grep ' delete ' "$K_LOG")"
assert_not_has "...and keeps its state, token and the transcripts" "delete pvc" "$(cat "$K_LOG")"
assert_not_has "..." "delete secret" "$(cat "$K_LOG")"
out=$(run stop)
assert_has "stop with none running says so" "your MCP server is not running" "$out"
out=$(K_DOWN=1 run stop)
assert_has "stop with a cluster that does not answer says so, and deletes nothing" "cannot tell whether your MCP server runs" "$out"
assert_not_has "..." "delete" "$(cat "$K_LOG")"
out=$(K_RUNNING=1 run status)
assert_has "status: running" "aidc-mcp (kubernetes, aidc-u-alice): RUNNING" "$out"
assert_has "...with the last access log event" 'last event:  {"event": "tool_call"' "$out"
assert_has "...and where the token is" "token file:  ${TOKEN_FILE}" "$out"
out=$(K_RUNNING=1 run status)
assert_has "...with the state claim's use" "state claim: 12% used" "$out"
out=$(K_RUNNING=1 K_DF=85 run status)
assert_has "...and a warning when it is nearly full (a full claim stops replies)" "85% used (WARNING" "$out"
out=$(K_STARTING=1 run status)
assert_has "status: starting" "): STARTING" "$out"
out=$(K_STARTING=1 K_WAITING='ImagePullBackOff ' run status)
assert_has "a pod that cannot start says why, and where to look" "waiting:     ImagePullBackOff (see: aidc mcp logs" "$out"
out=$(run status)
assert_has "status: not running" "): NOT RUNNING" "$out"
out=$(K_DOWN=1 run status)
assert_has "a cluster that does not answer is unknown, never NOT RUNNING" "): unknown (the cluster did not answer" "$out"
out=$(run logs --follow)
assert_has "logs: the server's container log, followed" "logs -f deployment/aidc-mcp -c mcp" "$(cat "$K_LOG")"

echo "=== aidc mcp token rotate and show ==="
printf 'old-token\n' > "$TOKEN_FILE"
out=$(K_RUNNING=1 K_TOKEN=old-token run token rotate)
new_tok=$(q 'select(.kind == "Secret") | .stringData.token' | tr -d '"')
assert_has "exit 0" "exit=0" "$out"
assert_eq "a new token is made" yes "$([ -n "$new_tok" ] && [ "$new_tok" != old-token ] && echo yes || echo no)"
assert_eq "the old Secret is removed before the new one is made" "delete create" \
    "$(grep -oE 'delete secret aidc-mcp-token|create -f -' "$K_LOG" | awk '{print $1}' | paste -sd' ' -)"
assert_has "the server is restarted, so it takes the new token (an open MCP session is refused on its next message)" \
    "rollout restart deployment/aidc-mcp" "$(cat "$K_LOG")"
assert_eq "this machine's copy is the new token" "$new_tok" "$(cat "$TOKEN_FILE")"
assert_has "the new token is printed, as on Docker" "$new_tok" "$out"
assert_not_has "...but never on a command line" "$new_tok" "$(cat "$K_LOG")"
out=$(run token rotate)
assert_not_has "a server that is not running is not restarted" "rollout restart" "$(cat "$K_LOG")"
out=$(K_TOKEN=shown-token run token show)
assert_has "token show prints the Secret's token" "shown-token" "$out"
out=$(run token show)
assert_has "token show with none says to start first" "run 'aidc mcp start' first" "$out"
out=$(K_RUNNING=1 K_DELETE_FAIL=1 run token rotate)
assert_has "an old token the cluster does not remove: nothing changes, and it says so" "could not remove the old token" "$out"
assert_not_has "...no new token is made" "create -f -" "$(cat "$K_LOG")"
out=$(K_RUNNING=1 K_CREATE_FAIL=1 run token rotate)
assert_has "a new token the cluster does not take says what to do" "run aidc mcp token rotate again" "$out"

echo "=== routing: aidc mcp goes to the configured backend ==="
out=$(run status --backend docker)
assert_not_has "--backend docker keeps it on Docker" "aidc-mcp (kubernetes" "$out"
assert_has "...where the Docker server is asked" "docker " "$(cat "$K_LOG")"
yq -i 'del(.backend)' "$CFG"
out=$(run status)
assert_not_has "a config with no backend: line is Docker's" "aidc-mcp (kubernetes" "$out"
out=$(run status --backend kubernetes)
assert_has "--backend kubernetes goes to the cluster" "aidc-mcp (kubernetes, aidc-u-alice)" "$out"
out=$(run help --backend kubernetes)
assert_has "help names the cluster form" "Your MCP server in the cluster" "$out"
write_config

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "$FAIL" -eq 0 ]
