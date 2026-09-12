# Changelog

All notable changes to **aidc** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each release also has full notes on the [GitHub releases page](https://github.com/pacepace/aidc/releases).

> Versions prior to 1.0.0 were developed in a private repository. Their entries are
> kept below as the project's development record, but their tags and release pages
> do not exist in the public repo — 1.0.0 is the first public release.

## [Unreleased]

## [1.6.0] - 2026-09-12

### Added
- **A session's scratchpad follows it across the container boundary.** Claude Code keeps
  per-session working files at `/tmp/claude-<uid>/<encoded-repo>/<session-id>/` —
  `scratchpad/` and `tasks/` — and inside a session those lived on the container's
  writable layer, where `aidc upgrade` and `aidc kill` destroyed them. A session moved
  between host and container therefore kept its conversation (which `share_memory` has
  always bridged) and lost the files that went with it. `aidc create` now bind-mounts the
  host's scratchpad dir for the repo at the identical path inside, keyed on the same
  encoded repo path as the memory bridge, so resuming a session on either side finds its
  own files. Toggle with `share_scratchpad: false`.

  Only this repo's subdirectory is bridged — never the whole `/tmp/claude-<uid>` root,
  which holds every other project's scratchpad. The bridge is skipped, with a message,
  when the host uid is not the container's `vscode` (1000): those directories are mode
  0700, so the mount would land unwritable and Claude could not write a scratchpad at
  all. Being bound to `/tmp` on both sides, a bridged scratchpad is exactly as durable as
  a host session's and is cleared by a host reboot.

  Existing sessions do not gain the mount — `aidc upgrade` reuses the compose file
  rendered at create time. Use `aidc kill` + `aidc create` to pick it up.

  The bridged directories live on your host and are not reaped by `aidc kill`. Claiming
  them can never fail a session: both levels sit under world-writable sticky `/tmp`, so a
  path already held by someone else — or by a planted symlink — is refused rather than
  followed, and the session is created without the bridge. On macOS the uid check is more
  conservative than it needs to be, since Docker Desktop remaps bind-mount ownership;
  the bridge is currently skipped there.

## [1.5.1] - 2026-09-11

### Changed
- **The docs and the MCP tool text describe "the orchestrator", not a specific product.**
  The README sections on callback delivery now document the contract itself (endpoint,
  bearer, both payload shapes) for any MCP-capable orchestrator, the examples use neutral
  names, and the tool descriptions and error messages an orchestrating model reads say
  "the orchestrator". The `metallm.callback_url` config key is unchanged and documented
  as keeping its historical name, so no configuration breaks.

## [1.5.0] - 2026-09-11

### Changed
- **The dev container owns its Claude login.** Each session keeps Claude's config
  directory on its own volume (`CLAUDE_CONFIG_DIR=/home/vscode/.claude`, the layout
  Anthropic's reference devcontainer uses) and you `/login` inside it once. The login
  refreshes itself, survives `restart` and `upgrade`, supports Remote Control, and can
  be a different account from the host's — `/login` again inside to switch. The host's
  `.credentials.json` and `~/.claude.json` are no longer bind-mounted: Claude Code
  replaces both files by rename, so a single-file bind mount went stale on the host's
  first refresh (anthropics/claude-code#18443) and could not be written from inside.
  That is why in-container logins expired after a few hours and why `/login` with
  another account never took. Onboarding state (theme, output style, this project's
  trust) is seeded once from the host's `~/.claude.json` without the account, so the
  first launch goes straight to the login prompt; API keys, MCP server definitions
  and prompt history are never copied. Memory, settings and plugins are bridged
  exactly as before. The long-lived token path (`aidc claude-token`) is unchanged
  and still skips the login, at the cost of Remote Control. A session created
  before this version can be upgraded: `aidc upgrade` removes its old host login
  mounts and says so, and its first launch afterwards runs Claude's onboarding and
  then asks for `/login`; `aidc kill` + `aidc create` gives it the seeded start.

### Fixed
- **`aidc upgrade` now actually moves a session onto the new version's image.** It
  recreated the dev container from the compose file rendered at create time, which
  pins the dev image at the tag current back then, so across a version bump the
  container came back on the old image while the command reported the new one. The
  dev image line is now pointed at the current tag before the recreate, and the
  command verifies the recreated container's image id before reporting success.

### Removed
- `aidc auth-bridge` (the macOS Keychain sync daemon), `aidc reauth`, the per-session
  Keychain extraction, and the `share_auth` config key. With nothing bridged there is
  nothing to keep fresh; a session that says "Please run /login" just needs a `/login`.
  A watcher left running by an earlier aidc on macOS is stopped, and its pid, log
  and sentinel files removed, by the next `aidc create` or `aidc kill`.

## [1.4.1] - 2026-09-11

### Fixed
- **A prompt typed straight into a watched session no longer reaches the orchestrator as
  an unexplained reply.** A person attached to the session's tmux window can talk to the
  same Claude the orchestrator drives over `session_send`; the reply came back over the
  webhook with no trace of the prompt, so the orchestrator read it as an answer to whatever
  it had last sent and could not tell where the new instructions came from. In the JSONL
  transcript a pasted prompt and a typed one are identical, so the MCP now keeps a durable,
  bounded record of every prompt it injects itself (`<session>.sent-prompts.json` beside
  the watermarks) and, at delivery, prepends any prompt on the turn that is *not* in that
  record — under a note saying the user typed it at the terminal — so the reply reads in
  context. Slash commands are rendered as `/name args`; hook feedback, task notifications,
  auto-continues, interrupt markers, and any wrapped line (local-command output, `!`
  bash-mode input and output) are never attributed to the person. The callback
  payload gains `prompt_origin` (`terminal` / `orchestrator` / `""`); the exactly-once
  ledger still keys on the bare reply, so replay protection is unchanged.

## [1.4.0] - 2026-09-10

### Added
- **The Homebrew tap updates itself on every release, with no token to rotate.**
  The release workflow pushed rendered formulae with a fine-grained PAT stored under
  a date-stamped secret name that had to be re-issued every few weeks. When the secret
  lapsed, the v1.3.1 release silently skipped the tap and left `install.sh` (which
  verifies downloads against the tap) unable to install it. It now pushes over SSH with
  a write deploy key on the tap repo: never expires, reaches nothing else, revocable
  from that repo's settings. `release/tap-deploy-key.sh` creates or rotates the key
  end to end and prints only the fingerprint; `--status` shows what is installed.
- **`aidc update`** updates the CLI itself, the way `brew upgrade` or `apt upgrade`
  would. It detects how this copy was installed — the release installer under
  `~/.local/share/aidc/`, a Homebrew keg, or a git checkout — and runs the matching
  step: re-fetches the latest release's `install.sh`, runs `brew upgrade` on the
  installed formula (`aidc` or `aidc@X.Y`), or fast-forwards the checkout. `--check` reports the installed and latest versions
  without changing anything; `--version vX.Y.Z` pins a release (installer copies
  only). An already-current copy is left alone; an unrecognised layout refuses
  rather than guessing. The CLI and the images are separate, so the command ends
  by pointing at `aidc rebuild` and `aidc upgrade <session>`.

  This exists because the failure mode is quiet: a stale installed copy rebuilds
  images from its own old tree, and nothing tells you the checkout you just pulled
  is not the `aidc` on your PATH.

## [1.3.1] - 2026-09-10

### Fixed
- **`aidc rebuild` now actually refreshes Claude Code.** The dev-base image bakes
  Claude Code with Anthropic's native installer, but that step was an ordinary cached
  Docker layer with nothing above it changing between releases — so every rebuild
  silently reused the version fetched the first time the layer was built (an image
  rebuilt today still carried the release from a month ago). The install step now
  takes a `CLAUDE_CODE_REFRESH` build arg used purely to invalidate that one layer,
  and `aidc rebuild` passes a fresh value each run. Everything above the step stays
  cached; only the installer re-runs.

  Note that a session's home directory is a named volume seeded from the image only
  on first create, so `aidc upgrade` keeps the session's existing copy of Claude Code.
  Existing sessions pick up new releases through Claude Code's in-session auto-update;
  a fresh `aidc create` starts from the newly baked version.

## [1.3.0] - 2026-09-05

### Fixed
- **Egress is now actually enforced, not merely configured.** The proxy was advisory:
  `HTTP_PROXY` pointed at squid, but the session bridge was an ordinary NATed Docker
  network, so `env -u HTTP_PROXY curl https://example.com` returned **200** and produced
  **no entry in `access.log`** — meaning the blocklist did not apply and the policy
  sidecar could not taint on it. NET-10 claimed processes inside the dev container
  "cannot reconfigure or bypass" the proxy. They could, with four `env -u` flags.

  The session bridge is now a Docker **`internal`** network: Docker installs no
  masquerade rule, so there is no route off it at all. Squid is dual-homed onto a
  separate `egress` network and is the only way out. The fix is topological on purpose —
  the dev container is `--privileged` for DinD, so any rule inside it can be flushed by
  whatever is running there. Verified against a privileged process that stripped the
  proxy vars, added an explicit default route via squid, enabled `ip_forward`, and
  installed its own `MASQUERADE`: every attempt returns `Network is unreachable`, while
  proxied traffic still returns 200 and a blocklisted domain still returns 403.

  Only `squid`, `refresher` (threat feeds) and `policy` (taint webhook) join the egress
  network. `dev` and `audit` never do.

- **`make smoke` no longer passes a sandbox that isn't sandboxing.** Step 7 tested only
  the *proxied* path (`curl -x http://aidc-proxy:3128`), which succeeds just as happily
  when nothing is enforced. It now also asserts that stripping the proxy variables fails,
  that raw TCP to a public IP fails, and that squid is still reachable — so the suite
  cannot go green on the bug it missed for three releases. (NET-10a)

### Added
- **`aidc status` reports the session's egress posture**, and `aidc upgrade` warns when
  it is about to preserve an unenforced one. This matters more than it sounds: `upgrade`
  reuses the compose file rendered at *create* time, so upgrading a session created
  before v1.3.0 does **not** switch it to enforced — it stays bypassable while looking
  upgraded. Both commands now say so and point at `aidc kill` + `aidc create`.
- **`--egress proxied|direct` and an `egress:` config key.** `direct` restores the
  pre-v1.3.0 NATed bridge for sessions needing reachability an attached network cannot
  provide (ZeroTier/Tailscale, direct DNS). `aidc create` states plainly that enforcement
  is off for that session. Default is `proxied`. (NET-14)

### Changed
- **Declared `--port` forwards and `aidc proxy` are now dual-homed forwarder sidecars.**
  An internal network cannot publish ports, so `ports:` on the dev service would have
  silently done nothing. Each declared port becomes an `aidc/forwarder` service
  (`aidc-<session>-dfwd-<port>`) that publishes on the egress network and reaches dev
  across the internal one; `aidc proxy` starts its adhoc sidecar the same way. Behaviour
  from the user's side is unchanged.
- **`aidc network` is unaffected** — attaching a network still grants full access to that
  network's services, which is the point of it. Because most compose bridges are NATed and
  an internal bridge has no default route of its own, an attachment does restore general
  internet egress as a side effect; aidc cannot prevent that, since it does not own that
  network. Detaching closes it again, and the smoke suite now asserts exactly that scoping.

## [1.2.0] - 2026-09-05

### Added
- **Sessions can reach another stack's services.** A session's dev container can now attach
  to named Docker bridge networks, so it resolves another compose project's containers by
  name and can talk to that project's database, queue, or cache directly — the case that
  motivated this was troubleshooting a metallm session against metallm's own postgres.

  Two forms, differing only in how long they last:

  - `aidc create <name> --network <net>` (repeatable) and a `networks:` list in
    `.aidc/config.yaml` — **declared**; survives restart, upgrade, and recreate. CLI and
    config *merge* here, unlike `--dns` which overrides. Networks are validated before any
    image build, so a typo costs a message rather than a `dev-base` rebuild.
  - `aidc network <session> add|rm|ls` — **adhoc**; attaches a session that is already
    running, no recreate needed. Survives `aidc restart` (a network endpoint is dev-container
    state, so there is nothing to sweep) but not `aidc upgrade` or `aidc kill`. `ls` marks
    each attachment declared or adhoc so that difference is visible.

  `aidc status <name>` gained an **attached networks** section, listed even when empty.

  Only the `dev` service is ever attached — squid, refresher, policy, and audit stay isolated
  on the session's own network. `host`, `none`, and Docker's default `bridge` are refused.

  **Every attachment pins `gw_priority` so `aidc-<session>-net` keeps the default route.**
  This is not a detail: measured on Docker 29.1.3, a plain `docker network connect` moves the
  default gateway onto the network being attached, and Compose's `priority` key — which only
  orders the connect sequence — does not prevent it. Without the pin, attaching a network
  silently reroutes *all* of the session's egress, squid-proxied traffic included, out through
  someone else's bridge, with nothing in the audit trail to show for it.

  Because `gw_priority` needs Compose 2.34+, `aidc create` probes for it and fails with that
  reason rather than rendering a file whose gateway pin would be dropped. Sessions with no
  attachment render a byte-identical compose file to before and are unaffected.

  This is a deliberate, documented widening of the sandbox: traffic to an attached network
  does not pass through squid, so the blocklist does not apply and taint detection cannot see
  it, and the attachment is bidirectional. `docs/done/design-07-safety-model.md` now sizes
  that honestly, and both the CLI and the config template say so at the point of use.
  (NET-13, CLI-24, CLI-25)

## [1.1.1] - 2026-08-22

### Fixed
- **`session_resend` no longer puts a duplicate reply into the conversation.** It
  warned about a duplicate but still delivered one: the warning went to the
  caller's tool result while the callback injected a verbatim second copy of an
  already-answered reply into the conversation (prod conv 01a01cf6: a 4851-char
  duplicate of the previous answer). A reply whose fingerprint is in the delivery
  ledger — meaning metallm acked it — is now **not re-posted at all**; its text
  comes back in the tool result instead, so the caller can read it without a
  second copy landing anywhere. `status` reports `already_delivered` vs `resent`.
  Pass `force` for the one case the ledger cannot see: metallm acked the callback
  but lost the message downstream.

  The gate is the ledger, not the watermark, on purpose — the watermark advances
  past a turn even when delivery was abandoned to the dead-letter dir, so a
  genuinely lost reply stays absent from the ledger and remains resendable. That
  is the case this tool exists for.

- **`session_resend`'s description now steers away from the misuse that caused
  the incident.** It was reached for whenever a reply seemed slow; the reply that
  looked missing had usually never been requested. It now says plainly that a
  session mid-turn has not answered yet, and points at an un-run `session_send`
  as the likeliest cause of a genuinely absent reply.

## [1.1.0] - 2026-08-22

### Added
- **`install.sh` — one-command install.** `curl -fsSL
  https://github.com/pacepace/aidc/releases/latest/download/install.sh | bash`
  resolves the latest release (or `--version vX.Y.Z`), verifies the tarball's
  sha256 against the checksum published in the Homebrew tap, installs to
  `~/.local/share/aidc/aidc-<version>/`, and symlinks `~/.local/bin/aidc`.
  Previous versions stay on disk for rollback; `--prune` clears them. The
  release workflow now requires the Release to carry `install.sh` as an asset
  byte-identical to the tagged tree's copy.

### Changed
- Releases now ship on **Release publish from `main`**, not on a tag push. A bare
  tag triggers nothing; publishing the GitHub Release fires the workflow, which
  validates the tag rather than creating it (so the job is read-only on contents)
  and refuses any tag whose commit is not on `main`.

### Fixed
- **`session_send` no longer discards a prompt sent to a busy session.** A
  dev-agent turn routinely outlives any inline wait — one ran 22 minutes after an
  auto-compaction — and the old path waited 30s for an idle pane and then returned
  an error, dropping the prompt with nothing retrying it. Prompts are now queued
  per session and injected the moment the turn ends, in order; the tool returns
  `status: "queued"` (still `ok`), so an orchestrator that tracks busy sessions on
  a successful send keeps tracking this one. A queue that can never drain (Claude
  gone, or a pane that never goes idle) is dead-lettered under `watcher-state/`
  rather than lost.
- **Every `session_send` refusal is now audited.** The "Claude not running",
  paste-failed, and queue-full paths returned silently, so the only trace of a
  dropped prompt was the *absence* of a `session_send_sent` line. They now log
  `session_send_failed` with the reason that closed the gate.
- **`session_resend` says when its reply is stale.** With no `turn_uuid` it
  re-delivers the newest *completed* turn, which — while the agent is mid-turn —
  answers an earlier prompt, not the one the caller is waiting for. The result now
  carries `session_busy` / `already_delivered` and a plain-language note, instead
  of passing an old answer off as the pending one.

## [1.0.0] - 2026-08-11

First public release, under the MIT license.

### Added
- `aidc help` now prints the version in its header line (also what `brew test`
  asserts).
- `docs/release-process.md` — the operator checklist for cutting a release,
  referenced by the release workflow and formula docs.

### Changed
- Homebrew caveats now state the `docker compose` v2 plugin requirement explicitly.
- `CODEOWNERS` reviews route to `@pacepace` directly (personal account, no org team).
- `.claude/settings.json` is no longer tracked — editor/agent plugin choices are
  local opt-in (`.claude/` settings are gitignored), so cloning the repo does not
  auto-install any third-party plugin.
- Docs refreshed to match the 0.6.x reality: CI gates vs. the local `make smoke`
  pre-tag gate (CONTRIBUTING, release workflow comments), Ubuntu 26.04 base
  (requirements CTR-01), and the completed task shards moved into `docs/done/`.

### Fixed
- The release workflow now hashes the same tag-archive byte stream the formula
  downloads (`archive/refs/tags/…` via codeload), instead of the GitHub API
  tarball whose sha256 never matches — `brew install` from the tap would have
  failed checksum verification for every user.
- The versioned-formula template now renders class names Homebrew can load
  (`aidc@1.0` → `AidcAT10`, not `AidcAT1_0`).

## [0.6.1] - 2026-08-04

Follow-up to 0.6.0. The dev image bakes one fewer Python, and the smoke gate
moves off GitHub Actions.

### Changed
- **The dev image bakes 2 Python minors instead of 3** (currently 3.13 + 3.14).
  Each one is a full CPython source build and this is the single biggest cost in
  a >5GB image. The third bought very little: `/usr/local/pyenv/versions/` is a
  shared named volume, so "instant start" only ever applied to the *first*
  session on a machine — a project asking for an unbaked version via
  `.python-version` compiles it once and then keeps it across every later
  `aidc kill` / `aidc create`. Measured on 24 cores: the pyenv build step drops
  180s → 120s and the image drops 5.48GB → 4.97GB. Tune with
  `--build-arg PYTHON_BAKE_COUNT=N`; `3` restores the previous behavior.

- **Smoke no longer runs in GitHub Actions.** Its real work is building
  `dev-base`, and a 2-core hosted runner is the wrong place to do it. Measured on
  the 0.6.0 candidate: 15m26s building the image to execute **53 seconds** of
  assertions — for an image every user builds locally anyway (REL-08). It failed
  twice consecutively on runner disk exhaustion rather than on any real defect,
  which is a gate costing more than it catches. `.github/workflows/smoke.yml` is
  retained for `workflow_call` only, so a self-hosted runner can drive it later.
  **`make smoke` is now the pre-tag gate** (see CONTRIBUTING.md). CI keeps the
  checks it was always good at: shellcheck, formula-template lint, shell unit
  tests, and the MCP suite on Python 3.12 and 3.14.

### Fixed
- **The smoke harness could not talk to the Squid 7.x sidecar, and four of its
  ten steps silently never ran.** Step 6 injects a domain into the blocklist and
  reloads Squid via `docker exec … bash -c "… && squid -k reconfigure"`. Every
  part of that broke when the sidecar moved to the chiselled Rock in 0.6.0: it
  ships no `bash`, the binary is `squid-gnutls` rather than `squid`, and
  `/etc/squid` is root-owned while Squid runs as UID 584792. `docker exec`
  returned 127 and `set -e` aborted — between step 6's last assertion and step
  7's banner, so the run printed `[cleanup]` and read as a teardown fault rather
  than a regression. Steps 7–10 (taint detection, taint in `aidc status`, kill,
  audit) never executed. The reload now signals PID 1 from the host, exactly as
  the refresher sidecar does in production, so it depends on nothing inside the
  container.

## [0.6.0] - 2026-08-04

Minor rather than patch: every image in the stack rebuilds, and the Squid
sidecar changes its runtime contract (see below). Nothing in the `aidc` CLI
surface changes, but no layer cache survives this.

### Changed
- **The entire toolchain moved to current releases.** The dev image had drifted
  far enough that it was shipping software nobody upstream supports any more:
  Node 20 (whose bundled npm 10.x is below the npm 11.10+ floor tooling now
  expects) and Go 1.22, which is outside upstream's two-major support window and
  therefore receives no security fixes at all. Now:

  | | was | now |
  |---|---|---|
  | dev container base | ubuntu 24.04 | ubuntu 26.04 |
  | Node / npm | 20.x / 10.x | 24 LTS / 12.x |
  | Go | 1.22 (apt `golang-go`) | 1.26.x (go.dev) |
  | proxy sidecars | alpine 3.20 | alpine 3.24 |
  | Squid | 6.6-24.04 | 7.2-26.04 |
  | MCP image | python 3.12-alpine, uv 0.11 | python 3.14-alpine, uv 0.12 |

  Go no longer comes from apt. A distro package is frozen for the life of the
  release, so it drifts back out of support as new majors ship; the toolchain is
  now fetched from go.dev resolving *latest stable at build time*, so a rebuild
  tracks Go forward with no Dockerfile edit — the same self-updating shape the
  pyenv block already used. The image also asserts npm ≥ 11 at build time, so
  this floor can't silently regress again.

- **Squid runs unprivileged.** The 7.x image is a chiselled Rock: it runs as UID
  584792 instead of root and ships no bash, sed, chmod, chown or mkdir. That is
  a real hardening win for the one container that brokers all egress, but it
  meant the sidecar's plumbing had to be rebuilt around it — build-time file
  modes now come from `COPY` flags, and the healthcheck and entrypoint are perl
  (already in the base image, so no new packages on a security-critical
  sidecar). `CMD` no longer carries `-f`; the entrypoint supplies the config
  path, because a DNS-override session must start Squid from a derived config.

- **CI runs the MCP suite on both ends of the supported range** (3.12, the floor
  `requires-python` declares, and 3.14, what the image actually ships).
  Previously it tested only 3.12 — neither the shipped interpreter nor the floor
  claim was verified. All GitHub Actions are updated to current majors and
  re-pinned by commit SHA.

### Fixed
- **`rustc` and `cargo` were missing from every tmux pane.** The image set them
  on `PATH` via `ENV` only, but `entrypoint.sh` drops privileges with
  `exec sudo -E -u vscode`, and sudo replaces `PATH` with its own `secure_path`.
  Only `/etc/profile.d` entries survive that, which pyenv had and Rust never
  did — so Rust worked under `docker exec` (which bypasses the entrypoint) and
  was simply absent in the interactive session where it's actually used.

- **`npm install -g` failed with EACCES for the `vscode` user.** The global
  prefix pointed at root-owned `/usr/lib/node_modules`. It is now a user-owned
  directory, so global installs work without sudo — the same trap that had
  previously broken Claude Code's self-update.

- **`post-create.sh` installed a second, root-owned copy of Claude Code** over
  the native install the image bakes, via `sudo npm install -g
  @anthropic-ai/claude-code`. Its guard was `command -v npm`, which is always
  true now that npm ships in the image, so it fired on every create and
  reintroduced exactly the EACCES self-update failure the native installer was
  adopted to avoid. Removed.

- **A Squid DNS override could fail silently and leave the session resolving
  through the wrong nameservers.** The entrypoint edited `squid.conf` in place,
  which is impossible for the unprivileged 7.x user against a root-owned
  `/etc/squid` — and Squid then started happily from the *unmodified* config and
  reported healthy. The rewrite now targets a writable path and verifies its own
  result, hard-failing the container if the directive is still present, the file
  is empty, or the derive could not be written. `aidc create` already gates on
  Squid becoming healthy, so this now fails the session loudly instead of
  quietly proxying through Quad9.

- **A config value with a trailing comment was read with the comment attached.**
  The shipped config template documents every key inline —
  `callback_url: ""    # base URL of your MetaLLM instance` — so filling it in
  the obvious way (replace the `""`, keep the comment) produced a URL with the
  comment glued on, and every callback POST went to an unresolvable host. The
  MCP config parser now strips inline comments and quotes the way
  `lib/config.sh` always has; the two no longer disagree about the same file.

- **`session_send` gave no reason when it declined to watch a session.** Both
  gates failed silently, and a send with no watcher still injects the prompt and
  reports `ok` — so the reply was produced and dropped with nothing in the audit
  log saying which gate closed. The log now names the specific cause (no
  `conversation_id` supplied, or `metallm.callback_url` unset).

## [0.5.13] - 2026-07-22

### Added
- **The transcript callback now names which session finished the turn.** The body
  carried `content` / `ok` / `source` only, so an orchestrator watching more than
  one session could not tell whose reply had arrived. `_post_turn` now includes
  `session`, passed through by both delivery paths (the watcher drain and the
  out-of-band resend). Purely additive — the existing fields are unchanged, so a
  consumer that ignores it is unaffected.

  This unblocks the orchestrator gating `session_send` on a per-session BUSY
  marker: it arms the marker from its own accepted send and needs this field to
  release the right session when the reply returns. Without it the assistant kept
  re-sending into a session whose turn was still running.

## [0.5.12] - 2026-07-22

### Fixed
- **The same reply could be delivered to the orchestrator more than once,
  poisoning the agent's context** — a recurring meltdown with a different
  upstream cause each time (mtime-flap rotation, torn-read baseline rewind,
  reconnect catch-up, a retry storm). The root problem was structural: the
  delivery path trusted the resume watermark for exactly-once safety, and the
  watermark has many ways to be wrong. Exactly-once is now enforced by a separate
  **durable delivery ledger** — a per-`(session, conversation)` append-only set of
  the content fingerprints already confirmed delivered, consulted right before
  every POST. A turn whose fingerprint is already recorded is never sent again, no
  matter how the watermark misbehaves; a watermark bug degrades from a duplicate
  delivery to a wasted disk read. Fingerprinting on content (not uuid) also
  catches a turn re-emitted under a new uuid after coalescing.
- **A callback that failed with a permanent HTTP status was retried for the full
  30-minute budget.** A `404 conversation-gone` (the orchestrator had discarded
  the conversation) was retried identically ~34 times, hammering a dead endpoint
  with the same payload. HTTP failures are now classified: `5xx`/`408`/`429` retry
  as before; every other `4xx` is permanent and dead-letters immediately.

## [0.5.11] - 2026-07-21

### Changed
- **`session_run` is no longer offered as an MCP tool.** Its synchronous,
  multi-turn round-trip blocks while every turn runs in sequence, and on MetaLLM
  that regularly outlasts the request window and times out the whole session. The
  tool is de-advertised (the `@app.tool()` registration is removed) the same way
  `session_kill` was — the wrapper is retained for easy re-advertisement, but MCP
  clients can no longer discover or call it. Drive a multi-turn sequence as
  repeated `session_send` calls instead.

## [0.5.10] - 2026-07-16

### Fixed
- **A torn read of the mirrored transcript could rewind the reconnect
  re-anchor**, so a watcher reconnecting mid-write could replay already-delivered
  turns. The re-anchor no longer moves backward on a short/torn mirror read.
- **Transcripts were copied forward non-atomically**, leaving a reader able to
  observe a partially written file. The copy-forward now writes to a temp file
  and renames atomically. Covered by a new regression test (with GNU/BSD `stat`
  portability fixed).

## [0.5.9] - 2026-07-11

### Fixed
- **A retried API error was delivered as a completion, and the pre-error reply
  was lost.** An assistant line with `isApiErrorMessage` eagerly flushed and
  emitted in `extract_completed_turns`, so an error that Claude Code auto-retried
  and continued past still surfaced as a premature `ok=False` completion — and
  because the flush dropped the in-flight group's text and advanced the watermark
  past the error, the work produced before the error never reached the watch
  session. The error is now treated as a terminal *candidate*: a later real
  terminal under the same prompt supersedes it (the retry succeeded → deliver the
  successful answer, `ok=true`), and only an error that is the last terminal
  before the next prompt or EOF — the session genuinely waiting for input — is
  delivered as a failure result, carrying the pre-error text plus the error
  message. Verified against the live faidh transcript.

## [0.5.8] - 2026-07-09

### Fixed
- **Fresh-session first reply swallowed ("the reply never comes back").** The
  forward-only baseline anchored a fresh session with an empty `session_id`; the
  first drain mistook the empty→real `session_id` transition for a session
  rotation and baselined *past* the first reply, so it was never delivered. The
  rotation branch is now gated on a non-empty prior pin, and a first pin adopts
  the new session and delivers its turns. Forward-only is preserved (an empty
  `session_id` is only ever the fresh-no-file baseline).
- **`session_send` description** no longer asks the model to supply
  `conversation_id` (metallm injects it), removing the contradictory
  "needs it / it is provided" wording that made the model debate what to pass.

### Added
- **`session_resend`** — re-delivers one completed reply (latest or a specific
  `turn_uuid`) via the same post/retry path without touching the watermark, so a
  resend can never trigger a backlog replay.
- Deterministic (no-AI) round-trip + resend test suite (8 tests).

## [0.5.7] - 2026-07-09

### Fixed
- **Transcript watcher replayed a backlog to "catch up" a reconnecting metallm
  session** (prod 2026-07-09, conv `019f4220` — a runaway that flooded the
  orchestrator with old turns). `_baseline_watermark` only anchored forward on the
  *first-ever* watch; on any reconnect / MCP restart / a mark left stale from a
  prior life it no-op'd and kept the old position, so the next drain delivered
  everything from that stale offset to now. It now **re-anchors forward on every
  watcher (re)start** — `last_delivered_uuid` moves to the current last turn, so a
  (re)connecting session gets only turns that complete *after* the reconnect,
  never a backlog. The response to a `session_send` completes after this anchor so
  it's still delivered; only pre-existing history is skipped. The durable
  loop-guard run (`consecutive_deliveries` / `last_delivery_at`) is preserved
  across the re-anchor so the ongoing-runaway backstop still trips.

## [0.5.6] - 2026-07-09

### Added
- **Share host Claude Code plugins into containers** via a new `share_plugins` config
  (default `true`, mirrors `share_memory`/`share_auth`). `aidc create` bind-mounts the
  host's `~/.claude/plugins` **read-only** so host plugins — prawduct and any others —
  are available inside sessions. This generalizes the v0.5.5 workspace-`settings.json`
  approach, which only worked when the workspace itself was aidc; `share_plugins` covers
  every workspace.
  - **Dual mount:** Claude Code resolves a plugin's cache by convention (a
    `~/.claude/plugins/cache/` scan) but loads its marketplace by the absolute
    `installLocation` in `known_marketplaces.json`, so the dir is bound at both the
    container home path and its own host-absolute path (the latter skipped when they
    coincide). Mirrors the existing workspace path-alignment mount.
  - **Read-only** keeps the host the single writer of the shared plugin registry; a
    container writing back would race/corrupt it and poison it with container paths.
  - **Enablement** is written container-locally by the entrypoint to
    `/etc/claude-code/managed-settings.json` (highest-precedence scope, merges over the
    bridged user settings) so it never leaks onto the host's `settings.json`.

## [0.5.5] - 2026-07-08

### Added
- **Prawduct plugin auto-install for aidc sessions** via a tracked `.claude/settings.json`
  (declares the prawduct GitHub marketplace + enables `prawduct@prawduct`). An aidc session
  bind-mounts the workspace repo, so Claude Code in the container reads this and auto-installs
  the plugin on start — aidc's own sessions are governed without a per-operator manual install.
  Requires github.com egress for the marketplace clone; `.gitignore` still excludes only
  `settings.local.json`.

## [0.5.4] - 2026-07-08

### Fixed
- **Every agent reply delivered to the MCP client TWICE** (`mcp/src/aidc_mcp/tools.py`).
  Delivery is exactly-once via a durable watermark, but advancing it is a read-modify-write
  that straddles the await-heavy callback POST (load the mark → extract undelivered turns →
  POST each → save the advanced mark). Two delivery passes for the same
  `(session, conversation)` could overlap and both load the *same* pre-delivery mark, so both
  POSTed the same turn — every reply surfaced twice. Overlap was reachable two ways in the
  single-process streamable-HTTP server (tool calls run as concurrent asyncio tasks): the
  watcher registration in `_start_watcher` did its check-then-register across an `await`, so
  `session_watch` ("call this first") racing `session_send`'s auto-watch — or two rapid sends —
  could leave **two** watcher tasks polling one watermark; and a `session_watch` replacement
  cancelled the old watcher without awaiting it, so its in-flight drain could still be mid-POST
  when the fresh watcher's first drain began. Fixes: (1) `_start_watcher` now cancels any
  existing watcher and registers the new task synchronously, before any `await`, so exactly one
  watcher polls a session; (2) each delivery pass runs under a per-`(session, conversation)`
  mutex, making the whole load→deliver→advance critical section atomic so a second pass sees the
  advanced mark and dedups. No delivery guarantee changes: no dropped turns, no replay, still
  forward-only. Regression tests pin exactly-once under two overlapping passes and under
  rotation-follow (which must never re-deliver a turn that existed at rotation time).

## [0.5.3] - 2026-07-04

### Fixed
- **Transcript watcher welded to a rotated-away session → no callbacks ever delivered**
  (`mcp/src/aidc_mcp/tools.py`, `transcript.py`). The watcher pins to a session's transcript
  file and keeps selecting it while it EXISTS — but Claude never deletes a rotated-away session
  transcript, so once the user's Claude rotated to a new session (a new `sessionId` file), the
  watcher stayed welded to the old, fully-consumed file and delivered nothing forever (prod
  019f1fde: pinned to `1b968f61` while faidh had moved to a new session; callbacks silent since
  the rotation, even though faidh was replying). Added a third recovery path: when the pinned
  session is fully consumed and a strictly-newer session exists, follow the rotation forward.
  Recency is decided by message **content** timestamps, not mtime — immune to the copy-forward
  mirror's mtime churn the pin was added to survive (a frozen sibling can never out-timestamp
  the session active after it). Gated by a sustained poll count against transient partial reads.

### Security
- **`session_kill` is no longer advertised as an MCP tool** (`mcp/src/aidc_mcp/tools.py`).
  A weak MCP client agent (metallm) discovered and called `session_kill`, tearing down a
  live session (audit 2026-07-04T17:53Z). The kill capability itself is unchanged — the
  `aidc kill` CLI is untouched and the wrapper is retained — but MCP clients can no longer
  discover or invoke it; tearing a session down is an operator action, not a client one.
- **MCP audit log + transcript mirrors are now `0700` and stored under the XDG state dir**,
  not a world-traversable `~/` path. These files contain conversation transcripts and must
  be private to the user.

### Changed
- **MCP state location** moved `~/aidc-mcp-audit` → `${XDG_STATE_HOME:-~/.local/state}/aidc-mcp`
  (`cmd-mcp.sh`, `cmd-create.sh`; the in-container `/var/log/aidc-mcp` mount target is
  unchanged). Applies to newly (re)created MCP + session containers.
- **Release pipeline** (`release.yml`): dropped the full-stack smoke re-run from the
  tag/release path. A `v*` tag always points at a main commit, which `smoke.yml`
  already validated on `push -> main` (the develop->main merge); re-running it on the
  tag rebuilt the whole `dev-base` image and spun the container stack to re-check an
  already-checked commit, adding ~3-20 min to every release. The release keeps its own
  cheap gates (tag<->VERSION<->commit checks + both tarball audits); end-to-end smoke
  still gates every `push -> main`, so no coverage is lost.

## [0.5.2] - 2026-07-03

### Fixed
- **Delivery loop guard timing-independence** (`_drain_transcript_once`): the v0.5.1
  rate-based guard never tripped in prod incident 2026-07-03 (MetaLLM conv 019f1fde).
  It reset its consecutive-run counter on any gap over 45s, but the runaway's turns
  grew slow as context ballooned (observed inter-delivery gaps up to ~250s), so it
  flooded the orchestrator with duplicate `agent_watch` callbacks without ever firing.
  Timing does not distinguish a loop from real work. The guard now counts the run of
  consecutive deliveries and trips past `_LOOP_GUARD_MAX_CONSECUTIVE` (20); only a
  genuinely idle gap (`_LOOP_GUARD_IDLE_RESET_S`, 15 min — far longer than any single
  turn) resets the run, so a slow runaway can't dodge while a truly quiet session is
  not latched. This is the coarse backstop; the orchestrator's own guard (which resets
  on a human turn) is the precise layer, so this cap sits above it. The watermark field
  `fast_consecutive` is renamed `consecutive_deliveries`, reading the old key for
  back-compat so a deploy mid-incident does not reset a latched run.
