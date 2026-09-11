# aidc — Requirements

**What this covers.** Authoritative requirements list for `aidc` (AI Dev Container). Each requirement has a stable ID, priority, and a source pointer. Design documents in `docs/design-NN-*.md` reference these IDs. Task shards (written later) cite them as well.

## ID conventions

| Prefix | Area |
|--------|------|
| `CTR-NN` | Container base, runtime, mounts, profiles |
| `GIT-NN` | Git isolation and asymmetry |
| `DKR-NN` | Docker-in-Docker |
| `NET-NN` | Network egress and proxy stack |
| `CLI-NN` | `aidc` command surface |
| `RMT-NN` | Remote control (retired — relocated to CTR/CLI; control plane is MCP) |
| `MCP-NN` | MCP control plane (external AI orchestration) |
| `SEC-NN` | Safety model, taint, threat mitigation |
| `CI-NN` | Continuous integration |
| `REL-NN` | Release engineering and distribution |

## Priority

- **P0** — Required for v1. Project does not ship without this.
- **P1** — Required for production confidence but acceptable to ship a partial v1 without.
- **P2** — Future work; tracked here so design can leave hooks for it.

## Source pointers

- **brief** — the original project brief
- **plan-2026-05-21** — clarifying decisions captured in the planning conversation on this date

---

## CTR — Container base, runtime, mounts, profiles

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| CTR-01 | The dev container uses a version-tagged Ubuntu LTS base image (currently 26.04) in the `Dockerfile`. `:latest` is forbidden. Digest pinning + scheduled holdback (e.g., Renovate `minimumReleaseAge: 30 days`) is P2 future work. | P0 | brief §1, plan-2026-05-21 |
| CTR-02 | The dev container is configured via `devcontainer.json` using the standard Dev Containers spec. | P0 | brief §1 |
| CTR-03 | The dev container includes the `ghcr.io/devcontainers/features/docker-in-docker:1` feature for nested Docker. | P0 | brief §1 |
| CTR-04 | The dev container includes the `ghcr.io/devcontainers/features/git:1` feature for full local git capability. | P0 | brief §1 |
| CTR-05 | Language runtimes are selected via a `profile` setting: `python`, `node`, `go`, `rust`, or `multi`. | P0 | brief §1, plan-2026-05-21 |
| CTR-06 | The host repo is mounted into the container read-write at a well-known path (e.g., `/workspaces/<repo-name>`). | P0 | brief §1 |
| CTR-07 | The container MUST NOT mount the host SSH agent socket. | P0 | brief §1 |
| CTR-08 | The container MUST NOT mount any GitHub credentials, tokens, or config (`~/.gitconfig` with credentials, `~/.config/gh/`, etc.). | P0 | brief §1 |
| CTR-09 | The container MUST NOT mount `~/.docker/` or `/var/run/docker.sock`. | P0 | brief §1, §3 |
| CTR-10 | The dev container is fully ephemeral — every `aidc create` produces a fresh container; persistent state lives only in the host-mounted repo. | P0 | brief safety model |
| CTR-11 | The CLI and dev container support macOS (Docker Desktop), Linux (native Docker), and Windows via WSL2. | P0 | plan-2026-05-21 |
| CTR-12 | The dev container MUST run a long-lived tmux session (named `main`) that Claude Code runs inside, and which persists across client detach. (Relocated from RMT-01.) | P0 | brief §5 |

---

## GIT — Git isolation

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| GIT-01 | Inside the container, `git status`, `diff`, `add`, `commit`, `branch`, `checkout`, `rebase`, `stash`, `log`, `blame`, `show` MUST all work. | P0 | brief §2 |
| GIT-02 | Inside the container, `git push`, `pull`, `fetch`, and any remote-touching operation MUST fail. | P0 | brief §2 |
| GIT-03 | The GitHub CLI (`gh`) MUST NOT be installed in the container. | P0 | brief §2 |
| GIT-04 | Push prevention is achieved primarily by mount restrictions (no SSH keys, no credentials); see CTR-07, CTR-08. | P0 | brief §2 |
| GIT-05 | A system-level pre-push hook (`/etc/git-hooks/pre-push`) installed via `git config --system core.hooksPath` MUST hard-fail any push attempt as a belt-and-suspenders defense. | P1 | brief §2 |
| GIT-06 | The host machine retains full remote git capability (push/pull/fetch/gh) — the asymmetry is one-directional. | P0 | brief §2 |

