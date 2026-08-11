# task-10: MCP Control Server

## Objective

Build `aidc-mcp` — a Python-based MCP server that exposes the aidc CLI surface as MCP tools and resources for external AI orchestrators (Saoirse). Single global container per host. Streaming HTTP transport. Single bearer token. Wraps the `aidc` CLI rather than reimplementing session management.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| MCP-01 | aidc exposes an MCP server (`aidc-mcp`) | P0 |
| MCP-02 | Single global instance per host; manages all sessions by name | P0 |
| MCP-03 | Lifecycle: `aidc mcp start \| stop \| status \| logs \| token rotate` | P0 |
| MCP-04 | Streaming HTTP transport | P0 |
| MCP-05 | Bearer token at `~/.config/aidc/mcp-token` (0600) | P0 |
| MCP-06 | Auto-generate token on first start; `token rotate` invalidates + restarts | P0 |
| MCP-07 | Long-running tools emit MCP progress notifications | P0 |
| MCP-08 | Full tool surface (session_*, session_invoke, file_*, audit_get, taint_mark) | P0 |
| MCP-09 | Resource URIs + push notifications on change | P0 |
| MCP-10 | Bind to configurable host interface (default 127.0.0.1) | P0 |
| MCP-11 | Refuse to start if bind_address doesn't match a real interface | P0 |
| MCP-12 | Dev containers cannot reach aidc-mcp | P0 |
| MCP-13 | Tools shell out to the aidc CLI, not reimplement | P0 |
| MCP-14 | Audit log at `~/aidc-mcp-audit/access.log` | P1 |

---

## Design Context

From `docs/design-08-mcp-control.md` (whole doc is the design — read it first):

> One container. Not per-session. `aidc-mcp` is the only process Saoirse talks to. It manages every session by name.

> Tool implementations MUST shell out to the `aidc` CLI rather than reimplement session management.

> Streaming HTTP (the modern MCP transport). Single endpoint accepts JSON-RPC over HTTP with optional SSE for streaming responses + notifications.

> Stored in `~/.config/aidc/mcp-token` (0600). Auto-generated on first `aidc mcp start` if absent. 32 bytes, base64url, no padding. Rotated with `aidc mcp token rotate`.

> The container binds with Docker's `-p` flag to a specific host interface address. Default: `127.0.0.1`. Refuse to start if address doesn't belong to a real interface.

---

## Files to Create

### Container source (`mcp/`)

- `mcp/Dockerfile` — Alpine 3.20 base + Python 3.12 + uv + the MCP Python SDK + the `aidc` CLI (or call it from a mount)
- `mcp/pyproject.toml` — declares dependency on the official MCP SDK, plus stdlib only otherwise
- `mcp/src/aidc_mcp/__init__.py`
- `mcp/src/aidc_mcp/__main__.py` — entry point (`python -m aidc_mcp`)
- `mcp/src/aidc_mcp/server.py` — wires up the MCP server with tool + resource handlers
- `mcp/src/aidc_mcp/tools.py` — one function per tool; each shells out to the `aidc` CLI
- `mcp/src/aidc_mcp/resources.py` — resource handlers + change-watching for live ones
- `mcp/src/aidc_mcp/auth.py` — bearer-token verification middleware
- `mcp/src/aidc_mcp/audit.py` — append to `~/aidc-mcp-audit/access.log`
- `mcp/src/aidc_mcp/streaming.py` — helpers for emitting progress notifications during long tool calls

### CLI integration (`scripts/cmd-mcp.sh`)

A new subcommand dispatcher. `aidc mcp <verb>` → dispatches to:

- `start`   — generate token if absent; validate `mcp.bind_address`; `docker run -d` the aidc-mcp container; print the bind address + port + a redacted token reference
- `stop`    — `docker stop` + `docker rm` the container
- `status`  — show running / not running, port binding, last access time
- `logs`    — `docker logs aidc-mcp` (with -f support)
- `token rotate` — generate a new token; restart the container; print the new token (this is the one time the full token is shown)

### Compose / runtime artifact

