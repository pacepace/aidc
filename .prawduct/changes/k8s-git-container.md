---
schema: 1
type: feature
scope: k8s-git-container
date: 2026-11-24
title: The trusted git container
---
**Why:** wave 3 of the Kubernetes backend (docs/design-12-kubernetes.md, "Git"; K8S-04, K8S-05,
K8S-08, K8S-23, K8S-24), extended to Docker by owner ruling: sessions cannot push, so their work
had no way to leave a cluster. One trusted git container per user now holds the GitHub login and
pushes and opens PRs for sessions, by rules enforced in code.

**What:**
- `aidc git setup | login | logout | attach | status` on both backends: the git container (image
  `aidc/gitctl`: git, a pinned `gh`, Claude Code, tmux), in the user's namespace in a cluster or
  as `aidc-git-dev` on Docker; egress to public addresses and Quad9 only (NetworkPolicy, or an
  internal network behind a public-only Squid). One `gh` login over HTTPS as the user, readable
  only by its credential user; commits show as the user.
- `gitctl`: the only route to the login, fixed verbs that build their own command lines: never a
  force push, never main/master/develop or the default branch, merge commits only, no AI
  attribution in commits or PR text, only repos the user added. git with the login runs only in
  private bare copies; commits cross to and from the working copies as git bundles.
- `aidc repo add | list | remove`: in a cluster the git container clones onto the user's disk; on
  Docker it works on the user's own working copies, mounted one by one, never re-owned.
- Sessions ask through a `gh` stand-in (`gh pr create`, `gh pr merge`, `gh pr view|list|status`,
  `gh aidc push|request`) that writes request files; `git push` in a session explains this. Git
  mode `ask` (default: `aidc git requests | approve | deny`, or the git agent's question) or
  `rules`; `aidc git mode <session> rules` for one session, by a token only it holds.
- `aidc git push | pr | merge | tidy | protect`: the same from the terminal; tidy deletes merged
  branches (GitHub and local) and their worktrees and lists every leftover; protections are
  read on first use and turned on only with the user's yes.
- The git agent is the session named `git`: `aidc list`, `attach`, `status`, `logs`; `kill` and
  `create` refuse it. Its Claude runs with managed instructions and a fixed allow list; on
  Docker its transcript reaches `aidc mcp` like any session's.
- Smokes: `make smoke` and `make smoke-k8s` include the git container (tests/smoke/git.sh), with
  parts that need a GitHub login and a scratch repo, or the git agent's Claude, run only when
  those are given.

## Consumer note

New and opt-in: nothing changes until `aidc git setup`. Then run `aidc git login`, add repos
with `aidc repo add`, and create sessions again (a session made before setup has no request
folder). On Kubernetes the git agent's question does not reach an orchestrator yet (aidc 2.0's
per-user MCP server): approve with `aidc git approve` or in `aidc attach git`. README, "The git
container".
