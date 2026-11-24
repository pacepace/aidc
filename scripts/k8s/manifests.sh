# shellcheck shell=bash
# Manifests the Kubernetes backend applies, rendered from the settings (scripts/k8s/lib.sh).
#
# Each k8s_render_* function prints YAML on stdout for `kubectl apply -f -`. Structured
# settings (node selector, tolerations) are JSON, which YAML reads as flow style, so they go
# in as they are. Sourced after lib.sh.

# Pinned images aidc runs itself, not built by it. Each is older than the 14-day cooldown
# (REL-09) when pinned; bump deliberately.
K8S_REGISTRY_IMAGE="${K8S_REGISTRY_IMAGE:-docker.io/library/registry:3.0.0}"
K8S_BUILDER_IMAGE="${K8S_BUILDER_IMAGE:-docker.io/library/docker:29.0.0-dind}"
K8S_INIT_IMAGE="${K8S_INIT_IMAGE:-docker.io/library/alpine:3.22.2}"

# Labels on everything aidc makes, so `kubectl get -l` finds it and nothing else.
K8S_MANAGED_BY="app.kubernetes.io/managed-by: aidc"

# k8s_node_selector: the configured node selector merged with the runtime class's own
# scheduling selector, as compact JSON. Pods that do not use the runtime class (the
# registry) still have to land where session pods do, because the node pulls session images
# from the registry over its own loopback address.
k8s_node_selector() {
    local rc json
    # Unreadable is not "no selector": an empty one would let the registry or a builder land on
    # a node sessions never use.
    json=$(k8s_kubectl get runtimeclass "$AIDC_K8S_RUNTIME_CLASS" -o json 2>/dev/null) || {
        err "cannot read the runtime class ${AIDC_K8S_RUNTIME_CLASS}"
        return 1
    }
    rc=$(printf '%s' "$json" | yq -p=json -o=json -I=0 '.scheduling.nodeSelector // {}' 2>/dev/null || true)
    [ -n "$rc" ] || rc='{}'
    # shellcheck disable=SC2016  # $m is yq's variable, not the shell's
    printf '%s\n%s\n' "$rc" "$AIDC_K8S_NODE_SELECTOR" \
        | yq ea -p=json -o=json -I=0 '. as $m ireduce ({}; . * $m)' 2>/dev/null || printf '{}'
}

# k8s_render_system <node-selector-json>: the system namespace and the registry.
# The registry listens on the node's loopback only (hostIP 127.0.0.1): the node pulls
# session images from localhost:<port>, which containerd treats as plain HTTP with no
# configuration, and nothing off the node can reach it. Builders push through the Service,
# and a NetworkPolicy lets only builder pods of this namespace reach it: a session that
# could push could replace the squid or policy image that enforces its own egress.
# With one replica on one node's loopback, only that node can pull: sessions must run
# there, which the shared node selector ensures.
#
# The namespace allows privileged pods (Pod Security "privileged"), for the builder alone:
# the squid image's base owns its files as UID 584792, which no user-namespaced builder can
# represent (owner ruling 2026-11-24). Nothing else aidc runs here is privileged.
k8s_render_system() {
    local sel="$1" ns size sc
    ns=$(k8s_system_ns)
    size="$AIDC_K8S_REGISTRY_SIZE"
    sc="$AIDC_K8S_REGISTRY_STORAGE_CLASS"
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    ${K8S_MANAGED_BY}
    aidc/role: system
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}}
spec:
  storageClassName: ${sc}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: ${size}}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}, app: registry}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: registry}}
  template:
    metadata:
      labels: {${K8S_MANAGED_BY}, app: registry}
    spec:
      automountServiceAccountToken: false
      nodeSelector: ${sel}
      tolerations: ${AIDC_K8S_TOLERATIONS}
      containers:
        - name: registry
          image: ${K8S_REGISTRY_IMAGE}
          ports:
            - {containerPort: 5000, hostPort: ${AIDC_K8S_REGISTRY_PORT}, hostIP: 127.0.0.1}
          env:
            - {name: REGISTRY_STORAGE_DELETE_ENABLED, value: "true"}
          volumeMounts: [{name: data, mountPath: /var/lib/registry}]
          readinessProbe: {httpGet: {path: /v2/, port: 5000}, periodSeconds: 5}
      volumes:
        - {name: data, persistentVolumeClaim: {claimName: registry}}
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}}
spec:
  selector: {app: registry}
  ports: [{port: ${AIDC_K8S_REGISTRY_PORT}, targetPort: 5000}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: registry-push-from-builders-only
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}}
spec:
  podSelector: {matchLabels: {app: registry}}
  policyTypes: [Ingress]
  ingress:
    - from: [{podSelector: {matchLabels: {app: builder}}}]
      ports: [{protocol: TCP, port: 5000}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: builders-take-no-connections
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}}
spec:
  podSelector: {matchLabels: {app: builder}}
  policyTypes: [Ingress]
