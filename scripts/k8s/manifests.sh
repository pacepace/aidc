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
    # Pod Security "baseline" (docs/design-12-kubernetes.md, "Users and credentials"): no
    # privileged pod, no host namespaces, ports or paths, only the default capabilities. It
    # admits every pod aidc makes here (Sysbox session pods with hostUsers: false, the proxy,
    # the git container with SETUID/SETGID/AUDIT_WRITE, the disk and repo folder steps);
    # "restricted" would refuse them (they start as root). It does not restrict the runtime
    # class.
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
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

# The user's transcript mirror (MCP-15 as amended; plan-aidc-2.0 Q-M3): each session's dev pod,
# and the git agent's, copies its Claude transcripts and writes its Claude Code hook events
# (MCP-46) into its own folder here, which the user's MCP server reads. A claim of its own, not
# a folder on the user's disk: every session mounts the whole disk, so a mirror there would let
# one session write another's transcripts and events; here each pod mounts only its own folder
# (subPath <session>, the git agent's `git`), as a Docker session mounts only its own. One claim
# per user, on the session class (a copy of what each session's home holds), never labelled
# with a session: aidc kill deletes a session's objects by label, and a session's folder is kept,
# as on Docker. Made once, when the first session or the git container needs it.
K8S_TRANSCRIPTS_CLAIM=transcripts
# Where a pod's own folder of the mirror is mounted (user-main.sh and gitctl-main.sh copy into
# it; hook-event.sh writes hook-events/ under it), the same path as on Docker.
K8S_TRANSCRIPT_OUT=/var/aidc/transcript-out
k8s_render_transcripts() {
    cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${K8S_TRANSCRIPTS_CLAIM}
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}}
spec:
  storageClassName: ${AIDC_K8S_SESSION_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: ${AIDC_K8S_TRANSCRIPTS_SIZE}}}
EOF
}

# k8s_ensure_transcripts <namespace>: the transcript mirror claim, made when it is not there yet
# (never applied over one that is: a changed size would be refused as a resize). Returns 1,
# saying why on stderr, when the cluster cannot be asked or does not take it.
k8s_ensure_transcripts() {
    k8s_ensure_claim "$1" "$K8S_TRANSCRIPTS_CLAIM" "transcript mirror" k8s_render_transcripts
}

# _k8s_mirror_dir_cmd <folder> <uid>: the root init step that readies a pod's own folder of the
# mirror: made when missing, given to <uid> (0700: conversations), and its hook events emptied,
# so the MCP never reads a Claude's state from the last event of the one before it (a restarted
# or replaced pod; the git agent's start does the same on Docker). Not followed: a symlink a
# session left as hook-events is removed, not its target; the folder itself is the pod's mount
# root, which nothing in the pod can replace.
_k8s_mirror_dir_cmd() {
    printf '%s' "d=/mirror/${1} && mkdir -p \"\$d\" && rm -rf -- \"\$d/hook-events\" && chown ${2}:${2} \"\$d\" && chmod 0700 \"\$d\""
}

# --- Claude: one login per user, and its broker (K8S-16, K8S-17, K8S-18) ---------------------
#
# Every session's Claude config dir (/home/vscode/.claude, CLAUDE_CONFIG_DIR) is its own folder
# of one claim per user, claude-config (subPath <session>; the git agent's `git`), so the user's
# Claude account broker, which mounts the claim whole, can replace each session's
# .credentials.json by rename (Claude Code re-reads it; it refuses one that is a symlink). A
# session mounts only its own folder. On the session class, never labelled with a session, made
# once when the first session, the git container or the broker needs it; aidc kill removes the
# session's folder (the broker's `forget`, or a one-shot pod when no broker runs).
#
# Claude's projects/ (conversations and memory) is not in that folder: it is the user's disk's
# .claude/projects, mounted over it, so every session of a repo shares one history (Q-K2), which
# Syncthing carries to the user's machines (K8S-18). The git agent keeps its own.
#
# The broker (claude-broker, broker/claude-broker.sh) holds the accounts' logins, refresh tokens
# included, on claude-accounts, a claim only its pod mounts, on the user's retained class (a lost
# claim is lost logins).
K8S_CLAUDE_CONFIG_CLAIM=claude-config
K8S_CLAUDE_ACCOUNTS_CLAIM=claude-accounts
K8S_BROKER_NAME=claude-broker
K8S_BROKER_CONFIG=claude-broker-config
# Where the broker mounts the two claims (broker/claude-broker.sh: BROKER_ACCESS, BROKER_HOME).
K8S_BROKER_ACCESS=/var/aidc/claude-config
K8S_BROKER_HOME=/var/lib/claude-broker
# The user's disk's Claude history folder (relative to the disk), and its shared Claude files
# (CLAUDE.md, rules/, skills/, agents/, commands/, keybindings.json, the settings template and
# status line), which come from the user's machines only: sessions mount them read-only.
K8S_DISK_PROJECTS=.claude/projects
K8S_DISK_SHARED=.claude-shared
# The session's first ~/.claude.json (k8s/session-create.sh), a key of its audit-seed ConfigMap,
# which the dev pod's claude-seed step mounts at K8S_CLAUDE_STATE_SEED_DIR.
K8S_CLAUDE_STATE_SEED=claude-state-seed.json
K8S_CLAUDE_STATE_SEED_DIR=/claude-state-seed

k8s_render_claude_config() {
    cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${K8S_CLAUDE_CONFIG_CLAIM}
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}}
spec:
  storageClassName: ${AIDC_K8S_SESSION_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: ${AIDC_K8S_CLAUDE_CONFIG_SIZE}}}
EOF
}

k8s_render_claude_accounts() {
    cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${K8S_CLAUDE_ACCOUNTS_CLAIM}
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_BROKER_NAME}}
spec:
  storageClassName: ${AIDC_K8S_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
EOF
}

# k8s_claim_missing <namespace> <claim> <what>: 0 when the claim is not there yet, 1 when it
# is; 2, saying why on stderr, when the cluster cannot be asked. A claim is made once and never
# applied over (a changed size would be refused as a resize).
k8s_claim_missing() {
    local have
    if ! have=$(k8s_get "$1" pvc "$2" -o name); then
        printf '[aidc] error: cannot read the %s claim in %s: the cluster did not answer (%s)\n' "$3" "$1" "$have" >&2
        return 2
    fi
    [ -z "$have" ]
}

# k8s_ensure_claude_config <namespace> / k8s_ensure_claude_accounts <namespace>: the claim, made
# when missing. Return 1, saying why on stderr, when the cluster cannot be asked or does not
# take it.
# k8s_ensure_claim <namespace> <claim> <what> <render-function>: the claim, made from what
# <render-function> prints when it is not there yet, and never applied over one that is. Every
# per-user claim aidc makes goes through here. Returns 1, saying why on stderr, when the cluster
# cannot be asked or does not take it.
k8s_ensure_claim() {
    local rc=0
    k8s_claim_missing "$1" "$2" "$3" || rc=$?
    case "$rc" in 1) return 0 ;; 2) return 1 ;; esac
    "$4" | k8s_kubectl apply -f - >/dev/null && return 0
    printf '[aidc] error: could not make the %s claim in %s\n' "$3" "$1" >&2
    return 1
}

k8s_ensure_claude_config() {
    k8s_ensure_claim "$1" "$K8S_CLAUDE_CONFIG_CLAIM" "Claude config" k8s_render_claude_config
}

k8s_ensure_claude_accounts() {
    k8s_ensure_claim "$1" "$K8S_CLAUDE_ACCOUNTS_CLAIM" "Claude accounts" k8s_render_claude_accounts
}

# _k8s_claude_dir_cmd <folder> <uid> <gid> <mode>: the root init step that readies a pod's own
# folder of claude-config (made when missing, given to its Claude's user). The folder is the
# pod's mount root, which nothing in the pod can replace.
_k8s_claude_dir_cmd() {
    printf '%s' "d=/claude-config/${1} && mkdir -p \"\$d\" && chown ${2}:${3} \"\$d\" && chmod ${4} \"\$d\""
}

# _k8s_claude_seed_cmd <image-claude-dir> [own-projects]: the Claude user's init step that fills
# a new folder of claude-config once (.aidc-seeded marks it): from the Claude config the pod's
# home already had (a session or git agent made before its config moved here keeps its login,
# settings and history), else the image's. A session's projects/ is left out (the user's disk's
# is mounted over it); with own-projects (the git agent) it comes along. Then, when that left
# no .claude.json, the state seed session-create wrote, if the pod mounts one.
_k8s_claude_seed_cmd() {
    local exclude="--exclude=./projects "
    [ "${2:-}" = own-projects ] && exclude=""
    printf '%s' "d=/claude-config-own && if [ ! -e \"\$d/.aidc-seeded\" ]; then src=${1}; if [ -d /seed/.claude ] && [ -n \"\$(ls -A /seed/.claude 2>/dev/null)\" ]; then src=/seed/.claude; fi; (cd \"\$src\" && tar ${exclude}-cf - .) | tar -C \"\$d\" -xf - && mkdir -p \"\$d/projects\" && if [ ! -e \"\$d/.claude.json\" ] && [ -s ${K8S_CLAUDE_STATE_SEED_DIR}/${K8S_CLAUDE_STATE_SEED} ]; then (umask 077 && cp ${K8S_CLAUDE_STATE_SEED_DIR}/${K8S_CLAUDE_STATE_SEED} \"\$d/.claude.json\"); fi && : > \"\$d/.aidc-seeded\"; fi"
}

