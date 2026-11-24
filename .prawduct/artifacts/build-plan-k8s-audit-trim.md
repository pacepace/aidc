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

- (01) Kubernetes state: a claim no session uses is `kept` even without a recorded kill time
  (only `aidc kill` leaves one behind; claims killed before this change have no annotations).
  `ended` is a Docker state only.
- (01) A trim right after `aidc kill` on Kubernetes is refused while the proxy pod terminates
  (it still mounts the claim): correct, and the refusal says a killed session's pods take a
  moment. `aidc kill` was left as it is (it does not wait for pods).
- (01) The Docker trail helpers that call docker (`_aidc_audit_docker_mounts`,
  `aidc_audit_docker_remove`) are named in test-backend-confinement.sh's allow list, the way
  common.sh's Docker helpers are.
- (01) Found on the way: `make lint` and CI's shellcheck did not cover `scripts/docker/` (and
  `make lint` not `gitctl/`); both clean, now covered. test-k8s-session.sh called an undefined
  `assert_not_has`, so two of its checks never ran; defined.
- (01) The Kubernetes smoke now lists its kept claim and trims it (`AIDC_SMOKE_KEEP_AUDIT=1`
  keeps it), so smoke runs stop piling up claims. Not yet run live as a whole smoke; the same
  commands were run live by hand (below).
- (01) Live 2026-11-24, Docker (scratch audit dir only): list; dry run; no answer and `n`
  remove nothing; `y` and `--yes` remove; an unknown name removes nothing; a scratch trail with
  the folder name an existing test session's audit container mounts is refused as running; a
  trail holding a root-owned folder (plain `rm` fails) is removed through the audit image.
- (01) Live 2026-11-24, cluster: `aidc audit list` showed the six existing test claims (none
  deleted). A session made for the purpose: listed running, trim refused; after kill, the claim
  carried size 28 KB, killed-at, tainted=no; trim refused until the proxy pod was gone, then
  dry run, no answer (nothing removed), `y`: claim, its Retain volume and the provisioner's
  volume object all gone, in 1.4 s.
- (01) Timing (20 runs each, scratch audit dir of 70 trails): `aidc list` on Docker 355 → 371 ms;
  a verb that does nothing 48 → 73 ms (sourcing config.sh, one sed, one du). Kubernetes `aidc list`
  591 ms before, 580 ms after with the total cached, 831 ms on the once-a-day refresh.
