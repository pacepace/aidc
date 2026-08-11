# Design 08 — MCP Control Plane

**What this covers.** The control API. AI orchestrators (Saoirse) call into aidc through MCP. One global server. Multi-session aware. Real auth, real transport, no phases.

**Requires:** MCP-01..14 (added in `docs/done/requirements.md` follow-up).

---

## Why MCP

REST would work. MCP wins because every Claude-based orchestrator already speaks it. Drop `aidc` into Saoirse's MCP server list, every tool we expose becomes a function call. No client SDK to write, no docs to follow — tool discovery is the protocol.

Composability is the second prize. aidc tools chain with GitHub MCP, filesystem MCP, anything else Saoirse has. One conversation, many tools, no glue code.

---

## Runtime

One container. Not per-session.

```
host
├── docker daemon
├── aidc-mcp  (this design)
│     ├── MCP streaming-HTTP server on ${bind_address}:${port}
│     ├── /var/run/docker.sock  (mounted from host)
│     └── shells out to /usr/local/bin/aidc  (the CLI)
└── per-session stacks  (aidc-<name>-dev, -squid, -policy, -refresher, -audit)
```

`aidc-mcp` is the **only** process Saoirse talks to. It manages every session by name. Saoirse doesn't track per-session URLs — there's one URL, period.

Lifecycle is `aidc mcp start | stop | status | logs | token rotate`. Same CLI, same conventions as the rest.

The dev containers cannot reach `aidc-mcp`. Different Docker network, no shared volumes that matter, no overlap. The control plane is one-way: Saoirse → aidc-mcp → sessions.

---

## Tools

| Tool | Returns | Notes |
|------|---------|-------|
| `session_create(name, profile, repo, workspace?)` | session info dict | Streams progress: pulling, starting squid, waiting healthy, dev up |
| `session_list()` | array of sessions w/ status + taint | Sync |
| `session_status(name)` | full status object | Sync |
| `session_kill(name)` | confirmation | Sync; preserves audit dir |
| `session_exec(name, cmd, timeout?)` | stdout, stderr, exit | Default timeout 60s; longer ops use streaming |
| `session_invoke(name, prompt, options?)` | claude's response | Streams tokens back; respects in-container yolo mode |
| `file_get(name, path)` | content (text or base64 for binary) | Reads from mounted repo only; path must be inside REPO_PATH |
| `file_put(name, path, content, mode?)` | confirmation | Writes via dev container as vscode user; audited |
| `audit_get(name, since?, kind?)` | array of audit events | Reads from session's audit dir |
| `taint_mark(name, reason)` | confirmation | Manual taint; same downstream behavior as auto-taint |

**Naming convention:** `<noun>_<verb>`. Lowercase snake_case. Stable; never renamed once published.

**Error envelope:** every tool returns `{ok: bool, error?: string, data?: ...}`. MCP's structured errors wrap this. Saoirse sees the error string in `error`.

---

## Resources

Read-only data. Lighter than tools, no side effects.

| URI | Contents |
|-----|----------|
| `aidc://sessions` | live JSON list of all sessions |
| `aidc://sessions/{name}/status` | live JSON status for one session |
| `aidc://sessions/{name}/audit` | listing of files in the session's audit dir |
| `aidc://sessions/{name}/audit/{filename}` | the named audit file's contents |
| `aidc://config` | the effective global aidc config |

Saoirse subscribes to whichever resources she needs. The server pushes updates on change for `aidc://sessions` and `aidc://sessions/{name}/status` (so she sees taint events the instant they fire).

---

## Transport

**Streaming HTTP** (the modern MCP transport). Single endpoint accepts JSON-RPC over HTTP with optional SSE for streaming responses + notifications. No WebSocket, no stdio for remote.

Server emits **progress notifications** during long-running tools (`session_create` is the obvious one). Claude Code as an MCP client renders these inline; Saoirse sees them as they happen.

---