---

## DKR — Docker-in-Docker

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| DKR-01 | The dev container runs a nested Docker daemon via the `docker-in-docker` Dev Container feature. | P0 | brief §3 |
| DKR-02 | The outer container runs with `--privileged` to enable the inner daemon; this is documented and accepted as the v1 trade-off. | P0 | brief §3 |
| DKR-03 | The inner Docker daemon's storage MUST be scoped to the container (no shared volume with host Docker). | P0 | brief §3 |
| DKR-04 | The design MUST document Sysbox runtime as an upgrade path that eliminates `--privileged` while preserving DinD. | P2 | brief §3 |

---

## NET — Network egress and proxy stack

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| NET-01 | All HTTP/HTTPS egress from the dev container MUST traverse the proxy stack; the container is configured with `HTTP_PROXY` and `HTTPS_PROXY` env vars pointing at the Squid sidecar. | P0 | brief §4, plan-2026-05-21 |
| NET-02 | The filtering model is **blocklist**, not allowlist. Default policy is permit; named threats are denied. | P0 | plan-2026-05-21 |
| NET-03 | DNS resolution from the dev container MUST use Quad9 (`9.9.9.9`, `149.112.112.112`) as upstream resolver. | P0 | plan-2026-05-21 |
| NET-04 | The Squid forward proxy MUST consult a file-backed blocklist refreshed from URLhaus, ThreatFox, and HaGeZi Threat-Intelligence Feeds. | P0 | plan-2026-05-21 |
| NET-05 | A maintained state-actor TLD policy file MUST block requests to domains under configured TLDs (default: `.ru`, `.cn`, `.by`, `.ir`, `.kp`). | P0 | plan-2026-05-21 |
| NET-06 | A **refresher sidecar** MUST run alongside Squid in the proxy compose stack: fetch threat feeds on startup and every 6h thereafter, atomically write the blocklist, signal Squid to reload via shared PID namespace (`kill -HUP`). | P0 | plan-2026-05-21 |
| NET-07 | A **policy sidecar** MUST tail Squid's `access.log` in real time, detect malware-list hits, and write a taint flag to a shared volume location readable by `aidc status`. | P0 | plan-2026-05-21 |
| NET-08 | An **audit aggregator sidecar** MUST collect Squid access log, dev container shell history, and Claude Code session transcripts into a host-visible audit directory. | P0 | plan-2026-05-21 |
| NET-09 | Per-project blocklist additions in `<repo>/.aidc/blocklist.conf` MUST be merged with the global blocklist at proxy startup. Projects can only **add** blocks, never remove them. | P0 | plan-2026-05-21 |
| NET-10 | The proxy stack MUST live outside the dev container (separate Docker compose stack) so that processes inside the dev container cannot reconfigure or bypass it. | P0 | brief §4 |
| NET-10a | **Correction (2026-09-05).** NET-10 was only half-implemented until v1.3.0: the proxy stack did live outside the dev container, but nothing *forced* traffic through it. `HTTP_PROXY` is advisory — `env -u HTTP_PROXY curl https://example.com` returned 200 and produced no entry in `access.log`, so the blocklist did not apply and the policy sidecar could not taint on it. NET-14 supplies the missing half. | P0 | conversation-2026-09-05 |
| NET-11 | If the refresher cannot reach feed sources, the previous (last-good) blocklist MUST continue serving. Refresher failure MUST NOT block proxy operation. | P0 | plan-2026-05-21 |
| NET-12 | The refresher MUST fetch feeds from a hard-coded list of upstream URLs baked into the refresher image; it MUST NOT accept feed URLs from runtime configuration. | P1 | plan-2026-05-21 |
| NET-14 | The session bridge MUST be a Docker `internal` network by default, so no NAT exists for it and the dev container has NO route to the internet except through squid, which is dual-homed onto a separate egress network. Enforcement MUST NOT depend on anything inside the dev container: it is `--privileged` for DinD and can flush any rule it can see. Only `squid`, `refresher` (threat feeds) and `policy` (taint webhook) may join the egress network; `dev` and `audit` MUST NOT. An `egress: direct` escape hatch MUST remain for sessions needing reachability an attached network cannot provide, and MUST say plainly that it disables enforcement. | P0 | conversation-2026-09-05 |
| NET-13 | A session MUST be able to attach its **dev container only** to named, existing Docker **bridge** networks, so it can reach another stack's services (database, queue, cache) by container name. The proxy sidecars MUST NOT be attached. `host`, `none`, and Docker's default `bridge` MUST be refused. Every attachment MUST pin gateway priority so that `aidc-<session>-net` remains the default route — otherwise an attached network silently captures all of the session's egress, squid-proxied traffic included. A session with no attachment MUST render a compose file identical to one produced before this requirement existed. | P1 | conversation-2026-09-05 |

