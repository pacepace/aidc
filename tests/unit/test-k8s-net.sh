#!/usr/bin/env bash
# Unit tests for a Kubernetes session's ports and ways out (W-K2): tunnels (K8S-14), LAN pages
# (K8S-15), TCP egress relays and the names responder (NET-15), --gpu (K8S-11), --dns and
# --network (K8S-01's cluster forms), clean-env.
#
# What these guard is the sandbox's edge: a relay that could reach more than its one address and
# port, a names responder that forwarded lookups, a page any pod could open, a login silently
# dropped, a tunnel that did not come back. kubectl is a PATH stub; HOME holds the config. Needs
# yq and jq; skips without them.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-net-$$"
PASS=0
FAIL=0
cleanup() {
    # Any supervisor a test left running.
    pkill -f "tunnel-supervisor.sh aidc-u-alice" 2>/dev/null || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/aidc" "$SCRATCH/state"

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

# kubectl stub. Logs every call to $K_LOG; apply appends stdin to $K_APPLIED. State in $K_STATE:
#   uid           the dev pod's uid (the supervisor watches it)
#   relays.json   what `get deployment -l ...app=egress -o json` answers
#   names         what the names responder was last given (exec -i ... -c names)
#   pf.<n>        each port-forward the supervisor started
# K_EXISTS=1 the session demo exists. K_PF_BUSY=1 port-forward cannot listen.
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
case "$*" in
    *"get runtimeclass"*"-o json"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"apply -f -"*) cat >> "$K_APPLIED" ;;
    *"rollout status"*) : ;;
    *"get deployment,statefulset -l aidc/session=demo"*) [ "${K_EXISTS:-}" = 1 ] && echo "statefulset.apps/demo-dev" ;;
    *"get deployment,statefulset -l"*) : ;;
    *"get statefulset demo-dev -o jsonpath={.metadata.annotations.aidc/audit}"*) printf 'demo-audit-20261124050000' ;;
    *"get statefulset demo-dev -o jsonpath={.metadata.annotations.aidc/ports}"*) printf '%s' "${K_PORTS:-}" ;;
    *"get deployment -l aidc/session=demo,app=egress -o json"*) cat "$K_STATE/relays.json" 2>/dev/null ;;
    *"get service -l aidc/session=demo,app=egress -o json"*)
        [ -s "$K_STATE/relays.json" ] && jq '{items: [.items[] | {metadata: {name: .metadata.name}, spec: {clusterIP: "10.45.7.7"}}]}' "$K_STATE/relays.json" ;;
    *"get networkpolicy -l aidc/session=demo,app=network -o json"*) cat "$K_STATE/nets.json" 2>/dev/null ;;
    *"-n shop get service -o json"*) echo '{"items":[{"metadata":{"name":"db"},"spec":{"clusterIP":"10.45.8.8"}},{"metadata":{"name":"headless"},"spec":{"clusterIP":"None"}}]}' ;;
    *"get pod -l aidc/session=demo,app=proxy"*) echo "pod/demo-proxy-abc" ;;
    *"exec -i pod/demo-proxy-abc -c names"*) cat > "$K_STATE/names" ;;
    *"exec demo-dev-0 -c dev -- getent hosts"*) exit 0 ;;
    *"get pod demo-dev-0"*"jsonpath="*) printf '%s|Running|' "$(cat "$K_STATE/uid" 2>/dev/null || echo uid1)" ;;
    *"port-forward pod/demo-dev-0"*)
        n=$(ls "$K_STATE" | grep -c '^pf\.')
        printf '%s\n' "$*" > "$K_STATE/pf.$n"
        if [ "${K_PF_BUSY:-}" = 1 ]; then
            echo "Unable to listen on port 18080: Listeners failed to create with the following errors: [unable to create listener: Error listen tcp4 127.0.0.1:18080: bind: address already in use]" >&2
            echo "error: unable to listen on any of the requested ports: [{18080 8080}]" >&2
            exit 1
        fi
        echo "Forwarding from 127.0.0.1:18080 -> 8080"
        exec sleep 300 ;;
    *"get pvc disk"*) printf 'Bound' ;;
    *"get networkpolicy default-deny"*) echo "networkpolicy.networking.k8s.io/default-deny" ;;
    *"get ingress"*) [ -n "${K_INGRESS_HOSTS:-}" ] && echo "{\"items\":[{\"metadata\":{\"namespace\":\"other\",\"name\":\"site\"},\"spec\":{\"rules\":[{\"host\":\"${K_INGRESS_HOSTS}\"}]}}]}" || echo '{"items":[]}' ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"

