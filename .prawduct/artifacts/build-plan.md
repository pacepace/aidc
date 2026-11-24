---
artifact: build-plan
version: 1
scope: backend-seam
branch: refactor/backend-seam
lifecycle: active
depends_on: [docs/design-12-kubernetes.md]
governed_by: [.prawduct/artifacts/project-preferences.md, .claude/rules/learnings/core.md]
partition: serial — chunk 01 is Python and could run beside 02, but 02-04 all edit scripts/lib/common.sh and the cmd-*.sh files, and 01 is small enough that a delegate's brief costs more than the work
---

# Build Plan — one switch point between aidc and Docker

**Work:** `backend-seam` · **Branch:** `refactor/backend-seam` (off `design/k8s-backend`
16a6122, which carries design-12 and the K8S requirements) · **Started:** 2026-11-24
**Critic mode:** chunk review after 01 and 03, final after 05

## Goals

- **Response taken:** proceed, citing it. The owner said "go" (2026-11-24) to starting the
  build with this step, recommended in design-12 "Backend seam" (K8S-01: the Kubernetes backend
  is a second target of the same aidc, and the Docker backend stays).
- **Product:** the first wave of the Kubernetes backend program (design-12). This wave changes
  nothing a user sees: every Docker call aidc makes goes through one module on each side (CLI
  and MCP server), so a Kubernetes implementation can be added beside it in the next wave
  without touching each command again.
- **Architecture:** a session's containers are addressed by **(session, role)** — roles `dev`,
  `policy`, `audit`, `proxy`, `refresher` — never by a Docker container name built in the
  caller. The backend turns that into `docker exec aidc-<name>-<role>` today and into a
  namespace and pod tomorrow. Shared logic (config, validation, claude state, rendering) stays
  out of the backend.
- **Constraints:** a refactor: behaviour preserved, existing tests unchanged (Tests are
  contracts). Smoke (`make smoke`) passes on this host before the wave ends. No backend
  selection yet: only Docker exists, so there is no switch to flip (no speculative plumbing).
- **Tradeoffs accepted:** the CLI's Docker-only infrastructure (networks, sidecar containers,
  forwarders) moves behind the seam as whole verbs, not as a portable abstraction of networks;
  Kubernetes will implement those verbs its own way (namespaces, NetworkPolicy). Revisit if the
  Kubernetes wave finds a verb that does not map.
- **Inferred:** the MCP seam returns an argv (`exec_argv`) rather than running the process,
  because the call sites differ in sync/async, stdin, timeouts and stream handling, and keeping
  those in the caller keeps the change mechanical. Inferred: the role names above are the full
  set; chunk 02's inventory confirms.
- **Decisions made mid-build:** (append here)
- **Level:** Medium-high. The MCP side is well understood (every call site read). The CLI side
  is 139 Docker calls across 20 files; the verb list in chunks 02-04 is a forecast that chunk 02's
  inventory may move.

## Chunks

### Chunk 01: MCP backend module

- `mcp/src/aidc_mcp/backend.py`: `exec_argv(session, role, argv, *, user="vscode", env=None,
  workdir=None, stdin=False)`, `run(...)` (the async runner `session_facts.run_docker` is today,
  with its timeout and result type), `session_instance(name)`, `dev_sessions()`.
- Route every Docker call through it: `session_facts.py`, `headless.py`, `repo.py`,
  `session_mcp.py`, `tools.py` (tmux exec, file put, exec tool, network inspect).
- Tests: the existing suite unchanged and green; a new test that no module in `aidc_mcp`
  except `backend.py` names the `docker` binary; unit tests of `exec_argv` for each option.
- Acceptance: `uv run --frozen pytest -q`, ruff and mypy clean.

### Chunk 02: CLI backend library and read verbs

- `scripts/lib/backend_docker.sh`, sourced by `common.sh`: session/role addressing
  (`backend_ct <session> <role>`), `backend_exec`, `backend_session_exists`,
  `backend_session_state`, `backend_logs`, `backend_list_sessions`.
- Move `attach`, `logs`, `status`, `list`, `restart` and the read helpers in `common.sh` onto it.
- Inventory every remaining `docker` call by file and the verb it will become (recorded below
  under Decisions).

### Chunk 03: CLI lifecycle verbs

- `create`, `kill`, `upgrade`, `rebuild`, `refresh`, `clean-env` call backend verbs
  (`backend_create_session`, `backend_kill_session`, `backend_replace_dev`, image build).

### Chunk 04: CLI network, proxy, egress and MCP verbs

- `lib/network.sh`, `lib/egress.sh`, `cmd-proxy.sh`, `cmd-network.sh`, `cmd-egress.sh`,
  `cmd-mcp.sh`, `lib/config.sh`, `lib/update.sh` go through backend verbs.

### Chunk 05: Enforcement and end-to-end

- `tests/unit/test-backend-seam.sh`: no `docker` invocation in `scripts/` outside
  `lib/backend_docker.sh` (and the documented exceptions, if any).
- `make smoke` on this host; MCP suite; every `tests/unit/*.sh`; record evidence.
- Docs: design-12 "Backend seam" updated to what was built; CHANGELOG.

## Verification strategy

Behaviour preservation is the whole contract. Per chunk: the unit suites for the touched side.
At the end: smoke creates a real session, exercises attach/exec/status/proxy/egress/kill, and an
MCP round trip (session_create, session_send, session_status, session_kill) against a real
session, so a mis-addressed container shows up as a failure, not as a silently skipped path.