EOF
}

# k8s_render_builder <name> <node-selector-json>: a privileged pod running Docker for
# `aidc k8s build`, trusting the in-cluster registry over plain HTTP. Privileged because the
# squid image's base owns files as UID 584792, beyond any user namespace's range (owner
# ruling 2026-11-24); it runs only during a build, only aidc's own Dockerfiles, and is deleted
# after. Its Docker daemon listens on its unix socket only, never the pod network, and uses the
# pod network's MTU. It lands
# on the session nodes (same selector and tolerations), so images match their CPU
# architecture. It fetches base images straight from the internet, not through a Squid.
k8s_render_builder() {
    local name="$1" sel="$2" ns host
    ns=$(k8s_system_ns)
    host="${AIDC_K8S_REGISTRY_PUSH}"
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}, app: builder}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  nodeSelector: ${sel}
  tolerations: ${AIDC_K8S_TOLERATIONS}
  initContainers:
    - name: daemon-json
      image: ${K8S_BUILDER_IMAGE}
      command: [sh, -c, 'printf "{\\"insecure-registries\\":[\\"%s\\"]}" "\$0" > /etc/docker/daemon.json', "${host}"]
      volumeMounts: [{name: etc-docker, mountPath: /etc/docker}]
  containers:
    - name: docker
      image: ${K8S_BUILDER_IMAGE}
      # The inner Docker network gets the pod network's MTU: a cluster overlay (VXLAN and the
      # like) carries smaller packets than Docker's default 1500, and large transfers inside
      # a build then stall and reset (seen: a git clone from GitHub, reset after 150 s).
      # dockerd itself, not the image's dockerd-entrypoint.sh: given any flag, that script still
      # prepends its default --host=tcp://0.0.0.0:2375 (no TLS), which on a privileged pod would
      # hand node root to anything that reaches the pod (seen live: both listeners).
      command: [sh, -c, 'exec dockerd --host=unix:///var/run/docker.sock --mtu="\$(cat /sys/class/net/eth0/mtu)"']
      securityContext: {privileged: true}
      env: [{name: DOCKER_TLS_CERTDIR, value: ""}]
      volumeMounts: [{name: etc-docker, mountPath: /etc/docker}]
  volumes:
    - {name: etc-docker, emptyDir: {}}
EOF
}

# k8s_render_user <user> <node-selector-json>: the user's namespace and disk, and a one-shot
# pod that binds the disk (the claim waits for a first consumer) and gives its top folder to
# the session user (uid 1000), since sessions write their repos there. The disk is mounted at
# /home/<user> in sessions, so a repo sits at the same path as on the user's Linux machines and
# its Claude history folder has the same name everywhere.
k8s_render_user() {
    local user="$1" sel="$2" ns
    ns=$(k8s_user_ns "$user")
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    ${K8S_MANAGED_BY}
    aidc/role: user
    aidc/user: ${user}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}}
spec: {podSelector: {}, policyTypes: [Ingress, Egress]}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: disk
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}, aidc/user: ${user}}
spec:
  storageClassName: ${AIDC_K8S_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: ${AIDC_K8S_USER_DISK_SIZE}}}
---
apiVersion: v1
kind: Pod
metadata:
  name: disk-init
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}, app: disk-init}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  nodeSelector: ${sel}
  tolerations: ${AIDC_K8S_TOLERATIONS}
  containers:
    - name: init
      image: ${K8S_INIT_IMAGE}
      command: [sh, -c, 'chown 1000:1000 /disk && chmod 0755 /disk && ls -ldn /disk']
      volumeMounts: [{name: disk, mountPath: /disk}]
  volumes:
    - {name: disk, persistentVolumeClaim: {claimName: disk}}
EOF
}

