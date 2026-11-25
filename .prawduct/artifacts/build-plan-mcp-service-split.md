---
artifact: build-plan
version: 1
scope: mcp-service-split
branch: feature/k8s-git-container
base: develop
working-branches: []
last_validated: 2026-11-25
depends_on:
  - artifact: .prawduct/artifacts/plan-aidc-2.0.md
  - artifact: docs/design-13-3tears-tools.md
  - artifact: docs/design-10-turn-state-and-sending.md
governed_by:
  - artifact: project-preferences
    dispositions:
      - "a name two modules share is public → conforms: every name the split makes shared loses its underscore (and its callers and tests follow)"
      - "Module split (tools.py holds the MCP surface, the send queue and the watcher) → amendment proposed: this plan is the change; the line is rewritten to name the service package"
      - "State: anything that must survive a restart is a file in the watcher-state dir → conforms: no state is added, the same files are written by the same code"
      - "Contracts: the envelope and callback payload change only by agreement → conforms: neither changes; published-tools.json stays byte-identical"
      - "no private names in the repo → conforms: moved comments that named a person now say 'owner ruling'"
      - "ruff, mypy clean; tests are sentences about behaviour → conforms"
  - artifact: .claude/rules/learnings/core.md
    dispositions:
      - "a value produced in one place and consumed in another must resolve in the same namespace and lifetime → applies: state moves between Python modules, so every reader must read the one module that owns it at call time (no `from x import name` copies, which a test's patch or a reassignment would not reach)"
      - "run the real path once before calling it done → applies: `make smoke` on Docker from a separate checkout closes the wave"
partition: serial — every chunk edits tools.py and moves code the next chunk's code calls
---

# Build Plan — MCP service split (W-T2)

**Work:** `mcp-service-split` (plan-aidc-2.0 W-T2; design-13 "Work, in order" step 2) ·
**Branch:** `feature/k8s-git-container` · **Started:** 2026-11-25

## Goals

**Response taken:** proceed, citing plan-aidc-2.0 W-T2 and design-13's Shape: the service
(watchers, send queues and drainers, delivery with retry and dead letters, resume on start,
persisted state) leaves `tools.py` for a module tree with no MCP types; tools become thin. The
main agent set the done-when (below) and asked for four review observations of
rev-20261125T020056Z-de0053fc to be folded in (chunk 05).

**Product:** nothing a caller sees changes. The point is W-T3: aidc's tools are rebuilt as
3tears `TearsTool`s over the service, and served locally through `3tears-mcp` or on a mesh;
with the service already free of MCP, W-T3 replaces only the adapters.

**Architecture (what must hold):**
- `mcp/src/aidc_mcp/service/` imports no `mcp` or `fastmcp` module, directly or through anything it
  imports (a test runs the import in a fresh interpreter and checks `sys.modules`).
- One event loop, one process: the invariants of design-13's Shape (one drainer per session,
  per-session locks, exactly-once delivery from the watermark and ledger) are unchanged, because
  the code that keeps them is moved, not rewritten.
- The service's in-memory state lives in one module, `service/state.py`; every other module
  reads it there, as `ss.<name>`, at call time. Cross-module calls are always `module.name`
  attribute lookups, never `from module import name`: that keeps one binding per name, which is
  what a test patch or a reassignment reaches (the learnings rule above).
- What only the transport knows stays in `tools.py`: the `Context` (progress via `ctx.info`, the
  request key the disconnect watcher uses), the app (tool descriptions listing watched
  sessions, `tools/list_changed`), the schemas (Annotated/Field) and docstrings, and the scope
  and taint guards that wrap each tool. The service takes plain callables instead: `progress`
  (an async str sink) and `announce` (an async "watchers changed" hook).
- The envelope `{ok, data}` / `{ok: false, error, error_code}` and `ERROR_CODES` move to the
  service: design-13 keeps the envelope as the tool's content on 3tears, so it is aidc's
  result contract, not an MCP type.

**Constraints:** no behaviour change; `published-tools.json` byte-identical; the MCP suite's
assertions unchanged in meaning (tests that patch or read internals are retargeted to the
module that now owns the name; none is weakened); ruff and mypy clean; `make smoke` passes on
Docker from a separate checkout with a test version tag, never touching the owner's images,
sessions or aidc-mcp containers.

**Tradeoffs accepted:**
- The move is mechanical (an AST-driven move of whole top-level statements, then qualified
  references and the shared-name rename), so comments and bodies arrive verbatim. Cleaner
  interfaces (fewer shared internals, a service API with types of its own) are W-T3's to draw,
  when the TearsTools say what they need. Revisit if W-T3 finds the shared surface too wide.
- The service reads the bearer for callbacks through `auth.load_token`, and `auth` imports
  starlette (the HTTP layer). Not an MCP type, so the boundary test allows it; worth moving the
  token read out of `auth` when the local face changes in W-T3.
- `session_kill` and `session_run` stay unregistered, as today; their bodies move with the rest
  so the service holds every session operation.

**Level:** High. The code moves without edits beyond qualification; the suite, which drives
every tool through its registered function, is the check, and smoke runs the real path.

## Chunks

### Chunk 01: service skeleton, state, config, common
- New `mcp/src/aidc_mcp/service/` package: `state.py` (every per-session dict, set and lock the loop
  owns, the watcher-state and transcript dirs, the forget/evict helpers), `config.py` (the
  orchestrator section of the aidc config), `common.py` (background tasks, the CLI runner,
  the envelope and `ERROR_CODES`).
