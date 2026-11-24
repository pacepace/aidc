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
    local rc
    rc=$(k8s_kubectl get runtimeclass "$AIDC_K8S_RUNTIME_CLASS" -o json 2>/dev/null \
        | yq -p=json -o=json -I=0 '.scheduling.nodeSelector // {}' 2>/dev/null || true)
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
