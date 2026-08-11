# task-11: Host-to-Container Port Forwarding

## Objective

Make services running inside the dev container reachable from the host browser / CLI without bridging into the proxy stack's locked-down egress path. Two ways in: **declared** ports baked into the compose template at `aidc create` time (for stable, project-known ports), and **adhoc** ports added at runtime via a new `aidc proxy` subcommand using a per-forward `aidc/forwarder:local` socat sidecar.

The motivating use case: dev work happens inside the container; "test the result" happens from the host browser. The host never needs a Python venv or `node_modules/` — it just needs HTTP access to whatever the container is serving.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| CLI-13 | `aidc create` MUST accept `--port HOST:CONTAINER` (or `--port N` shorthand for `N:N`), repeatable, and the merged set of CLI flags + `<repo>/.aidc/config.yaml` `ports:` list MUST be published from the dev container to the host. Conflicting host ports between sessions MUST fail at create time with the underlying docker error surfaced. | P0 |
| CLI-14 | `aidc proxy <session> add`, `rm`, `ls`, `clear` subverbs MUST manage adhoc host-to-container port forwards for a running session without restarting the dev container. Forwards MUST NOT persist across `aidc restart` or `aidc kill`. | P0 |
| CLI-15 | `aidc status <session>` MUST list all currently active port forwards (both declared and adhoc). | P0 |

---

## Design Context

### Container-first development

From the planning conversation (2026-05-22):

> The case where I'd want this running on the host is the one where I want to actually test it myself. Fire up the web interface and let me use it kind of test. Beyond that, devcontainers are the way forward.

This rules out solutions that involve cross-arch venv coexistence (per-arch suffixed dirs, etc.). The repo's `.venv/`, `node_modules/`, `target/`, etc. are container-only. The host's only role is editing files and viewing running services — over HTTP, not by linking against compiled binaries.

### Why two mechanisms

- **Declared ports (CLI-13)** are for ports that *every* aidc session of a given project needs. They live in `.aidc/config.yaml` so every box/dev gets the same set. They survive `aidc restart`.
- **Adhoc ports (CLI-14)** are for the "I just decided to expose this" moment that happens 10 minutes into a session. No restart needed.

User expectation (verbatim from conversation): *"if it works right I'll use proxy more often than the mapping, that way I can turn it on and off."*

### Sidecar approach for adhoc ports

A per-forward `socat` sidecar container joined to the session's docker network. Host's request for `localhost:HOST_PORT` is published into the sidecar by Docker Desktop / dockerd; socat inside the sidecar relays it to the dev container's hostname `aidc-${SESSION}-dev` on the network.

Works identically on macOS, Linux, and WSL2 because it uses only standard Docker primitives (a `docker run` with `-p` and `--network`).

### Image consistency

Per planning conversation: "let's do it the way we're doing it for everything else." All proxy-stack containers are locally-built `aidc/*:local` images from `proxy/<role>/Dockerfile`. The forwarder follows that pattern: `aidc/forwarder:local` from `proxy/forwarder/Dockerfile`. Lazy-built on first `aidc proxy add` (most sessions never use it).

---

## Files to Create

### `proxy/forwarder/Dockerfile`

```dockerfile
FROM alpine:3.20

# socat: the entire reason this image exists. apk's socat is current
# enough; no need to pin a specific version.
RUN apk add --no-cache socat

# Default arguments forwarded to socat. The aidc CLI overrides these
# via `docker run ... aidc/forwarder:local <args>`.
ENTRYPOINT ["socat"]
```

### `scripts/cmd-proxy.sh`

The new subcommand. Dispatches on sub-verb (`add` / `rm` / `ls` / `clear`).