# _k8s_claude_shared_cmd: the session user's step that links the user's shared Claude files (on
# the disk's .claude, which Syncthing keeps in step with the user's machines: CLAUDE.md, rules/,
# skills/, agents/, commands/, keybindings.json) into the session's Claude config dir, every start;
# a file of the session's own by that name is left as it is. A new session's settings.json is
# the template `aidc sync push-settings` left there, when there is one (laptop to cluster only).
_k8s_claude_shared_cmd() {
    printf '%s' "d=/claude-config-own; s=/home/${AIDC_K8S_USER}/${K8S_DISK_SHARED}; for n in CLAUDE.md rules skills agents commands keybindings.json; do if [ -L \"\$d/\$n\" ] || [ ! -e \"\$d/\$n\" ]; then ln -sfn \"\$s/\$n\" \"\$d/\$n\"; fi; done; if [ -f /shared-claude/settings.template.json ] && [ ! -e \"\$d/.aidc-settings-from-template\" ]; then cp /shared-claude/settings.template.json \"\$d/settings.json\" && : > \"\$d/.aidc-settings-from-template\"; fi; true"
}

# k8s_render_broker_config: the broker's settings from the user's config (claude_accounts: the
# order and each account's switch_at; claude_account_switch: auto or wait) as config.json.
k8s_render_broker_config() {
    local cfg json
    cfg=$(_aidc_global_config_file)
    json='{}'
    if [ -n "$cfg" ]; then
        json=$(aidc_yq '{"accounts": ((.claude_accounts // []) | map({"name": .name, "switch_at": (.switch_at // 90)})), "switch": (.claude_account_switch // "auto")}' -o=json -I=0 "$cfg" 2>/dev/null) || json='{}'
    fi
    AIDC_BROKER_CFG="$json" yq -n '
        .apiVersion = "v1" | .kind = "ConfigMap"
        | .metadata.name = "'"${K8S_BROKER_CONFIG}"'"
        | .metadata.namespace = "'"$(k8s_user_ns "$AIDC_K8S_USER")"'"
        | .metadata.labels = {"app.kubernetes.io/managed-by": "aidc", "aidc/user": "'"${AIDC_K8S_USER}"'", "app": "'"${K8S_BROKER_NAME}"'"}
        | .data."config.json" = strenv(AIDC_BROKER_CFG)'
}

# k8s_render_broker <node-selector-json>: the broker's NetworkPolicy (no way in; out to Quad9 for
# DNS and to public addresses on 443 only, where Claude's login and renewal go) and its
# Deployment. No ServiceAccount token: it needs no cluster API.
k8s_render_broker() {
    local sel="$1" ns
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    local labels="${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_BROKER_NAME}"
    cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${K8S_BROKER_NAME}, namespace: ${ns}, labels: {${labels}}}
spec:
  podSelector: {matchLabels: {app: ${K8S_BROKER_NAME}}}
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to: [{ipBlock: {cidr: 9.9.9.9/32}}, {ipBlock: {cidr: 149.112.112.112/32}}]
      ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 127.0.0.0/8]
      ports: [{protocol: TCP, port: 443}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${K8S_BROKER_NAME}, namespace: ${ns}, labels: {${labels}}}
spec:
  replicas: 1
  # One writer of the accounts' logins: never two brokers at once.
  strategy: {type: Recreate}
  selector: {matchLabels: {app: ${K8S_BROKER_NAME}}}
  template:
    metadata: {labels: {${labels}}}
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      nodeSelector: ${sel}
      tolerations: ${AIDC_K8S_TOLERATIONS}
      dnsPolicy: None
      dnsConfig: {nameservers: [9.9.9.9, 149.112.112.112]}
      securityContext: {seccompProfile: {type: RuntimeDefault}}
      initContainers:
        # The accounts' claim is the broker's alone (0700); a new claim is empty and root-owned.
        - name: accounts-dir
          image: ${K8S_INIT_IMAGE}
          command: [sh, -c, 'chown 1000:1000 /accounts && chmod 0700 /accounts']
          volumeMounts: [{name: accounts, mountPath: /accounts}]
      containers:
        - name: broker
          image: ${AIDC_K8S_REGISTRY_PULL}/aidc/broker:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          env:
            - {name: BROKER_HOME, value: ${K8S_BROKER_HOME}}
            - {name: BROKER_ACCESS, value: ${K8S_BROKER_ACCESS}}
            - {name: BROKER_CONFIG, value: /etc/claude-broker/config.json}
            # Claude Code updates come with the image (aidc k8s build), never into an account's folder.
            - {name: DISABLE_AUTOUPDATER, value: "1"}
            - {name: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, value: "1"}
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          resources: {requests: {cpu: 20m, memory: 128Mi}}
          volumeMounts:
            - {name: accounts, mountPath: ${K8S_BROKER_HOME}}
            - {name: claude-config, mountPath: ${K8S_BROKER_ACCESS}}
            - {name: config, mountPath: /etc/claude-broker, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: accounts, persistentVolumeClaim: {claimName: ${K8S_CLAUDE_ACCOUNTS_CLAIM}}}
        - {name: claude-config, persistentVolumeClaim: {claimName: ${K8S_CLAUDE_CONFIG_CLAIM}}}
        - {name: config, configMap: {name: ${K8S_BROKER_CONFIG}}}
        - {name: tmp, emptyDir: {}}
EOF
}

# k8s_claude_token_name <session> / k8s_render_claude_token <session> <token>: the session's own
# Secret holding the long-lived Claude token (the stopgap with no broker: broker.sh,
# k8s_claude_token_secret). Made with `kubectl create -f -` (the token never on a command line),
# removed by name at kill; the user's credentials cannot read it back.
k8s_claude_token_name() { printf '%s-claude-token' "$1"; }
k8s_render_claude_token() {
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $(k8s_claude_token_name "$1")
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, aidc/session: ${1}}
type: Opaque
stringData: {token: "${2}"}
EOF
}

# _k8s_claude_token_env <session>: the dev container's CLAUDE_CODE_OAUTH_TOKEN from the session's
# token Secret, when create made one (AIDC_K8S_CLAUDE_TOKEN_SECRET=1); nothing otherwise.
_k8s_claude_token_env() {
    [ "${AIDC_K8S_CLAUDE_TOKEN_SECRET:-0}" = 1 ] || return 0
    printf '            - {name: CLAUDE_CODE_OAUTH_TOKEN, valueFrom: {secretKeyRef: {name: %s, key: token}}}\n' "$(k8s_claude_token_name "$1")"
}

# k8s_render_claude_forget <session> <node-selector-json>: a one-shot pod removing a killed
# session's folder of claude-config when no broker runs to do it.
k8s_render_claude_forget() {
    local session="$1" sel="$2"
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${session}-claude-forget
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: claude-forget}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  nodeSelector: ${sel}
  tolerations: ${AIDC_K8S_TOLERATIONS}
  containers:
    - name: forget
      image: ${K8S_INIT_IMAGE}
      command: [sh, -c, 'rm -rf -- "/claude-config/\$1"', sh, "${session}"]
      volumeMounts: [{name: claude-config, mountPath: /claude-config}]
  volumes:
    - {name: claude-config, persistentVolumeClaim: {claimName: ${K8S_CLAUDE_CONFIG_CLAIM}}}
EOF
}

# --- Syncthing: one Claude history per repo on every machine (K8S-18) -----------------------
#
# One pod per user (`aidc sync start`) syncing the user's disk's .claude/projects (every
# session's conversations and memory, both ways) and .claude-shared (the user's CLAUDE.md, rules,
# skills, agents, commands and keybindings, from their machines only: Receive Only here, and
# read-only in sessions; lib/claude-sync.sh) with the user's own machines, over the LAN or VPN
# only (Q-K11):
# no global discovery, no relays, no local announcements, no NAT traversal; it dials each
# machine the config names, at the address given, and its NetworkPolicy lets it reach exactly
# those, on Syncthing's port. Nothing may connect to it. aidc writes its whole configuration
# (config.xml, the folder's .stignore) from the user's config on every start; its device key
# and certificate, which are its identity to the user's machines, are on a claim of its own on
# the user's retained class.
# shellcheck source=../lib/claude-sync.sh
. "${AIDC_SCRIPTS}/lib/claude-sync.sh"
K8S_SYNC_NAME=syncthing
K8S_SYNC_CONFIG=syncthing-config
K8S_SYNC_CLAIM=syncthing
K8S_SYNC_IMAGE="${K8S_SYNC_IMAGE:-docker.io/syncthing/syncthing:2.0.0}"
K8S_SYNC_PORT=22000

k8s_render_sync_claim() {
    cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${K8S_SYNC_CLAIM}
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_SYNC_NAME}}
spec:
  storageClassName: ${AIDC_K8S_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
EOF
}