# k8s_render_session <session> <repo-path> <profile> <node-selector-json> <audit-claim>
#     [proxy-ip]: one
# session's NetworkPolicies, proxy pod (squid, refresher, policy, audit), its Service, and the
# dev StatefulSet, all in the user's namespace and named <session>-*. Sessions live in the
# user's namespace, not one each, because every session mounts the user's one disk and a pod
# can mount only claims of its own namespace; labels and the policies below keep sessions apart
# (the namespace's default-deny comes from `aidc user add`). Without proxy-ip the dev
# StatefulSet is left out: it reaches its proxy by a hostAliases entry for the Service's
# ClusterIP (no cluster DNS in the dev pod), so it is rendered once the Service has an address.
#
# The lockdown is the one measured on the reference cluster (docs/design-12-kubernetes.md,
# "Egress"): the dev pod may open TCP 3128 to its own session's proxy and nothing else, and has
# no DNS; the proxy pod takes connections only from its own dev pod and may reach Quad9 for DNS
# and public addresses only. The rules live in the node's network namespace, which the Sysbox
# dev pod does not share.
k8s_render_session() {
    # aidc's images are pulled every time (imagePullPolicy: Always): `aidc k8s build --force`
    # replaces an image under the same version tag, and a node keeping its cached copy would run
    # the old one (it did). The registry is on the node, so a pull is cheap.
    local session="$1" repo="$2" profile="$3" sel="$4" audit="$5" proxy_ip="${6:-}" ns img
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    img="${AIDC_K8S_REGISTRY_PULL}/aidc"
    local labels="${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, aidc/session: ${session}"
    # Per-session DNS (--dns, dns_servers:): squid and the proxy pod resolve through these instead
    # of Quad9 (squid's entrypoint then resolves through resolv.conf, the pod's dnsConfig), and
    # the proxy may reach each of them on port 53, private ones included, as on Docker.
    local dns_list="${AIDC_K8S_DNS_SERVERS:-}" proxy_dns dns_rule="" d
    if [ -n "$dns_list" ]; then
        proxy_dns="[$(printf '%s' "$dns_list" | tr ' ' '\n' | awk 'NF' | paste -sd, - | sed 's/,/, /g')]"
        for d in $dns_list; do
            dns_rule="${dns_rule}    - to: [{ipBlock: {cidr: ${d}/32}}]
      ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
"
        done
    else
        proxy_dns="[9.9.9.9, 149.112.112.112]"
    fi
    # The GPU only when asked for (K8S-11): the device plugin hands one to the pod.
    local gpu=""
    [ "${AIDC_K8S_GPU:-0}" = 1 ] && gpu=", nvidia.com/gpu: 1"
    cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${session}-dev-only-to-its-proxy, namespace: ${ns}, labels: {${labels}}}
spec:
  podSelector: {matchLabels: {aidc/session: ${session}, app: dev}}
  policyTypes: [Ingress, Egress]
  egress:
    # Squid, and the session's names responder (relay and --network names only; it forwards
    # nothing, so a lookup cannot leave around squid).
    - to: [{podSelector: {matchLabels: {aidc/session: ${session}, app: proxy}}}]
      ports: [{protocol: TCP, port: 3128}, {protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${session}-proxy-public-only, namespace: ${ns}, labels: {${labels}}}
spec:
  podSelector: {matchLabels: {aidc/session: ${session}, app: proxy}}
  policyTypes: [Ingress, Egress]
  ingress:
    - from: [{podSelector: {matchLabels: {aidc/session: ${session}, app: dev}}}]
      ports: [{protocol: TCP, port: 3128}, {protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
  egress:
    - to: [{ipBlock: {cidr: 9.9.9.9/32}}, {ipBlock: {cidr: 149.112.112.112/32}}]
      ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
${dns_rule}    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 127.0.0.0/8]
---
# The audit trail outlives the session (aidc kill keeps it), on the user's retained class, and
# is named for its creation time so a later session of the same name never writes over it.
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: ${audit}, namespace: ${ns}, labels: {${labels}, aidc/kept: audit}}
spec:
  storageClassName: ${AIDC_K8S_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 5Gi}}
---
# The taint flag outlives the proxy pod (a replaced pod must not read as clean: SEC-06), and
# goes with the session.
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: ${session}-state, namespace: ${ns}, labels: {${labels}}}
spec:
  storageClassName: ${AIDC_K8S_SESSION_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
# The session user's home: mounted by the dev pod and, read-only, by the audit sidecar, which
# collects its shell history and Claude transcripts (SEC-07, NET-08). Two pods mount it, so the
# session storage class must allow that, as the user's disk class does; it goes with the session.
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: ${session}-home, namespace: ${ns}, labels: {${labels}}}
spec:
  storageClassName: ${AIDC_K8S_SESSION_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: ${AIDC_K8S_HOME_SIZE}}}
