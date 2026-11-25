# shellcheck shell=bash
# A Kubernetes session's ways out besides its squid, and the names it resolves (NET-15, NET-13's
# cluster form, per-session DNS): docs/design-12-kubernetes.md, "Egress".
#
# The dev pod has no cluster DNS. Its one nameserver is the `names` container of its own proxy
# pod: dnsmasq with no upstream, answering only the names aidc writes into its hosts file (on the
# session's state claim, so a replaced proxy pod keeps them) and refusing everything else, so a
# lookup still cannot leave around squid. aidc writes there:
#   - each TCP egress relay's name (the destination's own name, so TLS hostname checks pass);
#   - the Services of each namespace the session was given with --network.
# Writing the file never restarts the dev pod: `aidc egress add` and `aidc network add` are live.
#
# A relay is one Deployment per destination host (socat from the forwarder image, one listener
# per port, every connection logged to the session's audit claim), a ClusterIP Service, and two
# NetworkPolicies: the dev pod may open those ports on the relay, and the relay takes
# connections only from the dev pod and may open only <ip>/32 on those ports. The dev pod
# reaches it directly, not through squid (squid is public-only).
#
# Sourced after lib.sh and manifests.sh; uses lib/egress.sh's pure helpers.

# shellcheck source=../lib/egress.sh
. "$AIDC_SCRIPTS/lib/egress.sh"

# k8s_relay_name <session> <host>: the relay's object name. A DNS label: the session, "-egress-"
# and the host's slug, or a hash of the host when that is longer than 63 characters.
k8s_relay_name() {
    local n
    n="${1}-egress-$(aidc_egress_slug "$2")"
    if [ "${#n}" -gt 63 ]; then
        n="${1}-egress-$(printf '%s' "$2" | cksum | cut -d' ' -f1)"
    fi
    printf '%s' "$n"
}

# k8s_relay_reach_as <session> <host>: the name the session connects to. A host name is its own
# name; an IPv4 destination has none to borrow, so the session uses the relay's name, as on
# Docker (aidc_egress_reach_as).
k8s_relay_reach_as() { aidc_egress_reach_as "$1" "$2"; }

# k8s_render_relay <session> <host> <ip> <kind> <audit-claim> <node-selector-json> <port>...:
# the relay's Deployment, Service and NetworkPolicies.
k8s_render_relay() {
    local session="$1" host="$2" ip="$3" kind="$4" audit="$5" sel="$6" ns name img labels script port
    shift 6
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    name=$(k8s_relay_name "$session" "$host")
    img="${AIDC_K8S_REGISTRY_PULL}/aidc/forwarder:${AIDC_VERSION_TAG}"
    labels="${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, aidc/session: ${session}"
    script=$(aidc_egress_script "$host" "$ip" "$@")
    local svc_ports="" pol_ports=""
    for port in "$@"; do
        svc_ports="${svc_ports}    - {name: p${port}, port: ${port}, targetPort: ${port}}
"
        pol_ports="${pol_ports}{protocol: TCP, port: ${port}}, "
    done
    pol_ports="[${pol_ports%, }]"
    cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${ns}
  labels: {${labels}, app: egress}
spec:
  selector: {aidc/session: ${session}, app: egress, aidc/relay: ${name}}
  ports:
${svc_ports%$'\n'}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${name}-dev, namespace: ${ns}, labels: {${labels}, app: egress}}
spec:
  podSelector: {matchLabels: {aidc/session: ${session}, app: dev}}
  policyTypes: [Egress]
  egress:
    - to: [{podSelector: {matchLabels: {aidc/relay: ${name}}}}]
      ports: ${pol_ports}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${name}, namespace: ${ns}, labels: {${labels}, app: egress}}
spec:
  podSelector: {matchLabels: {aidc/relay: ${name}}}
  policyTypes: [Ingress, Egress]
  ingress:
    - from: [{podSelector: {matchLabels: {aidc/session: ${session}, app: dev}}}]
      ports: ${pol_ports}
  egress:
    - to: [{ipBlock: {cidr: ${ip}/32}}]
      ports: ${pol_ports}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${ns}
  labels: {${labels}, app: egress, aidc/relay: ${name}}
  annotations:
    aidc/egress-host: "${host}"
    aidc/egress-ip: "${ip}"
    aidc/egress-ports: "$*"
    aidc/egress-kind: "${kind}"
    aidc/egress-reach-as: "$(k8s_relay_reach_as "$session" "$host")"
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {aidc/session: ${session}, app: egress, aidc/relay: ${name}}}
  template:
    metadata: {labels: {${labels}, app: egress, aidc/relay: ${name}}}
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      nodeSelector: ${sel}
      tolerations: ${AIDC_K8S_TOLERATIONS}
      # It mounts the session's audit claim (ReadWriteOnce), which the proxy pod holds: on the
      # proxy pod's node, so a node pool with more than one node does not leave it waiting on
      # a second attach.
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector: {matchLabels: {aidc/session: ${session}, app: proxy}}
              topologyKey: kubernetes.io/hostname
      # It connects to an address, never a name: no DNS at all.
      dnsPolicy: None
      dnsConfig: {nameservers: [192.0.2.1]}
      containers:
        - name: relay
          image: ${img}
          imagePullPolicy: Always
          command: [/bin/sh, -c, $(jq -n --arg v "$script" '$v')]
          resources: {requests: {cpu: 10m, memory: 16Mi}}
          volumeMounts: [{name: audit, mountPath: /var/aidc/audit}]
      volumes:
        - {name: audit, persistentVolumeClaim: {claimName: ${audit}}}