- **Release tarball audit** (`tarball-audit-extracted.sh`): the extracted-tarball
  release gate false-aborted on the empty `tests/scratch/` directory entry — `tar tzf`
  lists directories with a trailing slash, and the `FORBIDDEN` pattern matched the bare
  dir, which the `.gitkeep` allow-rule didn't exempt. It now drops directory entries
  before the forbidden-file check (a real file *under* a forbidden dir is still caught).
  Surfaced on the first end-to-end run of this gate — v0.5.1's Release was hand-cut.
- **Watcher self-heals from a dead pinned session** (`_drain_transcript_once`): the
  transcript watcher pins to the session it is tracking so mtime flaps don't make it
  replay. But if that session's transcript lingers on disk while its resume anchor is
  gone for good — a torn final line from a session killed mid-write, or a compaction —
  the pin never rotates and `objs_after_uuid` returns `None` every poll, so the watcher
  sat in `torn_read_skip` forever and delivered nothing (prod 2026-07-03: the `faidh`
  watcher was welded to the 34MB runaway transcript for 40+ min while the live session,
  a fresh transcript after the container was rebuilt, went undelivered). A transient
  torn/partial read still recovers within a poll or two (unchanged); only a SUSTAINED
  absence — `_TORN_READ_RECOVER_POLLS` (~30s) consecutive misses — with a strictly-newer
  transcript present is treated as a dead pin, and the watcher rotates onto the newest
  session (forward-baseline), exactly like a genuine rotation.