---
apiVersion: v1
kind: Service
metadata: {name: ${session}-proxy, namespace: ${ns}, labels: {${labels}}}
spec:
  selector: {aidc/session: ${session}, app: proxy}
  ports:
    - {name: squid, port: 3128, protocol: TCP}
    - {name: dns, port: 53, protocol: UDP}
    - {name: dns-tcp, port: 53, protocol: TCP}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${session}-proxy, namespace: ${ns}, labels: {${labels}, app: proxy}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {aidc/session: ${session}, app: proxy}}
  template:
    metadata: {labels: {${labels}, app: proxy}}
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      nodeSelector: ${sel}
      tolerations: ${AIDC_K8S_TOLERATIONS}
      # Quad9, the only DNS the proxy's NetworkPolicy allows. Squid's own config names it too,
      # but the refresher's feed downloads resolve through resolv.conf: with cluster DNS they
      # failed, and every session ran with an empty malware blocklist (seen live).
      dnsPolicy: None
      dnsConfig: {nameservers: ${proxy_dns}}
      initContainers:
        # The audit record's first files, as aidc create writes them on Docker: meta.json (the
        # audit sidecar stamps tainted_at and killed_at into it) and the config snapshot. Only
        # when absent: a restarted proxy pod must not reset them.
        - name: seed-audit
          image: ${img}/audit:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          command: [sh, -c, 'for f in meta.json config-snapshot.yaml; do [ -e "/var/aidc/audit/\$f" ] || cp "/seed/\$f" "/var/aidc/audit/\$f"; done']
          volumeMounts:
            - {name: audit, mountPath: /var/aidc/audit}
            - {name: audit-seed, mountPath: /seed}
        # A Docker volume starts as a copy of the image's folder; an emptyDir starts empty.
        - name: seed-squid-etc
          image: ${img}/squid:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          command: [perl, -MFile::Copy, -e, 'copy("/etc/squid/\$_", "/seed/\$_") or die "\$_: \$!" for qw(squid.conf blocklist.txt state-actor-tlds.txt); mkdir "/seed/conf.d"']
          volumeMounts: [{name: blocklist, mountPath: /seed}]
      containers:
        - name: squid
          image: ${img}/squid:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          # Public addresses only, in squid as well as in the NetworkPolicy (defence in depth:
          # a request for a private address gets squid's 403, never reaching the policy). The
          # dev pod reaches anything else it is allowed (an --egress-tcp relay) directly, not
          # through squid, so this refuses nothing a session is meant to reach.
          env: [{name: AIDC_DNS_SERVERS, value: "${dns_list}"}, {name: AIDC_DNS_USER_CHOSEN, value: "1"}, {name: AIDC_MCP_DENY, value: ""}, {name: AIDC_PUBLIC_ONLY, value: "1"}]
          readinessProbe: {exec: {command: [/usr/local/bin/healthcheck.sh]}, periodSeconds: 10}
          # Requests keep the proxy out of the BestEffort class, first in line for eviction.
          resources: {requests: {cpu: 100m, memory: 256Mi}}
          volumeMounts:
            - {name: blocklist, mountPath: /etc/squid}
            - {name: squid-log, mountPath: /var/log/squid}
        # The dev pod's only nameserver: dnsmasq with no upstream (--no-resolv, no server), so it
        # answers the names aidc writes into its hosts folder (k8s/net.sh, k8s_names_sync) and
        # refuses every other name. The folder is on the state claim, so a new proxy pod keeps it,
        # and dnsmasq watches it (--hostsdir, inotify): a name added or removed is served within a
        # second, and nothing restarts. --except-interface turns off dnsmasq's default of answering
        # only its own subnet: queries come from the dev pod, through the proxy's Service.
        - name: names
          image: ${img}/forwarder:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          command: [dnsmasq, -k, --no-resolv, --no-hosts, --no-poll, --hostsdir=/var/aidc/names, --except-interface=lo, --log-facility=-]
          resources: {requests: {cpu: 10m, memory: 16Mi}}
          volumeMounts: [{name: state, mountPath: /var/aidc/names, subPath: names}]
        - name: refresher
          image: ${img}/refresher:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          resources: {requests: {cpu: 50m, memory: 128Mi}}
          volumeMounts:
            - {name: blocklist, mountPath: /etc/squid}
            - {name: aidc-log, mountPath: /var/log/aidc}
        - name: policy
          image: ${img}/policy:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          resources: {requests: {cpu: 50m, memory: 64Mi}}
          env:
            - {name: AIDC_SESSION, value: "${session}"}
            - {name: AIDC_TAINT_RESPONSE, value: "${AIDC_TAINT_RESPONSE:-freeze}"}
            - {name: AIDC_TLD_TAINTS, value: "${AIDC_TLD_TAINTS:-false}"}
            - {name: AIDC_NOTIFY_WEBHOOK, value: "${AIDC_NOTIFY_WEBHOOK:-}"}
          volumeMounts:
            - {name: blocklist, mountPath: /etc/squid, readOnly: true}
            - {name: squid-log, mountPath: /var/log/squid, readOnly: true}
            - {name: aidc-log, mountPath: /var/log/aidc}
            - {name: state, mountPath: /var/state}
            - {name: audit, mountPath: /var/aidc/audit}
        - name: audit
          image: ${img}/audit:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          resources: {requests: {cpu: 50m, memory: 64Mi}}
          env:
            - {name: AIDC_SESSION, value: "${session}"}
            - {name: AIDC_PROFILE, value: "${profile}"}
          volumeMounts:
            - {name: squid-log, mountPath: /var/log/squid, readOnly: true}
            - {name: aidc-log, mountPath: /var/log/aidc, readOnly: true}
            - {name: state, mountPath: /var/state, readOnly: true}
            - {name: home, mountPath: /var/aidc/dev-home, readOnly: true}
            - {name: audit, mountPath: /var/aidc/audit}
      volumes:
        - {name: blocklist, emptyDir: {}}
        - {name: squid-log, emptyDir: {}}
        - {name: aidc-log, emptyDir: {}}
        - {name: state, persistentVolumeClaim: {claimName: ${session}-state}}
        - {name: home, persistentVolumeClaim: {claimName: ${session}-home}}
        - {name: audit, persistentVolumeClaim: {claimName: ${audit}}}
        - {name: audit-seed, configMap: {name: ${session}-audit-seed}}