# _k8s_xml <text>: <text> escaped for an XML attribute or element.
_k8s_xml() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# k8s_sync_config_xml <peer-lines>: Syncthing's config.xml; <peer-lines> one
# "<name> <device-id> <ipv4> <port>" a line.
k8s_sync_config_xml() {
    local peers="$1" name id ip port devices="" folder_devices=""
    while read -r name id ip port; do
        [ -n "$id" ] || continue
        devices="${devices}    <device id=\"${id}\" name=\"$(_k8s_xml "$name")\" compression=\"metadata\" introducer=\"false\">
        <address>tcp://${ip}:${port}</address>
        <paused>false</paused>
        <autoAcceptFolders>false</autoAcceptFolders>
    </device>
"
        folder_devices="${folder_devices}        <device id=\"${id}\"></device>
"
    done <<<"$peers"
    cat <<EOF
<configuration version="37">
    <folder id="${AIDC_SYNC_PROJECTS_ID}" label="Claude conversations (aidc)" path="/var/syncthing/projects" type="sendreceive" rescanIntervalS="3600" fsWatcherEnabled="true" fsWatcherDelayS="10" ignorePerms="false" autoNormalize="true">
        <filesystemType>basic</filesystemType>
${folder_devices}        <minDiskFree unit="%">1</minDiskFree>
        <versioning></versioning>
    </folder>
    <folder id="${AIDC_SYNC_SHARED_ID}" label="Claude files from your machines (aidc)" path="/var/syncthing/shared" type="receiveonly" rescanIntervalS="3600" fsWatcherEnabled="true" fsWatcherDelayS="10" ignorePerms="false" autoNormalize="true">
        <filesystemType>basic</filesystemType>
${folder_devices}        <minDiskFree unit="%">1</minDiskFree>
        <versioning></versioning>
    </folder>
${devices}    <gui enabled="true" tls="false">
        <address>127.0.0.1:8384</address>
    </gui>
    <options>
        <listenAddress>tcp://0.0.0.0:${K8S_SYNC_PORT}</listenAddress>
        <globalAnnounceEnabled>false</globalAnnounceEnabled>
        <localAnnounceEnabled>false</localAnnounceEnabled>
        <relaysEnabled>false</relaysEnabled>
        <natEnabled>false</natEnabled>
        <urAccepted>-1</urAccepted>
        <crashReportingEnabled>false</crashReportingEnabled>
        <autoUpgradeIntervalH>0</autoUpgradeIntervalH>
        <startBrowser>false</startBrowser>
    </options>
</configuration>
EOF
}

# k8s_render_sync_config <peer-lines>: the ConfigMap holding config.xml and the .stignore.
k8s_render_sync_config() {
    AIDC_SYNC_XML="$(k8s_sync_config_xml "$1")" AIDC_SYNC_IGNORE_P="$(aidc_sync_stignore_projects)" \
        AIDC_SYNC_IGNORE_S="$(aidc_sync_stignore_shared)" yq -n '
        .apiVersion = "v1" | .kind = "ConfigMap"
        | .metadata.name = "'"${K8S_SYNC_CONFIG}"'"
        | .metadata.namespace = "'"$(k8s_user_ns "$AIDC_K8S_USER")"'"
        | .metadata.labels = {"app.kubernetes.io/managed-by": "aidc", "aidc/user": "'"${AIDC_K8S_USER}"'", "app": "'"${K8S_SYNC_NAME}"'"}
        | .data."config.xml" = strenv(AIDC_SYNC_XML)
        | .data."projects.stignore" = strenv(AIDC_SYNC_IGNORE_P)
        | .data."shared.stignore" = strenv(AIDC_SYNC_IGNORE_S)'
}

# k8s_render_sync <node-selector-json> <peer-lines>: the NetworkPolicy (no way in; out to each
# of the user's machines on its port only) and the Deployment.
k8s_render_sync() {
    local sel="$1" peers="$2" ns egress="" name id ip port
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    while read -r name id ip port; do
        [ -n "$ip" ] || continue
        egress="${egress}    - to: [{ipBlock: {cidr: ${ip}/32}}]
      ports: [{protocol: TCP, port: ${port}}]
"
    done <<<"$peers"
    [ -n "$egress" ] || egress="    []
"
    local labels="${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_SYNC_NAME}"
    cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${K8S_SYNC_NAME}, namespace: ${ns}, labels: {${labels}}}
spec:
  podSelector: {matchLabels: {app: ${K8S_SYNC_NAME}}}
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
${egress}---
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${K8S_SYNC_NAME}, namespace: ${ns}, labels: {${labels}}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: ${K8S_SYNC_NAME}}}
  template:
    metadata: {labels: {${labels}}}
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      nodeSelector: ${sel}
      tolerations: ${AIDC_K8S_TOLERATIONS}
      # No DNS: it dials the user's machines by address.
      dnsPolicy: None
      dnsConfig: {nameservers: [127.0.0.1]}
      securityContext: {seccompProfile: {type: RuntimeDefault}}
      initContainers:
        # The disk's .claude, made as the session user before anything mounts it (a subPath
        # that is missing is made root-owned, which no session could then write).
        - name: claude-dir
          image: ${K8S_INIT_IMAGE}
          command: [sh, -c, 'umask 002 && mkdir -p "/disk/${K8S_DISK_PROJECTS}" "/disk/${K8S_DISK_SHARED}"']
          securityContext: {runAsUser: 1000, runAsGroup: 1000}
          volumeMounts: [{name: disk, mountPath: /disk}]
        # Its key's claim is its alone; a new claim is empty and root-owned.
        - name: config-dir
          image: ${K8S_INIT_IMAGE}
          command: [sh, -c, 'chown 1000:1000 /config && chmod 0700 /config']
          volumeMounts: [{name: config, mountPath: /config}]
        # aidc's configuration, every start (Syncthing rewrites config.xml as it runs; what the
        # user's config says wins at the next start), and the folder's .stignore.
        - name: settings
          image: ${K8S_INIT_IMAGE}
          command: [sh, -c, 'umask 077 && cp /settings/config.xml /config/config.xml && umask 022 && cp /settings/projects.stignore /projects/.stignore && cp /settings/shared.stignore /shared/.stignore']
          securityContext: {runAsUser: 1000, runAsGroup: 1000}
          volumeMounts:
            - {name: config, mountPath: /config}
            - {name: settings, mountPath: /settings, readOnly: true}
            - {name: disk, mountPath: /projects, subPath: ${K8S_DISK_PROJECTS}}
            - {name: disk, mountPath: /shared, subPath: ${K8S_DISK_SHARED}}
      containers:
        - name: syncthing
          image: ${K8S_SYNC_IMAGE}
          command: [/bin/syncthing, serve, --home=/var/syncthing/config, --no-browser, --no-restart, --no-upgrade, --gui-address=127.0.0.1:8384]
          env:
            - {name: HOME, value: /var/syncthing}
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          resources: {requests: {cpu: 50m, memory: 128Mi}}
          volumeMounts:
            - {name: config, mountPath: /var/syncthing/config}
            - {name: disk, mountPath: /var/syncthing/projects, subPath: ${K8S_DISK_PROJECTS}}
            - {name: disk, mountPath: /var/syncthing/shared, subPath: ${K8S_DISK_SHARED}}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: config, persistentVolumeClaim: {claimName: ${K8S_SYNC_CLAIM}}}
        - {name: settings, configMap: {name: ${K8S_SYNC_CONFIG}}}
        - {name: disk, persistentVolumeClaim: {claimName: disk}}
        - {name: tmp, emptyDir: {}}
EOF
}

# --- Users' credentials (docs/design-12-kubernetes.md, "Users and credentials") ---------------
#
# What a user's own credentials may do: exactly what aidc's commands do in the user's namespace
# (tests/unit/test-k8s-rbac.sh reads every kubectl call in scripts/ and fails on one these rules
# do not grant). One rule a line: "<apiGroup> <resource> <verbs,...> [<resourceName>]", with
# "core" for the core group. `aidc user add` renders the Role from it; `aidc k8s check` compares
# the credentials in use with it.
#   reads (get, list, watch) on everything aidc reads: `kubectl get` by name or label,
#     `rollout status` and `wait`, and the `kubectl describe` aidc's errors point to (events)
#   create and patch: `kubectl apply` (sessions, relays, network policies, pages, the git
#     container, the repo folder pods); create and update: the repo list (configmap git-repos,
#     written at a resourceVersion)
#   delete: aidc kill (by label), aidc restart (the dev pod), the repo folder pods, audit trim
#   pods/exec (create and get: kubectl's exec is a websocket GET that newer API servers also
#     authorize as create), pods/log; pods/portforward: the tunnels (aidc create --port, proxy)
#   secrets create and delete only: a page's login (an htpasswd hash) is made with `kubectl
#     create` and removed by name, so no read of the namespace's Secrets is granted (no get, no
#     list); the admission policy (k8s_render_user_shared) refuses ServiceAccount token Secrets
#   ingresses: the pages (--expose); middlewares.traefik.io create and delete: a page's login
#     on Traefik, made with `kubectl create` and removed by name (a rule for a kind the cluster
#     does not have grants nothing). The admission policies narrow every Ingress to the user's
#     own page names under the configured domain and aidc's annotations, every Service to a
#     ClusterIP, and every Middleware to a basicAuth login reading a Secret of its own
#     namespace. Credentials are issued only where those policies can exist
#     (ValidatingAdmissionPolicy, Kubernetes 1.30; lib.sh, K8S_NO_VAP_WHY).
#   serviceaccounts/token on aidc-user only: the user renews their own kubeconfig
#   secrets get on aidc-mcp-token only: `aidc mcp` reads the user's MCP token into
#     ~/.config/aidc/mcp-token (MCP-05), and no other Secret of the namespace
K8S_USER_SA=aidc-user
K8S_USER_RULES='core pods get,list,watch,create,patch,delete
core pods/exec create,get
core pods/log get
core pods/portforward create
core services get,list,watch,create,patch,delete
core configmaps get,list,watch,create,patch,update,delete
core persistentvolumeclaims get,list,watch,create,patch,delete
core events get,list,watch
core secrets create,delete
core serviceaccounts/token create aidc-user
core secrets get aidc-mcp-token
apps deployments get,list,watch,create,patch,delete
apps statefulsets get,list,watch,create,patch,delete
networking.k8s.io networkpolicies get,list,watch,create,patch,delete
networking.k8s.io ingresses get,list,watch,create,patch,delete
traefik.io middlewares create,delete'