export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" K_LOG="$SCRATCH/kubectl.log" \
    K_APPLIED="$SCRATCH/applied.yaml" K_STATE="$SCRATCH/state" PATH="$SCRATCH/bin:$PATH" \
    XDG_STATE_HOME="$SCRATCH/xdg"
AIDC_VERSION_TAG=$(head -n1 "$AIDC_ROOT/VERSION" | tr -d '\r' | tr '+' '_')
export AIDC_VERSION_TAG
cat > "$HOME/.config/aidc/config.yaml" <<'EOF'
kubernetes:
  user: alice
  storage_class: shared-disk
  ingress: {domain: pages.example.org, class: traefik}
EOF

# The libraries, for the renders.
# shellcheck source=../../scripts/k8s/lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=../../scripts/k8s/manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=../../scripts/k8s/net.sh
. "$AIDC_SCRIPTS/k8s/net.sh"
# shellcheck source=../../scripts/k8s/tunnel.sh
. "$AIDC_SCRIPTS/k8s/tunnel.sh"
# shellcheck source=../../scripts/k8s/expose.sh
. "$AIDC_SCRIPTS/k8s/expose.sh"
k8s_load_settings
SEL='{"kubernetes.io/hostname":"n1"}'
yj() { printf '%s\n' "$2" | yq -N ea "$1" -o=json -I=0 -; }

echo "=== a TCP egress relay (NET-15) ==="
r=$(k8s_render_relay demo db.lan.example.org 192.168.5.20 declared demo-audit-1 "$SEL" 5432 6432)
assert_eq "one relay per host, named for the session and the host" "demo-egress-db-lan-example-org" \
    "$(yj 'select(.kind == "Deployment") | .metadata.name' "$r" | tr -d '"')"
assert_eq "its Service carries each port" '[5432,6432]' "$(yj 'select(.kind == "Service") | [.spec.ports[].port]' "$r")"
assert_eq "the relay may open only the destination's /32, on those ports" \
    '[{"to":[{"ipBlock":{"cidr":"192.168.5.20/32"}}],"ports":[{"protocol":"TCP","port":5432},{"protocol":"TCP","port":6432}]}]' \
    "$(yj 'select(.kind == "NetworkPolicy" and .metadata.name == "demo-egress-db-lan-example-org") | .spec.egress' "$r")"
assert_eq "and takes connections only from the session's dev pod" \
    '[{"from":[{"podSelector":{"matchLabels":{"aidc/session":"demo","app":"dev"}}}],"ports":[{"protocol":"TCP","port":5432},{"protocol":"TCP","port":6432}]}]' \
    "$(yj 'select(.kind == "NetworkPolicy" and .metadata.name == "demo-egress-db-lan-example-org") | .spec.ingress' "$r")"
assert_eq "the dev pod may open the relay on those ports, and nothing else by this policy" \
    '[{"to":[{"podSelector":{"matchLabels":{"aidc/relay":"demo-egress-db-lan-example-org"}}}],"ports":[{"protocol":"TCP","port":5432},{"protocol":"TCP","port":6432}]}]' \
    "$(yj 'select(.kind == "NetworkPolicy" and .metadata.name == "demo-egress-db-lan-example-org-dev") | .spec.egress' "$r")"
cmd=$(yj 'select(.kind == "Deployment") | .spec.template.spec.containers[0].command[2]' "$r")
assert_has "socat forwards to the address, not the name" "TCP:192.168.5.20:5432" "$cmd"
assert_has "and logs every connection to the session's audit trail" "/var/aidc/audit/egress-db-lan-example-org-6432.log" "$cmd"
assert_eq "on the session's audit claim" '"demo-audit-1"' \
    "$(yj 'select(.kind == "Deployment") | .spec.template.spec.volumes[0].persistentVolumeClaim.claimName' "$r")"
assert_eq "the relay has no DNS, no API token" '["None",["192.0.2.1"],false]' \
    "$(yj 'select(.kind == "Deployment") | .spec.template.spec | [.dnsPolicy, .dnsConfig.nameservers, .automountServiceAccountToken]' "$r")"
