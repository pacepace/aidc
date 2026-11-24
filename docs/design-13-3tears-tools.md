# Design 13 — aidc 2.0: Adopting 3tears

**What this covers.** Rebuilding aidc's MCP server (`mcp/`) on 3tears, the public MIT Python
package family: each aidc tool becomes a 3tears tool, so one implementation is reachable two ways.
**Local mode** serves its own MCP endpoint, as aidc is used today, with no 3tears infrastructure.
**Mesh mode** joins a 3tears mesh as a tool server, where an orchestrator calls the tools and the
mesh's hub can publish them as MCP and HTTP API endpoints. Observability moves to
`3tears-observe`.

**Requirements:** owner rulings of 2026-11-24 ("aidc's MCP server becomes a 3tears tools
server"; "2.0 is 3tears adoption"; enhance 3tears where it falls short, starting with
`3tears-mcp`; local mode or mesh; use `3tears-observe`); MCP-01..45 constrain what must be
preserved.

**Status:** plan, 2026-11-24. Built after the Kubernetes backend work is finished (design-12;
owner ruling). Read against 3tears 0.95.0 (all packages alpha, version-locked to one minor) and
aidc 1.9.10. Decisions marked **open** await the owner.

---

## Shape

```
aidc control plane
├─ core (no transport): transcript, turns_view, screen, repo, headless, session_facts,
│      session_mcp, backend           (already transport-free; their tests carry over)
├─ service (one per install, one event loop): watchers, send queues and drainers, delivery
│      with retry and dead letters, resume on start, persisted state      (tools.py today)
├─ tools: one 3tears TearsTool per aidc tool, a thin layer over core + service
└─ faces
   ├─ local:  3tears-mcp McpServer (stdio or Streamable HTTP), bearer token -> Identity,
   │          through an adapter TearsTool -> McpTool      (no NATS, no hub, no database)
   └─ mesh:   3tears ToolServer on NATS; the hub publishes face_mcp / face_api for outsiders
```

The service stays one process with one event loop in both modes: its invariants (one drainer
per session, the per-session locks, exactly-once delivery from a watermark and a ledger) assume
it. On a mesh it runs as a single replica per aidc install; on Kubernetes that is the per-user
server already designed (K8S-07).

## What 3tears provides (measured in the 3tears source)

- **A tool** subclasses `TearsTool` and implements `async execute(**kwargs) -> ToolResult`, its
  `mcp_schema()` (input and optional output schema, version, timeout), `mcp_name()` (namespaced
  `{package}.{name}`) and `mcp_version()`. `ToolResult` carries `success`, `content` (a string),
  `metadata`, `error` and an `error_code` from a closed set of five (CONFLICT,
  MALFORMED_REQUEST, PERMISSION_DENIED, TOOL_AUTHORIZATION_UNAVAILABLE, TOOL_NOT_READY).
- **Faces** (`face_platform_tool`, `face_mcp`, `face_api`, `face_rest`) are declarations on the
  registration manifest; 3tears itself serves none of them. On a mesh the hub acts on them.
- **A ToolServer** registers tools over NATS, answers calls in a queue group, and accepts only
  calls the registry proxied, each carrying a hub-signed caller identity and a body-bound proxy
  assertion it verifies (fail-closed: no single-user shortcut). It needs NATS with callout auth,
  a registered pod identity and key, and the registry and hub running.
- **`3tears-mcp`** serves an MCP server on its own (stdio or Streamable HTTP; stateless by
  default), with per-tool permissions and a pluggable identity resolver for bearer tokens. Base
  dependencies: the MCP SDK, 3tears-observe, httpx, starlette, uvicorn.
- **Long calls:** a caller can ask for the result on a subject (the pod answers "accepted" at
  once); `BackgroundOperation` gives a start-now, poll-for-status pattern. There is no progress or
  streaming channel and no per-call cancel; a hard timeout is the only stop.
- **`3tears-observe`:** structured logging with correlation, `@traced` tracing, Prometheus
  metrics, OpenTelemetry export, all zero-cost when switched off.

