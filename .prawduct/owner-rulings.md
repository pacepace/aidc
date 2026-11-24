# Owner rulings

Decisions the owner made in conversation, dated, so later sessions build on them.

## 2026-11-23: Kubernetes support is a second target for the same aidc

aidc gains a Kubernetes backend (first target: the owner's own cluster) as a new place
for sessions to run, not a separate tool. The existing commands, the MCP server and the
orchestrator keep working against it, and the Docker backend stays. Why: aidc's value is the
session workflow, orchestration, egress policy and audit trail, not Docker itself; a second tool
would duplicate all of it.

## 2026-11-23: Code lives on a per-user disk; a trusted git container talks to GitHub

No copying code in and out of sessions. Each user's code (all their repos, since projects need
each other) lives on a persistent volume in the cluster. Sandboxed sessions work on it. A
separate trusted aidc git container holds the SSH key and `gh`, and is the only thing that
pushes, pulls or opens PRs. It carries the git rules: merge commits only, never force-push, no
AI attribution in commits, PRs, code or docs. Several users each get their own setup on the same
cluster.

Who triggers git operations is a mode, ranging from "always ask the human" to "the agent
decides by the rules". Agent's addition (accepted as design direction, not yet ruled): the git
container never runs hooks or repo-level config from the shared disk, and enforces the hard rules
in code, not only in instructions.

## 2026-11-23: Each session gets its own git worktree

Two sessions on the same repo never share a working folder: each session works in its own git
worktree of that repo on the user's disk.

## 2026-11-23: The git container owns cleanup of branches and worktrees

The trusted git container is responsible for keeping branches and worktrees tidy: it actively
cleans up the stale branches and worktrees agents leave behind.
Refined: merged branches and their worktrees are deleted. Anything else left behind (unmerged,
unpushed, orphaned) is flagged for investigation right away, not left to sit, because the
longer it rots the harder it is to sort out.

## 2026-11-23: The user edits through VS Code, attached to a pod

The user views and edits their cluster-side code with VS Code attached to a pod that mounts
their disk, the same way aidc's dev containers are used from VS Code today.

## 2026-11-23: Users are trusted peers

The other users (first: a colleague who also administers the cluster) are trusted. Separation
between users is about not tripping over each other and each acting under their own GitHub
identity, not about walling them off from each other.
Confirmed: each user has their own code volume; users never share one.

## 2026-11-23: One aidc MCP server per user, in the cluster

Each user's aidc MCP server runs in the cluster in that user's area, so sessions keep running
and replies keep arriving while the user's laptop sleeps.

## 2026-11-23: Claude login is set up once per user, not per session (preferred)

Preferred: each user's Claude login is set up once, in their area, and every session they start
uses it. Fallback if that breaks (earlier trouble came from sharing one login inside and outside
aidc at once): each session logs in on its own. Users have several Claude accounts each, so
managing accounts must be easy; look at Jean-Claude (github.com/MikeVeerman/jean-claude, account
profiles) and similar tools before designing this.
Refined: a running session must be able to switch Claude accounts mid-work, because accounts run
out of usage quota during the work.

## 2026-11-23: Conversations and memory survive account switches and sync to other workstations

Switching a session's Claude account must never lose its conversation, memory or other Claude
state. That state also syncs between the cluster and the user's other workstations, the way the
owner syncs it today with iCloud. iCloud is preferred for ease but not required.
Refined: use Syncthing (works on Mac, Linux and Windows; Windows users work inside WSL). Folder
layout below the home directory is the same on every machine; only the home directory itself
differs (`/Users/<name>` on Mac, `/home/<name>` on Linux and WSL).

## 2026-11-23: One conversation history per repo across every machine

A repo's Claude conversations, memory and related state are one shared history across the
cluster, Mac, Linux and WSL; native Windows (no WSL) is a bonus. The differing home directories
must be handled so the same repo maps to the same history everywhere. Using Jean-Claude is not
required: building our own equivalent is acceptable if that is simpler than fitting around it.
A Jean-Claude user confirmed (2026-11-23) that it switches accounts by quitting and relaunching under
another profile, and `--continue` does not follow across profiles.

## 2026-11-23: Account switching is configurable and ordered