The MCP server is launched directly by `aidc mcp start` (no compose; one container, no sidecars). The launch command:

```bash
docker run -d \
    --name aidc-mcp \
    --restart unless-stopped \
    -v /var/run/docker.sock:/var/run/docker.sock:rw \
    -v "${AIDC_ROOT}:/aidc:ro" \
    -v "${HOME}/.config/aidc:/aidc-config:ro" \
    -v "${HOME}/aidc-mcp-audit:/var/log/aidc-mcp:rw" \
    -e AIDC_MCP_PORT=${PORT} \
    -p "${BIND_ADDRESS}:${PORT}:${PORT}" \
    aidc/mcp:local
```

The `${AIDC_ROOT}:/aidc:ro` mount gives the container a read-only view of the host's aidc repo so it can find and exec the `aidc` CLI. Container's PATH is configured so `aidc` resolves to `/aidc/scripts/aidc`.

### Config schema additions (`scripts/lib/config.sh` + `docs/requirements.md`)

Add to defaults:

```yaml
mcp:
  bind_address: 127.0.0.1
  port: 7878
```

`load_config` should read these into `AIDC_MCP_BIND_ADDRESS` and `AIDC_MCP_PORT`.

---

## Implementation Notes

1. **MCP SDK choice.** Use the official Python SDK from Anthropic — `pip install mcp` (or whatever the package is named at implementation time). Check https://github.com/modelcontextprotocol/python-sdk for current name.

2. **Tool surface (from design-08).** Implement these exactly, with these names:

| Tool | Args |
|------|------|
| `session_create` | name (str), profile (str), repo (str), workspace (str, optional) |
| `session_list` | (no args) |
| `session_status` | name (str) |
| `session_kill` | name (str) |
| `session_exec` | name (str), cmd (str), timeout_seconds (int, default 60) |
| `session_invoke` | name (str), prompt (str) |
| `file_get` | name (str), path (str) |
| `file_put` | name (str), path (str), content (str), mode (str, optional like "0644") |
| `audit_get` | name (str), since (str ISO8601, optional), kind (str, optional) |
| `taint_mark` | name (str), reason (str) |

3. **Return envelope.** Every tool returns `{ok: bool, error?: str, data?: any}`. Tool errors don't raise MCP errors — they return `{ok: false, error: ...}` so the calling LLM can react to the error in natural conversation. Only protocol-level errors (auth failure, unknown tool) use MCP's structured error type.

4. **Bearer auth.** Implement middleware that checks `Authorization: Bearer <token>` against the token file's contents. Constant-time compare. Missing or wrong → 401. Log to audit either way.

5. **bind_address validation.** Before `docker run`, query host interfaces and confirm the configured address belongs to one of them. Use `ifconfig -a` (macOS) or `ip -j addr` (Linux). If not found, die with a clear message listing the available interface addresses for the user to pick from.

6. **Streaming notifications.** For `session_create`, run `aidc create ...` with a pipe; parse its stdout in real time; emit progress notifications like:
   ```
   { "kind": "phase", "name": "proxy-stack-up", "detail": "squid started" }
   { "kind": "phase", "name": "squid-healthy" }
   ...
   ```
   The aidc CLI already prints structured lines for these phases (see `cmd-create.sh`); use the existing output rather than adding a parallel telemetry stream.

7. **Resource subscriptions.** For `aidc://sessions` and `aidc://sessions/{name}/status`, watch `~/aidc-audit/` and the docker event stream. When a session's state changes (new session created, taint flag appears, container stops), push a resource-update notification to subscribed clients.

8. **No conversation state in MCP server.** Keep the MCP server stateless beyond the audit log. Per-session conversation memory + transcripts live in `~/.claude/projects/<encoded>/` and `~/aidc-audit/<session>/` — owned by the dev containers, not by aidc-mcp.

9. **Token rotation atomicity.** `aidc mcp token rotate`: generate new token → write to temp file → fsync → atomic rename → restart container. Container reads token on startup. Brief window during restart where neither old nor new auth works; document this.

