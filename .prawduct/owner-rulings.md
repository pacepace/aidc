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