Not found in 3tears: an adapter from `TearsTool` to `McpTool`; anything that serves `face_api` or
`face_rest` outside the hub; MCP resources, `tools/list_changed`, progress or logging
notifications in `3tears-mcp`; a provisioning CLI for tool pods. The hub's own MCP and API face
is not in the 3tears repo, so what it supports is unknown here.

## What aidc's server does (inventory)

- **23 tools** in `mcp/published-tools.json`: session create, list, status, exec, invoke (blocking
  and async), send, watch, unwatch, resend, interrupt, queue cancel, transcript, the read-only
  repo and file tools, `file_put`, `audit_get`, `session_mcp_set`. `session_kill` and
  `session_run` are deliberately not offered.
- **5 resources** (`aidc://sessions`, `aidc://config`, per-session status and audit files).
- **Out-of-band delivery:** a finished turn is POSTed to the orchestrator's callback URL with
  retry and dead letters, exactly once (MCP-17/18/19), from per-session transcript watchers; a
  send queue per session drains when the session is free (MCP-28/29/30/44); resume on start
  (MCP-34) from state files.
- **Protocol extras:** `ctx.info` messages during `session_create` and `session_invoke` (named
  progress in MCP-07, implemented as logging); tool descriptions that list the watched sessions,
  announced by `tools/list_changed` (MCP-21); a disconnect watcher that stops a blocking
  `session_invoke` when its client goes away; server `instructions` steering long work to
  `session_send`.
- **Contract:** every result is the envelope `{ok, data}` / `{ok: false, error, error_code}`
  with a closed set of 20 aidc error codes (design-10 D6, MCP-32); `published-tools.json` is
  checked byte for byte; within 1.x only additions are allowed (README).
- **Auth and scope:** one bearer token (also the outbound callback credential); session scope by
  `AIDC_MCP_ALLOWED_SESSIONS`; a taint gate on most tools.

## Mapping, and what needs a decision

| aidc today | On 3tears | Recommendation |
|---|---|---|
| 23 tools | 23 `TearsTool`s over the core and service | Clean. Tool names become namespaced (`aidc.session_send`): a contract change (see "Contract"). |
| Envelope with 20 error codes | `ToolResult` with 5 platform codes | Keep the envelope as the tool's content (JSON), unchanged for callers; `success` mirrors `ok`; the aidc code also in `metadata`. Use the 5 platform codes only for their own meaning (bad arguments, permission). |
| Progress during create and invoke | none | **Open.** Keep `ctx.info` in local mode only; on a mesh, `session_create` returns when the session is ready (as today, without phase messages), and long work goes through `session_send` / `session_invoke_async`. |
| Resources | none in `3tears-mcp` | Their content already has tool equivalents (`session_list`, `session_status`, `audit_get`); drop the resources at the major version, or add resource support upstream in `3tears-mcp`. |
| Dynamic descriptions + `tools/list_changed` (MCP-21) | stateless, not supported | Drop at the major version: `session_list` / `session_status` already say which sessions are watched. |
| Blocking `session_invoke` with disconnect cancel | no cancel channel | Keep it in local mode with today's disconnect watcher; on a mesh, offer `session_invoke_async` and `session_interrupt(target="headless")` (blocking calls would sit inside the registry's call deadline). |
| Webhook delivery to the orchestrator | no push channel in the tool contract | Keep the service's webhook in both modes; **open:** add a NATS-subject delivery for mesh mode, agreed with the orchestrator (design-10 D5's rule for payload changes). |
| Bearer token, scope env var | local: identity resolver; mesh: hub-signed caller identity and grants | Local: the bearer resolves to one admin identity, scope as today. Mesh: grants per tool decide who may call; `AIDC_MCP_ALLOWED_SESSIONS` stays as a per-install limit; `conversation_id` must be injected by the hub as the orchestrator injects it today. |
| `audit.log_event` JSON access log | `3tears-observe` | Structured logs and traces through observe; keep a file sink for the access log, since it is aidc's audit record of tool calls. |
| `session_create` opt-in (MCP-38) | — | Unchanged: the tool is registered only when enabled. |

## Which 3tears packages aidc 2.0 uses