EOF
    [ -n "$proxy_ip" ] || return 0
    cat <<EOF
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${session}-dev
  namespace: ${ns}
  labels: {${labels}, app: dev}
  annotations: {aidc/repo: "${repo}", aidc/profile: "${profile}", aidc/audit: "${audit}", aidc/ports: "${AIDC_K8S_PORTS:-}", aidc/gpu: "${AIDC_K8S_GPU:-0}"}
spec:
  replicas: 1
  serviceName: ""
  selector: {matchLabels: {aidc/session: ${session}, app: dev}}
  template:
    metadata: {labels: {${labels}, app: dev}}
    spec:
      runtimeClassName: ${AIDC_K8S_RUNTIME_CLASS}
      hostUsers: false
      automountServiceAccountToken: false
      enableServiceLinks: false
      nodeSelector: ${sel}
      tolerations: ${AIDC_K8S_TOLERATIONS}
      # No cluster DNS: names are resolved by Squid, so a lookup cannot leave around it. The one
      # nameserver is the session's names responder in its proxy pod, which knows only its relays
      # and --network services and forwards nothing.
      dnsPolicy: None
      dnsConfig: {nameservers: ["${proxy_ip}"]}
      hostAliases: [{ip: "${proxy_ip}", hostnames: [aidc-proxy]}]
      initContainers:
        # The session home starts as a copy of the image's /home/vscode, as a Docker named volume
        # does on first use: Claude Code itself lives there (~/.local), with the shell setup. A
        # new claim starts empty and root-owned, so without this a session had no claude and its
        # user could not write its own home (no shell history, no transcripts to audit). Only on
        # first use (.profile is the marker): a restarted session keeps its home.
        - name: seed-home
          image: ${img}/dev-base:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          command: [sh, -c, '[ -e /seed/.profile ] || cp -a /home/vscode/. /seed/; chown 1000:1000 /seed && chmod 0755 /seed']
          volumeMounts: [{name: home, mountPath: /seed}]
        # The repo folder, made as the session user when it is not on the disk yet, group-writable
        # like everything sessions make on the disk (the git container tidies there).
        - name: repo-dir
          image: ${img}/dev-base:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          command: [sh, -c, 'umask 002 && mkdir -p "\$1"', sh, "${repo}"]
          securityContext: {runAsUser: 1000, runAsGroup: 1000}
          volumeMounts: [{name: disk, mountPath: "/home/${AIDC_K8S_USER}"}]
      containers:
        - name: dev
          image: ${img}/dev-base:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          workingDir: "${repo}"
          resources:
            requests: {cpu: "${AIDC_K8S_CPU_REQUEST}", memory: "${AIDC_K8S_MEMORY_REQUEST}"}
            limits: {cpu: "${AIDC_K8S_CPU_LIMIT}", memory: "${AIDC_K8S_MEMORY_LIMIT}"${gpu}}
          # The proxy by address, not by name: the dev pod has no DNS, and an inner container
          # handed \$HTTPS_PROXY could not resolve "aidc-proxy" (it is only in this pod's hosts
          # file). On Docker, inner containers resolve the name through Docker's DNS.
          env:
            - {name: HTTP_PROXY, value: "http://${proxy_ip}:3128"}
            - {name: HTTPS_PROXY, value: "http://${proxy_ip}:3128"}
            - {name: NO_PROXY, value: "localhost,127.0.0.1"}
            - {name: http_proxy, value: "http://${proxy_ip}:3128"}
            - {name: https_proxy, value: "http://${proxy_ip}:3128"}
            - {name: no_proxy, value: "localhost,127.0.0.1"}
            - {name: AIDC_SESSION, value: "${session}"}
            - {name: AIDC_PROFILE, value: "${profile}"}
            - {name: AIDC_REPO_PATH, value: "${repo}"}
            - {name: AIDC_CLAUDE_MODE, value: "${AIDC_CLAUDE_MODE:-yolo}"}
            - {name: AIDC_CLAUDE_RESUME, value: "${AIDC_CLAUDE_RESUME:-true}"}
            - {name: CLAUDE_CONFIG_DIR, value: /home/vscode/.claude}
            # Sysbox gives the inner Docker a real /var/lib/docker, where overlay2 works.
            - {name: AIDC_DOCKER_STORAGE_DRIVER, value: overlay2}
            # The session's gh stand-in hands pull requests to the git container through this
            # folder; on this backend new files are group-writable (umask 002) so the git
            # container can tidy merged worktrees.
            - {name: AIDC_BACKEND, value: kubernetes}
            - {name: AIDC_GIT_REQUESTS, value: "$(k8s_git_requests_path)"}
            # The session's own token, sent with its requests: a git mode the user gives this
            # session (aidc git mode) applies to requests carrying it, and no other session can
            # read it (sessions reach no API server and no other pod).
            - {name: AIDC_GIT_TOKEN, value: "${AIDC_K8S_GIT_TOKEN:-}"}
            # The user's git identity (session-create.sh, from this machine's git config, as
            # Docker's aidc create bridges it): the entrypoint writes it to the session's
            # .gitconfig, so its commits show as the user. Quoted as JSON strings.
            - {name: AIDC_GIT_USER_NAME, value: $(jq -n --arg v "${AIDC_K8S_GIT_USER_NAME:-}" '$v')}
            - {name: AIDC_GIT_USER_EMAIL, value: $(jq -n --arg v "${AIDC_K8S_GIT_USER_EMAIL:-}" '$v')}
          volumeMounts:
            - {name: disk, mountPath: "/home/${AIDC_K8S_USER}"}
            - {name: home, mountPath: /home/vscode}
      volumes:
        - {name: disk, persistentVolumeClaim: {claimName: disk}}
        - {name: home, persistentVolumeClaim: {claimName: ${session}-home}}
