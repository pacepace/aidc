---
schema: 1
type: refactor
scope: mcp-service-split
date: 2026-11-25
title: The MCP server's service moves out of tools.py into aidc_mcp/service/
---
**Why:** aidc 2.0 rebuilds the MCP tools as 3tears tools (design-13, plan-aidc-2.0 W-T2). The
watchers, send queues, delivery, resume and session operations must not depend on MCP for that.

**What:**
- New package `mcp/src/aidc_mcp/service/`: `state` (every per-session table the event loop owns
  and the state directories), `config` (the `orchestrator:` settings), `common` (background tasks,
  the CLI runner, the envelope and `ERROR_CODES`), `tmux`, `turns`, `callbacks`, `sending`,
  `delivery`, `startup`, `invoke`, `repos`, `sessions`. It imports no MCP type
  (`test_service_boundary`, which also checks a fresh interpreter).
- `tools.py` keeps each tool's schema, description and guards and calls the service; the
  request's Context reaches the service as plain hooks (`progress`, `announce`, `call_key`).
- Names now shared between modules are public; `auth.load_token` likewise.
- Tests that patched or read internals name the module that owns them. Every module logs
  through `audit.log_event` (none imports it by name), so `tests/logs.py` patches that one
  binding and reaches every module's events, auth.py's and session_facts.py's included. No
  assertion changed in meaning; `published-tools.json` is byte-identical.

**Proof:** `AIDC_SMOKE_GIT=0 make smoke` from a separate checkout with a test version tag: 122 of 123 on c4e5200, and again on the tree of eabd93c; the one failure is the test-tag version line. The unit and MCP suites passed on eabd93c's tree (results in the evidence store).

## Consumer note
Nothing to do: the MCP tools, their arguments, results and error codes are unchanged (published-tools.json is byte-identical).
