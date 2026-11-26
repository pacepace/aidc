---
artifact: api-notes
scope: 3tears-adoption
pinned_commit: 1378d2e9a540cdef98b28c93dd03d40402054469
branch: feat/mcp-face (unreleased, github.com/pacepace/3tears)
read: 2026-11-26
---

# 3tears API notes (verify-api)

Read from the 3tears source **at commit `1378d2e9a540cdef98b28c93dd03d40402054469`** of the
unreleased branch `feat/mcp-face`, the commit `mcp/pyproject.toml` pins. The branch is still under
review, so these notes hold for that commit only. When the pin moves, re-read the surfaces below and
record what changed under "Pin history".

Packages aidc takes (local mode, TRS-17), all version `0.95.0` at this commit:

| Distribution | Import | Base dependencies |
|---|---|---|
| `3tears-mcp` | `threetears.mcp` | 3tears-observe, jsonschema, `mcp>=2.0,<3`, httpx, starlette, uvicorn |
| `3tears-tool-contract[mcp]` | `threetears.tool_contract` | 3tears-observe, 3tears-tool-schema; the `mcp` extra adds 3tears-mcp |
| `3tears-tool-schema` | `threetears.tool_schema` | none |
| `3tears-observe` | `threetears.observe` | none (extras: `otel`, `otel-http`, `prometheus`, `asgi`) |

`3tears-mcp`'s `grants` extra (Postgres-backed `LocalGrantAuthorizer`) is not installed; aidc brings
its own authorizer. The resolved lock holds no NATS client, Postgres driver, LangGraph or LangChain
(`mcp/tests/test_dependencies.py`).

## The bridge: a TearsTool served over MCP (U08)

`threetears.tool_contract.mcp_face.mcp_tool(tool, *, required_permission, name=None, title=None,
annotations=None) -> McpTool`

- Refuses a tool whose class does not set `face_mcp = True` (ValueError).
- `name` overrides the listed name (default `tool.mcp_name()`); aidc passes the 1.x local name
  (TRS-15). `prepare_arguments=` is passed to the `McpTool` (below).
- The listing is `tool.mcp_schema()`: `description`, `input_schema`, `output_schema`.
- The handler calls `tool.run(**arguments)` (coercion, then `execute`). If `execute` declares a
  parameter annotated `CallContext`, the call's context is passed under that name; otherwise
  `execute` is called with its arguments only.
- Result mapping (`_call_result`):
  - `success=True`: one text block holding `content`; `structuredContent` only when the tool has an
    output schema and `content` parses as a JSON object.
  - `success=False`: `tool_error(...)` — `isError` true, the content text unchanged (and, for a
    tool with an output schema whose content is a JSON object, that object as
    `structuredContent`; SDK 2.x clients do not validate structured content on an error result), the code from `ToolResult.error_code` if set, else
    `metadata["error_code"]` if a string, else `TOOL_ERROR`. A code the server never registered
    answers `HANDLER_ERROR` (logged once per code).
- **Consequence for aidc:** a failed envelope (`ok: false`) becomes `isError: true` on the protocol
  result with the aidc code under `_meta["threetears.mcp/error"]`. The envelope text is unchanged.

## TearsTool / ToolResult (U09)

`threetears.tool_contract`: `TearsTool` (ABC), `ToolResult`, `MCPToolDefinition`,
`TOOL_RESULT_ERROR_CODES` = {CONFLICT, MALFORMED_REQUEST, PERMISSION_DENIED,
TOOL_AUTHORIZATION_UNAVAILABLE, TOOL_NOT_READY}.

- Subclass implements `async execute(**kwargs) -> ToolResult`, `mcp_schema() ->
  MCPToolDefinition`, `mcp_name() -> str` (`{package}.{name}`), `mcp_version() -> str`. Overriding
  `run` raises TypeError at class creation.
- Class flags: `face_mcp` (default False — must be True for the bridge), `face_platform_tool`
  (True), `face_api` (False), `face_rest` (None), `tool_eligible`, `skill_eligible`,
  `requires_confirmation`.
- `ToolResult(success, content: str, metadata=None, error=None, error_code=None)`; `error_code` must
  be one of the five or None, and only on a failure (ValueError otherwise).
