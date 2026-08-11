# task-02: Dev Container

## Objective

Build the dev container that Claude Code runs inside: pinned Ubuntu 24.04 base, the right Dev Container Features, no-credential mount discipline, tmux as the session entrypoint, and a system-level pre-push hook that hard-fails any git push attempt.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| CTR-01 | Pinned Ubuntu 24.04 base image, referenced by digest | P0 |
| CTR-02 | Configured via `devcontainer.json` | P0 |
| CTR-03 | Includes `ghcr.io/devcontainers/features/docker-in-docker:1` | P0 |
| CTR-04 | Includes `ghcr.io/devcontainers/features/git:1` | P0 |
| CTR-05 | Language runtimes selected by `profile`: python/node/go/rust/multi | P0 |
| CTR-07 | MUST NOT mount host SSH agent socket | P0 |
| CTR-08 | MUST NOT mount GitHub credentials | P0 |
| CTR-09 | MUST NOT mount `~/.docker/` or `/var/run/docker.sock` | P0 |
| GIT-03 | GitHub CLI (`gh`) MUST NOT be installed | P0 |
| GIT-05 | System-level pre-push hook hard-fails any push | P1 |
| CTR-12 | Long-lived tmux session named `main` with named windows (formerly RMT-01) | P0 |

---

## Design Context

From `docs/design-01-architecture.md`:
> The dev container is configured via `.devcontainer/devcontainer.json`...
> Profile is selected at create time: `aidc create my-session --profile python`. Profile defaults: if `--profile` is omitted, `aidc create` reads the per-project `.aidc/config.yaml`, then the global `~/.config/aidc/config.yaml`, then falls back to `multi`.

From `docs/design-02-git-isolation.md`:
> A system-level pre-push hook (`/etc/git-hooks/pre-push`) installed via `git config --system core.hooksPath` MUST hard-fail any push attempt as a belt-and-suspenders defense.

From `docs/design-06-remote-control.md`:
> By convention, the dev container's tmux session has named windows: `claude`, `shell`, `logs`. The window layout is set by the dev container's `postCreateCommand`.

---

## Files to Create

### `.devcontainer/Dockerfile`

Base on `ubuntu:24.04` pinned by digest. Find a recent digest from Docker Hub (or use a placeholder comment instructing to update — see implementation notes). Install:

- `tmux`, `git`, `curl`, `ca-certificates`, `gnupg`, `vim`, `less`, `jq`, `ripgrep`, `tree`, `procps`
- A non-root user `vscode` (UID 1000) with sudo via the common-utils feature

Set up `/etc/git-hooks/pre-push` (see content below). Do NOT install `gh`.

