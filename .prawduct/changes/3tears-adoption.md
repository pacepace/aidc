---
schema: 1
type: feature
scope: 3tears-adoption
date: 2026-11-26
title: aidc 2.0's MCP server on 3tears (build-plan-3tears-adoption)
---
**Why:** aidc 2.0 rebuilds the MCP server on 3tears (design-13, TRS-01..25): one tool implementation
served over MCP locally and on a 3tears mesh, built on the unreleased 3tears branch first (owner
ruling 2026-11-26).

**What:**
- Chunk 01: the 3tears family (3tears-mcp, 3tears-tool-contract with its MCP face,
  3tears-tool-schema, 3tears-observe) comes in as uv git sources pinned to one commit of
  `feat/mcp-face`, every package from the same commit; the `mesh` extra is declared empty. The
  REL-09 cooldown stays and does not hold git sources back (they carry no upload date), so no
  exception was added. The image installs git for the sync only. `tests/test_dependencies.py` pins
  TRS-02 (mcp 2.x, one 3tears minor and commit) and TRS-17's light lock. The 3tears surfaces the
  later chunks use are recorded in `.prawduct/artifacts/api-notes-3tears.md` against the pinned
  commit.
- Chunk 02: `mcp/src/aidc_mcp/tearstools/` holds one `TearsTool` per tool (23, session_create
  included; the face leaves it out unless MCP-38 turns it on). Each tool's `call` signature and
  docstring are 1.x's, carried over from tools.py's source, so its schema (made self-contained by
  tool-schema) and every description match 1.x word for word; the 1.x list is kept as
  `tests/fixtures/published-tools-1x.json` for that check. A tool returns the service's envelope as
  JSON content, `success` = `ok`, the aidc code in `metadata["error_code"]`; the platform's
  `ToolResult.error_code` stays unset. Arguments are read as 1.x read them (pydantic, lax; defaults
  filled, unknown ones ignored); one that cannot be read is `invalid_argument`. Phases go to the
  caller as log lines through the call context; watch changes are announced through a hook the
  face supplies. tools.py still serves the 1.x face until chunk 03 replaces it, so the shared
  descriptions exist twice for this one commit.
- #76: `file_put` writes through a temporary file renamed over the target instead of `install -m
  MODE /dev/stdin PATH`, which the session image's uutils coreutils refuse on an existing file.

**Proof:** chunk 02: the MCP suite is green; #76 reproduced in `ubuntu:26.04` (uutils 0.10.0: `install` exits 1 on an existing file) and the new write checked there (overwrite, mode applied, no temporary file left, a missing directory fails). Chunk 01: the MCP suite is green on the new lock; the image builds from it
(`docker build`, test tag) and imports the server with no git left in it.

## Consumer note
Chunks 01-02 change nothing a caller sees, except that `file_put` now overwrites an existing file (#76).