---

## CLI — `aidc` command surface

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| CLI-01 | The CLI is invoked as `aidc <subcommand> [args]`. | P0 | brief §6, plan-2026-05-21 |
| CLI-02 | The CLI is implemented as a bash dispatcher that sources subcommand scripts. No host runtime dependencies beyond bash, Docker CLI, and Docker Compose. | P0 | plan-2026-05-21 |
| CLI-03 | `aidc create <name> [--profile P] [--repo PATH]` MUST build and start the dev container plus the proxy stack as a coupled unit. | P0 | brief §5, §6 |
| CLI-04 | `aidc attach <name>` MUST attach to the dev container's tmux session via `docker exec -it`, allowing the operator to observe, interrupt, and take over the running Claude session interactively. (Absorbed RMT-02.) | P0 | brief §5 |
| CLI-05 | `aidc kill <name>` MUST tear down both the dev container and the associated proxy stack. | P0 | brief §5 |
| CLI-06 | `aidc list` MUST list all running aidc sessions. | P0 | derived |
| CLI-07 | `aidc status [<name>]` MUST report health of dev container and proxy stack components, plus the taint flag. | P0 | plan-2026-05-21 |
| CLI-08 | `aidc logs <name> [--component dev\|squid\|refresher\|policy\|audit]` MUST tail logs for the named component. | P1 | derived |
| CLI-09 | `aidc refresh <name>` MUST force an immediate blocklist refresh for the named session. | P1 | plan-2026-05-21 |
| CLI-10 | `aidc config [global\|<name>]` MUST show or edit configuration (global or per-session). | P1 | plan-2026-05-21 |
| CLI-11 | Configuration is read from two sources, with per-project overriding global: `~/.config/aidc/config.yaml` (global) and `<repo>/.aidc/config.yaml` (per-project). | P0 | plan-2026-05-21 |
| CLI-12 | Container and stack components are named with a stable scheme: `aidc-<session>-<role>` (e.g., `aidc-foo-dev`, `aidc-foo-squid`). | P0 | plan-2026-05-21 |
| CLI-13 | `aidc create` MUST accept `--port HOST:CONTAINER` (or `--port N` shorthand for `N:N`), repeatable, and the merged set of CLI flags + `<repo>/.aidc/config.yaml` `ports:` list MUST be published from the dev container to the host. Conflicting host ports between sessions MUST fail at create time with the underlying docker error surfaced. | P0 | conversation-2026-05-22 |
| CLI-14 | `aidc proxy <session> add <HOST:CONTAINER\|N>`, `aidc proxy <session> rm <PORT>`, `aidc proxy <session> ls`, and `aidc proxy <session> clear` MUST manage adhoc host-to-container port forwards for a running session without restarting the dev container. Forwards MUST NOT persist across `aidc restart` or `aidc kill`. | P0 | conversation-2026-05-22 |
| CLI-15 | `aidc status <session>` MUST list all currently active port forwards (both declared via CLI-13 and adhoc via CLI-14) so users can see what's reachable from the host. | P0 | conversation-2026-05-22 |
| CLI-16 | `aidc rebuild` MUST rebuild all `aidc/*:${AIDC_VERSION_TAG}` images (squid, refresher, policy, audit, dev-base, forwarder, mcp) without touching any running session. Equivalent to invoking `docker build` for each image's Dockerfile + context. | P0 | conversation-2026-05-23 |
| CLI-17 | `aidc upgrade <session>` MUST stop and recreate ONLY the dev container of the named session against the current `aidc/dev-base:${AIDC_VERSION_TAG}` image, preserving the proxy stack, the dev-home volume, the workspace bind mount, the per-project Claude memory mount, the audit dir, and the pyenv-versions volume. Adhoc port forwards (CLI-14) MUST be removed (re-add explicitly post-upgrade). Declared ports (CLI-13) MUST survive. Pre-flight MUST warn the operator that any in-flight claude conversation is interrupted, and MUST prompt for y/N (override with `--yes`). | P0 | conversation-2026-05-23 |
| CLI-18 | `aidc create` MUST honor a per-repo `container_only_paths:` list in `<repo>/.aidc/config.yaml` AND a workspace-level `container_only_paths:` list at `<workspace>/.aidc/config.yaml` when `--workspace` is in use. Each list entry is a path (supporting glob patterns like `packages/*/node_modules`) resolved relative to the workspace root. For each resolved path, `aidc create` MUST mount a session-scoped Docker named volume on top of that path inside the dev container so the container sees its own empty directory while the host's same-named directory remains untouched and invisible from inside the container. The host's directory MAY contain a different-platform venv / node_modules / target / etc.; the overlay isolates the container's filesystem at that path from the host's. | P0 | conversation-2026-05-23 |
| CLI-19 | Container-only-path volumes (CLI-18) MUST be session-scoped (named `aidc-sovl-<session>-<path-slug>`); `aidc kill` MUST remove them. `aidc create` against the same repo a second time gets a fresh empty overlay (and thus a fresh `uv sync` / `npm install` / `cargo build` cost). | P0 | conversation-2026-05-23 |
| CLI-20 | `aidc clean-env <session>` MUST remove all overlay volumes for the named session. `aidc clean-env --project <path>` MUST remove all overlay volumes whose name encodes the named project path, regardless of session. Both forms list volumes before deletion and prompt for y/N (override with `--yes`). | P1 | conversation-2026-05-23 |
| CLI-21 | On macOS, `aidc` MUST run a host-side `aidc-auth-bridge` daemon that polls the macOS Keychain (`Claude Code-credentials` entry) and synchronizes any change into the per-session bridged `${AUDIT_DIR}/.claude-credentials.json` files. This closes the gap where a host `claude /login` (e.g. after Anthropic revokes refresh tokens) leaves in-container Claude installs stuck on the rejected old token. On Linux/WSL2 the daemon is a no-op (the host's credentials file is bind-mounted directly, so updates propagate automatically). | P0 | conversation-2026-05-23 |
| CLI-22 | The auth bridge daemon MUST follow the same single-global-instance-per-host architectural pattern as `aidc mcp`, with `aidc auth-bridge start\|stop\|status\|logs\|restart` subcommands. Implementation is a host-side process (not a Docker container) because macOS Keychain is not reachable from inside a container. | P0 | conversation-2026-05-23 |
| CLI-23 | The auth bridge daemon's lifecycle MUST be managed implicitly by other `aidc` commands: `aidc create` and `aidc mcp start` MUST ensure the daemon is running (idempotent start). `aidc kill` and `aidc mcp stop` MUST stop the daemon when no aidc-managed containers remain on the host. An explicit `aidc auth-bridge stop` by the user MUST be respected — the daemon stays stopped until something else triggers a start (next create, next mcp start, or explicit `auth-bridge start`). | P0 | conversation-2026-05-23 |
| CLI-24 | `aidc network <session> add\|rm\|ls` MUST attach / detach / list foreign bridge networks on a **running** session, without recreating it. Attachments made this way survive `aidc restart` (the endpoint is dev-container state, so there is nothing to sweep) but are lost on `aidc upgrade` and `aidc kill`. `ls` MUST distinguish declared attachments from adhoc ones so the persistence difference is visible. Detaching the session's own network MUST be refused. | P1 | conversation-2026-09-05 |
| CLI-25 | `aidc create --network <net>` (repeatable) and a `networks:` config list MUST declare attachments that survive restart, upgrade, and recreate. The two sources MERGE (unlike `--dns`, which overrides) and dedupe first-wins. Every named network MUST be validated **before** any image build, so a typo costs a message rather than a full `dev-base` build. If `docker compose` is too old to understand `gw_priority`, create MUST fail with that reason rather than render a file whose gateway pin would be silently dropped. | P1 | conversation-2026-09-05 |
| CLI-26 | `aidc update [--check] [--version vX.Y.Z]` MUST update the CLI itself by the method that installed this copy — re-run the latest release's `install.sh` for an installer layout (`~/.local/share/aidc/aidc-<version>`), `brew upgrade <formula>` for a Homebrew keg (naming the installed formula, `aidc` or `aidc@X.Y`), `git pull --ff-only` for a checkout — and MUST refuse an unrecognised layout rather than guess. `--check` MUST report installed vs latest and change nothing. It MUST NOT rebuild images; it MUST point the operator at `aidc rebuild` then `aidc upgrade <session>`. | P1 | conversation-2026-09-10 |

---

## RMT — Remote control (retired)

*This section is retired. Remote control is the MCP control plane (see `MCP — Control plane`, MCP-01..MCP-19). The two local-interactive requirements were relocated; all rows below are historical tombstones.*

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| RMT-01 | Relocated to CTR-12 (the long-lived tmux session is container substrate, not remote control). | — | — |
| RMT-02 | Absorbed into CLI-04 (interactive attach: observe, interrupt, take over). | — | — |
| RMT-03 | Replaced by MCP-01..MCP-14 (control plane is MCP, not bespoke HTTP). | — | — |
| RMT-04 | Replaced by MCP-12 (isolation: MCP server unreachable from dev containers). | — | — |

---

## MCP — Control plane (Saoirse / external AI orchestration)

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| MCP-01 | aidc MUST expose an MCP server (`aidc-mcp`) that AI orchestrators can connect to. | P0 | plan-2026-05-22 |
| MCP-02 | The server MUST be a single global instance per host (not per-session). It manages all sessions by name. | P0 | plan-2026-05-22 |
| MCP-03 | The server MUST run as a Docker container with lifecycle commands `aidc mcp start \| stop \| status \| logs \| token rotate`. | P0 | plan-2026-05-22 |
| MCP-04 | Transport MUST be MCP streaming HTTP (not stdio, not SSE-only). | P0 | plan-2026-05-22 |
| MCP-05 | Authentication MUST use a single bearer token. Token is stored at `~/.config/aidc/mcp-token` with mode 0600. | P0 | plan-2026-05-22 |
| MCP-06 | The server MUST auto-generate a token on first `aidc mcp start` if absent. `aidc mcp token rotate` MUST invalidate the prior token and restart the server. | P0 | plan-2026-05-22 |
| MCP-07 | Long-running tools (`session_create`, `session_invoke`) MUST emit MCP progress notifications during execution. | P0 | plan-2026-05-22 |
| MCP-08 | The server MUST expose the documented tool surface (session_create/list/status/kill/exec, session_invoke, file_get/put, audit_get, taint_mark). | P0 | docs/design-08-mcp-control.md |
| MCP-09 | The server MUST expose the documented resource URIs (`aidc://sessions`, `aidc://sessions/{name}/status`, `aidc://sessions/{name}/audit`, `aidc://sessions/{name}/audit/{file}`, `aidc://config`) and push resource-update notifications on change for the live ones. | P0 | docs/design-08-mcp-control.md |
| MCP-10 | The server MUST bind to a configurable host interface address (`mcp.bind_address` in `~/.config/aidc/config.yaml`). Default `127.0.0.1`. | P0 | plan-2026-05-22 |
| MCP-11 | The server MUST refuse to start if `mcp.bind_address` does not match any interface on the host. | P0 | plan-2026-05-22 |
| MCP-12 | Dev containers MUST NOT be able to reach `aidc-mcp` (separate Docker network, no shared volumes). | P0 | plan-2026-05-22 |
| MCP-13 | Tool implementations MUST shell out to the `aidc` CLI rather than reimplement session management. | P0 | plan-2026-05-22 |
| MCP-14 | All authenticated and unauthenticated requests MUST be logged to `~/aidc-mcp-audit/access.log` (separate from per-session audit dirs). | P1 | plan-2026-05-22 |
| MCP-15 | The shared-session callback path (the watcher behind `session_send` / `session_run` / `session_watch`) MUST derive the response content it delivers to the orchestrator from Claude Code's native per-session JSONL transcript (`~/.claude/projects/<encoded-repo>/*.jsonl`) — the same transcript that interactive `claude` and headless `claude --print` already share via `--continue`. It MUST NOT derive delivered content by scraping the tmux pane (`tmux capture-pane`). | P0 | conversation-2026-06-08 |
| MCP-16 | Completion of an assistant turn MUST be detected from transcript structure (a fully-written assistant message in the JSONL), NOT from a terminal-idle heuristic. The "pane unchanged for N seconds" idle detection (`_wait_for_idle`, `_IDLE_STABLE_SECS`) and ANSI-stripping delta extraction (`_extract_delta`, `_strip_ansi`) MUST be retired from the delivery path. | P1 | conversation-2026-06-08 |
| MCP-17 | Delivery MUST be exactly-once per assistant turn. The watcher MUST persist a durable per-`(session, conversation_id)` high-water mark of the last delivered transcript position, and that mark MUST survive dev-container restart, `aidc restart`, `aidc upgrade`, and `aidc-mcp` restart. A `--continue` redraw or any container restart MUST NOT cause re-delivery of an already-delivered turn. Delivery MUST be **forward-only**: on the first watch of a `(session, conversation_id)`, the watcher MUST baseline the high-water mark to the current end of the transcript and deliver only turns that complete afterward — it MUST NOT replay pre-existing conversation history. (Eliminates the restart double-ping and the history-replay flood.) | P0 | conversation-2026-06-08 |
| MCP-18 | A failed delivery (connection error, timeout, or non-2xx response) MUST NOT advance the high-water mark. The affected turn MUST be retried on a bounded schedule until confirmed delivered or abandoned with a logged terminal failure. A response MUST NOT be silently lost on transient orchestrator/bridge unavailability. | P0 | conversation-2026-06-08 |
| MCP-19 | Every delivery attempt MUST be recorded in the MCP audit log with outcome, HTTP status (when applicable), elapsed time, payload size, and — on failure — the exception type and a non-empty representation. | P1 | conversation-2026-06-08 |
| MCP-20 | No exposed MCP tool may be named with "claude". Session interaction tools use a `session_*` namespace (`session_send`, `session_run`, `session_invoke`, `session_invoke_async`, `session_watch`, `session_unwatch`). | P0 | conversation-2026-06-09 |
| MCP-21 | The session-interaction tool descriptions MUST surface the set of sessions that currently have an open webhook (an active watcher), refreshed as that set changes (with a `tools/list_changed` notification), so an orchestrating LLM can choose a target session without remembering or rediscovering it. | P1 | conversation-2026-06-09 |
| MCP-22 | Tool descriptions and parameters MUST be written for reliable selection by smaller/cheaper orchestrating models (Haiku-, DeepSeek-class). Each session-interaction tool's description MUST state WHEN to call it (trigger-first) and disambiguate it from its siblings (`session_invoke` / `session_invoke_async` / `session_send` / `session_run`). Every parameter MUST carry a description, and `conversation_id` MUST be marked auto-injected / do-not-set. (Note: a smaller model reliably *calling* a tool also depends on the orchestrator's `tool_choice` setting — e.g. DeepSeek `tool_choice="auto"` is documented to under-trigger; wording mitigates but does not replace it.) | P1 | conversation-2026-06-09 |
| MCP-23 | A reply delivered over the webhook MUST let the orchestrator tell whose prompt it answers. A prompt a person typed into the session's tmux pane (indistinguishable in the transcript from one the MCP pasted) MUST be prepended to the delivered content with a note that it came from the terminal, and the payload MUST carry `prompt_origin` (`terminal` / `orchestrator` / `""`). Lines Claude Code writes on the user's behalf (hook feedback, task notifications, auto-continues, interrupt markers, wrapped local-command and bash-mode lines) MUST NOT be attributed to the person. Attribution MUST NOT weaken exactly-once delivery (MCP-17). | P1 | conversation-2026-09-11 |