- `MCPToolDefinition(name, version, description, input_schema, output_schema=None,
  timeout_seconds=None)`.
- `run` coerces empty strings / JSON strings toward declared object/array types
  (`normalize_kwargs`); a keyword outside the schema passes through unchanged.

## McpServer (`threetears.mcp.McpServer`)

`McpServer(*, name, identity_provider, authorizer, registry=None, tool_provider=None,
error_codes=None, resources=None, resource_provider=None)`

- Exactly one of `registry` (`ToolRegistry`) and `tool_provider` (`Callable[[], Iterable[McpTool]]`,
  read on every `tools/list` and `tools/call`).
- At most one of `resources` (`ResourceRegistry`) and `resource_provider`.
- `version: str = ""` and `instructions: str | None = None` (keywords): `serverInfo.version` and
  the `initialize` result's `instructions` on handshake-era protocols (the 2026-07-28 equivalents
  otherwise).
- `await start()` (calls `authorizer.start()`) before any build/serve; `await stop()`.
- `build_http_transport(*, path="/mcp", stateless=True, json_response=True) -> McpHttpTransport`
  for embedding: add `transport.routes` (or `.endpoint`) to the host's Starlette app and enter
  `transport.lifespan()` in the host lifespan. Single-use. Also `build_http_app(...)`,
  `serve_http(...)`, `serve_stdio()`.
- **aidc runs `stateless=False` (TRS-08) and `json_response=False`** (progress and log
  notifications need the SSE stream; with JSON they are dropped and a warning is logged once).
- `notify_tools_changed()`, `notify_resources_changed()`, `notify_resource_updated(uri)` push to
  stateful sessions (and 2026-07-28 listen streams); never raise for an unreachable client.
- `error_codes` property: the server's `ErrorCodes`.
- DNS-rebinding protection: the transport builds the SDK's `StreamableHTTPSessionManager` with no
  security settings, which the SDK treats as protection off (aidc 1.x turned it off explicitly).