Whether a session switches Claude accounts automatically when one runs out, or waits for the
user, is a setting. Each user sets the order their accounts are used in, and that order matters.

## 2026-11-23: GPU only on request

A session gets the shared GPU only when asked for at create (for example `--gpu`); sessions have
no GPU by default.

## 2026-11-23: Cluster sessions are driven from any of the user's machines

A user starts and drives their cluster sessions from any of their machines (Mac, Linux, WSL) with
the same `aidc` commands as today; a session created from one machine can be attached to from
another.

## 2026-11-23: Sessions come back after a node reboot

When the node running sessions reboots, aidc brings each session back on its own, with its files,
branches and conversation intact, and Claude picks up where it left off.

## 2026-11-23: Session ports reach the user by tunnel, and optionally the home network

A session's published port is reached through a tunnel aidc opens to the machine the user is on.
On request it can also be exposed on the home network at a stable address, so it can be tested
from other devices such as a phone.

## 2026-11-23: Expected load is 4-8 sessions per user at once

Each user runs about 4-8 sessions at the same time, so with two users, sizing plans for up to
about 16 concurrent sessions on the session node (64 threads, about 500 GB RAM).

## 2026-11-23: Session size defaults to 2 CPUs and 8 GB, settable per session

Each cluster session is guaranteed 2 CPUs and 8 GB of memory by default and may use more (up to
16 CPUs and 32 GB) when the node has room. Both are settable at create.

## 2026-11-23: New users are added by one admin command, and bring their own secrets

An admin creates a new user's area with one command (for example `aidc user add alice`). The
new user then adds their own SSH key, GitHub login and Claude accounts, so the admin never
handles another user's secrets.

## 2026-11-23: Git mode defaults to "ask", and each user can change their default

New sessions start in the mode where the git container asks the user before each push or PR.
Each user can set a different default for their own sessions, and change it per session.

## 2026-11-23: The git container runs Claude Code, and approvals happen in its terminal

The trusted git container runs Claude Code with the git rules. In "ask" mode it waits in its aidc
terminal for the user to approve, the same way Claude Code asks for permission today. Agent's
design note (direction, not yet ruled): that Claude reads text written by sandboxed sessions
(commit messages, diffs, requests), which could try to talk it into breaking a rule, so the hard
rules (no force-push, merge commits only, no attribution) are also blocked by code it cannot
override, not only by its instructions.
Refined: an orchestrator the user drives can give that approval through the
aidc MCP server, by sending it to the git container's Claude. Sandboxed sessions must never be
able to do this, which rests on them never reaching the MCP server.

## 2026-11-23: One git container (and its Claude) per user

Each user has one trusted git container, whose Claude handles git for all of that user's
sessions and repos: one place to approve, and one view of every branch and worktree to clean up.

## 2026-11-23: The git container checks GitHub repo protections and offers to turn them on

The first time the git container's Claude works with a repo, it checks the GitHub settings (no
force pushes, merge commits only) and offers to turn on any that are missing, applying them only
with the user's OK.

## 2026-11-23: No VMs for sessions; Docker inside sessions stays, without privileged mode if possible

Sessions do not run in VMs (Kata rejected: VMs inside Kubernetes are trouble, slow, and cannot
share the GPU). Docker inside sessions is a core need: bringing up a real program needs
databases, NATS and other services in containers, and testing leans on testcontainers. Explore
Sysbox and rootless Docker/Podman as ways to give sessions Docker without privileged mode.
Also: the owner's phone is on the same VPN as the cluster, so it can reach it for testing.

## 2026-11-23: Sessions run under Sysbox; GPUs reach pods through CDI

Sessions run under Sysbox (0.7.2 on the session node; owner approved the cooldown exception for its
GPU passthrough and security fixes). Measured 2026-11-23 on the session node: in an unprivileged
Sysbox pod (`hostUsers: false`, root mapped to an unprivileged host uid) `docker run`, compose
with postgres and NATS, and a testcontainers test all pass, and the node's GPU is visible
(`nvidia-smi -L`). The node needed an AppArmor local rule letting fusermount3 mount under
/var/lib/sysboxfs. The cluster's NVIDIA device plugin now hands GPUs to pods through CDI
so any runtime gets the GPU. Rootless Docker was tried and dropped: it needed
the AppArmor userns restriction lifted, a smaller ID range and a tun device plugin, and still
did not run.

