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

**Requirements implemented:** K8S-01 … K8S-26 (new, `docs/requirements.md`). Carries over NET-01,
NET-02, NET-03, NET-09, NET-14, NET-15, MCP-12 and the git rules of GIT.

**Status:** being built. Built and checked on the reference cluster (`tests/smoke/k8s.sh`): the
backend seam, the in-cluster images, users' disks and their own namespace-scoped credentials
("Users and credentials"), and sessions (create with a size, attach,
list, status, logs, restart, upgrade, refresh, kill) with the lockdown (NetworkPolicy and a
public-only squid), Docker inside, the blocklist and its feeds in `aidc status`, taint and
audit (with `aidc audit list|trim`), testament when configured, the git container ("Git",
on this backend and on Docker), tunnels and LAN pages ("Ports"), TCP egress relays, `--dns` and
`--network` ("Egress"), and the GPU on request. Not built yet: the in-cluster MCP server, account
switching, Syncthing, the taint freeze; all of it ships in aidc 2.0 (owner ruling 2026-11-24). Owner rulings are
in `.prawduct/owner-rulings.md`; each open item says what will settle it, and items marked
**proposal** await the owner.

---

## Shape

```
cluster (the session node)
├─ namespace <prefix>-system                aidc's own: the image registry, builds
│   ├─ registry                             loopback host port for pulls; pushes from builders only
│   └─ builder (during `aidc k8s build`)    privileged, deleted after (see "Images")
└─ namespace <prefix>-u-<user>              one per user; default-deny NetworkPolicy; Pod Security baseline
    ├─ ServiceAccounts aidc-user, aidc-mcp  the user's and their MCP's credentials ("Users and credentials")
    ├─ PVC disk                             all the user's repos + worktrees (K8S-02)
    ├─ <session>-dev  (StatefulSet)         Claude, Docker, optional GPU; sysbox-runc
    ├─ <session>-proxy (Deployment)         squid, refresher, policy, audit, names: the only way out
    ├─ <session>-egress-<host> (Deployment) a TCP relay per --egress-tcp host (NET-15)
    ├─ <session>-dev (Service) + Ingress    a page on the network (--expose, K8S-15)
    ├─ <session>-audit (PVC)                kept by `aidc kill`, removed by `aidc audit trim`
    ├─ git (Deployment)                     the git container: gitctl, the GitHub login (K8S-04..06; "Git")
    ├─ aidc-mcp (not built yet: aidc 2.0)   the user's MCP server (K8S-07)
    └─ syncthing (not built yet: aidc 2.0)  Claude state <-> user's machines (K8S-18)
```

Sessions live in their user's namespace, named `<session>-*`, not one namespace each: every
session mounts the user's one disk, and a pod can mount only claims of its own namespace.
Labels and per-session NetworkPolicies keep sessions apart, and `aidc kill` removes a session
by its label (decided while building; the plan records it).

The Docker backend stays. The same `aidc` commands, the MCP server and the orchestrator work
against either (K8S-01).

## Code: one disk per user, one worktree per session

Each user has one persistent volume holding every repo they work on, because projects need each
other (K8S-02). Users never share a volume. A session that works on a repo makes its own git
worktree and branch in it (K8S-03 as amended; "Sessions make their own worktrees" under "Git"),
so two sessions on one repo never share a working folder.

The user views and edits the same files with VS Code attached to a pod that mounts the volume,
the way aidc dev containers are used today (K8S-09).

## Git: a trusted git container per user

Sessions cannot push. One trusted git container per user holds the GitHub login (`gh`, over https), and is the
only thing that pushes, pulls or opens PRs (K8S-04). It runs Claude Code with the git rules:

- merge commits only; never force-push; no AI attribution in commits, PRs, code or docs;
- git mode, from **ask** (default: each session request waits for the user) to **rules**
  (gitctl's rules decide at once); each user sets their own, and may give one session its own,
  either way (K8S-05; "Per-session git mode" below);
- an orchestrator the user drives may approve through the user's MCP server; sandboxed sessions
  never reach that server (K8S-06; "Ask mode and orchestrators" below for where this stands);
- the first time it meets a repo it checks the GitHub protections (no force push, merge commits
  only) and offers to turn on any that are missing (K8S-23).

**Hard rules are enforced by code, not only instructions** (K8S-24). The git container's Claude reads
text written by sandboxed sessions (commit messages, diffs, requests), which can try to talk it
into breaking a rule. So: GitHub branch protection where available; a PreToolUse hook in a
read-only managed settings file; and, as built, no route to the login but `gitctl`'s fixed
verbs, which build their own git and gh command lines and refuse force pushes, protected
branches, non-merge merges and attribution (below). Wrapping `git` and `gh` behind option checks
was built first and dropped: they accept too many spellings of too many options to fence.

As built so far: `aidc git setup` runs it as a one-replica Deployment `git` in the user's
namespace, from the `aidc/gitctl` image (git, a pinned and checksum-checked `gh`, Claude Code,
tmux; no ssh client: pushes are HTTPS only), built in the cluster with the others. It runs as
uid 2000 (its own group 2000; supplementary group 1000, the sessions', so it can work in their
group-shared working copies), unprivileged (only SETUID, SETGID and AUDIT_WRITE, for sudo to gitctl's users), no
service-account token, no service links. It
mounts the user's disk at `/home/<user>` and its own home claim `git-home` (on the retained
`storage_class`: it holds the user's secrets) at `/home/git`, seeded once from the image as a
session's home is. Its NetworkPolicy `git-egress` allows no ingress and egress to Quad9 DNS and
public addresses only, the proxy's rule, and it resolves through Quad9 only. The user logs it
in to GitHub with `aidc git login` (one `gh` login over HTTPS; no SSH key) and its Claude through
`aidc git attach` (its tmux). Measured 2026-11-24 on
the reference cluster: GitHub reachable over HTTPS and SSH; the API service, every node's API
server, kubelet and ssh, the registry pod, cluster DNS and a listening pod in a namespace with
no policies all refused; the user's disk visible.

The hard rules as built: the agent and the user's terminal run as `git` (uid 2000) and run
ordinary git as themselves, with no credential, so nothing they run reaches GitHub (their git
still runs no repo hooks or fsmonitor and no `ext::` transport, from `/etc/gitconfig`). What
needs the login is `gitctl`, a set of fixed verbs (`gitctl --help` lists them) and the only
thing in the sudo rules. Each builds its own git or gh command line from arguments it
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
`main`, `master`, `develop` or origin's default branch under any name, as GitHub reports it
(they change by PR merges); it asks origin what it has
(`ls-remote`) rather than trusting `refs/remotes/*`, reads each commit it would send whole, and
refuses one that carries AI attribution anywhere, in its message or in a line it adds to a file
(a merge counts only the lines it writes itself; a rename adds none), or whose author or committer is an AI tool (a
name or email naming one, as a whole word: `Claude <x@example.invalid>` is refused; the user's
own identity, from the login's identity file, never is). `pr-create` and `pr-comment` refuse
attribution in their text; `pr-merge` always merges with a merge commit, after checking the
PR's title, body and commits, and bound to the head commit it checked (`--match-head-commit`; a
request's merge also to the head the user was shown when it was taken, `--expect-head`).
gitcred checks for itself that a repo is one the user added before any gh call that names one:
it asks gitrun (`has-copy`, read only, through the one sudo rule gitcred has, to that verb of
gitctl only), so a caller who reaches gitcred through sudo directly cannot act on another repo
either. "Added" is not "gitrun holds a copy": the agent can ask gitrun for a copy (sudo to its
`add-copy`, its own `gitctl clone`, `gitctl adopt` on an origin it set). It is the list of added
repos, one owner/name a line, which only the user's machine writes: on Kubernetes the
`git-repos` ConfigMap in the user's namespace (written by `aidc repo add|remove` and created
empty by `aidc git setup` with the user's kubectl), mounted read-only at `/etc/aidc/git-repos`
in the git container, whose pod, like every pod aidc makes, has no service account token; on
Docker `~/.config/aidc/git-added/repos`, its folder bind-mounted `:ro` at the same path. gitrun
refuses every verb that makes or uses a copy (`add-copy`, so `clone` and `adopt`, `fetch`,
`push`, `delete-branch`) for a repo off the list, and `has-copy` answers no for one even with a
copy in the store; `remove-copy` still deletes any. A caller check on gitrun (refusing `add-copy`
when sudo's caller is the agent) would add nothing: `aidc repo add` itself reaches gitrun as the
agent (`kubectl exec` and `docker exec -u git` run as uid 2000), so it could not tell them apart. gitrun and gitcred each append a line for every action that changes GitHub (push,
delete-branch; pr-create, pr-comment, pr-merge, protect) to an action log in their own storage,
which the agent cannot write: time, verb, repo, branch or PR, commit, who asked (a request's id
or `direct`) and the calling user; each is capped at 1 MiB, then kept as one older file.
`aidc git log` shows both, merged in time order. Claude Code's PreToolUse hook
(`/etc/claude-code/managed-settings.json`, root's, with `allowManagedHooksOnly`) is a courtesy
on top: it refuses switching user, reading the login's home, edits to the guard files, a gh
login in the agent's home, and attributed git commands. Measured 2026-11-24 in the git pod as
uid 2000, with a dummy token: `sudo -l` lists only gitctl; the token is unreadable by every route
tried; every verb refuses options and malformed arguments. The bypasses that remain are listed
in the build plan (`.prawduct/artifacts/archive/build-plan-k8s-git-container.md`, Chunk 02 decisions).

Repos as built: `aidc repo add <owner/name>` first puts the repo on the `git-repos` ConfigMap and
waits (up to `AIDC_K8S_GIT_REPOS_WAIT`, 180 s) until the git pod's mounted copy has it (the
kubelet brings a changed ConfigMap into the volume within about a minute); a failed add takes a
new entry off again. A working copy of the repo already at the path is put on the list and
adopted (`gitctl adopt`), so one added before the list existed is taken over by running `aidc
repo add` again. Then a one-shot root pod (CHOWN, DAC_OVERRIDE,
FOWNER and FSETID only, symlinks on the way refused, never followed) make the repo folder and
give it to the agent while `gitctl clone` fills it from gitrun's bundle, then give the working
copy to the session user, group-shared (setgid, `core.sharedRepository=group`) so the agent,
in the session group, works in it too. It is an ordinary repo: no lock, sessions write all of
it. `aidc repo remove` takes the repo off the list, then deletes gitrun's private copy (`gitctl remove-copy`), and the working
copy only with `--delete-working-copy`: first the agent fetches and lists what the delete would
lose (`gitctl unpushed`: branches with commits on no origin branch, detached commits,
uncommitted changes, stashes, and every worktree), and any of it refuses the delete unless
`--even-unpushed` is given too (run again after a first run removed gitrun's copy, it compares
with origin's branches as the working copy last fetched them, and says so); the root pod then empties the folder it checked from inside
and removes it by name with `rmdir`, so a folder swapped in at that name is never deleted.
`aidc repo list` strips control characters from the names and URLs it prints, which sessions
write. gitctl reaches GitHub only for repos the user added (on the list, and gitrun holds a
private copy): only `clone` and `adopt` make a copy, of a listed repo only, and every other verb,
pull request reads included, refuses another repo. `aidc git status` reports the private copies' and
bundles' size and warns above `kubernetes.git_storage_warn` (default 1Gi).

Sessions make their own worktrees (owner ruling 2026-11-24): a session sees the whole disk and
runs `git worktree add -b <branch> <path>` itself in a working copy; `aidc create` takes no
`--repo` on this backend.

**Cleanup is the git container's job** (K8S-08). Merged branches and their worktrees are deleted.
Anything else left behind (unmerged, unpushed, orphaned worktrees) is flagged to the user at
once, not left to rot.

Push, PR, merge, tidy and protections as built: the user drives them with `aidc git push`,
`pr`, `merge`, `tidy` and `protect` (kubectl exec to gitctl; running the command is the
approval), and logs the git container in with `aidc git login` (gh's device code as gitcred,
then `gh api user` writes the identity file `/etc/gitconfig` includes: the account's name, its
public email or else `<id>+<login>@users.noreply.github.com`; no signing; `logout` removes
both). `gitctl tidy <repo>` fetches, then for each local branch already in a base on origin
(origin's default branch, or main, master or develop): `delete-branch` on GitHub (as gitrun:
only a branch merged there, never a base, leased on the tip it checked), the clean worktree
removed with its admin folder (`git worktree remove`, after checking every folder in it is
writable by the agent, so nothing is half-deleted), the local branch deleted; prune; and every
leftover reported, never deleted (a worktree is removed only where its recorded path, which
sessions can write, resolves with no symlink inside the user's disk, outside `.aidc` and not
holding the working copy): unpushed and unmerged branches, a merged branch's worktree with
changes, detached and locked worktrees, folders that were worktrees whose admin folder is gone,
and what the agent may not delete. Only branches the working copy has are deleted on GitHub.
Sessions make files group-writable (umask 002 on this backend) so the agent, in their group,
can delete them. `gitctl protection` reads what guards the default branch (rulesets and classic
protection: force pushes and deletion blocked, allowed or unknown; the merge methods);
`gitctl protect` only adds a fixed ruleset (no force pushes or deletion of the default branch,
main, master, develop) and allows merge commits, never turning anything off; the CLI applies it
only on the user's yes. Every git the agent runs in a working copy overrides each filter driver
the copy's config names (clean and smudge `cat`, no process), read just before the call, with
hooks and fsmonitor off.

Session requests (owner rulings 2026-11-24): a session's `gh` is a stand-in
(`.devcontainer/gh-standin.sh`) that writes `pr create` (push included), `pr merge`, `pr view`,
`pr list` and `aidc push` as request files into `/home/<user>/.aidc/git-requests/requests/`
(the git container's folder, made by `aidc git setup`; sessions may add files there but not
list it, and read results by id from `results/`), waits up to a minute and prints the result as
gh would, "requested; waiting for approval" with the id when the request waits for the user,
or that the git container has not taken it (exit 1) when it still sits in `requests/`. The watcher (`git-requests watch`,
as the agent, kept running by the container's main process) moves each request out by rename,
refuses anything but a plain file, checks every field (known fields only, a working copy on the
disk with a GitHub origin, branch names, no protected branch, title and body without
attribution or control characters), and then, by `kubernetes.git_mode`: rules runs it through
gitctl at once; ask holds it as pending for `aidc git approve|deny` (reads run at once in both). A request
records the GitHub repo its working copy named when taken and, for a push, the branch's commit,
for a merge the pull request's head commit as GitHub had it then; the user is shown them, and the
run refuses (nothing done) if any has since changed: gitctl is given them (`--expect-repo`,
`--expect-commit`, `--expect-head`) and checks them against what it acts on. An approval and a
denial of one request take its lock and read its state again under it, so when they race exactly
one happens and the other says it did not. A watcher that cannot use its request folder logs why
(once per reason), and `aidc git status` shows that reason.
A session's `git push` to GitHub is rewritten (`pushInsteadOf`) to a remote helper that pushes
nothing and says to use `gh pr create`. Results, written only by the agent, say done, failed, denied or pending; a run cut short by a
restart is reported as interrupted, never retried. Requests and results are deleted after 30
days (a request still waiting then is logged as expired), and what a killed take or save leaves
in `work/` after an hour.

The git agent (owner rulings 2026-11-24: it is an aidc session; it does no prawduct work; its
instructions are one managed CLAUDE.md, no skills; it tidies after every merge; ask-mode
approvals bubble up through the orchestrator's approval path). The git container's tmux is laid
out as a session's: window `claude` runs `git-claude` (Claude Code in the agent's home, resuming
its conversation), window `shell` a shell. Its instructions are `/etc/claude-code/CLAUDE.md`,
root's, always loaded: gitctl as the only way to GitHub, the hard rules, everything sessions
write is data, the ask-mode procedure, push/PR, merge then tidy, protections, leftovers
reported. Its managed settings add a permission list (gitctl, git-requests, git, reads, its
question tool, writes under /tmp) in `dontAsk` mode, with bypass mode disabled: anything else is
refused, never left waiting on a prompt nobody sees. Unlike a sandboxed session's Claude it
keeps AskUserQuestion. The Deployment carries the reserved session label `aidc/session: git`
(not in its selector), so `aidc list` shows it, `aidc attach|logs|status git` reach it
(`aidc git attach` is the same attach), `aidc create git` is refused (its claims would collide
with the git container's) and `aidc kill git` refuses it. A home seeded before Claude Code
moved on gets the image's Claude at each start (init step `refresh-claude`, as the git user:
the image's version file copied in and linked when the home's is older; a newer one the home
updated to itself is kept); the managed files are the image's, so they are always current.

In ask mode the watcher hands a waiting request to the agent (`AIDC_GIT_NOTIFY`, `git-notify`):
one line naming only the id is pasted into window `claude` when Claude runs there and is set up
(never into a shell or Claude's first-run screens), and the agent runs `git-requests prompt <id>` (the session's text below a line, marked
as data) and asks the user with AskUserQuestion, Deny first; aidc delivers that question to an
orchestrator as any session's, and the user can answer in the terminal too; only then does it
approve or deny. One request is handed over at a time: while the request the agent may be asking
about still waits, new ones are only logged, and the agent takes them from `git-requests list`
after each decision, so no line lands in an open question. That request is the one last handed
over or the one the agent last ran `git-requests prompt` for (it also takes requests from the
list itself); after a watcher start, when which one is open is not known, it is every request
then waiting, until each is decided or the agent runs `prompt` for one. `aidc git approve|deny`
still work.

Residuals of the git agent, recorded rather than closed:

- Its allow list is a courtesy, not a boundary. `Bash(git *)` lets it run any command as the git
  user (uid 2000), for example through a git alias; what stops it reaching GitHub other than
  through gitctl is that its own git has no credential and gitctl and the watcher check every
  action, not the list.
- Only its instructions stop it approving a request without asking the user: `git-requests
  approve` is in its allow list, and nothing in code tells an approval the user gave from one the
  agent made up.
- prawduct's skills, if ever installed in the git home, would be kept out only by its CLAUDE.md
  ("You do no prawduct work"); nothing in its settings blocks them.

Per-session git mode (owner ruling 2026-11-23: each user changes their mode per session, both
ways): each session gets a random token at `aidc create` (`AIDC_GIT_TOKEN` in its dev pod or
container; sessions reach no API server, no other pod and no other container, so only it can
read it), which its gh stand-in sends with each request. Every mode decision is keyed on that
token. The git container keeps, per session, the token's SHA-256 and the session's own mode
(`default`, `rules` or `ask`): `aidc create` registers a new session (`git-requests register`,
the token on stdin), `aidc git setup` registers every session there is and prunes the records of
sessions that are gone (`sync`), `aidc kill` forgets the session (`forget`), and `aidc git mode
<session> <rules|ask|default>` (from the user's machine, which reads the token from the
StatefulSet or the container) sets its own. A request carrying its session's recorded token runs
by that session's own mode, or the user's when it has none; any other request (no token,
another token, a session with no record) waits for the user. So one session can be given rules
while the user's mode is ask, and held to ask while it is rules: leaving its token out gains a
held session nothing. A session made again under an old name has a new token and starts at the
user's mode.

### The git container on Docker

The same image, gitctl, request watcher, managed CLAUDE.md, modes and tokens on the Docker
backend (owner rulings 2026-11-24, "The git container works on Docker too" and "On Docker the
git container works on the user's own working copies"). `aidc git` and `aidc repo` pick the
backend by the one rule every command uses (`scripts/lib/git-common.sh`,
`aidc_default_backend`): `--backend`, else the config's top-level `backend:`, else Docker; a
`kubernetes:` block alone changes nothing. Each `aidc git` verb is one script for both backends
(`scripts/git/`), reaching the git container through a small interface each backend's library
defines (the `gb_*` functions of `scripts/docker/lib.sh` and `scripts/k8s/lib.sh`); only `aidc
git setup` and `aidc repo` are per backend. What differs is only what Docker is:

- The container is `aidc-git-dev`, labelled as the dev container of the session named `git`, so
  `aidc list|attach|logs|status` and the MCP server find it like any session (the MCP runs a
  session-user command there as its `git` user; it has no policy sidecar, so it is never
  tainted). `aidc kill|restart|upgrade|... git` and `aidc create git` are refused.
- Its homes are volumes (`aidc-git-home`, `aidc-git-cred`, `aidc-git-run`), seeded by a one-shot
  root container with only CHOWN, FOWNER and DAC_OVERRIDE and no network, as the pod's init steps
  do; the Claude refresh runs as the git user. The request folder is the `aidc-git-requests`
  volume at `/var/aidc/git-requests`, the agent's (2755, session group); a session created after
  setup mounts it (external, never removed with a session) and gets `AIDC_GIT_REQUESTS`;
  every session gets `AIDC_GIT_TOKEN` and `AIDC_BACKEND=docker`. Sessions keep the host's umask.
- Working copies are the user's own on their machine, never cloned, locked or re-owned. `aidc
  repo add <path>` (under the home, origin `https://github.com/<owner>/<name>`) records it in
  `~/.config/aidc/git-repos`, recreates the container with it mounted at its own path (the one
  sessions see), puts its GitHub repo on the list of added repos
  (`~/.config/aidc/git-added/repos`, the folder mounted `:ro` at `/etc/aidc/git-repos`) and runs
  `gitctl adopt` (gitrun makes its private copy, of a listed repo only; the working copy is only
  read). Only those working copies are mounted. `repo remove` takes the repo off the list and
  drops the copy and the mount, and never deletes the working copy. The watcher's disk is the user's home (`AIDC_GIT_DISK`).
- The agent (uid 2000) cannot write the user's files, which are not group-writable, so the verbs
  that write a working copy (`fetch`'s import, `tidy`, `unpushed`) run as `gitwc`, uid 1000 (the
  sessions' and the user's uid), through one more sudo rule; gitctl refuses `gitwc` unless Docker
  made the container (`/.dockerenv`, root's), and as `gitwc` runs those three verbs only, each on
  a mounted working copy: every other verb (push, adopt, the pull request verbs, which read their
  text files) refuses it, so no file only the user's uid can read reaches GitHub through it. `tidy` removes a worktree only inside its working
  copy, and one recorded outside it (unseen in the container, so it looks gone) keeps its record
  and branch: nothing is pruned while one exists. `clone` is refused.
- Egress: the container is on an internal network (`aidc-git-net`, no route out) whose only
  other member is its proxy, `aidc-git-squid` (alias `aidc-proxy`), the session Squid image with
  `AIDC_PUBLIC_ONLY=1`: every private, loopback, link-local, shared and multicast destination is
  refused, names resolve through Quad9. gitctl gives gitrun's git and gitcred's gh that proxy by
  value on Docker only. No ports are published. Its Claude takes the user's long-lived token when
  `aidc claude-token` set one, as sessions do.
- The agent's transcript is copied (the dev image's `transcript-mirror.sh`, kept identical) into
  the MCP server's `transcripts/git`, given to the agent, so an orchestrator reads its questions
  as it reads any session's.
- A working copy is mounted only while it is still as recorded (no symlink at it or on the way, a
  real `.git` folder); after the start each mounted path's device and inode inside the container
  must equal the host's (Linux hosts), else the container is removed: a symlink swapped in
  between the check and Docker's mount is caught. `gitwc` acts only on a path at or inside one of
  those mounts whose `.git` and config are its own (uid 1000), never on a repo the agent made.

### Ask mode and orchestrators

The owner ruling "Ask-mode git approvals bubble up through the orchestrator" has the git agent
ask with its question tool, an orchestrator see that question as any session's, and the answer
come back by `session_send` or from the user in the terminal. Where that stands (2026-11-24):

- Docker: the git agent's transcript reaches `aidc mcp` (above), so an orchestrator that watches
  the session `git` gets the question as that session's reply. Whether `session_send` can answer
  it is not yet checked: the MCP server's own notes say the question widget may not take a
  pasted answer and Enter. Checked by hand with a logged-in git agent (tests/smoke/README.md).
- Kubernetes: the question does not reach an orchestrator yet. The MCP server's session tools
  reach cluster sessions only through the per-user MCP server (K8S-07). Owner ruling 2026-11-24
  ("aidc 2.0 is the Kubernetes work and the 3tears adoption, released together"): the Kubernetes
  backend ships only in 2.0, with that server, and 2.0 must route Kubernetes git approvals
  through the orchestrator before it ships. Until then the user answers by attaching (`aidc
  attach git`) or with `aidc git approve|deny`.
- Both: `aidc git requests|approve|deny` always work, and answer the request whatever the agent
  is asking.

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

## Users and credentials

An admin (someone who may make namespaces) sets up the cluster (`aidc k8s setup|build`) and
adds users. Each user then works with their own credentials, which reach their own namespace
and nothing of anyone else's (K8S-14, K8S-20; plan-aidc-2.0 Q-K6 and Q-M2). Built and checked
live on the reference cluster (W-K5): a test user ran the whole session lifecycle with only
the kubeconfig `aidc user add` wrote, could do nothing in another user's namespace or
cluster-wide, and was removed with everything made for it.

**What `aidc user add <name>` makes** (scripts/k8s/manifests.sh):

```
namespace <prefix>-u-<name>     Pod Security enforce|audit|warn: baseline
  ServiceAccount aidc-user      the user; Role + RoleBinding aidc-user (below)
  ServiceAccount aidc-mcp       their MCP server (K8S-07, W-M2); Role + RoleBinding aidc-mcp
  (no token mounted into any pod: automountServiceAccountToken false)
ClusterRoleBinding <prefix>-u-<name>       -> ClusterRole <prefix>-user (shared)
ClusterRoleBinding <prefix>-u-<name>-mcp   -> ClusterRole <prefix>-mcp  (shared)
ClusterRole <prefix>-network (shared; bound only per namespace, by aidc user allow-network)
ValidatingAdmissionPolicy <prefix>-user-volumes (shared) + its binding
ValidatingAdmissionPolicies <prefix>-user-ingresses, -services, -secrets, -middlewares
  (shared) + bindings
kubeconfig ~/.config/aidc/users/<name>.kubeconfig (on the admin's machine, mode 0600)
```

**The user's Role** is exactly what aidc's commands do in the namespace, one table
(`K8S_USER_RULES`) rendered into the Role, read by `aidc k8s check`, and held to the scripts
by `tests/unit/test-k8s-rbac.sh`, which reads every kubectl call in `scripts/` and fails when a
call needs a verb the Role lacks, or the Role grants one no call uses and no reason names:

| Resource | Verbs | Used by |
|---|---|---|
| pods | get list watch create patch delete | status, taint, restart (delete), the repo folder pods (`aidc repo`, `aidc git setup`: apply, delete) |
| pods/exec | create get | attach, kill, refresh, status, upgrade, the git container (exec is a websocket GET that API servers authorize as get or create) |
| pods/log | get | logs, create and restart (the ready marker) |
| pods/portforward | create | the tunnels (`aidc create --port`, `aidc proxy`) |
| services | get list watch create patch delete | create (apply), kill |
| configmaps | get list watch create patch update delete | create (the audit seed), kill, the repo list (`git-repos`, replaced at a resourceVersion) |
| persistentvolumeclaims | get list watch create patch delete | create, kill (annotate the kept trail), audit list and trim |
| events | get list watch | `kubectl describe`, which aidc's errors point to |
| secrets | create delete | a page's login (`--expose --login`): made with `kubectl create`, removed by name; no get or list |
| serviceaccounts/token (aidc-user only) | create | `aidc user creds`: the user renews their own kubeconfig |
| deployments, statefulsets | get list watch create patch delete | create, kill, list, upgrade (set image, rollout restart), git setup |
| networkpolicies | get list watch create patch delete | create, kill, status, git setup, relays, `--network` |
| ingresses | get list watch create patch delete | the pages (`--expose`): apply, the login check, status, kill |
| middlewares.traefik.io | create delete | a page's login on Traefik: made with `kubectl create`, removed by name (a rule for a kind the cluster lacks grants nothing) |

Not granted: reading Secrets (get, list: the token lives only in the kubeconfig, and a page's
login, the one Secret aidc makes, is made and removed by name; a user who mounts a Secret into
a pod of their own can still read their own namespace's, so this keeps them out of `kubectl
get` output rather than out of reach), Roles and bindings (a user cannot widen their own
rights), the namespace itself (a user cannot relabel it to drop Pod Security), any other
ServiceAccount's token (not the MCP's). `watch` and `list` are on the table because `kubectl
delete --wait`, `wait`, `rollout status` and `-l` selectors use them; deletes of Secrets and
Middlewares pass `--wait=false`, since waiting reads the object.

**The shared ClusterRole** `<prefix>-user`: get runtime classes (create and git setup read the
runtime class's node selector) and storage classes, get ingress classes (`--expose` reads the
configured class's controller unless the config names it), list nodes (`aidc k8s check`), get, list,
watch and patch volumes (`aidc audit` lists released trails; trim sets a volume to Delete
before deleting its claim, so a retaining class keeps no data). RBAC cannot say "volumes
claimed in your namespace", so the patch is narrowed by the admission policy: a change to a
volume by any `system:serviceaccount:<prefix>-u-*:aidc-user` is refused unless the volume is
claimed in that user's own namespace, the change sets its reclaim policy to `Delete`, and its
claim reference stays as it was; deleting a volume is refused outright (and not granted).
Needs ValidatingAdmissionPolicy (Kubernetes 1.30), as every policy here does; aidc issues no
user credentials without it (below). Checked live: setting
another user's disk volume to Delete, labelling one's own volume, or handing it to another
namespace were each refused by the policy; setting one's own to Delete passed.

Not granted cluster-wide: listing Ingresses. `--expose` refuses a page name another Ingress
already serves; with an admin's credentials it reads every namespace, but a user's may read only
their own, since a cluster-wide list would show every user's page names. The check stays safe
without it because the Ingress admission policy (below) holds every user's Ingresses to their
own names, and `aidc user add` refuses a user name that ends in `-<another user>` (`a-bob`'s
session `x` and `bob`'s session `x-a` would both be `x-a-bob`), so two users' page names never
meet; an Ingress an admin made outside aidc under the same domain is the admin's to avoid. It
also refuses a user name that starts with `<another user>-`: Traefik names a Middleware
`<namespace>-<name>`, and `bob`'s `x-a` and `bob-x`'s `a` would both be `<prefix>-u-bob-x-a`.

**What a user makes, narrowed** (ValidatingAdmissionPolicies `<prefix>-user-ingresses`,
`<prefix>-user-services`, `<prefix>-user-secrets` and `<prefix>-user-middlewares`, one per
kind, for the user's and their MCP's ServiceAccounts, on create and update). RBAC grants a
verb on a kind, not on what the object says, so:
- an Ingress serves only the user's own page names under the configured domain: every rule's
  and certificate's host is `<label>-<user>.<domain>` (the user from the namespace's name, the
  domain the admin's `kubernetes.ingress.domain` when `aidc user add` rendered the policy; with
  none configured the policy refuses every page), there is no default backend, and it carries
  only the annotations aidc sets (its port, the Traefik login Middleware, which must be of the
  user's own namespace, ingress-nginx's three auth annotations, whose Secret may not name
  another namespace, the cert-manager issuer, and kubectl's last-applied record). No
  controller snippets, no catching every host, no names under another domain that reaches the
  controller;
- a Service is a ClusterIP with no external IPs (no node port or load balancer reaching past
  the namespace's policies, no external IP taking other traffic: CVE-2020-8554). This holds
  for every Service aidc makes, so it closes a door the Role had opened since W-K5;
- a Secret is never a ServiceAccount token Secret (a token that would not expire);
- a Traefik Middleware is a page login and nothing else: its spec's one key is `basicAuth`,
  with only `secret`, `realm` and `removeHeader`, and its `secret` a plain name, read from the
  Middleware's own namespace. Other kinds make the controller itself act, not only the routes
  that use them: a forwardAuth Middleware would make Traefik call any address the user names on
  every request to their page and hand back the answer. The NetworkPolicy `--expose` makes lets
  the controller's pods into every user's exposed port, and it must (the controller serves the
  pages), so such a Middleware would reach another user's dev server past their login, or
  cluster-internal and metadata addresses. Held to basicAuth, the controller's way in is used
  only to serve a page through a login that reads the user's own Secret.

**Without ValidatingAdmissionPolicy** (before Kubernetes 1.30) aidc issues no user
credentials: `aidc user add` and `aidc user creds` refuse, saying why, before anything is made,
and `aidc k8s check` reports it missing. Sessions need Services (`create`, `patch`), and
without the policy nothing would refuse a Service with external IPs (CVE-2020-8554: kube-proxy
would send another namespace's traffic for that address to the user's pods), a NodePort or a
LoadBalancer; nor would anything narrow volumes, Ingresses, Secrets or Middlewares.

**Other namespaces** (`--network`). A session given a namespace reaches its pods by a
NetworkPolicy in the user's own namespace, and its Services by name through the names
responder, which aidc fills from that namespace's Service list, read with the user's
credentials. A user's credentials read nothing outside their namespace, and no cluster-wide
Service list is granted (it would show every namespace's); instead an admin grants one
namespace at a time: `aidc user allow-network <user> <namespace>` makes a RoleBinding there,
`<prefix>-u-<user>-network`, to the shared ClusterRole `<prefix>-network` (list Services,
nothing else; it controls Service names and aidc's own `--network` flow, not the network
itself: a user's Role makes NetworkPolicies in their own namespace, so with their kubeconfig
they can open a session's egress to another namespace's pods by address, and what those pods
let in is their namespace's own policies' business), for the user and their MCP server (a
`networks:` entry in the config applies to sessions the MCP creates too). aidc's own namespaces
and the system ones are refused, as `--network` refuses them; `--remove` takes it back; with no
namespace it lists the grants. `aidc create --network` and `aidc network add` ask first
(`kubectl auth can-i list services -n <namespace>`) and refuse before anything is made, naming
the command, when the grant is not there. `aidc user remove` removes the user's grants with
them.

**The MCP's Role** (`K8S_MCP_RULES`, Q-M2) is the session lifecycle in its own namespace:
StatefulSets and Deployments (the proxy is a Deployment, so Q-M2's list gains it), Services,
NetworkPolicies, ConfigMaps, claims, pods (get, list, watch, delete: restart), exec and logs,
and, so that its `aidc kill` removes a page the user made, list, watch and delete Ingresses and
delete Secrets and Middlewares (by name). No bare pods, no repo list, no tokens, no volumes, no
tunnels (a port-forward ends on the machine that runs it), no pages of its own; its ClusterRole
reads runtime classes only. A test fails if it ever grants what the user's Role does not.

**Pod Security "baseline"** on every user namespace (enforce, audit, warn; version latest) is
what bounds any pod a user or their MCP makes: no privileged containers, host namespaces,
host paths or ports, capabilities beyond the default set, or unconfined seccomp. It admits
everything aidc runs there, checked live: Sysbox session pods (`runtimeClassName`, `hostUsers:
false`, root init steps with default capabilities), the proxy pod, the git container
(`SETUID`, `SETGID`, `AUDIT_WRITE`, all in baseline's default set), the disk and repo folder
steps (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `FSETID`). Pod Security does not restrict the runtime
class. `restricted` would refuse them (they start as root, and the git container allows
privilege escalation for its user switch), so baseline is the narrowest standard level; no
exemption is needed. The system namespace stays `privileged` for the builder alone ("Images").

**The kubeconfig.** A TokenRequest token for `aidc-user` (`kubectl create token`), lifetime
`kubernetes.user_token_ttl` (default 720h; the API server may cap it, and aidc prints the real
expiry), and the cluster's server and CA from the credentials in use. Written mode 0600 in a
0700 folder (aidc's `~/.config/aidc/users`, or one `--out` makes; an existing folder `--out`
names, such as `$HOME` or `/tmp`, is left as it is), never inside a git work tree unless the repo ignores the path, and never printed:
`aidc user creds <name> --token` prints the bare token to stdout on request, and nothing else
does. The admin hands the file over privately; the user points `kubernetes.kubeconfig` at it.
`aidc user creds <name>` renews it (the admin, or the user with their own still-valid
kubeconfig, which is renewed in place); `--revoke` (admin) replaces the ServiceAccount, which
invalidates every token issued before. Tradeoff accepted: a stolen kubeconfig can renew itself
until it is revoked. A user may instead bring their own kubeconfig; `aidc k8s check` says what
it may and may not do.

**`aidc k8s check`** asks the cluster what the credentials in use may do (one
SelfSubjectRulesReview, which everyone may make) and compares it with the tables: missing
namespace rights are `missing:`, missing cluster-wide reads a `note:` naming what is skipped
without them (no node check, released trails unlisted), and the registry in the system
namespace, which a user cannot see, is a note.

**`aidc user remove <name>`** (admin) leaves nothing behind: it refuses while the user has
sessions, lists exactly what goes and asks for the name (or `--yes`), sets every volume
claimed in the namespace to Delete, deletes the namespace, waits for each volume to go, deletes
the user's ClusterRoleBindings and, when no user namespace is left, the shared ClusterRoles
and the admission policy, and removes the kubeconfig it wrote. The user's token dies with the
ServiceAccount. Checked live: seven volumes (disk, a kept trail, git home, login and store, a
session's home and state) and both bindings gone, the old kubeconfig `Unauthorized`.

The rules test also reads the calls W-K2 added: what `kubectl apply` and `kubectl create -f -`
make for relays, network policies, pages and logins (by rendering them), `port-forward`, calls
through the `k8s_get` reader, and the one call into another namespace (held to the network
grant instead of the Role); it fails if a grant decided against (cluster-wide Ingress or
Service list, reading Secrets) is ever made.

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

The GPU is given only when asked for at create (`--gpu`, K8S-11): one `nvidia.com/gpu` in the dev
container's limits, the node selector unchanged. The cluster's NVIDIA device plugin hands GPUs to
pods through CDI, so it works under any runtime, Sysbox included. Measured 2026-11-24 on the
reference cluster: `nvidia-smi -L` lists the GPU in a `--gpu` session; without `--gpu` there is
no `nvidia-smi` and no `/dev/nvidia*`.

Rootless Docker and Podman were tried and dropped: they needed the AppArmor user-namespace
restriction lifted, a smaller ID range and a tun device plugin, and still did not run.

Sessions come with testament installed (K8S-25) when the user's config names its repo
(`testament: {repo: <ssh url>}`), so tests can run through that distributed test runner. It is
private for now, so it is optional (owner rulings 2026-11-24) and fetched the way the user
fetches it: on the user's machine, with their own SSH key (never gh, no token), at its newest
`vX.Y.Z` tag, built into a wheel there (`uv build`) and cached per tag
(`scripts/lib/testament.sh`). The wheel is the only thing that crosses: into the dev image's
build context on both backends (`aidc rebuild`, a first `aidc create`, `aidc k8s build`; the
image installs it like its other uv tools and keeps the wheel in `/opt/aidc/testament`), and
on `aidc upgrade` into the running session's home (where it survives restarts and a login
shell finds it first). A missing config, no access or no `uv` is one line, and the build or
upgrade goes on without it.

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
- `--egress-tcp HOST:PORT` (NET-15) becomes a socat relay pod per host with a ClusterIP Service
  and an egress rule for exactly that `/32:port` (below: "TCP egress relays"); its name resolves
  through the session's names responder, not `hostAliases`, so `aidc egress add` never restarts
  the dev pod.

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

Squid denies private destinations itself as well (defence in depth): every session's squid runs
public-only (`AIDC_PUBLIC_ONLY=1`, the same rule as the git container's proxy on Docker), so a
request for a private, loopback, link-local or shared address, or for a public name that resolves
to one, gets squid's 403 before the NetworkPolicy would refuse the connection. An `--egress-tcp`
relay (NET-15) is reached by the dev pod directly, by its own egress rule, not through squid, so
public-only refuses nothing a session is meant to reach (checked live 2026-11-24: a relay to a
LAN address answered while squid stayed public-only).

### Names: the session's own responder

The dev pod still has no cluster DNS. Its one nameserver is the `names` container of its own
proxy pod (reached through the proxy's Service, port 53): dnsmasq with no upstream
(`--no-resolv`, no server, not the pod's hosts file), answering only the names aidc writes into
its hosts folder and refusing every other name, so a lookup still cannot leave around squid (the
smoke's "a DNS lookup is blocked" holds). The folder is on the session's state claim, so a new
proxy pod keeps it; dnsmasq watches it (`--hostsdir`, inotify), so a name added or removed is
served at once and nothing restarts. aidc writes there (`scripts/k8s/net.sh`, from the cluster's
objects each time): each relay's name and each `--network` namespace's Services. Inner Docker
containers resolve through it too (the inner daemon takes the pod's resolver). This is the main
agent's Q-K9 call (plan-aidc-2.0 §5): `aidc egress add` stays live, which `hostAliases` (part of
the pod template) could not.

### TCP egress relays (NET-15)

As on Docker, one relay per destination host, resolved on the user's machine when it is made
(the machine whose resolver knows the LAN and split-horizon names), reached by the host's own
name (an IPv4 destination by `aidc-<session>-egress-<slug>`, as on Docker) so TLS hostname checks
pass. In the cluster a relay is a Deployment `<session>-egress-<slug>` (the forwarder image: one
socat per port, every connection logged to `egress-<slug>-<port>.log` on the session's audit
claim), a ClusterIP Service, and two NetworkPolicies: the dev pod may open the relay on those
ports; the relay takes connections only from the dev pod and may open only `<ip>/32` on those
ports. `aidc egress add|rm|clear` changes those objects and the names file; the dev pod keeps
running (a host's other ports drop their open connections when its relay is re-made, as on
Docker). Unlike Docker, a relay declared at create can be changed live too. Relays are their own
objects, so restart and upgrade leave them; `aidc kill` removes them with the session's label.
Loopback destinations are refused; the aidc-mcp address of MCP-12 has no cluster form yet (the
per-user MCP server, W-M*, decides its address).

Measured 2026-11-24 on the reference cluster: a relay to a LAN host's ssh port gave the session
the server's banner by the relay's name; the same address directly, another LAN host, the relay's
other ports, cluster DNS and the Kubernetes API were refused; `aidc egress add` and `rm` of a
second host took effect in seconds with the dev pod's uid unchanged; the relays and names
survived `aidc restart`; `getent hosts github.com` still failed.

### `--dns` and `--network` (K8S-01's cluster forms)

- `--dns <ip>` (and `dns_servers:`; at most three, IPv4: a pod takes three nameservers and each
  gets a `/32` rule): the proxy pod resolves through them, so squid does (its entrypoint drops
  Quad9 for resolv.conf when `AIDC_DNS_SERVERS` is set), and the proxy's policy lets it reach
  each on port 53, a private one included. The public-only squid normally refuses a DNS override;
  a session's proxy says the user chose it (`AIDC_DNS_USER_CHOSEN=1`), and squid's address check
  still refuses every private answer. So on this backend `--dns` changes which resolver answers
  public names; an internal name is reached with `--egress-tcp`, resolved on the user's machine.
- `--network <namespace>` (and `networks:`; live: `aidc network <s> add|rm|ls|sync`): Docker attaches
  the dev container to another stack's bridge; here a NetworkPolicy lets the dev pod open every
  pod of that namespace on any port, and the names responder serves its Services as
  `<svc>.<ns>[.svc[.cluster.local]]`, as read at create and on each `aidc network` add, rm or
  sync and each egress change (the proxy pod holds no API token to read them itself, so a Service
  made later resolves after `aidc network <s> sync`). It widens the sandbox the same way (not
  through squid, invisible to taint). The user's own namespace (the git login, other sessions), aidc's other
  namespaces and the system namespaces (`kube-system`, `kube-public`, `kube-node-lease`,
  `default`) are refused. With a user's own credentials, the namespace's Services are readable
  only where an admin granted it (`aidc user allow-network <user> <namespace>`, "Users and
  credentials"); without that, `--network` and `aidc network add` refuse it, naming the command.
  Measured: a session given a scratch namespace fetched its web Service by name; cluster DNS
  stayed refused.
- `clean-env` keeps its purpose (remove what a session left behind) and gets a cluster form: the
  objects of a session that is no longer running (a create or kill that stopped half way), except
  its kept audit claim, and this machine's tunnels to it. Docker's container-only-path volumes have
  no cluster counterpart (a session's worktree is its own on the user's disk), so `--project` is
  Docker's only. No K8S-01 amendment is needed for any of the three.

Measured 2026-11-24 on the reference cluster (`tests/smoke/k8s.sh` step 3 repeats both):
- through the session's squid, `http://192.168.1.1/`, `http://10.0.0.1/` and
  `http://localtest.me/` (a public name for 127.0.0.1) answer 403; `https://example.com` 200;
- root inside a Sysbox session (uid 0 in the pod's user namespace) can insert
  `iptables -I OUTPUT 1 -j ACCEPT` and set the OUTPUT policy to ACCEPT in its own network
  namespace, sees only its inner Docker's chains there (no NetworkPolicy chain of the node's),
  and a direct `curl --noproxy '*' https://1.1.1.1` still fails (no connection): the rules that
  fence it live in the node's network namespace, which the pod does not share.

## Ports: tunnel by default, home network on request

- **Tunnel** (K8S-14): `aidc create --port H:C` and `aidc proxy <s> add` start a local
  supervisor per port (`scripts/k8s/tunnel-supervisor.sh`, a process the user sees in `aidc proxy
  <s> ls` and `ps`, logging to `~/.local/state/aidc/tunnels/<namespace>/`): it runs `kubectl
  port-forward` to the dev pod with the user's own cluster credentials on 127.0.0.1, starts it
  again when it exits, and restarts it when the dev pod's uid changes (a port-forward to a pod
  that is gone does not always exit by itself). Works from anywhere the user reaches the cluster.
  The declared ports are recorded on the dev StatefulSet's metadata (`aidc/ports`), so `aidc
  proxy <s> up` starts them on another machine (K8S-21) and `aidc status` lists them with this
  machine's tunnels; `aidc kill` stops this machine's, and a supervisor elsewhere stops by itself
  once the dev StatefulSet is not found for three checks running (a restart keeps it; a failed
  read is not "gone"). Measured 2026-11-24: the port answered on
  localhost, and again by itself after `aidc restart` replaced the dev pod.
- **Home network** (K8S-15, optional at create): `--expose <port>` makes a ClusterIP Service for
  the dev pod, an Ingress per port at `<session>-<user>.<domain>` (further ports
  `<session>-<port>-<user>.<domain>`), and a NetworkPolicy letting only the ingress controller's
  pods open those ports. The domain, the class, the certificate (a TLS Secret, a cert-manager
  ClusterIssuer, or the controller's default certificate) and the controller's namespace and pod
  labels come from the user's config (`kubernetes.ingress`), never the repo. No login by default;
  `--login` (ruled 2026-11-24: the developer's choice per session) generates a username and a
  password, prints them once, keeps only an htpasswd (apr1) hash in a Secret, and puts it in
  front of every page by the controller's own mechanism: a Traefik basicAuth Middleware, or
  ingress-nginx's auth annotations. Another controller refuses `--login` rather than serve the
  page without the login asked for. Which controller it is comes from `kubernetes.ingress.controller`
  or else the IngressClass's `spec.controller` matched exactly (`traefik.io/ingress-controller`,
  `k8s.io/ingress-nginx`), never the class's name (F5's NGINX controller also defaults to a class
  named `nginx` and ignores ingress-nginx's annotations); and create opens each page once
  without the login afterwards, removing the pages and failing unless each answers 401. A page name another Ingress already serves is refused. Needs
  DNS that points the domain's names at the ingress (a wildcard record); a phone reaches it over
  whatever network or VPN already reaches the cluster. `aidc kill` removes the Ingresses,
  Service, policy, login (and a cert-manager certificate made for them). Measured 2026-11-24 on
  the reference cluster (Traefik, its default TLS store holding the domain's wildcard
  certificate): from this machine on the LAN, a page with no login answered 200 by its name; one
  with `--login` answered 401 without or with a wrong password and 200 with the printed one; a pod
  in another namespace could not open the exposed port directly; after kill the name answered
  404.

## Claude: logins, account switching, history

### Login once per user

Each user's Claude logins are set up once in their area; every session uses them (K8S-16).
Fallback if sharing breaks: each session logs in on its own. Users bring their own secrets
(their GitHub login, `aidc git login`, and Claude accounts); the admin who runs `aidc user add <name>` never handles
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
| Git agent's question answered by `session_send` (Docker) | live check with a logged-in git agent (tests/smoke/README.md) |
| Git agent's question reaching an orchestrator on Kubernetes | owner ruling; aidc 2.0's per-user MCP server |
| A real push, PR, merge, tidy and protect through the git container | the smokes' GitHub part, with a login and a scratch repo |
| The Docker git container on macOS (volume ownership, the mount check) | live test on a Mac |