assert_eq "the session reaches it by the destination's own name" '"db.lan.example.org"' \
    "$(yj 'select(.kind == "Deployment") | .metadata.annotations["aidc/egress-reach-as"]' "$r")"
r=$(k8s_render_relay demo 192.168.5.21 192.168.5.21 live demo-audit-1 "$SEL" 22)
assert_eq "an IPv4 destination is reached by the relay's name, as on Docker" '"aidc-demo-egress-192-168-5-21"' \
    "$(yj 'select(.kind == "Deployment") | .metadata.annotations["aidc/egress-reach-as"]' "$r")"
long="a$(printf 'b%.0s' $(seq 1 60)).example.org"
n=$(k8s_relay_name demo "$long")
assert_eq "a long host name still makes a valid object name (63 at most)" "yes" "$([ "${#n}" -le 63 ] && echo yes)"
assert_eq "  and a stable one" "$n" "$(k8s_relay_name demo "$long")"

echo "=== the session: names responder, DNS, GPU, ports ==="
s=$(AIDC_K8S_PORTS="18080:8080" k8s_render_session demo /home/alice/code/p multi "$SEL" demo-audit-1 10.45.9.9)
names=$(yj 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "names")' "$s")
assert_has "the proxy pod runs the names responder" '"command":["dnsmasq"' "$names"
assert_has "  with no upstream: it forwards nothing" '"--no-resolv"' "$names"
assert_not_has "  and names no server to forward to" '--server' "$names"
assert_has "  and not the pod's own hosts file" '"--no-hosts"' "$names"
assert_has "  serving the folder aidc writes, on the session's state claim" \
    '{"name":"state","mountPath":"/var/aidc/names","subPath":"names"}' "$names"
assert_eq "the dev pod's only nameserver is that responder, through its proxy's address" '["10.45.9.9"]' \
    "$(yj 'select(.kind == "StatefulSet") | .spec.template.spec.dnsConfig.nameservers' "$s")"
assert_eq "the proxy Service carries squid and DNS" '[[3128,"TCP"],[53,"UDP"],[53,"TCP"]]' \
    "$(yj 'select(.kind == "Service") | [.spec.ports[] | [.port, .protocol]]' "$s")"
assert_eq "no GPU unless asked" "null" \
    "$(yj 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].resources.limits["nvidia.com/gpu"]' "$s")"
assert_eq "the declared ports are recorded on the StatefulSet (metadata: changing it restarts nothing)" '"18080:8080"' \
    "$(yj 'select(.kind == "StatefulSet") | .metadata.annotations["aidc/ports"]' "$s")"
assert_eq "squid and the proxy pod resolve through Quad9 by default" '["9.9.9.9","149.112.112.112"]' \
    "$(yj 'select(.kind == "Deployment") | .spec.template.spec.dnsConfig.nameservers' "$s")"
s=$(AIDC_K8S_GPU=1 AIDC_K8S_DNS_SERVERS="10.0.0.53 1.1.1.1" k8s_render_session demo /home/alice/code/p multi "$SEL" demo-audit-1 10.45.9.9)
assert_eq "--gpu: one GPU in the dev container's limits" '1' \
    "$(yj 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].resources.limits["nvidia.com/gpu"]' "$s")"
assert_eq "  and the node selector is the same" "$SEL" \
    "$(yj 'select(.kind == "StatefulSet") | .spec.template.spec.nodeSelector' "$s")"
assert_eq "--dns: the proxy pod resolves through the user's servers" '["10.0.0.53","1.1.1.1"]' \
    "$(yj 'select(.kind == "Deployment") | .spec.template.spec.dnsConfig.nameservers' "$s")"
sq=$(yj 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "squid") | .env' "$s")
assert_has "  squid is told so" '{"name":"AIDC_DNS_SERVERS","value":"10.0.0.53 1.1.1.1"}' "$sq"
assert_has "  as the user's own choice (the public-only squid takes it, still refusing private answers)" \
    '{"name":"AIDC_DNS_USER_CHOSEN","value":"1"}' "$sq"
assert_has "  and the proxy may reach each server on 53, a private one included" \
    '{"to":[{"ipBlock":{"cidr":"10.0.0.53/32"}}],"ports":[{"protocol":"UDP","port":53},{"protocol":"TCP","port":53}]}' \
    "$(yj 'select(.kind == "NetworkPolicy" and .metadata.name == "demo-proxy-public-only") | .spec.egress' "$s")"
assert_eq "  and nothing else private" '["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","127.0.0.0/8"]' \
    "$(yj 'select(.kind == "NetworkPolicy" and .metadata.name == "demo-proxy-public-only") | .spec.egress[] | select(.to[0].ipBlock.cidr == "0.0.0.0/0") | .to[0].ipBlock.except' "$s")"

echo "=== networks: another namespace (NET-13's cluster form) ==="
for bad in kube-system kube-public default aidc-system aidc-u-bob aidc-u-alice "Bad_NS"; do
    if why=$(k8s_network_refusal "$bad"); then
        echo "  PASS: ${bad} is refused (${why})"; PASS=$((PASS + 1))
    else
        echo "  FAIL: ${bad} is refused"; FAIL=$((FAIL + 1))
    fi
done
if k8s_network_refusal shop >/dev/null; then echo "  FAIL: an ordinary namespace is taken"; FAIL=$((FAIL + 1)); else echo "  PASS: an ordinary namespace is taken"; PASS=$((PASS + 1)); fi
p=$(k8s_render_network demo shop)
assert_eq "the dev pod may reach every pod of that namespace, any port" \
    '[{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"shop"}}}]}]' \
    "$(yj '.spec.egress' "$p")"

echo "=== the names the responder serves ==="
rm -f "$K_STATE/relays.json" "$K_STATE/nets.json"
k8s_render_relay demo db.lan.example.org 192.168.5.20 declared a "$SEL" 5432 \
    | yq -N ea 'select(.kind == "Deployment")' -o=json - | jq -s '{items: .}' > "$K_STATE/relays.json"
echo '{"items":[{"metadata":{"annotations":{"aidc/network":"shop"}}}]}' > "$K_STATE/nets.json"
hosts=$(k8s_names_hosts aidc-u-alice demo)
assert_has "a relay's name, at its Service's address" "10.45.7.7 db.lan.example.org" "$hosts"
assert_has "a --network namespace's Services, by <svc>.<ns> and the cluster forms" \
    "10.45.8.8 db.shop db.shop.svc db.shop.svc.cluster.local" "$hosts"
assert_not_has "a headless Service has no address to give" "headless" "$hosts"
: > "$K_LOG"
k8s_names_sync aidc-u-alice demo 2>/dev/null
assert_eq "sync writes exactly that into the responder" "$hosts" "$(cat "$K_STATE/names")"
assert_has "  through the proxy pod's names container" "exec -i pod/demo-proxy-abc -c names" "$(cat "$K_LOG")"

echo "=== LAN pages (K8S-15) ==="
assert_eq "the first page is <session>-<user>.<domain>" "demo-alice.pages.example.org" "$(k8s_expose_host demo 8080 1)"
assert_eq "a further one names its port" "demo-3000-alice.pages.example.org" "$(k8s_expose_host demo 3000 0)"
e=$(k8s_render_expose demo "" 8080)
assert_eq "only the ingress controller's pods may open the port" \
    '[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"traefik"}}}],"ports":[{"protocol":"TCP","port":8080}]}]' \
    "$(yj 'select(.kind == "NetworkPolicy") | .spec.ingress' "$e")"
assert_eq "an Ingress at the page's name, on the configured class" '["traefik","demo-alice.pages.example.org","demo-dev",8080]' \
    "$(yj 'select(.kind == "Ingress") | [.spec.ingressClassName, .spec.rules[0].host, .spec.rules[0].http.paths[0].backend.service.name, .spec.rules[0].http.paths[0].backend.service.port.number]' "$e")"
assert_eq "TLS with the controller's default certificate when the config names none" '[{"hosts":["demo-alice.pages.example.org"]}]' \
    "$(yj 'select(.kind == "Ingress") | .spec.tls' "$e")"
assert_eq "no login unless asked" "" "$(yj 'select(.kind == "Secret" or .kind == "Middleware") | .kind' "$e")"
line=$(k8s_htpasswd_line u1 s3cret)
case "$line" in 'u1:$apr1$'*) echo "  PASS: the login is kept as an apr1 hash"; PASS=$((PASS + 1)) ;; *) echo "  FAIL: apr1 hash ($line)"; FAIL=$((FAIL + 1)) ;; esac
assert_not_has "  never the password" "s3cret" "$line"
e=$(k8s_render_expose demo "$line" 8080)
assert_eq "Traefik: a basicAuth Middleware on the login Secret" '{"secret":"demo-login","realm":"demo"}' \
    "$(yj 'select(.kind == "Middleware") | .spec.basicAuth' "$e")"
