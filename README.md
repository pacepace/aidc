# aidc

A disposable, isolated dev container for running Claude Code in `--dangerously-skip-permissions` ("yolo") mode. Claude can do whatever it wants in here. The host can't be reached.

## What's enforced

- **Sessions hold no way to GitHub.** No SSH keys. No GitHub tokens. No GitHub CLI (a session's `gh` is aidc's stand-in). Pre-push hook hard-fails any push attempt. The container has full local git — branches, commits, rebases, stashes. With no git container nothing leaves; with one set up, a session's commits reach GitHub only as requests it pushes by fixed rules (in `ask` mode only after you approve; in `rules` mode at once): see [The git container](#the-git-container-pushes-and-prs-for-your-sessions).
- **Network egress is enforced.** The session bridge is a Docker `internal` network — no NAT, so there is no route out except through the Squid sidecar. Blocklist (URLhaus + HaGeZi-TIF, refreshed every 6h), state-actor TLD policy, Quad9 upstream. Not just `HTTP_PROXY`: a privileged process that strips the proxy vars and adds its own route still gets `Network is unreachable`.
- **Docker is isolated.** DinD inside the sandbox. The host Docker daemon is unreachable. Claude can build and run images; they live and die with the session.
- **The MCP control plane is off limits.** A session's Squid denies the `aidc mcp` server's bind address and port (from `mcp.bind_address` / `mcp.port` when the session is created), so a sandboxed agent cannot reach the server that drives every session, even with a stolen token. Sessions created before this change get the rule on `aidc kill` + `aidc create`. That rule is the whole enforcement, so it holds for a session whose traffic goes through its Squid: one created with `--egress direct`, or attached to another network with `--network`, can route around it — as those options already warn at create time.
- **Compromise is detected and recovered.** A policy sidecar tails the proxy log. A malware-list hit writes a taint flag, optionally pauses the container. Recovery is `aidc kill` + `aidc create`, not "clean up."
- **Everything is audited.** Squid access log, shell history, Claude session transcript, policy events — all preserved on host after `aidc kill`.

## What's bridged from your host

- Per-project memory (`~/.claude/projects/<encoded>/`) — your conversations and memory follow the repo, read-write, the same directory the host uses.
- Per-project scratchpad (`/tmp/claude-<uid>/<encoded>/`) — the working files that go with those conversations (`scratchpad/` and `tasks/`), read-write at the identical path on both sides, so a session popped out to the host and back still finds them. Only this repo's subdirectory is bridged, never the whole scratchpad root — and it is a live read-write host path by design, since a one-way copy could not carry work back *in*. Skipped when your host uid isn't the container's `vscode` (1000), which currently includes macOS. See [tearing down](#tearing-down) for what stays behind.
- `settings.json` — theme, model, env vars, plugins, hooks: **copied** into the session when it is created, not shared live. That file can carry hooks your host Claude Code runs, so a session must never be able to write it. A preference you change inside a session stays there; one you change on the host reaches sessions created afterwards. The status-line script `~/.claude/statusline-command.sh`, if your settings name it, is bridged read-only so the same line shows inside, with that session's own context, cost and limits.
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