## Authentication

Single bearer token. One token per host. Anyone who has it has full access — the trust boundary is the token, not finer-grained ACLs.

```
Authorization: Bearer <token>
```

- Stored in `~/.config/aidc/mcp-token` (0600).
- Auto-generated on first `aidc mcp start` if absent. 32 bytes, base64url, no padding.
- Rotated with `aidc mcp token rotate` — invalidates the old token, prints the new one, restarts `aidc-mcp` so it picks up the new value.
- Saoirse's MCP client config carries the same token. We do not solve token distribution for v1; copy/paste it.

Unauthenticated requests get `401 Unauthorized`. Malformed Bearer headers get `400`. Both are logged to the audit dir.

---

## Network binding

The container binds with Docker's `-p` flag to a specific host interface address. Default: `127.0.0.1`. Pace's case: his ZeroTier interface address. Tailscale users: their `tailscale0` IP. Whatever the user configures, that's where the listener lives.

Config:

```yaml
mcp:
  bind_address: 192.168.196.X    # ZeroTier interface IP on the host
  port: 7878                     # default
```

Resolution at `aidc mcp start`:

1. Read `mcp.bind_address` from `~/.config/aidc/config.yaml`. Default `127.0.0.1`.
2. Verify the address belongs to a real interface on the host (`ifconfig` / `ip addr`). Refuse to start if not — refuses to silently bind to 0.0.0.0.
3. `docker run -p ${bind_address}:${port}:${port} aidc/mcp:local`.

No host networking required. Works identically on macOS Docker Desktop, native Linux, WSL2.

---

## Implementation

**Language:** Python 3.12. The Anthropic MCP SDK has the most complete Python implementation; the rest of aidc is bash but the MCP server is the one place where typed schema + async is worth the runtime dep.

**Container:** Alpine 3.20 base. `pip install mcp` (or `anthropic-mcp`, whichever is current). Mount the host's aidc repo as `/aidc/` (read-only) so the server can shell out to the CLI it ships with. Mount `/var/run/docker.sock` so the CLI can drive `docker compose`. Mount `~/.config/aidc/` for the token + config.

**Wrapping the CLI:** the MCP server doesn't reimplement session management. Each tool call shells out to `aidc <subcommand>` and parses the result (the CLI already prints structured fields). This avoids two codebases drifting.

**Streaming:** for `session_create` and `session_invoke`, the server tails the underlying CLI's stdout and emits MCP progress notifications. `session_create` notification chunks: image-build (if needed), proxy-stack-up, squid-healthy, refresher-started, dev-container-started, ready.

**Resource subscriptions:** the server watches `~/aidc-audit/` for new files (fs notify) and pushes resource-update notifications to subscribed clients.

---

## Isolation guarantees

aidc-mcp is the **highest-privilege** component in the system. It:

- Has the host Docker socket (can create / kill / inspect any container).
- Can read/write the user's `~/.config/aidc/` and `~/aidc-audit/`.
- Holds the bearer token.

The dev containers cannot reach it. The proxy stack cannot reach it. Saoirse-on-remote-host can — via the bearer token, over the configured network interface, and that's the entire trust surface.

If the bearer token leaks, the leaker can: spin up sessions, exec arbitrary commands in them, read any file via `file_get`. Rotate immediately if suspected.

aidc-mcp itself does not store conversation history, secrets, or credentials. It's a thin tool-router. Forensic data lives in audit dirs (per-session), not in the MCP server's state.

---

## Cross-references

- CLI lifecycle: `docs/done/design-05-cli.md`
- Per-session topology: `docs/done/design-04-proxy-stack.md`
- Safety model + taint: `docs/done/design-07-safety-model.md`
- Tmux / human attach (parallel path): `docs/done/design-06-remote-control.md`
- MCP spec: https://spec.modelcontextprotocol.io/
- Claude Code MCP integration: https://code.claude.com/docs/en/mcp