assert_eq "  the Ingress goes through it" '"aidc-u-alice-demo-login@kubernetescrd"' \
    "$(yj 'select(.kind == "Ingress") | .metadata.annotations["traefik.ingress.kubernetes.io/router.middlewares"]' "$e")"
assert_eq "  the Secret holds the hash" "\"$line\"" "$(yj 'select(.kind == "Secret") | .stringData.users' "$e" | sed 's/\\\$/$/g')"
e=$(AIDC_K8S_INGRESS_CONTROLLER=nginx AIDC_K8S_INGRESS_TLS_SECRET=wild k8s_render_expose demo "$line" 8080)
assert_eq "ingress-nginx: its auth annotations on the login Secret" '["basic","demo-login"]' \
    "$(yj 'select(.kind == "Ingress") | [.metadata.annotations["nginx.ingress.kubernetes.io/auth-type"], .metadata.annotations["nginx.ingress.kubernetes.io/auth-secret"]]' "$e")"
assert_eq "  and no Traefik Middleware" "" "$(yj 'select(.kind == "Middleware") | .kind' "$e")"
assert_eq "a TLS Secret named in the config is used" '[{"hosts":["demo-alice.pages.example.org"],"secretName":"wild"}]' \
    "$(yj 'select(.kind == "Ingress") | .spec.tls' "$e")"