# The cluster-wide part, one ClusterRole shared by all users, bound per user:
#   runtimeclasses, storageclasses (get): aidc create and git setup read the runtime class's node
#     selector; aidc k8s check reads both
#   ingressclasses (get): --expose reads the configured IngressClass's controller when the
#     config does not name it
#   nodes (list): aidc k8s check, the ready nodes sessions can land on
#   persistentvolumes (get, list, watch, patch): aidc audit lists released audit volumes, and
#     trim sets a volume to Delete before deleting its claim, so the data goes with it. RBAC
#     cannot say "volumes claimed in your namespace", so patch is narrowed by an admission
#     policy (k8s_render_user_shared): only a volume claimed in the user's own namespace, only
#     to Delete, its claim unchanged.
# Not granted: listing Ingresses cluster-wide (it would show every user's page names); the page
# name check reads the user's own namespace, and the admission policy keeps users' page names
# apart (docs/design-12-kubernetes.md, "Users and credentials").
K8S_USER_CLUSTER_RULES='node.k8s.io runtimeclasses get
storage.k8s.io storageclasses get
networking.k8s.io ingressclasses get
core nodes list
core persistentvolumes get,list,watch,patch'

# The user's MCP server (W-M2; plan-aidc-2.0 Q-M2): its ServiceAccount drives the session
# lifecycle in its own namespace only (create, kill, status, list, attach and send by exec,
# logs, restart, upgrade, refresh, audit list) and the git container's request registration by
# exec. No bare pods (sessions are StatefulSets and Deployments), no repo list, no tokens, no
# volumes, no tunnels (they end on the machine that runs them), no pages of its own: it may
# list and delete Ingresses and delete a page's login (by name) so its aidc kill removes pages
# the user made. Pod Security "baseline" bounds what any pod it makes may do.
K8S_MCP_SA=aidc-mcp
K8S_MCP_RULES='core pods get,list,watch,delete
core pods/exec create,get
core pods/log get
core services get,list,watch,create,patch,delete
core configmaps get,list,watch,create,patch,delete
core persistentvolumeclaims get,list,watch,create,patch,delete
core events get,list,watch
core secrets delete
apps deployments get,list,watch,create,patch,delete
apps statefulsets get,list,watch,create,patch,delete
networking.k8s.io networkpolicies get,list,watch,create,patch,delete
networking.k8s.io ingresses list,watch,delete
traefik.io middlewares delete'
K8S_MCP_CLUSTER_RULES='node.k8s.io runtimeclasses get'

# Another namespace a user's sessions may reach (--network): a ClusterRole bound in that
# namespace only, by `aidc user allow-network <user> <namespace>` (an admin's grant), so the
# session's names responder can serve its Services. Never bound cluster-wide.
K8S_NETWORK_RULES='core services list'

# Cluster-scoped names: shared by every user of this prefix, or one user's.
k8s_user_clusterrole()   { printf '%s-user' "$AIDC_K8S_PREFIX"; }
k8s_mcp_clusterrole()    { printf '%s-mcp' "$AIDC_K8S_PREFIX"; }
k8s_user_volume_policy() { printf '%s-user-volumes' "$AIDC_K8S_PREFIX"; }
k8s_user_ingress_policy() { printf '%s-user-ingresses' "$AIDC_K8S_PREFIX"; }
k8s_user_service_policy() { printf '%s-user-services' "$AIDC_K8S_PREFIX"; }
k8s_user_secret_policy() { printf '%s-user-secrets' "$AIDC_K8S_PREFIX"; }
k8s_user_middleware_policy() { printf '%s-user-middlewares' "$AIDC_K8S_PREFIX"; }
k8s_network_clusterrole() { printf '%s-network' "$AIDC_K8S_PREFIX"; }
k8s_network_rb()         { printf '%s-u-%s-network' "$AIDC_K8S_PREFIX" "$1"; }
k8s_user_crb()           { printf '%s-u-%s' "$AIDC_K8S_PREFIX" "$1"; }
k8s_mcp_crb()            { printf '%s-u-%s-mcp' "$AIDC_K8S_PREFIX" "$1"; }

# _k8s_rules_yaml <rules>: the rules table as a YAML list of RBAC rules (flow style).
_k8s_rules_yaml() {
    printf '%s\n' "$1" | awk 'NF {
        g = ($1 == "core") ? "\"\"" : "\"" $1 "\""
        n = split($3, v, ","); verbs = ""
        for (i = 1; i <= n; i++) verbs = verbs (i > 1 ? ", " : "") v[i]
        printf "  - {apiGroups: [%s], resources: [%s], verbs: [%s]%s}\n", g, $2, verbs, \
            (NF >= 4 ? ", resourceNames: [" $4 "]" : "")
    }'
}

# k8s_render_user_access <user>: the user's and their MCP's ServiceAccounts, Roles and
# RoleBindings in the user's namespace, and their ClusterRoleBindings.
k8s_render_user_access() {
    local user="$1" ns sa rules crb cr
    ns=$(k8s_user_ns "$user")
    for sa in "$K8S_USER_SA" "$K8S_MCP_SA"; do
        rules="$K8S_USER_RULES" crb=$(k8s_user_crb "$user") cr=$(k8s_user_clusterrole)
        if [ "$sa" = "$K8S_MCP_SA" ]; then
            rules="$K8S_MCP_RULES" crb=$(k8s_mcp_crb "$user") cr=$(k8s_mcp_clusterrole)
        fi
        cat <<YAML
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: ${sa}, namespace: ${ns}, labels: {${K8S_MANAGED_BY}, aidc/user: ${user}}}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: ${sa}, namespace: ${ns}, labels: {${K8S_MANAGED_BY}, aidc/user: ${user}}}
rules:
$(_k8s_rules_yaml "$rules")
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: ${sa}, namespace: ${ns}, labels: {${K8S_MANAGED_BY}, aidc/user: ${user}}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: ${sa}}
subjects: [{kind: ServiceAccount, name: ${sa}, namespace: ${ns}}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: ${crb}, labels: {${K8S_MANAGED_BY}, aidc/user: ${user}}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: ${cr}}
subjects: [{kind: ServiceAccount, name: ${sa}, namespace: ${ns}}]
YAML
    done
}

# k8s_render_network_clusterrole: the ClusterRole `aidc user allow-network` binds in another
# namespace (K8S_NETWORK_RULES).
k8s_render_network_clusterrole() {
    cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: $(k8s_network_clusterrole), labels: {${K8S_MANAGED_BY}}}
rules:
$(_k8s_rules_yaml "$K8S_NETWORK_RULES")
YAML
}

# k8s_render_network_access <user> <namespace>: the RoleBinding in <namespace> that lets the
# user and their MCP read its Services (for --network), and nothing else there.
k8s_render_network_access() {
    local user="$1" target="$2" ns
    ns=$(k8s_user_ns "$user")
    cat <<YAML
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $(k8s_network_rb "$user")
  namespace: ${target}
  labels: {${K8S_MANAGED_BY}, aidc/user: ${user}, aidc/grant: network}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: $(k8s_network_clusterrole)}
subjects:
  - {kind: ServiceAccount, name: ${K8S_USER_SA}, namespace: ${ns}}
  - {kind: ServiceAccount, name: ${K8S_MCP_SA}, namespace: ${ns}}
YAML
}

# k8s_render_user_shared: the ClusterRoles every user's bindings name, and the admission policies
# that narrow the volume patch and what a user may make in their namespace. Page names are held
# to the configured domain (kubernetes.ingress.domain, read when this is rendered: aidc user add);
# with none configured, the policy refuses every page. The caller has checked the cluster has
# ValidatingAdmissionPolicy (no credentials are issued without it) and that the domain, if any,
# is a domain name (it goes into the policy's expressions).
k8s_render_user_shared() {
    local rules="$K8S_USER_CLUSTER_RULES" sa_prefix
    sa_prefix="system:serviceaccount:${AIDC_K8S_PREFIX}-u-"
    cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: $(k8s_user_clusterrole), labels: {${K8S_MANAGED_BY}}}
rules:
$(_k8s_rules_yaml "$rules")
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: $(k8s_mcp_clusterrole), labels: {${K8S_MANAGED_BY}}}
rules:
$(_k8s_rules_yaml "$K8S_MCP_CLUSTER_RULES")
---
$(k8s_render_network_clusterrole)
YAML
    local user_ns_prefix="${AIDC_K8S_PREFIX}-u-"
    cat <<YAML
---
# Every volume change by a user's ServiceAccount (${sa_prefix}<user>:${K8S_USER_SA}) is refused
# unless the volume is claimed in that user's own namespace, the change sets its reclaim policy
# to Delete, and its claim reference stays as it was (a volume is never handed to another
# namespace). RBAC grants the patch; this policy is what makes it narrow.
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: $(k8s_user_volume_policy), labels: {${K8S_MANAGED_BY}}}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - {apiGroups: [""], apiVersions: [v1], operations: [UPDATE, DELETE], resources: [persistentvolumes]}
  matchConditions:
    - name: aidc-user
      expression: "request.userInfo.username.startsWith('${sa_prefix}') && request.userInfo.username.endsWith(':${K8S_USER_SA}')"
  validations:
    - expression: "request.operation == 'UPDATE'"
      message: "an aidc user may not delete volumes"
    - expression: "has(oldObject.spec.claimRef) && has(oldObject.spec.claimRef.namespace) && request.userInfo.username == 'system:serviceaccount:' + oldObject.spec.claimRef.namespace + ':${K8S_USER_SA}'"
      message: "an aidc user may change only volumes claimed in their own namespace"
    - expression: "has(object.spec.claimRef) && object.spec.claimRef == oldObject.spec.claimRef"
      message: "an aidc user may not change a volume's claim"
    - expression: "object.spec.persistentVolumeReclaimPolicy == 'Delete'"
      message: "an aidc user may only set a volume's reclaim policy to Delete"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: $(k8s_user_volume_policy), labels: {${K8S_MANAGED_BY}}}