`ENTRYPOINT`: starts the tmux session via the post-create script (or `sleep infinity` if devcontainer.json's `overrideCommand` handles tmux startup).

### `.devcontainer/devcontainer.json`

Schema-compliant Dev Container config. Key fields:

```jsonc
{
  "name": "aidc-dev",
  "build": { "dockerfile": "Dockerfile" },
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": {
      "installZsh": false,
      "username": "vscode",
      "userUid": "1000",
      "userGid": "1000"
    },
    "ghcr.io/devcontainers/features/git:1": {},
    "ghcr.io/devcontainers/features/docker-in-docker:1": {
      "moby": true,
      "version": "latest"
    }
    // Profile-specific features added dynamically by `aidc create`; see Implementation Notes
  },
  "runArgs": ["--privileged"],
  "containerEnv": {
    "HTTP_PROXY": "http://aidc-proxy:3128",
    "HTTPS_PROXY": "http://aidc-proxy:3128",
    "NO_PROXY": "localhost,127.0.0.1"
  },
  "mounts": [
    // host repo mount is injected by `aidc create`; do not hardcode here
  ],
  "postCreateCommand": "/usr/local/bin/aidc-post-create.sh",
  "overrideCommand": false,
  "remoteUser": "vscode"
}
```

The proxy env vars use the literal hostname `aidc-proxy` — the docker-compose template (task-07) sets up a network alias for the Squid container so all dev containers see it under this name.

### `.devcontainer/post-create.sh`

This file is COPIED into the image by the Dockerfile (`COPY post-create.sh /usr/local/bin/aidc-post-create.sh`) and chmod +x. It runs once when the container is first created. Responsibilities:

1. Configure git: enable system-level pre-push hook (`git config --system core.hooksPath /etc/git-hooks`)
2. Configure DNS: write `/etc/resolv.conf` with `nameserver 9.9.9.9` and `nameserver 149.112.112.112` (override the Docker-provided one; this requires CAP_NET_ADMIN which the `--privileged` flag gives us)
3. Install Claude Code if requested (`npm install -g @anthropic-ai/claude-code` — only if `node` is in the profile; otherwise skip with a friendly notice)
4. Start the tmux session with three named windows. Use the start script below.

### `.devcontainer/tmux-start.sh`

```bash
#!/usr/bin/env bash
# Start the aidc dev container tmux session.
# Idempotent: if session already exists, attach instead of recreate.
set -euo pipefail

SESSION="main"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    exit 0
fi

tmux new-session -d -s "$SESSION" -n claude
tmux send-keys -t "$SESSION:claude" "# Claude Code window. Run: claude" C-m
tmux new-window -t "$SESSION:" -n shell
tmux new-window -t "$SESSION:" -n logs
tmux send-keys -t "$SESSION:logs" "echo 'Logs window. Tail what you need here.'" C-m
tmux select-window -t "$SESSION:claude"
```

Copy into the image at `/usr/local/bin/aidc-tmux-start.sh` (chmod +x).

### `.devcontainer/pre-push-hook.sh`

This is the pre-push hook installed system-wide. Hard-fail any push:

```bash
#!/usr/bin/env bash
# aidc system pre-push hook: blocks all push attempts inside the container.
echo "aidc: git push is disabled inside the dev container." >&2
echo "aidc: review and push from the host machine." >&2
exit 1
```

The Dockerfile copies this to `/etc/git-hooks/pre-push` and chmod +x.

### Profile feature snippets

Profile-specific features are picked up by `aidc create` (task-08) by reading a JSON file per profile. Create:

`.devcontainer/profiles/python.json`:
```json
{ "ghcr.io/devcontainers/features/python:1": { "version": "3.12" } }
```

`.devcontainer/profiles/node.json`:
```json
{ "ghcr.io/devcontainers/features/node:1": { "version": "22" } }
```

`.devcontainer/profiles/go.json`:
```json
{ "ghcr.io/devcontainers/features/go:1": { "version": "1.23" } }
```

`.devcontainer/profiles/rust.json`:
```json
{ "ghcr.io/devcontainers/features/rust:1": { "version": "stable" } }
```

`.devcontainer/profiles/multi.json`: an object that merges all four of the above.

`aidc create` reads the chosen profile JSON and merges it into `devcontainer.json`'s `features` field at render time.

---

## Implementation Notes

1. **Base image digest pinning**: At time of writing, `ubuntu:24.04` resolves to a digest like `sha256:...`. The Dockerfile should reference `ubuntu:24.04@sha256:<digest>`. If you can resolve a current digest at implementation time (e.g., via `docker pull` then `docker inspect`), use it. Otherwise leave a comment: `# TODO(pin): replace with current sha256 digest before merge`.

2. **No GitHub CLI**: The `git:1` Dev Container Feature does NOT install `gh` (that's a different feature, `github-cli:1`, which we deliberately omit). Do not add it.

3. **resolv.conf override**: Docker normally overwrites resolv.conf on container restart. Setting it in post-create is a one-time write that survives until the next Docker restart. The compose template (task-07) ALSO sets DNS via `dns:` array; that's the durable mechanism. Post-create is belt-and-suspenders.

4. **tmux session lifecycle**: The container's main process needs to stay alive. Two options:
   - Set the container CMD to `tmux new-session -d -s main && tail -f /dev/null` (tmux as background, main process is tail)
   - Or run `tmux -CC` attached
   The simpler/more robust choice is the former. Use that.

5. **Pre-push hook scope**: `git config --system core.hooksPath` writes to `/etc/gitconfig`. Confirm this is a global effect for all users in the container, not just `vscode`.

6. **Claude Code install**: Only when `node` is in the profile. The post-create script checks for `npm` and skips quietly if absent.

---

## Anti-patterns

- DO NOT mount `~/.ssh/`, `~/.gitconfig`, or `~/.docker/` — defeats the isolation
- DO NOT install `gh` CLI — explicit requirement (GIT-03)
- DO NOT use `latest` tags on the base image — must be digest-pinned (CTR-01)
- AVOID making the container run as root — use the `vscode` user from common-utils
- AVOID baking the host repo path into devcontainer.json — that's per-session, injected at create time

---

## Success Criteria

- [ ] `.devcontainer/Dockerfile` exists, references `ubuntu:24.04` (digest-pinned or TODO-noted)
- [ ] `.devcontainer/devcontainer.json` exists with the three required features (common-utils, git, docker-in-docker)
- [ ] `.devcontainer/post-create.sh` is executable, configures git system hooks path, writes resolv.conf, starts tmux
- [ ] `.devcontainer/tmux-start.sh` creates a session named `main` with windows `claude`, `shell`, `logs`
- [ ] `.devcontainer/pre-push-hook.sh` exits non-zero unconditionally
- [ ] `.devcontainer/profiles/*.json` exist for python, node, go, rust, multi
- [ ] `gh` is NOT installed in the Dockerfile
- [ ] No mounts in devcontainer.json (host repo and audit mounts come at runtime from the compose template)
- [ ] Image builds without error: `docker build -t aidc-dev-test .devcontainer/` succeeds

---

## Verification

```bash
# Lint Dockerfile
docker build -t aidc-dev-test -f .devcontainer/Dockerfile .devcontainer/

# Verify pre-push hook exits non-zero
docker run --rm aidc-dev-test bash -c '/etc/git-hooks/pre-push' ; echo "exit=$?"
# Expected: exit=1 (the script exits 1)

# Verify gh is NOT installed
docker run --rm aidc-dev-test bash -c 'command -v gh' ; echo "exit=$?"
# Expected: exit=1 (no gh)

# Verify tmux-start.sh creates the right windows
docker run --rm aidc-dev-test bash -c '/usr/local/bin/aidc-tmux-start.sh && tmux list-windows -t main'
# Expected: three lines for claude / shell / logs

# Verify post-create wires the system hook path
docker run --rm aidc-dev-test bash -c '/usr/local/bin/aidc-post-create.sh && git config --system --get core.hooksPath'
# Expected: /etc/git-hooks
```

---

## Enforcement Test Suggestions

After completing this task, consider whether enforcement tests are needed for:

- [ ] No GitHub-credential mounts ever added to devcontainer.json — suggested test: grep for SSH/gh/docker.sock mount paths in devcontainer.json
- [ ] Pre-push hook script always exits non-zero — suggested test: shellcheck + a unit test that runs it and asserts exit code
- [ ] Base image is always digest-pinned, never tag-only — suggested test: grep Dockerfile for `:latest` or unpinned references

These suggestions are not implemented automatically; they're flagged for review.
