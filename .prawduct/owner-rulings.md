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
