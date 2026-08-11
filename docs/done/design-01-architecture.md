# Design 01 — Container Architecture

**What this covers.** The dev container's base image, Dev Container Features, mount rules, language-runtime profiles, and how the architecture varies (or doesn't) across macOS, Linux, and WSL2. Sibling docs cover proxy stack (`design-04`), CLI (`design-05`), and safety model (`design-07`).

**Requirements implemented:** CTR-01 through CTR-11.

---

## Overview

The dev container is a single Docker container running:

- A long-lived tmux session (entry point) — see `design-06-remote-control.md`
- Claude Code, invoked inside tmux in `--yolo` mode
- A nested Docker daemon (DinD) — see `design-03-docker-isolation.md`
- The user's repo, bind-mounted from the host

Everything else (proxy, refresher, policy, audit) lives in a sibling Docker Compose stack — see `design-04-proxy-stack.md`.

The dev container is fully ephemeral. State that needs to survive a session lives in the host-mounted repo. The container itself can be killed and recreated at any time without losing real work.

---

## Base image

- **Distro:** Ubuntu 24.04 LTS (Noble Numbat)
- **Reference:** version-tagged (`ubuntu:24.04`) in the `Dockerfile`. `:latest` is forbidden. Digest pinning + a 30-day holdback (via Renovate's `minimumReleaseAge`) is P2 future work — keeps v1 simple while leaving the path open.
- **Why Ubuntu 24.04:** broad Dev Container Feature support, current LTS, matches what most Claude-Code-friendly Dockerfiles assume.

The `Dockerfile` lives in `.devcontainer/Dockerfile`. It is intentionally minimal — most capability comes from Dev Container Features, not the base image.

---

## Dev Container Features

Configured in `.devcontainer/devcontainer.json`:

| Feature | Purpose |
|---------|---------|
| `ghcr.io/devcontainers/features/docker-in-docker:1` | Nested Docker daemon (CTR-03, DKR-01) |
| `ghcr.io/devcontainers/features/git:1` | Full local git capability (CTR-04, GIT-01) |
| `ghcr.io/devcontainers/features/common-utils:2` | Standard dev shell, sudo wiring, ZSH if desired |
| Language features per profile | See "Profiles" below |

All feature versions are pinned by the feature's own version major (e.g., `:1`), and locked further by the Dev Container Features lockfile mechanism where the spec supports it.

---

## Profiles

A **profile** selects which language runtimes are installed in the container. Profiles exist so the container isn't bloated with toolchains the project doesn't need.

| Profile | Features added |
|---------|----------------|
| `python` | `ghcr.io/devcontainers/features/python:1` (pinned), `poetry` via post-create |
| `node` | `ghcr.io/devcontainers/features/node:1` |
| `go` | `ghcr.io/devcontainers/features/go:1` |
| `rust` | `ghcr.io/devcontainers/features/rust:1` |
| `multi` | All four of the above |

Profile is selected at create time:

```
aidc create my-session --profile python
```

The profile choice is recorded in the session's metadata so `aidc status` and `aidc logs` can show it.

Profile defaults: if `--profile` is omitted, `aidc create` reads the per-project `.aidc/config.yaml`, then the global `~/.config/aidc/config.yaml`, then falls back to `multi`. (CLI-11)

---

## Mounts

The container's mount surface is deliberately tiny:

| Path | Source | Mode | Purpose |
|------|--------|------|---------|
| `/workspaces/<repo-name>` | Host repo dir | `rw` | The repo Claude works in (CTR-06) |
| `/var/aidc/audit` | `aidc-audit` named volume | `rw` | Shared with audit aggregator sidecar |
| `/var/aidc/state` | `aidc-state` named volume | `ro` | Taint flag readable here |

Explicitly **NOT** mounted (CTR-07, CTR-08, CTR-09):

- `~/.ssh/`
- SSH agent socket (`$SSH_AUTH_SOCK`)
- `~/.gitconfig` (a clean `.gitconfig` is generated post-create; user's host one is not exposed)
- `~/.config/gh/`
- Any GitHub Personal Access Tokens or credential files
- `~/.docker/`
- `/var/run/docker.sock`
- `~/.aws/`, `~/.kube/`, or other cloud-credential paths

Rationale: the goal is git-local-only (`design-02`) and no-host-Docker-access (`design-03`). The way to achieve both is to deny credentials and sockets at the mount layer rather than try to neutralize them post-mount.

---

## Network configuration

The dev container is configured to use Squid for HTTP/HTTPS egress and Quad9 for DNS:

- `HTTP_PROXY=http://aidc-<session>-squid:3128`
- `HTTPS_PROXY=http://aidc-<session>-squid:3128`
- `NO_PROXY=localhost,127.0.0.1` (anything the container talks to internally; the inner Docker daemon, etc.)
- `/etc/resolv.conf` overridden to point at Quad9 (`9.9.9.9`, `149.112.112.112`)

These are baked into the container at create time. See `design-04-proxy-stack.md` for the full proxy stack.

---

## Lifecycle

A session goes through three states:

1. **Created** — `aidc create <name>` builds the image (if needed), starts the proxy stack first, then starts the dev container, then runs `postCreateCommand` to seed tmux and Claude Code.
2. **Running** — tmux session is up; Claude is either active inside it or idle waiting for input. Pace can `aidc attach <name>` at any time.
3. **Killed** — `aidc kill <name>` stops the dev container and the proxy stack, removes both, and (by default) preserves the audit volume on the host for later review.

Tainted sessions (`design-07-safety-model.md`) can only exit running state via kill — there is no rehabilitation.

---

## Cross-platform considerations

| Platform | Notes |
|----------|-------|
| **macOS (Docker Desktop)** | Docker runs inside a Linux VM managed by Docker Desktop. DinD with `--privileged` works. File system bind mounts go through the Docker Desktop file-sharing layer; performance is acceptable for typical dev work but not for heavy IO. `HTTP_PROXY` env var semantics are standard. |
| **Linux (native Docker)** | Best performance. DinD with `--privileged` works natively. No Docker-Desktop layer in the way. Default platform for development of aidc itself. |
| **Windows / WSL2** | The aidc CLI runs inside WSL2; Docker Desktop integrates with WSL2 natively. From aidc's perspective, this looks identical to Linux. The path-translation for `--repo PATH` must handle WSL2 paths (`/mnt/c/...`) — see `design-05-cli.md`. |

No platform-specific code paths are expected in the container itself. All variance is handled in the CLI layer (`design-05-cli.md`).

---

## Things deliberately not in the dev container

- **GitHub CLI (`gh`)** — see GIT-03. Even installed, `gh` requires a token, which we don't mount. Belt-and-suspenders: don't install it at all.
- **AWS / GCP / Azure CLIs** — not part of the v1 profile. Projects that need cloud access can add them via post-create scripts, but the container does not provide credentials.
- **VS Code Server** — not assumed. aidc is for headless Claude Code execution, not interactive IDE work. (Users who want VS Code attach can still use Dev Containers' VS Code support orthogonally.)
- **Anything that needs `/var/run/docker.sock`** — DinD only.

---

## References

- Dev Containers spec: https://containers.dev/
- Dev Container Features: https://containers.dev/features
- Ubuntu 24.04 image: https://hub.docker.com/_/ubuntu