- New test `test_service_boundary.py`: no service module imports `mcp`/`fastmcp`, statically and
  in a fresh interpreter.
- Tests retargeted to the new owners; the source-scanning tests (error codes, off-loop state)
  scan `tools.py` and the service.
- Done when: suite green, ruff/mypy clean, published-tools.json unchanged.

### Chunk 02: tmux, turn state, callbacks
- `tmux.py` (the pane commands and the paste), `turns.py` (SessionState, the markers, the free
  and turn verdicts, the echo wait, session instance), `callbacks.py` (POST to the orchestrator,
  retry, dead letters).
- Done when: as chunk 01.

### Chunk 03: queues, watchers, delivery, resume
- `sending.py` (queues, drainers, inject, join, notifications, resume of queues),
  `delivery.py` (watchers, drain, resend, baseline, resume of watchers), `startup.py`
  (resume_on_startup). `_start_watcher` and `resume_watchers` take a plain hook instead of
  the app and Context; `tools.py` keeps `resume_on_startup(app)` / `resume_watchers(app)` as
  adapters that bind the description refresh.
- Done when: as chunk 01.

### Chunk 04: session operations and thin tools.py
- `invoke.py` (headless claim, stop, interrupt, session_invoke and _async), `repos.py`
  (repository reads), `sessions.py` (create, MCP hand-over, list, status, kill, exec, file_put,
  audit, transcript, interrupt); send, run and queue cancel in `sending.py`; watch, unwatch and
  resend in `delivery.py`. Each tool in `tools.py` keeps its signature and docstring and calls
  its service function. `server.py` takes fire and the disconnect callback from the service.
- project-preferences "Module split" rewritten.
- Done when: as chunk 01, plus `make smoke` on Docker from a separate checkout under `$HOME`
  with a test version tag.

### Chunk 05: review observations (rev-20261125T020056Z-de0053fc)
- `aidc mcp start` warns about a misplaced `callback_url` only when `orchestrator.callback_url`
  is unset.
- Shell and Python agree on what counts as a `callback_url` key when naming a misplaced
  section (see decision (05)).
- Assertions for the rename hint at session_resend, session_send's no-watch reason, the
  session_create refusal and the `aidc mcp start` warning.
- design-11's opening loses the redundant "(the orchestrator)".
- Done when: the MCP suite and `tests/unit/test-config-sources.sh` (and the mcp start test) pass.

## Decisions made mid-build
- (01) Module aliases follow the package's short-alias style (`ts`, `tv`, `sf`): `ss` state,
  `orc` orchestrator config, `com` common, and later `tmx`, `tn`, `cbk`, `snd`, `dlv`, `sup`,
  `inv`, `rps`, `ses`. Chosen so no alias is also a local name anywhere (checked by the move
  tool); `cfg` was not usable, the tests use it for config paths.
- (01) Tests that captured `tools.log_event` now capture it in tools and every service module
  at once (`tests/logs.py`), since each module binds its own `log_event`: a capture of one
  module would miss events logged from another, and an assertion that an event is absent
  would then pass for the wrong reason.
- (01) The two tests that scan source (every envelope carries a known code; off-loop bodies
  touch no loop state) scan tools.py and the whole service, and follow `alias.name` calls
  into other modules; each was checked to fail on a planted violation.
- (02) `auth._load_token` becomes `auth.load_token`, called as `auth.load_token()` from the
  tools and the service: it was shared across modules, and a name imported into each module
  is a binding per module, so a test's patch of one (as the round-trip rig did) stopped
  reaching the callback POST once that moved. Tests that patched `tools.asyncio`,
  `tools.httpx`, `tools.subprocess` etc. now name those modules directly (the same objects;
  the patches were always module-wide).
- (03) The service's resume entry points are `startup.resume(resume_watchers)` and
  `delivery.resume_watches(on_resumed)`; `tools.resume_on_startup(app)` and
  `tools.resume_watchers(app)` keep their names as the adapters that bind the app, so the
  server and the tests that drive startup through them are unchanged. The service modules
  import one another without a cycle: state, config, tmux at the bottom; turns, callbacks;
  delivery and sending; startup on top.
- (04) Service operation names: `sessions.create|list_sessions|status|kill|exec_command|
  transcript|interrupt|file_put|audit_get`, `invoke.invoke|invoke_async`,
  `sending.send|run_turns|queue_cancel`, `delivery.watch|resend|unwatch`; the repository and
  file tools and session_mcp_set were already one call and call `repos.in_repo` /
  `sessions.hand_session_mcp` directly. Each operation's body is the tool's body verbatim,
  with `ctx` replaced by the hooks; `call_key` is computed by the adapter before the call
  (it reads only the request's headers, so when it is read does not matter).
- (04) Docs that named tools.py internals now name the service modules (design-10 cross
  references, design-13's Shape, boundary-patterns' producers, project-preferences' module
  split). boundary-patterns also lost a redundant "(the orchestrator)", like design-11's.
- (05) `callback_url:"x"` (no space after the colon): both now take it as the key when naming
  a misplaced section, as the Python check already did. Chosen over the YAML rule (a plain
  scalar, not a key) because both readers of `orchestrator.callback_url`, the shell's
  `_aidc_yaml_nested` and aidc-mcp's `_orchestrator_setting`, already read it as the key: the
  misplaced check now matches what the readers would do with the same line.
- (05) The `aidc mcp start` warning is `aidc_callback_url_warning` in lib/config.sh (printing
  its lines; cmd-mcp.sh sends them to err), so a unit test can call it without docker.
