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
`--network` ("Egress"), and the GPU on request. Built, not yet checked on the cluster: the
per-user MCP server ("Control plane") and the taint freeze ("Taint on Kubernetes"). Not built
yet: account switching, Syncthing; all of it ships in aidc 2.0 (owner ruling 2026-11-24). Owner rulings are
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
    ├─ transcripts (PVC)                    the transcript mirror the user's MCP reads (MCP-15)
    ├─ claude-config (PVC)                  every session's Claude config dir, a folder each (K8S-16)
    ├─ claude-broker (Deployment) + claude-accounts (PVC)  the user's Claude accounts ("Claude")
    ├─ git (Deployment)                     the git container: gitctl, the GitHub login (K8S-04..06; "Git")
    ├─ aidc-mcp (Deployment) + aidc-mcp-state (PVC)  the user's MCP server (K8S-07; "Control plane")
    └─ syncthing (Deployment) + syncthing (PVC)  the disk's .claude/projects <-> the user's machines, .claude-shared <- them (K8S-18)
```

The transcript mirror (MCP-15, Q-M3): each session's dev pod copies its Claude transcripts, and
its Claude Code hooks write their events (MCP-46), into `/var/aidc/transcript-out`, as on Docker;
there it is the session's own folder (`subPath: <session>`; the git agent's `git`) of one claim
per user, `transcripts`, which the user's MCP server mounts whole. Not a folder on the user's
disk, which Q-M3 first named: every session mounts the whole disk, so a mirror there would let a
session write another's transcripts and events; a pod mounts only its own folder of the claim,
as a Docker session mounts only its own folder of the MCP's state. A root init step makes the
folder, gives it to the session user (the git agent's to uid 2000), 0700, and empties its hook
events on every pod start, so the MCP never reads a Claude's state from the one before; the
session's hook writer keeps only the newest 200 events, and the MCP, whose mount is read-only,
removes nothing (MCP-46). The
claim is on the session class (a copy of what each home holds), made by the first `aidc create`
or `aidc git setup` that needs it and never applied over (`kubernetes.transcripts_size`, default
10Gi); it carries no session label, so `aidc kill` keeps a session's folder, as Docker keeps its.

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
or that the git container has not taken it (exit 1) when it still sits in `requests/`. The
stand-in also takes `-C <dir>` (2026-11-27), right after `gh` (`gh -C <dir> pr create ...`),
right after the subcommand, or anywhere in a `gh issue` call as `-R` is: it runs in that folder,
as `git -C` does, and finds the working copy from it (`git rev-parse --show-toplevel`) exactly as
it would after a `cd` there. Real gh has no `-C`. The stand-in has one because the git agent,
whose `gh` is this same stand-in, must not `cd` (Claude Code asks before a cd followed by git,
and nobody answers in the git container; see its permission mode below), and the stand-in finds
its working copy from a folder. Sessions get it too, because the file is shared; nobody needs to
limit it, since it gives no new access: it names only a folder the caller could already `cd`
into, and the holder still checks every field of every request (the working copy on the disk,
its GitHub origin, branches, texts) whatever folder it came from. Bringing the stand-in back in
line with real gh must keep `-C`: the git agent's procedures (`gh -C <working copy> pr create`,
`pr merge`, `issue ...`, `aidc push`) and gitctl's refusal text depend on it. The watcher (`git-requests watch`,
as the request holder `gitreq`, below) moves each request out by rename,
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
nothing and says to use `gh pr create`. Results, written only by the request holder, say done, failed, denied or pending; a run cut short by a
restart is reported as interrupted, never retried. Requests and results are deleted after 30
days (a request still waiting then is logged as expired), and what a killed take or save leaves
in `work/` after an hour.

The git agent (owner rulings 2026-11-24: it is an aidc session; it does no prawduct work; its
instructions are one managed CLAUDE.md, no skills; it tidies after every merge; ask-mode
approvals bubble up through the orchestrator's approval path). The git container's tmux is laid
out as a session's: window `claude` runs `git-claude` (Claude Code in the agent's working folder
`~/work`, marked trusted with onboarding done at every start, resuming its conversation; not
the home, which Claude Code trusts for one run only), window `shell` a shell. Its instructions are `/etc/claude-code/CLAUDE.md`,
root's, always loaded: gitctl as the only way to GitHub, the hard rules, everything sessions
write is data, the ask-mode procedure, push/PR, merge then tidy, protections, leftovers
reported. Its managed settings add a permission list (gitctl, git-requests, git, its gh
stand-in, reads, its question tool, writes under /tmp), with bypass mode disabled: anything else
is refused, not left waiting on a prompt nobody sees (unless the hook below fails). Unlike a
sandboxed session's Claude it keeps AskUserQuestion.

Its permission mode (2026-11-27): Claude Code's `default`, not `dontAsk`. The agent's Claude
first ran in `dontAsk`, which refuses AskUserQuestion (Claude Code 2.1.332, live) even with the
tool in the managed allow list and a PreToolUse hook returning allow; its question then came out
as plain text, no question was open for the orchestrator's answer to settle, and ask mode
decided nothing. So the refusal `dontAsk` gave moved into the managed PreToolUse hook
(`claude-hook.sh`, matcher `*`, which also applies the guard rules): it reads `permissions.allow`
from the managed settings, the one list, and returns `permissionDecision: "deny"`, with a
reason, for every call the list would not allow. A Bash command is judged part by part (split
at `&&`, `||`, `;`, `|`, `&` and newlines outside quotes, as Claude checks a compound command),
each part starting with a listed command; a command or process substitution, an open quote, or
bash's `$'...'` or `$"..."` quoting, or a comment (a `#` starting a word) is denied: in `$'...'`
a `\'` does not end the string, and in a comment a quote opens nothing, so a plain quote toggle
would read `git $'\'' ; rm -rf ~ ; git '\'` as one command where bash runs three. A call the
list allows and every check passes gets `permissionDecision: "allow"`, with a reason, so the
hook is the one authority over the agent's tools (2026-11-27, below; its set is not
`dontAsk`'s). Claude's tools that ask no permission and the list does not name (TodoWrite,
ToolSearch ...) get no decision, as `dontAsk` ran them; Read, Grep and Glob are named, and get
the allow. AskUserQuestion gets no decision either: its permission step is the question itself,
so an allow would answer it with nothing, while no decision on a listed AskUserQuestion opens
the real question. The hook matches rules as Claude does: an `Edit(path)`
rule covers every tool that edits files (Write, Edit, NotebookEdit, MultiEdit), and a
`Write(path)` rule matches nothing (code.claude.com/docs, permissions). The list's first
`Write(//tmp/**)` therefore allowed no write under `dontAsk`; it is `Edit(//tmp/**)` now.

