# Design 03 — Docker Isolation (DinD)

**What this covers.** How Claude inside the container can build and run Docker images for its own work without being able to touch the host's Docker daemon or any host containers. Why we run a nested Docker daemon (Docker-in-Docker) instead of mounting the host socket, why `--privileged` is acceptable here, and what the upgrade path looks like (Sysbox).

**Requirements implemented:** DKR-01 through DKR-04.

---

## The problem we're avoiding

The most common pattern for "give the container access to Docker" is mounting `/var/run/docker.sock` from the host into the container:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock   # ❌ NEVER for aidc
```

This is **catastrophic** for our threat model. The Docker daemon runs as root and trusts anything connecting to its socket. A process inside the container that can talk to the host's `dockerd` can:

- Spawn a new container with the host root filesystem mounted at `/host` and a shell — instant root on host.
- Stop / delete / modify any container on the host, including aidc's own proxy stack.
- Read any Docker secrets, image layers, or volumes the host has.

This is well-documented and not a controversial claim. The Docker daemon is a root-level API; exposing it to a sandboxed workload is the opposite of sandboxing. For aidc, this option is **off the table**.

---

## What we do instead: Docker-in-Docker

aidc uses the `ghcr.io/devcontainers/features/docker-in-docker:1` Dev Container Feature. This installs a **second**, **independent** Docker daemon **inside** the container. Claude can `docker build`, `docker run`, `docker compose up`, etc., and all of it happens inside the outer container's process tree. The host's `dockerd` is invisible and unreachable.

### What's inside, what's outside

```
HOST machine
├── dockerd  (the real one — runs aidc-foo-dev, aidc-foo-squid, etc.)
│
└── container: aidc-foo-dev
    ├── dockerd  (nested — runs Claude's test containers, build cache)
    │   ├── container: my-app-test
    │   ├── container: postgres-fixture
    │   └── ...
    ├── tmux session
    └── Claude Code
```

Two daemons. They do not share anything. From inside `aidc-foo-dev`, `docker ps` only shows containers the inner daemon manages.

---

## The `--privileged` trade-off

DinD requires the outer container to run with `--privileged`. This grants:

- All Linux capabilities (`CAP_*`)
- Access to all devices
- AppArmor / SELinux disabled for the container
- Effectively unlimited control over the container's own kernel namespace

**This is not the same as having root on the host.** A privileged container is still:

- In its own PID namespace (can't see host processes)
- In its own mount namespace (can't see host filesystems beyond what's explicitly mounted)
- In its own network namespace (subject to the proxy stack)
- Subject to the kernel's namespace isolation

A privileged container CAN, in theory:

- Load kernel modules
- Mount block devices
- Talk to kernel facilities normally hidden from containers

In practice, for aidc's threat model, `--privileged` is **acceptable** because:

1. The kernel namespace boundary still holds — the privileged container is in its own namespaces, not the host's.
2. We don't mount any sensitive host paths into the privileged container. There's nothing for it to escape *to* even if it broke out of its namespace, beyond the host repo (which Claude already has access to via the bind mount anyway).
3. The proxy stack runs in a **separate, non-privileged** Docker Compose stack alongside the dev container, with its own network namespace. A privileged dev container cannot reconfigure the proxy stack any more than a normal container can.
4. The container is ephemeral — `aidc kill` destroys it and any modifications it made to itself.

The trade-off is: yes, `--privileged` weakens the isolation between the container and the kernel below. But it does not weaken the isolation that matters for our threat model — keeping Claude from touching anything on the host other than the one mounted repo.

---

## What the inner daemon sees

The inner `dockerd` has its own:

- Storage driver (overlay2) with storage rooted at `/var/lib/docker` **inside** the outer container, not on the host (DKR-03). When the outer container dies, all inner images, containers, and volumes die with it.
- Image cache, independent from the host's image cache. First builds inside a fresh aidc session re-pull base images. (This is acceptable; the proxy stack permits Docker Hub.)
- Network bridge. Inner containers get inner-bridge IPs, totally separate from host docker networks.

Performance implications:

- First-time image pulls are slower than on the host (no shared cache).
- Disk usage of an aidc session can grow if Claude builds large images. Worth surfacing in `aidc status`.
- `docker compose up` of large stacks works but is slower than on the host. Acceptable for dev-workflow purposes.

---

## What the inner daemon CANNOT see

- Host containers (`aidc-foo-squid`, `aidc-foo-policy`, anything else running on the host)
- Host images
- Host volumes (other than the explicit bind mount of `/workspaces/<repo-name>`)
- Host networks
- `/var/run/docker.sock` (it isn't there)

Concretely: `docker ps` inside aidc shows only what Claude has started inside aidc. `docker images` shows only what Claude has built/pulled inside aidc. There is no command from inside the container that can enumerate or affect host Docker resources.

---

## Sysbox as the upgrade path (DKR-04)

`--privileged` works but is a bigger hammer than we need. Nestybox's **Sysbox** runtime is designed exactly for our use case: it provides full Docker-in-Docker (including systemd) **without** requiring `--privileged`. It does this by exposing a more nuanced set of capabilities and using user-namespace isolation.

Why we're not using Sysbox in v1:

- Adds an external dependency (`sysbox-runc`) that has to be installed at the Docker layer on the host. That's an extra setup step per host machine and we want v1's install story to be "just Docker."
- Less universal on macOS/Windows — Sysbox is primarily a Linux daemon. Docker Desktop integration is improving but isn't seamless.

When to revisit:

- If `--privileged` ever proves to be the actual weak link in a real incident.
- If a Linux-only deployment pattern emerges where install complexity is acceptable.
- If Docker Desktop adds first-class Sysbox support.

The design leaves room: the runtime is selected in `devcontainer.json` via the `runArgs` field, so switching from default-runc-with-privileged to Sysbox is a config change, not a re-architecture.

---

## Inner daemon lifecycle

The inner Docker daemon starts as part of the outer container's startup (managed by the docker-in-docker Dev Container Feature). It is up by the time Claude's tmux session is ready.

If Claude does something that crashes the inner daemon, the outer container keeps running (tmux, Claude, the shell stay alive) but `docker` commands inside fail. The inner daemon can be restarted with `sudo service docker restart` inside the container. This isn't a sandbox-escape concern; it's just a robustness concern.

---

## Things to verify in implementation

- Inner `docker ps -a` returns only what was started inside the container. (Smoke test.)
- Inner `docker volume ls` returns only inner volumes.
- Attempting to `cat /var/run/docker.sock` returns ENOENT.
- `mount | grep docker.sock` finds nothing pointing at a host path.
- The inner daemon's storage path resolves to a path inside the outer container's overlay, not a host bind.

These checks become enforcement tests for the task shard that implements this design.

---

## References

- Docker-in-Docker feature: https://github.com/devcontainers/features/tree/main/src/docker-in-docker
- Sysbox: https://github.com/nestybox/sysbox
- "Don't expose the Docker socket": https://docs.docker.com/engine/security/protect-access/
