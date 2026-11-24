---
schema: 1
type: refactor
scope: coordinator-naming
date: 2026-11-24
title: The orchestrator config section is now coordinator
---
**Why:** the owner ruled 2026-11-24 that aidc's repo must not name his private projects. The
config section and the code, docs, tests and fixtures around it carried the name of his
orchestrator project.

**What:**
- The `~/.config/aidc/config.yaml` section is `coordinator:` with the same keys
  (`callback_url`, `send_speaker`, `turn_settle_seconds`). The readers in `tools.py`
  (`_coordinator_setting` and its helpers), `session_mcp.py` and `scripts/lib/config.sh` read the
  new name only; there is no fallback to the old one.
- Every "not set" error names `coordinator.callback_url`.
- Docs, comments, docstrings, tests and the README now say "the coordinator" or "an
  orchestrator". The README's sentence that the key keeps its historical name is gone.
- `.prawduct/artifacts/joint-test-metallm.md` is now `joint-test-coordinator.md`.
- Released CHANGELOG entries, the change log, its archive and `docs/done` are history and are
  unchanged.

## Consumer note
Rename the section in `~/.config/aidc/config.yaml` from `metallm:` to `coordinator:` (keys
unchanged) before restarting `aidc-mcp`. Until then callbacks stop with an error that names
`coordinator.callback_url`.