---

## SEC — Safety model and taint

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| SEC-01 | The safety model MUST document mitigations for each named threat: host file modification, remote git push, `curl evil.sh \| bash`, host Docker compromise, and persistent in-image malware. | P0 | brief safety model |
| SEC-02 | Tainted state MUST be persisted to a shared volume location written by the policy sidecar. | P0 | plan-2026-05-21 |
| SEC-03 | Taint detection MUST trigger on any malware-list (URLhaus, ThreatFox, HaGeZi-TIF) hit in Squid's `access.log`. | P0 | plan-2026-05-21 |
| SEC-04 | State-actor TLD hits MUST be logged. By default they do not trigger taint, but this is configurable per devcontainer. | P0 | plan-2026-05-21 |
| SEC-05 | Taint response MUST be configurable per devcontainer with three modes: `log` (flag only), `notify` (flag + alert), `freeze` (flag + `docker pause` on dev container). | P0 | plan-2026-05-21 |
| SEC-06 | Once tainted, a container MUST NOT be "cleaned" or rehabilitated. The only recovery path is `aidc kill` followed by `aidc create`. | P0 | plan-2026-05-21 |
| SEC-07 | The audit aggregator MUST capture sufficient data (Squid access log, shell history, Claude session transcript) to allow post-hoc forensic review of a taint event. | P0 | plan-2026-05-21 |
| SEC-08 | The default taint response in the absence of any config MUST be `freeze` (pause the dev container on a malware-blocklist hit). Notify and log remain available via config. | P0 | conversation-2026-05-22 |

