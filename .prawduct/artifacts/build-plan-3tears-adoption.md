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
      - "State: anything that must survive a restart is a file in the watcher-state dir → amended: the owner ratified TRS-25 option A (owner-rulings 2026-11-25, design-13 Q4); the row now names the 3tears state store (store.py), amended 2026-11-26"
      - "Contracts: the envelope and callback payload change only by agreement, additively → the envelope is the TearsTool content unchanged and the payload does not change unless Q2 adds a mesh delivery; one ruled, non-additive change: a failed call is isError with its code under _meta (TRS-05/TRS-16, rulings 2026-11-24), in design-10 D6 and the 2.0 CHANGELOG"
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
- 01: pinned 3tears `feat/mcp-face` at `b28bbebf4d66`; the REL-09 cooldown does not hold git sources back (no upload date), so no `exclude-newer-package` entry was needed (tested by re-locking); the image installs git for `uv sync` only and removes it in the same layer.
- 01: two findings sent upstream/owner: `McpServer` lacks `version`/`instructions` (aidc 1.x sends both; a 3tears change requested), and the SQLite L3 imports asyncpg and sqlalchemy, which TRS-01/TRS-17 forbid as written (owner question, chunk 07).
- 02: the TearsTools live in `aidc_mcp/tearstools/` (a package beside tools.py, which chunk 03 removes); the call context's type is imported for type checking only, so no tool imports an MCP type at run time; `ToolResult.error_code` is never set for an aidc refusal (TRS-10), the face carries the aidc code from the metadata.
- 01→03: pin moved to the head of feat/mcp-face carrying `McpServer(version=, instructions=)` before chunk 03 (main, 2026-11-26).
- 03: pins moved twice more for 3tears changes aidc's tests needed (Refusal content, cancel on a dropped request; api-notes pin history). The HTTP bearer gate stays in front of the server: identity is resolved by 3tears for tool calls and resources but not for `initialize` or `tools/list`, and MCP-14 logs every request. So a rotated token on an open session is refused with 401 at the gate; the server's resolver refuses it too (tested), so TRS-08's "identity unavailable" holds for any message that reached it. The token file is read on every check (a modification-time cache could miss a rotation within one clock tick).
- 03: `disconnect.py` went in 03 rather than 04: with tools.py gone nothing used it, and 3tears' drop cancellation at the pin made its test green. `session_invoke`'s in-flight table is keyed by run id, so interrupting a headless run always finds the host's docker exec.
- 03 (main, 2026-11-26, from design-13's Contract: an existing orchestrator needs no change beyond the 2.0 notes): null for an optional argument and whole numbers in text stay accepted, through a `[type, "null"]` schema and 3tears' `prepare_arguments` hook, the published schema staying `integer`.
- 03: `retryable` on a failed call is design-10 D6's Retryable column (`cli_failed`, `invoke_busy`), decided from its Caller column and tested against the table.
- 04: MCP-09's update notifications were never sent by 1.x; built here, from one service hook (`common.session_changed`) called where a session's status changes (inject on a paste, delivery of a reply, create, interrupt), which the face turns into `resources/updated` for the status and the session list.
- 04: what "on change" (MCP-09) means for 2.0: a paste, a delivered reply, a create, an interrupt (agent or headless); a scoped server reports only its own sessions. Chunk 24 adds the hook events (a turn starting or ending, a permission prompt, idle), which also cover a person typing into the terminal; a taint, or a kill or stop from the CLI, reach a subscriber on its next read.
- 04: the orchestrator round trip waits for the owner (asked through main 2026-11-26); everything else in 04 is built and tested.
- 05: the call scope is entered in `AidcTool.execute`, not the MCP face, so the mesh face gets the same correlation and span; access-log events also go out as observe log lines (the file and its fields unchanged); export and metrics are opt-in extras, not in the default image. TRS-13's boundary forbids the 3tears face types (threetears.mcp, threetears.tool_contract) in the service, not observe, which every module logs through.
- 07: rows keep 1.x's documented JSON documents under their natural keys (data-model.md), so the documented shapes stay the contract and the persistence functions keep their signatures; the store runs on one loop thread of its own behind a synchronous interface, as the 1.x file writes were synchronous. Only the four column types both 3tears stores share are used. Switching the L3 to Postgres by configuration (the store creates no Postgres tables yet) belongs with the mesh face in chunk 21, where the first Postgres deployment is; recorded here so it is not lost.
- 07: TRS-01 amended in this chunk's commit (main, 2026-11-26): 3tears' own `threetears.nats` modules that core imports are allowed while the NATS client is neither installed nor imported; the import test checks both and that nothing connects.
- 23: the event format is Claude Code's own hook input plus `event` and `at`, so a field a newer Claude Code adds reaches the MCP without a change here; events go to the mirror dir the MCP already reads (both backends), never to the MCP. The git agent's managed settings are the git wave's files (gitctl/), so its hooks were asked of that wave (main, 2026-11-26). The live check's Claude-fired half needs a logged-in Claude in the scratch session: asked of the owner (main, 2026-11-26).
- 24 (main, 2026-11-26): no screen fallback. A session with no hook event whose managed settings lack aidc's hook predates 2.0: `turn: "unknown"`, `session_send` refused with the new code `session_outdated` (D6, not retryable), recreate it (in the 2.0 upgrade notes). `SessionStart` joined the hooks, since a new 2.0 session has no other event before its first prompt; whether the hooks are installed is read from the session's managed settings once per instance (a file read, not the screen), and a session whose settings cannot be read waits rather than being refused. An Esc before output is reported after Claude's idle notice (about a minute) instead of from the screen.
- 24: the live checks (a reply delivered once across an MCP restart on Docker; a human-typed prompt's reply reaching the orchestrator) wait on a logged-in Claude in the scratch session and on the owner's orchestrator (asked through main, 2026-11-26).

- 08: one server serves one backend, chosen by its environment (`AIDC_MCP_BACKEND`, `AIDC_K8S_NAMESPACE`), refusing to start on unusable settings; a Kubernetes server's `session_create` always passes `--backend kubernetes`, the Docker server's keeps the CLI's config rule. Targets are kubectl exec objects (`pod/<s>-dev-0`, `deployment/<s>-proxy`, `deployment/git`) plus a container; the session user by `sudo -E -H -u vscode` (as `aidc attach`; keeps the pod's proxy env, gets the session umask), the git holder as the git pod's gitreq container. Instance id = the state claim's uid (git: git-home). The audit resources were broken on Docker too (they parsed an `audit:` line `aidc status` never prints, from a host path the container does not mount): both backends now read the trail in the audit sidecar. The 1.x `audit_get` description stays word for word (TRS-11); its `pvc:` form on Kubernetes is in design-12 and the CHANGELOG.
- 09: the mirror is a per-user claim `transcripts` (session class), not a folder of the user's disk as Q-M3 worded it: every session mounts the whole disk, so a mirror there would let one session write another's transcripts and hook events (an orchestrator would receive forged replies). Each pod mounts only its own folder (`subPath`), as on Docker; a root init step makes it, gives it to uid 1000 (the git agent's to 2000), 0700, and empties its hook events on each pod start. The claim is made when missing by create and git setup, never applied over, and carries no session label so kill keeps the folder as Docker does. MCP-15's amendment records it. The MCP pod (chunk 10) mounts it whole, read-only, and must read 0600 files of uids 1000 and 2000.
- 10: `aidc mcp` routes by the configured backend (`--backend` overrides), like `aidc git`. The server runs as root with only DAC_OVERRIDE and a read-only root (the mirror's files are 0600 of uids 1000 and 2000; baseline allows DAC_OVERRIDE, not DAC_READ_SEARCH). Its config and token are one projected volume at /aidc-config, where both the server (config.py reads config.yaml beside the token) and the CLI (`_aidc_global_config_file`'s fallback) already look. Egress to the API server: the kubeconfig's server (resolved locally, loopback refused; `kubernetes.api_endpoints` overrides) plus the in-cluster Service address read from the pod's env after rollout, since a CNI may judge before or after the Service's translation; no new grant is needed for it. The user's Role gains `get` on the one Secret `aidc-mcp-token` (MCP-05: the user's machine reads the token), so users added before need `aidc user add` again. The image bakes the CLI from a staged context (aidc_build_context); the server's CLI session verbs pass `--backend kubernetes` (chunk 08's observation). Chunk 09's live check runs with this chunk's: the server mounts the mirror claim whole, read-only.
- 10 (review rev-20261126T094350Z, main 2026-11-26): the server mounts the mirror read-only and prunes nothing; the session's hook writer keeps the newest 200 events, one owner on both backends (MCP-46 refined). Over a running server the in-cluster API address is read first and the policy applied once (a server that does not answer keeps what its policy allows; with neither readable start stops, changing nothing). The server's ConfigMap is rendered in manifests.sh with strenv. Status names a not-ready pod's reason and the state claim's use (warning at 80%: the unrotated access log shares the claim with the store). kubectl's version follows the Alpine base (main: left as it is).
- 11 (main 2026-11-26, within the owner's Q-M1 ruling; the owner may overrule): VPN exposure is an Ingress `mcp-<user>.<pages domain>` on the pages' class and wildcard certificate, `mcp.kubernetes.expose: ingress`, off by default; the session name `mcp` is reserved on Kubernetes. The in-cluster Service is reachable from every namespace but the user's own (no session reaches it), behind the bearer. The live test goes through the Ingress (the owner's orchestrator may run outside the cluster).
- 12: no new mechanism was needed: the server's pod (chunks 08-11) already runs the CLI's cluster create; this chunk proves it fits: a static check that every cluster call `aidc create|list|status` reach (minus page and tunnel paths) is in K8S_MCP_RULES (mutation-checked), a create run under the pod's conditions, the cluster create's progress phases and a 960 s timeout. Git identity is not bridged for a server-made session (no git in the image; same as Docker's aidc-mcp). session_mcp_set reaches the orchestrator only where the session's egress allows (security-model, unchanged).
- 15/16 (built together: the server's one check both records a poke and freezes): the webhook is a poke naming only the session, on its own port (7879) and app, unauthenticated and never trusted (the server reads the flag by exec). The server's Service is made by the first create and kept by stop, so a session's webhook address (the proxy pod has no cluster DNS) stays good. Freeze per Q-K3, made complete: every egress rule of the session's NetworkPolicies (dev, proxy, relays, networks) is cut to [], since policies are additive and a deny-all policy alone cuts nothing; a frozen mark on the state claim; a reconcile pass at start and each minute (missed pokes, re-applied policies); egress/network add refuse a tainted session. Freeze needs the user's server running: status says PENDING otherwise.
- Cumulative review rev-20261126T105056Z (0 blocking, 5 warnings, all fixed with its observations): audit_get's description extends 1.x's (test pins the one change, TRS-11); taint's tables moved into state.LIFETIMES, the report keyed by instance id, and every module's tables now declared (state.ELSEWHERE, the lifetimes test scans the package); a stalled freeze is logged once per cause and left as /var/state/freeze-trouble for `aidc status`; a git answer into a full queue is refused before its request is decided (D6 all-or-nothing); the backend runners renamed run_backend/BackendResult/BackendFailed (they run kubectl too; the decision to keep them separate stands).
- 08: the image's kubectl and yq belong to chunk 10 (the in-cluster image).
- 08 live probe (2026-11-26, owner's go-ahead; namespace aidc-u-pace, the user's own kubeconfig, a scratch HOME): `aidc create probe08 --backend kubernetes` from the branch's CLI passed with no admin step. The MCP's Kubernetes backend, run on the laptop against it: the session list (probe08 running, git running), the instance id (the state claim's uid) and NotFound for a missing session, exec in the dev pod as vscode (uid 1000, umask 0002, tmux `main` up, `/var/aidc/transcript-out` 0700 vscode), exec in the proxy's policy and audit containers, env and workdir, the mirror's mount as `pvc:aidc-u-pace/transcripts`, a missing session's exec reported missing; through the service: session_list, session_status, audit_get (the sidecar's trail, empty), file_put read back by session_exec. Then `aidc kill probe08`. Seen: session_status says the session predates 2.0's hook events, because the cluster registry holds the v1.9.10 images (`aidc k8s build`, the owner's step, brings the branch's). Left by design: the user's `transcripts` claim and the `aidc-mcp` Service (made by the first create, kept by kill), and the audit trail `probe08-audit-20261126194341` (kept by kill; its deletion is the owner's call). Script and output: the session's scratchpad (probe08.py, probe08-result.txt).
- 17+18 (built together: the broker's pass both renews and switches): every token handling is Claude Code's own (main 2026-11-26: no call to Anthropic's OAuth endpoint as Claude Code; the owner may overrule); renewal by a one-word prompt to the smallest model when the access token is within an hour of expiry, since `claude auth status` only reads the stored login (Claude Code 2.1.332's source). A session's Claude config dir moved to its own folder of a per-user claim `claude-config`, which the broker mounts whole: Claude Code refuses a symlinked `.credentials.json`, and the broker cannot mount every session's home. projects/ is the user's disk's `.claude/projects` (Q-K2), mounted over it in the dev pod and read-only in the audit sidecar. The broker needs no API token (create/kill reach it by exec; no Role change, no admin step). Usage reaches it through files the session writes in its own folder (`aidc-claude-usage`: status line, StopFailure rate_limit), not the transcript mirror. The stopgap token (`aidc claude-token`) is wired on Kubernetes: a session Secret when no broker runs, never from the MCP server. Review rev-20261126T203556Z (1 blocking: the shared projects/ fed every session's mirror and audit trail other sessions' conversations): one rule, each per-session reader takes only the session's own conversations, named by its Claude's hook events (`own-transcripts`); the audit sidecar reads the session's mirror folder. Its verify (rev-20261126T204708Z: the wrapper's --continue resumed another session's conversation): a cluster session resumes only its own newest conversation, by id; the smoke's transcripts moved to the session's own. Main 2026-11-26: an expired account with renewal failing is spent and switched from even in wait mode; the list gives each reason, the broker's log each change once, and with none usable the sessions' status line says every account needs adding again. Its observations: passes and state updates under one lock; an account whose token expired with renewal failing counts as spent; the renewal margin waits on the live expiry test.

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
| Q-K1 | How a user adds a Claude account to the broker. | 17 — answered 2026-11-26: `aidc claude account add`, login inside the broker pod; one-year token as a stopgap |
| Q-G1 | In ask mode, do GitHub issue writes (create, edit, comment, close) wait for approval like pushes, or run at once like reads? | 13 — answered 2026-11-26: run at once, checked by gitreq |
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
- **Deliverables:** the face module `mcp/src/aidc_mcp/server.py` (rewritten on 3tears-mcp) and
  the guards as `mcp/src/aidc_mcp/authz.py` (1.x's tools.py removed); wire tests rewritten
  against it; the fresh-interpreter import test for TRS-01; token-rotation-on-an-open-session
  test; one run of the built image (handshake, list, call) with the mounted token.
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
  a cluster session's Claude Code hook events (MCP-46) reach the server, so its busy and idle come
  from them (the Kubernetes half of plan-aidc-2.0 W-H-02); `/prawduct:critic`; committed.
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

### Chunk 13: Approvals out of the agent's reach (W-M3-00, Q-K8 as refined 2026-11-26)

- **Description:** A separate user in the git container, `gitreq`, holds and decides requests;
  uid git (the agent) cannot act as it. In ask mode, approval comes only from outside: `aidc git
  approve|deny <id>` and the request list on the user's machine (exec as gitreq), or the MCP server
  carrying out the orchestrator's answer as gitreq, matched to the request id in the question.
  Every push, PR and merge, including terminal-requested ones, is a request. rules mode runs
  passing requests at once, with the check done by gitreq. Only the user changes a mode. Docker
  in full; on Kubernetes, the gitreq container and the CLI path. The MCP side on Docker (the
  orchestrator's answer performed as gitreq) is this chunk's too, built in its review-fix round
  after the merge (`service/gitapprove.py`, design-10 S10: session_send to `git` whose open
  question names one waiting request, answered plainly Approve or Deny, runs `git-requests
  approve|deny` as gitreq, then sends the answer into the question; ambiguous or unclear answers
  approve nothing and send nothing). Kubernetes is chunk 14.
- **Depends on:** none in this plan for the container and CLI part (W-K0 done).
- **Requirements:** K8S-05, K8S-06, K8S-24, GIT-07.
- **Also (GIT-07):** gitctl issue verbs (list, view, create, edit, comment, close, reopen) on added
  repos, through gitreq, and the session `gh issue` stand-in handing them to the git container;
  the approval policy per Q-G1.
- **Done when:** a test and a mutation show uid git cannot approve, deny, change a mode, or push,
  PR or merge outside a request (Docker and the Kubernetes pod spec); `aidc git approve` approves;
  rules mode runs a passing request with no question; on Docker an orchestrator's "Approve" or
  "Deny: <why>" to the agent's question decides the request it names, and a test and a mutation
  show an answer to a question naming no waiting request approves nothing
  (`mcp/tests/test_git_approve.py`); `/prawduct:critic`; committed.
- **Owner's hands:** the live check of the orchestrator approving a request on Docker (a
  logged-in git agent and the orchestrator; tests/smoke/README.md).
- **Notes (the MCP side's entry point):** the MCP server carries out an orchestrator's answer by
  running, as gitreq, `git-requests approve <id>` or `git-requests deny <id> [<why>]`. On Docker
  that is `docker exec -u gitreq -e HOME=/var/lib/gitctl/gitreq aidc-git-dev git-requests ...`; on
  Kubernetes, `kubectl -n <user ns> exec <git pod> -c gitreq -- git-requests ...` (the pod's own
  gitreq container, since kubectl exec cannot choose a user). Each acts only on a request still
  waiting: one that is gone, done, denied or being run exits 1 and says which, and nothing
  happens. approve prints the result's message (and output) and exits with the run's status.
  The id is the 32-hex request id the agent's question names (`git request <id>`); the MCP side
  matches the answer to it and passes nothing else. git-requests refuses these verbs when it is
  reached through sudo or runs as anything but gitreq, so only an exec from outside the
  container can use them. The same exec reads the list (`git-requests list`, `show <id>`).
- **Notes (what the agent keeps):** reads (pull requests, issues, protections, fetch, the action
  log) and `gitctl tidy`. Tidy's `delete-branch` stays the agent's (and gitwc's, on Docker): it
  deletes only a branch GitHub reports merged, never a base, so it removes nothing a merge has
  not already landed. `gitctl logout` is the holder's (the user's `aidc git logout`); `gitctl
  login` stays the agent's, since it needs the user's own approval in a browser.

### Chunk 14: Git approvals through the orchestrator on Kubernetes (W-M3-01..03)

- **Description:** The in-cluster server watches the `git` session, and an orchestrator's answer
  to the agent's question decides the request it names as on Docker (design-10 S10,
  `service/gitapprove.py`), the holder reached by `kubectl -n <user ns> exec <git pod> -c gitreq
  -- git-requests approve|deny <id> [why]` (the pod's own gitreq container; kubectl exec cannot
  choose a user) instead of `docker exec -u gitreq`. The answer still goes into the question
  (paste, or the key sequence per W-K0-03 / Q-M5) so the agent's turn goes on; the decision does
  not depend on it, since the agent approves nothing. The smoke's Claude part automatic.
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

- **Description:** On taint, `freeze` (the default) cuts the session's egress by emptying the egress
  rules of every NetworkPolicy of the session (NetworkPolicies add up, so a deny-all policy beside
  them would cut nothing), and marks it frozen; acted on by the per-user server (Q-K3, §5, as
  built: decision 15/16).
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
  in mesh mode or both by config; the image(s) per Q3; aidc-mcp's state store on the Postgres L3
  by configuration (store.py's tables created on Postgres, the same collections; chunk 07 built
  it on SQLite).
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
