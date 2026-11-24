---
artifact: build-plan
version: 1
scope: backend-seam
branch: refactor/backend-seam
lifecycle: active
depends_on: [docs/design-12-kubernetes.md]
governed_by: [.prawduct/artifacts/project-preferences.md, .claude/rules/learnings/core.md]
partition: serial — three small chunks, each depending on the last; a delegate's brief would cost more than the work
---

# Build Plan — one switch point between aidc and Docker

**Work:** `backend-seam` · **Branch:** `refactor/backend-seam` (off `design/k8s-backend`
16a6122, which carries design-12 and the K8S requirements) · **Started:** 2026-11-24
**Critic mode:** chunk review after 01, final after 03

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
  those in the caller keeps the change mechanical. Resolved (chunk 02 inventory): the MCP server
  addresses only `dev`, `policy` and `audit`, which `backend.py` defines; `proxy` and
  `refresher` are used only by the CLI (`cmd-refresh.sh`, the network libraries), so the MCP
  seam owes nothing for them. The leak scanner still watches their names so none is built in
  Python later.
- **Decisions made mid-build:**
  - [DECISION: chunk 01's interface differs from the forecast above | callers address a
    container by the string `backend.target(session, role)` and pass it to
    `exec_argv(tgt, argv, …)`, instead of `exec_argv(session, role, …)`, because the call sites
    already thread a `container` string through many helpers (tmux, headless, session_mcp) and
    the tests pin that shape; the Kubernetes backend can encode namespace/pod/container in the
    same string, and switching to (session, role) stays possible if it cannot | owner can veto]
  - [DECISION: no `backend.run`; the two existing runners (`session_facts.run_docker`,
    `headless._docker`) stay where they are and start `backend.BIN` | they differ in error
    contract (a result vs. a raise) and are the seams the tests replace; merging them would
    change behaviour and the tests, which this refactor must not | owner can veto]
  - [DECISION: the two queries are command/parse pairs (`instance_argv` + `instance_gone`,
    `dev_list_args` + `session_of_dev`) instead of `session_instance()` / `dev_sessions()` |
    the callers keep their own subprocess handling (Goals, "Inferred"), and the backend owns
    both the command and the reading of its output | owner can veto]
  - [DECISION: the CLI's switch point is the dispatcher, not a shell backend library; chunks
    02-04 (per-verb `backend_*` functions) become one confinement chunk | nearly every CLI
    Docker call is in a per-verb script (create, kill, network, proxy, egress) whose Kubernetes
    form shares little with it (namespaces, NetworkPolicy), so wrapping each call now would be an
    abstraction with one implementation and guessed signatures; moving the Docker helpers out of
    common.sh would break the libraries-report-their-own-failures rule
    (tests/unit/test-lib-self-contained.sh) or change how they fail. Shared helpers get extracted
    when the Kubernetes verbs show which are shared. Departs from design-12 "Backend seam"
    (backend_docker.sh / backend_k8s.sh), which chunk 03 updates | owner can veto]
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

### Chunk 02: CLI switch point and Docker confinement

- The CLI's switch point is the dispatcher (`scripts/aidc` runs `scripts/cmd-<verb>.sh`): the
  Kubernetes wave adds its verbs beside these and the dispatcher picks by the session's backend.
  Documented in design-12 "Backend seam".
- `tests/unit/test-backend-confinement.sh`: `docker` is invoked only in the files that implement
  the Docker backend (the `scripts/cmd-*.sh` verbs, `scripts/lib/network.sh`,
  `scripts/lib/egress.sh`) and, in the shared
  libraries, only inside the named Docker helper functions (`common.sh`: session_exists,
  require_docker, ensure_image, aidc_session_audit_dir, list/remove_adhoc_forwards,
  remove_session_networks, wait_for_dev_ready; `config.sh`: aidc_mcp_deny_target). Every other
  shared library (`claude-state.sh`, `yq.sh`, `update.sh` …) stays Docker-free. Verified to fail on
  a planted call.

### Chunk 03: End-to-end and docs

- `make smoke` on this host; MCP suite; every `tests/unit/*.sh`; record evidence.
- An MCP round trip against a real session (session_create, session_send, session_status,
  session_exec, file_put, session_kill) through the new backend module.
- design-12 "Backend seam" updated to what was built (done in chunk 02); change record
  `.prawduct/changes/backend-seam.md` (CHANGELOG is written from it at release).
- Result 2026-11-24: `make smoke` all passed. Live MCP check against a real
  session (`seamprobe`, created and killed with this branch's CLI): 14 of 14 — instance id and
  gone, dev listing, taint, policy events, audit dir, repo path, git in the repo, tmux exec,
  window list, screen capture, headless listing, stdin, exec user. Then a round trip through a
  running aidc-mcp built from this branch (a second server on a spare port with its own token
  and state, scoped to a throwaway session `seamrt`; the live aidc-mcp was not touched):
  session_list, session_status, session_exec, file_put to a new path, audit_get, the scope
  refusal and session_send (queued and pasted) all answered as before. Overwriting a file with
  file_put fails in Ubuntu 26.04 sessions (uutils `install` from /dev/stdin); the same command
  fails without this branch, so it is filed as pacepace/aidc#76, not fixed in this refactor.

## Verification strategy

Behaviour preservation is the whole contract. Per chunk: the unit suites for the touched side.
At the end: smoke creates a real session, exercises attach/exec/status/proxy/egress/kill, and an
MCP round trip (session_create, session_send, session_status, session_kill) against a real
session, so a mis-addressed container shows up as a failure, not as a silently skipped path.
