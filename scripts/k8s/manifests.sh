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
# configuration, and nothing off the node can reach it. Builders push through the Service.
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
  labels: {${K8S_MANAGED_BY}, aidc/role: system}
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
EOF
}

# k8s_render_builder <name>: a pod that runs Docker under the configured runtime class,
# trusting the in-cluster registry over plain HTTP, for `aidc k8s build`. Trusted aidc
# infrastructure: it fetches base images straight from the internet, not through a session's
# Squid.
k8s_render_builder() {
    local name="$1" ns host
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
  runtimeClassName: ${AIDC_K8S_RUNTIME_CLASS}
  hostUsers: false
  automountServiceAccountToken: false
  restartPolicy: Never
  nodeSelector: ${AIDC_K8S_NODE_SELECTOR}
  tolerations: ${AIDC_K8S_TOLERATIONS}
  initContainers:
    - name: daemon-json
      image: ${K8S_BUILDER_IMAGE}
      command: [sh, -c, 'printf "{\\"insecure-registries\\":[\\"%s\\"]}" "\$0" > /etc/docker/daemon.json', "${host}"]
      volumeMounts: [{name: etc-docker, mountPath: /etc/docker}]
  containers:
    - name: docker
      image: ${K8S_BUILDER_IMAGE}
      env: [{name: DOCKER_TLS_CERTDIR, value: ""}]
      volumeMounts: [{name: etc-docker, mountPath: /etc/docker}]
  volumes:
    - {name: etc-docker, emptyDir: {}}
EOF
}
