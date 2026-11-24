---
schema: 1
type: refactor
scope: backend-seam
date: 2026-11-24
title: One switch point between aidc and Docker
---
**Why:** first step of the Kubernetes backend (docs/design-12-kubernetes.md, K8S-01): aidc gains a
second place for sessions to run, and every Docker call must go through one place so the second
backend can answer instead. No behaviour change.

**What:**
- MCP server: `aidc_mcp/backend.py` is the only module that starts `docker` or names a session's
  containers; the taint, audit, repository, headless, repo-inspection, tmux, exec, file and
  session-instance paths build their commands through it. `test_backend.py` fails if any other
  module does it.
- CLI: the dispatcher is the switch point (one `cmd-<verb>.sh` per verb);
  `tests/unit/test-backend-confinement.sh` keeps `docker` out of the dispatcher and the shared
  libraries, except the named Docker helpers.