e=$(AIDC_K8S_INGRESS_CLUSTER_ISSUER=letsencrypt k8s_render_expose demo "" 8080)
assert_eq "a cert-manager ClusterIssuer gets a certificate per page" '["letsencrypt","demo-expose-8080-tls"]' \
    "$(yj 'select(.kind == "Ingress") | [.metadata.annotations["cert-manager.io/cluster-issuer"], .spec.tls[0].secretName]' "$e")"
out=$(AIDC_K8S_INGRESS_CONTROLLER=other k8s_expose_check demo 1 8080 2>&1); rc=$?
assert_has "--login on a controller aidc cannot put a login in front of is refused, not dropped" "puts a login in front of a page with Traefik or ingress-nginx" "$out"
assert_eq "  (refused)" 1 "$rc"
out=$(AIDC_K8S_INGRESS_DOMAIN="" k8s_expose_check demo 0 8080 2>&1)
assert_has "--expose without a domain in the config says where it goes" "kubernetes.ingress.domain" "$out"
out=$(k8s_expose_check "s$(printf 'x%.0s' $(seq 1 60))" 0 8080 2>&1)
assert_has "a page name longer than a DNS label is refused" "longer than 63" "$out"

echo "=== tunnels (K8S-14) ==="
assert_eq "N is N:N" "3000 3000" "$(k8s_port_spec 3000)"
assert_eq "H:C" "18080 8080" "$(k8s_port_spec 18080:8080)"
for bad in 0 70000 abc 1:2:3 :80 080; do
    if k8s_port_spec "$bad" >/dev/null 2>&1; then echo "  FAIL: '$bad' is refused"; FAIL=$((FAIL + 1)); else echo "  PASS: '$bad' is refused"; PASS=$((PASS + 1)); fi