spec:
  policyName: $(k8s_user_volume_policy)
  validationActions: [Deny]
YAML
    local vars checks
    # shellcheck disable=SC2016  # CEL, not shell
    vars=$(cat <<'CEL'
    - name: user
      expression: "request.namespace.startsWith('@NSP@') ? request.namespace.substring(@NSN@) : ''"
    - name: host
      expression: "'^[a-z0-9-]+-' + variables.user + '[.]@DOMRE@$'"
    - name: ann
      expression: "has(object.metadata.annotations) ? object.metadata.annotations : {}"
CEL
)
    local domain="${AIDC_K8S_INGRESS_DOMAIN:-}"
    vars=${vars//@NSP@/${user_ns_prefix}}; vars=${vars//@NSN@/${#user_ns_prefix}}
    vars=${vars//@DOMRE@/${domain//./[.]}}
    # shellcheck disable=SC2016
    checks=$(cat <<'CEL'
    - expression: "!has(object.spec.defaultBackend) && has(object.spec.rules) && size(object.spec.rules) > 0 && object.spec.rules.all(r, has(r.host) && r.host.matches(variables.host))"
      message: "an aidc user's Ingress serves only their own page names (<session>-<user>.@DOMAIN@), with no default backend"
    - expression: "!has(object.spec.tls) || object.spec.tls.all(t, !has(t.hosts) || t.hosts.all(h, h.matches(variables.host)))"
      message: "an aidc user's Ingress certificate names only their own page names"
    - expression: "variables.ann.all(k, k in ['aidc/expose-port', 'kubectl.kubernetes.io/last-applied-configuration', 'traefik.ingress.kubernetes.io/router.middlewares', 'nginx.ingress.kubernetes.io/auth-type', 'nginx.ingress.kubernetes.io/auth-secret', 'nginx.ingress.kubernetes.io/auth-realm', 'cert-manager.io/cluster-issuer'])"
      message: "an aidc user's Ingress carries only the annotations aidc sets"
    - expression: "!('traefik.ingress.kubernetes.io/router.middlewares' in variables.ann) || variables.ann['traefik.ingress.kubernetes.io/router.middlewares'].matches('^' + request.namespace + '-[a-z0-9-]+@kubernetescrd$')"
      message: "an aidc user's page uses only a login Middleware of their own namespace"
    - expression: "!('nginx.ingress.kubernetes.io/auth-secret' in variables.ann) || !variables.ann['nginx.ingress.kubernetes.io/auth-secret'].contains('/')"
      message: "an aidc user's page uses only a login Secret of their own namespace"
CEL
)
    checks=${checks//@DOMAIN@/${domain}}
    if [ -z "$domain" ]; then
        checks='    - expression: "false"
      message: "no page domain (kubernetes.ingress.domain) was configured when aidc user add set up this cluster: an aidc user may make no pages; an admin sets it and runs aidc user add again"'
    fi
    _k8s_user_object_policy "$(k8s_user_ingress_policy)" networking.k8s.io '"*"' ingresses "$vars" "$checks"
    _k8s_user_object_policy "$(k8s_user_service_policy)" '""' v1 services "" \
'    - expression: "(!has(object.spec.type) || object.spec.type == '"'ClusterIP'"') && (!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0)"
      message: "an aidc user'"'"'s Service is a ClusterIP with no external IPs"'
    _k8s_user_object_policy "$(k8s_user_secret_policy)" '""' v1 secrets "" \
'    - expression: "!has(object.type) || object.type != '"'kubernetes.io/service-account-token'"'"
      message: "an aidc user may not make ServiceAccount token Secrets"'
    # shellcheck disable=SC2016
    _k8s_user_object_policy "$(k8s_user_middleware_policy)" traefik.io '"*"' middlewares "" \
'    - expression: "has(object.spec) && object.spec.all(k, k == '"'basicAuth'"')"
      message: "an aidc user'"'"'s Middleware is a page login: basicAuth and nothing else"
    - expression: "has(object.spec.basicAuth) && has(object.spec.basicAuth.secret) && object.spec.basicAuth.all(k, k in ['"'secret', 'realm', 'removeHeader'"']) && object.spec.basicAuth.secret.matches('"'^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'"')"
      message: "an aidc user'"'"'s login Middleware reads a Secret of its own namespace (a plain name), with at most a realm and removeHeader besides"'
}

# What a user's or their MCP's ServiceAccount makes in the user's namespace, narrowed where RBAC
# cannot (it grants a verb on a kind, not on what the object says), one policy per kind (so each
# expression is checked against its own kind's schema):
#   - an Ingress serves only the user's own page names under the configured domain: every host
#     is <label>-<user>.<domain> (<session>-<user>, <session>-<port>-<user>; `aidc user add`
#     refuses a user name that ends in -<another user> or starts with <another user>-, so no
#     two users' page names or namespaces overlap), no default backend, and only the
#     annotations aidc sets (no controller snippets, no login from another namespace: Traefik
#     names a Middleware <namespace>-<name>, which the start rule keeps unambiguous);
#   - a Service is a ClusterIP with no external IPs (no node port, load balancer or external
#     address: those would reach past the namespace's policies or take other traffic);
#   - a Secret is never a ServiceAccount token (a token that would not expire);
#   - a Traefik Middleware is a basicAuth login reading a Secret of its own namespace, and
#     nothing else: other kinds make the controller itself act (forwardAuth calls any address
#     the user names, from the controller's place in the network, which every user's exposed
#     port lets in; errors fetches a page from any Service), so only the login aidc makes is
#     allowed.
k8s_user_object_policies() { printf '%s %s %s %s' "$(k8s_user_ingress_policy)" "$(k8s_user_service_policy)" "$(k8s_user_secret_policy)" "$(k8s_user_middleware_policy)"; }

# _k8s_user_object_policy <name> <apiGroup> <apiVersion> <resource> <variables yaml> <validations
# yaml>: one such policy and its binding, on create and update by a user's or their MCP's
# ServiceAccount.
_k8s_user_object_policy() {
    local sa_prefix="system:serviceaccount:${AIDC_K8S_PREFIX}-u-"
    cat <<YAML
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: ${1}, labels: {${K8S_MANAGED_BY}}}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - {apiGroups: [${2}], apiVersions: [${3}], operations: [CREATE, UPDATE], resources: [${4}]}
  matchConditions:
    - name: aidc-user
      expression: "request.userInfo.username.startsWith('${sa_prefix}') && (request.userInfo.username.endsWith(':${K8S_USER_SA}') || request.userInfo.username.endsWith(':${K8S_MCP_SA}'))"
${5:+  variables:
${5}
}  validations:
${6}
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: ${1}, labels: {${K8S_MANAGED_BY}}}
spec:
  policyName: ${1}
  validationActions: [Deny]
YAML
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
    # The taint webhook (W-M4): the policy sidecar pokes the user's MCP server at its Service
    # address (AIDC_K8S_TAINT_WEBHOOK_IP, read at create; the proxy pod has no cluster DNS), on
    # that one port; the rule names both the server's pods and the Service address, since a
    # network plugin may judge before or after the address is translated. Squid refuses every
    # private address, so nothing a session asks for reaches it.
    local webhook="" webhook_rule=""
    if [ -n "${AIDC_K8S_TAINT_WEBHOOK_IP:-}" ]; then
        webhook="http://${AIDC_K8S_TAINT_WEBHOOK_IP}:${K8S_MCP_TAINT_PORT}/taint"
        webhook_rule="    - to: [{podSelector: {matchLabels: {app: ${K8S_MCP_NAME}}}}, {ipBlock: {cidr: ${AIDC_K8S_TAINT_WEBHOOK_IP}/32}}]
      ports: [{protocol: TCP, port: ${K8S_MCP_TAINT_PORT}}]
"
    fi
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
${dns_rule}${webhook_rule}    - to:
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
        # The session's folder of claude-config and the user's disk's Claude history folder, made
        # here, before any pod mounts a part of them (a subPath that is missing is made root-owned,
        # which the session could not write): the folder by root, given to the session user; the
        # history folder as the session user, on the disk sessions write.
        - name: claude-dirs
          image: ${img}/audit:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          command: [sh, -c, '$(_k8s_claude_dir_cmd "$session" 1000 1000 0700)']
          volumeMounts: [{name: claude-config, mountPath: /claude-config}]
        - name: claude-projects
          image: ${img}/audit:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          command: [sh, -c, 'umask 002 && mkdir -p "/disk/${K8S_DISK_PROJECTS}" "/disk/${K8S_DISK_SHARED}"']
          securityContext: {runAsUser: 1000, runAsGroup: 1000}
          volumeMounts: [{name: disk, mountPath: /disk}]
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
            - {name: AIDC_TAINT_WEBHOOK, value: "${webhook}"}
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
            # The session's Claude history folder is the user's disk's, shared by the user's
            # sessions: its own conversations are the ones its mirror folder holds.
            - {name: AIDC_AUDIT_CLAUDE_PROJECTS, value: /var/aidc/session-transcripts}
          volumeMounts:
            - {name: squid-log, mountPath: /var/log/squid, readOnly: true}
            - {name: aidc-log, mountPath: /var/log/aidc, readOnly: true}
            - {name: state, mountPath: /var/state, readOnly: true}
            - {name: home, mountPath: /var/aidc/dev-home, readOnly: true}
            - {name: transcripts, mountPath: /var/aidc/session-transcripts, subPath: ${session}, readOnly: true}
            - {name: audit, mountPath: /var/aidc/audit}
      volumes:
        - {name: blocklist, emptyDir: {}}
        - {name: squid-log, emptyDir: {}}
        - {name: aidc-log, emptyDir: {}}
        - {name: state, persistentVolumeClaim: {claimName: ${session}-state}}
        - {name: home, persistentVolumeClaim: {claimName: ${session}-home}}
        - {name: audit, persistentVolumeClaim: {claimName: ${audit}}}
        - {name: audit-seed, configMap: {name: ${session}-audit-seed}}
        - {name: disk, persistentVolumeClaim: {claimName: disk}}
        - {name: claude-config, persistentVolumeClaim: {claimName: ${K8S_CLAUDE_CONFIG_CLAIM}}}
        - {name: transcripts, persistentVolumeClaim: {claimName: ${K8S_TRANSCRIPTS_CLAIM}}}
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
        # The session's own folder of the transcript mirror (k8s_render_transcripts).
        - name: mirror-dir
          image: ${img}/dev-base:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          command: [sh, -c, '$(_k8s_mirror_dir_cmd "$session" 1000)']
          volumeMounts: [{name: transcripts, mountPath: /mirror}]
        # The session's Claude config dir, filled once (k8s_render_claude_config; its folder is
        # made by the proxy pod's claude-dirs step).
        - name: claude-seed
          image: ${img}/dev-base:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          command: [sh, -c, '$(_k8s_claude_seed_cmd /home/vscode/.claude) && $(_k8s_claude_shared_cmd)']
          securityContext: {runAsUser: 1000, runAsGroup: 1000}
          volumeMounts:
            - {name: home, mountPath: /seed, readOnly: true}
            - {name: claude-config, mountPath: /claude-config-own, subPath: ${session}}
            - {name: disk, mountPath: /shared-claude, subPath: ${K8S_DISK_SHARED}, readOnly: true}
            - {name: claude-state-seed, mountPath: ${K8S_CLAUDE_STATE_SEED_DIR}, readOnly: true}
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
            # One history per repo (K8S-18): this session's name in a conversation's lease, and
            # the user's shared Claude folder on the disk (a synced status line runs from it).
            - {name: AIDC_LEASE_MACHINE, value: "cluster/${session}"}
            - {name: AIDC_SHARED_CLAUDE, value: "/home/${AIDC_K8S_USER}/${K8S_DISK_SHARED}"}
$(_k8s_claude_token_env "$session")            # Sysbox gives the inner Docker a real /var/lib/docker, where overlay2 works.
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
            # Its own folder of the mirror only: the MCP reads its transcripts and hook events
            # there, and no session sees another's.
            - {name: transcripts, mountPath: ${K8S_TRANSCRIPT_OUT}, subPath: ${session}}
            # Its Claude config dir, its own folder of claude-config (the broker writes its
            # credentials there), with the user's one Claude history over its projects/.
            - {name: claude-config, mountPath: /home/vscode/.claude, subPath: ${session}}
            - {name: disk, mountPath: /home/vscode/.claude/projects, subPath: ${K8S_DISK_PROJECTS}}
            # The user's shared Claude files, which come from their machines, read-only over the
            # disk: no session writes what a Claude on the user's machines loads.
            - {name: disk, mountPath: "/home/${AIDC_K8S_USER}/${K8S_DISK_SHARED}", subPath: ${K8S_DISK_SHARED}, readOnly: true}
      volumes:
        - {name: disk, persistentVolumeClaim: {claimName: disk}}
        - {name: home, persistentVolumeClaim: {claimName: ${session}-home}}
        - {name: transcripts, persistentVolumeClaim: {claimName: ${K8S_TRANSCRIPTS_CLAIM}}}
        - {name: claude-config, persistentVolumeClaim: {claimName: ${K8S_CLAUDE_CONFIG_CLAIM}}}
        # Optional: a session made before the seed was there has no such key.
        - {name: claude-state-seed, configMap: {name: ${session}-audit-seed, optional: true, items: [{key: ${K8S_CLAUDE_STATE_SEED}, path: ${K8S_CLAUDE_STATE_SEED}}]}}
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
# The request holder's settings (gitctl/git-requests.sh): where the request folder is, the
# user's disk, and the user's git mode. Mounted read-only in both of the pod's containers: the
# holder reads its mode from here (sudo drops the environment), and nothing in the pod holds an
# API token, so nothing in it can change the mode.
apiVersion: v1
kind: ConfigMap
metadata: {name: git-settings, namespace: ${ns}, labels: {${labels}, app: git}}
data:
  settings: |
    requests=$(k8s_git_requests_path)
    disk=/home/${AIDC_K8S_USER}
    mode=${AIDC_K8S_GIT_MODE:-ask}
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
          command: [sh, -c, '[ -e /seed/.profile ] || cp -a /home/git/. /seed/; chown 2000:2000 /seed && chmod 0700 /seed && chown 2001:2001 /cred && chmod 0711 /cred && chown 2002:2002 /run-store && chmod 0700 /run-store && $(_k8s_mirror_dir_cmd "$K8S_GIT_SESSION" 2000) && $(_k8s_claude_dir_cmd "$K8S_GIT_SESSION" 2000 1000 0770)']
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL], add: [CHOWN, FOWNER, DAC_OVERRIDE]}
          volumeMounts: [{name: home, mountPath: /seed}, {name: cred, mountPath: /cred}, {name: run-store, mountPath: /run-store}, {name: transcripts, mountPath: /mirror}, {name: claude-config, mountPath: /claude-config}]
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
        # The agent's Claude config dir, its folder of claude-config (group 1000, of which the
        # git user is a member: the broker writes its credentials there), filled once from the
        # one its home had, its own history included.
        - name: claude-seed
          image: ${img}
          imagePullPolicy: Always
          command: [sh, -c, '$(_k8s_claude_seed_cmd /home/git/.claude own-projects)']
          securityContext:
            runAsUser: 2000
            runAsGroup: 2000
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: home, mountPath: /seed, readOnly: true}
            - {name: claude-config, mountPath: /claude-config-own, subPath: ${K8S_GIT_SESSION}}
      containers:
        - name: git
          image: ${img}
          imagePullPolicy: Always
          workingDir: /home/git
          env:
            - {name: HOME, value: /home/git}
            - {name: AIDC_USER, value: "${AIDC_K8S_USER}"}
            - {name: AIDC_GIT_REQUESTS, value: "$(k8s_git_requests_path)"}
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
            - {name: settings, mountPath: /etc/aidc/git-settings, readOnly: true}
            # The agent's own folder of the transcript mirror (gitctl-main.sh copies its
            # transcripts there, hook-event.sh writes its hook events), read by the MCP.
            - {name: transcripts, mountPath: ${K8S_TRANSCRIPT_OUT}, subPath: ${K8S_GIT_SESSION}}
            # Its Claude config dir (the account broker writes its credentials there).
            - {name: claude-config, mountPath: /home/git/.claude, subPath: ${K8S_GIT_SESSION}}
        # The request holder (gitreq): takes the sessions' requests, holds them in ask mode,
        # and alone runs the gitctl verbs that change GitHub, out of the agent's reach (owner
        # ruling 2026-11-26). A container of its own: kubectl exec cannot choose a user, so the
        # user's aidc git approve|deny|mode (and the MCP server carrying out an orchestrator's
        # answer) reach gitreq by exec into this container, which nothing in the agent's can.
        # The agent's container reaches it only through the sudo rule naming the reading verbs.
        - name: gitreq
          image: ${img}
          imagePullPolicy: Always
          command: [/opt/aidc/lib/gitctl/git-requests.sh, watch]
          workingDir: /var/lib/gitctl/gitreq
          env:
            - {name: HOME, value: /var/lib/gitctl/gitreq}
          securityContext:
            runAsUser: ${K8S_GIT_HOLDER_UID}
            runAsGroup: ${K8S_GIT_HOLDER_UID}
            runAsNonRoot: true
            privileged: false
            # sudo, to gitrun and gitcred for gitctl's verbs (gitctl/sudoers).
            allowPrivilegeEscalation: true
            capabilities: {drop: [ALL], add: [SETUID, SETGID, AUDIT_WRITE]}
          resources: {requests: {cpu: 50m, memory: 128Mi}}
          volumeMounts:
            - {name: disk, mountPath: "/home/${AIDC_K8S_USER}"}
            - {name: cred, mountPath: /var/lib/gitctl/gitcred}
            - {name: run-store, mountPath: /var/lib/gitctl/gitrun}
            - {name: repos, mountPath: /etc/aidc/git-repos, readOnly: true}
            - {name: settings, mountPath: /etc/aidc/git-settings, readOnly: true}
      volumes:
        - {name: disk, persistentVolumeClaim: {claimName: disk}}
        - {name: home, persistentVolumeClaim: {claimName: git-home}}
        - {name: cred, persistentVolumeClaim: {claimName: git-cred}}
        - {name: run-store, persistentVolumeClaim: {claimName: git-run}}
        - {name: transcripts, persistentVolumeClaim: {claimName: ${K8S_TRANSCRIPTS_CLAIM}}}
        - {name: claude-config, persistentVolumeClaim: {claimName: ${K8S_CLAUDE_CONFIG_CLAIM}}}
        - {name: repos, configMap: {name: git-repos, defaultMode: 292}}  # 0444
        - {name: settings, configMap: {name: git-settings, defaultMode: 292}}  # 0444
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
p="$1" top="$2" mode="$3" agent="$4" holder="${5:-}"
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
        # Given to the request holder. One the agent held, before requests moved out of its
        # reach, is given to the holder with what is in it (no symlink followed).
        if [ "$(stat -c %u .)" = "$agent" ]; then chown -R -h "$holder" .
        elif [ "$(stat -c %u .)" != "$holder" ]; then
            if [ -n "$(ls -A .)" ]; then echo "refused: $p holds files and does not belong to the git container: move it aside" >&2; exit 3; fi
            chown "$holder:1000" .
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
      command: [sh, -c, $(printf '%s' "$K8S_REPO_DIR_SCRIPT" | jq -Rs .), repo-dir, "${path}", "/home/${AIDC_K8S_USER}", "${mode}", "${K8S_GIT_AGENT_UID}", "${K8S_GIT_HOLDER_UID}"]
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