EOF
}

# k8s_render_git <node-selector-json>: the user's git container (docs/design-12-kubernetes.md,
# "Git"): its home claim, its egress policy and its Deployment, in the user's namespace.
#
# It is the only thing that pushes, so it holds the user's GitHub login (on its own claim,
# git-cred) and its home claim, both on the user's retained class: a lost claim is a lost login,
# and the user, not the admin, adds it again. It mounts the user's disk at the same path sessions do, so a repo has
# one path everywhere.
#
# It runs as the git user (uid 2000; its own group 2000, plus the session group 1000 the
# group-shared working copies belong to), unprivileged, with no API token and no service links.
# The agent and the user's terminal run as that user, which holds no credential: what needs
# the GitHub login goes through gitctl's fixed verbs, which run git as gitrun and gh as gitcred
# through the one sudo rule that names gitctl (gitctl/sudoers). sudo is a setuid program, so
# this container alone may escalate, holding only the capabilities a user switch needs
# (SETUID, SETGID, and AUDIT_WRITE for sudo's audit record); it can become those two users,
# for gitctl only. The
# GitHub login lives on its own claim, git-cred, readable by gitcred only.
# Egress is Quad9 and public addresses only, as the session proxy's, so a login held here cannot
# be walked to the API server, a node, a session or the LAN; nothing may connect to it (the
# namespace's default-deny covers ingress, and the policy names it again for this pod). Like
# the proxy, it resolves through Quad9 only, the one DNS its policy allows.
#
# Not under the sessions' runtime class: it runs no Docker, and its uid 2000 must be the same
# number on the shared disk as the one that owns what it writes there.
k8s_render_git() {
    local sel="$1" ns img
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    img="${AIDC_K8S_REGISTRY_PULL}/aidc/gitctl:${AIDC_VERSION_TAG}"
    local labels="${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}"
    # The git agent is an aidc session (owner ruling 2026-11-24) under a reserved name: its
    # Deployment and pod carry the session label, so aidc's lookup finds it like any session.
    # Not in the selector: a Deployment's selector cannot change, and app: git stays its key.
    local session="aidc/session: ${K8S_GIT_SESSION}"
    cat <<EOF2
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: git-egress, namespace: ${ns}, labels: {${labels}}}
spec:
  podSelector: {matchLabels: {app: git}}
  policyTypes: [Ingress, Egress]
  egress:
    - to: [{ipBlock: {cidr: 9.9.9.9/32}}, {ipBlock: {cidr: 149.112.112.112/32}}]
      ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 127.0.0.0/8]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: git-home, namespace: ${ns}, labels: {${labels}, app: git}}
spec:
  storageClassName: ${AIDC_K8S_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: git-cred, namespace: ${ns}, labels: {${labels}, app: git}}
spec:
  storageClassName: ${AIDC_K8S_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
# gitrun's private bare copies of the user's GitHub repos (gitctl): a cache of GitHub, so on the
# session class, deleted with nothing else; gitrun's alone (0700).
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: git-run, namespace: ${ns}, labels: {${labels}, app: git}}
spec:
  storageClassName: ${AIDC_K8S_SESSION_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: ${AIDC_K8S_GIT_STORE_SIZE}}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: git, namespace: ${ns}, labels: {${labels}, ${session}, app: git}}