EOF
}

# k8s_relays <namespace> <session>: one line per relay of the session,
# "name|kind|host|ip|ports|reach-as|ready" (ports space-separated; ready the Deployment's ready
# replicas, 0 when it is not relaying). Returns 2 (kubectl's last line on stdout) when the
# cluster did not answer.
k8s_relays() {
    local out
    out=$(k8s_get "$1" deployment -l "aidc/session=${2},app=egress" -o json) || { printf '%s' "$out"; return 2; }
    [ -n "$out" ] || return 0
    printf '%s' "$out" | jq -r '.items[] | [.metadata.name,
        (.metadata.annotations["aidc/egress-kind"] // "?"), (.metadata.annotations["aidc/egress-host"] // "?"),
        (.metadata.annotations["aidc/egress-ip"] // "?"), (.metadata.annotations["aidc/egress-ports"] // ""),
        (.metadata.annotations["aidc/egress-reach-as"] // "?"), ((.status.readyReplicas // 0) | tostring)] | join("|")' | sort
}

# k8s_relays_describe <namespace> <session>: the relays as display lines,
# "kind  reach-as:port -> ip:port  [not ready]".
k8s_relays_describe() {
    local rows name kind host ip ports reach ready port flag
    rows=$(k8s_relays "$1" "$2") || { printf 'unknown (the cluster did not answer: %s)\n' "$rows"; return 0; }
    while IFS='|' read -r name kind host ip ports reach ready; do
        [ -n "$name" ] || continue
        flag=""
        [ "$ready" != 0 ] || flag="  [not ready: kubectl -n ${1} describe deployment ${name}]"
        for port in $ports; do
            printf '%-9s  %-40s  %s%s\n' "$kind" "${reach}:${port}" "${ip}:${port}" "$flag"
        done
    done <<EOF_REL
${rows}
EOF_REL
}

# ---- networks: another namespace's services (NET-13's cluster form) ---------------------

# k8s_network_refusal <namespace>: why <namespace> may not be given to a session (printed, and
# returns 0), or returns 1 when it may. aidc's own namespaces hold the user's GitHub login, other
# users' sessions and the image registry; the system namespaces hold the API server's Service
# and the cluster's controllers.
k8s_network_refusal() {
    local n="$1"
    if ! k8s_valid_label "$n"; then printf '%s is not a namespace name' "'$n'"; return 0; fi
    case "$n" in
        kube-system|kube-public|kube-node-lease|default)
            printf '%s is a system namespace (the API server, the cluster'"'"'s controllers)' "$n"; return 0 ;;
        "${AIDC_K8S_PREFIX}"-*)
            printf '%s is one of aidc'"'"'s own namespaces (your git login, other sessions, the registry)' "$n"; return 0 ;;
    esac
    return 1
}

# k8s_network_ungranted <namespace>: why these credentials cannot give <namespace> to a session
# (printed, and returns 0), or returns 1 when they can. The session's names responder serves that
# namespace's Services, read with the user's credentials, which may list them only where an admin
# granted it (`aidc user allow-network <user> <namespace>`): a user's credentials reach no other
# namespace by themselves. An admin's credentials may anyway.
k8s_network_ungranted() {
    local a
    a=$(k8s_kubectl auth can-i list services -n "$1" 2>/dev/null </dev/null) || true
    [ "$a" = yes ] && return 1
    printf 'your credentials may not read the Services of %s: an admin grants it with `aidc user allow-network %s %s`' \
        "$1" "$AIDC_K8S_USER" "$1"
    return 0
}

# k8s_render_network <session> <namespace>: the NetworkPolicy that lets the session's dev pod
# reach every pod of <namespace>, on any port. That namespace's own policies may still refuse.
k8s_render_network() {
    local session="$1" target="$2" ns
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    cat <<EOF
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${session}-net-${target}
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, aidc/session: ${session}, app: network}
  annotations: {aidc/network: "${target}"}
spec:
  podSelector: {matchLabels: {aidc/session: ${session}, app: dev}}
  policyTypes: [Egress]
  egress:
    - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: ${target}}}}]