# --- The user's MCP server (K8S-07; MCP-02/03/05/06/13/14 as amended; TRS-23) -----------------
#
# The same server as Docker's aidc-mcp, from the same image, as one replica in the user's
# namespace, so one process holds the user's queues and watchers and replies keep arriving while
# the user's machines are off. It drives the user's sessions with the CLI baked into its image,
# under the aidc-mcp ServiceAccount `aidc user add` makes (K8S_MCP_RULES: the session lifecycle
# in this namespace only).
#
# - State: its store, watermarks and access log on a claim of its own (aidc-mcp-state, the
#   user's retained class); one process per store, so the Deployment is Recreate, never two.
# - Transcripts: the user's mirror claim, mounted whole and read-only (k8s_render_transcripts).
#   Its files are each session's (uid 1000, the git agent's 2000) and 0600, so the server runs
#   as root with only DAC_OVERRIDE, the one capability reading them takes: no other.
# - Token: a Secret (MCP-05), never in the image or a ConfigMap, beside the config in one
#   projected volume at /aidc-config, where the server reads its token on every request and
#   the orchestrator settings (a rotated Secret reaches the file; `token rotate` also restarts).
# - Config: a ConfigMap of the user's config as this server's CLI needs it (k8s_mcp_config).
# - Network (aidc-mcp NetworkPolicy, on top of the namespace's default-deny; MCP-10/11/12 as
#   amended, owner ruling Q-M1): it is always reachable in the cluster by its Service,
#   aidc-mcp.<namespace>.svc:7878, from every namespace but the user's own, so no session of the
#   user reaches it (another user's sessions reach no pod address: their egress is their own
#   proxy, which goes to public addresses only); on the VPN/LAN through an Ingress at
#   mcp-<user>.<domain> when mcp.kubernetes.expose is `ingress` (k8s_render_mcp_expose; aidc mcp
#   start refuses a name that resolves to a public address, which sessions' proxies reach); every
#   path behind its bearer token. It reaches the API server and the orchestrator's callback
#   host and port, and nothing else.
K8S_MCP_NAME=aidc-mcp
K8S_MCP_TOKEN_SECRET=aidc-mcp-token
K8S_MCP_CONFIG=aidc-mcp-config
K8S_MCP_STATE_CLAIM=aidc-mcp-state
K8S_MCP_PORT=7878
# The taint webhook (W-M4, K8S-13's one exception): each session's policy sidecar pokes it when
# the session is tainted; nothing else may reach this port, and nothing on it but the poke.
K8S_MCP_TAINT_PORT=7879
# Where the server keeps its state in its pod (its claim) and reads the mirror.
K8S_MCP_STATE_DIR=/var/lib/aidc-mcp

