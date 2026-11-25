---
schema: 1
type: feature
scope: k8s-user-creds
date: 2026-11-24
title: Per-user cluster credentials (aidc user add|creds|remove), Pod Security baseline
---
**Why:** K8S-14 and K8S-20 ask for the user's own cluster credentials; until now every cluster
command ran with the admin's kubeconfig (wave 2 tradeoff, plan-aidc-2.0 P25). Q-K6 (plan §5):
`aidc user add` mints namespace-scoped credentials; a user may still bring their own. The
per-user MCP server (W-M1/M2) needs the same model (Q-M2).

**What:**
- `aidc user add <name>` also labels the namespace Pod Security `baseline` (enforce, audit,
  warn), makes ServiceAccounts `aidc-user` and `aidc-mcp` with Roles in that namespace only,
  binds them to shared ClusterRoles (`<prefix>-user`: read runtime classes, storage classes,
  nodes, volumes, and patch volumes; `<prefix>-mcp`: read runtime classes), applies a
  ValidatingAdmissionPolicy that lets a user change only a volume claimed in their own
  namespace, only to Delete, and writes the user a kubeconfig (server and CA from the admin's
  context, a TokenRequest token, default 720h) at `~/.config/aidc/users/<name>.kubeconfig`,
  mode 0600. Options `--out`, `--duration`.
- `aidc user creds <name> [--out F] [--duration D] [--token] [--revoke]`: renew (admin or the
  user, in place), print only the token on request, revoke every earlier token. Refuses a path
  inside a git work tree that the repo does not ignore.
- `aidc user remove <name> [--yes]`: refuses while the user has sessions, asks for the name,
  sets the namespace's volumes to Delete, deletes the namespace, waits for the volumes, deletes
  the user's bindings and, with the last user, the shared objects.
- `aidc k8s check` reports what the credentials in use may and may not do (a
  SelfSubjectRulesReview against aidc's tables); without cluster-wide reads it notes what is
  skipped; the registry a user cannot see is a note.
- `tests/unit/test-k8s-rbac.sh` reads every kubectl call in `scripts/` and fails when the user's
  Role lacks a verb a call needs, grants one nothing uses (without a named reason), or the MCP's
  rules exceed the user's, or kubectl is called around `k8s_kubectl`.
- Checked live: a test user ran create, status, list, logs, attach, refresh, restart, upgrade,
  kill, git setup, repo add and remove, audit list and trim with only its kubeconfig; every
  attempt on another user's namespace and every cluster-wide write was refused (RBAC, or the
  admission policy for volumes); Pod Security admitted sessions and the git container and
  refused privileged, host and extra-capability pods; `aidc user remove` left nothing.

- After the merge with W-K2 (ports, pages, relays, `--network`, clean-env): the user's Role
  gains `pods/portforward` create (tunnels), Secrets create and delete only (a page's login is
  made with `kubectl create` and removed by name; no Secret is read), Ingresses (pages) and
  Traefik Middlewares create and delete (the login); the shared ClusterRole gains `get
  ingressclasses`. The MCP's Role gains only what its `aidc kill` needs to remove a page (list
  and delete Ingresses, delete Secrets and Middlewares by name). No cluster-wide Ingress or
  Service list. New admission policies `<prefix>-user-ingresses` (a user's Ingress serves only
  `<anything>-<user>` page names, no default backend, only aidc's annotations),
  `<prefix>-user-services` (ClusterIP only, no external IPs) and `<prefix>-user-secrets` (no
  ServiceAccount token Secrets); `aidc user add` refuses a user name ending in `-<another
  user>`. New `aidc user allow-network <user> [<namespace>] [--remove]` (admin): a RoleBinding in
  that namespace letting the user and their MCP list its Services, for `--network`, which now
  refuses an ungranted namespace before making anything. The rules test reads the new call
  shapes and fails if a grant decided against is made. Checked live with a test user.

## Consumer note

An existing user namespace has none of this until an admin runs `aidc user add <name>` again
(safe to repeat): that labels it baseline (pods already running that baseline refuses are
warned about, not stopped), adds the credentials and writes the kubeconfig. Users then set
`kubernetes.kubeconfig` to it. Needs Kubernetes 1.30+ for the volume policy; older clusters get
no volume patch, and an admin trims retained audit volumes.

After this update, an admin runs `aidc user add <name>` again for each existing user (it
applies the new Role, ClusterRoles and policies), and `aidc user allow-network <name>
<namespace>` for each namespace a user's sessions are given with `--network` or `networks:`.
