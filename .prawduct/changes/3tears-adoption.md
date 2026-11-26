---
schema: 1
type: feature
scope: 3tears-adoption
date: 2026-11-26
title: aidc 2.0's MCP server on 3tears (build-plan-3tears-adoption)
---
**Why:** aidc 2.0 rebuilds the MCP server on 3tears (design-13, TRS-01..25): one tool implementation
served over MCP locally and on a 3tears mesh, built on the unreleased 3tears branch first (owner
ruling 2026-11-26).

**What:**
- Chunk 01: the 3tears family (3tears-mcp, 3tears-tool-contract with its MCP face,
  3tears-tool-schema, 3tears-observe) comes in as uv git sources pinned to one commit of
  `feat/mcp-face`, every package from the same commit; the `mesh` extra is declared empty. The
  REL-09 cooldown stays and does not hold git sources back (they carry no upload date), so no
  exception was added. The image installs git for the sync only. `tests/test_dependencies.py` pins
  TRS-02 (mcp 2.x, one 3tears minor and commit) and TRS-17's light lock. The 3tears surfaces the
  later chunks use are recorded in `.prawduct/artifacts/api-notes-3tears.md` against the pinned
  commit.
- Chunk 02: `mcp/src/aidc_mcp/tearstools/` holds one `TearsTool` per tool (23, session_create
  included; the face leaves it out unless MCP-38 turns it on). Each tool's `call` signature and
  docstring are 1.x's, carried over from tools.py's source, so its schema (made self-contained by
  tool-schema) and every description match 1.x word for word; the 1.x list is kept as
  `tests/fixtures/published-tools-1x.json` for that check. A tool returns the service's envelope as
  JSON content, `success` = `ok`, the aidc code in `metadata["error_code"]`; the platform's
  `ToolResult.error_code` stays unset. Arguments are read as 1.x read them (pydantic, lax; defaults
  filled, unknown ones ignored); one that cannot be read is `invalid_argument`. Phases go to the
  caller as log lines through the call context; watch changes are announced through a hook the
  face supplies. tools.py still serves the 1.x face until chunk 03 replaces it, so the shared
  descriptions exist twice for this one commit.