## 2026-11-24: The git container shares the repo, with its settings and hooks locked

The git container works in the same repo on the user's disk as the sessions, not in a private
copy. The repo's settings file and hooks folder (and the rest of `.git/` except objects, refs and
each session's own worktree folder) belong to the git container and are read-only to sessions;
repos use reftable ref storage; the git container never runs git inside a session's worktree and
always runs with hooks off. Measured 2026-11-24 (design-12). The owner noted that
shared volumes for other pods already use NFS from the session node; that is the expected storage,
pending a test that Sysbox sessions see correct file owners on it.

## 2026-11-24: Each user's code lives on the session node's local ZFS, one dataset per user

Sessions run only on the session node, so each user's code volume is a dataset on that node's local
ZFS, mounted into the git container and the user's sessions as a local volume. Not NFS: measured
2026-11-24, NFS cannot carry the user-ID remapping Sysbox sessions need, so files written by a
session showed as `nobody` in every other pod (design-12, "Storage").

## 2026-11-24: Claude history syncs under the Linux folder names, with Mac aliases

A repo's Claude history folder is synced under its Linux name (`-home-<name>-…`), the name Linux,
WSL and the cluster already use. On each Mac a small script creates an alias (symlink) with the
Mac name (`-Users-<name>-…`) pointing at it inside `~/.claude/projects/`; aliases are not synced.
Measured: Claude follows such an alias, appends to the same conversation and finds its memory.

## 2026-11-24: aidc sessions come with testament installed

