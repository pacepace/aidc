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

## Decisions made mid-build
(append here)