- #76: `file_put` writes through a temporary file renamed over the target instead of `install -m
  MODE /dev/stdin PATH`, which the session image's uutils coreutils refuse on an existing file.
- Chunk 13 (owner ruling 2026-11-26, git approvals out of the agent's reach): a user of its own
  in the git container, `gitreq` (2003), holds and decides requests. The request folder, the
  session modes (now `state/modes` in it) and every decision are its. The agent (git) reaches it
  only through a sudo rule for list, show, prompt, handoff, handed and watch; approve, deny and
  the mode and record verbs refuse git and anything reached through sudo. gitctl's GitHub writes
  (push, pr-create, pr-comment, pr-merge, protect) run only for gitreq, checked on every side.
  The user's `aidc git approve|deny|mode|push|pr|merge|protect` and aidc's session records run as
  gitreq: `docker exec -u gitreq` on Docker, and on Kubernetes an exec into the git pod's new
  `gitreq` container, which runs the watcher. The holder's mode and paths come from a read-only
  settings file (Docker: `~/.config/aidc/git-settings`; Kubernetes: the `git-settings`
  ConfigMap). The agent's `gh` is now the sessions' stand-in, so its own pushes and pull requests
  are requests too (always ask). Waiting requests reach its Claude by the main process asking the
  holder (handoff), not by the watcher typing in. The agent's question names the request id, and
  it answers with the `aidc git approve|deny` to run. Setup gives the holder a request folder the
  agent held, contents included.
- Chunk 13, GIT-07 (owner rulings 2026-11-26): GitHub issues through the git container, as an
  issue-scoped API passthrough. `gitctl api` passes on only the endpoints of one table
  (`GITCTL_API_TABLE`, gitctl-rules.sh: the calls prawduct's backlog makes, and the `gh issue`
  forms), each with its query and body keys, on added repos, with the attribution check and the
  conditional read; writes run only for gitreq. The gh stand-in sends `gh api` and `gh issue`
  as `api` requests; the holder runs them at once in every mode (Q-G1) and the caller gets
  GitHub's stdout, messages and exit status.
- Chunk 13, also: the holder wakes on a new request (inotify) and reads requests with one jq, so
  an issue call takes about 0.3 s; `gitctl logout` is the holder's too; the mode left the
  containers' environment; the git agent's managed settings run aidc's hook writer on
  SessionStart, Stop, Notification and UserPromptSubmit, into its Docker mirror (MCP-46/47);
  `tests/smoke/git-holder.sh` checks the users, sudo rules and process layout live on Docker.

- Chunk 03: the local face is 3tears-mcp's `McpServer` (`server.py`), stateful Streamable HTTP on
  SSE responses, serving the TearsTools through the bridge under their 1.x names, with the
  server's version and instructions. `tools.py` and `disconnect.py` are gone. Scope and taint are
  `authz.AidcAuthorizer`, which 3tears asks before a tool runs; a refusal answers aidc's envelope
  as its content (1.x's text, `data.tainted` included) and is logged as before. aidc's 20 codes
  are registered as protocol codes, with which are retryable: a failed call is now `isError`,
  its code under `_meta["threetears.mcp/error"]`. The bearer is checked against the token file
  as it is now, in the gate (401, logged) and in the server's resolver, so a rotated token
  refuses an open session's next message. Resources are 3tears resources with the scope in the
  authorizer: an out-of-scope read is now a JSON-RPC refusal, not a JSON error body, and the
  global config is left out of a scoped server's listing. A dropped connection cancels a
  blocking `session_invoke` through 3tears (no watcher of aidc's own). `published-tools.json`
  is regenerated: the same names and descriptions, self-contained schemas. Every tool declares
  the envelope as its output schema, so the envelope is sent as `structuredContent` too (design-10
  D6), failures included. Where 1.x accepted null for an optional argument the schema lists
  `[type, "null"]` and null reaches the tool as not given; an integer argument sent as a whole
  number in text ("5") is read as the number before the schema checks it (3tears'
  `prepare_arguments`), the schema staying `integer`. A failed call's `retryable` is design-10
  D6's new Retryable column (`cli_failed`, `invoke_busy`), held to it by a test. A token file
  unreadable for a moment (mid-rotation) answers a logged 401.

- Chunk 04: each phase `session_create` and `session_invoke` report is `notifications/progress`
  (counting up, the phase as its message) as well as a log line. The service reports a session
  changed (`common.session_changed`: a paste, a delivered reply, a create, an interrupt), and
  the face sends `notifications/resources/updated` for the session's status and the session
  list to subscribed clients, which 1.x never did (MCP-09). `published-tools.json` names each
  tool's `mesh_name`. The CHANGELOG's Unreleased section has the 2.0 upgrade notes; the README's
  MCP section says what changed.

- Chunk 05: observability on 3tears-observe (`observability.py`). The server logs through it
  to stderr; every access-log event is also one structured line; each tool call runs in its
  own scope (a correlation id and the tool's name in the log context, one `aidc.tool_call`
  span), entered by the tool itself so every face gets it. Export is off unless configured:
  `AIDC_MCP_OTEL_ENDPOINT` (OTLP/HTTP, the `otel` extra) and `AIDC_MCP_METRICS=true` (per-tool
  counts and durations at `/metrics` behind the bearer, the `prometheus` extra). The access log's
  file and fields are unchanged.

- Chunk 07: aidc-mcp's durable state is one 3tears SQLite L3 per state dir
  (`watcher-state/aidc-state.sqlite`; `aidc_mcp/store.py`): watermarks, the delivery ledger,
  send queues, webhooks, send records, prompt origins, joined batches, pasted prompt ids, session
  markers and dead letters, each a 3tears collection whose rows keep the JSON document 1.x kept
  in a file (`.prawduct/artifacts/data-model.md`, with the persisted-format questions answered
  before the fields were designed). transcript.py's persistence functions keep their names and
  arguments; a write returns once it is committed. The first start on a 1.x state dir reads its
  files in (idempotently) and moves them to `watcher-state/migrated-1x/`. `python -m
  aidc_mcp.store` prints the store for a person after an incident. 3tears core comes in from the
  same commit (asyncpg and SQLAlchemy with it, no NATS client; TRS-01/TRS-17 amended by owner
  ruling, and TRS-01's wording on 3tears' own `threetears.nats` modules applied here).

- Chunk 23 (MCP-46): every session's Claude Code runs with aidc's hooks from its managed
  settings (`.devcontainer/managed-settings.sh`, installed by the entrypoint; shared plugins kept
  beside them). `Stop`, `Notification` and `UserPromptSubmit` each run `aidc-hook-event`
  (`.devcontainer/hook-event.sh`), which writes Claude Code's hook input, with `event` and `at`,
  as one file in `hook-events/` of the session's MCP-readable mirror dir, by rename; it never
  fails or holds up Claude. The MCP reads them with `aidc_mcp/hook_events.py`. MCP-46 and
  MCP-47 are added to the requirements. The git agent's own managed settings (gitctl/) still
  lack the hooks; asked of that wave's owner.

- Chunk 24 (MCP-47): busy, idle and waiting on a permission prompt come from the session's hook
  events (`turns.turn_from_hooks`, design-10 S9); the transcript stays the record (a turn still
  being written, a Stop hook's hold, a turn ended by an Esc after output) and the reply's
  content; the screen is read only for what a paste needs. An Esc before output is reported
  after Claude's idle notice. `SessionStart` joins the hooks. A session from before 2.0 (no
  event, no hook in its settings) is `turn: "unknown"` and `session_send` refuses it with
  `session_outdated`; the screen rule, its working-text markers and stall window are gone. The
  turns suite was rewritten from screen evidence to hook evidence, each scenario kept (Esc before
  output, a prompt put back in the box, Stop hook holds, a session created again, restarts).

- Chunk 13, the MCP side (Docker): `session_send` to the git agent whose open question names
  one git request carries the orchestrator's answer out as the request holder
  (`service/gitapprove.py`, design-10 S10): "Approve" or "Deny: <why>" runs `git-requests
  approve|deny <id>` as gitreq, then the answer goes into the question; the result's
  `data.git_request` says what happened. New codes: `git_answer_unclear` (not plainly Approve or
  Deny), `git_request_ambiguous` (the question names several), `git_requests_unreadable`
  (retryable). An answer into a full queue is refused before the request is decided.

- Chunk 08 (K8S-01): `backend.py`'s Kubernetes half, chosen by the server's environment
  (`AIDC_MCP_BACKEND`, `AIDC_K8S_NAMESPACE`): kubectl exec into the dev pod (the session user by
  `sudo -E -H`), the proxy's policy and audit containers, the git pod (its gitreq container for
  the holder); the instance id is the state claim's uid. The audit resources read the trail in
  the audit sidecar on both backends (they never worked: they parsed an `audit:` line `aidc
  status` does not print). The runners are `run_backend`/`BackendResult`/`BackendFailed`.

- Chunk 09 (MCP-15 refined): cluster sessions' and the git agent's transcripts and hook events go
  to a per-user claim, `transcripts`, each pod mounting only its own folder. The session's hook
  writer keeps the newest 200 events, on both backends; the server only reads them.

- Chunks 10-12 (K8S-07, MCP-02/03/05/06/10/11/13/38): `aidc mcp start|stop|status|logs|token
  rotate|token show` on Kubernetes run the same server as one replica in the user's namespace
  (`scripts/k8s/mcp.sh`): its state on `aidc-mcp-state`, the mirror read-only, the token a
  Secret also copied to `~/.config/aidc/mcp-token`, root with only DAC_OVERRIDE. The image
  carries the CLI, kubectl and yq. It is reached in the cluster by its Service (every namespace
  but the user's own) and, with `mcp.kubernetes.expose: ingress`, at `mcp-<user>.<pages
  domain>` (refused when that name resolves to a public address); it may reach only the API
  server and the orchestrator's callback. `session_create` and `session_mcp_set` work through it;
  a static test holds the CLI's cluster calls to the MCP's Role.

- Chunks 15-16 (W-M4, W-K4, SEC-05 amended): the policy sidecar pokes the user's server on port
  7879 (`{"session": <name>}`, never trusted); the server reads the flag and, with `freeze`,
  empties every egress rule of the session's NetworkPolicies and marks `/var/state/frozen` (a
  stalled freeze leaves `/var/state/freeze-trouble`), looking at every flag each minute too.
  `aidc status` says FROZEN or PENDING; egress/network add refuse a tainted session.

- D6 (owner ruling 2026-11-26): `claude_not_running`, `paste_failed` and `turn_not_finished` are
  retired from the closed code set; only the synchronous `session_run`, gone in 2.0, returned
  them (`claude_not_running` stays a waiting reason).
- Chunks 17-18 (K8S-16, K8S-17; Q-K1): the user's Claude account broker (`aidc claude account
  add|remove|list|use`, `aidc claude broker ...`, image `aidc/broker`) holds each account's
  login on `claude-accounts`, renews it by running Claude Code, and writes the active account's
  access-only credentials into every session's Claude config dir, now its own folder of
  `claude-config`; accounts switch around a configured cycle on weekly usage and rate limits
  (auto or wait), an account whose login ended is moved from at once, and with none usable the
  sessions and `session_status`'s new `claude_account` say so. Until an account is added, the
  long-lived token from `aidc claude-token` reaches cluster sessions. A cluster session's
  `projects/` is the user's disk's; its mirror and audit trail hold only its own conversations,
  and it resumes only its own.
- Chunk 19 (K8S-18; Q-K11): `aidc sync` runs a Syncthing pod reaching only the user's machines
  over the LAN or VPN: conversations both ways under a lease, the Claude files a Claude loads
  from the machines only; a Mac's alias reconciler; symlinks in synced conversation folders
  removed (#35); a prompt the lease refuses waits as `conversation_held_elsewhere`.

**Proof:** chunks 17-19: unit tests (`tests/unit/test-claude-broker.sh`, `test-k8s-claude.sh`, `test-claude-usage.sh`, `test-claude-sync.sh`, `test-k8s-sync.sh`, and the session, git, hook-event, mirror and resume tests; `mcp/tests/test_session_send.py` for the refusal, `test_session_report.py` for `claude_account`); their live runs wait on the owner's Claude login, a second account and a Mac (listed in the plan). Chunks 08-16: unit tests with kubectl stubs mirroring the Docker ones (`tests/test_backend.py`, `tests/test_taint_freeze.py`, `tests/unit/test-k8s-{session,git,mcp,net,rbac}.sh`, `tests/unit/test-policy-webhook.sh`), the MCP's Role checked against every cluster call its CLI reaches; the live cluster runs wait for the owner (listed in the plan). Chunk 24: the delivery, turns, send and roundtrip suites pass with the screen rule removed (the roundtrip harness fires the events a real session's Claude does). The live checks wait on a logged-in Claude in the scratch session and on the orchestrator. Chunk 23: unit tests for the writer and the settings (`tests/unit/test-hook-event.sh`) and for the reader, run against the shipped writer (`tests/test_hook_events.py`). Live, on a scratch Docker session from test-tagged images: the managed settings hold the three hooks and the shared plugin, and the hook, run inside the container as the session's user, wrote an event the MCP read back from its state dir on the host. Claude itself firing each kind waits on a logged-in Claude in the scratch session (asked of the owner). Chunk 07: the built image, started on a state dir holding 1.x files (a webhook, a watermark, a ledger, a send dead letter), read them in and moved them aside, resumed the webhook, printed the store with `python -m aidc_mcp.store` while running, and after `docker kill` and a start resumed it again from the store. The restart and delivery suites pass on the store (assertions that read a state file read the store instead, same meaning); a write killed with SIGKILL right after it returned is found, for each kind (watermark, ledger, queue, webhook, send record, dead letter); a 1.x state dir is read in once, kept aside, not read twice after a restart, and finished after a start killed half way; a second process on the same state dir is refused; the local server in a fresh interpreter loads the SQLite L3 with no NATS client installed or imported and opens no connection. Chunk 05: the access-log tests pass unchanged; tests show one correlation id on every log line of a call and a fresh one per call, one span per call, no network connection and no exporter set up with export off, export to a configured endpoint, and metrics counted and served only when switched on. Chunk 04: `AIDC_SMOKE_GIT=0 make smoke` from a separate checkout with a test version tag: 122 of 123, the one failure the test-tag version line (the image reports the package's 1.9.10), as on the service split's run; its MCP part initializes, lists and calls through the new server. The MCP suite is green, with wire tests reading a progress notification and a log line before the result for both tools, and a real uvicorn server pushing `notifications/resources/updated` to a subscribed client's stream. Chunk 03: the built image (test tag, a test-only container with the token mounted as `aidc mcp start` mounts it) answered 401 without a token, the handshake with aidc's name, version and instructions, the tool list, a call failing with its code on the protocol result and the envelope as structured content, the resource list, and a token rotation refusing the old token at once and serving the new one, each request in the access log. The MCP suite is green, the wire suite against the new server included (cancel, DELETE and dropped connection each stop a blocking invoke; a rotated token refuses an open session; every aidc code rides the protocol result; local mode starts, lists and calls every tool in a fresh interpreter with no NATS, Postgres, LangGraph or 3tears core loaded). Chunk 02: the MCP suite is green; #76 reproduced in `ubuntu:26.04` (uutils 0.10.0: `install` exits 1 on an existing file) and the new write checked there (overwrite, mode applied, no temporary file left, a missing directory fails). Chunk 01: the MCP suite is green on the new lock; the image builds from it
(`docker build`, test tag) and imports the server with no git left in it.

## Consumer note
Chunks 03-04 change what a caller sees, chunk 07 what an operator sees, and chunks 08-16 what a cluster user gets (aidc 2.0; the CHANGELOG's Unreleased upgrade notes):
- A failed call (`ok: false`) is now `isError: true`, its code also under
  `_meta["threetears.mcp/error"]` with `retryable`; the envelope text is unchanged.
- Input schemas are self-contained: an optional parameter is `type: [type, "null"]` rather
  than `anyOf [type, null]`, and titles are gone. Null and whole numbers sent as text are still
  accepted; leaving an optional argument out and sending a real number are the forms to use.
  Arguments a schema refuses answer `INVALID_ARGUMENTS` before the tool runs.
- A resource of a session outside a scoped server's scope is refused as a JSON-RPC error, and
  `aidc://config` is not listed on a scoped server.
