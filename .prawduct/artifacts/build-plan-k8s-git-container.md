---
artifact: build-plan
version: 2
scope: k8s-git-container
branch: feature/k8s-git-container
base: develop
working-branches: []
last_validated: 2026-11-24
depends_on:
  - artifact: docs/design-12-kubernetes.md
  - artifact: .prawduct/artifacts/build-plan-k8s-first-session.md
governed_by:
  - artifact: project-preferences
    dispositions:
      - "bash CLI, shellcheck, shell tests stub kubectl on PATH → conforms"
      - "no private names in the repo → conforms (the owner's cluster values stay in their private repos)"
partition: serial, delegated — each chunk to one subagent (opus) in turn on this branch, briefed with the chunk and design-12 "Git"; the main agent reviews (Critic), integrates and runs the live checks; chunks share scripts/k8s/ and the git container image, so they do not run in parallel
---

# Build Plan — the trusted git container

**Work:** `k8s-git-container` (wave 3 of the Kubernetes backend, design-12 "Git") ·
**Branch:** `feature/k8s-git-container` (off `feature/k8s-first-session`) · **Started:** 2026-11-24

## Goals

**Response taken:** proceed, citing it. Owner rulings of 2026-11-23/24 fix the design (one trusted
git container per user, holding the SSH key and `gh`, the only thing that pushes or opens PRs;
git modes ask..rules, default ask; hard rules enforced in code; cleanup of merged branches and
worktrees, leftovers flagged; GitHub protections checked; the shared repo with its settings and
hooks locked, reftable; users bring their own secrets). The owner ordered the Kubernetes work
finished before aidc 2.0, and asked that it run in subagents.

**Product:** cluster sessions' work can leave the cluster. A user adds a repo once (the git
container clones it onto their disk), creates sessions on it (each in its own worktree on its
own branch), and pushes and opens PRs through the git container, which applies the rules: merge
commits only, never force-push, no AI attribution.

**Architecture:**
- One `git` Deployment per user in the user's namespace, running a git-container image built in
  the cluster like the others (`aidc/gitctl`: git, `gh`, Claude Code, the wrapped `git`/`gh`,
  tmux). Runs as its own user (uid 2000) in a group shared with sessions (gid 1000). Its own
  home claim holds its secrets (SSH key, `gh` login, Claude login); the user adds them by
  attaching (`aidc git attach`), never through the admin.
- It mounts the user's disk and owns each repo's `.git/` (settings, hooks, info locked; objects,
  refs, reftable group-writable), exactly as measured in design-12. It never runs git inside a
  session's worktree, and always with hooks and fsmonitor off.
- Egress: public addresses only and Quad9 DNS (NetworkPolicy, like the proxy pod); no ingress.
- Hard rules in code: wrapped `git` and `gh` refuse force pushes (`--force`,
  `--force-with-lease`, `+refspec`), non-merge PR merges, and attribution trailers or lines;
  Claude Code's PreToolUse hook in a read-only managed settings file enforces the same.
- Generic: nothing names the owner's cluster; GitHub is the forge for now.

**Constraints:** the session lockdown is unchanged (sessions still cannot push or reach the git
container). Docker backend unchanged. No private names in the repo. 14-day cooldown for any new
tool version (`gh` included).