## [0.5.1] - 2026-07-03

### Fixed
- **Delivery loop guard** (`_drain_transcript_once`): break runaway orchestrator↔session
  loops. An aidc session has no human at the pane, so an orchestrator (MetaLLM) and the
  session answering each other forever had no natural terminator (prod incident 2026-07-03:
  a MetaLLM conversation fired every ~6s for tens of minutes, and restarting the MCP did not
  stop it). The watcher now rate-limits: it drops a delivery once the run of consecutive
  *rapid* deliveries — each within `_LOOP_GUARD_FAST_GAP_S` (45s) of the prior — exceeds
  `_LOOP_GUARD_MAX_FAST` (15). A slower gap (real work) resets the run, so a legitimate long
  task never trips no matter how many turns it runs. The run + last-delivery time are
  persisted in the durable watermark, so an MCP restart cannot silently resume the loop. On
  trip the turn is dead-lettered and the watermark advances (no POST), so the orchestrator
  stops receiving and the session idles out — self-healing.
- **Dev-container git** (`safe.directory`): the workspace is bind-mounted and owned by the
  host uid, not `vscode`, so modern git refused every command with "detected dubious
  ownership". The image now trusts all directories at the system level
  (`git config --system safe.directory '*'`); the container is single-purpose and isolated,
  so the cross-user-ownership guard adds nothing. (Committing to a repo owned by a *different*
  uid still requires it be writable by the container user — a host-side concern; the CI smoke
  test makes its scratch repo world-writable to cover a runner uid ≠ the container's 1000.)
- **Audit `meta.json` write robustness**: both meta.json writers in the audit sidecar —
  `aggregate.sh`'s `meta_update` (the periodic + SIGTERM-final `tainted_at`/`killed_at`
  stamps) and `finalize.sh` — now write atomically *within* the audit volume (mktemp in
  `meta.json`'s own directory → same-filesystem `rename()`) **and world-readable**
  (`chmod 0644`). Previously they used a cross-filesystem `mktemp`+`mv` copy at mode `0600`: a
  SIGKILL that cut short the teardown sweep left a truncated, invalid-JSON file, and the
  root-owned `0600` result was unreadable to a non-root host (a CI runner). `jq -e .` failed.
- **Smoke teardown**: git commit inside the dev container (uid 1000) leaves `.git` objects a
  differently-uid'd host runner can't `rm`; the smoke cleanup now falls back to a root
  container to clear the scratch tree.
- **Release pipeline** (`release.yml`): every `v*` tag push had failed at *startup* — the
  reusable `smoke` release-gate requests `contents: read`, which exceeded the workflow's
  top-level `permissions: {}`, so GitHub rejected the whole workflow and **no GitHub Release
  or Homebrew-tap update was ever produced** (v0.5.0's Release was hand-created). The `smoke`
  job now grants itself `contents: read`, so tag pushes actually cut the Release + tap. A
  second latent break: the "download published source tarball" step curled the *public*
  `github.com/<repo>/archive/...` URL, which 404s for a **private** repo (no auth) — it now
  uses the authenticated API tarball endpoint (`/repos/<repo>/tarball/<tag>` with the token).

## [0.5.0] - 2026-07-03

A broad v1.0.0-readiness spring-clean.

### Added
- **CI** (`.github/workflows/ci.yml`): shellcheck + mcp `pytest`/`ruff`/`mypy` on push/PR.
- **Release automation** (`release.yml`) on `v*` tags, plus a reusable smoke workflow, a
  Homebrew formula (`Formula/aidc.rb` + versioned templates), and tarball-audit gates.
- **Lint/type tooling**: `ruff` + `mypy` for the MCP server (both green).
- **Docs**: `CHANGELOG.md`, `SECURITY.md`, `CONTRIBUTING.md`, and an Uninstall section.
- **Tests**: MCP suite grown 100 → 163 — the full `session_*`/`file_*`/`audit_get`/`taint_mark`
  tool surface, the bearer-auth middleware, and the resource layer are now covered.

### Fixed
- **Security**: the rendered `/tmp/aidc-<session>.yaml` (holds the OAuth token) is now created
  and kept `0600` instead of world-readable.
- Two latent MCP bugs surfaced by mypy: `audit_get` raised `TypeError` on every call
  (kwarg collision), and a `session_invoke` stderr-drain deadlock/orphan.
- `session_run` no longer double-delivers (it delivers inline; no duplicate webhook watcher).
- Reproducible MCP image build (installs from `uv.lock`; `.dockerignore` added).

### Changed
- Dead-code removal, helper de-duplication across the CLI, `--help` on every subcommand,
  complete config-snapshot audit record, and doc/artifact fitness fixes (design-09 moved to
  `docs/done/`, README tool list + facts corrected).

## [0.4.4] - 2026-07-03

### Added
- Selectable Claude Code permission modes via `AIDC_CLAUDE_MODE` / config `claude_mode`:
  `yolo` (default) · `safe` · `default` · `acceptEdits` · `auto` · `bypassPermissions` ·
  `dontAsk` · `plan`. Unknown modes make the `aidc-claude` wrapper exit 2.

### Changed
- The v0.4.3 human-in-the-loop deny is now mode-aware: `AskUserQuestion` is denied in every
  mode; `ExitPlanMode` / `EnterPlanMode` are denied in every mode except `plan`. Default
  behavior is byte-identical to v0.4.3 (yolo + all three tools denied).

## [0.4.3] - 2026-07-02

### Fixed
- Orchestrated-session deadlock when the agent called an interactive tool: `aidc-claude`
  now denies `AskUserQuestion`, `ExitPlanMode`, and `EnterPlanMode` so the agent asks in
  plain text over the normal delivery path.
- Delivery-path hardening against an attacker-influenced transcript: defensive JSONL parse
  (crafted lines skipped, never crash the watcher), delivery anchors require a real `uuid`
  (no empty-anchor whole-file replay), and committed text is snapshotted per terminal so it
  is not re-delivered on resume.
- Safety net: if an interactive tool appears anyway, the watcher delivers the rendered
  question instead of hanging silently.

## [0.4.2] - 2026-06-16

### Fixed
- Tool-routing: `session_send` is now framed as "ask the live, context-loaded agent a
  question, or hand it a task," so an orchestrator delegates to the session's resident Claude
  instead of self-serving via `session_exec` / `file_get`. `session_exec` / `file_get` point
  at `session_send`; `session_invoke` sharpened as the fresh/headless tool. Routing-cue tests
  guard the cross-references.

## [0.4.1] - 2026-06-16

### Fixed
- Transcript-watcher replay: the active transcript is now pinned to the tracked `session_id`
  (mtime only as fallback), so copy-forward mtime churn no longer flaps between files and
  re-delivers whole transcripts; genuine rotation is forward-only and torn reads are skipped.
- Premature "ready": `end_turn` segments between user prompts are coalesced into one turn and
  held until the transcript is quiet for `metallm.turn_settle_seconds` (default 4s).
- Resume stability: resume is anchored on the append-only line uuid, so an early settle
  degrades to a follow-up delivery instead of wedging or replaying.

## [0.4.0] - 2026-06-15

### Changed
- **Breaking:** `session_send` is now non-blocking. It injects the prompt and returns a
  send-confirmation (`{status: "sent", delivery: ...}`) immediately; Claude's reply is
  delivered back into the conversation by the transcript watcher (auto-started on first send)
  over the webhook, not in the tool's return value. If no webhook is open, the return says so
  and points at `session_invoke` for an inline answer.

## [0.3.0] - 2026-06-15

### Added
- Reliable JSONL-sourced callback delivery (MCP-15..19): responses are delivered from Claude
  Code's per-session JSONL transcript instead of scraping the tmux pane. Turn completion is
  detected from transcript structure; delivery is exactly-once via a durable
  per-`(session, conversation_id)` high-water mark, with bounded retry, dead-letter, and
  per-attempt instrumentation. Forward-only: a first watch baselines to the current transcript
  end (no history replay).
- Transcript surfacing via an in-container copy-forward mirror into the MCP audit volume
  (scoped per session).
- Open-webhook sessions surfaced in tool descriptions; trigger-first / per-parameter
  descriptions tuned for smaller orchestrating models.

### Changed
- **Breaking:** MCP tool-namespace rename — no exposed tool is named `claude` anymore. The
  session-interaction tools use a `session_*` namespace (`session_invoke`,
  `session_invoke_async`, `session_send`, `session_run`, `session_watch`, `session_unwatch`).
  MCP clients must update their tool configuration.

## [0.2.4] - 2026-06-07

### Fixed
- Claude Code project-path encoding: `.` is now replaced along with `/` when computing the
  per-project session directory, restoring session continuity for repo paths containing dots
  (e.g. `pace.org`). Requires `aidc rebuild` to bake the fixed wrapper into the dev image.
- Removed the MCP session auto-restart: `session_send` / `session_run` now return a clear
  error if Claude is not running rather than silently injecting keystrokes to restart it.

## [0.2.2] - 2026-06-07

### Added
- `claude_session_send` / `claude_session_run` accept `conversation_id` and auto-start the
  background watcher if one is not already active — no explicit watch call needed first.

## [0.2.1] - 2026-06-06

### Added
- `conversation_id` is accepted as optional on the watch tool and auto-injected by MetaLLM,
  so shared-session webhooks route to the correct conversation. Calls without it return a
  clear error. (Tag `v0.2.1-fix1` carries a follow-up patch.)

### Changed
- Sharper session tool descriptions (correct window name, call-this-first guidance, truncation
  warning).

## [0.2.0] - 2026-06-06

### Added
- Agent-window session tools driving the persistent `claude` tmux window:
  `claude_session_send`, `claude_session_run`, `claude_session_watch` /
  `claude_session_unwatch` (idle-detected webhook to a nominated MetaLLM conversation).
- Idle webhook with anchor-based delta extraction.
- `develop` branch established — gitflow now in effect for this repo.

### Removed
- `aidc-isolated-claude` HOME isolation (it triggered an unresolvable consent dialog on every
  fresh container start); the agent tools now share the interactive session's `claude` window.

<!-- Pre-1.0 versions have no link definitions: their tags exist only in the
     private pre-release history, so compare links would 404. -->
[Unreleased]: https://github.com/pacepace/aidc/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/pacepace/aidc/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/pacepace/aidc/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/pacepace/aidc/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/pacepace/aidc/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/pacepace/aidc/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/pacepace/aidc/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/pacepace/aidc/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/pacepace/aidc/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/pacepace/aidc/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/pacepace/aidc/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/pacepace/aidc/releases/tag/v1.0.0
