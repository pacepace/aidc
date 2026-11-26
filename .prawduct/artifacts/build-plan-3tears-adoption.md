---
artifact: build-plan
version: 2
scope: 3tears-adoption
branch: feature/k8s-git-container
base: develop
working-branches: []
last_validated: 2026-11-25
depends_on:
  - artifact: .prawduct/artifacts/plan-aidc-2.0.md
  - artifact: docs/design-13-3tears-tools.md
  - artifact: docs/design-12-kubernetes.md
  - artifact: docs/design-10-turn-state-and-sending.md
  - artifact: docs/requirements.md
governed_by:
  - artifact: project-preferences
    dispositions:
      - "Module split (service/ holds the service with no MCP types; tools.py holds only the MCP surface) → amendment proposed: chunk 02 replaces tools.py with one TearsTool per tool and chunk 03 a face module; the line is rewritten then to name them"
      - "State: anything that must survive a restart is a file in the watcher-state dir → ruling needed: design-13 Q4 (TRS-25 option B conforms; option A is an amendment)"
      - "Contracts: the envelope and callback payload change only by agreement, additively → conforms: the envelope is the TearsTool content unchanged, the payload does not change unless Q2 adds a mesh delivery, agreed with the orchestrator"
      - "no private names in the repo → conforms: the owner's mesh, cluster and hosts are named only in the user's config"
      - "ruff, mypy clean; tests are sentences about behaviour; uv run --frozen → conforms"
  - artifact: .claude/rules/learnings/core
    dispositions:
      - "a value produced in one place and consumed in another must resolve in the same namespace and lifetime → applies throughout: the bearer identity per message, not per MCP session (TRS-08); paths the per-user server reads in its pod, not on the laptop (chunks 08-12); state on a claim that outlives the pod (07, 10); mesh caller identity from the hub, not from arguments (TRS-21)"
      - "run the real path once before calling it done → applies: every chunk's done-when names a live run (Docker smoke, a cluster session, a real mesh), not only unit tests"
partition: "serial for 01-07, then 23-24 (each changes the MCP package the next builds on) and 08-12 (each needs the last running in the cluster); 13-19 (scripts/k8s, gitctl, broker, Syncthing) touch no code 20-21 touch, so a wave of them may be delegated to an isolated worktree when its gate is open, decided when that wave starts"
---

# Build Plan — 3tears adoption and the per-user MCP (aidc 2.0)

**Work:** `3tears-adoption` (plan-aidc-2.0 W-T1, W-T3, W-T4, W-M1..W-M4, W-K4, W-K3, W-K3b,
W-T5) · **Branch:** `feature/k8s-git-container` · **Written:** 2026-11-25 · **Requirements:**
TRS-01..25 and the 2026-11-25 amendments of MCP-02/03/05/06/07/08/09/10/11/12/13/14/15/38/43
(`docs/requirements.md`).

## Goals

**Response taken:** proceed, citing plan-aidc-2.0 W-T0-03 and the owner rulings of 2026-11-24 and
2026-11-25: 2.0 is the Kubernetes program and the 3tears adoption, released together; nothing is
deferred; Kubernetes git approvals go through the orchestrator before 2.0 ships; the orchestrator
reaches the per-user MCP in the cluster and on the VPN, behind its bearer token; 3tears-mcp drops
SDK 1.x before the features are added.

**Product:** one aidc tool implementation, served locally over MCP as today (and as an HTTP API),
and on a 3tears mesh; on Kubernetes, a per-user server that keeps sessions answering while the
user's machines are off, and through which an orchestrator approves the git agent's requests.

**Architecture (what must hold):**
- One service per install (`mcp/src/aidc_mcp/service/`, done in W-T2), one process, one event
  loop, in every face and on both backends (TRS-13, TRS-19, TRS-23).
- Each tool is one `TearsTool` (TRS-10); faces are adapters over them: the local MCP face through
  3tears-mcp's bridge, the HTTP API face, the mesh `ToolServer`.
- The envelope `{ok, data}` / `{ok: false, error, error_code}` is the tool's content, unchanged;
  aidc's codes are also protocol codes (TRS-05).
