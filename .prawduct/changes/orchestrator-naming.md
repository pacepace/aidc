---
schema: 1
type: refactor
scope: orchestrator-naming
date: 2026-11-24
title: The orchestrator config section is now orchestrator
---
**Why:** the owner ruled 2026-11-24 that aidc's repo must not name his private projects. The
config section and the code, docs, tests and fixtures around it carried the name of his
orchestrator project.

**What:**
- The `~/.config/aidc/config.yaml` section is `orchestrator:` with the same keys
  (`callback_url`, `send_speaker`, `turn_settle_seconds`). The readers in `tools.py`
  (`_orchestrator_setting` and its helpers), `session_mcp.py` and `scripts/lib/config.sh` read the
  new name only; there is no fallback to the old one.
- Every "not set" error names `orchestrator.callback_url`.
- Docs, comments, docstrings, tests and the README now say "the orchestrator" or "an
  orchestrator". The README's sentence that the key keeps its historical name is gone.
- The 2026-09-17 joint-test log is now `.prawduct/artifacts/joint-test-orchestrator.md`.
- Released CHANGELOG entries, the change log, its archive and `docs/done` are history and are
  unchanged.

## Consumer note
In `~/.config/aidc/config.yaml`, rename the top-level section that holds `callback_url` (and
`send_speaker`, `turn_settle_seconds`) to `orchestrator:`, keys unchanged, before restarting
`aidc-mcp`. Until then callbacks stop with an error that names
`orchestrator.callback_url`.