The hook also denies, with guidance, calls the list allows that would trip Claude Code's own
safety prompts (2026-11-27): a `cd`, `pushd` or `popd` (alone or before other commands); an
unquoted glob (outside `ls`); a redirect to anything but `/dev/null` or an absolute path under
`/tmp`, or an input redirect from a pattern; a write, by redirect or file tool, to a protected
path (`.git/`, `.claude/`, shell rc files and the rest of Claude Code's list); and a command it
cannot parse (over 10,000 characters, or ending in an operator). Why: in the default mode Claude
asks before such a call whatever the allow list or a hook's silence says, and in the git
container nobody is there to answer, so the agent sits at `waiting_on_permission`. That is how
the live check stalled: the agent ran `cd <working copy> && git ...`, both parts listed, and
Claude asked before the cd. The denial's reason names what to write instead (`git -C <dir>`,
`gh -C <dir>`, absolute paths, `/tmp` files), so the agent corrects itself and goes on. The hook
allows explicitly what it has checked: at first it gave no decision on a listed call, leaving it
to Claude's own check of the same list, and that check still asked about listed calls, with
nobody there, three times live (Claude Code 2.1.332): the cd before git above; and
`git -C <worktree> log ...; git -C <worktree> diff --stat ...; gitctl protection <repo>`, a plain
"Do you want to proceed?" offering "allow reading from <worktree> from this project", since
Claude asks before reads outside its working folder. Under `dontAsk` none of these asked: it
refused them. A call off the list is still denied (`tests/unit/test-git-agent.sh`: with an
empty list the hook allows nothing, and each call it allows stops being allowed when the one
rule that carries it is taken off the list), and the safety shapes the hook models are denied,
not allowed past their prompt. But the allow set is not `dontAsk`'s. `dontAsk` refused every
listed call Claude would have asked about; the hook's allow skips Claude's prompt, so the
effective set is the allow list minus the shapes the hook models. A shape Claude prompts on
that the hook does not model, including one a later Claude Code adds, now runs where `dontAsk`
refused it, and nothing waits at `waiting_on_permission` to show it. The shapes it models come
from the Claude Code documentation it cites (permissions: "Read-only commands", "Compound
commands", "Redirections"; permission modes: "Protected paths") and change with Claude Code, so
they are checked again on each upgrade of the image's Claude: the hook records the version they
were last checked against (`SHAPES_CHECKED_ON`, 2.1.332), and logs every allow, one line each
(UTC time, the tool, the rule or rules that matched, the call cut to 200 characters, that
version), to `~/.cache/gitctl/hook-allow.log` in the git container (the agent's home, beside
the request watcher's `requests.log`; past 1 MiB kept as `hook-allow.log.1`, one older file).
The operator reads it from the container's shell window (`aidc git attach`) or by exec, and on an
upgrade checks it for calls the new Claude would have asked about. It is the agent's own file,
an aid for that check, not a tamper-proof audit (gitctl's action log is that). The set is also
narrower than `dontAsk`'s in one place: `Bash(cd *)` was on the list and has left it, and must
not return (the git agent never changes folder; `gitctl/CLAUDE.md` says so, and the hook
refuses one). None of this is the git agent's security. `Bash(git *)` already runs any command
as the agent (`git -c core.fsmonitor=<cmd> status`, an alias with `!`, `core.hooksPath` pointed
at a file written under `/tmp`), as it did under `dontAsk`, and the user's disk is writable to
it. The agent's security rests on two things only: it holds no credential, and gitctl, the one
way to the GitHub login, checks every request itself (the request holder deciding, out of the
agent's reach). The allow list, the hook and the instructions are courtesies that keep the agent
from stalling or erring, not a boundary. The git agent's Claude is given no `--add-dir`:
Claude Code 2.1.332 asks about a folder added that way that it has not worked in ("Adding a new
directory: ... Is this a directory you created or one you trust?"), and that prompt stopped the
agent before it started, with no one there (live, 2026-11-27); the hook's explicit allow already
covers reads outside its working folder (Read, Grep, Glob and checked Bash). The MCP names that
screen as the first-launch dialog `add_dir_prompt` (design-10), should a Claude show it. When
the hook itself fails (a crash, a non-zero exit other than 2, or its timeout), Claude Code
treats it as a non-blocking error and the call goes on through the normal permission flow
(code.claude.com/docs, hooks: "staying silent doesn't approve it"): in the default mode a
listed call runs or asks and any other asks, so aidc shows the agent `waiting_on_permission`. A failed
hook never runs a call the list does not allow; it can only leave one waiting. Input the hook
cannot read, or a list it cannot read, blocks the call (exit 2). The Deployment carries the reserved session label `aidc/session: git`
(not in its selector), so `aidc list` shows it, `aidc attach|logs|status git` reach it
(`aidc git attach` is the same attach), `aidc create git` is refused (its claims would collide
with the git container's) and `aidc kill git` refuses it. A home seeded before Claude Code
moved on gets the image's Claude at each start (init step `refresh-claude`, as the git user:
the image's version file copied in and linked when the home's is older; a newer one the home
updated to itself is kept); the managed files are the image's, so they are always current.

Approvals out of the agent's reach (owner ruling 2026-11-26, refining Q-K8 and the 2026-11-23
"approve in its terminal" ruling). The git agent's Claude and everything it runs share uid git,
so anything shown or typed in its terminal, and any file, variable or argument git can read, is
the agent's too: a one-time code in its question could not bind an approval. So the agent
decides nothing. A user of its own, `gitreq` (uid 2003, in the session group), holds and
decides requests: the request folder (`requests/`, `results/`, `work/`, and `state/` with the
session modes, the protection markers and the watcher's lock) is its, and gitctl runs the verbs
that change GitHub (push, pull request create, comment and merge, protect) only when the caller
is gitreq, on the agent's side and again as gitrun and gitcred, where the caller is the user sudo
names (it sets `SUDO_USER` from the real uid; the agent, and gitwc on Docker, are refused). git
reaches gitreq through one sudo rule naming the verbs that read (`list`, `show`, `prompt`), hand
a request over (`handoff`, `handed`) and start the one watcher (`watch`; a second leaves at once,
`state/watch.lock`). `approve`, `deny`, `mode`, `register`, `forget`, `sync`, `first-use` and
`pr-base` run only as gitreq reached directly, never through sudo: by the user's `aidc git
approve|deny|mode|push|pr|merge|protect` (Docker: `docker exec -u gitreq`; Kubernetes: `kubectl
exec` into the git pod's own `gitreq` container, since kubectl exec cannot choose a user), or by
the MCP server carrying out an orchestrator's answer the same way. The holder's settings (the
request folder, the disk, the user's mode) come from a file mounted read-only
(`/etc/aidc/git-settings/settings`: on Docker written by `aidc git setup` under
`~/.config/aidc/git-settings`, on Kubernetes the `git-settings` ConfigMap), since sudo drops the
environment and nothing in the container may change a mode. On Docker the container's main
process starts the watcher through its sudo rule (`AIDC_GIT_WATCH_HERE=1`); on Kubernetes the
`gitreq` container runs it. A request folder the agent held before (uid 2000) is given to the
holder with its contents by setup's root step; the session modes start again from the user's
(setup's `sync` registers every session).

The agent asks; the user decides outside. Every push, pull request and merge is a request,
including those the user asks for in the agent's terminal: the agent's `gh` is the sessions'
stand-in, its requests carry no session token, so they always wait. In ask mode the holder
cannot type into the agent's tmux (it is git's), so the container's main process asks it every
2 seconds which request to hand over (`git-requests handoff`: the oldest waiting one not handed
over yet, and none while a request the agent may be asking about still waits), pastes one line
naming only the id into window `claude` when Claude runs there and is set up (`git-notify`;
never into a shell or Claude's first-run screens), then says so (`handed`). The agent runs
`git-requests prompt <id>` (the session's text below a line, marked as data) and asks with
AskUserQuestion, naming the request id, Deny first; aidc delivers that question to an
orchestrator as any session's. Once it is answered, the agent reads the request's actual
result (`git-requests show <id>`) and reports only that, never a guess (live 2026-11-27: after
an orchestrator's answer it guessed the decision "probably" carried out). A decided request it
reports as shown, naming no command; one still pending it reports as waiting, and names
`aidc git approve <id>` / `aidc git deny <id> "<why>"` for the user to run on their machine,
outside the agent's reach (owner ruling 2026-11-26): choosing Approve in the question approves
nothing by itself, so an answer at the terminal, or an orchestrator's answer that was not
carried out, leaves it pending. The Approve option reads "Carry out this request (decided
outside the agent: by the orchestrator, or with aidc git approve)", true for both readers. It checks the repo's
protections (`gitctl protection`) for every request, never reusing an earlier check. An orchestrator's answer is carried out by the MCP
server, as gitreq, matched to the request id in the question (design-10 S10; on Docker built
with plan chunk 13's fix round, on Kubernetes plan chunk 14). The one request the agent may be asking about is the one last handed over or the one
it last ran `prompt` for; after a watcher start, when which one is open is not known, it is every
request then waiting, until each is decided or the agent runs `prompt` for one.

The git agent's Claude Code runs aidc's hooks as every session's does (MCP-46/47): its managed
settings add SessionStart, Stop, Notification and UserPromptSubmit, each running
`/usr/local/bin/aidc-hook-event` (the sessions' writer, copied into the image), which writes the
event as the agent into `/var/aidc/transcript-out/hook-events`, the mirror aidc's MCP server
reads for the session `git`. On Docker that is the mounted transcript folder; on Kubernetes the
agent's folder (`git`) of the user's transcript mirror claim ("Shape", below).

GitHub issues (GIT-07; owner rulings 2026-11-26, Q-G1) go through the git container as an
issue-scoped API passthrough, not as a general one. `gitctl api <method> <path>` passes a call
to GitHub's REST API only when it is a row of one table (`GITCTL_API_TABLE`,
`gitctl/gitctl-rules.sh`): the issue, comment, label, sub-issue, dependency and timeline
endpoints prawduct's backlog calls through `gh api`, plus `GET user` and `GET branches/{b}`;
each path part of its shape (an issue number, a URL-encoded label with no encoded dot, a branch
name git accepts), only the query keys the row lists, and a write's JSON body of only the row's
keys, typed, compacted, with no AI attribution and no control characters. Its repo must be one
the user added, checked again as gitcred. The conditional read is kept (`--include`,
`--if-none-match`, gh's exit 1 on a 304, its headers on stdout). There is no row to delete,
transfer or lock an issue. Reads are the agent's too; writes run only for gitreq (WRITE_VERBS).
A session's `gh api` and `gh issue list|view|create|edit|comment|close|reopen` are `api`
requests the holder checks and runs at once in every mode, never waiting for approval; the
result carries gh's stdout, stderr and exit status, which the stand-in gives back as gh would.

Residuals of the git agent, recorded rather than closed:

- Its allow list is a courtesy, not a boundary. `Bash(git *)` lets it run any command as the git
  user (uid 2000), for example through a git alias; what stops it reaching GitHub other than
  through gitctl is that its own git has no credential and gitctl and the watcher check every
  action, not the list.
- Closed 2026-11-26: it cannot approve a request, or push, open or merge a pull request outside
  one. Approvals and those verbs are the request holder's (gitreq), which git cannot act as
  (above). Left to it: `gitctl tidy`, whose `delete-branch` deletes only a branch GitHub has
  merged (not a base), and `gitctl logout`.
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
  volume at `/var/aidc/git-requests`, the request holder's (2755, session group); a session created after
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
come back by `session_send` or from the user in the terminal. Refined 2026-11-26 (approvals out
of the agent's reach, above): the answer no longer approves through the agent. The user's answer
is `aidc git approve|deny <id>` on their machine, which the agent names when the request is
still pending after its question; an orchestrator's answer is carried out
by the MCP server as gitreq (`git-requests approve|deny <id>` by exec as gitreq, which acts only
on a request still waiting), matched to the request id the question names. Where the question's
delivery stands (2026-11-24):

- Docker: the git agent's transcript reaches `aidc mcp` (above), so an orchestrator that watches
  the session `git` gets the question as that session's reply, and answers it with
  `session_send` "Approve" or "Deny: <why>": the MCP server runs `git-requests approve|deny`
  as gitreq for the one waiting request the question names, then sends the answer into the
  question (design-10 S10). Whether the question widget takes the pasted answer is checked by
  hand with a logged-in git agent (tests/smoke/README.md); the decision does not depend on it.
- Kubernetes: the question does not reach an orchestrator yet. The MCP server's session tools
  reach cluster sessions only through the per-user MCP server (K8S-07). Owner ruling 2026-11-24
  ("aidc 2.0 is the Kubernetes work and the 3tears adoption, released together"): the Kubernetes
  backend ships only in 2.0, with that server, and 2.0 must route Kubernetes git approvals
  through the orchestrator before it ships. Until then the user answers with `aidc git
  approve|deny`.
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
kubeconfig, which is renewed in place: in a file that holds other clusters' contexts too, only
this user's context, user and cluster entries change and every other one is kept; a file
there that is not a kubeconfig is refused, never replaced); `--revoke` (admin) replaces the ServiceAccount, which
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
- **Digests recorded where the build ran.** A pull happens only when a pod is made, and a
  Deployment that names the same tag applies unchanged, so a long-running pod keeps an image
  rebuilt under it. `aidc k8s build` records the digest each image was pushed as (`docker image
  inspect` in the builder, after the push) in `~/.local/state/aidc/k8s-images`, one line per
  cluster (its API server URL, which the builder's kubeconfig and a user's share) and image; a
  digest it cannot read removes that image's line rather than leave an old one. The record is
  on the machine, not in the cluster: users have no read access to the system namespace, and the
  registry is reachable from inside the cluster only. `aidc mcp start` uses it (below, the MCP
  server's image). The broker and the git container are restarted on start or setup whenever
  their Deployment applies unchanged instead: neither is a connection the orchestrator holds,
  and an unconditional restart also takes an image built on another machine.

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
- the policy sidecar's taint webhook is the one allowed path to the user's MCP server: the proxy
  pod may reach the server's pods, and its Service address, on the webhook port (7879) only,
  and the server lets the user's proxy pods in on that port only. Squid refuses private
  addresses, so nothing a session asks for reaches it ("Taint on Kubernetes", below);
- `--egress-tcp HOST:PORT` (NET-15) becomes a socat relay pod per host with a ClusterIP Service
  and an egress rule for exactly that `/32:port` (below: "TCP egress relays"); its name resolves
  through the session's names responder, not `hostAliases`, so `aidc egress add` never restarts
  the dev pod.

### Taint on Kubernetes: the webhook and the freeze

The policy sidecar writes the taint flag on the session's state claim, as on Docker (SEC-02).
It has no API token, so it cannot pause or cut anything itself; the user's MCP server does
(plan-aidc-2.0 Q-K3, W-M4, W-K4):

- **The poke (K8S-13's one exception):** on the first taint the sidecar POSTs
  `{"session": "<name>"}` to `http://<the server's Service address>:7879/taint`
  (`AIDC_TAINT_WEBHOOK`, set at create; the proxy pod has no cluster DNS). The server's own
  Service is made by the first `aidc create` when missing and kept by `aidc mcp stop`, so the
  address a session holds stays good. The port serves nothing else and logs every request; a
  poke carries no token and is never trusted: it only says which session's flag to read.
- **The server acts:** it reads the flag itself (exec into the policy sidecar), logs the taint
  once and tells subscribers (`resources/updated`). When the session's response is `freeze`
  (the default, SEC-08), it cuts every egress rule of the session's NetworkPolicies (the dev
  pod's, the proxy's, its relays' and `--network` ones: each becomes `egress: []`, keeping
  what it lets in), so under the namespace's default-deny none of the session's pods reaches
  anything, and writes `/var/state/frozen` beside the flag. The dev pod keeps running (exec,
  `aidc attach` and the audit trail still work), as Docker's pause keeps the container.
- **Never cleaned (SEC-06):** a policy a later apply opens again (a re-render) is cut again;
  `aidc egress add` and `aidc network add` refuse a tainted session, and one whose taint
  cannot be read.
- **A missed poke:** the server looks at every session's flag at start and every minute, so a
  poke lost while it was down or restarting is made up for within that bound.
- **`aidc status`** says `freeze: FROZEN <mark>` once done, `PENDING` while the server has not
  done it (it is not running, say), or the session's other response.

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
  that is gone does not always exit by itself); a read of the pod that fails is not a change,
  and the forward is kept. Each tunnel's log starts fresh with its supervisor (the one before
  kept once), is capped while it runs (`AIDC_K8S_TUNNEL_LOG_BYTES`, 1 MiB, then one older
  copy), and goes with the tunnel: `aidc proxy <s> rm|clear`, `aidc kill`, and the supervisor
  finding the session gone delete it. Works from anywhere the user reaches the cluster.
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

As built (Q-K1, owner ruling 2026-11-26): `aidc claude account add <name>` starts the user's
broker (`claude-broker`, image `aidc/broker`) when it is not running and runs Claude's own login
in it (`claude auth login --claudeai`, the account's own config dir as `CLAUDE_CONFIG_DIR`, on
this terminal through `kubectl exec -it`): the user opens the link, signs in, pastes the code.
The login, refresh token included, stays on `claude-accounts`, a claim only the broker's pod
mounts (the user's retained class). `account list | use | remove` reach the broker the same way.

Where a session's Claude config dir lives: its own folder of one claim per user,
`claude-config` (`subPath: <session>`, mounted at `/home/vscode/.claude`, the path
`CLAUDE_CONFIG_DIR` always named), which the broker mounts whole. A folder of the home claim
would not do: the broker would have to mount every session's home, and a `.credentials.json`
symlinked to a broker-written file is refused (Claude Code 2.1.332 reads it as
"refused-symlink"). The proxy pod's first step makes the folder (root: owner 1000, 0700), before
any pod mounts it; the dev pod's `claude-seed` step fills a new one once, as the session user,
from the Claude config the home already had, else the image's; then, when that left no
`.claude.json`, from the state seed `aidc create` put in the session's audit-seed ConfigMap
(Docker's filtered copy of the machine's own, else empty, with onboarding done and the start
folder trusted: owner ruling 2026-11-27, cluster sessions trust their start folder), so the first launch goes straight to the prompt. The
machine's file names the project by the machine's path (a Mac's `/Users/<name>/x`), the session
by the cluster's (`/home/<user>/x`): the entry is picked by the one and moved to the other. The
seed's key is not in the proxy pod's mount of that ConfigMap (its seed-audit step sees only the
audit record's two first files). A session launched with bypass (claude_mode `yolo`, the
default, or `bypassPermissions`) also skips the bypass-permissions warning: the entrypoint sets
`skipDangerousModePermissionPrompt` in its managed settings, a settings key, so it is not
`.claude.json`'s to carry, and it follows the mode on every start (the mode is the user's
consent to bypass; the same ruling). The git agent's is the folder
`git` (owner 2000, group 1000, 0770: the broker writes its credentials as group 1000, of which
the git user is a member), filled from its home's Claude config with its own history.
`aidc kill` removes a session's folder (the broker's `forget`, or a one-shot pod when no broker
runs).

`projects/` (conversations, memory) is the user's disk's `.claude/projects`, mounted over the
folder's (Q-K2), so two sessions in one repo share its history folder. What reads a session's
conversations still reads only its own, and a session writes only its own: its aidc-claude
resumes the newest conversation its own Claude wrote, by id (`--resume`), never `--continue`,
which would take the newest there, another session's, and append to it; a new session starts
a new one. Likewise: the hook writer keeps `own-transcripts` (the file names
of the transcripts its Claude's hook events name) in the session's mirror folder, the mirror
copies only those on Kubernetes, and the audit sidecar takes its Claude transcripts from that
mirror folder (read-only) rather than the shared folder. The MCP, which reads the mirror, never
follows another session's conversation.

Until an account is added (the ruling's stopgap): a session logs in itself, or, when the user
stored a one-year inference token with `aidc claude-token setup` (`claude setup-token`), a
session created with no broker running gets it as `CLAUDE_CODE_OAUTH_TOKEN` from a Secret of its
own (`<session>-claude-token`, made from stdin, removed by kill; the user's credentials cannot
read Secrets back). With a broker running no token is handed on: the variable would override the
broker's credentials. The user's MCP server never hands one on (the token is a file on the
user's machine).

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

As built (`broker/claude-broker.sh`, a pass a minute): every token handling is Claude Code's own
(main, 2026-11-26: aidc never presents itself as Claude Code to Anthropic's OAuth endpoint).
An account whose access token is within an hour of expiring is renewed by running Claude Code in
its folder with the cheapest call that refreshes: `claude auth status` only reads the stored
login (read from Claude Code 2.1.332), so a one-word prompt to the smallest model, with no
tools, MCP servers or slash commands, no session kept. Claude writes the renewed login back
there; the broker copies it, without the refresh token, into every session's folder whose copy
differs, with the account's name (`.aidc-account`) and any notice for the status line
(`.aidc-notice`). A failed renewal is recorded with Claude's own words, shown by `aidc claude
account list` (RENEWAL FAILING) and in the sessions' status line, and tried again in Claude's
own refresh window (below, "Crediting usage, limit events and renewal"). A
session's own login (a `.credentials.json` the broker did not write) is replaced only while the
broker has an active account; with none, it is left as it is.
`aidc claude broker start` restarts a broker whose Deployment applied unchanged, as `aidc git
setup` does the git container: the image tag is aidc's version, so an image rebuilt under it
(`aidc k8s build --force`) is pulled only by a new pod. The accounts are on their claim and
survive it.

Switching, as built (K8S-17): the order is `claude_accounts` (accounts not listed come after, by
name), each with `switch_at` (default 90); `claude_account_switch: auto|wait` (default auto).
In a cluster session the managed settings run the status line through `aidc-claude-usage`, which
leaves `rate_limits.seven_day` (used percentage, reset time) in the Claude config dir
(`.aidc-usage.json`) and then prints the user's own status line (their `settings.json`
statusLine, its `~/.claude/` or `/Users/<name>/.claude/` path made the session's) and the
broker's notice; a `StopFailure` hook with matcher `rate_limit` leaves `.aidc-limit.json`. Each
pass, a fresh report (half an hour) counts for the account the broker gave that session; the
active account is spent when its usage is at its threshold and its week has not reset, or a
session hit its rate limit in the last hour. Then the next account of the cycle that is not
spent becomes active, at once (auto) or waiting for `aidc claude account use <next>` (wait;
the list shows `> waiting`, the status line the command). An account whose access token
expired while its renewal keeps failing is spent too (its login ended), and the switch from it
never waits (main, 2026-11-26). With every account spent it stays, and every session's status
line says so: that every account's login ended (`aidc claude account add <name>` again for
each) or that every one is at a limit. `aidc claude account list` gives each spent account's
reason; the broker's log (`aidc claude broker logs`) says each account's change of state once.
An orchestrator sees it too: the session's status line leaves the account and the notice in
its mirror folder (`claude-account.json`), which the user's MCP server gives as
`session_status`'s (and `session_list`'s) `claude_account`.
The git agent's Claude reports its rate limits the same way (its managed settings' StopFailure
hook).

The broker writes into the session's Claude config **directory**, which the session pod mounts as
a whole directory (on the user's volume). Never a single-file mount (a `subPath` naming a file included), or a Secret
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
refresh token. The broker must replace it first; it is the broker's main job. It renews an hour
before expiry; the live test (hours) is the plan's chunk 18.

Fallback if the broker breaks: one config directory per account, and switching restarts Claude
with `--resume <session>` (seconds of downtime, cold prompt cache).

Jean-Claude (profiles `~/.claude-<name>`) was assessed: it shares settings, hooks, agents and
skills across profiles and syncs settings through git, but does no credential switching, and
conversations do not follow across profiles (confirmed by a user of it). We may reuse its layout; we do
not depend on it.

### Crediting usage, limit events and renewal (amended 2026-11-28)

The live switch test (2026-11-28) found three faults, fixed in the shared program and status line
so both backends have the fixes (K8S-17 as amended):

- **Usage is credited only to the account whose credentials produced it.** Claude's status line
  shows the numbers of its last API call. A new session whose first call hit `main`'s weekly
  limit was switched to `second` in seconds, and its status line, with no earlier report to
  compare with, reported `main`'s week as `second`'s, so `second` was marked at its threshold.
  Two guards now: `aidc-claude-usage` writes no report when the transcript's newest assistant
  entry (a failed call's error included) is no later than `.aidc-account`'s time, the moment the
  broker named the account (where the transcript cannot be read, the earlier rule: the previous
  report's numbers under a new name are dropped); and the broker counts no report whose week
  (its reset time) is another account's and not the named account's own.
  The status line does not show those numbers either (amended the same day: it showed
  `week 100% [second]`, `main`'s week under `second`'s name, until the next call): they are
  left out of what it prints and of the input the user's own status line gets, until the new
  account's first call brings its own.
- **A limit event is authoritative.** The `StopFailure` hook now says which limit was hit
  (`kind: weekly` when Claude's words name the weekly limit, else `rate`). A weekly limit makes the
  account's usage 100% (source: limit) and keeps it spent until its known reset time (else an
  hour); any other rate limit, an hour, as before. `aidc claude account list` shows each usage
  number's source and age (`usage 70% (status line, 6h ago)`), so a stale number is not trusted
  blindly; `--json` carries `usage_source`, `usage_at`, `usage_age_s`.
- **Renewal before Claude's own window is not a failure.** Claude Code refreshes a token only in
  its last minutes (seen 4.5 minutes before expiry), so with the hour's margin the broker ran a
  prompt a minute for 55 minutes and logged each as `could not renew main: ok`. Now a prompt that
  succeeded and left the token as it was is logged once as "renewal not due yet" and the next try
  waits until four minutes before expiry (`BROKER_CLAUDE_WINDOW_S`, 240); inside that window
  every pass tries, and a prompt there that still did not refresh is a failure, recorded and
  shown as RENEWAL FAILING. An hour's margin costs two prompts.
  Amended the same day (the live test's account at its weekly limit): Claude refused the
  renewal prompt ("You've hit your weekly limit"), and the broker called that a failure and
  tried again every minute. A renewal is now judged by the stored token, never by Claude's
  exit: Claude Code refreshes before its call, so a token whose expiry moved on (or is beyond
  the margin) is renewed even when the prompt was refused. Before the window, a prompt refused
  for a usage limit (the weekly limit read with the `StopFailure` hook's own pattern) is not
  due yet, as a prompt that ran well; any other failure there is recorded, and its next try
  too waits for the window. Inside the window a prompt that left the token unrenewed, whatever
  it said, is a failure (a login that ended is still reported). A recorded failure clears on a
  later renewal, or when the broker finds the token renewed already.

`--help` (or `-h`) on any `aidc claude account|broker` verb prints the help on both backends; it
was passed to the broker as an account name.

### The broker on Docker

Owner ruling 2026-11-28 ("Account switching on Docker too"; K8S-27, K8S-28): the broker and
switching work on Docker as in a cluster. The same `aidc/broker` image and `claude-broker`
program; the difference is the Docker glue (`scripts/docker/broker.sh`, `scripts/docker/claude.sh`):

| | Kubernetes | Docker |
|---|---|---|
| broker | Deployment `claude-broker` in the user's namespace | container `aidc-claude-broker`, one per machine user (a Docker daemon serves one user's aidc, as `aidc-git-dev` does), `--restart unless-stopped` |
| accounts | claim `claude-accounts`, only the broker mounts it | volume `aidc-claude-accounts`, only the broker mounts it |
| sessions' Claude config dirs | claim `claude-config`, `subPath: <session>` | volume `aidc-claude-config`, a volume subpath `<session>` at `/home/vscode/.claude` (compose `volume: {subpath: ...}`) |
| settings | ConfigMap `claude-broker-config` | `config.json` copied into the container when it is made (`aidc claude broker start` makes it again) |
| network | NetworkPolicy: no way in, out to Quad9 and public 443 | a bridge of its own (`aidc-claude-broker-net`), Quad9 DNS, nothing published, `--cap-drop ALL`, no-new-privileges |
| reaching it | `kubectl exec` | `docker exec` |

The one settings function both backends use is `aidc_claude_broker_config_json`
(`scripts/lib/config.sh`). The volumes are readied by a one-shot root container from the broker
image with no network and only `CHOWN`/`FOWNER` (both the broker's uid 1000, 0700). Names are
volumes, never host paths, so `aidc create` run by aidc-mcp's container (session_create) resolves
them in the daemon's namespace as the CLI does.

Docker's network is looser than the cluster's NetworkPolicy: the broker can reach the LAN. It runs
no agent: Claude Code only for the user's own login and for a fixed one-word prompt with no tools,
MCP servers or slash commands; nothing connects in. The sessions' sandbox is unchanged.

**Which sessions use it.** A session made while the broker runs (`dk_claude_session_ready`):
the broker makes its folder and writes the active account's credentials (`claude-broker session
<name>`) before the session starts; its compose file mounts the folder over dev-home's
`.claude`, declares the volume external, sets `AIDC_CLAUDE_BROKER=1`, and hands on no long-lived
token (it would override the broker's credentials). The entrypoint then installs the managed
settings' `broker` form: the status line through `aidc-claude-usage` and the `StopFailure`
rate-limit hook, nothing else of a cluster session's (no lease: its history is its own). The
compose file is the session's record, so restart and upgrade keep the choice. A session made while
no broker runs (or while it did not answer) keeps its Claude config dir on dev-home: its own
`/login`, or the long-lived token. Sessions made before keep theirs; nothing about a running
session changes. The host's `~/.claude` is never written; the broker's refresh tokens never leave
`aidc-claude-accounts`.

**Switching** reaches running broker sessions as in a cluster: the broker writes each folder by
rename; Claude reads the new credentials on its next message, conversation kept.

**`aidc kill`** removes the session's folder: the broker's `forget` (under its lock) when it runs;
else, or for what the broker cannot remove (a mountpoint Docker made root-owned for a nested
mount), a one-shot root container from the broker image with no network and only
`DAC_OVERRIDE`. Never fatal. A create that fails after the broker made the folder and before compose was asked to
start the session forgets it itself (its exit trap, `dk_claude_create_cleanup`); once compose was
asked, the kill of what it left does.

**Docker Engine 26 or later** mounts a volume subpath; on an older engine a session, and the git
agent, keep today's way and `aidc create` says why.

**The git agent** (`dk_git_start`, at `aidc git setup`): when the broker runs, or the git container
it replaces already had it (once moved it stays, so its history follows), its Claude config dir is
the folder `git` of `aidc-claude-config`, made as root (owner 2000, group 1000, 0770: the broker
writes the credentials as group 1000, of which the git user is a member) and filled once, as the
agent, from its home's `.claude` with its history (`.aidc-seeded`); the broker writes its
credentials before the container starts, and no token is handed on. The gitctl image's managed
settings already carry the rate-limit hook. A broker started later reaches the git agent at its
next start; `aidc claude broker start` says so.

**Images.** `aidc claude account add` and `broker start` build `aidc/broker` when missing (as
`ensure_image` does for any image); `aidc rebuild` rebuilds it where its accounts' volume exists,
with a fresh Claude Code. The dev image carries the `broker` form of the managed settings and the
amended `aidc-claude-usage`.

The weekly-or-rate classification of a limit reads only the hook's error and message fields,
never its paths (a repo named "weekly-report" says nothing about the limit).

**The audit trail** of a broker session holds its Claude conversations as any other session's
does. Its audit sidecar reads them where the session's Claude writes them: the session's folder of
`aidc-claude-config`, mounted read-only at `/var/aidc/claude-config` (the whole folder, as
dev-home is mounted whole: its `projects/` may not exist yet, and a volume subpath must), with
`AIDC_AUDIT_CLAUDE_PROJECTS` naming its `projects/`, as the cluster's names its mirror folder;
for any other session compose names dev-home's `.claude/projects`. What reaches the trail is
then the same for both: with the memory bridge on (the default) the repo's history folder is the
host's, bind-mounted over the config dir inside the dev container only, in either kind of session.
Everything else that reads `~/.claude` runs inside the dev container and sees the broker's folder
there: the memory bridge's mount nested in it (its mountpoint claimed by the entrypoint), the
transcript mirror, the MCP's `session_mcp_set`. A broker session made before this keeps an audit
sidecar that reads dev-home's until `aidc kill` + `aidc create`.

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

As built (chunk 19; Q-K11: the user's own machines only):
- **Two folders, two directions** (`scripts/lib/claude-sync.sh`). `aidc-claude-projects` is the
  conversations and memory (a machine's `~/.claude/projects`, the cluster disk's
  `.claude/projects`), both ways, under the lease. `aidc-claude-shared` is the Claude files a
  Claude loads, `CLAUDE.md`, `rules/`, `skills/`, `agents/`, `commands/` and `keybindings.json`
  (a machine's `~/.claude`, Send Only; the cluster disk's `.claude-shared`, Receive Only): from
  the user's machines to the cluster only. The 2026-11-24 ruling sent `settings.json` one way
  because it carries hooks that run code on the machine that receives it; skills, agents (their
  hooks and scripts), commands, rules and CLAUDE.md are the same kind of thing, so they go the
  same way: a sandboxed session must never write what an unsandboxed Claude on the user's
  machine loads. Sessions mount `.claude-shared` read-only over the disk, and a change made to
  it in the cluster (the git agent, which mounts the disk) is a Receive Only folder's local
  change, never sent. `settings.json` and the status line go by `aidc sync push-settings`
  (laptop to cluster, not Syncthing, the machine's own aidc hooks left out): the template becomes
  a new session's `settings.json` once; the status line script stays in `.claude-shared`, where
  `aidc-claude-usage` runs it from (`AIDC_SHARED_CLAUDE`). What still flows from the cluster to
  the machines is `projects/` (transcripts and memory); see docs/security-model.md.
- **The pod** (`aidc sync start`, `scripts/k8s/sync.sh`): `syncthing` in the user's namespace,
  the pinned official image, as uid 1000, read-only root, no API token, no DNS. aidc writes its
  whole `config.xml` from `sync.peers` on every start (the two folders; global discovery, local
  announcements, relays, NAT traversal, usage and crash reports off; the GUI on its loopback
  only), so what the config says wins. Its NetworkPolicy lets nothing in and lets it out to each
  peer's address and port only; a peer whose address is public is refused (a name is resolved on
  the user's machine, as a relay's is). Its key and certificate, its identity to the user's
  machines, are on its own claim (retained class). `aidc sync status` gives its device ID for
  pairing, and asks Syncthing itself (its REST API on the loopback) whether each peer is
  connected and each folder in step or in error.
- **A machine** (`aidc sync setup [--hooks]`): the two `.stignore` files, a Mac's aliases, and
  with `--hooks` aidc's hooks in `~/.claude/settings.json`, as the stable `aidc sync lease-hook`
  and `aidc sync reconcile --hook` (the `aidc` on PATH, never a versioned install path); a re-run
  replaces aidc's own entries, an older install path's included.
- **Sessions** link the shared files into their Claude config dir each start (a file of the
  session's own by that name is left as it is).
- **The lease** (`.devcontainer/claude-lease.sh`): `<project>/<session id>.aidc-lease`
  (`{machine, until_s}`, the holder's clock), synced with the transcript; taken at
  SessionStart, renewed for 15 minutes at each prompt, each tool call (a turn longer than the
  lease time keeps it) and each turn end, let go at SessionEnd. A prompt to a conversation
  another machine holds is refused (the hook's exit 2, the reason shown); a cluster session's
  `aidc-claude` resumes only its own conversation, and not one another machine holds. Cluster
  sessions run it from their managed settings (machine `cluster/<session>`), a machine from its
  own settings. In a cluster session a prompt goes through the lease before the hook-event
  writer (`--then`): one that goes through is recorded as its UserPromptSubmit, a refused one as
  a `PromptRefused` event naming the holder, in the same sequence. aidc-mcp takes the newest
  event name before pressing Enter and reads what follows it, so no clock of its own is compared
  with the pod's: on a refusal the paste has not landed (nothing recorded, the prompt kept
  queued, `waiting_reason: "conversation_held_elsewhere"`), and the queue tries again a minute
  later by its own clock, going in once the other machine has let go. Syncthing carries a lease
  in seconds, so two machines starting the same conversation within that moment are not stopped;
  a lease is the common case's guard, not a lock.
- **The Mac's aliases** (`aidc sync reconcile`, and the SessionStart hook there): each
  `-home-<user>-...` folder gets a `-Users-<name>-...` symlink; a `-Users-` folder Claude made
  with no Linux one yet is moved to the Linux name and aliased; dangling aliases go; a name
  both have is left, said. Windows junctions are not built (native Windows is a bonus; WSL has
  the Linux layout).
- **#35, a symlink in synced memory:** Syncthing carries a symlink as a symlink, which on the
  receiving machine points at whatever that path is there. The lease's SessionStart (both sides;
  through a Mac's alias too) and `aidc sync reconcile` remove every symlink inside a
  conversation's folder; the top-level aliases are not inside one.

## Control plane

One aidc MCP server per user, in that user's namespace, so sessions run and replies arrive while
the laptop sleeps (K8S-07). The user drives sessions from any of their machines with the same
`aidc` commands; a session created from one machine can be attached from another (K8S-21).

Sessions come back on their own after a node reboot, with files, branches and conversation
intact, and Claude resumes where it left off (K8S-22).

### The user's MCP server

`aidc mcp start|stop|status|logs|token rotate|token show` with the kubernetes backend
(`scripts/k8s/mcp.sh`; the manifests are `scripts/k8s/manifests.sh`, "The user's MCP server")
run the same server as Docker's aidc-mcp, from the same image, as one replica in the user's
namespace (TRS-23, MCP-02/03 as amended):

- **Image:** `aidc/mcp` carries the CLI (staged into its build context as `aidc/`), `kubectl`
  and `yq`; the Docker server mounts the host's CLI over the baked one.
- **Identity:** the `aidc-mcp` ServiceAccount (K8S_MCP_RULES: the session lifecycle in this
  namespace only), its token mounted, because the server runs kubectl. Its environment says the
  backend and the namespace (`AIDC_MCP_BACKEND=kubernetes`, `AIDC_K8S_NAMESPACE`), and its CLI
  calls pass `--backend kubernetes`.
- **State:** its store, watermarks and access log on its own claim, `aidc-mcp-state` (the
  user's retained class), Recreate and one replica, since one process holds a store.
- **Transcripts:** the user's mirror claim, mounted whole and read-only. Its files are 0600 and
  owned by each session's user (the git agent's is uid 2000), so the server runs as root with
  only `DAC_OVERRIDE`, a read-only root filesystem and no privilege escalation.
- **Token:** a Secret, `aidc-mcp-token` (MCP-05), projected with the config into
  `/aidc-config`, where the server reads the token on every request and the CLI its config.
  `start` makes it when missing and copies it to `~/.config/aidc/mcp-token` (0600) on the
  user's machine; `token rotate` replaces it (delete, then create from stdin, never on a command
  line) and restarts the server, so an MCP session opened with the old token is refused on its
  next message (TRS-08). The user's Role may read that one Secret by name, no other.
- **Config:** a ConfigMap of the user's config for the cluster: `backend: kubernetes`,
  `kubernetes.user` set, the kubeconfig and context left out (kubectl uses the ServiceAccount),
  `ports:` left out (a tunnel ends on the machine that runs it).
- **Reach (MCP-10/11, owner ruling Q-M1):** always in the cluster by its Service,
  `aidc-mcp.<namespace>.svc:7878`, and on the VPN/LAN when `mcp.kubernetes.expose: ingress`
  through an Ingress at `mcp-<user>.<kubernetes.ingress.domain>`, on the pages' class and
  wildcard certificate; every path behind the bearer (the server's middleware covers all).
  Chosen over a LAN address because a user's Services are held to ClusterIP by the admission
  policy and the pages' DNS and certificate already exist; the name is one of the user's page
  names, so the session name `mcp` is reserved on Kubernetes. `aidc mcp start` refuses an
  exposure the cluster cannot serve: no pages domain or class, an IngressClass it lacks, or the
  name another Ingress serves. It also refuses one whose name resolves (on the user's machine)
  to a public address, or does not resolve: a session's proxy reaches any public address and
  no private one, so only a VPN/LAN address keeps every session, the user's and other users',
  from reaching the server through its Squid (MCP-12, K8S-13). Residual: the check is made at
  start, on the first IPv4 answer the user's machine gets; a DNS answer changed to a public
  address afterwards, a name that also has a public answer elsewhere (split-horizon DNS, several
  addresses), or a controller that also listens at a public address, is not seen.
  The ingress rule assumes a controller on the pod network; one on the node's network connects
  from node addresses, which the namespace rule does not admit (as for the pages). The NetworkPolicy lets in connections to the server's port from
  every namespace but the user's own (a decision taken while building, main agent 2026-11-26):
  an orchestrator in the cluster and the ingress controller reach it, and no session of the
  user does; another user's sessions reach no pod address at all (their egress is their own
  proxy, public addresses only). The readiness probe is an exec from inside the pod, since some
  network plugins would judge a node's tcpSocket probe by the same policy.
- **Callback egress:** the one host and port of `orchestrator.callback_url`, resolved on the
  user's machine as relays are (or `mcp.kubernetes.callback_address`), refused when loopback or
  unresolvable, in a NetworkPolicy of its own (`aidc-mcp-callback`, replaced on every start, so a
  changed callback leaves no old way out, and kept apart from the API server's addresses, which
  start reads back from the `aidc-mcp` policy); the name goes in the pod's hosts file, since the
  pod has no DNS. No callback URL: no callback egress (its policy removed), and start says so.
- **Network:** a NetworkPolicy on top of the namespace's default-deny: ingress as above, egress
  to the callback and to the API server only, at the addresses of "API server reach" below
  (the user's kubeconfig's, resolved on their machine and refused when it is loopback, with the
  other control-plane nodes'; or `kubernetes.api_endpoints`) and at its in-cluster Service
  address, as the server's own pod reports it. Both, because a network
  policy may see a connection before or after the Service's address is translated, depending
  on the CNI. Over a running server the in-cluster address is read first and the policy applied
  once, so it is never narrowed under the server (a server that does not answer keeps what
  its policy allows); a new server's is read once it runs and added.
- **API server reach (2026-11-27):** the server's kubectl, and the aidc CLI it runs, use a
  kubeconfig of aidc's (`k8s_mcp_kubeconfig`, in the server's ConfigMap): the pod's
  ServiceAccount token and CA, the certificate checked for `kubernetes.default.svc` (every API
  server's certificate carries that name, so the address need not be in it), and one API server
  address. Not kubectl's in-cluster default, for two reasons found on a live cluster: the API
  Service balances over every control-plane node, and a policy judged after the Service's
  translation lets through only the node addresses it names (half or more of the calls were
  refused on a three-node control plane); and kubectl drops the in-cluster default whenever a
  flag such as `--request-timeout` is given, then tries `localhost:8080`. The addresses are
  `kubernetes.api_endpoints` when configured; otherwise the kubeconfig's server as the user's
  machine resolves it and, when that is a control-plane node's own address, every control-plane
  node's (their InternalIPs, as the cluster reports them, at the same port), so the policy
  allows each. Which one the kubeconfig names is not taken on the machine's word: once the pod
  runs, start asks from inside it (its own kubectl, `get --raw /readyz`, which any client may
  read) and uses the first it reaches. A server that runs already is asked before its
  kubeconfig is written (the ConfigMap is projected into the running pod, so a write is live),
  and is restarted only when the address it reaches is not the one it held; a new one starts on
  the first and is restarted when it reaches another only. When the pod reaches none (a VPN,
  tunnel or load-balancer address only the machine can route), start refuses, saying to set
  `kubernetes.api_endpoints`, with the last attempt's own error (a refused connection reads
  differently from an exec that failed for its own reason).
  Trade-off, taken knowingly: no failover while the server runs. A kubeconfig cluster has one
  server; the server and the CLI call kubectl directly in many places; and a retrying wrapper
  would have to replay a command's stdin, which a streaming exec (attach, send) cannot. So
  with that control-plane node down every cluster call from the server fails until
  `aidc mcp start` is run again, which asks the pod afresh and moves it to a node that answers.
- **The server's image:** the orchestrator holds a connection to the server, so start never
  restarts a running server for nothing (only for the API address above, or a rebuilt image).
  The image's tag is aidc's version, and an image rebuilt under it (`aidc k8s build --force`)
  would leave the Deployment unchanged and the old pod running. Start puts the digest `aidc k8s
  build` recorded on this machine (above, "Images") on the pod template as the annotation
  `aidc/image-digest`: a new digest changes the template, so the apply replaces the pod, which
  pulls the image (imagePullPolicy Always); the same digest applies unchanged and the server
  keeps running. Start says which: the digest it runs, or that it is restarted onto the rebuilt
  image. With no record for this cluster (the image was built on another machine) the running
  server's own annotation is kept, so it is not restarted, and start says a stop and then a
  start puts it on an image rebuilt since. A cluster that does not say which digest the running
  server has stops start before anything is changed. The kubeconfig's server URL is read for
  this only when some cluster has a record of the image.
- **Creating sessions (MCP-38/39, TRS-23):** with `mcp.session_create: true` the server's
  `session_create` runs `aidc create --backend kubernetes` in its pod, under its ServiceAccount:
  no repo or workspace (refused), the session starting at `/home/<user>` (the pod's home and
  working dir), the user's config from the ConfigMap, no tunnel (its config has no `ports:`),
  no git identity bridged (the image has no git; the session's commits carry the identity set
  in it). `tests/unit/test-k8s-rbac.sh` holds every cluster call `aidc create|list|status`
  reach, minus their page and tunnel paths, to the MCP's Role. A cluster create may take up to
  fifteen minutes (the proxy's and the dev pod's waits), and reports its steps as progress.
  `session_mcp_set` writes into the session's Claude state by the same exec, as the session user.
- **Status:** `aidc mcp status` says why a server that is not ready waits (its pod's reason:
  an image not built yet, a crash) and how full its state claim is, warning from 80%: the
  access log grows on the claim the store needs, and a full claim stops replies.

### Backend seam

Built first, with no behaviour change (branch `refactor/backend-seam`):

- **MCP server:** `mcp/src/aidc_mcp/backend.py` is the one module that knows sessions run on
  Docker. Callers address a container as `backend.target(session, role)` (roles `dev`, `policy`,
  `audit`) and get commands from it: `exec_argv` (user, workdir, env, stdin), the inspect and list
  queries with the readers of their output, the reading of a missing container, and the
  session's instance id. They keep their own
  process handling (sync or async, timeouts, stdin). `mcp/tests/test_backend.py` fails if any
  other module starts `docker` or `kubectl`, or spells a container or cluster object name.
  The Kubernetes backend answers the same functions with `kubectl` and namespace/pod names.
  One server serves one backend: its environment says which (`AIDC_MCP_BACKEND=docker`, the
  default, or `kubernetes` with `AIDC_K8S_NAMESPACE`, the user's namespace), and a server
  whose settings name neither, or no namespace, refuses to start. On Kubernetes:
  - targets: a session's `dev` role is `pod/<s>-dev-0` container `dev`; `policy` and `audit`
    are those containers of `deployment/<s>-proxy`; the git agent is `deployment/git`
    container `git`, and its request holder the same pod's `gitreq` container (kubectl exec
    cannot choose a user).
  - the session user is reached with `sudo -E -H -u vscode`, as `aidc attach` does: the pod's
    environment (its proxy settings) is kept and the dev image's sudo rule gives the
    session's umask, so what the MCP writes on the shared disk stays group-writable; a
    workdir and env are part of the command (kubectl exec has neither flag).
  - a session's instance id is the uid of its state claim (`<s>-state`, the git agent's
    `git-home`): made by create, deleted by kill, kept by restart and upgrade, as Docker's
    session network. Only the API server's NotFound for that claim is a gone session.
  - `audit_get`'s `audit_dir` is `pvc:<namespace>/<claim>`, the audit claim. The audit
    resources (`aidc://sessions/{name}/audit[/{file}]`) read the trail in the session's
    audit sidecar on both backends, where it is mounted.
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
| Syncthing in a pod | built (chunk 19); live: one per-user pod paired with a laptop |
| Alias symlinks: purge, retention, `/resume` picker, long hashed names | live test on a Mac |
| Git agent's question answered by `session_send` (Docker) | the decision: `mcp/tests/test_git_approve.py` (approve, deny with a reason, a request not waiting, ambiguous and unclear answers, the gitreq command); the answer into the widget and the request run: live check with a logged-in git agent (tests/smoke/README.md) |
| Git agent's question reaching an orchestrator on Kubernetes | owner ruling; aidc 2.0's per-user MCP server |
| A real push, PR, merge, tidy and protect through the git container | the smokes' GitHub part, with a login and a scratch repo |
| The Docker git container on macOS (volume ownership, the mount check) | live test on a Mac |
