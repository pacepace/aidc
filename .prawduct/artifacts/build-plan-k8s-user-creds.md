---
artifact: build-plan
version: 1
scope: k8s-user-creds
branch: feature/k8s-user-creds
base: feature/k8s-git-container
working-branches: []
last_validated: 2026-11-25
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

After the merge with W-K2 (ports, pages, relays, names, `--network`, clean-env), chunk 05 below
brought the Roles, the rules test and the admission policies up to what aidc now does; checked
the same way (decisions (05)).

### Chunk 05: the Roles after W-K2
- Grants for tunnels, pages and logins, the ingress class read; `aidc user allow-network` for
  `--network`; admission policies for Ingresses, Services and Secrets; the rules test reads
  W-K2's call shapes.
- Done when: test-k8s-rbac.sh, test-k8s-user.sh, test-k8s-check.sh, test-k8s-net.sh and
  test-k8s-session.sh pass; live, a test user with only its kubeconfig runs create with
  `--port`, `--expose --login`, `--egress-tcp`, `--network`, `aidc egress add|rm`, clean-env, kill
  and audit trim, and isolation still holds.

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
- (05) Secrets: the user's Role grants `create` and `delete` only. A page's login (the one
  Secret aidc makes) is rendered apart from the pages (`k8s_render_expose_login`) and made with
  `kubectl create` (apply would need get and patch), after removing one a half-made create left,
  and removed by name (`--wait=false`: waiting reads the object); cert-manager certificates are
  removed by the names their Ingresses give; clean-env no longer lists Secrets and removes a
  stray login unasked. So no get or list of the namespace's Secrets is granted. Said plainly in
  design-12: a user who mounts a Secret into their own pod can still read their own
  namespace's, so this keeps Secrets out of `kubectl get`, not out of reach. The MCP gets
  `delete` only, so its `aidc kill` removes a page the user made; it makes no pages.
- (05) Cluster-wide Ingress list: not granted (it would show every user's page names). The page
  name clash check reads the user's own namespace and skips the cluster-wide read when refused
  (both paths unit-tested). It is still safe because the clash it guarded against between users
  is now impossible by construction: an admission policy (`<prefix>-user-ingresses`) holds every
  host of a user's Ingress (rules and TLS) to a first label ending in `-<user>`, no default
  backend, and only aidc's annotations; and `aidc user add` refuses a user name that ends in
  `-<another user>` (or that another ends in), since `a-bob`'s `x` and `bob`'s `x-a` would both
  be `x-a-bob`. Found while deciding this: without such a policy, the `ingresses create` the
  pages need would let any user publish any host under the domain (another user's page, an
  admin's site) or set ingress-nginx snippet annotations; the policy closes that.
- (05) `ingressclasses get` in the shared user ClusterRole: `--expose` reads the configured
  class's `spec.controller` when the config does not name the controller. The MCP makes no
  pages, so its ClusterRole does not get it.
- (05) `--network <namespace>`: no cluster-wide Service list (it would show every namespace's).
  Admin grant per namespace: `aidc user allow-network <user> <namespace> [--remove]` (list with
  no namespace) makes RoleBinding `<prefix>-u-<user>-network` in that namespace to the shared
  ClusterRole `<prefix>-network` (`list services`, nothing else; never bound cluster-wide), for
  the user and their MCP (a config `networks:` entry applies to MCP-made sessions too). It
  refuses aidc's and the system namespaces as `--network` does, and a namespace or user that
  does not exist. `aidc create --network` and `aidc network add` ask `auth can-i list services`
  first and refuse before anything is made, naming the command. `aidc user remove` deletes the
  user's grants; the last user's removal deletes the ClusterRole. Chosen over degrading (pods by
  address, no names) because the grant also makes widening the sandbox into another namespace
  an admin's decision, not only the user's.
- (05) `middlewares.traefik.io` `create` and `delete` in the user's Role (created with `kubectl
  create` with the login Secret, removed by name), `delete` in the MCP's. A rule for a kind the
  cluster lacks grants nothing. No admission rule on Middlewares: one only affects the routes
  that use it, and the Ingress policy lets a user's page use only a Middleware of their own
  namespace.
- (05) `pods/portforward` `create` for the tunnels. Live on a 1.35 API server with a 1.37
  kubectl, `create` alone was enough. The MCP gets none: a port-forward ends on the machine
  that runs it.
- (05) Services: the user and MCP could already create any Service type (since W-K5). An
  admission policy (`<prefix>-user-services`) now refuses anything but a ClusterIP and any
  external IP (NodePort and LoadBalancer reach past the namespace's policies; external IPs can
  take other traffic, CVE-2020-8554). Every Service aidc makes is a ClusterIP. Also
  `<prefix>-user-secrets`: no ServiceAccount token Secrets (a token that never expires). One
  policy per kind, since one policy over three kinds fails type checking for the other kinds'
  fields.
- (05) Without ValidatingAdmissionPolicy, `aidc user add` grants no page making (no Ingress,
  login Secret or Middleware create or patch; deleting them stays so kill and clean-env work)
  and says so; `aidc k8s check` and `aidc user creds --revoke` use the same table
  (`k8s_user_rules`). The rules test checks the MCP stays within the user's rules on such a
  cluster too.
- (05) The rules test reads W-K2's shapes: kinds of `apply` and `create -f -` pipelines by
  rendering `k8s_render_relay`, `k8s_render_network`, `k8s_render_expose` and
  `k8s_render_expose_login` (both controllers' forms; whole-name matching, so
  `k8s_render_expose` is not taken for `k8s_render_expose_login`), `port-forward`, `k8s_get` and
  `k8s_read` as the `get` they make, multi-resource `type/name` deletes, the one call into
  another namespace (held to `K8S_NETWORK_RULES`, which must have no unused rule), and grants
  decided against (cluster-wide Ingress and Service list, reading Secrets) fail if made.
- (05) Live on the reference cluster (2026-11-25), a test user with only the kubeconfig `aidc
  user add` wrote: `aidc create` with `--port`, `--expose --login` (controller read from the
  IngressClass), `--egress-tcp` to a scratch listener and `--network` to a scratch namespace
  granted with `aidc user allow-network` all worked (tunnel answered on localhost; the page 401
  without or with a wrong password, 200 with the printed one; the relay and the namespace's
  Service by name answered from the dev pod); `--network` to an ungranted namespace was refused
  before anything was made; `aidc egress add|rm`, `aidc network rm|add|ls`, status, kill (pages,
  login Secret and Middleware gone), clean-env (labelled leftovers and a stray login), audit
  list and trim worked. Isolation: can-i and real attempts on another user's namespace, a
  cluster-wide Ingress, Secret or Service list, the user's own Secrets list or get, another
  namespace's Services without a grant, RoleBindings, the namespace itself: all refused.
  Admission (server dry runs as the user): another user's or a site's page name, a default
  backend, a snippet annotation, another namespace's Middleware or auth Secret, a LoadBalancer
  or NodePort Service, external IPs and a ServiceAccount token Secret refused; the user's own
  page name and Middleware, a ClusterIP Service and an Opaque Secret admitted. The test user,
  its grant and the scratch namespaces were removed; the shared ClusterRoles and policies stay
  (the owner's namespace is a user namespace and will use them).
