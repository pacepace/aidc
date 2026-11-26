# Boundary Patterns — aidc

Contract surfaces where components interact. A change that crosses one of these needs its
consumer checked before the work is done — for the first two, the consumer is another program
that ships separately.

## Contract Surfaces

### The MCP tool surface (external consumer)
- **Producer**: `mcp/src/aidc_mcp/tearstools/` (one TearsTool per tool), served by
  `server.py` (3tears-mcp) with the refusals in `authz.py`, and `resources.py`; the envelopes
  are built in `mcp/src/aidc_mcp/service/` (`common.envelope_ok` / `envelope_err`).
- **Consumer**: the orchestrator, over streamable HTTP with a bearer token. It is a
  separate product, developed by another session/agent.
- **Contract**: every tool returns `{"ok": true, "data": ...}` or `{"ok": false, "error": "...",
  "error_code": "<kind>"}` as its content; from 2.0 a failure is also `isError: true` with the
  same code (and `retryable`) under `_meta["threetears.mcp/error"]` (TRS-05). The code set is
  closed (`service/common.py` `ERROR_CODE_DESCRIPTIONS`) and documented in
  `docs/design-10-turn-state-and-sending.md` D6.
- **Rule**: adding a tool or a code is additive and safe; removing one, renaming one, or changing
  what a code means is agreed with the orchestrator first. `session_create` exists only under
  MCP-38. A test fails if any failure path omits a code or invents one.

### The reply callback (external consumer)
- **Producer**: `post_turn` in `mcp/src/aidc_mcp/service/callbacks.py`.
- **Consumer**: the orchestrator's callback endpoint, `POST {callback_url}/api/v1/internal/callback/{conversation_id}`.
- **Contract**: the payload table in design 10 D5 — `content`, `ok`, `source`, `session`,
  `prompt_origin`, `interrupted`, plus `error_code` on the two callbacks that are notices rather
  than replies, and `speaker` only when `orchestrator.send_speaker` is on.
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

### A session's Claude Code hook events ↔ the MCP's turn state
- **Producer**: `aidc-hook-event` (`.devcontainer/hook-event.sh`; the git image takes the same file
  through its staged build context), run by Claude Code's SessionStart, UserPromptSubmit,
  Notification and Stop hooks from the managed settings, only for the Claude in tmux window
  `main:claude`, as the container's session user.
- **Consumer**: aidc-mcp (`hook_events.py`, `service/turns.py`), reading
  `<mirror>/<session>/hook-events/`: on Docker the host-mounted state dir, on Kubernetes the
  user's `transcripts` claim, mounted read-only (each session's pod mounts only its own folder).
