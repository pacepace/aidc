---
schema: 1
type: feature
scope: k8s-audit-trim
date: 2026-11-24
title: aidc audit list and trim, and the kept-audit size warning
---
**Why:** K8S-26 and the owner rulings of 2026-11-24 ("aidc gets an audit trim command" and its
refinements; issue #77): every session's audit trail outlives it on both backends, and they pile
up (hundreds of MB of folders on Docker; one claim and retained volume per session on
Kubernetes, removed by hand until now).

**What:**
- `aidc audit list`: every kept trail, Docker (folders under the audit dir) and Kubernetes (kept
  claims, and released audit volumes whose claim is gone), with session, created, killed,
  tainted, size and state, and a total per backend.
- `aidc audit trim [--older-than <age>] [<name>...] [--yes] [--dry-run]`: lists exactly what will
  go and asks first; never removes a running session's trail (Docker: one a container still
  mounts, checked again just before removal; Kubernetes: one a StatefulSet names or a pod
  mounts). A name that matches nothing, or neither an age nor a name, removes nothing. Docker
  falls back to a throwaway container of aidc's audit image for files the sidecar wrote as root.
- Kubernetes trim sets the claim's volume to Delete before deleting the claim, so the provisioner
  removes the volume and its data on a retaining class; it waits and says so, or names the volume
  the provisioner kept.
- `aidc kill` on Kubernetes records the trail's size, kill time and taint on the kept claim.
- Every command warns when the kept trails pass 100 MB: one `du` on Docker (about 15-25 ms); on
  Kubernetes only during cluster commands, from a total cached for a day (one claim list when
  stale).
- The Kubernetes smoke trims its own audit claim (`AIDC_SMOKE_KEEP_AUDIT=1` keeps it).
- `make lint` and CI's shellcheck now cover `scripts/docker/` (and `make lint` `gitctl/`).

## Consumer note

New commands; nothing to migrate. Claims kept by `aidc kill` before this change show size `?`
and count as unknown in the warning until trimmed.
