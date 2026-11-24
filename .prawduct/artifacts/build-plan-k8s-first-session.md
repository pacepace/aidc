---
artifact: build-plan
version: 2
scope: k8s-first-session
branch: feature/k8s-first-session
base: develop
working-branches: []
last_validated: 2026-11-24
depends_on:
  - artifact: docs/design-12-kubernetes.md
  - artifact: .prawduct/artifacts/build-plan.md
governed_by:
  - artifact: project-preferences
    dispositions:
      - "bash CLI + Python MCP, uv, ruff/mypy/shellcheck → conforms"
      - "shell tests stub external tools on PATH (docker today, kubectl here) → conforms"
      - "anything that must survive a restart is a file or a cluster object, never memory → conforms"
partition: serial — each chunk needs the one before it on the live cluster (config → images → user area → session → attach), and they share the new scripts/k8s/ files
---

# Build Plan — a first Kubernetes session

**Work:** `k8s-first-session` (wave 2 of the Kubernetes backend program,
docs/design-12-kubernetes.md) · **Branch:** `feature/k8s-first-session` (off
`refactor/backend-seam`, wave 1) · **Started:** 2026-11-24

## Goals

**Response taken:** proceed, citing it. The owner said "go" (2026-11-24) to "a first Kubernetes
session on ranch-dev01 that you can create, attach to and kill"; rulings of 2026-11-23/24 in
`.prawduct/owner-rulings.md` fix the shape (Sysbox, per-user local ZFS disk, NetworkPolicy
egress, in-cluster registry, generic configuration).

**Product:** a user with a configured cluster runs `aidc create <name> --backend kubernetes
--repo <path>`, `aidc attach <name>`, `aidc list`, `aidc status <name>` and `aidc kill <name>`
and gets the same sandboxed session they get on Docker: Claude in tmux, Docker inside, egress only
through the session's own Squid with the blocklist and taint policy. Not in this wave: the git
container (sessions cannot push yet; that is what it is for), the in-cluster MCP server and the
MCP Kubernetes backend, account switching, Syncthing, port tunnels, `--egress-tcp`, `--gpu`, the
taint "freeze" response (this wave records and reports a taint; freezing a pod is designed
later), VS Code attach.

**Architecture:**
- **Generic, configured** (ruling 2026-11-24): nothing ranch-specific in aidc. A `kubernetes:`
  block in `~/.config/aidc/config.yaml` names the kubeconfig context, the namespace prefix, node
  selector and tolerations, the Sysbox runtime class, the per-user storage class, and the registry
  (push address inside the cluster, pull address the node uses). The ranch's values live in
  agent-cluster, with the cluster objects they need (storage class) in the.ranch.
- **Switch point:** the dispatcher (wave 1). `scripts/k8s/cmd-<verb>.sh` implements a verb for
  the Kubernetes backend; `scripts/aidc` runs it when the session is a Kubernetes one (create:
  `--backend kubernetes` or the config default; other verbs: the session is found in the cluster
  by its namespace label, so any of the user's machines can drive it, K8S-21).
- **Objects:** `aidc-system` namespace with the registry; one namespace per user
  (`<prefix>-u-<user>`) holding the user's disk (PVC, shared by every pod of the user on the
  node); one namespace per session (`<prefix>-<user>-<session>`) holding the proxy pod (squid,
  refresher, policy, audit containers), the dev StatefulSet (one replica, Sysbox, its own home
  volume, so it comes back after a node reboot, K8S-22) and the NetworkPolicies measured in
  design-12.
- **Paths:** the user's disk is mounted at `/home/<user>` in the session, and a repo lives at the
  same path below it as on the user's Linux machines, so its Claude history folder has the same
  name everywhere (ruling 2026-11-24, history folder names).
- **Images:** built in the cluster by a Sysbox builder pod from this aidc install's build
  contexts, pushed to the in-cluster registry, pulled by the node through a loopback-only host
  port (measured 2026-11-24: no node configuration needed). Tagged with the aidc version
  (REL-01).

**Constraints:** the Docker backend's behaviour does not change (its tests and smoke stay
green). No kubectl calls outside `scripts/k8s/` and the files the confinement test allows. The
14-day cooldown (REL-09) for any new image or tool version.

**Tradeoffs accepted:**
- Repos reach the user's disk by cloning inside a session (public https through Squid) until the
  git container exists. Revisit: the git container wave.
- Taint response is record-and-report only on Kubernetes. Revisit: before any untrusted
  workload runs there (a backlog item records it).
- The CLI talks to the cluster with the user's own kubeconfig (for the owner, the admin one);
  per-user RBAC comes with `aidc user add`'s second half. Inferred: acceptable for two trusted
  users (ruling 2026-11-23, users are trusted peers).

**Decisions made mid-build:**
- Chunk 01: the ranch's example config moves to chunk 03, where its storage class exists to name
  in it; one agent-cluster PR instead of two (Constraints: generic, ranch config outside aidc).
