---
artifact: build-plan
version: 1
scope: k8s-user-creds
branch: feature/k8s-user-creds
base: feature/k8s-git-container
working-branches: []
last_validated: 2026-11-24
depends_on:
  - artifact: docs/design-12-kubernetes.md
  - artifact: .prawduct/artifacts/plan-aidc-2.0.md
  - artifact: .prawduct/artifacts/build-plan-k8s-git-container.md
governed_by:
  - artifact: project-preferences
    dispositions:
      - "bash CLI, shellcheck, shell tests stub kubectl on PATH → conforms"
      - "no private names in the repo → conforms (the owner's cluster values stay in their private repos)"
partition: serial, one subagent (this wave, W-K5 of plan-aidc-2.0); the main agent runs the Critic
---

# Build Plan — per-user cluster credentials (W-K5)

**Work:** `k8s-user-creds` (plan-aidc-2.0 W-K5, Q-K6 and Q-M2 as decided in its §5) ·
**Branch:** `feature/k8s-user-creds` (off `feature/k8s-git-container`) · **Started:** 2026-11-24

## Goals

**Response taken:** proceed, citing Q-K6 (§5, main agent's call; the owner may overrule):
`aidc user add` mints namespace-scoped credentials (Role/RoleBinding + a kubeconfig handed to
the user); a user may still bring their own kubeconfig. Owner ruling 2026-11-24: everything
ships in 2.0, nothing deferred.

**Product:** an admin adds a user once and hands them one file. With only that file the user
runs every aidc command they need (sessions, git container, repos, audit) in their own
namespace, and can do nothing in another user's namespace and no cluster-wide write beyond
setting their own volumes' reclaim policy to Delete (audit trim). Users and their MCP server
(W-M2, not built here) get the same model; removing a user leaves nothing behind.

**Architecture:**
- Per user, in `<prefix>-u-<user>` (applied by `aidc user add`, admin):
  - Pod Security labels `enforce|audit|warn: baseline` (version latest).
  - ServiceAccount `aidc-user` + Role `aidc-user` + RoleBinding `aidc-user`: the user's identity.
  - ServiceAccount `aidc-mcp` + Role `aidc-mcp` + RoleBinding `aidc-mcp`: the per-user MCP
    (W-M2), the session lifecycle only.
  - ClusterRoleBindings `<prefix>-u-<user>` (to ClusterRole `<prefix>-user`) and
    `<prefix>-u-<user>-mcp` (to ClusterRole `<prefix>-mcp`).
- Shared, cluster-scoped (applied by every `aidc user add`, deleted with the last user):
  ClusterRole `<prefix>-user` (read runtime classes, storage classes, nodes, volumes; patch
  volumes), ClusterRole `<prefix>-mcp` (read runtime classes), and a ValidatingAdmissionPolicy
  `<prefix>-user-volumes` + binding that refuses any volume change by a `<prefix>-u-*:aidc-user`
  ServiceAccount unless the volume is claimed in that user's own namespace, the change sets
  `Delete`, and the claim reference is unchanged.
- One table, `K8S_USER_RULES` in `scripts/k8s/manifests.sh`, is the source of the Role,
  the check's report and the unit test's mapping.
- The token is a TokenRequest for `aidc-user` (`kubectl create token`), lifetime
  `kubernetes.user_token_ttl` (default 720h). The kubeconfig names the cluster's server and CA
  from the admin's current context; written mode 0600 to `~/.config/aidc/users/<user>.kubeconfig`
  (or `--out`), never inside a git work tree, never printed.

**Constraints:** session lockdown unchanged; Docker backend unchanged; no Secrets (the token
lives only in the kubeconfig); no private names in the repo.

**Tradeoffs accepted:**
- A user may renew their own token (`create serviceaccounts/token`, resourceNames `aidc-user`):
  a stolen kubeconfig can be renewed until the ServiceAccount is replaced
  (`aidc user creds <name> --revoke`). Chosen so users are not locked out every 30 days.
- The volume patch is a cluster-wide RBAC grant made narrow by an admission policy, not by RBAC
  (RBAC cannot name a volume by its claim's namespace). Needs ValidatingAdmissionPolicy (GA in
  Kubernetes 1.30); on an older cluster `aidc user add` grants no patch and `aidc audit trim`
  says the volume is left for an admin.
- `aidc k8s check` run with user credentials cannot read the registry in `<prefix>-system`
  (an admin's); it says so as a note, not as missing.

## Chunks

### Chunk 01: RBAC and Pod Security in `aidc user add`
- `K8S_USER_RULES` / `K8S_MCP_RULES` tables; renderers for Role, RoleBinding, ServiceAccount,
  ClusterRoles, ClusterRoleBindings, the admission policy; namespace labels.
- Done when: `test-k8s-user.sh` checks the rendered objects; `test-k8s-rbac.sh` greps every
  kubectl call in `scripts/` and fails on a (resource, verb) the Role does not grant.

### Chunk 02: `aidc user creds` (kubeconfig, token), `aidc user remove`
- creds: write/refresh the kubeconfig (0600, refuses a path in a git work tree), `--token`
  prints only the token, `--duration`, `--revoke`.
- remove: confirmation (type the name, or `--yes`), refuses while sessions run, sets every
  volume claimed in the namespace to Delete, deletes the namespace, waits for the volumes,
  deletes the user's ClusterRoleBindings and, with the last user, the shared objects.
- Done when: unit tests for mode, no token on stdout, refusals, order of removal.

### Chunk 03: `aidc k8s check` reports what the credentials can and cannot do
- A SelfSubjectRulesReview compared with the tables; namespace and cluster lines; degrade notes.
- Done when: unit tests for full, user-scoped and missing rights.

### Chunk 04: live on the reference cluster, docs
- Test user: full session lifecycle with only its kubeconfig; can-i and real attempts against
  another user's namespace and cluster-wide writes; Pod Security admits sessions and the git
  pod; then `aidc user remove`. README, design-12, K8S-20, change record.

## Status

All four chunks built and checked (unit suites green; live on the reference cluster with a
test user, removed afterwards). The Critic has not run (the main agent runs it).

## Decisions made mid-build
- (01) Pod Security `baseline` is the narrowest standard level that admits what aidc runs in a
  user namespace; `restricted` refuses the root init steps, Sysbox session pods and the git
  container (which allows privilege escalation for its user switch). No exemption needed.
  Checked live (server dry runs and real pods), recorded in design-12 "Users and credentials".
- (01) Volumes: RBAC cannot scope a cluster-scoped volume to a namespace, so the user's
  ClusterRole grants `patch` and a ValidatingAdmissionPolicy narrows it (own namespace's
  claim, only to Delete, claim unchanged; DELETE refused). Chosen over "degrade" because
  `aidc audit trim` must leave no data behind for a user, not only for an admin. Without
  ValidatingAdmissionPolicy (before 1.30) no patch is granted and trim says an admin must.
- (01) `events` get/list/watch granted with no aidc call: aidc's errors point users at
  `kubectl describe`. `pods/exec` gets both `create` and `get` (the websocket GET is authorized
  either way depending on the API server version).
- (01) The MCP's Role gains `deployments` (Q-M2 listed StatefulSets; the proxy is a Deployment)
  and pods get/list/watch/delete (restart), but no pod create, no repo list update, no tokens,
  no volume access. A test fails if it exceeds the user's.
- (02) A user may renew their own kubeconfig (`create serviceaccounts/token`, resourceNames
  `aidc-user`); `--revoke` (admin) replaces the ServiceAccount. The kubeconfig path check
  allows a path the enclosing repo ignores (the unit tests' scratch lives in this repo,
  ignored); anything else in a work tree is refused.
- (02) `aidc user remove` deletes the shared ClusterRoles and policy only when no namespace
  labelled `aidc/role=user` is left (a user namespace made before this change counts: its user
  will need them).
- (03) `aidc k8s check` sends its SelfSubjectRulesReview with `--validate=false`: kubectl's
  client-side validation lists CRDs first, which a user may not (found live).
- (03) `aidc k8s check` with user credentials: the registry in the system namespace and nodes
  (when not readable) are notes, not missing.
- (04) Live: the shared ClusterRoles and admission policy were made by the test (none existed
  before) and stayed after `aidc user remove k5probe` because the owner's namespace is a user
  namespace; they were deleted by hand to leave the cluster as it was. The owner's namespace
  has no credentials or Pod Security labels until the owner runs `aidc user add <name>` again
  (a server dry run showed its running git pod passes baseline).