spec:
  replicas: 1
  # Recreate: two git containers at once would share one home and one GitHub login and race on
  # the same repos.
  strategy: {type: Recreate}
  selector: {matchLabels: {app: git}}
  template:
    metadata: {labels: {${labels}, ${session}, app: git}}
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      nodeSelector: ${sel}
      tolerations: ${AIDC_K8S_TOLERATIONS}
      dnsPolicy: None
      dnsConfig: {nameservers: [9.9.9.9, 149.112.112.112]}
      # The session group, named here rather than left to the image's /etc/group.
      securityContext: {supplementalGroups: [1000], seccompProfile: {type: RuntimeDefault}}
      initContainers:
        # A new home starts as a copy of the image's /home/git (Claude Code lives there, with
        # the shell setup), as a session's home does. A new claim is empty and root-owned, so
        # this one step runs as root, with only the capabilities a copy and a chown need. Only
        # on first use (.profile is the marker): a restarted pod keeps the user's secrets.
        - name: seed-home
          image: ${img}
          imagePullPolicy: Always
          # The login's home is gitcred's: 0711, so git can read the identity file a login
          # writes there but cannot list it; gh's own files in it are 0600.
          # gitrun's store is gitrun's alone: gitctl refuses one anyone else can enter.
          command: [sh, -c, '[ -e /seed/.profile ] || cp -a /home/git/. /seed/; chown 2000:2000 /seed && chmod 0700 /seed && chown 2001:2001 /cred && chmod 0711 /cred && chown 2002:2002 /run-store && chmod 0700 /run-store']
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL], add: [CHOWN, FOWNER, DAC_OVERRIDE]}
          volumeMounts: [{name: home, mountPath: /seed}, {name: cred, mountPath: /cred}, {name: run-store, mountPath: /run-store}]
        # Claude Code is copied into the home once, when it is seeded; this brings a home made
        # earlier the image's Claude when that is newer than the one it has. As the git user,
        # not root: the home is the agent's, so nothing it planted there is followed by root.
        - name: refresh-claude
          image: ${img}
          imagePullPolicy: Always
          command: [/opt/aidc/lib/gitctl/claude-refresh.sh, /home/git, /seed]
          securityContext:
            runAsUser: 2000
            runAsGroup: 2000
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
          volumeMounts: [{name: home, mountPath: /seed}]
      containers:
        - name: git
          image: ${img}
          imagePullPolicy: Always
          workingDir: /home/git
          env:
            - {name: HOME, value: /home/git}
            - {name: AIDC_USER, value: "${AIDC_K8S_USER}"}
            - {name: AIDC_GIT_REQUESTS, value: "$(k8s_git_requests_path)"}
            - {name: AIDC_GIT_MODE, value: "${AIDC_K8S_GIT_MODE:-ask}"}
            # In ask mode a waiting request is handed to the git agent's Claude, which asks the
            # user with its question tool (the approval path every session's question takes).
            - {name: AIDC_GIT_NOTIFY, value: /opt/aidc/lib/gitctl/git-notify.sh}
            - {name: AIDC_SESSION, value: "${K8S_GIT_SESSION}"}
          securityContext:
            runAsUser: 2000
            runAsGroup: 2000
            runAsNonRoot: true
            privileged: false
            allowPrivilegeEscalation: true
            capabilities: {drop: [ALL], add: [SETUID, SETGID, AUDIT_WRITE]}
          readinessProbe: {exec: {command: [tmux, has-session, -t, main]}, periodSeconds: 10}
          resources: {requests: {cpu: 100m, memory: 512Mi}}
          volumeMounts:
            - {name: disk, mountPath: "/home/${AIDC_K8S_USER}"}
            - {name: home, mountPath: /home/git}
            - {name: cred, mountPath: /var/lib/gitctl/gitcred}
            - {name: run-store, mountPath: /var/lib/gitctl/gitrun}
            # The repos the user added (aidc repo add, from the laptop): read-only, and the pod
            # holds no API token, so nothing in it can add one (gitctl, ADDED_LIST).
            - {name: repos, mountPath: /etc/aidc/git-repos, readOnly: true}
      volumes:
        - {name: disk, persistentVolumeClaim: {claimName: disk}}
        - {name: home, persistentVolumeClaim: {claimName: git-home}}
        - {name: cred, persistentVolumeClaim: {claimName: git-cred}}
        - {name: run-store, persistentVolumeClaim: {claimName: git-run}}
        - {name: repos, configMap: {name: git-repos, defaultMode: 292}}  # 0444
EOF2
}

# k8s_render_git_repos <namespace> <list> [<resourceVersion>]: the ConfigMap holding the list of
# repos the user added (lib.sh, k8s_git_repos_*), as JSON for kubectl create or replace; with a
# resourceVersion, a replace of exactly that version.
k8s_render_git_repos() {
    jq -n --arg ns "$1" --arg repos "$2" --arg rv "${3:-}" --arg user "$AIDC_K8S_USER" '{
        apiVersion: "v1", kind: "ConfigMap",
        metadata: ({name: "git-repos", namespace: $ns,
            labels: {"app.kubernetes.io/managed-by": "aidc", "aidc/user": $user, app: "git"}}
            + (if $rv == "" then {} else {resourceVersion: $rv} end)),
        data: {repos: (if $repos == "" then "" else $repos + "\n" end)}}'
}