Dispatch order (`_dispatch`), each refusal an `isError` result with the code in `_meta`:
tool lookup (`UNKNOWN_TOOL`; provider failure `TOOLS_UNAVAILABLE`) → the tool's
`prepare_arguments`, when set (given a read-only mapping, answers a new dict; raising or
answering a non-dict is `INVALID_ARGUMENTS`) → jsonschema validation of the
arguments against `input_schema` (`INVALID_ARGUMENTS`, text `Input validation error: ...`,
`argument` set) → `identity_provider.identify()` (RuntimeError → `IDENTITY_UNAVAILABLE`) →
authorizer (`authorize_call` if the authorizer's class defines it, else `allows`; raise →
`AUTHZ_ERROR`; `False` → `PERMISSION_DENIED`; a `Refusal` → its code if registered, else
`PERMISSION_DENIED`) → handler (`McpToolError` → its code; a mapped exception → its code; other
exception → `HANDLER_ERROR`; `CancelledError` sets the context's cancel event and re-raises) →
output-schema check (`OUTPUT_VALIDATION_ERROR`).

Identity is resolved for `tools/call` and resource requests, **not for `tools/list`** or
`initialize`: an HTTP-level bearer check stays aidc's for those (and for the access log, MCP-14).

## Call context (U02/U03)

`threetears.mcp.CallContext(*, tool_name, request_id=None, progress_token=None,
progress_sender=None, log_sender=None, cancelled: asyncio.Event | None = None)`

- Properties: `tool_name`, `request_id`, `progress_token`, `cancelled` (bool).
- `await report_progress(progress, total=None, message=None)`: sends nothing without a progress
  token; raises ValueError if `progress` is not finite or not strictly greater than the last report.
- `await log(level, data, *, logger=None)`: `notifications/message` on the call's stream, filtered
  by the connection's `logging/setLevel` (handshake-era) or the request's opt-in (2026-07-28).
- `await wait_cancelled()`: returns only on cancellation (client `notifications/cancelled`, session
  close, or the client dropping the HTTP request that carries the call → the handler task is
  cancelled; the event is set in `_dispatch`). A drop cancels only that call, stateless and
  stateful, both protocol eras, **except** plain-JSON responses in stateless mode: aidc runs SSE
  (`json_response=False`). The transport's hook is
  `threetears.mcp.http_server.on_request_drop(callback) -> stop | None`.
- A handler asks for it by a parameter annotated `CallContext` (found by signature at `McpTool`
  construction; a name the schema also has is refused). Tests build one directly with recording
  senders.
- `LogLevel` = the RFC 5424 names, least severe first.

## Error model (U04)

`threetears.mcp.errors`: `ErrorCode(code, description, retryable=False)` (code matches
`[A-Za-z][A-Za-z0-9_]*`, lower case allowed); `ErrorCodes(codes=())` with `register(code)`
(case-insensitive clash → ValueError), `map_exception(exc_type, code)`, `get(name)`,
`for_exception(exc)`, `all()`; `McpToolError(code, message, *, argument=None)`;
`ERROR_META_KEY = "threetears.mcp/error"`; `error_detail(code, message, argument=None)` →
`{"code", "message", "retryable", "argument"?}`.

Built-in codes: UNKNOWN_TOOL, TOOLS_UNAVAILABLE (retryable), INVALID_ARGUMENTS,
IDENTITY_UNAVAILABLE, PERMISSION_DENIED, AUTHZ_ERROR (retryable), HANDLER_ERROR,
OUTPUT_VALIDATION_ERROR, TOOL_ERROR, UNKNOWN_RESOURCE, CONFLICT (retryable), MALFORMED_REQUEST,
TOOL_AUTHORIZATION_UNAVAILABLE (retryable), TOOL_NOT_READY (retryable).

aidc's 20 `ERROR_CODES` are lower case (`tainted`, `out_of_scope`, ...); none equals a built-in
code case-insensitively, so all register (checked 2026-11-26; `register` raises on a clash at
startup).

`threetears.mcp.tool_error(error, *, code=None, message=None, argument=None) -> CallToolResult`:
a mapping rides as `structuredContent` plus its JSON text; a string is the text alone.

## The call authorizer (U07)

`threetears.mcp.auth`:
- `ToolCall(tool_name, arguments: Mapping, required_permission)` (arguments read-only).
- `Refusal(code: ErrorCode | str, message, argument=None, content=None)`. With `content` (a
  mapping or text) a refused call answers that content as `tool_error` does (`isError`, the text
  block, `structuredContent` for a mapping) with the code under `_meta`; aidc passes its envelope
  so a refusal reads as 1.x's did (TRS-05).
- `CallAuthorizer` protocol: `Authorizer` plus `async authorize_call(identity, call) -> bool |
  Refusal`. Detected by the authorizer's **class** defining `authorize_call`.
- `ResourceRequest(uri, variables: Mapping, required_permission, action)` with `action` one of
  `"list"`, `"read"`, `"subscribe"`, `"listen"`; `ResourceAuthorizer` protocol: `Authorizer` plus
  `async authorize_resource(identity, request) -> bool | Refusal`, called (when the class defines
  it) for each fixed resource a listing would show and for every read, subscription and listen
  naming a resource; a template's listing still asks `allows`. A refusal answers JSON-RPC
  `RESOURCE_REFUSED` with its own code when registered, else `PERMISSION_DENIED`. aidc's scope
  filter on resources goes here (the URI's `name` variable).
- `Authorizer` protocol: `async allows(identity, permission) -> bool`, `async start()`, `async
  stop()`.
- A `Refusal` naming a registered code answers that code with `refusal.message`; an unregistered
  one answers `PERMISSION_DENIED` with `refused: <message>`.

## Identity (U06)

- `Identity(principal_type, principal_id: UUID, groups=frozenset(), roles=frozenset(),
  is_admin=False)`.
- `BearerTokenIdentityProvider(*, resolver: Callable[[str], Awaitable[Identity]], token_source:
  Callable[[], str | None])`; production `token_source` is
  `threetears.mcp.current_bearer_token`. Any failure → RuntimeError → `IDENTITY_UNAVAILABLE`.
  Re-resolved on every message, stateful sessions included (the SDK runs each message's handler in
  the request's contextvars).

## Resources (U05)

`threetears.mcp.resources`:
- `McpResource(uri, name, required_permission, reader, description=None, mime_type=None,
  title=None)`; reader called with no arguments.
- `McpResourceTemplate(uri_template, name, required_permission, reader, description=None,
  mime_type=None, title=None)`; reader called with the URI's template variables as keywords.
- Reader returns `str` (text), `bytes` (blob), `ResourceContent(uri, text=None, blob=None,
  mime_type=None)` or an iterable of them.
- `ResourceRegistry()` with `register(...)` and `all()`; or `ResourceProvider` (live set).
- Refusals are JSON-RPC errors: `UNKNOWN_RESOURCE` (INVALID_PARAMS); identity/permission/authz
  (`RESOURCE_REFUSED = -32010`); reader raised (INTERNAL_ERROR, `HANDLER_ERROR`).
- `resources/subscribe` in stateful mode; `McpServer.notify_resource_updated(uri)` pushes
  `notifications/resources/updated` to subscribers.

## tool-schema

`threetears.tool_schema.self_contained_input_schema(schema, *, tool_name) -> dict`: inlines every
local `$ref`, collapses `anyOf: [X, null]` to `X`, drops titles and the root description, keeps
field descriptions; always `type: object` with `properties` and `required`.
`declared_type(prop, schema)`.

## observe (chunk 05)

`threetears.observe`: `get_logger`, `configure_logging`, `set_context` / `get_context` /
`clear_context` (correlation fields), `traced`, `set_span_attribute`, `counter` / `gauge` /
`histogram` / `metered`, `CallMetrics`, `contain`, `spawn_background`, `cancel_and_wait`. Export
and metrics backends are extras (`otel`, `prometheus`); with neither installed they are no-ops.
Read in detail when chunk 05 starts (recorded below then).

## core: the SQLite L3 (chunk 07)

Not in aidc's lock yet. `threetears.core.backends.sqlite_file` exists at this commit. Importing it
loads `asyncpg` (its refusals raise asyncpg's error types, per the 2026-11-25 ruling) and
`sqlalchemy`; core's base dependencies also install `3tears-nats` (not the nats-py client). This
conflicts with TRS-01/TRS-17 as written; raised to the owner 2026-11-26. Read in detail when chunk
07 starts.

`threetears.mcp.tool.context_parameter_of(tool_name, handler, input_schema) -> str | None`: the
parameter a handler takes the call context in, as `McpTool` finds it (the bridge uses it for
`execute`). A PEP 695 alias of `CallContext` is read through.

## Pin history

- 2026-11-26: first pin, `b28bbebf4d662e5e6498b35a5c9af20955d108a6` (head of `feat/mcp-face`).
- 2026-11-26: moved to `bbbf5ead8d8c4838d800f95e488a7fafd8c04d65`. What changed for aidc:
  `McpServer` gained `version` and `instructions` (asked for by aidc); resources gained
  `ResourceAuthorizer` / `ResourceRequest`; `context_parameter_of` is public and the bridge uses
  it; the resource service's internal subscribe/unsubscribe were renamed watch/unwatch (not used by
  aidc); log levels are now kept per SDK connection. No signature aidc already used changed.
- 2026-11-26: moved to `3d5dd9cf91be988dba56c72e39b0600bdabef8f7`: `Refusal` gained `content`
  (asked for by aidc). Nothing else changed in the packages aidc uses.
- 2026-11-26: moved to `281ecb1f7559a02683becd62edd8acd2bb8b8c81`: a call whose client drops its
  HTTP request is cancelled (asked for by aidc, TRS-09; measured not cancelled at `bbbf5ead`).
  Nothing else changed in the packages aidc uses.
- 2026-11-26: moved to `3bc97f872b17edd7ff96948af3aa7833f10971b1`: a structured tool's failure
  carries its JSON object as `structuredContent` too (asked for by aidc, design-10 D6). Nothing
  else changed in the packages aidc uses.
- 2026-11-26: moved to `1378d2e9a540cdef98b28c93dd03d40402054469`: `McpTool` and `mcp_tool(...)`
  take `prepare_arguments` (a hook over a call's arguments before schema validation; asked for
  by aidc to keep 1.x's numeric strings working). Nothing else changed in the packages aidc uses.
