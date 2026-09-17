# Boundary Patterns — aidc

Contract surfaces where components interact. A change that crosses one of these needs its
consumer checked before the work is done — for the first two, the consumer is another program
that ships separately.

## Contract Surfaces

### The MCP tool surface (external consumer)
- **Producer**: `mcp/src/aidc_mcp/tools.py` (registration and envelopes), `resources.py`.
- **Consumer**: the orchestrator (MetaLLM), over streamable HTTP with a bearer token. It is a
  separate product, developed by another session/agent.
- **Contract**: every tool returns `{"ok": true, "data": ...}` or `{"ok": false, "error": "...",
  "error_code": "<kind>"}`, `isError` false either way; the code set is closed
  (`tools.ERROR_CODES`) and documented in `docs/design-10-turn-state-and-sending.md` D6.
- **Rule**: adding a tool or a code is additive and safe; removing one, renaming one, or changing
  what a code means is agreed with the orchestrator first. `session_create` exists only under
  MCP-38. A test fails if any failure path omits a code or invents one.

### The reply callback (external consumer)
- **Producer**: `_post_turn` in `tools.py`.
- **Consumer**: the orchestrator's callback endpoint, `POST {callback_url}/api/v1/internal/callback/{conversation_id}`.
- **Contract**: the payload table in design 10 D5 — `content`, `ok`, `source`, `session`,
  `prompt_origin`, `interrupted`, plus `error_code` on the two callbacks that are notices rather
  than replies, and `speaker` only when `metallm.send_speaker` is on.
- **Rule**: fields are added, never repurposed; a receiver that ignores an added field must still
  read the payload correctly. Changes are agreed with the orchestrator before they are built —
  the 2026-09-17 joint test changed this payload three times that way.

### The CLI ↔ the MCP container
- **Producer**: `scripts/` (the CLI), run both on the host and inside `aidc-mcp`.
- **Consumer**: `aidc mcp start`, which decides what that container can see.
- **Contract**: `AIDC_HOST_HOME`, `AIDC_MCP_MOUNTS` (the `<host>|<mount>` list the `-v` flags are
  built from) and `AIDC_MCP_SESSION_CREATE`. Every host path the CLI hands docker is a HOST path;
  every path it writes goes through the matching mount (`aidc_resolve_local`).
- **Rule**: a mount and its reachability entry come from one list (`aidc_mcp_mount_pairs`), which
  produces both the `docker run -v` flags (`mcp_mount_args`) and `AIDC_MCP_MOUNTS` — they were
  written twice once, and a mount was granted that the CLI then called unreachable.

### The dev container ↔ the watcher
- **Producer**: the in-container transcript mirror (`.devcontainer/transcript-mirror.sh`), running
  as the container user.
- **Consumer**: the MCP watcher, reading `watcher-state/` and the mirrored transcripts.
- **Contract**: one directory per session under the MCP's state dir, owned by the host user so the
  mirror can write it; Claude Code's JSONL shapes as measured in
  `.prawduct/artifacts/claude-code-measurements.md` and design 10's facts table.
- **Rule**: a change to the shapes the watcher relies on is re-measured against a real session, not
  assumed; ownership of those directories is asserted at create time, loudly.

### The session compose file
- **Producer**: `scripts/cmd-create.sh` + `proxy/compose.yaml.template`.
- **Consumer**: the host docker daemon, and every later `aidc` command for that session.
- **Contract**: container names `aidc-<session>-<role>`, the session network `aidc-<session>-net`
  (which identifies the session), the labels `aidc.session` / `aidc.role`.
- **Rule**: those names are load-bearing for the MCP as well as the CLI — the network id is how a
  killed-and-recreated session is told from an upgraded one.