aidc installs testament (a distributed test runner the owner's team uses) in its sessions, so work in a session
can run tests through it. How it is installed (release binary, pinned version, cooldown) is a
technical decision for the build.

## 2026-11-24: What Syncthing syncs

Synced: Claude conversations and memory (`projects/`), `CLAUDE.md`, rules, skills, agents,
commands, keybindings, and the status bar (the `statusLine` setting and its script). Settings and
the status bar go laptop to cluster only, because they can run code on the machine that receives
them; on the cluster aidc wraps the status bar script to read usage for account switching, and
fixes its path. Never synced: logins (`.credentials.json`), `.claude.json`, and the files of
running Claude processes. One machine at a time continues a given conversation (aidc holds a
lock). Also: there is no 5-hour usage window any more; only the weekly one counts.

## 2026-11-24: Session ports reach the phone at a stable name under the cluster's domain

On request at create, a session's web port gets a stable name `<session>-<user>.<domain>` through
the cluster's ingress, removed at kill, covered by a wildcard certificate for that domain. The
owner asked that the names be added to the router DNS and the VPN DNS; checked 2026-11-24 on the
owner's cluster, its existing wildcard DNS entry already answers them, so only the certificate
is new there.

## 2026-11-24: A session's test page needs no login by default

Exposing a session port on the home network does not require a login in front of it. The user
adds protection to a page when they need it (an option at create), so a test page can come up
open.

## 2026-11-24: Cluster images are built in the cluster and kept in a private in-cluster registry

aidc builds its images for the Kubernetes backend inside the cluster (a Sysbox pod on
the session node, which runs Docker) and keeps them in a small private registry inside the cluster.
Nothing is pushed to a public registry. REL-08 is amended accordingly: images are built locally
and never pushed to a public registry (the Docker backend still builds on the user's machine).
Rejected: building on the node over SSH and importing into k3s (couples aidc to node logins), and
GitHub's registry (a public registry, against REL-08).

## 2026-11-24: The Kubernetes backend is generic and driven by configuration

aidc is public (MIT), so nothing in the Kubernetes backend is specific to the owner's cluster. Everything
cluster-specific is configuration: the cluster context, the node selector and tolerations, the
Sysbox runtime class, the storage class, the in-cluster registry and the like. Building aidc's
images for a cluster is an aidc command that reads that configuration ("there should be an aidc
command that has config that builds this repo"). The owner's cluster is one configuration, kept
outside aidc's repo, in the owner's own private repos and config.

## 2026-11-24: The in-cluster image builder may run privileged, during builds only

aidc's squid image builds on Canonical's ubuntu/squid Rock, which owns its files as UID 584792;
a builder in a Kubernetes user namespace (Sysbox) has only IDs 0-65535 and cannot build it. The
owner chose a privileged builder pod: it runs only during `aidc k8s build`, only aidc's own
Dockerfiles, in aidc's system namespace, and is deleted when the build ends. Sessions stay
unprivileged. "Remember the rules": it must work on anyone's cluster, so it needs no node changes
and no Sysbox, uses the session nodes' selector and tolerations (same CPU architecture), and the
system namespace carries the Pod Security label that allows privileged pods there only.
Rejected: a node-level change to the per-pod ID range (a burden on every cluster), building on the
user's machine (cross-architecture), and changing the Docker backend's squid base.

## 2026-11-24: No private infrastructure names in aidc's repo

aidc is public. Its code, docs, tests and records name no private infrastructure, project or
person of the owner's: not the owner's cluster or its nodes, addresses, domains, routers or
repos, and not the names of the owner's other projects (for example the orchestrator aidc was
built alongside) or colleagues. Generic terms instead ("the reference cluster", "an
orchestrator", "a second user"); the specifics go in the owner's private repos. "This isn't a
security breach that needs repo rewrite, just something to stop doing": what is already in
history stays, and current files are cleaned with ordinary commits.

## 2026-11-24: The external orchestrator's config section is `orchestrator:`

The config section once named after the owner's private orchestrator project is `orchestrator:`,
and docs call that role "the orchestrator", the name aidc already used for it. Not
"coordinator": Claude Code already uses that word for a message from another Claude session
(transcript SESSION_MESSAGE_KINDS), and one word for two roles would let an orchestrator read
such a message as its own prompt. Owner: "yes" (2026-11-24) to `orchestrator:`.

## 2026-11-24: The account order wraps around, and each account has its own switch threshold

The user's ordered list of Claude accounts is a cycle: after the last account, switching goes
back to the first. Each account has its own setting for the weekly usage at which aidc switches
away from it (for example one account switched at 90 %, another at 70 %).

## 2026-11-24: aidc gets an audit trim command

Kept audit trails accumulate (one per session on both backends: folders under the audit dir on
Docker, kept claims on Kubernetes), so aidc needs a command that lists them and removes old ones
("we need an audit trim command if they grow to GB that rapidly"). Audit is evidence, so trimming
is explicit and never touches a running session's trail.
Refined (2026-11-24): any aidc command warns when the kept audit trails are larger than 100 MB
("something should warn you when you run any aidc command if it is larger than 100MB").
Refined (2026-11-24): on Kubernetes the size check runs only during cluster commands, and its
answer may be cached for about a day ("only during a cluster command, caching the answer is fine
if we make it check once a day or something").

## 2026-11-24: aidc's MCP server becomes a 3tears tools server (after the Kubernetes work)

aidc's control plane is to be rebuilt on 3tears tools ("convert the mcp to being a tears tools
mcp and use all the things that gets used, then we don't need two"): each aidc tool a 3tears
tool, so one implementation is reachable on the 3tears mesh, as MCP and as an HTTP API. Not a
separate bridge. Investigate properly now; build after the Kubernetes backend work is finished.
Python 3.12 is not a constraint (the MCP server already requires 3.14).
Refined (2026-11-24): the converted server runs either way: it serves itself locally the way it
is used now (its own MCP endpoint, no 3tears infrastructure needed), or it joins a 3tears mesh
("then it can serve itself locally the way it is used now or it can join a 3tears mesh").
Refined (2026-11-24): the rebuilt server uses 3tears-observe for its observability ("we should use
3tears observe then while we're at it").

## 2026-11-24: aidc 2.0 is 3tears adoption, improving 3tears where it falls short

aidc 2.0 rebuilds the control plane on 3tears and uses the family properly, not only for tools
("2.0 is 3tears adoption"). Where 3tears lacks what aidc needs, 3tears is enhanced rather than
worked around: `3tears-mcp` gains progress, resources, tools/list_changed, cancellation and a
richer error model ("enhance 3tears mcp to support these things properly and give it more error
codes"), taken as the chance to really improve the MCP server. Plan the adoption across the
other 3tears packages before building. Still after the Kubernetes work.

## 2026-11-24: Finish the Kubernetes work before the 3tears move

The Kubernetes backend work is finished before aidc 2.0 (3tears adoption) starts: "we have to
finish it before 3tears, so do the 3tears plan, but finish the k8s work". The 2.0 plan is written
now; the build waits. Next Kubernetes wave: the git container.

## 2026-11-24: The git container logs in to GitHub once, as the user; the agent cannot reach the token

GitHub access for the git container is one `gh` login (device code approved in the user's
browser), on the condition that the agent cannot get around the hardened commands ("are we
hardening the gh commands so that the agent couldn't circumvent this? If so then I think we do
this"). So the token is readable only by a separate credential user; the real `git`/`gh` run as
that user through one fixed sudo rule that allows only the wrappers; the agent's own user cannot
read the token. Commits, pushes and PRs show as the user ("commits have to show up as me"): the
author name and email come from the user's GitHub account; no signing. Rejected: per-repo
manual tokens or keys (too much ceremony), a GitHub App (acts as a bot), SSH agent forwarding
(only works while connected).

## 2026-11-24: The git container does not do prawduct's work

"I don't want it doing double duty." Sessions run prawduct's whole cycle, `/prawduct:pr`
included (gate, hygiene, template, body); the git container knows nothing of prawduct and runs
no prawduct check. Since sessions cannot reach GitHub, a session's `gh` (PR create, and the push
before it) becomes a request handed to the git container, which applies only its own rules
(gitctl's hard rules; ask or rules mode) and then pushes and opens the PR.

## 2026-11-24: Sessions make their own worktrees on Kubernetes

A session agent that wants to work on a repo makes its own worktree and branch (`git worktree
add`, under a name it chooses) in a repo the git container added to the user's disk; when done
it asks the git container to push and open the PR, and later to merge. aidc does not hand a
session a repo on Kubernetes (no `aidc create --repo` worktree step): "isn't that something the
dev container agents do on their own when they want to work on a repo?" The lock leaves
`.git/worktrees/` writable by sessions (sticky, so one cannot remove another's).

## 2026-11-24: The git agent is an aidc session

"we need to make sure the git agent is just like any other aidc session that we can talk to via
orchestrators and via the aidc attach." The git container's Claude is reachable the way every
session is: listed by `aidc list`/`status` (marked as the user's git session, a reserved name),
`aidc attach`, `aidc logs`, `aidc send`, and an orchestrator's aidc MCP tools (approval in ask
mode per K8S-06). It stays trusted (no proxy sandbox, holds the gitctl route to the login), is
managed by `aidc git setup`, and `aidc kill` refuses it. Sandboxed sessions still reach it only
through request files.

## 2026-11-24: The git container works on Docker too

"this should work on docker as well as on k8s." The git container, gitctl, session requests,
the git agent's instructions and its being an aidc session all apply on the Docker backend as
well. Open design question for that work: on Docker the user also uses the repos directly on
their machine, so a repo lock owned by the gitrun uid would get in their way; settle whose repos
the Docker git container works on before building it.

## 2026-11-24: On Docker the git container works on the user's own working copies

"my own working copies on my laptop." The Docker git container pushes and opens PRs for the
repos the user works in on their machine; it does not keep its own clones, and those repos are
not locked or re-owned. Consequence (proposed for Chunk 07): gitrun never runs git in the user's
repo; the agent (no login) writes the commits to push into a `git bundle`, and gitrun fetches
the bundle into a private bare copy, scans and pushes from there, so no repo config the user or a
session wrote can run as gitrun.

## 2026-11-24: One git design on both backends: bundles, no repo lock

"shouldn't we make them both the same?" Yes: Kubernetes uses the bundle approach too. gitrun
never runs git in a repo anyone else can write: on push the git agent (no login) bundles the
branch from the working copy and gitrun imports the bundle into its private bare copy, scans and
pushes; on fetch/clone gitrun fetches into its private copy and writes a bundle the agent
imports. Repos on the user's Kubernetes disk are ordinary repos owned by the user's sessions, not
locked; this supersedes the repo-lock proposal (design-12) and gitctl's lock checks.