- Chunk 01: the Kubernetes backend requires `yq` (node selector and tolerations are structured;
  the awk fallback parser reads only flat keys). `aidc k8s check` says so when it is missing.

**Level:** Medium. Measured already: Sysbox Docker-in-pod, NetworkPolicy egress, port-forward,
shared ZFS dataset with correct file owners in Sysbox, registry push/pull. Not yet: the aidc dev
image's own entrypoint (dockerd start, tmux, Claude state install) under Sysbox without
privileged mode, and the proxy images' assumptions about Docker networking (aliases, the policy
sidecar's pause through the Docker socket). Chunk 04 starts by running them.

## Build Chunks

### Chunk 01: Kubernetes configuration and a cluster check

- **Description:** the `kubernetes:` config block and `aidc k8s check`, which says whether the
  configured cluster can run sessions.
- **Depends on:** none
- **Deliverables:** config keys read in `scripts/lib/config.sh`; new `scripts/k8s/` with a
  shared `lib.sh` (kubectl with the configured context, naming); `aidc k8s check`: kubectl
  present, context reachable, runtime class, storage class, a schedulable node, registry
  answering. README section; an example config for the ranch in agent-cluster.
- **Tests:** shell unit tests with a kubectl stub: config parsing (defaults, overrides, missing
  block), each check's pass and fail; the confinement test extended to kubectl.
- **Acceptance criteria:** `aidc k8s check` passes against the ranch with the agent-cluster
  config, and fails with a clear message for each missing piece.

### Chunk 02: Images in the cluster

- **Description:** `aidc k8s setup` creates the `aidc-system` namespace and the registry;
  `aidc k8s build` builds the dev and proxy images in the cluster and pushes them.
- **Depends on:** Chunk 01
- **Deliverables:** registry Deployment (pinned image, storage on the configured class, loopback
  host port for pulls, ClusterIP Service for pushes); builder pod (Sysbox) fed this install's
  build contexts as a tar stream; images tagged with the aidc version; `aidc k8s build` skips
  images already present for the version (like `ensure_image`).
- **Tests:** unit tests for the rendered manifests and the build sequence (kubectl stub);
  live: build all images on the ranch, then pull one on the node.
- **Acceptance criteria:** every image a session needs is in the registry for this version.
- **Critic mode:** chunk

### Chunk 03: The user's area

- **Description:** `aidc user add <name>` creates the user's namespace and disk.
- **Depends on:** Chunk 02
- **Deliverables:** namespace with owner labels; PVC on the configured storage class; for the
  ranch, the storage class (the.ranch) and the parent dataset (agent-cluster node step) as their
  own PRs.
- **Tests:** unit (manifests, idempotence); live: the PVC binds and two pods share it.
- **Acceptance criteria:** `aidc user add pace` on the ranch gives a usable disk.

### Chunk 04: Create and kill a session

- **Description:** `aidc create --backend kubernetes` and `aidc kill` for it.
- **Depends on:** Chunk 03
- **Deliverables:** session namespace, NetworkPolicies, proxy pod, Services, dev StatefulSet
  (Sysbox, `hostUsers: false`, no service-account token, `dnsPolicy: None` with Squid as the only
  way out); the dev image's entrypoint working under Sysbox; readiness wait; kill deletes the
  namespace and leaves the user's disk.
- **Tests:** unit (rendered manifests: every policy, the security settings, the labels);
  live: create on the ranch, Docker runs inside, an allowed and a blocked domain behave, kill.
- **Acceptance criteria:** a session is created and killed on the ranch with the plain commands.
- **Critic mode:** chunk

### Chunk 05: Attach, list, status, logs

- **Description:** the everyday verbs for a Kubernetes session, from any of the user's machines.
- **Depends on:** Chunk 04
- **Deliverables:** dispatcher routing by where the session lives; `attach` (tmux over
  `kubectl exec -it`), `list` (both backends), `status` (pods, taint, egress), `logs`.
- **Tests:** unit with docker and kubectl stubs for routing and output.
- **Acceptance criteria:** the owner attaches to a cluster session and works in Claude.

### Chunk 06: End to end and docs

- **Description:** a full run on the ranch and the documentation.
- **Depends on:** Chunk 05
- **Deliverables:** a Kubernetes smoke script (create, Docker inside, egress allowed and blocked,
  taint recorded, kill, user disk kept); README and design-12 updated to what was built; change
  record.
- **Tests:** the smoke script on the ranch; Docker smoke still green.
- **Acceptance criteria:** both smokes pass.
- **Type:** cumulative-final

## Verification Strategy

Each chunk is checked on the ranch as a user would use it, not only with stubs: run the command,
look at the cluster objects it made, and use the session. Scratch objects go in their own
namespaces and are deleted after; node changes, if any, go through agent-cluster.

## Governance Checkpoints

- After chunk 02: the build-and-pull path works; confirm before the session work rests on it.
- After chunk 04: a session exists end to end; review the security settings as a set.
- Chunk 06: cumulative review of the wave.