- Progress notifications for `session_create` and `session_invoke` phases; resource update
  notifications for a session's status and the session list; `mesh_name` in the published list.
- `file_put` overwrites an existing file (#76).
- Sessions created before 2.0 must be killed and created again: their Claude reports no hook
  events, `session_send` refuses them with `session_outdated`, and `session_status` says
  `turn: "unknown"`.
- aidc-mcp's state is `watcher-state/aidc-state.sqlite` rather than one JSON file per session;
  the first start reads 1.x's files in and keeps them in `watcher-state/migrated-1x/`; `python -m
  aidc_mcp.store` in the server's container prints it. Two servers cannot share a state dir.

- `audit_get`'s `audit_dir` is `pvc:<namespace>/<claim>` on a cluster server; the audit
  resources answer for every session (they answered "audit dir not found" before).
- On Kubernetes: `aidc user add <user>` again (the Role reads the MCP token's Secret), `aidc k8s
  build` (the mcp image carries the CLI), then `aidc mcp start`; sessions created again get the
  transcript mirror and the taint webhook; the session name `mcp` is reserved.

### Chunks 17-19 and D6
- A caller that branches on `claude_not_running`, `paste_failed` or `turn_not_finished` can drop
  those branches; nothing sends them.
- `session_status` and `session_list` gain `claude_account` (`{account, notice, at}` or null);
  a new waiting reason, `conversation_held_elsewhere`.
- On Kubernetes: `aidc k8s build` (the broker image, and the dev and git images), then create
  sessions again (their Claude config dir moves to `claude-config`; their history is the disk's);
  `aidc git setup` moves the git agent's. `aidc sync setup --hooks` on each machine.

### Chunk 13
- `aidc git setup` must run again on each backend (new image, the gitreq container on
  Kubernetes, the settings file). Sessions must be created again: their gh stand-in checks the
  request folder is gitreq's. Sessions' own modes start again from the user's mode.
- Answering the git agent's question in its terminal no longer approves: run
  `aidc git approve|deny <id>`. Asking the agent to push or open a pull request makes a request.
- The MCP server's entry point for an orchestrator's answer is `git-requests approve|deny <id>`
  by exec as gitreq (build plan chunk 13, notes).
- A session's `gh api` (the issue endpoints) and `gh issue list|view|create|edit|comment|close|
  reopen` work through the git container, so prawduct's backlog on GitHub issues works in a
  session. Issue writes run at once in every mode, checked by gitreq; there is no delete,
  transfer or lock.