`--port N` shorthand publishes `localhost:N` → `dev:N`. `--port H:C` lets you remap. Repeatable. You can also list them in your `~/.config/aidc/config.yaml` (a repo's `.aidc/config.yaml` needs `--trust-repo-config` for this; see [Config](#config)):

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
# or in ~/.config/aidc/config.yaml (a repo's .aidc/config.yaml needs --trust-repo-config)
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

### Reaching a database on another network (ZeroTier, VPN, LAN)

A proxied session has no route out, and squid only carries HTTP. When the session needs a
postgres, a redis or an SSH host that **the host** can reach — over ZeroTier, a VPN, the
office LAN — name that one destination:

```yaml
# ~/.config/aidc/config.yaml
egress_tcp:
  - db.internal.example:5432
  - cache.internal.example:6379
```

```bash
aidc create api --egress-tcp db.internal.example:5432     # same thing, per session
aidc egress api add db.internal.example:5432              # a session that's already running
aidc egress api ls
aidc egress api rm db.internal.example:5432
```

Inside the session nothing changes about how you connect:

```bash
psql "postgresql://app@db.internal.example:5432/app?sslmode=require"
```

Each destination gets a small relay (`aidc/forwarder`, socat) that answers to that name on
the session network and forwards to that one address and port. The name is resolved **on
the host** when the relay is made, so overlay and split-horizon DNS work; if the address
changes later, `rm` and `add` it again (or recreate). TLS is end to end — the relay never
sees inside it, so `sslmode=verify-full` checks the real hostname as usual (if your server's
certificate names that host). Every connection is logged to a file named after the host and port (e.g. `egress-db-internal-example-5432.log`) in
the session's audit dir. A bare IP works too; the session then reaches it by the relay's
name, which `aidc egress <s> ls` shows.

| | `aidc restart` | `aidc upgrade` | `aidc kill` |
|---|---|---|---|
| declared (`--egress-tcp` / `egress_tcp:`) | survives | survives | removed; comes back on `create` |
| live (`aidc egress … add`) | survives | survives | removed |

What it opens, precisely: that address, those ports, nothing else — much narrower than
`--network` or `--egress direct`. That traffic doesn't pass through squid, so the blocklist
and taint detection don't see it; the connection log is the record. The relay refuses
aidc-mcp's own address and port, and loopback.

`egress_tcp` is operator-only: a repo's own `.aidc/config.yaml` can't open it (see
[Config](#config)). A session created by an orchestrator through the MCP's `session_create`
never trusts the repo's config either; the names in your own `egress_tcp:` are then resolved
inside the aidc-mcp container, which uses the host's upstream DNS servers but not a per-link
resolver (systemd-resolved routing a ZeroTier domain, say). Such a name may not resolve
there, or may resolve to a different, public address than it does on the host. Check with
`aidc egress <s> ls` (it shows the address each relay forwards to), and list the IP address
instead when they differ. For a clustered database whose driver discovers other nodes (YugabyteDB
smart drivers, Cassandra), list each node, or turn discovery off (`load_balance=false`).

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

Only `squid`, `refresher` (fetches threat feeds), `policy` (POSTs the taint
webhook) and the one-target socat sidecars (port forwards, TCP egress relays) sit
on the egress network. `dev` and `audit` never do.

**Two deliberate ways out**, both visible:

```bash
aidc create myproj --egress direct     # restores the old NATed bridge
```

```yaml
egress: direct                          # or in ~/.config/aidc/config.yaml
```

Use it only when a session needs reachability nothing narrower provides. To reach a
few services over ZeroTier/Tailscale/a VPN, name them with `egress_tcp` instead (above):
it keeps enforcement on. `aidc create` tells you plainly when enforcement is off.

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
aidc create myproj --dns 10.0.0.1 --dns 9.9.9.9

# Or in ~/.config/aidc/config.yaml (a repo's .aidc/config.yaml needs --trust-repo-config):
dns_servers:
  - 10.0.0.1     # a private-network DNS
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

### New package versions wait 14 days

Inside a session, `pip install`, `uv add` / `uv pip install` and `npm install` skip any version
published in the last 14 days. Most malicious releases, from a hijacked maintainer account or a
typosquat, are found and pulled within days, so waiting two weeks keeps them out. It's a
system-wide default, so a project's own `uv.toml`, `pip.conf` or `.npmrc` still sets its own
rule. When you really need something newer, override it for that one command:

```bash
uv add somepkg --exclude-newer false
pip install --uploaded-prior-to "$(date -u +%FT%TZ)" somepkg
npm install --min-release-age=0 somepkg
```

Claude Code is exempt and stays current, and so are the Go, Rust and Python toolchains and
Ubuntu's own packages (holding back security updates there would do more harm than good).
The rule binds pip 25.3 or newer; the image checks every interpreter's pip at build. One gap:
a venv created with Ubuntu's own `/usr/bin/python3 -m venv` starts with pip 25.1, which ignores
the setting, until you `pip install -U pip` inside it. `python -m venv` (the pyenv Python on
PATH) and `uv venv` are covered.

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

**Browser checks.** The image carries the system libraries and fonts Playwright's Chromium
needs, so `npx playwright install chromium` (cached in `~/.cache/ms-playwright`) is all a
project has to do; no `sudo npx playwright install-deps`. Firefox and WebKit need more, which
`sudo npx playwright install-deps firefox` (or `webkit`) adds in the session.

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

### Kept audit trails

Every session's audit trail outlives it: a folder under `audit_dir` on Docker, a kept volume
claim on Kubernetes. They add up, so:

```bash
aidc audit list                       # every kept trail, both backends: session, created, killed,
                                      # tainted, size, state
aidc audit trim --older-than 30d      # trails created more than 30 days ago (12h, 2w also work)
aidc audit trim eng-ai-bot            # all of a session's trails, or one by the name list shows
aidc audit trim --older-than 30d --dry-run
```

`trim` lists exactly what will go and asks first (`--yes` to skip the question; with no
terminal and no `--yes` it removes nothing). It never removes the trail of a session that still
exists, running or stopped. On Kubernetes it sets the claim's volume to `Delete` before
deleting the claim, so the provisioner removes the volume and its data even on a storage class
that retains volumes; it waits for that and says so, or names the volume if the provisioner
keeps it. A released audit volume whose claim was deleted some other way is listed and trimmed
the same way. `--backend docker|kubernetes` limits either command to one backend.

Every aidc command warns when the kept trails total more than 100 MB (`AIDC_AUDIT_WARN_BYTES`
changes the threshold). On Docker that is one `du` of the audit dir. On Kubernetes the check
runs only during cluster commands and reads a total cached for a day
(`~/.cache/aidc/audit-k8s-size`), from the sizes `aidc kill` records on each kept claim; a
running session's trail, or one killed before aidc recorded sizes, counts as unknown.

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

From the other machine, point an MCP client at `http://<your-overlay-ip>:7878/mcp` with that bearer. It gets the tool surface (`session_invoke`, `file_get`, `session_send`, etc.; `session_create` only if you enabled it). See [`docs/done/design-08-mcp-control.md`](docs/done/design-08-mcp-control.md).

### Driving sessions from an orchestrator

The MCP server is built for an orchestrating agent that runs somewhere else on your overlay network and talks to sessions over MCP. **The rule: give a session's agent any task, and anything long, with `session_send`** (edits, builds, test suites, dev processes, multi-step work). `session_invoke` and `session_invoke_async` are only for short, single-shot questions ("what does function X return?"). Replies that take a while are delivered by POSTing to a callback endpoint the orchestrator exposes.

**The callback contract:**

1. The orchestrator injects the current `conversation_id` into its agent's system prompt; the agent passes it through and never has to invent it.
2. The agent calls `session_send(name, prompt)` (below), or `session_invoke_async(name, prompt, conversation_id)` for a short single-shot question. The call returns immediately.
3. aidc hands the prompt to the session's agent (`session_send`), or runs the question in the named session container (`session_invoke_async` runs a fresh `aidc-claude --print <prompt>`, stopped after 30 minutes).
4. When it finishes, aidc POSTs to `{callback_url}/api/v1/internal/callback/{conversation_id}` with `Authorization: Bearer <mcp-token>`. `session_invoke_async` sends `{"content": "...", "ok": true|false}`; the session watcher behind `session_send` sends `{"content", "ok", "source": "agent_watch", "session": "<name>", "prompt_origin": "terminal"|"person"|"orchestrator"|"", "interrupted": true|false}` (plus `"sent_by"` with a `"person"` origin: whoever `session_send`'s `sent_by` named) (plus `"prompts"`, the `session_send` prompts the reply answers as `{prompt_id, sent_by, conversation_id}` in paste order, and `"pasted_at"`, when their batch was pasted) (plus `"speaker": "human"|"agent"` with `metallm.send_speaker: true`). Two callbacks are notices rather than replies and carry `error_code`: `"prompt_dropped"` for a queued prompt whose session was removed before it could be pasted, and `"prompt_waiting"`, sent once, for a queued prompt that has waited 10 minutes (every field is described in [design 10, D5](docs/design-10-turn-state-and-sending.md#d5-the-callback-payload-contract)).
5. The orchestrator verifies the bearer, injects the content into the conversation, and wakes its agent.

**Setup (one time):**

**Step 1 — Tell aidc where the callback endpoint lives.** Add `metallm.callback_url` to `~/.config/aidc/config.yaml` (the key keeps its historical name):

```yaml
metallm:
  callback_url: https://orchestrator.example.com
```

**Step 2 — Make sure the orchestrator can reach `aidc mcp`,** and aidc can reach the callback URL. Check `aidc mcp status` for the bind address and port.

**Step 3 — Register aidc as an MCP server in the orchestrator:** URL `http://<your-overlay-ip>:7878/mcp`, bearer from `aidc mcp token show`. aidc reads the same token from `~/.config/aidc/mcp-token` at call time when it POSTs back, so `aidc mcp token rotate` takes effect on the next callback.

**Step 4 — Verify.** Ask the orchestrator's agent to call `session_invoke_async` with a short question on a running session. It confirms the launch; when the task finishes the result appears in the conversation without further prompting.

**Notes:**
- Use `session_status` before calling `session_invoke_async` to confirm the target session is alive.
- If `metallm.callback_url` is not set, the tool returns an error immediately rather than silently losing the result.
- A short question whose answer is needed inline is `session_invoke` (synchronous). Anything that may take more than about a minute, or that edits files or runs builds or tests, is `session_send`, not either invoke.
- One headless run at a time per session: while a `session_invoke` or `session_invoke_async` runs, another is refused with `error_code: "invoke_busy"`, naming the run (its `run_id`, `started_at`, `prompt`, `pid`). `session_status` lists runs under `headless_runs`, including one left from before an `aidc-mcp` restart (`orphan: true`), and `session_interrupt` with `target: "headless"` stops one with every process it started.
- A headless run is a fresh Claude: it never resumes the session's conversation. `session_invoke` has no time limit. If the caller cancels the call (`notifications/cancelled`), closes its MCP session, or drops the connection, the run is stopped in the container. A client that abandons a call without any of those cannot be seen; the one-at-a-time rule and `headless_runs` cover that case.

### Interactive sessions from an orchestrator

`session_invoke` and `session_invoke_async` run a fresh `claude --print` — headless, no UI, result as text — and are only for short, single-shot questions. For any task, anything long, work that builds a conversation thread, needs visible progress, or spans many turns: use the session tools.

**`session_send(name, prompt)`** — injects a prompt into an interactive Claude session in the named container and returns immediately with a send-confirmation. An orchestrator relaying a person's message sets `sent_by` to name them, and the reply comes back with `prompt_origin: "person"` and that `sent_by`. Claude's reply is delivered back into the orchestrator's conversation by the transcript watcher (auto-started on first send) when the turn finishes — non-blocking, so the conversation stays free while the session works. The reply arrives via the webhook callback, not in the tool's return value. For a multi-turn sequence, call it repeatedly. If the session cannot take it yet (Claude is mid-turn, someone has unsent text in Claude's input box, Claude is restarting, or the paste did not land), the prompt is queued and pasted as soon as the session is free; the return says `queued` with a `waiting_reason` and what the agent is busy with (`working_on`, `started_by`, `turn_started_at`, `last_activity`, as `session_status` shows them), and `session_status` lists what is still waiting and why. Every prompt waiting when the session frees up goes in together, as one message in send order with `" [next message] "` between prompts, whoever sent each; the one reply names them all (`prompts`) with `pasted_at`. Every return carries a stable `prompt_id`; `session_queue_cancel(name, prompt_id)` takes back that prompt alone while it waits and answers `cancelled`, `already_pasted` (too late, with `pasted_at`) or `unknown`. With `deliver: "join"` a prompt for the work in flight is pasted into the running turn instead (`status: "joined_turn"`); its answer comes in that turn's reply. A join never jumps a prompt already queued, and holds off whenever a plain send would (a dialog, unsent text, Claude not running), saying why in `join_declined`. A queued prompt is never dropped: it survives an `aidc-mcp` restart and leaves the queue only when pasted or when the session is killed or re-created (then it is kept in the MCP's dead-letter dir, and the conversation that sent it gets a `prompt_dropped` callback). The webhook survives a restart too: a reply written while the MCP was down still arrives, once. While a prompt waits on someone's unsent text, the session's tmux status line says so.

**`session_resend(name)`** — re-delivers the session's most recent reply when a callback was lost (a dropped POST, an MCP restart at the wrong moment). It refuses to re-post a reply the orchestrator already acknowledged and returns the content to the caller instead, so it can never inject a duplicate.

**`session_watch(name)`** — call this first to open the callback webhook for a session: every reply the session's Claude produces is then delivered into this conversation automatically. `session_send` auto-starts it on first use, so you only need it explicitly to watch a session you aren't actively sending to yet. Safe to re-call.

**`session_unwatch(name)`** — closes the webhook for a session, stopping automatic delivery. No-op if nothing is being watched.

**`session_mcp_set(name, server, path, bearer)`** — gives the session's Claude one HTTP MCP server on the orchestrator's own API, so the Claude working in the session can read from the orchestrator or ask it things. `path` is a path on that API; aidc adds the host from `metallm.callback_url`, so a caller cannot point a session anywhere else. `bearer` is the token Claude sends. Call it again whenever the token changes.

- **Where it goes.** Under the session's Claude config directory, on its dev-home volume: the token in `aidc-mcp/<server>.bearer` (mode 0600), a helper `aidc-mcp/headers.sh` that prints it as an `Authorization` header, and one entry in `.claude.json` (`mcpServers.<server>`: the URL and the helper, no token). The entry is written into the installed state, after the first start has installed the seed that strips every `mcpServers` entry; a session still starting is refused (`session_not_ready`).
- **When Claude can use it.** Claude Code loads its MCP servers when it starts and runs the helper on each connection and again when a call is refused (401 or 403). So a new token for a server the session already has needs no restart, and a server the session did not have is there after Claude restarts (`aidc restart <name>`). The result says which (`needs_claude_restart`).
- **Restart, resume, upgrade.** The files are on the dev-home volume, so `aidc restart`, `aidc upgrade` and Claude's own `--continue` keep them. `aidc kill` removes them with the volume: hand the server again to a session created anew.
- **The token.** It reaches the container on the exec's standard input. It is never in a command line, the audit log, a tool result, the session's audit directory or `.claude.json`. Anything that can run commands in the session (`session_exec`, `file_get`, the session's own Claude) can read the file, as it must for Claude to use it.

`session_create` takes the same three as `mcp_server`, `mcp_path` and `mcp_bearer`, and hands the server once the session is created.

`session_send` drives the interactive Claude in the `claude` window (window 0) — the same session `aidc attach` drops you into. Attach to watch in real-time:

```bash
aidc attach <name>
# Ctrl-b 0 → claude window
```

You can type into that window yourself. A reply to a prompt you typed there is still delivered to the orchestrator, prefixed with your prompt and a note that it came from the terminal rather than from `session_send`, so the orchestrator is never left guessing where an instruction came from.

**Which tool to use:**

| Tool | Use when |
|---|---|
| `session_send` | Any task and anything long: edits, builds, tests, multi-step work, back-and-forth with the session's agent — non-blocking; reply delivered into the conversation via webhook. Call repeatedly for a multi-turn sequence |
| `session_invoke` | A short, single-shot question whose answer is needed inline ("what does function X return?") — blocks until done; a fresh Claude, one at a time per session |
| `session_invoke_async` | A short, single-shot question whose answer can land in the conversation later; a fresh Claude, one at a time per session |

### The git container: pushes and PRs for your sessions

Sessions cannot push. One git container per user does, on either backend: it holds your GitHub
login where its own agent cannot read it, and pushes and opens and merges pull requests by its
rules (fast-forward pushes only, never a force push, never `main`, `master`, `develop` or the
default branch directly, merge commits only, no commit or PR text with AI attribution).
Design: [docs/design-12-kubernetes.md](docs/design-12-kubernetes.md), "Git".

**Set it up once.** `aidc git setup` starts it: on Docker the container `aidc-git-dev`, beside
your sessions, behind its own proxy that reaches public addresses only (DNS through Quad9); in a
cluster a `git` Deployment in your namespace (after `aidc user add`). Safe to run again: it
restarts the container on the current image, and keeps its volumes (your login, its home, its
private copies of your repos), and registers your sessions with it (below, **Modes**). `aidc git
status` says whether it runs and is logged in, the git mode, how many requests wait (or why its
request watcher cannot take any), and how much its copies take ("unknown" when it cannot be
asked). `aidc git log` shows what it changed on GitHub (pushes, pull requests opened, merged and
commented on, branches deleted, protections added: when, which repo, branch or PR and commit,
and which session request asked, or "direct"), from a log kept where its agent cannot change it,
capped so it never piles up.

**Log it in.** `aidc git login` logs it in to GitHub as you: a one-time code you approve in your
browser. Commits it makes show as you (your GitHub name; your public email, else GitHub's
noreply address for your account), unsigned. `aidc git logout` removes the login. Its agent (a
Claude of its own) needs its own Claude login: `aidc git attach` opens its terminal (window
`claude`, and a `shell`), where you log in as in any session; detach with Ctrl-b d. With
`aidc claude-token` set, the Docker git container takes that token as sessions do.

**Add your repos.** Only repos you add reach GitHub through it:

- On Docker it works on your own working copies, never its own clones: `aidc repo add <path>`
  takes a working copy under your home whose origin is `https://github.com/<owner>/<name>` (to
  keep pushing over SSH yourself, set the SSH URL as the push URL only). The container sees it
  at the same path; nothing in it is re-owned or locked. `aidc repo remove <path|owner/name>`
  forgets it and never deletes your working copy.
- In a cluster `aidc repo add <github-url|owner/name> [--path P]` clones it onto your disk
  (default `/home/<user>/<name>`), an ordinary working copy shared by your sessions;
  `aidc repo remove` deletes the working copy only with `--delete-working-copy`, and not while
  anything in it is unpushed unless `--even-unpushed` is given too.

`aidc repo list` shows them. Behind each, the git container keeps a private copy of the GitHub
repo that only the user holding the login runs git in; commits move between the two as git
bundles, so nothing a session writes in a working copy (hooks, config, filters) runs where the
login is. Which repos are added is a list only `aidc repo add|remove` on your machine writes,
read-only in the git container (in a cluster the `git-repos` ConfigMap, on Docker
`~/.config/aidc/git-added/repos`): the git agent cannot add a repo itself, and gitctl acts on
no other. A repo added before that list existed is taken over by running `aidc repo add` again
(after `aidc git setup`).

**How sessions ask.** A session works in its own worktree and branch inside an added repo
(`git -C <repo> worktree add -b <branch> <repo>/<folder> origin/HEAD`; on Docker the worktree
must be inside the working copy, and the session must have been created after `aidc git setup`,
or created again, to get the request folder). Its `gh` is aidc's stand-in, not GitHub's CLI:
`gh pr create` (pushing the branch first), `gh aidc push`, `gh pr merge` (merge commit only),
`gh pr view`, `gh pr list` and `gh pr status` become requests the git container answers, so
`/prawduct:pr` and plain `gh pr create` work unchanged. `git push` in a session fails and says to
use `gh pr create`. The stand-in waits up to a minute for the answer, then prints
"requested; waiting for approval" with the request's id (`gh aidc request <id>` reads it later);
when the git container has not taken the request at all it says so instead, and fails.

**Approve or deny.** In the git mode `ask` (the default) each push, PR and merge waits for you:
`aidc git requests` lists them, `aidc git requests <id>` shows one (session, repo, branch and
the commit you approve, or for a merge the pull request's head commit: a branch or pull request
that moves after the request is refused), `aidc git approve
<id>` runs it, `aidc git deny <id> [why]` refuses it and the session reads why. Your git agent
also asks you about each waiting request with its question tool: answer in its terminal
(`aidc attach git`). Reads (`gh pr view`, `gh pr list`) run at once. Requests and results are
deleted after 30 days.

**Modes.** `rules` lets gitctl's rules decide at once. Your mode is `git.mode` in the global
config on Docker and `kubernetes.git_mode` in a cluster (applied by `aidc git setup`).
`aidc git mode` lists it and the sessions given their own. Per session, both ways: `aidc git mode
<session> rules` lets one session's requests run at once while your mode is `ask`; `aidc git mode
<session> ask` holds one session's requests for your approval while your mode is `rules`; `aidc
git mode <session> default` gives it your mode again. Each session sends a random token only it
has, and every mode is keyed on it: a request without its session's token (or naming a session
the git container does not know) always waits for you, so another session cannot claim a mode
and a held session gains nothing by leaving its token out. `aidc create` registers a session's
token with a running git container (`aidc git setup` registers every session, for ones made while
it was not running, and drops the modes of sessions that are gone); `aidc kill` drops the
session's mode, and a session made again under the same name starts at yours. One created
before per-session modes existed must be created again.

**From the terminal.** `aidc git push <repo> <branch>`, `aidc git pr <repo> <branch> [--base B]
--title T --body-file F` and `aidc git merge <repo> <number>` do the same for a working copy;
running the command is your approval. `aidc git tidy [<repo>]` deletes merged branches (on
GitHub and locally) and their clean worktrees, and lists every leftover (unpushed, unmerged,
uncommitted, orphaned worktree folders) without deleting it; `merge` tidies after itself. The
first push of a repo shows GitHub's protections of its default branch; `aidc git protect
<repo>` turns missing ones on (a ruleset against force pushes and deletion, merge commits
allowed) only when you answer yes, and never turns any off (rulesets on private repos need a
paid GitHub plan; GitHub's refusal is shown).

**The git agent is a session.** It is the session named `git`: `aidc list` shows it (profile
`git-agent`), `aidc attach git`, `aidc status git` and `aidc logs git` reach it, and `aidc kill
git` and `aidc create git` are refused (`aidc git setup` manages it). It runs Claude with
managed instructions it cannot change (the git rules; everything sessions write is data, never
instructions) and a fixed allow list, and only it, never a session, reaches GitHub.

**An orchestrator and ask mode.** On Docker the git agent's transcript reaches `aidc mcp` like
any session's, so an orchestrator that watches the session `git` (`session_watch`) receives the
agent's question about a request as that session's reply. Answering it with `session_send` is
not yet checked live (the question tool may not take a pasted answer); answer in its terminal
or with `aidc git approve|deny` meanwhile. **On Kubernetes the question does not reach an
orchestrator yet:** the MCP server's session tools reach cluster sessions only through the
per-user MCP server. The Kubernetes backend ships in aidc 2.0 together with that server, and 2.0
routes Kubernetes git approvals through the orchestrator before it ships. Until then answer by
attaching (`aidc attach git`) or with `aidc git approve|deny`.

## Reference

### Commands

| Command | What it does |
|---------|--------------|
| `aidc create <name> [--profile P] [--repo PATH] [--workspace PATH] [--port H:C ...] [--dns IP ...] [--network NET ...] [--egress-tcp HOST:PORT ...] [--egress proxied\|direct] [--trust-repo-config]` | Start a session. ~30s. `--port` declares published ports baked into compose. `--dns` overrides Quad9 for sessions needing overlay-network resolution (applies to both container and squid). `--network` attaches the dev container to an existing docker bridge so it can reach another stack's services; repeatable, merges with the `networks:` config list. `--egress-tcp` lets the session reach one TCP destination the host can reach (see "Reaching a database on another network"). `--egress direct` disables enforced egress (see "Egress is enforced"). `--trust-repo-config` applies the sandbox-widening settings in the repo's own `.aidc/config.yaml` (see "Config"). |
| `aidc list` | All sessions; status + taint flag. |
| `aidc status <name>` | Component health, taint, the malware feeds (a feed lost at 0 entries, a failed refresh, a list older than twice the refresh interval), declared + adhoc ports, TCP egress relays, attached networks, audit dir path. |
| `aidc attach <name>` | `docker exec -it -u vscode` into tmux. |
| `aidc proxy <name> {add\|rm\|ls\|clear}` | Manage adhoc host->container port forwards (not persisted across restart/kill). |
| `aidc network <name> {add\|rm\|ls}` | Attach a running session's dev container to another docker bridge so it can reach that stack's services by name. Survives `restart`, not `upgrade`/`kill` — use `create --network` for permanent. Widens the sandbox: see "Reaching another stack's services". |
| `aidc egress <name> {add\|rm\|ls\|clear}` | Let a running session reach a TCP `host:port` the host can reach (a database over ZeroTier). Survives `restart` and `upgrade`, not `kill`; use `create --egress-tcp` or `egress_tcp:` for permanent. |
| `aidc logs <name> [--component dev\|squid\|refresher\|policy\|audit]` | Tail logs. |
| `aidc refresh <name>` | Force a blocklist refresh. |
| `aidc restart <name>` | Restart the dev container in place from its existing image (proxy stack stays; adhoc forwards do NOT survive). Does **not** pick up image rebuilds — use `upgrade` for that. |
| `aidc rebuild` | Rebuild all `aidc/*` images at the current VERSION, always fetching the current Claude Code release into `dev-base`. Does NOT touch any running session. Pair with `aidc upgrade`. |
| `aidc update [--check]` | Update the aidc CLI itself to the latest release, by whichever method installed it (install.sh, Homebrew, or git). Then `aidc rebuild`. |
| `aidc upgrade <name> [--yes]` | Swap a session's dev container onto the freshly-rebuilt image. Proxy stack untouched; adhoc forwards removed. Recreates from the compose file rendered at create time, kept in `~/.local/state/aidc/sessions/<name>.yaml`. A session made before v1.9.9 kept it in `/tmp`: if that copy is still there it is moved into place and the upgrade goes ahead; if a reboot or a cleanup took it, the session can only be recreated. Does **not** replace the session's Claude Code: it lives in the dev-home volume and auto-updates in-session. Prompts before interrupting an in-flight claude conversation. |
| `aidc kill <name>` | Tear down. Audit dir preserved. Overlay volumes (container-only paths) removed. |
| `aidc audit list` / `aidc audit trim [--older-than <age>] [<name>...] [--yes] [--dry-run]` | List kept audit trails (both backends), or remove old or named ones; never a running session's (see "Kept audit trails"). |
| `aidc clean-env <name>\|--project <path>` | Remove stray container-only-path overlay volumes after a botched session. |
| `aidc claude-token <verb>` | Manage a long-lived OAuth token that new sessions use instead of logging in (`setup\|show\|clear`). Inference-only: Remote Control needs an in-session `/login` instead. See "Claude auth" above. |
| `aidc config [global\|<name>]` | Show / edit config. |
| `aidc mcp <verb>` | Control-plane lifecycle (see "Driving from another machine" above). |
| `aidc k8s {check\|setup\|build}` | Check the cluster in the `kubernetes:` config, make its registry, build aidc's images in it (see "Kubernetes backend"). |
| `aidc user {add\|creds\|remove} <name>` | Kubernetes backend: make a user's namespace, disk and own credentials (a kubeconfig), renew or revoke the kubeconfig, remove the user and everything made for them (see "Admins and users"). |
| `aidc git {setup\|login\|logout\|attach\|status\|push\|pr\|merge\|tidy\|protect\|requests\|approve\|deny\|mode}` | Your git container (Docker or Kubernetes), which holds your GitHub login and pushes, opens and merges PRs for you and your sessions (see "The git container"). |
| `aidc repo {add\|list\|remove}` | The repos your git container works on: your own working copies on Docker, clones on your disk in a cluster. |

### Profiles

`--profile` picks which language toolchain the dev container ships with: `python` · `node` · `go` · `rust` · `multi` (all of them; default).

### What's running per session

- `aidc-<name>-dev`        — your dev container (Ubuntu, vscode user, claude installed, DinD)
- `aidc-<name>-squid`      — forward proxy
- `aidc-<name>-refresher`  — keeps the blocklist fresh
- `aidc-<name>-policy`     — tails the proxy log, manages taint state
- `aidc-<name>-audit`      — collects forensics into a host-visible dir

## Kubernetes backend

Being built (design: [docs/design-12-kubernetes.md](docs/design-12-kubernetes.md)). Sessions
will also run on a Kubernetes cluster, with the same commands. What works today:

- `aidc k8s check`: whether the cluster can run sessions, what is missing, and what the
  credentials in use may and may not do (read-only).
- `aidc k8s setup`: the `<prefix>-system` namespace and a private image registry in it, on the
  session node(s). Pulls go through the node's loopback (no node configuration); only aidc's
  builder pods can push.
- `aidc k8s build [--force] [--only ROLE]`: builds aidc's images in the cluster and pushes them
  there; nothing goes to a public registry. The builder pod is privileged for the length of a
  build (the squid image's base owns files as a UID no user namespace has), takes no
  connections, and is deleted afterwards. Its namespace is the only one aidc labels to allow
  privileged pods.
- `aidc user add|creds|remove <name>`: a user's namespace, disk and own credentials; see
  "Admins and users" below.
- `aidc git ...` and `aidc repo ...`: the user's git container, the one thing in the cluster
  that pushes and opens PRs (sessions cannot); see "The git container" above. In a cluster it
  runs in your namespace with its request folder at `/home/<user>/.aidc/git-requests` on your
  disk; its agent runs as its own user (uid 2000, in the sessions' group), unprivileged, with
  no API token, and reaches public addresses and Quad9 DNS only (NetworkPolicy); nothing may
  connect to it. `aidc repo add` clones onto your disk; sessions make group-writable files
  (umask 002), so the git container can tidy their worktrees. `aidc git status` warns when its
  private copies take more than `git_storage_warn` (default 1Gi).
- `aidc create <name> --backend kubernetes [--profile P] [--cpu N] [--memory Q] [--cpu-limit N]
  [--memory-limit Q]`: a session in the cluster, in your namespace. `--cpu`/`--memory` are what
  it is guaranteed, the limits what it may use when the node has room (defaults below); a request
  above the configured limit raises the limit with it, and `aidc status` shows the size. It sees your whole disk and starts at the current directory's place on it: a path
  under your home directory is the same path under `/home/<user>` on the disk, so a repo's
  Claude history has the same name everywhere. There is no `--repo` here: a session that works
  on an added repo makes its own worktree and branch in it
  (`git -C <repo> worktree add -b <branch> <repo>/<folder> origin/HEAD`). Its commits carry your
  git identity (this machine's `git config user.name` and `user.email`), as on Docker. A top-level
  `backend: kubernetes` in the config makes the cluster the default for `create`, and for `aidc
  git` and `aidc repo` alike (one rule: `--backend`, else that line, else Docker; a
  `kubernetes:` block alone changes nothing).
- `aidc attach | status | logs | kill <name>` find the session where it lives (the cluster is
  asked first when one is configured); `aidc list` shows both backends. `kill` keeps the
  session's audit volume (`<name>-audit-<UTC time>`, named for when it was made, so a later
  session of the same name never writes over it) and your disk, and records the trail's size on
  the claim. Kept audit volumes add up: `aidc audit list` and `aidc audit trim` (see "Kept audit
  trails") remove them with their volume and data, whatever the storage class retains.
- `aidc restart <name>` gives the session a new dev pod on the same image, `aidc upgrade <name>`
  one on this aidc version's image (after `aidc k8s build`), and `aidc refresh <name>` re-pulls
  its malware feeds. The proxy pod, the session home and your disk are kept, so Claude resumes
  its conversation (`--continue`).
- Not yet on this backend: `--port`, `--dns`, `--network`, `--egress-tcp`, `--gpu`, and
  `proxy`, `network`, `egress` (each says so). A tainted session is recorded and reported, not
  frozen.

Inside a cluster session the lockdown is the Docker backend's, enforced by NetworkPolicy outside
the pod: the dev pod reaches only its own Squid and has no DNS at all (Squid resolves names), so
tools must use the proxy settings in the environment; Docker runs inside without privileged mode
(Sysbox), and an inner container reaches the internet only when handed `$HTTPS_PROXY`.

The cluster needs a runtime that runs Docker inside a pod without privileged mode (Sysbox,
measured with Sysbox 0.7.2 on k3s 1.35) and a storage class whose volumes several pods on one
node can mount at once (each user's repos live on one volume). Everything about the cluster is
configuration, in the global config:

```yaml
kubernetes:
  context: my-cluster            # kubeconfig context (default: kubectl's current one)
  kubeconfig: ~/.kube/config     # optional
  user: alice                    # whose sessions (default: your login name)
  namespace_prefix: aidc         # every namespace aidc makes starts with this
  runtime_class: sysbox-runc     # runs session pods
  storage_class: shared-zfs      # the user's disk (required)
  node_selector: {}              # added to session pods
  tolerations: []                # added to session pods
  session_storage_class: ""      # each session's home and taint-flag volumes, deleted with it
                                 # (default: storage_class); like storage_class, several pods on
                                 # a node must be able to mount one volume (the audit sidecar reads
                                 # the home), and it should delete its volumes when released
  git_store_size: 10Gi           # the git container's private copies of GitHub repos (on the
                                 # session class: a cache of GitHub)
  git_storage_warn: 1Gi          # `aidc git status` warns when those copies take more
  git_mode: ask                  # sessions' push/PR/merge requests: ask (you approve each) or
                                 # rules (gitctl's rules decide); applied by `aidc git setup`
  cpu: 2                         # guaranteed per session; cpu_limit / memory_limit: the ceiling
  memory: 8Gi                    #   (default 16 and 32Gi)
  user_disk_size: 100Gi          # each user's disk
  registry:                      # where aidc keeps the images it builds in the cluster
    port: 5000                   # push: registry.<prefix>-system.svc.cluster.local:<port>
                                 # pull: localhost:<port> (the node, through a loopback-only host port)
    storage_class: ""            # the registry's volume (default: storage_class)
    size: 50Gi
```

With one registry on one node's loopback, only that node pulls: keep sessions on it (the node
selector and the runtime class's own scheduling do).

### Admins and users

An **admin** (credentials that may make namespaces, such as the cluster's own kubeconfig) runs
`aidc k8s setup`, `aidc k8s build` and, for each person:

```bash
aidc user add alice            # namespace aidc-u-alice, her disk, her credentials, a kubeconfig
aidc user creds alice          # a new kubeconfig (renew; --revoke kills every earlier token)
aidc user remove alice         # alice and everything made for her: refuses while she has sessions
```

`aidc user add` labels the namespace Pod Security `baseline` (no privileged pods, host paths,
host network or extra capabilities; aidc's sessions, Sysbox included, and git container pass)
and makes a ServiceAccount for the user whose Role may do exactly what aidc's commands do in
that namespace and nothing in any other, a second one for the user's MCP server (sessions
only), and read-only cluster-wide rights for the runtime class, storage class, nodes and
volumes, plus setting her own volumes to Delete (`aidc audit trim`; an admission policy refuses
any other volume change). It writes her kubeconfig (the cluster's server and CA, a token valid
`user_token_ttl`, default 720h) to `~/.config/aidc/users/alice.kubeconfig`, mode 0600, and
prints the path, never the token (`aidc user creds alice --token` prints only the token, when
you want it). Hand the file over privately. `aidc user remove` sets the user's volumes to
Delete, so her disk and kept audit trails go with their data, and asks for her name first
unless `--yes`.

A **user** puts the file somewhere private and points their config at it:

```yaml
backend: kubernetes
kubernetes:
  kubeconfig: ~/.kube/aidc-alice.kubeconfig
  user: alice
  storage_class: shared-zfs      # and the rest of the cluster's block, as the admin has it
  # user_token_ttl: 720h         # lifetime of the kubeconfig aidc user creds issues
```

With it they run every session, git and repo command and `aidc audit`; `aidc k8s check` says
what their credentials may and may not do (the registry is the admin's, so it shows as a note).
They renew before the token expires with `aidc user creds alice` (their kubeconfig is renewed
in place). A user may bring their own kubeconfig instead; the check says what it lacks.

**testament** (optional): when your config names its repo, sessions on both backends come with
testament (a distributed test runner) at its newest release. The repo is private for now, so this is opt-in and uses
your own SSH key: aidc reads the newest `vX.Y.Z` tag with `git ls-remote`, clones that tag
shallowly, builds a wheel with `uv build` (cached in `~/.cache/aidc/testament/<tag>`), and puts
only the wheel into the dev image (`aidc rebuild`, `aidc k8s build --force`) and into a running
session (`aidc upgrade`). Without the setting, without access or without `uv`, it says so in one
line and the build or upgrade goes on.

```yaml
testament:
  repo: git@github.com:<owner>/<repo>.git   # an ssh URL your key can fetch
```

`aidc k8s check` reads it and checks, without changing anything, that kubectl reaches the
cluster, the runtime class and storage class exist, a ready node can take session pods, and you
may create pods in your namespace (and, for `setup` and `user add`, namespaces). Needs `kubectl`
and `yq`.

## Config

Two layers, both YAML:

```
~/.config/aidc/config.yaml           # global
<workspace>/.aidc/config.yaml        # workspace (if --workspace given; overrides global)
<repo>/.aidc/config.yaml             # per-project (overrides workspace + global)
```

Scalars override (later wins); lists concatenate-and-dedupe across all three.

**A repo's or workspace's config can tighten the sandbox, never loosen it.** Those files are
writable from inside the session they configure, so an agent could otherwise edit one and get
a wider sandbox on the next `aidc create`. From a workspace or repo config, aidc applies
`profile`, `claude_mode`, `claude_resume`, additions to `state_actor_tlds`,
`blocklist_additions` and `container_only_paths`, and anything that only tightens
(`egress: proxied`, `share_*: false`, `tld_taints: true`, a stricter `taint_response`).
Anything that widens it (`egress: direct`, `networks`, `ports`, `egress_tcp`, `dns_servers`,
`audit_dir`, `notify_webhook`, `share_*: true`, a softer `taint_response`) is listed by
`aidc create` and ignored. Put those settings in your own `~/.config/aidc/config.yaml` or pass
them as flags. If you wrote the repo's file yourself and want it applied as written, use
`aidc create … --trust-repo-config`. `aidc config` shows what was set aside.

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
  - 10.0.0.1                       #   e.g. a private-network DNS
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

egress_tcp:                           # TCP destinations the session may reach through a relay,
                                      # without a route out: a database over ZeroTier, a VPN, the LAN.
                                      # Additive; same as `aidc create --egress-tcp`. Resolved on the
                                      # host at create. See "Reaching a database on another network".
  - db.internal.example:5432

notify_webhook: ""                    # POSTed to on taint events

# Only relevant if you use the git container on Docker (`aidc git setup`; a cluster's are
# kubernetes.git_mode and kubernetes.git_storage_warn):
git:
  mode: ask                           # sessions' push/PR/merge requests: ask (you approve each) or
                                      # rules (gitctl's rules decide); applied by `aidc git setup`
  storage_warn: 1Gi                   # `aidc git status` warns when its private copies take more

# Only relevant if you use `aidc mcp`:
mcp:
  bind_address: 127.0.0.1             # bind the MCP server here. Change to e.g. your ZeroTier/Tailscale IP for remote access.
  port: 7878
  session_create: false               # offer the session_create tool. Creating a session means reading a repo and
                                      # writing Claude's per-project memory on the HOST, so turning this on mounts
                                      # your home dir into the aidc-mcp container. Off, the tool is not offered at all.

# Only relevant if an orchestrator drives sessions over MCP (the key keeps its historical name):
metallm:
  callback_url: ""                    # base URL of the orchestrator's callback endpoint (e.g. https://orchestrator.example.com).
                                      # Required for session_invoke_async / session_send to deliver results back.
                                      # See "Driving sessions from an orchestrator" above.
  send_speaker: false                 # add "speaker": "human"|"agent" to session_send replies. Leave off until the
                                      # orchestrator records human turns instead of dropping them (design 10 D4).
```

## Taint

A session is "tainted" the moment the proxy blocks a request to a known-malware domain, or to any subdomain of one. The policy sidecar handles this. The malware list refreshes every 6 hours and takes effect without restarting the proxy, so connections never drop for it.

Three responses (`taint_response` config):

- `log` — write the flag, no other action. Quietest.
- `notify` — flag + notify (webhook + a FIFO under the audit dir).
- `freeze` (default) — flag + `docker pause` on the dev container. The agent stops mid-step; you investigate via `aidc status` / `aidc logs` / audit dir before deciding whether to kill+recreate. Strictest, and the right stance for a sandbox.

Once tainted, **kill and recreate** is the only path. The session does not get "cleaned." Your committed work in the host repo is unaffected.

## MCP control plane (reference)

**Compatibility:** the MCP interface follows aidc's version number. A release can add tools,
fields or default-off settings; removing or changing an existing tool, field, callback or error
code waits for a major version (v2.0) and is announced in the CHANGELOG. An orchestrator built
against 1.x keeps working through every 1.x upgrade.

When `aidc mcp` is running, an external AI orchestrator on your overlay network gets:

**Tools** (function calls): `session_create` (only with `mcp.session_create: true`, see the config above), `session_list`, `session_status`, `session_transcript`, `session_exec`, `session_invoke`, `session_invoke_async`, `session_send`, `session_watch`, `session_unwatch`, `session_resend`, `session_interrupt`, `session_queue_cancel`, `session_mcp_set`, `repo_status`, `repo_diff`, `repo_log`, `repo_branches`, `file_get`, `file_list`, `file_search`, `file_put`, `audit_get`. (`session_kill` and `session_run` exist as CLI/wrapper capabilities but are deliberately not exposed over MCP; `taint_mark` is gone: the policy sidecar writes the taint flag.) Every tool's name, description and input schema is published in [`mcp/published-tools.json`](mcp/published-tools.json), generated from the code and held to it by a test.

- **What a session is doing.** `session_status` and each `session_list` record say whether the coding agent is `working`, on what (`working_on`), its `repo` and `branch`, when it last replied, where its replies go, and its taint as a typed field (`tainted: {at, trigger, domain}` or null). `session_transcript` returns its completed turns as prompt and reply text only, never tool calls or their results, with known secret shapes redacted and every part capped.
- **Reading the repository.** `repo_status`, `repo_diff`, `repo_log`, `repo_branches`, `file_list`, `file_search` and `file_get` are read-only and run inside the session's dev container as its user, with fixed argument lists (`--end-of-options` before every ref, the repository's fsmonitor, pager, diff drivers and textconv off), a timeout and a byte cap. Paths stay inside the repository: one outside it, or a symlink pointing out, is refused with `outside_repo`.
- **A tainted session takes no more work.** `session_send`, `session_resend`, `session_invoke`, `session_invoke_async`, `session_exec` and `file_put` refuse it with `error_code: "tainted"`, and a prompt queued before the taint is never pasted (`waiting_reason: session_tainted`).
- **Stopping work.** `session_interrupt` sends Esc to a session whose agent is working and says what it was doing and the state of the working tree; `session_queue_cancel` takes back sent prompts that have not been pasted: by `prompt_id` (the one `session_send` returned), by `position`, or all of them.

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
make smoke        # Docker
make smoke-k8s    # the cluster of your kubernetes: config
```

A few minutes each: a real session (dev + squid + refresher + policy + audit), checked for
isolation (no host docker.sock, no GitHub CLI, no SSH), git asymmetry (push fails, commit
works), DinD, proxy allow/deny, taint detection, the MCP server, and audit survival after kill;
then the git container (setup, a public repo added, a session's requests denied, approved and
run in rules mode, tidy, the git agent as a session). With the git container logged in and
`AIDC_SMOKE_GIT_REPO=<owner/name>` naming a scratch repo you own, also a real push, PR, merge
and tidy there. [tests/smoke/README.md](tests/smoke/README.md) says what each part needs. The
Docker harness writes to `tests/scratch/` (gitignored) and removes what it made.

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
