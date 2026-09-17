# Design 11 — Testing an Orchestrator That Runs Inside a Dev Container

**What this covers.** How an orchestrator under development (MetaLLM) runs inside an aidc dev
container, iterating on its own code, while it drives another aidc session through an `aidc-mcp`
server. It also covers what keeps that from handing the sandboxed agent control of every session
on the host.

**Requirements implemented:** MCP-31 (session-scoped MCP). Relates to MCP-12 (dev containers
cannot reach `aidc-mcp`).

**Status:** the session-scoped mode is built; the MCP-12 enforcement and the joint test are next
(build plan Chunks 06–08).

---

## The problem

Design 10's behaviour has to be tested end to end with the real orchestrator. That orchestrator
has to run where its agent can change and restart it, which is an aidc dev container. It then
needs two network paths:

- **orchestrator → MCP** (`session_send`, `session_status`, …);
- **MCP → orchestrator** (the callback POST with each finished turn).

It also needs the MCP's bearer token. The MCP drives docker on the host, so that token normally
reaches every session: `session_exec` into it, `file_put` into it, `session_create` new ones. A
token inside a `--dangerously-skip-permissions` sandbox would undo the sandbox.

## Facts measured on 2026-09-17

- **A dev container reaches an MCP port on the host's overlay IP through squid.** From the
  `measure` session, `curl http://10.23.68.16:17999/mcp` (proxy env set) returned 401 from a
  scratch MCP, whose audit log recorded the request from the squid container's address. Without
  the proxy the connection failed (no route). `squid.conf` allows every destination for local
  sources (`http_access allow localnet`), so the live MCP at `10.23.68.16:7878` is reachable
  the same way, and only its token stops a request. That contradicts MCP-12.
- **A port published with `aidc proxy` binds `0.0.0.0:<port>` on the host**, so a process on the
  host (the MCP) can reach a service inside a dev container.

## Session-scoped MCP (MCP-31)

`AIDC_MCP_ALLOWED_SESSIONS=jointtest` limits a server to the named sessions (`scope.py`):

- every tool that takes a session `name` is wrapped by `tools._scoped`, which refuses any other
  name before the tool runs (a test asserts every such tool is wrapped);
- `session_create` is refused;
- `session_list` and the `aidc://sessions` resource show only the allowed rows;
- the per-session resources refuse other names, and `aidc://config` is refused;
- `resume_send_queues` skips other sessions' queue files, so a scoped server sharing a state dir
  can neither resume nor dead-letter them.

Unset, the server behaves exactly as before.

## Joint test topology

```
host
├─ aidc-mcp (live, :7878)                 untouched
├─ test aidc-mcp (this branch, :17878)    AIDC_MCP_ALLOWED_SESSIONS=jointtest
│    own token, state dir, audit log, config.yaml (callback_url → orchestrator)
├─ session `metallm-test` (dev container) orchestrator agent + MetaLLM running
│    MetaLLM → http://10.23.68.16:17878/mcp via squid, with the test token
│    MetaLLM API published with `aidc proxy` → host 0.0.0.0:<port>
└─ session `jointtest` (dev container)    the Claude session MetaLLM drives
```

The test MCP runs from the branch checkout on the host (`python -m aidc_mcp` with
`AIDC_MCP_PORT`, `AIDC_MCP_TOKEN_FILE`, `AIDC_MCP_AUDIT_LOG`, `AIDC_MCP_WATCHER_STATE`,
`AIDC_MCP_TRANSCRIPTS` and `AIDC_MCP_ALLOWED_SESSIONS`). Its `config.yaml` sits next to its
token file.

## MCP-12 enforcement (next)

Squid gets a deny rule for the live MCP's bind address and port, ahead of `allow localnet`, so a
dev container cannot reach it at all. The test MCP runs on a different port and stays reachable
for the length of the test. That exposure is deliberate, and bounded by MCP-31.
