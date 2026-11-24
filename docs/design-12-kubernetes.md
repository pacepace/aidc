# Design 12 — Running aidc Sessions on Kubernetes

**What this covers.** A second place for aidc sessions to run: a Kubernetes cluster (first target
a k3s cluster with a GPU node that runs Sysbox).
Measurements below come from the reference cluster aidc was developed against: k3s 1.35.5
with one amd64 agent node for sessions (Ubuntu 26.04, kernel 7.0, OpenZFS 2.4.1, containerd
2.2.3, Sysbox 0.7.2, an NVIDIA GPU). Nothing in aidc depends on that cluster: every
cluster-specific value is configuration (README, "Kubernetes backend"). It covers where code lives, how git leaves
the sandbox, how sessions get Docker and the GPU without privileged mode, how egress stays
fenced, how ports reach the user, and how Claude logins, account switching and conversation
history work across the cluster and the user's own machines.

**Requirements implemented:** K8S-01 … K8S-25 (new, `docs/requirements.md`). Carries over NET-01,
NET-02, NET-03, NET-09, NET-14, NET-15, MCP-12 and the git rules of GIT.

**Status:** being built. Built and checked on the reference cluster (`tests/smoke/k8s.sh`): the
backend seam, the in-cluster images, users' disks, and sessions (create, attach, list, status,
logs, kill) with the lockdown, Docker inside, the blocklist, taint and audit. Not built yet: the
git container, the in-cluster MCP server, account switching, Syncthing, ports. Owner rulings are
in `.prawduct/owner-rulings.md`; each open item says what will settle it, and items marked
**proposal** await the owner.

---

## Shape

```
cluster (the session node)
├─ namespace <prefix>-system                aidc's own: the image registry, builds
│   ├─ registry                             loopback host port for pulls; pushes from builders only
│   └─ builder (during `aidc k8s build`)    privileged, deleted after (see "Images")
└─ namespace <prefix>-u-<user>              one per user; default-deny NetworkPolicy
    ├─ PVC disk                             all the user's repos + worktrees (K8S-02)
    ├─ <session>-dev  (StatefulSet)         Claude, Docker, optional GPU; sysbox-runc
    ├─ <session>-proxy (Deployment)         squid, refresher, policy, audit: the only way out
    ├─ <session>-audit (PVC)                kept by `aidc kill`
    ├─ git container (later)                Claude Code + SSH key + gh (K8S-04..06)
    ├─ aidc-mcp (later)                     the user's MCP server (K8S-07)
    └─ syncthing (later)                    Claude state <-> user's machines (K8S-18)
```

Sessions live in their user's namespace, named `<session>-*`, not one namespace each: every
session mounts the user's one disk, and a pod can mount only claims of its own namespace.
Labels and per-session NetworkPolicies keep sessions apart, and `aidc kill` removes a session
by its label (decided while building; the plan records it).

The Docker backend stays. The same `aidc` commands, the MCP server and the orchestrator work
against either (K8S-01).

## Code: one disk per user, one worktree per session

Each user has one persistent volume holding every repo they work on, because projects need each
other (K8S-02). Users never share a volume. Each session works in its own git worktree of the
repo it was created for (K8S-03), so two sessions on one repo never share a working folder.

The user views and edits the same files with VS Code attached to a pod that mounts the volume,
the way aidc dev containers are used today (K8S-09).

## Git: a trusted git container per user

Sessions cannot push. One trusted git container per user holds the SSH key and `gh`, and is the
only thing that pushes, pulls or opens PRs (K8S-04). It runs Claude Code with the git rules:

- merge commits only; never force-push; no AI attribution in commits, PRs, code or docs;
- git mode per session, from **ask** (default, waits in the git container's terminal for the
  user) to **rules** (the agent decides by the rules); each user sets their own default (K8S-05);
- an orchestrator the user drives may approve through the user's MCP
  server; sandboxed sessions never reach that server (K8S-06);
- the first time it meets a repo it checks the GitHub protections (no force push, merge commits
  only) and offers to turn on any that are missing (K8S-23).

