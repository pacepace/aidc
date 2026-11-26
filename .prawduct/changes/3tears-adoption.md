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
- Chunk 13 (owner ruling 2026-11-26, git approvals out of the agent's reach): a user of its own
  in the git container, `gitreq` (2003), holds and decides requests. The request folder, the
  session modes (now `state/modes` in it) and every decision are its. The agent (git) reaches it
  only through a sudo rule for list, show, prompt, handoff, handed and watch; approve, deny and
  the mode and record verbs refuse git and anything reached through sudo. gitctl's GitHub writes
  (push, pr-create, pr-comment, pr-merge, protect) run only for gitreq, checked on every side.
  The user's `aidc git approve|deny|mode|push|pr|merge|protect` and aidc's session records run as
  gitreq: `docker exec -u gitreq` on Docker, and on Kubernetes an exec into the git pod's new
  `gitreq` container, which runs the watcher. The holder's mode and paths come from a read-only
  settings file (Docker: `~/.config/aidc/git-settings`; Kubernetes: the `git-settings`
  ConfigMap). The agent's `gh` is now the sessions' stand-in, so its own pushes and pull requests
  are requests too (always ask). Waiting requests reach its Claude by the main process asking the
  holder (handoff), not by the watcher typing in. The agent's question names the request id, and
  it answers with the `aidc git approve|deny` to run. Setup gives the holder a request folder the
  agent held, contents included.

## Consumer note (chunk 13)
- `aidc git setup` must run again on each backend (new image, the gitreq container on
  Kubernetes, the settings file). Sessions must be created again: their gh stand-in checks the
  request folder is gitreq's. Sessions' own modes start again from the user's mode.
- Answering the git agent's question in its terminal no longer approves: run
  `aidc git approve|deny <id>`. Asking the agent to push or open a pull request makes a request.
- The MCP server's entry point for an orchestrator's answer is `git-requests approve|deny <id>`
  by exec as gitreq (build plan chunk 13, notes).

- Chunk 03: the local face is 3tears-mcp's `McpServer` (`server.py`), stateful Streamable HTTP on
  SSE responses, serving the TearsTools through the bridge under their 1.x names, with the
  server's version and instructions. `tools.py` and `disconnect.py` are gone. Scope and taint are
  `authz.AidcAuthorizer`, which 3tears asks before a tool runs; a refusal answers aidc's envelope
  as its content (1.x's text, `data.tainted` included) and is logged as before. aidc's 20 codes
  are registered as protocol codes, with which are retryable: a failed call is now `isError`,
  its code under `_meta["threetears.mcp/error"]`. The bearer is checked against the token file
  as it is now, in the gate (401, logged) and in the server's resolver, so a rotated token
  refuses an open session's next message. Resources are 3tears resources with the scope in the
  authorizer: an out-of-scope read is now a JSON-RPC refusal, not a JSON error body, and the
  global config is left out of a scoped server's listing. A dropped connection cancels a
  blocking `session_invoke` through 3tears (no watcher of aidc's own). `published-tools.json`
  is regenerated: the same names and descriptions, self-contained schemas. Every tool declares
  the envelope as its output schema, so the envelope is sent as `structuredContent` too (design-10
  D6), failures included. Where 1.x accepted null for an optional argument the schema lists
  `[type, "null"]` and null reaches the tool as not given; an integer argument sent as a whole
  number in text ("5") is read as the number before the schema checks it (3tears'
  `prepare_arguments`), the schema staying `integer`. A failed call's `retryable` is design-10
  D6's new Retryable column (`cli_failed`, `invoke_busy`), held to it by a test. A token file
  unreadable for a moment (mid-rotation) answers a logged 401.

- Chunk 04: each phase `session_create` and `session_invoke` report is `notifications/progress`
  (counting up, the phase as its message) as well as a log line. The service reports a session
  changed (`common.session_changed`: a paste, a delivered reply, a create, an interrupt), and
  the face sends `notifications/resources/updated` for the session's status and the session
  list to subscribed clients, which 1.x never did (MCP-09). `published-tools.json` names each
  tool's `mesh_name`. The CHANGELOG's Unreleased section has the 2.0 upgrade notes; the README's
  MCP section says what changed.

**Proof:** chunk 04: `AIDC_SMOKE_GIT=0 make smoke` from a separate checkout with a test version tag: 122 of 123, the one failure the test-tag version line (the image reports the package's 1.9.10), as on the service split's run; its MCP part initializes, lists and calls through the new server. The MCP suite is green, with wire tests reading a progress notification and a log line before the result for both tools, and a real uvicorn server pushing `notifications/resources/updated` to a subscribed client's stream. Chunk 03: the built image (test tag, a test-only container with the token mounted as `aidc mcp start` mounts it) answered 401 without a token, the handshake with aidc's name, version and instructions, the tool list, a call failing with its code on the protocol result and the envelope as structured content, the resource list, and a token rotation refusing the old token at once and serving the new one, each request in the access log. The MCP suite is green, the wire suite against the new server included (cancel, DELETE and dropped connection each stop a blocking invoke; a rotated token refuses an open session; every aidc code rides the protocol result; local mode starts, lists and calls every tool in a fresh interpreter with no NATS, Postgres, LangGraph or 3tears core loaded). Chunk 02: the MCP suite is green; #76 reproduced in `ubuntu:26.04` (uutils 0.10.0: `install` exits 1 on an existing file) and the new write checked there (overwrite, mode applied, no temporary file left, a missing directory fails). Chunk 01: the MCP suite is green on the new lock; the image builds from it
(`docker build`, test tag) and imports the server with no git left in it.

## Consumer note
Chunks 03-04 change what a caller sees (aidc 2.0; the CHANGELOG's Unreleased upgrade notes):
- A failed call (`ok: false`) is now `isError: true`, its code also under
  `_meta["threetears.mcp/error"]` with `retryable`; the envelope text is unchanged.
- Input schemas are self-contained: an optional parameter is `type: [type, "null"]` rather
  than `anyOf [type, null]`, and titles are gone. Null and whole numbers sent as text are still
  accepted; leaving an optional argument out and sending a real number are the forms to use.
  Arguments a schema refuses answer `INVALID_ARGUMENTS` before the tool runs.
- A resource of a session outside a scoped server's scope is refused as a JSON-RPC error, and
  `aidc://config` is not listed on a scoped server.
- Progress notifications for `session_create` and `session_invoke` phases; resource update
  notifications for a session's status and the session list; `mesh_name` in the published list.
- `file_put` overwrites an existing file (#76).
