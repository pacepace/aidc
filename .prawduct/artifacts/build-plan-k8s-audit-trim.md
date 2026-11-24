---
artifact: build-plan
version: 2
scope: k8s-audit-trim
branch: feature/k8s-audit-trim
base: feature/k8s-git-container
working-branches: []
last_validated: 2026-11-24
depends_on:
  - artifact: docs/requirements.md
  - artifact: docs/design-12-kubernetes.md
  - artifact: .prawduct/artifacts/plan-aidc-2.0.md
governed_by:
  - artifact: project-preferences
    dispositions:
      - "bash CLI, shellcheck, shell tests stub docker and kubectl on PATH → conforms"
      - "no private names in the repo → conforms"
partition: serial, one delegate on this branch; the main agent runs the Critic and integrates
---

# Build Plan — audit list and trim

**Work:** `k8s-audit-trim` (wave W-K6 of `plan-aidc-2.0.md`, requirement K8S-26, issue #77) ·
**Branch:** `feature/k8s-audit-trim` (off `feature/k8s-git-container`) · **Started:** 2026-11-24

## Goals

**Response taken:** proceed, citing it. K8S-26 and the owner rulings of 2026-11-24 ("aidc gets an
audit trim command" and its two refinements) say what this is for: kept audit trails pile up on
both backends; aidc lists them, removes old or named ones on request (never a running session's),
and warns on any command when they total more than 100 MB, without slowing commands.

**Product:**
- `aidc audit list`: every kept trail, Docker and Kubernetes, with session, created, killed,
  tainted, size, state and backend.
- `aidc audit trim [--older-than <age>] [<name>...] [--yes] [--dry-run]`: lists exactly what will
  go, asks before deleting unless `--yes`, refuses a running session's trail.
- The 100 MB warning: Docker measures the audit dir with `du` on every command; Kubernetes only
  during cluster commands, from a cache refreshed at most about once a day.

**Decisions (inferred, for the boundary review):**
- A `<name>` is a session name (all its trails) or one trail's id (folder or claim name). With
  both `--older-than` and names, a trail must match both. With neither, trim refuses: there is
  no "trim everything" by accident.
- Age counts from the trail's creation (meta.json `created_at`; the claim's creation time).
- Running: Docker, a trail some aidc container still mounts (the session exists, running or
  stopped); a trail with no `killed_at` while Docker cannot be asked is treated as running.
  Kubernetes, a claim a session's StatefulSet names (`aidc/audit`) or a pod mounts.
- Kubernetes trim on a Retain class: the claim's volume is first set to `Delete`, then the claim
  is deleted, so the provisioner removes the volume and its data; aidc waits for the volume to
  go and says so. If it stays (a provisioner that cannot delete), aidc names it and says its
  data is still on the storage class's backend. Released audit volumes whose claim is already
  gone are listed and trimmed the same way, so nothing piles up.
- Kubernetes size: a killed trail does not grow, so `aidc kill` records the trail's size (`du`
  in the audit sidecar after the final sweep), killed time and taint on the claim as
  annotations. List and the warning read annotations: no pod is started to measure. A running
  session's trail, or one whose final sweep did not run, shows size `?` and is not counted.
- The Kubernetes cache (`~/.cache/aidc/audit-k8s-size`) holds the time, the namespace and the
  total; refreshed with one `kubectl get pvc` when older than a day, and by `aidc audit` and
  `aidc kill` on the cluster.
- Docker trim removes a folder with `rm -rf`; when root-owned files (written by the audit
  sidecar) stop it, through a throwaway container of aidc's audit image.

## Build Chunks

### Chunk 01: list, trim and the warning on both backends

- **Deliverables:** `scripts/cmd-audit.sh`, `scripts/lib/audit.sh` (Docker trails, ages, sizes,
  the warning and its cache), `scripts/k8s/audit.sh` (claims, released volumes, trim); the
  dispatcher runs the warning; `aidc kill` on Kubernetes records the trail's size. Unit tests
  with docker and kubectl stubs: both backends, the running-session refusal, the dry run and
  confirmation, the cache and the threshold. README and docs/requirements.md (K8S-26 as built),
  change record.
- **Live:** Docker list and trim on scratch trails; cluster `aidc audit list`, and a trim of a
  claim made for the purpose (no existing claim is deleted: the owner has not yet approved H7).
  A command timed before and after the warning.
- **Type:** final

## Decisions made mid-build

(none yet)