# The repo folder step's script (sh, as root in the init image, with only CHOWN, DAC_OVERRIDE,
# FOWNER and FSETID: the last so the setgid bit survives a chmod of a folder whose group,
# 1000, root is not in), for the folder $1 below the user's disk mounted at $2. Each step down is entered
# with cd -P and checked with pwd -P, so a symlink a session put on the way is refused, never
# followed. $3 is the mode:
#   make    before the clone: missing folders on the way are made as the session user, as
#           `mkdir -p` in a session would; the repo folder itself (missing or empty) is given
#           to the git container's agent ($4), writable by it alone, so nothing is planted in
#           it while gitctl clones;
#   own     after the clone: the working copy becomes the session user's, like any repo a
#           session made, group-shared (setgid) so the agent, in the session group, can work
#           in it too; symlinks in it are not followed;
#   requests  aidc git setup: the git container's request folder (missing parents as the
#           session user); made, or taken when empty, for the agent ($4) with the session group,
#           setgid, 2755. One that holds anything and is not the agent's is refused, not taken.
#   delete  aidc repo remove --delete-working-copy: the folder goes, if it is a git working copy.
#           It is emptied from inside, from the folder that was checked (find -delete does not
#           follow symlinks), and only then removed by name with rmdir, which removes nothing
#           but an empty folder: a session that swaps another folder in at that name after the
#           check gets an error, not that folder deleted by root.
# shellcheck disable=SC2016  # run by the pod's shell
K8S_REPO_DIR_SCRIPT='set -eu
p="$1" top="$2" mode="$3" agent="$4"
cd -P "$top"
rest="${p#"$top"/}" here="$top"
while [ -n "$rest" ]; do
    c="${rest%%/*}"
    if [ "$c" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    here="$here/$c"
    if [ -L "$c" ]; then echo "refused: $here is a symlink" >&2; exit 3; fi
    made=0
    if [ ! -e "$c" ]; then
        if [ "$mode" != make ] && [ "$mode" != requests ]; then echo "refused: $here does not exist" >&2; exit 3; fi
        mkdir "$c"; made=1
    fi
    cd -P "$c"
    if [ "$(pwd -P)" != "$here" ]; then echo "refused: $here moved on the way" >&2; exit 3; fi
    if [ -n "$rest" ] && [ "$made" = 1 ]; then chown 1000:1000 . && chmod 0755 .; fi
done
case "$mode" in
    make)
        if [ -n "$(ls -A .)" ]; then echo "refused: $p is not empty" >&2; exit 3; fi
        chown "$agent:1000" . && chmod 0755 .
        echo "ready: $p" ;;
    requests)
        if [ "$(stat -c %u .)" != "$agent" ]; then
            if [ -n "$(ls -A .)" ]; then echo "refused: $p holds files and does not belong to the git container: move it aside" >&2; exit 3; fi
            chown "$agent:1000" .
        fi
        chmod 2755 .
        echo "ready: $p" ;;
    own)
        chown -R -h 1000:1000 . && chmod 2775 .
        echo "owned: $p" ;;
    delete)
        if [ ! -d .git ] || [ -L .git ]; then echo "refused: $p is not a git working copy" >&2; exit 3; fi
        find . -mindepth 1 -delete
        cd -P ..
        if ! rmdir -- "$c"; then echo "refused: $p changed while it was deleted; its contents are gone, a folder now at its name is left" >&2; exit 3; fi
        echo "deleted: $p" ;;
    *) echo "refused: unknown mode $mode" >&2; exit 3 ;;
esac'

# k8s_render_repo_dir <pod-name> <cluster-path> <mode> <node-selector-json>: a one-shot pod
# running K8S_REPO_DIR_SCRIPT in <mode> (make, own or delete) for `aidc repo add|remove`.
# Root, because only root can give a folder on the session user's disk to the agent and back;
# with only the capabilities that needs, no escalation, no API token, no network (the
# namespace's default-deny).
k8s_render_repo_dir() {
    local name="$1" path="$2" mode="$3" sel="$4" ns
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: repo-dir}
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  nodeSelector: ${sel}
  tolerations: ${AIDC_K8S_TOLERATIONS}
  containers:
    - name: repo-dir
      image: ${K8S_INIT_IMAGE}
      command: [sh, -c, $(printf '%s' "$K8S_REPO_DIR_SCRIPT" | jq -Rs .), repo-dir, "${path}", "/home/${AIDC_K8S_USER}", "${mode}", "${K8S_GIT_AGENT_UID}"]
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL], add: [CHOWN, DAC_OVERRIDE, FOWNER, FSETID]}
      volumeMounts: [{name: disk, mountPath: "/home/${AIDC_K8S_USER}"}]
  volumes:
    - {name: disk, persistentVolumeClaim: {claimName: disk}}
EOF
}