Surveyed 2026-11-24: every package of 3tears 0.95, against aidc's needs. "Local" means it works
with no 3tears infrastructure (no NATS, no Postgres, no hub).

| Package | Use in aidc 2.0 | Local? | Notes |
|---|---|---|---|
| `3tears-mcp` | **Adopt, and enhance upstream** (below): the local MCP face, per-tool permissions, bearer identity | yes (base install; bring our own `Authorizer`) | Its `[grants]` extra needs Postgres: not used in local mode |
| `3tears-tool-schema` | **Adopt**: flat, self-contained JSON schemas for every tool | yes | No dependencies |
| `3tears-observe` | **Adopt**: structured logs with correlation, tracing, metrics | yes | Not an audit trail: the access log stays a file sink |
| `3tears-agent-tools` | **Adopt for mesh mode**: `TearsTool` as the one tool definition, `ToolServer` on the mesh | the `TearsTool` type, yes; `ToolServer`, no | Heavy dependency tree; its closed `ToolResult` error vocabulary is the model for the new MCP error model |
| `3tears-nats`, `3tears-registry` | **Mesh mode**: transport, catalog, routing, caller identity | no | Registry's real grants go through the hub |
| `3tears-agent-audit` | **Mesh mode**: tool-call audit events to the hub's table | no (NATS) | Publish never raises, so events can be lost when NATS is down: keep the local audit file as the record of truth, or fix upstream |
| `3tears-agent-acl` | **Later**: per-caller grants on the destructive tools for multi-user Kubernetes | no (Postgres) | Path-glob file grants fit `file_get` / `file_put` |
| `3tears-iam` | **Later**: real login if multi-user grows past trusted peers | yes (in-memory stores) | OIDC, GitHub login, DPoP |
| `3tears-object-store` | **Possible**: audit artifacts (filesystem driver, optionally encrypted) | yes (filesystem) | Importing it pulls aioboto3 and pins botocore |
| `3tears-evals` | **Possible**: evaluate orchestrator behaviour against aidc offline | yes | Not a runtime need |
| `3tears` (core) | **Not in local mode as it stands**: durable tiers need Postgres, NATS or git+NATS | no | Candidate upstream work: a filesystem L3 (below) |
| scheduled-jobs, epoch, wake, channels, conversations, workspace, memory, identity, intention, knowledge, skills, models, langgraph, search, scrape, geo, backup, datasources, enforcement, interfaces, media-contracts | **Not used** | — | Built for multi-pod agent platforms (Postgres, conversations, customers) or unrelated domains. `wake` is a scheduler, not a "turn finished" notifier. `enforcement` would push 3tears conventions onto all of aidc's source. |

What stays aidc's own: the service (watchers, send queues, exactly-once delivery with retry and
dead letters, resume), the taint gate (as a custom `Authorizer` over per-session state), the
session backends (Docker, Kubernetes), and the CLI.

## Upstream work in 3tears

In the order 2.0 needs it. Each is a 3tears change of its own, reviewed and released there,
then picked up by pinning the family's new minor.

1. **`3tears-mcp`: a call context for handlers.** Handlers are called as `handler(**arguments)`
   and see nothing of the request, so they can neither report progress nor notice cancellation.
   Add an opt-in context parameter (detected by signature, existing handlers unchanged) exposing
   the progress token, `report_progress`, a log channel and a cancellation signal.
2. **`3tears-mcp`: progress and logging.** Over Streamable HTTP these ride a per-request event
   stream (`json_response=False`), which works even in stateless mode.
3. **`3tears-mcp`: a richer error model.** Today the codes are literals in the dispatcher, and
   several failures (identity unavailable among them) collapse into `PERMISSION_DENIED`. Add a
   closed, documented code set with retryable and field metadata, an exception-to-code
   registry, and room for a server's own codes, aligned with agent-tools' `ToolResult`
   vocabulary. aidc's 20 codes then become real protocol codes, not only envelope text.
4. **`3tears-mcp`: resources** (`McpResource`, `ResourceProvider`, list, read, templates, a
   permission per resource), mirroring tools. Straightforward in both SDK majors.
