# Design 13 — aidc's Control Plane as 3tears Tools

**What this covers.** Rebuilding aidc's MCP server (`mcp/`) on 3tears, the public MIT Python
package family: each aidc tool becomes a 3tears tool, so one implementation is reachable two ways.
**Local mode** serves its own MCP endpoint, as aidc is used today, with no 3tears infrastructure.
**Mesh mode** joins a 3tears mesh as a tool server, where an orchestrator calls the tools and the
mesh's hub can publish them as MCP and HTTP API endpoints. Observability moves to
`3tears-observe`.

**Requirements:** owner rulings of 2026-11-24 ("aidc's MCP server becomes a 3tears tools
server"); MCP-01..45 constrain what must be preserved.

**Status:** investigation, 2026-11-24. To be built after the Kubernetes backend work (design-12).
Read against 3tears 0.95.0 and aidc 1.9.10. Decisions marked **open** await the owner.

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

1. **Separate the service from the transport**: move watchers, queues, delivery and resume out
   of `tools.py` into a service module with no MCP types; tools become thin. Behaviour preserved;
   the large internal suites carry over.
2. **The TearsTool layer and the local face**: each tool as a `TearsTool`; an adapter to
   `3tears-mcp`; local mode serves as today. Wire tests rewritten for the new transport.
3. **Observability on `3tears-observe`**, keeping the access log file.
4. **Mesh mode**: a ToolServer entry point, pod identity and registration, grants, the mesh
   delivery channel if agreed.
5. **2.0 release**: contract regenerated, CHANGELOG, README.

## Open questions for the owner

1. Progress messages: local-only, or ask 3tears for a progress channel?
2. Mesh delivery of finished turns: keep the webhook, or add a NATS subject the orchestrator
   consumes?
3. Packaging: one image with mesh support, or a light default plus a mesh variant?
4. Upstream work in 3tears worth doing first: a `TearsTool` → `McpTool` adapter, MCP resources in
   `3tears-mcp`, a way to serve `face_api` without the hub (the owner wants an API face; today
   only the hub serves one).