10. **No Tailscale/ZeroTier client in the container.** The container binds to a host interface IP; the overlay network is handled by the host. Don't embed wireguard, zerotier, or tailscale binaries.

---

## Anti-patterns

- DO NOT reimplement session management in Python. Shell out to `aidc <subcommand>`. (MCP-13)
- DO NOT expose the bearer token in any tool response, log line, or status output. Only `aidc mcp token rotate` prints it.
- DO NOT bind to `0.0.0.0` by default. Default is `127.0.0.1`. User has to opt into a network-reachable interface explicitly.
- DO NOT install Tailscale/ZeroTier/Wireguard inside the container.
- DO NOT use stdio transport for this server. It's a long-running networked service, not a per-conversation companion.
- AVOID adding a Python web framework. The MCP SDK provides its own HTTP transport — use it directly.

---

## Success Criteria

- [ ] `aidc mcp start` brings the container up cleanly on first run (token auto-generated)
- [ ] `aidc mcp status` shows running, the bind address, port, and last access time
- [ ] `curl -H 'Authorization: Bearer $(cat ~/.config/aidc/mcp-token)' http://${bind}:${port}/...` (or whatever MCP's discovery endpoint is) returns the server's metadata
- [ ] `curl` WITHOUT the bearer returns 401
- [ ] `mcp` CLI client (or equivalent) can connect, list tools, list resources
- [ ] `session_list` tool returns the same data as `aidc list`
- [ ] `session_create` emits progress notifications during the ~30s create
- [ ] After create, `session_kill` tears it down
- [ ] `aidc mcp token rotate` produces a new token and the old one no longer authenticates
- [ ] Dev containers cannot reach `aidc-mcp` (verify: from inside an aidc session's dev container, attempt to connect to the MCP server's bind address — must fail)
- [ ] `aidc mcp stop` removes the container cleanly

---

## Verification

```bash
# 0. Configure bind address (use 127.0.0.1 for the smoke; ZeroTier IP for real)
cat > ~/.config/aidc/config.yaml <<EOF
mcp:
  bind_address: 127.0.0.1
  port: 7878
EOF

# 1. Build the MCP image
docker build -t aidc/mcp:local mcp/

# 2. Start the server
./scripts/aidc mcp start
TOKEN=$(cat ~/.config/aidc/mcp-token)

# 3. Status
./scripts/aidc mcp status

# 4. Unauthenticated request -> 401
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:7878/mcp
# expected: 401

# 5. Authenticated request -> 200 with capabilities
curl -s -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
     http://127.0.0.1:7878/mcp | jq '.result.tools | length'
# expected: >= 10 tools listed

# 6. Verify dev container cannot reach the MCP server
./scripts/aidc create mcp-test --profile multi --repo $(pwd)
docker exec -u vscode aidc-mcp-test-dev curl -sf --max-time 5 http://127.0.0.1:7878/mcp
# expected: connection refused or timeout

# 7. session_list via MCP (replace 127.0.0.1 hostname appropriately if needed)
curl -s -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_list","arguments":{}}}' \
     http://127.0.0.1:7878/mcp | jq

# 8. Token rotation invalidates old token
./scripts/aidc mcp token rotate
NEW_TOKEN=$(cat ~/.config/aidc/mcp-token)
[ "$NEW_TOKEN" != "$TOKEN" ] && echo "rotated"
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7878/mcp
# expected: 401 (old token invalid)

# 9. Cleanup
./scripts/aidc kill mcp-test
./scripts/aidc mcp stop
```

---

## Enforcement Test Suggestions

- [ ] Bearer token never appears in any log file — suggested test: grep audit log + container stdout, confirm full token never logged
- [ ] Tools always return the structured `{ok, error?, data?}` envelope — suggested test: every tool's return path passes through one envelope helper
- [ ] No reimplementation of session lifecycle inside the MCP server — suggested test: grep Python source for `docker compose` invocations (should be none — only `aidc` CLI calls)
- [ ] bind_address validation rejects unbound IPs — suggested test: set `mcp.bind_address: 10.99.99.99` (likely not on host), assert start fails with the available-interfaces list