5. **`3tears-mcp`: an optional stateful mode** for `tools/list_changed`, resource subscriptions
   and request-level cancellation, re-validating the bearer identity on every message (a
   session outlives the request that opened it). Stateless stays the default.
6. **A `TearsTool` → `McpTool` bridge**, so one tool definition serves both faces.
7. **A way to serve `face_api` without the hub** (today only the hub serves API faces), so local
   mode can also offer the HTTP API the owner wants.
8. **Possible: L1 on a file, for an L1-only store.** 3tears already runs a collection with no
   L2 (`NO_L2`) and no L3 (`l3_pool` None), and L1 has no size-based eviction (only the
   absence markers are capped). L1 is SQLite opened as a named in-memory database
   (`cache/sqlite.py`, `vfs=memdb`); a setting to open a file instead (write-ahead log on) would
   make an L1-only store durable on one machine. aidc's queues, ledger, watches and dead letters
   could then be 3tears collections locally, and gain L2/L3 on a mesh by configuration. To check
   before relying on it: every path that drops an L1 row because L3 is the record (an
   invalidation, a failed write's eviction) must not run in an L1-only store, and the
   `DataStore` methods that refuse without an L3 must not be ones aidc needs. Weigh against
   keeping aidc's temp+rename files, which work.
9. **`3tears-agent-audit`: a durable local sink or a publish that reports failure**, so an audit
   trail cannot drop events silently.

Two cross-cutting facts: `3tears-mcp` supports two MCP SDK majors (1.x and 2.x), so each feature
is built twice unless 1.x is dropped first; and the family is alpha, with no compatibility
across minor versions, so aidc pins one minor and moves with it.

## Contract

Namespaced tool names, dropped resources and dropped dynamic descriptions are breaking changes,
so the rebuild is aidc **2.0**, announced in the CHANGELOG, with `published-tools.json`
regenerated. The callback payload (design-10 D5) does not change unless a mesh delivery is
agreed.

## Packaging

- Local mode needs `3tears-mcp` and `3tears-observe` (light). Mesh mode needs
  `3tears-agent-tools` and its family (heavy: Postgres drivers, LangGraph and more), pinned to one
  3tears minor version (`>=0.95,<0.96`-style), so aidc's releases follow 3tears' minor releases.
- **Open:** one image with both (simplest; larger), or a `mesh` extra and a second image (light
  default for people who never join a mesh).

## Work, in order

1. **Upstream, `3tears-mcp`**: items 1-5 above, as 3tears releases.
2. **Separate the service from the transport** in aidc: watchers, queues, delivery and resume
   out of `tools.py` into a service module with no MCP types; tools become thin. Behaviour
   preserved; the large internal suites carry over. (Can start in parallel with step 1.)
3. **Tools as `TearsTool`s, local face on the enhanced `3tears-mcp`** through the bridge;
   schemas via `tool-schema`; the taint gate as an `Authorizer`; aidc's error codes as real
   codes; progress, resources, `tools/list_changed` and cancellation kept. Wire tests rewritten.
4. **Observability on `3tears-observe`**, keeping the access log file.
5. **Mesh mode**: a `ToolServer` entry point, pod identity and registration, grants, mesh audit,
   the mesh delivery channel if agreed; the per-user server on Kubernetes (K8S-07) runs in this
   mode or locally.
6. **aidc 2.0**: `published-tools.json` regenerated, CHANGELOG with the upgrade notes, README.

## Open questions for the owner

1. Progress on the mesh: carry it through `TearsTool` (another upstream change in agent-tools
   and the registry), or keep progress local and use the async tools on the mesh?
2. Mesh delivery of finished turns: keep the webhook, or add a NATS subject the orchestrator
   consumes (agreed with the orchestrator, design-10 D5)?
3. Packaging: one image with mesh support, or a light default plus a mesh variant?
4. Durable state: an L1-on-a-file store in 3tears core (upstream item 8), or keep aidc's files?
5. `3tears-mcp`'s SDK 1.x support: keep building each feature twice, or drop 1.x first?
