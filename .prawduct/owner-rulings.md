# Owner rulings

Decisions the owner made in conversation, dated, so later sessions build on them.

## 2026-11-23: Kubernetes support is a second target for the same aidc

aidc gains a Kubernetes backend (first target: ranch-dev01 on the ranch cluster) as a new place
for sessions to run, not a separate tool. The existing commands, the MCP server and the
orchestrator keep working against it, and the Docker backend stays. Why: aidc's value is the
session workflow, orchestration, egress policy and audit trail, not Docker itself; a second tool
would duplicate all of it. Starting outline: agent-cluster `docs/ranch-dev01.md`, the "aidc" row.

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

The other users (first: Brooks, who also has access to the ranch nodes) are trusted. Separation
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
Brooks confirmed (2026-11-23) that Jean-Claude switches accounts by quitting and relaunching under
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
about 16 concurrent sessions on ranch-dev01 (EPYC 7452, 64 threads, about 500 GB RAM).

## 2026-11-23: Session size defaults to 2 CPUs and 8 GB, settable per session

Each cluster session is guaranteed 2 CPUs and 8 GB of memory by default and may use more (up to
16 CPUs and 32 GB) when the node has room. Both are settable at create.

## 2026-11-23: New users are added by one admin command, and bring their own secrets

An admin creates a new user's area with one command (for example `aidc user add brooks`). The
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
Refined: an orchestrator the user drives (such as metallm) can give that approval through the
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
Also: the owner's phone is on ZeroTier, so it can reach ranch addresses for testing.

## 2026-11-23: Sessions run under Sysbox; GPUs reach pods through CDI

Sessions run under Sysbox (0.7.2 on ranch-dev01; owner approved the cooldown exception for its
GPU passthrough and security fixes). Measured 2026-11-23 on ranch-dev01: in an unprivileged
Sysbox pod (`hostUsers: false`, root mapped to an unprivileged host uid) `docker run`, compose
with postgres and NATS, and a testcontainers test all pass, and the RTX 3080 is visible
(`nvidia-smi -L`). The node needed an AppArmor local rule letting fusermount3 mount under
/var/lib/sysboxfs. The cluster's NVIDIA device plugin now hands GPUs to pods through CDI
(the.ranch #246), so any runtime gets the GPU. Rootless Docker was tried and dropped: it needed
the AppArmor userns restriction lifted, a smaller ID range and a tun device plugin, and still
did not run.

## 2026-11-24: The git container shares the repo, with its settings and hooks locked

The git container works in the same repo on the user's disk as the sessions, not in a private
copy. The repo's settings file and hooks folder (and the rest of `.git/` except objects, refs and
each session's own worktree folder) belong to the git container and are read-only to sessions;
repos use reftable ref storage; the git container never runs git inside a session's worktree and
always runs with hooks off. Measured 2026-11-24 on ranch-dev01 (design-12). The owner noted that
shared volumes for other pods already use NFS from ranch-dev01; that is the expected storage,
pending a test that Sysbox sessions see correct file owners on it.

## 2026-11-24: Each user's code lives on ranch-dev01's local ZFS, one dataset per user

Sessions run only on ranch-dev01, so each user's code volume is a dataset on that node's local
ZFS, mounted into the git container and the user's sessions as a local volume. Not NFS: measured
2026-11-24, NFS cannot carry the user-ID remapping Sysbox sessions need, so files written by a
session showed as `nobody` in every other pod (design-12, "Storage").

## 2026-11-24: Claude history syncs under the Linux folder names, with Mac aliases

A repo's Claude history folder is synced under its Linux name (`-home-<name>-…`), the name Linux,
WSL and the cluster already use. On each Mac a small script creates an alias (symlink) with the
Mac name (`-Users-<name>-…`) pointing at it inside `~/.claude/projects/`; aliases are not synced.
Measured: Claude follows such an alias, appends to the same conversation and finds its memory.

## 2026-11-24: aidc sessions come with testament installed

aidc installs testament (Brooks's distributed test runner; coordinator deployed in the.ranch
`apps/testament`, image `ghcr.io/brookstalley/testament`) in its sessions, so work in a session
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

## 2026-11-24: Session ports reach the phone at <session>-<user>.dev.ranch.illuminati.org

On request at create, a session's web port gets a stable name `<session>-<user>.dev.ranch.illuminati.org`
through Traefik, removed at kill; a `*.dev.ranch.illuminati.org` wildcard
certificate (cert-manager, DNS-01) covers it. The owner asked that the names go on the MikroTiks
and in ZeroTier DNS. Checked 2026-11-24: the RB5009's existing regexp entry
`.*\.ranch\.illuminati\.org` already answers these names with 10.42.0.101 (Traefik), and
ZeroTier clients' split DNS for `ranch.illuminati.org` already sends them there, so no new DNS
entry is needed where `ranch.*` names already resolve.

## 2026-11-24: A session's test page needs no login by default

Exposing a session port on the home network does not require a login in front of it. The user
adds protection to a page when they need it (an option at create), so a test page can come up
open.