- Local tool names stay the 1.x names; mesh names are `aidc.<tool>` (TRS-15).
- 3tears is changed upstream where it falls short, never worked around in aidc (ruling): the
  items below are 3tears changes, built, reviewed and released in the 3tears repo, then adopted
  by pinning one 3tears minor.

**Constraints:** behaviour of every MCP-NN row preserved unless a 2026-11-25 amendment says
otherwise; the MCP suite's assertions keep their meaning (tests that drove FastMCP are rewritten
against the new face, none weakened); `make smoke` (Docker) and `make smoke-k8s` pass at the end;
no private infrastructure names in the repo; the owner's own images, sessions and aidc-mcp are not
touched by tests (separate checkout, test version tag).

**Tradeoffs accepted:**
- Local names stay unprefixed (TRS-15), so a tool's local and mesh names differ. Chosen because
  a dotted local name would break every orchestrator whose model API rejects dots, and the
  prefix adds nothing an MCP client does not already add.
- The taint gate and scope move into the framework as authorizers (TRS-12), which needs an
  upstream change (U07) rather than keeping aidc's wrapper. Revisit if U07 is refused upstream.

**What I would do differently (advisory):** this plan is a program (21 chunks, several sessions
each, three repos' worth of hands: aidc, 3tears, the cluster). Planning's rule is a per-wave plan
drawn when each wave starts. Recommended: keep this file as the map, and when chunk 01's upstream
release lands, split off one plan per wave (T3+T4, M1+M2, M3+M4+K4, K3+K3b, T5), each claiming its
own branch off this one, so a blocking finding in one wave does not stall the others. Built as
one plan as asked.

**Decisions made mid-build:** *(appended while building; one line each, naming what settled it)*

**Level:** Medium — requirements written; four design-13 questions and two new ones are open
(below); the upstream surface does not exist yet, so every 3tears-facing chunk starts with
verify-api against the released source.

## Gates (questions that must be answered before the chunk that needs them)

| Gate | Question | Blocks |
|---|---|---|
| design-13 Q1 | Progress on the mesh: through `TearsTool` (upstream in agent-tools and the registry, U13), or local only with the async tools on the mesh? | 20 |
| design-13 Q2 | Mesh delivery of finished turns: keep the webhook only, or add a NATS subject agreed with the orchestrator? | 21 |
| design-13 Q3 | Images: one image with the mesh extra, or a light default plus a mesh variant? | 21 |
| design-13 Q4 | Durable state: an L1-on-a-file 3tears store (U11, TRS-25 A), or aidc's files (TRS-25 B)? | 07 (and U11) |
| design-13 Q5 | Answered 2026-11-25: drop SDK 1.x first (U01). | — |
| REL-09 | Does the 3tears family wait out the 14-day cooldown, or is it an explicit exception (the owner's own package)? | 22 (moved from 01 by the 2026-11-26 ruling) |
| TRS-18 | Must local mode serve the HTTP API too, or is the hub's API face on the mesh enough? | 06 (and U10) — answered 2026-11-25: no API in 2.0; U10 and chunk 06 dropped, kept addable |
| Q-K1 | How a user adds a Claude account to the broker. | 17 |
| W-K0-03 / Q-M5 | Does paste+Enter answer AskUserQuestion? If not, the key sequence (§5 decision). | 14 |

## Upstream work in 3tears (W-T1; built and released in the 3tears repo)

Not chunks of this plan: they are reviewed in the 3tears repo and become done there. Each is
released in one 3tears minor that chunk 01 pins; an item a later chunk needs (U10-U13) may come in
a later release of the same minor, re-pinned by that chunk. Owner's hands: each 3tears release.
Order follows design-13 "Upstream work".

- **U01 Drop MCP SDK 1.x** (ruling 2026-11-25). Done when: `3tears-mcp` requires `mcp>=2,<3`, the
  1.x registration path (`_SDK_V1`) and its tests are gone, the suite is green on 2.x, released.
- **U02 Call context** (design-13 item 1; TRS-03). Done when: a handler that declares the context
  gets the progress token, a progress reporter, a client log channel and a cancellation signal; a
  handler that does not is called as before; both tested; released.
- **U03 Progress and logging over Streamable HTTP** (item 2; TRS-04). Done when: a real SDK client
  receives `notifications/progress` and `notifications/message` before the result, in stateless
  and stateful modes.
- **U04 Error model** (item 3; TRS-05). Done when: a closed, documented code set on the protocol
  result with `retryable` and the argument at fault, an exception-to-code registry, server-
  registered codes, an argument-validation failure with its own code, aligned with agent-tools'
  `ToolResult` vocabulary; released.
- **U05 Resources** (item 4; TRS-06). Done when: list, read, templates and a permission per
  resource, plus subscribe and `resources/updated` in stateful mode, tested over HTTP.
- **U06 Stateful mode** (item 5; TRS-07, TRS-08, TRS-09). Done when: opt-in stateful Streamable
  HTTP with `tools/list_changed`, resource subscriptions and request cancellation reaching the call
  context; the bearer identity is resolved for every message, and a revoked token is refused on
  the next message of an open MCP session (test).
- **U07 An Authorizer that sees the call** (item 10; TRS-12). Done when: an authorizer can ask for
  the tool name and arguments and is evaluated before the handler; existing authorizers unchanged.
- **U08 `TearsTool` → MCP bridge** (item 6; TRS-10). Done when: a `TearsTool` is served by
  `McpServer` with its schema, its `ToolResult` mapped to the result, and the call context reachable
  from `execute` without changing `TearsTool.run`.
- **U09 The `TearsTool` contract installable on its own** (item 11; TRS-17). Done when: installing
  it resolves no NATS client, Postgres driver, LangGraph or LangChain (a resolver check in CI).
- **U10 `face_api` without the hub** (item 7; TRS-18). Only if gate TRS-18 keeps the local API.
  Done when: one POST per tool with the same bearer, served by 3tears without NATS.
- **U11 L1 on a file** (item 8; TRS-25 A). Only if Q4 = A. Done when: an L1-only store on a WAL
  file, refusing to start with eviction on, no path drops a row that only L1 holds; kill -9 test.
- **U12 agent-audit reports a failed publish** (item 9; TRS-22). Done when: a failed publish is
  counted or reported to the caller, not only logged.
- **U13 Progress through `TearsTool` and the registry.** Only if Q1 = carry it. Done when: a mesh
  caller receives a tool's progress before its result.

## Build Chunks

### Chunk 01: Adopt the unreleased 3tears branch

- **Description:** Take the 3tears family from the merged, pushed 3tears branch that carries
  U01-U09: one uv git source per package, pinned to a commit. Per the owner's ruling of
  2026-11-26, aidc is tested on unreleased 3tears before 3tears is released, and chunk 22 moves
  to the release. Read the source at that commit for every surface the later chunks use, before
  any code is written against it.
- **Depends on:** U01-U09 merged and pushed on the 3tears branch (no release needed).
- **Requirements:** TRS-02, TRS-17 (local dependencies).
- **Deliverables:** `mcp/pyproject.toml` and `mcp/uv.lock` on the pinned minor, with the `mesh` extra
  declared empty for now; a unit test for TRS-02 (mcp >= 2, one 3tears minor); verify-api notes
  in new `.prawduct/artifacts/api-notes-3tears.md` (signatures of the call context, error
  registry, resources, stateful mode, the authorizer call, the bridge, as released).
- **Foreign API:** 3tears-mcp, 3tears-agent-tools (contract), 3tears-tool-schema, 3tears-observe
- **Done when:**
  0. verify-api — read the 3tears source at the pinned commit for each surface above, and record
     it with that commit.
  1. TRS-02's test passes; the MCP suite is green on the new lock (FastMCP still serves).
  2. `/prawduct:critic` run and blocking findings resolved; committed.
- **Owner's hands:** none (the release and REL-09 move to chunk 22).

### Chunk 02: Tools as TearsTools over the service

- **Description:** One `TearsTool` per aidc tool (23, plus `session_create` under MCP-38), each a
  thin call into the service returning the envelope as content; schemas through tool-schema with
  descriptions verbatim; canonical names `aidc.<tool>`. #76 (`file_put` overwrite) fixed in the
  rebuilt tool.
- **Depends on:** 01.
- **Requirements:** TRS-10, TRS-11, TRS-15, MCP-08, MCP-22, #76.
- **Deliverables:** a tools package of TearsTools; tests that each published tool has one, that
  descriptions match the 1.x `mcp/published-tools.json` word for word, and #76's regression test.
- **Done when:** the tools' own tests pass calling `run` directly against the service with the
  Docker backend stubbed; `/prawduct:critic` run, findings resolved; committed.
- **Owner's hands:** none.

### Chunk 03: The local face — server, identity, authorizers, error codes

- **Description:** Replace FastMCP with `3tears-mcp`'s `McpServer` in stateful Streamable HTTP
  mode over the bridge; the bearer token resolves to one admin identity per message; scope and
  taint as authorizers; aidc's codes registered as protocol codes.
- **Depends on:** 02.
- **Requirements:** TRS-01, TRS-05, TRS-08, TRS-12, MCP-04, MCP-05, MCP-06, MCP-31, MCP-32.
- **Deliverables:** the face module (replacing `mcp/src/aidc_mcp/server.py` and the guards in
  `mcp/src/aidc_mcp/tools.py`); wire tests rewritten against it; the fresh-interpreter import test
  for TRS-01; token-rotation-on-an-open-session test.
- **Critic mode:** final
- **Done when:** the wire suite passes against the new server; `/prawduct:critic` run, findings
  resolved; committed.
- **Owner's hands:** none.

### Chunk 04: The local face — progress, cancellation, resources, list_changed

- **Description:** Wire the call context into the tools that report phases and the blocking invoke;
  serve the MCP-09 resources; dynamic descriptions with `tools/list_changed`; regenerate
  `published-tools.json` with `mesh_name`; CHANGELOG draft for 2.0.
- **Depends on:** 03.
- **Requirements:** TRS-03, TRS-04, TRS-06, TRS-07, TRS-09, TRS-16, MCP-07, MCP-09, MCP-21, MCP-43.
- **Deliverables:** `mcp/src/aidc_mcp/disconnect.py` removed; resources on the new server; the
  regenerated contract file and its byte-for-byte test.
- **Done when:** an orchestrator round trip on Docker passes against the new server: send, watch,
  callback, cancel of a blocking invoke, a resource read and a `list_changed` seen;
  `AIDC_SMOKE_GIT=0 make smoke` from a separate checkout; `/prawduct:critic`; committed.
- **Owner's hands:** the orchestrator running for the round trip.

### Chunk 05: Observability on 3tears-observe (W-T4)

- **Description:** Logging through observe with a per-call correlation id and a span per call;
  exporters off unless configured; the access log stays aidc's file sink.
- **Depends on:** 04.
- **Requirements:** TRS-14, MCP-14, MCP-19.
- **Done when:** the access-log tests pass unchanged; a test shows no network connection with
  export off; `/prawduct:critic`; committed.
- **Owner's hands:** none.

### Chunk 06: The HTTP API face — NOT IN 2.0 (owner ruling 2026-11-25: no API yet; keep it addable as another face over the same TearsTools)

- **Description:** Serve each tool as one POST with the same bearer and envelope, in local mode.
- **Depends on:** 05; gate TRS-18; U10 released.
- **Requirements:** TRS-18.
- **Exposed API:** aidc-http-api
- **Done when:** a test calls every tool over the API and gets the same envelope as over MCP;
  `/prawduct:critic`; committed.
- **Owner's hands:** the gate answer; the 3tears release with U10.

### Chunk 07: Durable state on a SQLite L3 (design-13 Q4, answered 2026-11-25)

- **Description:** Move the queues, ledger, watches and dead letters onto 3tears collections. Locally
  they are backed by a single SQLite file as a 3tears L3, with no L2 and L1 as the normal cache (the
  sqlite-l3 work on the pinned 3tears branch). The state dir is a path the Kubernetes server puts
  on a claim. On a mesh, the L3 becomes Postgres by configuration.
- **Depends on:** 05; gate Q4 (answered: SQLite L3).
- **Requirements:** TRS-25, MCP-17, MCP-30, MCP-33, MCP-34, MCP-36, MCP-45.
- **Done when:** every restart test passes unchanged; a kill -9 test after each kind of write loses
  nothing that was acknowledged; the persisted-format questions (planning: lock-in) are listed
  before the collections' fields are designed; existing state files are migrated or read once on
  upgrade (tested); `/prawduct:critic`; committed.
- **Owner's hands:** none.

### Chunk 23: Session state from Claude Code hooks (W-H-01, owner ruling 2026-11-26)

- **Description:** Each session's managed settings install the `Stop` hook (turn done, with
  `last_assistant_message`), the `Notification` hook (`permission_prompt`, `idle_prompt`) and the
  `UserPromptSubmit` hook. The hooks write events as files under the session's state dir, which the
  MCP already reads on Docker and on Kubernetes. The hook process does not reach the MCP.
- **Depends on:** 05.
- **Requirements:** plan-aidc-2.0 W-H-01. Requirement IDs are added to docs/requirements.md
  before code.
- **Done when:** a real Docker session writes each event kind (live check); unit tests for the
  event format and the writer; `/prawduct:critic`; committed.
- **Owner's hands:** none.

### Chunk 24: Busy, idle, permission and replies from hook events (W-H-02)

- **Description:** The service takes busy, idle and waiting-on-permission, and the reply, from hook
  events instead of screen reads. The transcript stays the record, used for catch-up after an MCP or
  Claude restart. Screen reads and tmux keys stay only for AskUserQuestion, dialogs and the paste
  send path.
- **Depends on:** 07, 23.
- **Requirements:** plan-aidc-2.0 W-H-02.
- **Done when:** the delivery and turns suites pass with screen classification removed from the
  busy/idle and reply paths; a Docker session delivers a reply once across an MCP restart; a
  human-typed prompt's reply still reaches the orchestrator; `/prawduct:critic`; committed. The
  Kubernetes half of the plan-aidc-2.0 done-when is proved in chunk 09.
- **Owner's hands:** the orchestrator for the human-typed-prompt check.

### Chunk 08: MCP Kubernetes backend (W-M1-01)

- **Description:** `mcp/src/aidc_mcp/backend.py` gains a kubectl implementation (target to
  namespace, pod and container; exec, inspect, list, instance id, missing); the confinement test
  extended.
- **Depends on:** 04, 24 (W-K5's RBAC is built; the Kubernetes backend is built on hook events).
- **Requirements:** K8S-01, MCP-13.
- **Done when:** unit tests mirror the Docker ones with a kubectl stub; a probe against a real
  cluster session lists and execs; `/prawduct:critic`; committed.
- **Owner's hands:** the cluster with a test user.

### Chunk 09: Transcripts and state for cluster sessions (W-M1-02)

- **Description:** Mirror each cluster session's transcripts, and the git agent's, to the user's
  disk (Q-M3, §5), and read them there; the state dir on a claim.
- **Depends on:** 07, 08.
- **Requirements:** MCP-15, MCP-17, MCP-34, MCP-35, K8S-02.
- **Done when:** a cluster session's turn is delivered exactly once across a server restart (live);
  `/prawduct:critic`; committed.
- **Owner's hands:** the cluster.

### Chunk 10: The per-user server in the cluster (W-M2-01)

- **Description:** `aidc mcp start|stop|status|logs|token rotate` on Kubernetes: a one-replica
  Deployment in the user's namespace, state and access log on a claim, the token a Secret, an image
  with the aidc CLI, kubectl and yq, under the MCP ServiceAccount.
- **Depends on:** 09.
- **Requirements:** TRS-23, MCP-02, MCP-03, MCP-05, MCP-06, MCP-13, MCP-14, K8S-07, K8S-20.
- **Critic mode:** final
- **Done when:** a unit test renders the manifests; live: start, status, logs, rotate (an open MCP
  session is refused after rotate), stop; `/prawduct:critic`; committed.
- **Owner's hands:** the cluster.

### Chunk 11: Reaching the per-user server, and its callback egress (W-M2-02/03)

- **Description:** The in-cluster Service always; VPN/LAN exposure when configured (an Ingress name
  with TLS, or a LAN address), every path behind the bearer; refusal when the configured exposure
  cannot be served; a NetworkPolicy letting the server reach exactly the callback host and port.
- **Depends on:** 10.
- **Requirements:** MCP-10, MCP-11, MCP-12, K8S-13 (ruling Q-M1).
- **Done when:** live: an orchestrator in the cluster and one on the VPN both call a tool, an
  unauthenticated call is refused on each path, and the server cannot reach any other host;
  `/prawduct:critic`; committed.
- **Owner's hands:** the DNS name and certificate for the Ingress, or a LAN address; the
  orchestrator in both places.

### Chunk 12: Creating sessions from the cluster server; the laptop-off test (W-M2-04)

- **Description:** `session_create` on Kubernetes (no repo or workspace) and `session_mcp_set`
  through the in-cluster server.
- **Depends on:** 11.
- **Requirements:** MCP-38, MCP-39, TRS-23, K8S-07.
- **Done when:** live, with the user's machines off: a session created through the server keeps
  running, its reply reaches the orchestrator, and a prompt sent then is pasted when it is free;
  `/prawduct:critic`; committed.
- **Owner's hands:** the orchestrator; turning the laptop off.

### Chunk 13: Approvals bound to the answer (W-M3-00, Q-K8)

- **Description:** The git agent's question carries a one-time code only the user's or the
  orchestrator's answer returns; `git-requests approve` refuses without it (both backends).
- **Depends on:** none in this plan (W-K0 done).
- **Requirements:** K8S-05, K8S-06, K8S-24.
- **Done when:** a unit test and a mutation show the agent cannot approve its own request, and an
  answer carrying the code approves; `/prawduct:critic`; committed.
- **Owner's hands:** none.

### Chunk 14: Git approvals through the orchestrator on Kubernetes (W-M3-01..03)

- **Description:** The in-cluster server watches the `git` session; the orchestrator's answer
  reaches the agent's question (paste, or the key sequence per W-K0-03 / Q-M5); the smoke's Claude
  part automatic.
- **Depends on:** 12, 13; gate W-K0-03 / Q-M5.
- **Requirements:** K8S-06 (ruling: a 2.0 ship blocker), K8S-07.
- **Done when:** live: an orchestrator approves a cluster session's PR request end to end and the
  PR opens; `/prawduct:critic`; committed.
- **Owner's hands:** GitHub and Claude logins in the git agent; a scratch repo; the orchestrator.

### Chunk 15: The taint webhook path (W-M4)

- **Description:** The policy sidecar posts taint to the per-user server's webhook port, allowed by
  one NetworkPolicy rule; the server records it.
- **Depends on:** 11.
- **Requirements:** K8S-13, MCP-12, SEC-02.
- **Done when:** live: a taint shows in `session_status` within seconds, and the session still
  cannot reach any other port of the server; `/prawduct:critic`; committed.
- **Owner's hands:** the cluster.

### Chunk 16: Taint freeze on Kubernetes (W-K4)

- **Description:** On taint, `freeze` (the default) cuts the session's egress with a deny-all policy
  on its proxy and marks it frozen; acted on by the per-user server (Q-K3, §5).
- **Depends on:** 15.
- **Requirements:** SEC-05, SEC-06, SEC-08, K8S-13.
- **Done when:** smoke: a blocklisted fetch freezes the session within the bound and `aidc status`
  says so; `/prawduct:critic`; committed.
- **Owner's hands:** the cluster.

### Chunk 17: The account broker (W-K3-01)

- **Description:** A per-user broker pod holding refresh tokens on a claim only it mounts, writing
  access-only credentials into each session's Claude dir by rename; accounts added per Q-K1.
- **Depends on:** 09 (one Claude-state layout, Q-K2 §5); gate Q-K1.
- **Requirements:** K8S-16, K8S-20.
- **Done when:** live: a new session works without its own `/login`; `/prawduct:critic`;
  committed.
- **Owner's hands:** the Q-K1 answer; Claude accounts.

### Chunk 18: Account switching and token expiry (W-K3-02/03)

- **Description:** The statusline wrapper reads weekly usage against each account's threshold,
  the `StopFailure` rate-limit hook, the cycle order, the auto/wait setting; the live expiry test.
- **Depends on:** 17.
- **Requirements:** K8S-17.
- **Done when:** live: a session crosses an account switch mid-conversation without a restart and
  survives a real token expiry; `/prawduct:critic`; committed.
- **Owner's hands:** two or more Claude accounts; hours for the expiry test.

### Chunk 19: One history per repo with Syncthing (W-K3b)

- **Description:** One `projects/` per user on the cluster shared by their sessions, a Syncthing pod
  reaching only the user's machines (Q-K11, §5), the sync set per ruling, the lease, the Mac alias
  reconciler; #35's symlink risk settled for synced memory.
- **Depends on:** 17.
- **Requirements:** K8S-18.
- **Done when:** live: a conversation started on the cluster is continued on the Mac with memory
  intact, never two writers at once; `/prawduct:critic`; committed.
- **Owner's hands:** Syncthing on each laptop, pairing, a Mac.

### Chunk 20: The mesh face (W-T5-01)

- **Description:** A `ToolServer` entry point registering the same TearsTools as `aidc.*`, pod
  identity and key, registry grants with the scope on top, `conversation_id` from the hub, mesh
  audit with the access log as the record; no blocking invoke on the mesh; progress per Q1.
- **Depends on:** 05; gate Q1; U12 (and U13 if Q1 = carry).
- **Requirements:** TRS-19, TRS-20, TRS-21, TRS-22.
- **Foreign API:** 3tears-agent-tools ToolServer, 3tears-registry, 3tears-agent-audit
- **Done when:**
  0. verify-api — read the released ToolServer, registration and grant source.
  1. Tests: an ungranted caller refused, a granted caller outside the scope refused, a granted call
     delivered and audited in both places.
  2. `/prawduct:critic`; committed.
- **Owner's hands:** the Q1 answer.

### Chunk 21: Mesh delivery, the per-user server on the mesh, images

- **Description:** The mesh delivery channel if Q2 adds it; the per-user cluster server running
  in mesh mode or both by config; the image(s) per Q3.
- **Depends on:** 12, 20; gates Q2, Q3.
- **Requirements:** TRS-17, TRS-19, TRS-23, TRS-24.
- **Done when:** live, on a real mesh: an orchestrator calls `aidc.session_send` and gets the turn;
  the same server still answers its local face; then committed, `/prawduct:critic cumulative` run
  and blocking findings resolved.
- **Owner's hands:** a running 3tears mesh (NATS with callout auth, registry, hub) to test against;
  the Q2 and Q3 answers; the orchestrator agreeing any payload change.

### Chunk 22: Move to the 3tears release

- **Description:** aidc has passed end to end on the unreleased 3tears branch, including every
  3tears fix its tests forced, each landed on that branch with the pin moved. The owner then
  releases 3tears. This chunk replaces each git source with the released version and records the
  REL-09 decision beside the cooldown setting: wait out the 14 days, or an explicit
  `exclude-newer-package` exception for the 3tears family.
- **Depends on:** 21; the 3tears release; gate REL-09.
- **Requirements:** TRS-02, TRS-17.
- **Type:** cumulative-final
- **Done when:** the lock resolves only released 3tears versions, with no git sources left; the
  MCP suite and TRS-01/TRS-02's tests pass on it; the image builds from it; committed, then
  `/prawduct:critic cumulative` run and blocking findings resolved.
- **Owner's hands:** the 3tears release; the REL-09 answer.

## Early Feedback Milestone

**Milestone chunk:** 04
**What the user can do:** point the orchestrator at the rebuilt server on Docker and use it as
today (send, watch, replies, cancel, resources), with real progress notifications.

## Governance Checkpoints

**Commit & PR cadence:** commit per chunk after its review; push reviewed commits; no PR until 2.0
is done and tested end to end (W-R, the one 2.0 PR).

- After chunk 04: the local face is whole; confirm the TearsTool and bridge shape before the
  cluster and mesh build on it.
- After chunk 12: the per-user server is live; confirm before approvals and taint build on it.
- Chunk 21: the whole adoption tested end to end on the unreleased 3tears branch; then the owner
  releases 3tears.
- Chunk 22 (cumulative): moved to the released 3tears, the whole adoption reviewed before W-R.
