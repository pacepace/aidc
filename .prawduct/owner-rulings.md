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
