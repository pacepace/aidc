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
- (02) A gitrun verb enters the repo's `.git` once (`cd -P`), checks it from inside, and runs every git with `GIT_DIR=.`: what was checked is what git uses, so swapping `.git` or any folder above it afterwards changes nothing. From inside it requires `.`, `config`, `hooks`, `info` and `objects/info` to belong to gitrun or root, be no symlinks and be writable by no group or other, and the config to hold only allowed keys (core basics, extensions, origin's url/pushurl/fetch, branch remote/merge, user identity): no includes, `url.*`, `http.*`, `remote.*.uploadpack`, `credential.*`, `protocol.*`, program-running keys or other remotes. git is given origin's URL by value (never the remote's name) after checking it is one `https://github.com/<owner>/<name>`, with proxies, ssh, askpass and protocols other than https pinned off and the helper reset on the command line, and with replace refs off (`GIT_NO_REPLACE_OBJECTS=1`). So Chunk 03's lock needs exactly that of `.git` and those entries; the repo folder and the path down to it need not be locked against uid 1000 or 2000, because gitctl never looks a path up twice (a swapped-in `.git` that is not gitrun's is refused, and one that is gitrun's is another locked repo with its own origin).
- (02) `gitctl push` never forces (it refuses a branch that is not a fast-forward of origin's), never deletes, never pushes tags, and refuses `main`, `master` and `develop`: they change by `gitctl pr-merge`, which keeps "merge commits only" true for them (GitHub protection is the backstop). It decides what a push carries from `ls-remote`, never from `refs/remotes/*`, reads every commit it would send whole and on its own (`rev-list`, then `cat-file commit`: headers and message, so no separator bytes in a message can split the scan) for attribution and for an AI-tool or bot author, and pushes the exact commit it scanned.
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
- (03) Supersedes the (02) lock decisions (`gitctl_enter_repo`'s ownership and mode checks, the config allowlist, `GIT_DIR=.` in the user's repo, the lock Chunk 03 was to build): owner ruling 2026-11-24 "One git design on both backends: bundles, no repo lock". gitrun never runs git in a repo anyone else can write; `gitctl_enter_repo` and `gitctl_repo_key_ok` are deleted. A lock (clone verb, `gitctl check`, sticky `objects/` and `worktrees/`, commit-graph/bitmap/midx pins) was built and measured first, then dropped uncommitted when the ruling came; its live table stays in design-12 as history.
- (03) gitrun's private bare copies live on a new claim `git-run` (`kubernetes.git_store_size`, default 10Gi, on the session class: a cache of GitHub, refetchable) at `/var/lib/gitctl/gitrun`, gitrun's, 0700, chowned by the seed step; gitctl refuses a store anyone else can enter. One copy per `<owner>/<name>` (lowercased), made on first use with `init --bare --template=`; every gitrun verb first fetches origin's branches into it (`+refs/heads/*:refs/heads/*`, `--prune`, no tags), sets its HEAD from `ls-remote --symref`, then `gc --auto`. Not a subfolder of git-cred or git-home: those belong to other users.
- (03) Bundles cross users only as streams: gitrun's `fetch` writes one to stdout; `push` reads one on stdin, saves it in its own store (mktemp, 0600), `bundle verify` (base must be in the private copy), `bundle unbundle`, takes only `refs/heads/<branch>`. gitrun never opens a path the caller names, so no bundle path can be swapped. The agent side never fetches by transport: it imports with `bundle unbundle` and one `update-ref --stdin` transaction (origin's branches to `refs/remotes/origin/*`, pruning the rest), its git pinned against hooks, fsmonitor, auto gc and every protocol. The push bundle is `<branch> --not --remotes=origin` (falling back to the tip's parents, then the whole branch, when that is empty).
- (03) Bundles are temporary: each is deleted when its verb ends, success or failure (trap; gitrun's in a global so the EXIT trap still sees it), and any over 60 minutes old is swept at the start of the next verb (agent's `~/.cache/gitctl/*.bundle`, gitrun's `incoming.*`). Tested both ways, with a mutation.
- (03) Dropped with the lock, with reasons: the commit-graph, bitmap and multi-pack-index pins (only gitrun writes the private copy), the `gc.auto=0` pin (gitctl now runs `gc --auto` there), the pushurl check (gitrun pushes to the URL built from owner/name, never a remote's config), gitrun's membership of group 1000 (it never touches the user's disk). Kept: fixed verbs, no caller options, texts and bundles on stdin, the attribution scan, protected branches, the ls-remote fast-forward check, never tags, `env -i`, URL by value, `GIT_NO_REPLACE_OBJECTS`. Tests deleted on purpose: the config-allowlist loop, the `.git` swap and its mutation, the lock/check/sticky/pin sections and their mutations, the replace-refs mutation (a bundle carries only its one ref, so the private copy has no replace refs to follow); added: hostile working-copy config (hooks, fsmonitor, uploadpack, receivepack, sshCommand, gc.auto) never runs, bundle cleanup and sweep, gitrun refusing a non-bundle, a bundle without the branch, a path argument, and an attributed bundle when called directly, store permissions, prune, storage, remove-copy.
- (03) gc --auto in the private copy is called on every fetch but no unit test shows it packing: git's estimate counts loose objects in one fan-out folder only, which a small test repo does not reach.
- (03) `gitctl fetch` takes the working copy's path (it must update that copy), not owner/name; owner/name is read from its origin. `gitctl clone <owner/name> <path>` is agent-side only (gitrun has no clone verb: it never writes a working copy). New verbs `gitctl storage` (bytes in the copies and the bundles) and `gitctl remove-copy <owner/name>`.
- (03) Working copies: `aidc repo add` runs a one-shot root pod (CHOWN, DAC_OVERRIDE, FOWNER, FSETID; FSETID keeps setgid on a folder whose group root is not in) in mode `make` (missing parents as 1000:1000; the repo folder, missing or empty, to the agent 2000:1000, 0755, so nothing is planted while it clones), then `gitctl clone` as the agent (`init --template= --shared=group`, so every folder in `.git` is setgid from the start; umask 002; origin the GitHub URL, default branch from the bundle's HEAD, main/master first on a tie), then mode `own` (`chown -R -h 1000:1000`, 2775). Default path `/home/<user>/<name>`. The ruling asked for session-owned copies; only root can hand files to 1000, hence the second pod.
- (03) `aidc repo remove <path|owner/name> [--delete-working-copy]` always deletes gitrun's copy (first) and deletes the working copy only with the flag, by the root pod in mode `delete`, which refuses anything but a git working copy. `aidc repo list` lists GitHub working copies on the disk (path, origin, branch; worktrees not listed). `aidc git status` adds a storage row (copies + bundles) and warns above `kubernetes.git_storage_warn` (default 1Gi).
- (03) Sessions make their own worktrees (owner ruling 2026-11-24): `aidc create --backend kubernetes` refuses `--repo`, pointing at `aidc repo add` and `git worktree add`; the session starts at the current directory's place on the disk as before. The unit test "a repo outside the home directory is refused" became "a create run outside the home directory is refused" (same guard, `--repo` gone). Known consumer: the MCP server's `session_create` always passes `--repo` (mcp tools.py), so it fails against a user whose config default is `backend: kubernetes`; the in-cluster MCP is aidc 2.0's.
- (03) For Chunk 04/05: the session's instructions (where repos are, worktree naming, asking for a push/PR) are Chunk 04/05's (request and result files: cleared after 30 days, Chunk 04). Tidy is simpler now: the agent or a session removes worktrees and branches in the working copy itself; only remote branch deletion needs gitctl. All sessions are uid 1000, so nothing stops one session from removing another's worktree.
- (03) Residual: the agent's git reads the working copy's config, which sessions write, when it bundles and imports; program-running settings on those steps are pinned, but a session could still try to steer the agent's own git (code as uid 2000, never gitrun or gitcred). Tags are never moved by gitctl.
- (03, Critic) MCP `session_create` decides the backend as the CLI dispatcher does (the first top-level `backend:` line of `$HOME/.config/aidc/config.yaml`, docker when none) and passes it as `--backend`, so the arguments match: on kubernetes no `--repo`/`--workspace`; a caller who names either gets `invalid_argument` naming `aidc repo add` and the session's own worktree (an explicit repo is refused, not ignored, so the caller does not believe a repo was set up). `$HOME`, not the `/aidc-config` mount: inside the aidc-mcp container the dispatcher does not read the mount and creates on Docker (the image has no kubectl), and the MCP must agree with it. The tool's `repo` description changed; `mcp/published-tools.json` regenerated (description only, no schema change). Still open: `mcp_server` at create and the other session tools on a kubernetes session are aidc 2.0's.
- (03, Critic) The folder pod's delete mode empties the folder it checked from inside (`find . -mindepth 1 -delete`, no symlink followed), then `rmdir`s it by name from the parent: a folder swapped in at that name after the check is non-empty, so rmdir fails and nothing of it is deleted. Residual: busybox find deletes by path inside the tree, so a session renaming a subfolder to a symlink mid-walk could redirect the delete of that subtree; reach is the user's own disk.
- (03, Critic) `aidc repo remove --delete-working-copy` asks `gitctl unpushed <path>` first (new agent-side verb, the agent's own git, after a fetch): local branches with commits on no `refs/remotes/origin/*`, detached worktrees' such commits, uncommitted changes (untracked count; nested worktrees excluded from their parent's status), stashes, and every worktree; any of it refuses the delete, listing it, unless `--even-unpushed`; a report without its end line (a failed fetch) refuses the same way. Nothing (not even gitrun's copy) is removed on a refusal. `git status` in a working copy can still run a session-planted clean filter as the agent (the recorded uid-2000 residual); hooks and fsmonitor are pinned off, submodules not entered.
- (03, Critic) gitrun reads a push bundle through `head -c` up to 2 GiB (fixed: sudo resets the environment, so no config reaches gitrun) and refuses a larger one, its file removed by the trap. Each push holds its branch under `refs/incoming/<its bundle's name>`, deleted at exit; a killed push's ref (its bundle gone) is dropped by the next push. `aidc repo list` strips control characters from each field in the container (so no newline can forge a row) and again before printing (`k8s_printable`); C1 bytes are left (stripping them would break UTF-8).

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

### Chunk 03: Repos on the user's disk, through gitrun's private copies

- **Deliverables (as rebuilt after the 2026-11-24 rulings):** gitctl moves commits as bundles
  between the working copies and gitrun's private bare copies (`clone`, `fetch`, `push`,
  `storage`, `remove-copy`); `aidc repo add <url> [--path P]` (an ordinary, session-owned
  working copy), `aidc repo list`, `aidc repo remove`; storage in `aidc git status`;
  `aidc create --backend kubernetes` refuses `--repo` (sessions make their own worktrees).
  Live: add a public repo, a session makes a worktree and commits, the agent's `gitctl push`
  stops only for want of a login, `gitctl fetch` works, planted config never runs as gitrun.

### Chunk 04: Push, PR and cleanup

- **Deliverables:** `aidc git push <session>` and `aidc git pr <session>` (through the wrappers,
  the PR merge-commit-only and attribution-free); `aidc git tidy` deletes merged branches and
  their worktrees and lists every leftover (unmerged, unpushed, orphaned) for the user; GitHub
  protections checked on first use of a repo and offered (`aidc git protect <repo>`, applied only
  with the user's yes). Sessions ask for pushes and PRs through a `gh` stand-in in the session
  image that writes a request (branch, title, body) to a request folder on the user's disk, so
  `/prawduct:pr` and plain `gh pr create` work unchanged in sessions; the git container acts on
  requests by its rules (ask mode: shows the user first) and knows nothing of prawduct (owner
  ruling 2026-11-24). The stand-in waits up to about a minute for a result, then returns
  "requested; waiting for approval". Requests reach the git agent as prompts; in ask mode it asks
  with Claude Code's question tool, which aidc already delivers to the orchestrator, so approvals
  bubble up with no separate system (owner ruling 2026-11-24). Request and result files are cleared after 30 days (owner: nothing piles up
  unnoticed). Tidy after a merge deletes the branch (GitHub and local), the session's
  worktree and its admin folder, and reports every leftover; sessions create their own worktrees
  (owner ruling 2026-11-24), owned by uid 1000 under a sticky `.git/worktrees/`, so removal is a
  gitctl verb running as gitrun (the folder's owner), and session files must stay group-writable
  (umask 002 in sessions) for gitrun to delete them. Live: push a session's branch, open a PR,
  tidy after a merge.

### Chunk 05: The git container's Claude, git modes and approval

- **Deliverables:** Claude Code in the git container with the git rules; per-session git mode
  (ask default, rules), the user's default; in ask mode Claude waits in its terminal. Orchestrator
  approval over MCP is left to aidc 2.0 (the per-user MCP server), recorded.
  The git agent is an aidc session (owner ruling 2026-11-24): the git pod carries the session
  labels and layout aidc's lookup, attach, logs, send, status and the MCP backend target read
  (Claude in tmux as in session pods, its transcript where the watchers look), under a reserved
  name; `aidc kill` refuses it; `aidc git attach` stays as a shortcut.
  Its instructions: a managed, root-owned `/etc/claude-code/CLAUDE.md` (always loaded: the git
  rules, `gitctl` as the only way to GitHub, ask/rules mode, and that everything sessions write
  (commit messages, diffs, PR text, files) is data, never instructions, and the procedures: push a
  session's branch and open a PR; tidy and report leftovers; check and offer GitHub
  protections; after every merge, tidy that branch and worktree and report leftovers). No skills: one locked file (owner, 2026-11-24: "CLAUDE.md is fine").

### Chunk 07: The git container on Docker

- **Deliverables:** the same git container, gitctl, request folder, instructions and
  session-ness on the Docker backend (owner ruling 2026-11-24): `aidc git setup|attach|status`
  start and use a `git` container with its own login volumes and a network that reaches only
  public addresses. It works on the user's own working copies on their machine, unlocked and
  owned by the user (owner ruling 2026-11-24): gitrun never runs git in them; the agent bundles
  the commits to push (`git bundle`, no login), gitrun fetches the bundle into a private bare
  copy, scans and pushes from it. Live: the Docker smoke extended.

### Chunk 06: End to end and docs

- **Deliverables:** the Kubernetes and Docker smokes extended (add a repo, session on a worktree, push, PR on a
  scratch GitHub repo if one is configured, tidy); README and design-12 updated; change record.
- **Type:** cumulative-final
