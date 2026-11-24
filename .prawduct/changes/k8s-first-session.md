---
schema: 1
type: feature
scope: k8s-first-session
date: 2026-11-24
title: A first Kubernetes session
---
**Why:** wave 2 of the Kubernetes backend (docs/design-12-kubernetes.md, K8S-01): sessions run on
a Kubernetes cluster with the same commands, sandboxed as on Docker.

**What:**
- `kubernetes:` config block (cluster, runtime class, storage classes, node selector and
  tolerations, registry, session size); everything cluster-specific is configuration.
- `aidc k8s check | setup | build`: check a cluster, make aidc's private in-cluster registry,
  build aidc's images in the cluster (privileged builder during builds only; socket-only Docker;
  pod-network MTU).
- `aidc user add <name>`: the user's namespace (default-deny) and shared disk.
- `aidc create --backend kubernetes`, `attach`, `list`, `status`, `logs`, `kill`: a session in the
  user's namespace (Sysbox dev pod, no DNS, its own Squid as the only way out, audit kept by
  kill); the dispatcher's `--backend` switch and session lookup; `backend:` default for create.
- The dev image's inner dockerd takes the container's MTU when it is below 1500 (unchanged on a
  plain Docker host).
- `tests/smoke/k8s.sh` (`make smoke-k8s`).

## Consumer note

New and opt-in: nothing changes for Docker sessions. To use a cluster, add a `kubernetes:` block
(README, "Kubernetes backend"), then run `aidc k8s check`, `aidc k8s setup`, `aidc k8s build` and
`aidc user add <you>`.