EOF
}

# k8s_networks <namespace> <session>: the namespaces the session was given, one per line (from
# its NetworkPolicies). Returns 2 when the cluster did not answer.
k8s_networks() {
    local out
    out=$(k8s_get "$1" networkpolicy -l "aidc/session=${2},app=network" -o json) || { printf '%s' "$out"; return 2; }
    [ -n "$out" ] || return 0
    printf '%s' "$out" | jq -r '.items[].metadata.annotations["aidc/network"] // empty' | sort -u
}

# ---- names ------------------------------------------------------------------------------

# k8s_names_hosts <namespace> <session>: the hosts file the session's names responder serves:
# each relay's name, and each given namespace's Services as <svc>.<ns>, <svc>.<ns>.svc and
# <svc>.<ns>.svc.cluster.local. Returns 2, saying why on stderr, when a read failed: a partial
# file would drop names the session uses.
k8s_names_hosts() {
    local ns="$1" s="$2" out target
    out=$(k8s_get "$ns" service -l "aidc/session=${s},app=egress" -o json) \
        || { printf 'cannot read the relays: %s\n' "$out" >&2; return 2; }
    if [ -n "$out" ]; then
        # The Service's address, with the name from its Deployment's annotation (same name).
        local deps
        deps=$(k8s_get "$ns" deployment -l "aidc/session=${s},app=egress" -o json) \
            || { printf 'cannot read the relays: %s\n' "$deps" >&2; return 2; }
        [ -n "$deps" ] || deps='{"items":[]}'
        jq -rn --argjson svc "$out" --argjson dep "$deps" '
            ($dep.items | map({key: .metadata.name, value: (.metadata.annotations["aidc/egress-reach-as"] // "")}) | from_entries) as $reach
            | $svc.items[] | select(.spec.clusterIP != null and .spec.clusterIP != "None")
            | select(($reach[.metadata.name] // "") != "")
            | "\(.spec.clusterIP) \($reach[.metadata.name])"'
    fi
    local nets
    nets=$(k8s_networks "$ns" "$s") || { printf 'cannot read the networks: %s\n' "$nets" >&2; return 2; }
    for target in $nets; do
        out=$(k8s_get "$target" service -o json) \
            || { printf 'cannot read the services of %s: %s\n' "$target" "$out" >&2; return 2; }
        [ -n "$out" ] || continue
        printf '%s' "$out" | jq -r --arg n "$target" '.items[]
            | select(.spec.clusterIP != null and .spec.clusterIP != "None")
            | "\(.spec.clusterIP) \(.metadata.name).\($n) \(.metadata.name).\($n).svc \(.metadata.name).\($n).svc.cluster.local"'
    done
}

# k8s_names_sync <namespace> <session>: write the hosts file into the session's names responder,
# which reads it again as soon as it changes (written aside, then renamed into place). Returns 1, saying why on stderr, when it could not.
k8s_names_sync() {
    local ns="$1" s="$2" hosts proxy
    hosts=$(k8s_names_hosts "$ns" "$s") || return 1
    proxy=$(k8s_get "$ns" pod -l "aidc/session=${s},app=proxy" --field-selector=status.phase=Running -o name) \
        || { printf 'cannot find the proxy pod of %s: the cluster did not answer (%s)\n' "$s" "$proxy" >&2; return 1; }
    proxy=$(printf '%s\n' "$proxy" | head -n1)
    [ -n "$proxy" ] || { printf 'the proxy pod of %s is not running\n' "$s" >&2; return 1; }
    printf '%s\n' "$hosts" | awk 'NF' | k8s_kubectl -n "$ns" exec -i "$proxy" -c names -- \
        sh -c 'umask 022; cat > /var/aidc/names/.hosts.new && mv /var/aidc/names/.hosts.new /var/aidc/names/hosts' >&2 \
        || { printf 'could not write the names of %s into its proxy pod\n' "$s" >&2; return 1; }
}

# k8s_names_wait <namespace> <session> <name> [seconds]: wait until <name> resolves in the dev
# pod (the responder reloads within seconds). Returns 1 when it did not.
k8s_names_wait() {
    local end
    end=$(( $(date +%s) + ${4:-30} ))
    while [ "$(date +%s)" -lt "$end" ]; do
        k8s_kubectl -n "$1" exec "${2}-dev-0" -c dev -- getent hosts "$3" </dev/null >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}
