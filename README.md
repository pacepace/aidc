# aidc

A disposable, isolated dev container for running Claude Code in `--dangerously-skip-permissions` ("yolo") mode. Claude can do whatever it wants in here. The host can't be reached.

## What's enforced

- **Git is local-only.** No SSH keys. No GitHub tokens. No `gh` CLI. Pre-push hook hard-fails any push attempt. The container has full local git — branches, commits, rebases, stashes — but nothing leaves.
- **Network egress is enforced.** The session bridge is a Docker `internal` network — no NAT, so there is no route out except through the Squid sidecar. Blocklist (URLhaus + ThreatFox + HaGeZi-TIF, refreshed every 6h), state-actor TLD policy, Quad9 upstream. Not just `HTTP_PROXY`: a privileged process that strips the proxy vars and adds its own route still gets `Network is unreachable`.
- **Docker is isolated.** DinD inside the sandbox. The host Docker daemon is unreachable. Claude can build and run images; they live and die with the session.
- **Compromise is detected and recovered.** A policy sidecar tails the proxy log. A malware-list hit writes a taint flag, optionally pauses the container. Recovery is `aidc kill` + `aidc create`, not "clean up."
- **Everything is audited.** Squid access log, shell history, Claude session transcript, policy events — all preserved on host after `aidc kill`.

## What's bridged from your host

- Per-project memory (`~/.claude/projects/<encoded>/`) — your conversations and memory follow the repo, read-write, the same directory the host uses.
- Per-project scratchpad (`/tmp/claude-<uid>/<encoded>/`) — the working files that go with those conversations (`scratchpad/` and `tasks/`), read-write, at the identical path on both sides. Pop a session out of the container and resume it on the host and it still has its own files; pop it back in and they are still there. Only this repo's subdirectory is bridged, never the whole scratchpad root — that holds every other project's. This is a live read-write host path the sandboxed agent can write to, chosen over a one-way copy because a copy cannot carry work back *in*; it is the same trade the repo mount already makes, bounded to one directory. Bridged only when your host uid matches the container's `vscode` (1000) — otherwise it is skipped with a message, because these directories are mode 0700 and the mount would land unwritable inside. On macOS, where Docker Desktop remaps bind-mount ownership, that check is more conservative than it needs to be and the bridge is currently skipped. Unlike the rest of a session, these directories live on your host: `aidc kill` does not remove them, and a host reboot clears them exactly as it would a host session's. Turn it off with `share_scratchpad: false`.
- `settings.json` — env vars, status line, editor mode.
- Plugins (`~/.claude/plugins/`, read-only) — what you have installed resolves and is enabled inside.
- Onboarding state, seeded once from `~/.claude.json` — theme, output style, and this project's trust and allowed-tools entry, so the first launch goes straight to the login prompt. Your account, API keys, MCP server definitions, and prompt history are never copied.