- **Contract**: one file per event, `<epoch-ns>-<pid>.json`, written temp-then-rename; the hook's
  JSON input with `event` and `at` (UTC, milliseconds) added; names sort in time order. The folder
  starts empty with each session instance (`aidc create`; the git container's main process; on
  Kubernetes the dev pod's mirror step). Retention is the writer's: it keeps the newest 200 event
  files; the reader never removes one.
- **Rule**: the writer never fails or prints (a Stop hook's output is read as a decision); a
  writer that cannot write shows as `hook_events_missing`, never as silence. A new Claude Code
  hook field the reader depends on is measured against a real session first.

### A session's policy sidecar ↔ the user's MCP server: the taint webhook (Kubernetes)
- **Producer**: `proxy/policy/policy.sh`, on a session's first taint, when `AIDC_TAINT_WEBHOOK`
  is set (session-create renders it from the server's Service address).
- **Consumer**: aidc-mcp's taint listener (`server.build_taint_app`, `AIDC_MCP_TAINT_PORT` 7879)
  and `service/taint.py`.
- **Contract**: `POST /taint` with `{"session": "<name>"}`, nothing else; 202 for a session
  name, 400 otherwise, every request in the access log. The NetworkPolicies let the user's proxy
  pods reach that port only.
- **Rule**: a poke is never trusted: the server reads the taint flag itself, and also looks at
  every session's flag on its own, so a lost poke costs at most a minute.

### The user's MCP server ↔ `aidc status`: the frozen mark (Kubernetes)
- **Producer**: `service/taint.py` (session_facts.mark_frozen, mark_freeze_trouble), by exec into
  the session's policy sidecar.
- **Consumer**: `scripts/k8s/lib.sh` k8s_session_frozen, printed by `session-status.sh`.
- **Contract**: `/var/state/frozen` (JSON: `frozen_at`, `by`, `egress_cut`, `trigger`, `domain`)
  once the egress is cut; `/var/state/freeze-trouble` (JSON: `at`, `step`, `error`) while a
  freeze cannot go on, removed once frozen. The reader prints the JSON after `yes ` / `stalled `.
- **Rule**: the frozen mark is written only after every egress rule is cut; a sidecar that cannot
  be read is "unknown", never "not frozen".

### A cluster session ↔ the user's Claude account broker (files in the session's Claude config dir)
- **Producer → consumer**: the broker (`broker/claude-broker.sh`) writes `.credentials.json`
  (access token only), `.aidc-account` and `.aidc-notice` into each session's folder of
  `claude-config`; the session's Claude and `aidc-claude-usage` read them. `aidc-claude-usage`
  (`.devcontainer/claude-usage.sh`, in the session) writes `.aidc-usage.json`
  (`{account, seven_day, resets_at, at_s}`) and `.aidc-limit.json` (`{account, at_s}`); the
  broker reads them.
- **Contract**: every file by temp then rename; the refresh token never in a session's folder;
  a report names the account it measured (the producer's, not the consumer's guess).
- **Rule**: `at_s` is the session pod's clock and is compared only with the broker's within a
  freshness window of half an hour; a report naming no account is not counted. The session image
  and the broker image are built by the same `aidc k8s build`, so their versions match.

### A cluster session ↔ the user's MCP server: the account and the lease (the transcript mirror)
- **Producer**: in the session, `aidc-claude-usage` writes `claude-account.json`
  (`{account, notice, at}`); `aidc-hook-event` writes `own-transcripts` (a transcript file name a
  line) and, through the lease (`aidc-claude-lease hook --then`), a `PromptRefused` hook event
  (`{holder}`) in place of a refused prompt's UserPromptSubmit.
- **Consumer**: aidc-mcp (`service/sessions.py` claude_account; the mirror, `user-main.sh`,
  copying only `own-transcripts`' files; `service/sending.py` `_refused_by_lease`).
- **Rule**: the session's clock is never compared with the server's: the refusal is read as the
  first prompt event after the newest event name taken before Enter (the pod's own sequence),
  and the retry a minute later is the server's own clock.

### The user's machines ↔ the cluster: the lease and the synced folders (Syncthing)
- **Producer and consumer**: `aidc-claude-lease` on every side (cluster sessions from their
  managed settings, a machine through `aidc sync lease-hook`), writing and reading
  `<project>/<session id>.aidc-lease` (`{machine, until_s}`), carried by `aidc-claude-projects`.
  `aidc-claude-shared` carries the Claude files from the machines to the cluster only.
- **Contract**: `until_s` is the holder's clock, read by another machine against its own: a
  lease is good for its 15 minutes give or take the machines' skew and Syncthing's seconds.
- **Rule**: a machine may run an older aidc than the cluster image, so a change to the lease's
  fields is additive and both readers must accept the other's; the folder ids and directions are
  fixed (`scripts/lib/claude-sync.sh`) and changed only with an upgrade note.

### The MCP server ↔ the git container's request holder
- **Producer**: aidc-mcp's `service/gitapprove.py`, carrying out an orchestrator's answer to the
  git agent's question; the user's `aidc git approve|deny|requests` uses the same entry point.
- **Consumer**: `git-requests` (`gitctl/git-requests.sh`) running as gitreq in the git container.
- **Contract**: `git-requests list` (a header line, then one waiting request per line, its 32-hex
  id first), `approve <id>`, `deny <id> [why]`; reached on Docker by `docker exec -u gitreq -e
  HOME=/var/lib/gitctl/gitreq aidc-git-dev`, on Kubernetes by `kubectl exec -c gitreq` into the
  git pod. Each verb acts only on a request still waiting and exits non-zero saying why otherwise.
- **Rule**: the request id always comes from the agent's own question, never from the caller's
  text; the holder refuses these verbs to anything reaching it through sudo or as another user,
  so only an exec from outside the container decides.

### The session compose file
- **Producer**: `scripts/cmd-create.sh` + `proxy/compose.yaml.template`.
- **Consumer**: the host docker daemon, and every later `aidc` command for that session.
- **Contract**: container names `aidc-<session>-<role>`, the session network `aidc-<session>-net`
  (which identifies the session), the labels `aidc.session` / `aidc.role`.
- **Rule**: those names are load-bearing for the MCP as well as the CLI — the network id is how a
  killed-and-recreated session is told from an upgraded one.