# k8s_mcp_config: the user's global config as the server's CLI reads it, on stdout: the backend
# is the cluster; kubernetes.user is set (the pod's own login name is root); the settings that
# name this machine's kubeconfig and context are left out (in the pod kubectl uses its
# ServiceAccount); ports: are left out (a tunnel ends on the machine that runs it, and the
# server may not open one). Returns 1, saying why, when the config cannot be read.
k8s_mcp_config() {
    local cfg
    cfg=$(_aidc_global_config_file)
    if [ -z "$cfg" ]; then
        printf '[aidc] error: no config to give the MCP server\n' >&2
        return 1
    fi
    AIDC_K8S_USER="$AIDC_K8S_USER" yq '.backend = "kubernetes"
        | .kubernetes.user = strenv(AIDC_K8S_USER)
        | del(.kubernetes.kubeconfig) | del(.kubernetes.context) | del(.ports)' "$cfg" \
        || { printf '[aidc] error: cannot read %s\n' "$cfg" >&2; return 1; }
}

# k8s_mcp_kubeconfig <ip>:<port> <namespace>: the kubeconfig kubectl uses in the server's pod:
# its ServiceAccount's token and CA, at that API server address, which the server's policy
# allows. Not the in-cluster default: the API Service balances over every control-plane node,
# and a policy judged after the Service's translation lets through only the addresses it names
# (half or more of the calls were refused on a three-node control plane); and kubectl drops the
# in-cluster default when any flag such as --request-timeout is given, then tries
# localhost:8080. The certificate is checked for the Service's name, which every API server's
# certificate carries, so the address need not be in it. One address, since a kubeconfig cluster
# has one server: aidc mcp start picks the first its policy allows that the pod itself reaches
# (mcp.sh, mcp_reachable_endpoint), and a start again moves it off a node that went down
# (docs/design-12-kubernetes.md, the MCP server's "API server reach").
K8S_MCP_KUBECONFIG=/aidc-config/kubeconfig
k8s_mcp_kubeconfig() {
    local sa=/var/run/secrets/kubernetes.io/serviceaccount
    cat <<EOF_MCP_KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster: {server: "https://${1}", certificate-authority: ${sa}/ca.crt, tls-server-name: kubernetes.default.svc}
users:
  - name: aidc-mcp
    user: {tokenFile: ${sa}/token}
contexts:
  - name: in-cluster
    context: {cluster: in-cluster, user: aidc-mcp, namespace: ${2}}
current-context: in-cluster
EOF_MCP_KUBECONFIG
}

# k8s_render_mcp_config <ip>:<port>: the server's config (k8s_mcp_config) and its pod's
# kubeconfig (k8s_mcp_kubeconfig, at that API server address) as its ConfigMap. Every value
# goes to yq as an environment string (strenv), never spliced into its program. Returns 1,
# saying why, when the config cannot be read.
k8s_render_mcp_config() {
    local cfg ns
    cfg=$(k8s_mcp_config) || return 1
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    AIDC_MCP_CFG="$cfg" AIDC_MCP_CM="$K8S_MCP_CONFIG" AIDC_MCP_NS="$ns" \
        AIDC_MCP_KC="$(k8s_mcp_kubeconfig "${1:?an API server address}" "$ns")" \
        AIDC_MCP_USER="$AIDC_K8S_USER" AIDC_MCP_APP="$K8S_MCP_NAME" yq -n '
        .apiVersion = "v1" | .kind = "ConfigMap"
        | .metadata.name = strenv(AIDC_MCP_CM) | .metadata.namespace = strenv(AIDC_MCP_NS)
        | .metadata.labels = {"app.kubernetes.io/managed-by": "aidc", "aidc/user": strenv(AIDC_MCP_USER), "app": strenv(AIDC_MCP_APP)}
        | .data."config.yaml" = strenv(AIDC_MCP_CFG)
        | .data.kubeconfig = strenv(AIDC_MCP_KC)'
}

# k8s_render_mcp_token <token>: the token's Secret. Applied from stdin (`kubectl create -f -`),
# so the token is never on a command line.
k8s_render_mcp_token() {
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${K8S_MCP_TOKEN_SECRET}
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_MCP_NAME}}
type: Opaque
stringData: {token: "${1}"}
EOF
}

# k8s_render_mcp_state: the server's state claim. Made when missing, never applied over (a
# changed size would be refused as a resize).
k8s_render_mcp_state() {
    cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${K8S_MCP_STATE_CLAIM}
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_MCP_NAME}}
spec:
  storageClassName: ${AIDC_K8S_STORAGE_CLASS}
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: ${AIDC_K8S_MCP_STATE_SIZE}}}
EOF
}