Claude auth is deliberately **not** bridged. The container owns its Claude config directory and you log in inside it once (or configure a long-lived token). See [Claude auth](#claude-auth--the-container-logs-in-on-its-own).

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

However you installed it, `aidc update` moves the CLI to the latest release the
same way: it re-runs the installer, runs `brew upgrade` on the installed
formula, or fast-forwards the checkout, whichever applies. `aidc update --check` only reports. The CLI
and the images are separate: after an update, `aidc rebuild` bakes images at
the new version, then `aidc upgrade <session>` swaps each running session onto
them.

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
aidc create api --network webapp_default           # attach at create time
```

```yaml
# or in .aidc/config.yaml
networks:
  - webapp_default
```

Repeatable, and CLI **merges** with config (unlike `--dns`, which overrides) — more sources
just means more networks. Everything is validated before any image build, so a typo costs
you a message, not a `dev-base` rebuild.

**Adhoc** (attach a session that's already running, no recreate):

```bash
aidc network api add webapp_default
aidc network api ls                                # marks declared vs adhoc
aidc network api rm webapp_default
```

Then, from inside the session:

```bash
psql -h webapp-postgres-1 -U webapp                # resolves over docker DNS
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

### Egress is enforced, not requested

The session bridge is a Docker **`internal`** network. Docker installs no NAT for
it, so there is no route to the internet at all — squid, dual-homed onto a
separate egress network, is the only way out.

That distinction matters. Before v1.3.0 the proxy was advisory: `HTTP_PROXY`
pointed at squid, but `env -u HTTP_PROXY curl https://example.com` returned 200
and left no trace in `access.log`, so the blocklist didn't apply and taint
detection couldn't see it. The dev container is `--privileged` (it needs DinD),
so any rule *inside* it can be flushed by whatever is running there — enforcement
has to live where the agent can't reach. Now a privileged process that adds its
own default route, enables `ip_forward`, and installs its own `MASQUERADE` still
gets `Network is unreachable`.

Only `squid`, `refresher` (fetches threat feeds) and `policy` (POSTs the taint
webhook) sit on the egress network. `dev` and `audit` never do.

**Two deliberate ways out**, both visible:

```bash
aidc create myproj --egress direct     # restores the old NATed bridge
```

```yaml
egress: direct                          # or in .aidc/config.yaml
```

Use it when a session needs reachability an attached network can't provide —
ZeroTier/Tailscale hosts, direct DNS. `aidc create` tells you plainly that
enforcement is off for that session.

The other is attaching a network (below): it grants whatever that network grants,
and most compose bridges are NATed, so attaching one restores general internet
egress as a side effect. aidc can't prevent that — it doesn't own that network.
Detaching closes it again.

**Existing sessions are not converted.** `aidc upgrade` reuses the compose file rendered
at create time, so a session created before v1.3.0 keeps its NATed bridge — upgraded, but
still bypassable. `aidc status <name>` reports which posture a session is in, and
`aidc upgrade` warns before preserving an unenforced one. Recreate to convert:
`aidc kill <name> && aidc create <name> ...`.

Declared `--port` forwards and `aidc proxy` still work: each becomes a small
dual-homed `aidc/forwarder` sidecar that publishes the host port and reaches dev
across the internal bridge, since an internal network can't publish ports itself.

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

### Claude auth — the container logs in on its own

Each session owns its Claude config directory: `CLAUDE_CONFIG_DIR=/home/vscode/.claude`, on the session's `dev-home` volume, the same layout Anthropic's reference devcontainer uses. Credentials, `.claude.json` and session state live there. Nothing auth-related is bind-mounted from the host.

**Why not share the host's login?** Claude Code replaces `.credentials.json` and `.claude.json` by writing a new file and renaming it into place, on every refresh and every `/login`. Many Claude processes on one host coexist because they share the same *directory*: a write lock serialises refreshes and each process re-reads the file when it changes. A single-file bind mount breaks both halves. After the host's first refresh the container is left holding the old inode ([anthropics/claude-code#18443](https://github.com/anthropics/claude-code/issues/18443)), and the container's own writes fail because you cannot rename over a mount point. That is what made in-container logins expire after a few hours and account switches not stick. Sharing the whole `~/.claude` *directory* would keep the renames working, but it hands the sandboxed container every project's memory and history, and `~/.claude.json` sits at the home root outside any directory that could be shared, so the container gets its own.

**Two ways in. Both are supported; pick per host.**

**1. Log in inside the session (default).** The first launch of a new session shows Claude's login prompt:

```bash
aidc attach my-feature
# window 0: /login  → open the URL, paste the code back
```

That claude.ai session belongs to the container. It refreshes itself on the volume, survives `aidc restart` and `aidc upgrade`, and is discarded by `aidc kill`. Because it is a full login, **Remote Control works**, and the account can differ from the host's: run `/login` again inside the session to switch, for example when one account hits its session limit. The MCP tools (`session_invoke`, `session_send`) use the same login. Nothing you do inside touches the host's own login.

**2. Long-lived token (no login step).** `claude setup-token` mints a one-year token; aidc injects it into every new session as `CLAUDE_CODE_OAUTH_TOKEN`:

```bash
aidc claude-token setup       # one-time: walks you through generating + storing the token
aidc claude-token show        # confirms a token is stored (last-6 chars + mtime)
aidc claude-token clear       # removes it; new sessions log in inside instead
```

Trade-offs: running `claude setup-token` invalidates the host's current login once (`/login` on the host afterwards); the token is **inference-only**, so **Remote Control does not work** in sessions that use it, and `/login` inside such a session is ignored while the token is set; rotate yearly by re-running setup. Billing stays on your subscription. Existing sessions keep whatever they were created with; `aidc kill` + `aidc create` moves one onto the other path.

### Inside the session

`aidc attach <name>` drops you into a `tmux` session named `main` with three windows.

**The three windows:**

| Window | What |
|---|---|
| `0` claude   | `aidc-claude` already running (yolo mode by default, with `--continue` so it resumes the previous conversation). On a brand-new session it is sitting at the login prompt: run `/login` once (see [Claude auth](#claude-auth--the-container-logs-in-on-its-own)). This is also the window an orchestrator's `session_send` tool drives. |
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

Removes every container + volume + network for the session. Two things on the host stay: the audit dir, and — when `share_scratchpad` is on — the bridged scratchpad at `/tmp/claude-<uid>/<encoded>/`, which is the point of bridging it (a session you pop back in later still finds its files). Nothing sweeps those per-session directories, so they accumulate until a host reboot clears `/tmp`; delete the ones you are done with by hand.

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

### Driving sessions from an orchestrator

The MCP server is built for an orchestrating agent that runs somewhere else on your overlay network and talks to sessions over MCP. Tasks that take minutes should not block the orchestrator's request, so two tools finish asynchronously and deliver their result by POSTing to a callback endpoint the orchestrator exposes.

**The callback contract:**

1. The orchestrator injects the current `conversation_id` into its agent's system prompt; the agent passes it through and never has to invent it.
2. The agent calls `session_invoke_async(name, prompt, conversation_id)` (or `session_send`, below). The call returns immediately.
3. aidc runs the task in the named session container (`session_invoke_async` runs `aidc-claude --print <prompt>` with a 30-minute cap).
4. When it finishes, aidc POSTs to `{callback_url}/api/v1/internal/callback/{conversation_id}` with `Authorization: Bearer <mcp-token>`. `session_invoke_async` sends `{"content": "...", "ok": true|false}`; the session watcher behind `session_send` sends `{"content", "ok", "source": "agent_watch", "session": "<name>", "prompt_origin": "terminal"|"orchestrator"|""}`.
5. The orchestrator verifies the bearer, injects the content into the conversation, and wakes its agent.

**Setup (one time):**

**Step 1 — Tell aidc where the callback endpoint lives.** Add `metallm.callback_url` to `~/.config/aidc/config.yaml` (the key keeps its historical name):

```yaml
metallm:
  callback_url: https://orchestrator.example.com
```

**Step 2 — Make sure the orchestrator can reach `aidc mcp`,** and aidc can reach the callback URL. Check `aidc mcp status` for the bind address and port.

**Step 3 — Register aidc as an MCP server in the orchestrator:** URL `http://<your-overlay-ip>:7878/mcp`, bearer from `aidc mcp token show`. aidc reads the same token from `~/.config/aidc/mcp-token` at call time when it POSTs back, so `aidc mcp token rotate` takes effect on the next callback.

**Step 4 — Verify.** Ask the orchestrator's agent to call `session_invoke_async` with a short task on a running session. It confirms the launch; when the task finishes the result appears in the conversation without further prompting.

**Notes:**
- Use `session_status` before calling `session_invoke_async` to confirm the target session is alive.
- If `metallm.callback_url` is not set, the tool returns an error immediately rather than silently losing the result.
- Tasks that finish within the orchestrator's response window are better served by `session_invoke` (synchronous). Use async for anything that might take more than a minute or two.

### Interactive sessions from an orchestrator

`session_invoke` and `session_invoke_async` run `claude --print` — headless, no UI, result as text. For work that builds a conversation thread, needs visible progress, or spans many turns: use the session tools.

**`session_send(name, prompt)`** — injects a prompt into an interactive Claude session in the named container and returns immediately with a send-confirmation. Claude's reply is delivered back into the orchestrator's conversation by the transcript watcher (auto-started on first send) when the turn finishes — non-blocking, so the conversation stays free while the session works. The reply arrives via the webhook callback, not in the tool's return value. For a multi-turn sequence, call it repeatedly. If the session is still mid-turn, the prompt is queued and injected the moment that turn ends (the return says `queued`); nothing is lost and nothing needs re-sending.

**`session_resend(name)`** — re-delivers the session's most recent reply when a callback was lost (a dropped POST, an MCP restart at the wrong moment). It refuses to re-post a reply the orchestrator already acknowledged and returns the content to the caller instead, so it can never inject a duplicate.

**`session_watch(name)`** — call this first to open the callback webhook for a session: every reply the session's Claude produces is then delivered into this conversation automatically. `session_send` auto-starts it on first use, so you only need it explicitly to watch a session you aren't actively sending to yet. Safe to re-call.

**`session_unwatch(name)`** — closes the webhook for a session, stopping automatic delivery. No-op if nothing is being watched.

`session_send` drives the interactive Claude in the `claude` window (window 0) — the same session `aidc attach` drops you into. Attach to watch in real-time:

```bash
aidc attach <name>
# Ctrl-b 0 → claude window
```

You can type into that window yourself. A reply to a prompt you typed there is still delivered to the orchestrator, prefixed with your prompt and a note that it came from the terminal rather than from `session_send`, so the orchestrator is never left guessing where an instruction came from.

**Which tool to use:**

| Tool | Use when |
|---|---|
| `session_invoke` | Short one-off, answer needed inline — blocks until done (no conversation memory) |
| `session_invoke_async` | Headless fire-and-forget (e.g. a scheduled/skill job); result delivered back into the orchestrator's conversation, no conversation memory |
| `session_send` | Live back-and-forth with a session — non-blocking; reply delivered into the conversation via webhook. Call repeatedly for a multi-turn sequence |

## Reference

### Commands

| Command | What it does |
|---------|--------------|
| `aidc create <name> [--profile P] [--repo PATH] [--workspace PATH] [--port H:C ...] [--dns IP ...] [--network NET ...] [--egress proxied\|direct]` | Start a session. ~30s. `--port` declares published ports baked into compose. `--dns` overrides Quad9 for sessions needing overlay-network resolution (applies to both container and squid). `--network` attaches the dev container to an existing docker bridge so it can reach another stack's services; repeatable, merges with the `networks:` config list. `--egress direct` disables enforced egress (see "Egress is enforced"). |
| `aidc list` | All sessions; status + taint flag. |
| `aidc status <name>` | Component health, taint, declared + adhoc ports, attached networks, audit dir path. |
| `aidc attach <name>` | `docker exec -it -u vscode` into tmux. |
| `aidc proxy <name> {add\|rm\|ls\|clear}` | Manage adhoc host->container port forwards (not persisted across restart/kill). |
| `aidc network <name> {add\|rm\|ls}` | Attach a running session's dev container to another docker bridge so it can reach that stack's services by name. Survives `restart`, not `upgrade`/`kill` — use `create --network` for permanent. Widens the sandbox: see "Reaching another stack's services". |
| `aidc logs <name> [--component dev\|squid\|refresher\|policy\|audit]` | Tail logs. |
| `aidc refresh <name>` | Force a blocklist refresh. |
| `aidc restart <name>` | Restart the dev container in place from its existing image (proxy stack stays; adhoc forwards do NOT survive). Does **not** pick up image rebuilds — use `upgrade` for that. |
| `aidc rebuild` | Rebuild all `aidc/*` images at the current VERSION, always fetching the current Claude Code release into `dev-base`. Does NOT touch any running session. Pair with `aidc upgrade`. |
| `aidc update [--check]` | Update the aidc CLI itself to the latest release, by whichever method installed it (install.sh, Homebrew, or git). Then `aidc rebuild`. |
| `aidc upgrade <name> [--yes]` | Swap a session's dev container onto the freshly-rebuilt image. Proxy stack untouched; adhoc forwards removed. Does **not** replace the session's Claude Code: it lives in the dev-home volume and auto-updates in-session. Prompts before interrupting an in-flight claude conversation. |
| `aidc kill <name>` | Tear down. Audit dir preserved. Overlay volumes (container-only paths) removed. |
| `aidc clean-env <name>\|--project <path>` | Remove stray container-only-path overlay volumes after a botched session. |
| `aidc claude-token <verb>` | Manage a long-lived OAuth token that new sessions use instead of logging in (`setup\|show\|clear`). Inference-only: Remote Control needs an in-session `/login` instead. See "Claude auth" above. |
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
claude_mode: yolo                     # yolo (--dangerously-skip-permissions) | safe (= default) |
                                      # default | acceptEdits | auto | bypassPermissions | dontAsk | plan
                                      # (--permission-mode). Non-yolo modes surface approve prompts
                                      # that an orchestrator answers over session_send.
claude_resume: true                   # pass --continue so claude picks up the prior conversation
share_memory: true                    # mount ~/.claude/projects/<encoded>/ into the session
share_scratchpad: true                # bridge /tmp/claude-<uid>/<encoded>/ (scratchpad + tasks) into the session
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

egress: proxied                       # proxied (default) | direct. proxied makes the
                                      # session bridge a Docker `internal` network -- no NAT,
                                      # so the ONLY route out is squid. direct restores the
                                      # pre-v1.3.0 NATed bridge (proxy still configured, but
                                      # nothing stops a process going around it).

networks:                             # foreign docker bridges the dev container attaches to,
                                      # so the session can reach that stack by container name.
                                      # Additive; same as `aidc create --network`.
                                      # WIDENS THE SANDBOX -- everything on an attached network
                                      # is reachable on every port, unproxied and invisible to
                                      # taint detection. See "Reaching another stack's services".
  - webapp_default

notify_webhook: ""                    # POSTed to on taint events

# Only relevant if you use `aidc mcp`:
mcp:
  bind_address: 127.0.0.1             # bind the MCP server here. Change to e.g. your ZeroTier/Tailscale IP for remote access.
  port: 7878

# Only relevant if an orchestrator drives sessions over MCP (the key keeps its historical name):
metallm:
  callback_url: ""                    # base URL of the orchestrator's callback endpoint (e.g. https://orchestrator.example.com).
                                      # Required for session_invoke_async / session_send to deliver results back.
                                      # See "Driving sessions from an orchestrator" above.
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