**Argument shapes:**
- `aidc proxy <session> add <HOST:CONTAINER>` or `aidc proxy <session> add <N>` (shorthand for `N:N`)
- `aidc proxy <session> rm <HOST_PORT>` (remove by host port, since that's the disambiguating key — same container port can be forwarded from multiple host ports)
- `aidc proxy <session> ls`
- `aidc proxy <session> clear`

**Container name scheme:** `aidc-${SESSION}-fwd-${HOST_PORT}`. The host port is unique per session so this name guarantees one forward per host port.

**Lazy-build rule:** before first `docker run`, check `docker image inspect aidc/forwarder:local`; if missing, `docker build -t aidc/forwarder:local proxy/forwarder/` (use the existing `build_if_missing` from `cmd-create.sh` — extract it to `lib/common.sh` first if not already there).

**`add` flow:**

```bash
# Validate <session> exists and the dev container is running.
# Validate the port spec: HOST:CONTAINER or N (shorthand).
# Validate the host port isn't already forwarded by this session.
# Validate the host port isn't already published statically (compose ps will show it).
# Lazy-build aidc/forwarder:local if missing.
docker run -d --rm \
    --name "aidc-${SESSION}-fwd-${HOST_PORT}" \
    --network "aidc-${SESSION}-net" \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    aidc/forwarder:local \
    "TCP-LISTEN:${CONTAINER_PORT},fork,reuseaddr" \
    "TCP:aidc-${SESSION}-dev:${CONTAINER_PORT}"
# Print: "forwarding localhost:HOST_PORT -> aidc-${SESSION}-dev:CONTAINER_PORT"
```

**`rm` flow:** `docker rm -f "aidc-${SESSION}-fwd-${HOST_PORT}"` (idempotent — non-zero exit if name didn't exist, surface that as a warning, not a fatal error since the user's intent is "make sure it's gone").

**`ls` flow:** `docker ps --filter "name=aidc-${SESSION}-fwd-" --format '{{.Names}} {{.Ports}}'`, parse out host:container pairs, print as a small table.

**`clear` flow:** `docker ps --filter "name=aidc-${SESSION}-fwd-" -q | xargs -r docker rm -f`.

### `proxy/forwarder/Dockerfile` build registration

Append to `scripts/cmd-create.sh`'s `build_if_missing` block — but the forwarder is *lazy*, so don't eager-build at `aidc create`. Just make `cmd-proxy.sh` lazy-build via the shared helper.

If `build_if_missing` is still inline in `cmd-create.sh`, move it to `scripts/lib/common.sh` first so `cmd-proxy.sh` can reuse it. (Check first — it may already be in common.sh.)

---

## Files to Modify

### `proxy/compose.yaml.template`

Add `${PORTS_BLOCK}` placeholder under the `dev` service. The CLI renders this as a YAML `ports:` block (or empty string if no ports).

```yaml
  dev:
    image: aidc/dev-base:local
    ...
    ${PORTS_BLOCK}
```

Rendered output when ports are present looks like:
```yaml
  dev:
    image: aidc/dev-base:local
    ...
    ports:
      - "3000:3000"
      - "8080:80"
```

The CLI script is responsible for producing a string that is either empty (no `ports:` key at all) or a properly-indented `ports:` block followed by `- "H:C"` lines. **Indentation matters** — YAML is whitespace-sensitive. Output indentation: 4 spaces for `ports:`, 6 spaces for each `-` entry (to match the existing service block's interior indent).

### `scripts/cmd-create.sh`

1. Parse `--port` flags into a bash array. Each arg is either `N` (shorthand → expand to `N:N`) or `H:C`.
2. After config-merge, append entries from `.aidc/config.yaml`'s `ports:` list to the same array. CLI-flag entries come first; dedupe by host port (CLI flags win on conflict).
3. Validate each entry: `[1-9][0-9]{0,4}:[1-9][0-9]{0,4}` (1–65535 on both sides, but cheap regex is enough — docker will reject invalid ports).
4. Render the `${PORTS_BLOCK}` string and pass to `envsubst`.

### `scripts/cmd-status.sh`

Add a section listing port forwards:

- **Declared** (from compose): `docker compose -p aidc-${SESSION} ps --format json | jq '.[] | select(.Service=="dev") | .Publishers'` — yes I know this is ugly, just parse it.
- **Adhoc** (from forwarder containers): `docker ps --filter name=aidc-${SESSION}-fwd- --format '{{.Names}} {{.Ports}}'`.

Display as one block under the existing "components" output:

```
ports:
  declared:
    3000 -> dev:3000
    8080 -> dev:80
  adhoc:
    5432 -> dev:5432
```

If there are no ports at all, print `ports: (none)` or omit the block entirely — either is fine.

### `scripts/cmd-kill.sh`

Before `docker compose down`, find and remove any forwarder containers:
```bash
docker ps --filter "name=aidc-${SESSION}-fwd-" -q | xargs -r docker rm -f
```
This ensures adhoc forwards don't outlive the session.

### `scripts/cmd-restart.sh`

Same cleanup as `cmd-kill.sh` — forwards should NOT survive restart per CLI-14. After restart, the user re-adds them explicitly.

### `scripts/cmd-help.sh`

Add `proxy` to the subcommand list with a one-line synopsis.

### `tests/smoke/run.sh`

Add a new test step between current step 4 (DinD) and step 5 (proxy enforcement):

```
[X/Y] port forwarding
  - aidc proxy add <session> <PORT>
  - verify socat container exists
  - start a trivial HTTP server in the dev container, curl it from the host (via 127.0.0.1:PORT)
  - aidc proxy <session> ls shows the forward
  - aidc proxy <session> rm <PORT>
  - verify socat container is gone
  - confirm aidc status <session> also lists declared+adhoc forwards (empty/empty here)
```

Pick an obscure port range (e.g., 28000–28999) to avoid collisions with whatever might be running on the host. The host listener test is the important one — it proves the round trip works.

---

## Implementation Notes

1. **Build/run boundary.** Forwarder image is built lazily on first `add`. Don't eager-build during `aidc create` — most sessions never use it.

2. **Port spec parsing.** Use bash parameter expansion, not awk/sed. Examples:
   ```bash
   case "$arg" in
       *:*) HOST_PORT="${arg%:*}"; CONTAINER_PORT="${arg#*:}" ;;
       *)   HOST_PORT="$arg";       CONTAINER_PORT="$arg" ;;
   esac
   ```

3. **Idempotency of `add`.** If a forward already exists with the same name, `docker run` errors with "name in use." Catch that and produce a clearer message ("port 3000 is already forwarded for session foo; use `aidc proxy foo rm 3000` first").

4. **Forwarder container restart policy.** Use `--rm` (not `restart: unless-stopped`) — these are intentionally ephemeral. If socat crashes, the forward dies and the user re-creates it. This is fine because socat doesn't crash spontaneously and we don't want zombie forwards surviving the session.

5. **Network attach.** The `--network aidc-${SESSION}-net` arg lets the sidecar resolve `aidc-${SESSION}-dev` via compose's built-in DNS. No need for an explicit IP lookup.

6. **No reverse direction.** This task does NOT implement container-to-host forwarding. If we ever need it, `host.docker.internal` already works inside the dev container — no new tooling required.

---

## Anti-patterns

- **DO NOT** use Docker's `network_mode: host` for the sidecar. Breaks on macOS/Docker Desktop and pollutes the host's port table even on Linux.
- **DO NOT** use `kubectl port-forward`-style processes on the host. We don't depend on Kubernetes; sticking with `docker run` keeps the dependency surface flat.
- **DO NOT** persist adhoc forwards across `aidc restart` / `aidc kill`. Per CLI-14: "Forwards MUST NOT persist." Users re-add explicitly; this keeps the model honest about what's reachable.
- **DO NOT** auto-publish "common dev ports" (3000/8000/8080/etc.) by default. Surprise port exposure is a footgun; users opt in via `--port` or config.
- **DO NOT** add a Python or Node-based forwarder. socat is 100KB, has been there forever, and does exactly this one job.
- **DO NOT** use `alpine/socat` from Docker Hub. Per design decision, every container in the aidc stack is locally built (`aidc/*:local`) for consistency and to avoid third-party Hub dependencies.

---

## Success Criteria

- [ ] `aidc create foo --port 3000` results in `dev` service having a `ports:` block with `"3000:3000"`. `docker compose -p aidc-foo ps` shows `3000->3000/tcp`.
- [ ] `<repo>/.aidc/config.yaml` `ports: [3000, "8080:80"]` is honored on create.
- [ ] CLI-flag ports merge with config ports; conflicts (same host port) resolve to the CLI flag.
- [ ] `aidc proxy foo add 5432` creates `aidc-foo-fwd-5432`; image is built on first invocation if missing.
- [ ] HTTP server in dev container is reachable from host via `curl http://localhost:5432/` after the add (use a non-DB port for the test — 5432 is symbolic here).
- [ ] `aidc proxy foo ls` shows the forward.
- [ ] `aidc proxy foo rm 5432` removes the sidecar; `docker ps` confirms.
- [ ] `aidc proxy foo clear` removes all forwards in one shot.
- [ ] `aidc status foo` lists both declared and adhoc forwards.
- [ ] `aidc restart foo` removes adhoc forwards (verified after restart that `aidc proxy foo ls` shows none).
- [ ] `aidc kill foo` removes adhoc forwards.
- [ ] Smoke test passes 10/10 runs (taint race threshold from prior fix).

---

## Verification

```bash
# Build + create a session with one declared port
aidc create pftest --port 28080

# Inside the dev container, start a tiny HTTP server
aidc attach pftest
# (in attached tmux:)
#   python3 -m http.server 28080 &
#   exit (detach: Ctrl-b d)

# From the host, the declared port works
curl -fsS http://localhost:28080/ | head -5

# Add an adhoc forward at runtime
aidc proxy pftest add 28081
aidc attach pftest
# (in attached tmux:)
#   python3 -m http.server 28081 &
#   exit

# From the host, the adhoc port works
curl -fsS http://localhost:28081/ | head -5

# List shows both
aidc status pftest | grep -A 10 'ports:'

# Remove one
aidc proxy pftest rm 28081
aidc proxy pftest ls   # should NOT list 28081

# Clear all
aidc proxy pftest clear
aidc proxy pftest ls   # should be empty

# Cleanup
aidc kill pftest

# Smoke
make smoke              # all assertions pass
for i in $(seq 1 10); do make smoke || break; done   # 10/10 stable
```

---

## Enforcement Test Suggestions

Subagent fills this in at completion if drift potential identified. Candidates:

- [ ] Forwarder image is built locally (not pulled from Hub) — suggested test: `docker image inspect aidc/forwarder:local` succeeds; image has no remote registry tag.
- [ ] Forwarder containers always have the `--rm` flag — suggested test: inspect the forwarder container's HostConfig.AutoRemove field, assert true.