done
export AIDC_K8S_TUNNEL_CHECK=1 AIDC_K8S_TUNNEL_WAIT=10
echo uid1 > "$K_STATE/uid"; rm -f "$K_STATE"/pf.*
k8s_tunnel_start aidc-u-alice demo 18080 8080 2>&1
pid=$(k8s_tunnel_pid aidc-u-alice demo 18080) || pid=""
assert_eq "a tunnel's supervisor runs, detached" "yes" "$([ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo yes)"
assert_has "it runs kubectl port-forward on 127.0.0.1 only" "port-forward pod/demo-dev-0 --address 127.0.0.1 18080:8080" "$(cat "$K_STATE/pf.0" 2>/dev/null)"
assert_eq "it is listed" "18080 8080 ${pid}" "$(k8s_tunnels aidc-u-alice demo)"
# A new dev pod (restart, upgrade, node reboot): the forward is started again on it.
echo uid2 > "$K_STATE/uid"
for _ in $(seq 1 20); do [ -e "$K_STATE/pf.1" ] && break; sleep 0.5; done
assert_eq "a new dev pod gets a new port-forward" "yes" "$([ -e "$K_STATE/pf.1" ] && echo yes)"
log=$(cat "$(k8s_tunnel_dir aidc-u-alice)/demo-18080.log")
assert_has "  and the log says why" "the dev pod changed (uid1 -> uid2); reconnecting" "$log"
# The port-forward exits by itself (a dropped connection): started again.
pkill -f "sleep 300" 2>/dev/null
for _ in $(seq 1 20); do [ -e "$K_STATE/pf.2" ] && break; sleep 0.5; done
assert_eq "a port-forward that ends is started again" "yes" "$([ -e "$K_STATE/pf.2" ] && echo yes)"
k8s_tunnel_stop aidc-u-alice demo 18080
assert_eq "stop ends the supervisor" "gone" "$(kill -0 "$pid" 2>/dev/null && echo running || echo gone)"
sleep 0.5
assert_eq "  and its port-forward" "" "$(pgrep -f 'sleep 300' || true)"
assert_eq "  and forgets the tunnel" "" "$(k8s_tunnels aidc-u-alice demo)"
out=$(K_PF_BUSY=1 k8s_tunnel_start aidc-u-alice demo 18080 8080 2>&1); rc=$?
assert_has "a host port in use here is said so" "localhost:18080 is taken on this machine" "$out"
assert_eq "  start fails" 1 "$rc"
assert_eq "  and leaves no supervisor" "" "$(k8s_tunnels aidc-u-alice demo)"

run() { : > "$K_APPLIED"; : > "$K_LOG"; (cd "$HOME" && "$AIDC_ROOT/scripts/aidc" "$@" 2>&1 </dev/null); echo "exit=$?"; }

echo "=== aidc proxy on Kubernetes ==="
echo uid1 > "$K_STATE/uid"; rm -f "$K_STATE"/pf.*
out=$(K_EXISTS=1 run proxy demo add 18080:8080)
assert_has "add starts a tunnel" "tunnel: localhost:18080 -> demo:8080" "$out"
out=$(K_EXISTS=1 K_PORTS=18080:8080 run proxy demo ls)
assert_has "ls shows the declared ports" "declared (aidc create --port): 18080:8080" "$out"
assert_has "and this machine's tunnel, with its supervisor" "localhost:18080 -> demo:8080" "$out"
out=$(K_EXISTS=1 run status demo)
assert_has "status lists the tunnel" "localhost:18080 -> demo:8080  tunnel up" "$out"
out=$(K_EXISTS=1 run proxy demo rm 18080)
assert_has "rm stops it" "stopped the tunnel on localhost:18080" "$out"
out=$(K_EXISTS=1 K_PORTS=18080:8080 run proxy demo up)
assert_has "up starts the declared ports on this machine" "tunnel: localhost:18080 -> demo:8080" "$out"
out=$(K_EXISTS=1 run proxy demo clear)
assert_has "clear stops every tunnel of the session" "stopped the tunnels on localhost:18080" "$out"
out=$(K_EXISTS=1 run proxy demo add 99999)
assert_has "a bad port is refused" "invalid host port" "$out"

echo "=== aidc egress on Kubernetes (live, no restart) ==="
rm -f "$K_STATE/relays.json" "$K_STATE/nets.json" "$K_STATE/names"
out=$(K_EXISTS=1 run egress demo add 192.168.5.21:22)
assert_has "add makes the relay" "egress: aidc-demo-egress-192-168-5-21:22 -> 192.168.5.21:22 (live" "$out"
assert_has "  its Deployment, Service and policies" "kind: Deployment" "$(cat "$K_APPLIED")"
assert_has "  writes its name into the responder" "exec -i pod/demo-proxy-abc -c names" "$(cat "$K_LOG")"
assert_not_has "  and never touches the dev pod" "demo-dev-0 --" "$(grep -E 'delete|patch|rollout restart' "$K_LOG")"
assert_not_has "  (no StatefulSet change)" "statefulset" "$(grep -E 'apply|patch' "$K_LOG")"
out=$(K_EXISTS=1 run egress demo add 127.0.0.1:5432)
assert_has "a loopback destination is refused" "is loopback" "$out"
assert_eq "  and nothing is made" "" "$(cat "$K_APPLIED")"
k8s_render_relay demo 192.168.5.21 192.168.5.21 live a "$SEL" 22 \
    | yq -N ea 'select(.kind == "Deployment")' -o=json - | jq -s '{items: [.[] | .status = {readyReplicas: 1}]}' > "$K_STATE/relays.json"
