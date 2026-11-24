# Design 12 — Running aidc Sessions on Kubernetes

**What this covers.** A second place for aidc sessions to run: a Kubernetes cluster (first target
ranch-dev01, an agent node of the ranch k3s cluster). It covers where code lives, how git leaves
the sandbox, how sessions get Docker and the GPU without privileged mode, how egress stays
fenced, how ports reach the user, and how Claude logins, account switching and conversation
history work across the cluster and the user's own machines.

**Requirements implemented:** K8S-01 … K8S-24 (new, `docs/requirements.md`). Carries over NET-01,
NET-02, NET-03, NET-09, NET-14, NET-15, MCP-12 and the git rules of GIT.

**Status:** design. Owner rulings of 2026-11-23 are recorded in `.prawduct/owner-rulings.md`.
Sysbox, Docker-in-session and the GPU are measured on ranch-dev01 (below). Egress enforcement,
account switching and Syncthing are not yet measured; each open item says what will settle it.
Items marked **proposal** await the owner.

---

## Shape

```
cluster (ranch-dev01)
├─ namespace aidc-<user>                    one per user
│   ├─ aidc-mcp                             the user's MCP server (K8S-07)
│   ├─ git container                        Claude Code + SSH key + gh (K8S-03..06)
│   ├─ syncthing                            Claude state <-> user's machines (K8S-17)
│   └─ PVC code-<user>                      all the user's repos + worktrees (K8S-02)
└─ namespace aidc-<user>-<session>          one per session
    ├─ dev pod   (runtimeClass sysbox-runc) Claude, Docker, optional GPU
    ├─ squid pod (+ policy, refresher)      the only way out (K8S-12)
    └─ NetworkPolicy default-deny
```

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
- an orchestrator the user drives (for example metallm) may approve through the user's MCP
  server; sandboxed sessions never reach that server (K8S-06);
- the first time it meets a repo it checks the GitHub protections (no force push, merge commits
  only) and offers to turn on any that are missing (K8S-23).

**Hard rules are enforced by code, not only instructions** (K8S-24). The git container's Claude reads
text written by sandboxed sessions (commit messages, diffs, requests), which can try to talk it
into breaking a rule. So: GitHub branch protection where available; a PreToolUse hook in a
read-only managed settings file; and wrapped `git` and `gh` binaries that refuse `--force`,
`--force-with-lease`, `+refspec`, squash/rebase merges and attribution trailers.

**Cleanup is the git container's job** (K8S-08). Merged branches and their worktrees are deleted.
Anything else left behind (unmerged, unpushed, orphaned worktrees) is flagged to the user at
once, not left to rot.

### Proposal: lock the parts of the repo that can run code

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

Measured 2026-11-24 on ranch-dev01 (git 2.49, git-container pod as uid 2000, Sysbox session pod
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
without it failed to start). Measured 2026-11-24 on ranch-dev01:

| Volume | Several pods | Session's files on disk |
|---|---|---|
| local-path (a folder on the node's ZFS) | yes | correct (uid 1000 shows as 1000 everywhere) |
| OpenEBS ZFS LocalPV (default) | no: `device already mounted` | not reached |
| NFS from the node's ZFS (as the station songs share) | yes | wrong: written as a host uid derived from that pod's own ID range (e.g. 2211906536), and every other pod's files show as `nobody` |

NFS cannot carry Kubernetes' ID remapping, so a session's files would belong to a different
owner in every other pod, and after the session restarts. Sessions run only on ranch-dev01, so
the per-user volume is a dataset on the node's local ZFS, one per user, mounted as a local volume
(ruled 2026-11-24).

## Sessions: Sysbox, Docker inside, GPU on request

Sessions do not run in VMs (Kata rejected: slow, trouble inside Kubernetes, cannot share the
GPU). Docker inside sessions is a core need (databases, NATS, testcontainers). Sessions run under
**Sysbox** (RuntimeClass `sysbox-runc`, `hostUsers: false`), which gives a real Docker daemon in
an unprivileged pod (K8S-10).

Measured 2026-11-23 on ranch-dev01 (Ubuntu 26.04, kernel 7.0.0-43, ZFS 2.4.1, k3s 1.35.5,
containerd 2.2.3, Sysbox 0.7.2), in an unprivileged Sysbox pod whose root maps to an
unprivileged host uid:

| Check | Result |
|---|---|
| `docker run hello-world` (Docker 29, overlayfs, cgroup v2) | pass |
| compose: postgres 17 + NATS 2.11 | healthy, `select 42` |
| testcontainers (Python, postgres) | pass |
| `nvidia-smi -L` | RTX 3080 visible |

Node setup this needs (today done by hand on ranch-dev01, logged in
`/root/aidc-probe-backup/CHANGES.txt`):

1. `sysbox-ce` 0.7.2 package.
2. A `sysbox-runc` runtime in k3s's containerd template
   (`/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl`), then a k3s-agent restart.
3. AppArmor local rule letting `fusermount3` mount under `/var/lib/sysboxfs`.
4. RuntimeClass `sysbox-runc` pinned to ranch-dev01 with the dev toleration.

**Proposal:** move these into agent-cluster's node scripts so a rebuilt node gets them.

The GPU is given only when asked for at create (`--gpu`, K8S-11). The cluster's NVIDIA device
plugin hands GPUs to pods through CDI (the.ranch #246), so it works under any runtime,
Sysbox included.

Rootless Docker and Podman were tried and dropped: they needed the AppArmor user-namespace
restriction lifted, a smaller ID range and a tun device plugin, and still did not run.

Default size: 2 CPU and 8 GB guaranteed, may burst to 16 CPU and 32 GB; both settable at create
(K8S-19). Expected load is 4–8 sessions per user.

## Egress: the session's only way out is its own Squid

Same model as Docker (NET-01/02/03/14), rebuilt with NetworkPolicy (K8S-12, K8S-13):

- default-deny ingress and egress in each session namespace;
- dev pod egress: TCP 3128 to its own squid pod, nothing else; `dnsPolicy: None` so it cannot
  query cluster DNS; `automountServiceAccountToken: false`;
- squid egress: Quad9 for DNS, and public addresses only (`0.0.0.0/0` except `10/8`,
  `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10`, `127/8`), so it cannot reach the MCP
  server, the git container, other namespaces, the API server, nodes, the LAN or ZeroTier;
  squid also denies those destinations itself;
- the policy sidecar's taint webhook is the one allowed path to the user's MCP server;
- `--egress-tcp HOST:PORT` (NET-15) becomes a socat relay pod per host with a ClusterIP Service,
  a `hostAliases` entry in the dev pod, and an egress rule for exactly that `/32:port`.

Unlike Docker, NetworkPolicy rules live in the node's network namespace, outside the pod, so a
process inside the pod cannot remove them. That only holds while the pod cannot reach the node,
which is why sessions run unprivileged under Sysbox.

**Open (measure before building):** k3s's built-in policy controller is on, but no egress policy
has ever been used on this cluster. A test matrix in a scratch namespace (pod to 1.1.1.1, to the
API server, to kube-dns, to its own node, to another node, to a pod in another namespace; squid
3128 must work) settles it.

## Ports: tunnel by default, home network on request

- **Tunnel** (K8S-14): `aidc` runs `kubectl port-forward` to the session with the user's own
  cluster credentials and reconnects it if it drops. Works from anywhere the user reaches the
  cluster.
- **Home network** (K8S-15, optional at create): a Traefik Ingress with a stable name such as
  `<session>-<user>.dev.ranch.illuminati.org`, behind an auth middleware, removed at kill. The
  owner's phone is on ZeroTier and can reach it. **Proposal** needs: a `*.dev.ranch.illuminati.org`
  wildcard certificate (cert-manager, DNS-01, already wired) and one RouterOS DNS entry.

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

Signals: the statusline's `rate_limits` (proactive, e.g. 90 %), and the `StopFailure` hook with
`rate_limit` (reactive).

**Proposal**, two mechanisms, to choose by a live test:

- **A. Broker.** One process per user owns every account's refresh token and writes the active
  account's short-lived credentials into the session's `.credentials.json`. Claude re-reads the
  file on change, so the next message uses the new account, with no restart and no refresh races.
  Test first: does a running session pick up an overwritten credentials file, and does it accept
  one without a refresh token?
- **B. Restart.** One Claude config directory per account (the way Jean-Claude works); switching
  restarts Claude under the other directory with `--resume <session>`, which keeps the
  conversation because history lives in a shared folder (next section). Seconds of downtime, a
  cold prompt cache, but no unknowns.

Jean-Claude (profiles `~/.claude-<name>`) was assessed: it shares settings, hooks, agents and
skills across profiles and syncs settings through git, but does no credential switching, and
conversations do not follow across profiles (Brooks confirmed). We may reuse its layout; we do
not depend on it.

### One history per repo, on every machine

A repo's conversations and memory are one history across the cluster, Mac, Linux and WSL
(native Windows a bonus), synced with Syncthing (K8S-18).

Claude names a repo's history folder after the repo's real path, with every character outside
`[A-Za-z0-9]` turned into `-`, and it resolves symlinks in the working directory first. Folder
layout below the home directory is the same everywhere, so only the home prefix differs
(`/Users/<name>` on Mac, `/home/<name>` on Linux, WSL and the cluster).

**Proposal:** sync history under the Linux name (`-home-<name>-…`). On a Mac, a small reconciler
creates an alias symlink `-Users-<name>-…` → `-home-<name>-…` inside `~/.claude/projects/`
(measured: Claude follows a symlink there, appends to the same transcript and finds memory);
Windows uses junctions. Aliases are excluded from sync.

What to sync: `projects/` (transcripts, memory), `CLAUDE.md`, `rules/`, `skills/`, `agents/`,
`commands/`, `keybindings.json`. Never: `.credentials.json`, `.claude.json`, and live-process
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

About 18 CLI scripts call `docker` directly, and the MCP server shells `docker exec` from several
places (`session_facts.run_docker`, `headless._docker`, `tools.py`, `repo.py`,
`session_mcp.py`). The change introduces one seam on each side:

- CLI: `scripts/lib/backend_docker.sh` and `scripts/lib/backend_k8s.sh` with the same function
  names (create, exec, attach, kill, list, port, logs); the dispatcher picks one per session.
- MCP: a `Backend` interface (`exec`, `copy_in`, `status`, …) with Docker and Kubernetes
  implementations; every current `docker exec` call goes through it.

The Docker path is refactored behind the seam first, with no behaviour change, before any
Kubernetes code lands.

## Open items

| Item | Settles it |
|---|---|
| Egress policy enforcement on k3s | test matrix in a scratch namespace |
| Account switch: broker vs restart | live test of credentials-file swap in a running session |
| Syncthing in a pod | one per-user pod paired with a laptop |
| Alias symlinks: purge, retention, `/resume` picker, long hashed names | live test on a Mac |
| `kubectl port-forward` with default-deny ingress | live test |
| Sysbox node setup in agent-cluster scripts | owner proposal |
| LAN name, wildcard cert, DNS | owner proposal |