---

## CI — Continuous integration

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| CI-01 | A GitHub Actions workflow MUST run `make smoke` on every pull request targeting `main` and on every push to `main`. Failure MUST block merge (branch protection enforced separately by the repo admin). | P0 | conversation-2026-05-22 |
| CI-02 | The smoke job MUST run on `ubuntu-latest`. macOS runners do NOT support Docker and MUST NOT be used. | P0 | conversation-2026-05-22 |
| CI-03 | The CI workflow MUST cache Docker layers across runs (GitHub Actions cache via the `type=gha` builder cache) so that re-runs on unchanged Dockerfiles complete in <5 minutes. First runs on a fresh cache may take longer. | P0 | conversation-2026-05-22 |
| CI-04 | A `lint` job MUST run `shellcheck` against `scripts/` and the proxy sidecar `*.sh` files on every PR. Lint failures surface as PR-check warnings but do NOT block merge — shellcheck advice is advisory. False positives are exempted via per-line `# shellcheck disable=SCxxxx` comments; real issues get fixed. | P1 | conversation-2026-05-22 |
| CI-05 | The CI workflow MUST NOT publish artifacts, push images, or modify any external repo. It is read-only against the world. (Release engineering lives in a separate workflow gated on tags — see REL section.) | P0 | conversation-2026-05-22 |