out=$(K_EXISTS=1 run egress demo ls)
assert_has "ls lists it" "aidc-demo-egress-192-168-5-21:22" "$out"
out=$(K_EXISTS=1 run egress demo add 192.168.5.21:2222)
assert_has "a second port on the same host re-makes its relay with both" "aidc/egress-ports: \"22 2222\"" "$(cat "$K_APPLIED")"
out=$(K_EXISTS=1 run egress demo rm 192.168.5.21:22)
assert_has "rm of its only port removes the relay" "delete deployment/demo-egress-192-168-5-21 service/demo-egress-192-168-5-21 networkpolicy/demo-egress-192-168-5-21 networkpolicy/demo-egress-192-168-5-21-dev" "$(cat "$K_LOG")"
assert_has "  and writes the names again" "exec -i pod/demo-proxy-abc -c names" "$(cat "$K_LOG")"

echo "=== aidc network on Kubernetes ==="
rm -f "$K_STATE/relays.json" "$K_STATE/nets.json"
out=$(K_EXISTS=1 run network demo add kube-system)
assert_has "a system namespace is refused" "refusing kube-system" "$out"
out=$(K_EXISTS=1 run network demo add aidc-u-alice)
assert_has "the user's own namespace (the git login, other sessions) is refused" "refusing aidc-u-alice" "$out"
out=$(K_EXISTS=1 run network demo add shop)
assert_has "add lets the session reach the namespace" "network: demo -> every pod of shop, any port" "$out"
assert_has "  says it bypasses squid" "NOT proxied by squid" "$out"
assert_has "  by its own policy" "name: demo-net-shop" "$(cat "$K_APPLIED")"

echo "=== aidc create: the new flags ==="
mkdir -p "$HOME/code/p"
crun() { : > "$K_APPLIED"; : > "$K_LOG"; (cd "$HOME/code/p" && "$AIDC_ROOT/scripts/aidc" create demo --backend kubernetes "$@" 2>&1 </dev/null); echo "exit=$?"; }
out=$(crun --port 70000)
assert_has "a bad --port is refused before anything is made" "invalid --port/ports: entry: 70000" "$out"
assert_eq "  (nothing applied)" "" "$(cat "$K_APPLIED")"
out=$(crun --login)
assert_has "--login with nothing exposed is refused" "give --expose <port> too" "$out"
out=$(crun --dns 1.1.1.1 --dns 1.0.0.1 --dns 9.9.9.9 --dns 8.8.8.8)
assert_has "more than three DNS servers is refused (a pod takes three)" "at most 3 DNS servers" "$out"
out=$(crun --dns fd00::53)
assert_has "an IPv6 DNS server is refused on this backend" "an IPv4 address on the kubernetes backend" "$out"
out=$(crun --network kube-system)
assert_has "a refused --network is refused before anything is made" "refusing --network kube-system" "$out"
assert_eq "  (nothing applied)" "" "$(cat "$K_APPLIED")"
out=$(crun --egress-tcp 127.0.0.1:22)
assert_has "a loopback --egress-tcp is refused before anything is made" "is loopback" "$out"
out=$(K_INGRESS_HOSTS=demo-alice.pages.example.org crun --expose 8080)
assert_has "a page name another Ingress serves is refused, saying which" "already served by ingress other/site" "$out"
assert_eq "  (nothing applied)" "" "$(cat "$K_APPLIED")"
sed -i '/ingress:/d' "$HOME/.config/aidc/config.yaml"
out=$(crun --expose 8080)
assert_has "--expose with no ingress in the config is refused" "kubernetes.ingress.domain" "$out"

echo "=== clean-env on Kubernetes ==="
out=$(K_EXISTS=1 run clean-env demo --yes --backend kubernetes)
assert_has "a running session is refused (aidc kill is for that)" "is running: aidc kill demo" "$out"
out=$(run clean-env demo --project /x --backend kubernetes)
assert_has "--project is the Docker backend's" "--project is the Docker backend's" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