**Tradeoffs accepted:** pushes and PRs are CLI-driven first (`aidc git push|pr <session>`, the
user's running the command is the approval in "ask" mode); the git container's own Claude
driving git by the rules, and orchestrator approval over MCP, come after (chunk 05). GitHub only.

**Decisions made mid-build:** (append here)
- (01) git user's primary group is its own (2000), 1000 supplementary: with `core.sharedRepository=group`, files the git container writes to lock a repo would otherwise be group-writable by sessions.
- (01) `git-home` is 1Gi on `storage_class`; a new one is seeded from the image's `/home/git` by a root init step holding only CHOWN, FOWNER, DAC_OVERRIDE (a new claim is root-owned), as session homes are seeded.
- (01) The git pod runs under the default runtime, not Sysbox: it runs no Docker, and its uid must be 2000 on the shared disk as in the measured lock.
- (01) `aidc rebuild` (Docker) skips `aidc/gitctl`: the image runs only in a cluster, so Docker users are not charged its build.
- (01) `gh` 2.103.3 (published 2026-10-26), sha256 for amd64 and arm64 from the release's checksums file, the amd64 one recomputed from the download.
- (01) `aidc git status` reports a stored `gh` login that `gh auth status` cannot confirm as unknown, not "not logged in" (GitHub may only have been unreachable).
- (01) `aidc git setup` refuses `kubernetes.user: git`: the user's disk would be mounted over the git user's home.
- (01) Live "cannot reach a session" checked against a listening stand-in pod in a policy-free scratch namespace (no session was running), a stricter test of the egress policy alone; the stand-in was reachable from its own namespace.
- (01, Critic) A Claude Code refresh does not reach an existing git-home: Claude is copied into the home claim once, when it is seeded. Assigned to Chunk 05.
- (02) GitHub access (was an open owner question): ruled 2026-11-24 in `.prawduct/owner-rulings.md` ("The git container logs in to GitHub once, as the user; the agent cannot reach the token"): one `gh` login over HTTPS, gh as git's credential helper; not SSH agent forwarding. Chunk 02 builds the isolation; the login command (`aidc git login`, identity from the user's GitHub account) is Chunk 04/05's.
- (02) Redesign after the Critic's Chunk 02 review: the first build ran the agent's own git and gh command lines as the login's users behind option checks, and git and gh accept too many spellings (unique prefixes like `--upload-pa=`, attached forms like `-Ftext=@file`, `=value` booleans, options after positionals) and too many program-running options on ordinary subcommands to fence. Now the agent runs plain git as itself with no credential, and the login is reached only through `gitctl`'s fixed verbs, which build their own command lines and pass on no caller option. The wrappers, the allowlists and the shadow exec path are deleted.
- (02) Three users, not the ruling's two: `git` (2000, the agent and the user's terminal, no credential); `gitrun` (2002, own group, supplementary 1000) runs git for `gitctl fetch|push` and holds no secret; `gitcred` (2001) runs gh and git's credential helper and alone can read the login. git is not run as gitcred so that even a mistake in git's handling of a repo cannot read the token file; gitrun gets the token only from the helper, for `https://github.com`.
- (02) sudo has two rules: the agent may run `gitctl` as gitrun or gitcred; gitrun may run the credential helper as gitcred. `env_reset`, `!use_pty`, visudo-checked at build. sudo is setuid, so the git container runs with `allowPrivilegeEscalation: true` and adds SETUID, SETGID and AUDIT_WRITE only. Called through sudo directly, a verb re-validates its arguments as the target user and opens no file the caller names: texts come on stdin.
- (02) A verb runs only in the main checkout of a repo whose `.git` and `.git/config` belong to the running user (gitrun) or root, are no symlinks, are writable by no group or other, and include no other file; and whose origin fetch and push URLs (after insteadOf) are all one `https://github.com/<owner>/<name>`. Chunk 03's repo lock must produce exactly that: the lock's owner is gitrun, not git.
- (02) `gitctl push` never forces (it refuses a branch that is not a fast-forward of origin's), never deletes, never pushes tags, and refuses `main`, `master` and `develop`: they change by `gitctl pr-merge`, which keeps "merge commits only" true for them (GitHub protection is the backstop). It decides what a push carries from `ls-remote`, never from `refs/remotes/*`, scans every commit it would send for attribution and for an AI-tool or bot author, and pushes the exact commit it scanned.
- (02) The attribution check is one function (`gitctl_attribution`), matching anywhere in the text, case-insensitively, used by every verb. The agent's local commits cannot be checked (its git is its own); the push scan is the enforcement, and the hook refuses attributed git commands as a courtesy.
- (02) `gitctl pr-merge` always runs `gh pr merge N --repo owner/name --merge`, after reading the PR and refusing it if its title, body or any commit carries attribution or an AI-tool author. `pr-create`/`pr-comment` read their text files as the agent and hand the text to gitcred on stdin.
- (02) `gitctl pr-*` take the repo's owner/name from its origin as read by the agent; a caller who goes to sudo directly can name any owner/name the token reaches, under the same rules.
- (02) Plain `gh` in the git container is a shim pointing to gitctl: a `gh auth login` run as the agent would keep a second login where the agent can read it. The real gh at its install path, run as the agent, has no login.
- (02) Live push is not tested in the pod: a verb refuses any origin that is not GitHub (a local-path origin is allowed only when gitctl runs from a checkout, in the unit tests, which push to a bare repo with real git), no GitHub login exists, and the agent cannot make a gitrun-owned repo until Chunk 03. The pod run covers the refusals and the token's isolation.
- (02) `aidc git status` asks `gitctl status` (yes, no, unknown); `aidc git setup`, attach and help name `gitctl login`.
- (02) Remains open: the agent's own git can move refs and write objects in a repo the session group may write, as a session can (GitHub sees only what `gitctl push` sends, after its checks). gh holds the token in memory while it runs; a process running as gitcred could read it, so nothing may run code as gitcred: gh runs only with argv gitctl built, in `/`, with no editor, pager or browser. A commit's diff is not scanned (attribution in code or docs is not caught at push). The attribution patterns are a list of names; a tool not on it gets through. A fine-grained token without admin scope, and GitHub branch protection (K8S-23), are the backstop for anything that reaches the API.
- (02) `aidc git status` still has an SSH-key row; with an HTTPS login it is for Chunk 04 to drop. `aidc git setup` after `aidc k8s build --force` does not roll the pod: the image tag is unchanged, so the Deployment applies unchanged (the live run needed `kubectl rollout restart`). Chunk 04 or 06 should make setup restart the pod when the image was rebuilt.
- (02) The login lives on a new claim `git-cred` (1Gi, retained class) mounted at `/var/lib/gitctl/gitcred`, gitcred's, 0711; gh's files in it are 0600. Not a subfolder of `git-home`: the agent owns that claim's root and could move a subfolder aside.
- (02) Identity seam: `/etc/gitconfig` includes `/var/lib/gitctl/gitcred/git-identity` (missing until the login step writes it, as gitcred); `commit.gpgSign` and `tag.gpgSign` false.
- (02) The managed settings set `allowManagedHooksOnly`: a repo's `.claude/settings.json`, written by sessions, would otherwise run its hooks in the git container.

**Level:** Medium. The repo lock is measured (design-12). Not yet: `gh` and SSH inside a pod
behind NetworkPolicy, Claude Code with a managed read-only hook in the git container.

## Build Chunks

### Chunk 01: The git container

- **Deliverables:** the git container image from `gitctl/Dockerfile` (in the inventory, built by `aidc k8s build`); rendered
  Deployment, home claim and NetworkPolicy in the user's namespace; `aidc git setup` (apply),
  `aidc git attach` (its tmux, to log in to GitHub and Claude), `aidc git status`; `aidc user add`
  offers it. Unit tests (kubectl stub); live: the pod runs, reaches GitHub, cannot reach the
  cluster or a session.

### Chunk 02: The hard rules in code

- **Deliverables:** the wrapped `git` and `gh` in the image (refuse force pushes, non-merge
  merges, attribution trailers and lines), and Claude Code's PreToolUse hook in a read-only
  managed settings file. Unit tests run the wrappers against fixture commands; live: a force push
  from the git container is refused.

### Chunk 03: Repos and session worktrees

- **Deliverables:** `aidc repo add <url> [--path P]` (the git container clones onto the user's
  disk with reftable, locks `.git/` as design-12 measured, sets the shared group);
  `aidc repo list`; `aidc create --backend kubernetes --repo` on an added repo gets its own
  worktree on its own branch, made by the git container with the admin folder owned by the
  session user. Live: the design-12 lock table rerun through these commands.

### Chunk 04: Push, PR and cleanup

- **Deliverables:** `aidc git push <session>` and `aidc git pr <session>` (through the wrappers,
  the PR merge-commit-only and attribution-free); `aidc git tidy` deletes merged branches and
  their worktrees and lists every leftover (unmerged, unpushed, orphaned) for the user; GitHub
  protections checked on first use of a repo and offered (`aidc git protect <repo>`, applied only
  with the user's yes). Live: push a session's branch, open a PR, tidy after a merge.

### Chunk 05: The git container's Claude, git modes and approval

- **Deliverables:** Claude Code in the git container with the git rules; per-session git mode
  (ask default, rules), the user's default; in ask mode Claude waits in its terminal. Orchestrator
  approval over MCP is left to aidc 2.0 (the per-user MCP server), recorded.

### Chunk 06: End to end and docs

- **Deliverables:** the Kubernetes smoke extended (add a repo, session on a worktree, push, PR on a
  scratch GitHub repo if one is configured, tidy); README and design-12 updated; change record.
- **Type:** cumulative-final