**Hard rules are enforced by code, not only instructions** (K8S-24). The git container's Claude reads
text written by sandboxed sessions (commit messages, diffs, requests), which can try to talk it
into breaking a rule. So: GitHub branch protection where available; a PreToolUse hook in a
read-only managed settings file; and wrapped `git` and `gh` binaries that refuse `--force`,
`--force-with-lease`, `+refspec`, squash/rebase merges and attribution trailers.

As built so far: `aidc git setup` runs it as a one-replica Deployment `git` in the user's
namespace, from the `aidc/gitctl` image (git, a pinned and checksum-checked `gh`, Claude Code,
openssh, tmux), built in the cluster with the others. It runs as uid 2000 (its own group 2000,
so the files that lock a repo are not group-writable by sessions; supplementary group 1000, the
sessions'), unprivileged with no capabilities, no service-account token, no service links. It
mounts the user's disk at `/home/<user>` and its own home claim `git-home` (on the retained
`storage_class`: it holds the user's secrets) at `/home/git`, seeded once from the image as a
session's home is. Its NetworkPolicy `git-egress` allows no ingress and egress to Quad9 DNS and
public addresses only, the proxy's rule, and it resolves through Quad9 only. The user adds
their own GitHub login and SSH key through `aidc git attach` (its tmux). Measured 2026-11-24 on
the reference cluster: GitHub reachable over HTTPS and SSH; the API service, every node's API
server, kubelet and ssh, the registry pod, cluster DNS and a listening pod in a namespace with
no policies all refused; the user's disk visible.

The hard rules as built: the agent and the user's terminal run as `git` (uid 2000) and run
ordinary git as themselves, with no credential, so nothing they run reaches GitHub (their git
still runs no repo hooks or fsmonitor and no `ext::` transport, from `/etc/gitconfig`). What
needs the login is `gitctl`, a set of fixed verbs and the only thing in the sudo rules:
`fetch`, `push <repo> <branch>`, `pr-create`, `pr-comment`, `pr-merge`, `pr-view`, `pr-list`,
`status`, `login`, `logout`. Each builds its own git or gh command line from arguments it
validates and passes no option the caller writes, so there is no flag spelling to get past.
git runs as `gitrun` (no secret; the token comes from the credential helper, for
`https://github.com` only) and gh as `gitcred`, the only user that can read the login, kept on
its own claim, `git-cred`. sudo drops the caller's environment, and called through sudo
directly a verb re-checks everything as that user and opens no file the caller names (texts
come on stdin, and so do bundles). gitrun never runs git in a repo anyone else can write
(owner ruling 2026-11-24, "One git design on both backends"): it keeps a private bare copy of
each GitHub repo in its own store (the `git-run` claim, 0700, gitrun's; gitctl refuses a
store anyone else can enter) and moves commits between that copy and the working copies as git
bundles. `fetch` and `clone`: gitrun fetches origin into its copy (pruning deleted branches,
then `gc --auto`) and writes a bundle to stdout; the agent imports it into the working copy as
itself, with `bundle unbundle` (no transport at all) and one ref transaction, its own git
pinned against hooks, fsmonitor and auto gc. `push`: the agent bundles the branch from the
working copy and hands it to gitrun on stdin; gitrun saves it in its own store (at most
2 GiB: the store is one fixed-size claim), verifies it
(its base must already be in the private copy), unbundles it there and takes only the branch's
commit, held under a ref named after that push's bundle so concurrent pushes never touch each
other's. Every git gitrun runs is given origin's URL by value, built from `<owner>/<name>`, with
proxies and other protocols pinned off and replace refs ignored. Bundles are temporary on both
sides: each is deleted when its verb ends, whatever the outcome, and one over an hour old (a
killed verb's) is swept at the start of the next verb.
`push` sends the one branch by the exact commit it checked, never forced, never tags, never to
`main`, `master` or `develop` (they change by PR merges); it asks origin what it has
(`ls-remote`) rather than trusting `refs/remotes/*`, reads each commit it would send whole, and
refuses one that carries AI attribution anywhere or whose author is an AI tool. `pr-create` and `pr-comment` refuse
attribution in their text; `pr-merge` always merges with a merge commit, after checking the
PR's title, body and commits. Claude Code's PreToolUse hook
(`/etc/claude-code/managed-settings.json`, root's, with `allowManagedHooksOnly`) is a courtesy
on top: it refuses switching user, reading the login's home, edits to the guard files, a gh
login in the agent's home, and attributed git commands. Measured 2026-11-24 in the git pod as
uid 2000, with a dummy token: `sudo -l` lists only gitctl; the token is unreadable by every route
tried; every verb refuses options and malformed arguments. The bypasses that remain are listed
in the build plan (`build-plan-k8s-git-container.md`, Chunk 02 decisions).

Repos as built: `aidc repo add <owner/name>` has a one-shot root pod (CHOWN, DAC_OVERRIDE,
FOWNER and FSETID only, symlinks on the way refused, never followed) make the repo folder and
give it to the agent while `gitctl clone` fills it from gitrun's bundle, then give the working
copy to the session user, group-shared (setgid, `core.sharedRepository=group`) so the agent,
in the session group, works in it too. It is an ordinary repo: no lock, sessions write all of
it. `aidc repo remove` deletes gitrun's private copy (`gitctl remove-copy`), and the working
copy only with `--delete-working-copy`: first the agent fetches and lists what the delete would
lose (`gitctl unpushed`: branches with commits on no origin branch, detached commits,
uncommitted changes, stashes, and every worktree), and any of it refuses the delete unless
`--even-unpushed` is given too; the root pod then empties the folder it checked from inside
and removes it by name with `rmdir`, so a folder swapped in at that name is never deleted.
`aidc repo list` strips control characters from the names and URLs it prints, which sessions
write. `aidc git status` reports the private copies' and
bundles' size and warns above `kubernetes.git_storage_warn` (default 1Gi).

Sessions make their own worktrees (owner ruling 2026-11-24): a session sees the whole disk and
runs `git worktree add -b <branch> <path>` itself in a working copy; `aidc create` takes no
`--repo` on this backend.

**Cleanup is the git container's job** (K8S-08). Merged branches and their worktrees are deleted.
Anything else left behind (unmerged, unpushed, orphaned worktrees) is flagged to the user at
once, not left to rot.

### Proposal: lock the parts of the repo that can run code

Superseded 2026-11-24 by the owner ruling "One git design on both backends: bundles, no repo
lock" (as built above: gitrun works only in its own private copies). Kept as the record of what
was measured; nothing in aidc locks a repo now.

A repo on the shared disk is written by sandboxed sessions. Git runs code from only two places
in a repo: its settings file (`.git/config`: hooks path, fsmonitor, ssh command, filters) and its
hooks folder. If a session could change either, the next trusted `git` command would run the
session's code next to the SSH key. So the repo is shared, but those parts are locked by file
permissions:

- the git container's user owns `.git/` itself, `.git/config`, `hooks/`, `info/` and
  `objects/info/`; sessions can read them and cannot change, replace or add to them;
- sessions (a different user, in a shared group) can write `objects/`, `refs/`, `reftable/` and
  their own worktree's admin folder, which is all a commit, branch, merge, rebase or stash needs;
- repos use git's reftable ref storage, so no ref change needs a lock file in the locked
  top-level folder, and `core.sharedRepository=group` keeps files group-writable both ways;
- the git container runs git only in the main repo, never in a session's worktree, and always
  with `-c core.hooksPath=/dev/null -c core.fsmonitor=false` as a backstop.

There is one copy of each repo and no fetch step: a session's commit is in the shared repo the
moment it is made, and so is anything the git container fetches from GitHub.

Measured 2026-11-24 on the reference cluster (git 2.49, git-container pod as uid 2000, Sysbox session pod
as uid 1000, one shared volume):

| As the session | Result |
|---|---|
| status, commit, branch, switch, merge, stash, rebase, tag | works |
| delete a branch or tag | works with reftable; warns that it cannot remove the branch's entry in the locked settings (harmless). With the older ref files storage, every ref delete fails |
| `git gc` | refused (the git container does it) |
| write `.git/config`, `git config …`, add a hook, replace `hooks/`, write `info/attributes`, `objects/info/alternates`, new files in `.git/` | refused |
| write its worktree's `config.worktree` | allowed, but git ignores it unless `extensions.worktreeConfig` is set in the locked settings, and the git container never runs in worktrees |
| move `main` or another branch | allowed: refs are data. GitHub branch protection and the git container's checks before a push cover it |

| As the git container | Result |
|---|---|
| log, push the session's branch, fetch, delete branches, `gc`, list worktrees | works; no planted code ran |

Setup needs: the session's worktree admin folder (`.git/worktrees/<name>/`) owned by the
session user (git's ownership check refuses otherwise) and group-setgid, so files the git
container rewrites during `gc` stay writable by the session.

Storage: the per-user volume is mounted by the git container and every session at once, and
sessions run with Kubernetes user namespaces (`hostUsers: false`, which Sysbox needs: a Sysbox pod
without it failed to start). Measured 2026-11-24 on the reference cluster:

| Volume | Several pods | Session's files on disk |
|---|---|---|
| local-path (a folder on the node's ZFS) | yes | correct (uid 1000 shows as 1000 everywhere) |
| OpenEBS ZFS LocalPV (default) | no: `device already mounted` | not reached |
| NFS from the node's ZFS | yes | wrong: written as a host uid derived from that pod's own ID range (e.g. 2211906536), and every other pod's files show as `nobody` |

NFS cannot carry Kubernetes' ID remapping, so a session's files would belong to a different
owner in every other pod, and after the session restarts. Sessions run only on the session node, so
the per-user volume is a dataset on the node's local ZFS, one per user, mounted as a local volume
(ruled 2026-11-24).

## Images: built in the cluster, kept in a private registry

aidc's images are built inside the cluster and kept in a registry in `<prefix>-system` (owner
ruling; REL-08 amended: never pushed to a public registry). `aidc k8s setup` makes the registry;
`aidc k8s build` builds every image from this aidc install's own files.

- **Pulls with no node configuration.** The registry listens on its node's loopback only
  (`hostPort` with `hostIP: 127.0.0.1`); session pods name images `localhost:<port>/aidc/...`,
  which containerd pulls over plain HTTP without any registry configuration. One replica on one
  node means only that node pulls, so sessions run there (the shared node selector).
- **Pushes from builders only.** A NetworkPolicy lets only builder pods of the system namespace
  reach the registry: a session that could push could replace the squid or policy image that
  enforces its own egress. Measured: the node pulls; a pod elsewhere is refused.
- **A privileged builder, during builds only** (owner ruling). The squid image's base (Canonical's
  ubuntu/squid Rock) owns its files as UID 584792, which no user namespace (0-65535) can hold, so
  a Sysbox builder cannot build it. The builder runs `dockerd` itself, on its unix socket only
  (the dind image's entrypoint adds an unauthenticated TCP listener whatever flags it gets: seen
  live), takes no inbound connections, and is deleted when the build ends. Its namespace is the
  only one aidc labels to allow privileged pods.
- **The pod network's MTU.** An overlay (VXLAN) carries smaller packets than Docker's default
  1500; inner Docker networks left at 1500 stall large transfers (a git clone reset after 150 s).
  The builder and every session's inner dockerd take the pod's MTU.
- **Always pulled.** `aidc k8s build --force` replaces an image under the same version tag, so
  session pods pull aidc's images every time (the registry is on the node; a pull is cheap).

## Sessions: Sysbox, Docker inside, GPU on request

Sessions do not run in VMs (Kata rejected: slow, trouble inside Kubernetes, cannot share the
GPU). Docker inside sessions is a core need (databases, NATS, testcontainers). Sessions run under
**Sysbox** (RuntimeClass `sysbox-runc`, `hostUsers: false`), which gives a real Docker daemon in
an unprivileged pod (K8S-10).

Measured 2026-11-23 on the reference cluster (Ubuntu 26.04, kernel 7.0, ZFS 2.4.1, k3s 1.35.5,
containerd 2.2.3, Sysbox 0.7.2), in an unprivileged Sysbox pod whose root maps to an
unprivileged host uid:

| Check | Result |
|---|---|
| `docker run hello-world` (Docker 29, overlayfs, cgroup v2) | pass |
| compose: postgres 17 + NATS 2.11 | healthy, `select 42` |
| testcontainers (Python, postgres) | pass |
| `nvidia-smi -L` | the node's GPU visible |

Node setup this needs (on the reference cluster, done by its operator's node scripts; aidc
documents it but does not change nodes):

1. `sysbox-ce` 0.7.2 package.
2. A `sysbox-runc` runtime in k3s's containerd template
   (`/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl`), then a k3s-agent restart.
3. AppArmor local rule letting `fusermount3` mount under `/var/lib/sysboxfs`.
4. A RuntimeClass `sysbox-runc` pinned to the session node(s).

The GPU is given only when asked for at create (`--gpu`, K8S-11). The cluster's NVIDIA device
plugin hands GPUs to pods through CDI, so it works under any runtime,
Sysbox included.

Rootless Docker and Podman were tried and dropped: they needed the AppArmor user-namespace
restriction lifted, a smaller ID range and a tun device plugin, and still did not run.

Sessions come with testament installed (K8S-25), so tests can run through that distributed
test runner.

Default size: 2 CPU and 8 GB guaranteed, may burst to 16 CPU and 32 GB; both settable at create
(K8S-19). Expected load is 4–8 sessions per user.

## Egress: the session's only way out is its own Squid

Same model as Docker (NET-01/02/03/14), rebuilt with NetworkPolicy (K8S-12, K8S-13):

- default-deny ingress and egress in the user's namespace, where the user's sessions live;
- dev pod egress: TCP 3128 to its own squid pod, nothing else; `dnsPolicy: None` so it cannot
  query cluster DNS; `automountServiceAccountToken: false`;
- squid egress: Quad9 for DNS, and public addresses only (`0.0.0.0/0` except `10/8`,
  `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10`, `127/8`), so it cannot reach the MCP
  server, the git container, other namespaces, the API server, nodes, the LAN or a VPN;
  squid also denies those destinations itself;
- the policy sidecar's taint webhook is the one allowed path to the user's MCP server;
- `--egress-tcp HOST:PORT` (NET-15) becomes a socat relay pod per host with a ClusterIP Service,
  a `hostAliases` entry in the dev pod, and an egress rule for exactly that `/32:port`.

As built, the lockdown carries three details the measurements above did not need:
- the proxy pod resolves through Quad9 only (`dnsPolicy: None`): the refresher's feed downloads
  resolve through resolv.conf, and with cluster DNS (blocked by its policy) every session ran
  with an empty malware blocklist until this was fixed;
- the dev pod's proxy settings carry the proxy Service's address, not the name `aidc-proxy`
  (which only the dev pod's own hosts file knows), so an inner container handed `$HTTPS_PROXY`
  can use it without DNS;
- under Sysbox, `/sys/class/net` inside the pod lists the NODE's interfaces, so the inner
  dockerd reads its MTU from the kernel (an ioctl in the pod's network namespace), not sysfs.

Unlike Docker, NetworkPolicy rules live in the node's network namespace, outside the pod, so a
process inside the pod cannot remove them. That only holds while the pod cannot reach the node,
which is why sessions run unprivileged under Sysbox.

Measured 2026-11-24 on the reference cluster (k3s 1.35.5, embedded kube-router policy controller): a
Sysbox session pod (`hostUsers: false`, `dnsPolicy: None`, no service-account token) and a
stand-in Squid pod, with the three policies above. kube-router rejects a denied TCP connection
(connection refused) rather than dropping it; a baseline run with the policies removed showed
every target below open.

| Target | From the session pod | From Squid |
|---|---|---|
| its Squid, TCP 3128 | open | — |
| internet (1.1.1.1:443) | refused | open (also :80; Quad9 :53 open) |
| Kubernetes API service | refused | refused |
| cluster DNS | refused, UDP unanswered | refused |
| own node: ssh, kubelet | refused | refused |
| another node: API server, ingress | refused | refused |
| the LAN router, a VPN router | refused | refused |
| pod in another namespace | refused | refused |
| storage-network NFS | timeout (the node's own NFS firewall, with or without policies) | timeout |
| DNS to Quad9 or the router, UDP | unanswered; name lookups fail | — |

`kubectl port-forward` to the session pod still works under default-deny ingress (HTTP 200), so
the tunnel needs no ingress rule.

Still to check when built: Squid's own deny of private destinations (defence in depth), and that
a root process inside a Sysbox session cannot change the node-side rules (the rules live in the
node's network namespace, which the pod does not share).

## Ports: tunnel by default, home network on request

- **Tunnel** (K8S-14): `aidc` runs `kubectl port-forward` to the session with the user's own
  cluster credentials and reconnects it if it drops. Works from anywhere the user reaches the
  cluster.
- **Home network** (K8S-15, optional at create): an Ingress with a stable name such as
  `<session>-<user>.<configured domain>`, removed at kill. No login by default; the user can add
  one at create when a page needs protecting (ruled 2026-11-24). Needs a wildcard certificate
  for the domain and DNS that points its names at the ingress; a phone reaches it over whatever
  network or VPN already reaches the cluster.

## Claude: logins, account switching, history

### Login once per user

Each user's Claude logins are set up once in their area; every session uses them (K8S-16).
Fallback if sharing breaks: each session logs in on its own. Users bring their own secrets
(SSH key, GitHub login, Claude accounts); the admin who runs `aidc user add <name>` never handles
them (K8S-20).

### Switching accounts mid-work

Accounts run out of usage quota during work, so a running session must switch account without
losing its conversation (K8S-17). Whether it switches on its own or waits for the user is a
setting, and each user sets the order accounts are used in.

The order is a cycle: after the last account, switching goes back to the first. Each account
has its own threshold, the weekly usage at which aidc switches away from it (ruled 2026-11-24),
for example:

```yaml
claude_accounts:            # in the order they are used
  - {name: work,     switch_at: 90}
  - {name: personal, switch_at: 70}
```

Signals: the statusline's weekly `rate_limits.seven_day` (proactive, against that account's
threshold), and the
`StopFailure` hook with `rate_limit` (reactive). There is no 5-hour window any more (owner,
2026-11-24).

**Mechanism: a per-user credential broker.** One process per user owns every account's login
(its refresh token) and writes the active account's credentials, with the refresh token left
out, into each session's `.credentials.json` by atomic rename. Claude re-reads the file, so the
next message uses the new account with no restart; sessions never refresh, so they never race
each other over a rotating refresh token. The broker renews each account's access token before
it expires and rewrites the sessions' files.

The broker writes into the session's Claude config **directory**, which the session pod mounts as
a whole directory (on the user's volume). Never a single-file mount, a `subPath`, or a Secret
volume: Claude replaces `.credentials.json` by rename, so a single-file mount goes stale on one
side and cannot be renamed over on the other. That is what made in-container logins expire and
account switches not stick in aidc's Docker backend before 1.5 (CTR-13, anthropics/claude-code#18443).
The measurement below renamed within the directory, as the broker will.

Measured 2026-11-24 (Claude Code 2.1.331, two Max accounts, one running interactive session):

| Step | Next message served by |
|---|---|
| start on account A | A (weekly 89 %) |
| replace the file with account B's (atomic rename) | B (weekly 43 %, different reset), same session id, conversation intact |
| replace with A's, refresh token removed | A; the session kept working and did not write the file back |
| same, `expiresAt` set in the past | A; Claude used the access token as is |

Not yet seen: what a session does when the access token really expires and the file has no
refresh token. The broker must replace it first; it is the broker's main job.

Fallback if the broker breaks: one config directory per account, and switching restarts Claude
with `--resume <session>` (seconds of downtime, cold prompt cache).

Jean-Claude (profiles `~/.claude-<name>`) was assessed: it shares settings, hooks, agents and
skills across profiles and syncs settings through git, but does no credential switching, and
conversations do not follow across profiles (confirmed by a user of it). We may reuse its layout; we do
not depend on it.

### One history per repo, on every machine

A repo's conversations and memory are one history across the cluster, Mac, Linux and WSL
(native Windows a bonus), synced with Syncthing (K8S-18).

Claude names a repo's history folder after the repo's real path, with every character outside
`[A-Za-z0-9]` turned into `-`, and it resolves symlinks in the working directory first. Folder
layout below the home directory is the same everywhere, so only the home prefix differs
(`/Users/<name>` on Mac, `/home/<name>` on Linux, WSL and the cluster).

Ruled 2026-11-24: sync history under the Linux name (`-home-<name>-…`). On a Mac, a small reconciler
creates an alias symlink `-Users-<name>-…` → `-home-<name>-…` inside `~/.claude/projects/`
(measured: Claude follows a symlink there, appends to the same transcript and finds memory);
Windows uses junctions. Aliases are excluded from sync.

What to sync (ruled 2026-11-24): `projects/` (transcripts, memory), `CLAUDE.md`, `rules/`,
`skills/`, `agents/`, `commands/`, `keybindings.json`, and the status bar (`statusLine` and its
script, laptop to cluster only; on the cluster aidc wraps it to read usage, and fixes its path). Never: `.credentials.json`, `.claude.json`, and live-process
state (`sessions/`, `shell-snapshots/`, caches). `settings.json` only as a template, laptop to
cluster, because it carries hooks that run code on the receiving machine. One machine at a time
resumes a given conversation; aidc holds a lease so two machines do not both append.

## Control plane

One aidc MCP server per user, in that user's namespace, so sessions run and replies arrive while
the laptop sleeps (K8S-07). The user drives sessions from any of their machines with the same
`aidc` commands; a session created from one machine can be attached from another (K8S-21).

Sessions come back on their own after a node reboot, with files, branches and conversation
intact, and Claude resumes where it left off (K8S-22).

### Backend seam

Built first, with no behaviour change (branch `refactor/backend-seam`):

- **MCP server:** `mcp/src/aidc_mcp/backend.py` is the one module that knows sessions run on
  Docker. Callers address a container as `backend.target(session, role)` (roles `dev`, `policy`,
  `audit`) and get commands from it: `exec_argv` (user, workdir, env, stdin), the inspect and list
  queries with the readers of their output, the reading of a missing container, and the
  session's instance id. They keep their own
  process handling (sync or async, timeouts, stdin). `mcp/tests/test_backend.py` fails if any
  other module starts `docker` or spells a container name. The Kubernetes backend answers the
  same functions with `kubectl` and namespace/pod names.
- **CLI:** the switch point is the dispatcher: `scripts/aidc` runs `scripts/cmd-<verb>.sh` for
  Docker and `scripts/k8s/session-<verb>.sh` for Kubernetes. `--backend docker|kubernetes`
  chooses; without it, `create` takes the config's top-level `backend:`, a verb that names a
  session asks the configured cluster first (`scripts/k8s/session-where.sh`, quiet when no
  cluster is configured) and goes to Docker otherwise, and `list` shows both. A verb the
  Kubernetes backend lacks says so. Wrapping each Docker
  call in a shell backend library was considered and not done: nearly every call is in a per-verb
  script whose Kubernetes form shares little with it (namespaces and NetworkPolicy instead of
  networks and sidecar containers), so the wrapper would have one implementation and guessed
  signatures. Shared helpers are extracted once the Kubernetes verbs show which are shared.
  `tests/unit/test-backend-confinement.sh` keeps Docker out of the dispatcher and the shared
  libraries, except for the named Docker helpers in `common.sh` and `config.sh`.

## Open items

| Item | Settles it |
|---|---|
| Session behaviour at real access-token expiry with no refresh token | live test (hours) |
| Syncthing in a pod | one per-user pod paired with a laptop |
| Alias symlinks: purge, retention, `/resume` picker, long hashed names | live test on a Mac |