# k8s_render_mcp <node-selector-json> [<ip>:<port> ...]: the server's Service, its NetworkPolicy
# (who may connect; egress to the API server at those addresses only), the callback's policy
# when there is a callback, and its Deployment.
k8s_render_mcp() {
    local sel="$1" ns ep egress="" session_create="false"
    shift
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    for ep in "$@"; do
        egress="${egress}    - to: [{ipBlock: {cidr: ${ep%:*}/32}}]
      ports: [{protocol: TCP, port: ${ep##*:}}]
"
    done
    [ -n "$egress" ] || egress="    []
"
    # The orchestrator's callback (K8S_MCP_CALLBACK_IP/_PORT, resolved on the user's machine by
    # aidc mcp start; _HOST when the URL names it): its one address and port, in a policy of its
    # own (aidc-mcp-callback), so the API server's addresses are the aidc-mcp policy's alone; and
    # the name in the pod's hosts file, since the pod has no DNS.
    local aliases="[]" callback=""
    if [ -n "${K8S_MCP_CALLBACK_IP:-}" ]; then
        [ -z "${K8S_MCP_CALLBACK_HOST:-}" ] \
            || aliases="[{ip: \"${K8S_MCP_CALLBACK_IP}\", hostnames: [\"${K8S_MCP_CALLBACK_HOST}\"]}]"
        callback="---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${K8S_MCP_NAME}-callback, namespace: ${ns}, labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_MCP_NAME}}}
spec:
  podSelector: {matchLabels: {app: ${K8S_MCP_NAME}}}
  policyTypes: [Egress]
  egress:
    - to: [{ipBlock: {cidr: ${K8S_MCP_CALLBACK_IP}/32}}]
      ports: [{protocol: TCP, port: ${K8S_MCP_CALLBACK_PORT:?}}]
"
    fi
    [ -n "$egress" ] || egress="    []
"
    [ "${AIDC_MCP_SESSION_CREATE:-}" = true ] && session_create=true
    local labels="${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_MCP_NAME}"
    k8s_render_mcp_service
    cat <<EOF
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${K8S_MCP_NAME}, namespace: ${ns}, labels: {${labels}}}
spec:
  podSelector: {matchLabels: {app: ${K8S_MCP_NAME}}}
  policyTypes: [Ingress, Egress]
  ingress:
    # Every namespace but the user's own: an orchestrator in the cluster, the ingress controller.
    - from: [{namespaceSelector: {matchExpressions: [{key: kubernetes.io/metadata.name, operator: NotIn, values: [${ns}]}]}}]
      ports: [{protocol: TCP, port: ${K8S_MCP_PORT}}]
    # The user's sessions' proxy pods (their policy sidecars), to the taint webhook only.
    - from: [{podSelector: {matchLabels: {app: proxy}}}]
      ports: [{protocol: TCP, port: ${K8S_MCP_TAINT_PORT}}]
  egress:
${egress}${callback}---
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${K8S_MCP_NAME}, namespace: ${ns}, labels: {${labels}}}
spec:
  replicas: 1
  # One process per state store (a second server on it stops at start): never two at once.
  strategy: {type: Recreate}
  selector: {matchLabels: {app: ${K8S_MCP_NAME}}}
  template:
    metadata: {labels: {${labels}}}
    spec:
      serviceAccountName: ${K8S_MCP_SA}
      automountServiceAccountToken: true
      enableServiceLinks: false
      nodeSelector: ${sel}
      tolerations: ${AIDC_K8S_TOLERATIONS}
      securityContext: {seccompProfile: {type: RuntimeDefault}}
      hostAliases: ${aliases}
      containers:
        - name: mcp
          image: ${AIDC_K8S_REGISTRY_PULL}/aidc/mcp:${AIDC_VERSION_TAG}
          imagePullPolicy: Always
          # The CLI starts a session it creates here, at /home/<user> on the disk.
          workingDir: "/home/${AIDC_K8S_USER}"
          env:
            - {name: AIDC_MCP_BACKEND, value: kubernetes}
            - {name: AIDC_K8S_NAMESPACE, value: ${ns}}
            - {name: HOME, value: "/home/${AIDC_K8S_USER}"}
            - {name: AIDC_MCP_PORT, value: "${K8S_MCP_PORT}"}
            - {name: AIDC_MCP_TOKEN_FILE, value: /aidc-config/mcp-token}
            - {name: AIDC_MCP_AUDIT_LOG, value: ${K8S_MCP_STATE_DIR}/access.log}
            - {name: AIDC_MCP_WATCHER_STATE, value: ${K8S_MCP_STATE_DIR}/watcher-state}
            - {name: AIDC_MCP_TRANSCRIPTS, value: ${K8S_MCP_STATE_DIR}/transcripts}
            - {name: AIDC_MCP_SESSION_CREATE, value: "${session_create}"}
            - {name: AIDC_MCP_TAINT_PORT, value: "${K8S_MCP_TAINT_PORT}"}
            - {name: KUBECONFIG, value: ${K8S_MCP_KUBECONFIG}}
          ports:
            - {name: mcp, containerPort: ${K8S_MCP_PORT}, protocol: TCP}
            - {name: taint, containerPort: ${K8S_MCP_TAINT_PORT}, protocol: TCP}
          # From inside the pod: the policy lets in no connection from the node, which a
          # tcpSocket probe would be on some network plugins.
          readinessProbe:
            exec: {command: [python, -c, "import socket; socket.create_connection(('127.0.0.1', ${K8S_MCP_PORT}), 2)"]}
            periodSeconds: 10
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL], add: [DAC_OVERRIDE]}
          resources: {requests: {cpu: 100m, memory: 256Mi}}
          volumeMounts:
            - {name: config, mountPath: /aidc-config, readOnly: true}
            - {name: state, mountPath: ${K8S_MCP_STATE_DIR}}
            - {name: transcripts, mountPath: ${K8S_MCP_STATE_DIR}/transcripts, readOnly: true}
            - {name: home, mountPath: "/home/${AIDC_K8S_USER}"}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - name: config
          projected:
            sources:
              - secret: {name: ${K8S_MCP_TOKEN_SECRET}, items: [{key: token, path: mcp-token, mode: 256}]}  # 0400
              - configMap: {name: ${K8S_MCP_CONFIG}, items: [{key: config.yaml, path: config.yaml}, {key: kubeconfig, path: kubeconfig}]}
        - {name: state, persistentVolumeClaim: {claimName: ${K8S_MCP_STATE_CLAIM}}}
        - {name: transcripts, persistentVolumeClaim: {claimName: ${K8S_TRANSCRIPTS_CLAIM}}}
        - {name: home, emptyDir: {}}
        - {name: tmp, emptyDir: {}}
EOF
}

# k8s_render_mcp_service: the server's Service: the MCP port, and the taint webhook's. Its
# address is stable for the namespace's life: session create makes it when missing (each
# session's policy sidecar is given it then, since the proxy pod has no cluster DNS), and
# `aidc mcp stop` keeps it.
k8s_render_mcp_service() {
    cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${K8S_MCP_NAME}
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_MCP_NAME}}
spec:
  selector: {app: ${K8S_MCP_NAME}}
  ports:
    - {name: mcp, port: ${K8S_MCP_PORT}, targetPort: ${K8S_MCP_PORT}, protocol: TCP}
    - {name: taint, port: ${K8S_MCP_TAINT_PORT}, targetPort: ${K8S_MCP_TAINT_PORT}, protocol: TCP}
EOF
}

# k8s_mcp_service_ip <namespace>: the server's Service address, made when the Service is not
# there yet; prints it, or says why on stderr and returns 1.
k8s_mcp_service_ip() {
    local ip
    if ! ip=$(k8s_get "$1" service "$K8S_MCP_NAME" -o 'jsonpath={.spec.clusterIP}'); then
        printf '[aidc] error: cannot read your MCP server'"'"'s Service in %s: the cluster did not answer (%s)\n' "$1" "$ip" >&2
        return 1
    fi
    if [ -z "$ip" ]; then
        k8s_render_mcp_service | k8s_kubectl apply -f - >/dev/null \
            || { printf '[aidc] error: could not make your MCP server'"'"'s Service in %s\n' "$1" >&2; return 1; }
        ip=$(k8s_get "$1" service "$K8S_MCP_NAME" -o 'jsonpath={.spec.clusterIP}') || ip=""
    fi
    case "$ip" in
        ''|None) printf '[aidc] error: your MCP server'"'"'s Service in %s has no address\n' "$1" >&2; return 1 ;;
    esac
    printf '%s' "$ip"
}

# k8s_mcp_host: the server's name on the user's network (mcp-<user>.<domain>): one of the user's
# page names, which the admission policy lets them serve, on the pages' wildcard certificate; the
# session name `mcp` is reserved on Kubernetes so no page takes it.
k8s_mcp_host() { printf 'mcp-%s.%s' "$AIDC_K8S_USER" "$AIDC_K8S_INGRESS_DOMAIN"; }

# k8s_render_mcp_expose: the Ingress that serves the server on the user's network (VPN/LAN) at
# k8s_mcp_host, over TLS, on the pages' class and certificate (kubernetes.ingress); every path
# goes to the server, which asks for its bearer token on each.
k8s_render_mcp_expose() {
    local host tls ann=""
    host=$(k8s_mcp_host)
    if [ -n "$AIDC_K8S_INGRESS_TLS_SECRET" ]; then
        tls="[{hosts: [${host}], secretName: ${AIDC_K8S_INGRESS_TLS_SECRET}}]"
    elif [ -n "$AIDC_K8S_INGRESS_CLUSTER_ISSUER" ]; then
        tls="[{hosts: [${host}], secretName: ${K8S_MCP_NAME}-tls}]"
        ann="cert-manager.io/cluster-issuer: ${AIDC_K8S_INGRESS_CLUSTER_ISSUER}"
    else
        tls="[{hosts: [${host}]}]"
    fi
    cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${K8S_MCP_NAME}
  namespace: $(k8s_user_ns "$AIDC_K8S_USER")
  labels: {${K8S_MANAGED_BY}, aidc/user: ${AIDC_K8S_USER}, app: ${K8S_MCP_NAME}}
  annotations: {${ann}}
spec:
  ingressClassName: ${AIDC_K8S_INGRESS_CLASS}
  tls: ${tls}
  rules:
    - host: ${host}
      http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: ${K8S_MCP_NAME}, port: {number: ${K8S_MCP_PORT}}}}}
EOF
}