---

## REL — Release engineering and distribution

| ID | Requirement | Priority | Source |
|----|-------------|----------|--------|
| REL-01 | Local `aidc/*` image tags MUST be versioned with the CLI version (e.g. `aidc/dev-base:v0.1.0`), NOT a single shared `:local` tag, so that `brew upgrade aidc` and a subsequent `aidc create` rebuilds against the new Dockerfile rather than reusing a stale image. | P0 | conversation-2026-05-22 |
| REL-02 | The CLI version MUST be sourced from a single `VERSION` file at the repo root; `scripts/aidc` MUST read it once at dispatcher init and expose it as `AIDC_VERSION`. | P0 | conversation-2026-05-22 |
| REL-03 | Tagging the repo with `v*` MUST trigger a GitHub Actions release workflow that gates on `make smoke` passing, generates a release tarball, and creates a GitHub Release with the tarball attached. | P0 | conversation-2026-05-22 |
| REL-04 | The release tarball MUST contain everything needed to run aidc from a clean checkout: `scripts/`, `proxy/`, `.devcontainer/`, `mcp/`, `docs/`, `Makefile`, `LICENSE`, `README.md`, `VERSION`. It MUST exclude `tests/scratch/`, `.git/`, audit data, and any other developer-only artifacts. | P0 | conversation-2026-05-22 |
| REL-05 | A separate `pacepace/homebrew-aidc` repo MUST host the Homebrew tap formula (`Formula/aidc.rb`). The tap repo's only purpose is to host the formula; no source code lives there. | P0 | conversation-2026-05-22 |
| REL-06 | The release workflow MUST update the tap's formula with the new version and tarball sha256 on every successful tag-triggered release. Updates MUST use a deploy key or fine-scoped PAT, never a long-lived account token. | P0 | conversation-2026-05-22 |
| REL-07 | The Homebrew formula MUST install the CLI scripts + image build contexts (`proxy/`, `.devcontainer/`) under `prefix/libexec/` (NO extra `aidc/` nesting; `libexec.install Dir["*"]` drops the tarball's top-level entries directly into libexec) and symlink `scripts/aidc` into `prefix/bin/`. It MUST declare runtime deps: `jq`, `gettext` (for `envsubst`). Docker is documented in `caveats`, not declared as `depends_on`, because Homebrew's `docker` formula does not provide a daemon. | P0 | conversation-2026-05-22 |
| REL-08 | Docker images MUST NOT be pre-built or pushed to any registry. Every aidc install builds images locally on first `aidc create`. This is a deliberate choice: zero registry maintenance, hermetic builds, and an audience (advanced AI devs with Claude Max subscriptions) that tolerates a 10-15 minute first-run build. | P0 | conversation-2026-05-22 |
