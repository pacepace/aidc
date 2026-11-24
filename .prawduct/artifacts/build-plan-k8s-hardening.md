---
artifact: build-plan
version: 2
scope: k8s-hardening
branch: feature/k8s-git-container
base: develop
working-branches: []
last_validated: 2026-11-24
depends_on:
  - artifact: docs/requirements.md
  - artifact: docs/design-12-kubernetes.md
  - artifact: .prawduct/artifacts/plan-aidc-2.0.md
  - artifact: .prawduct/artifacts/archive/build-plan-k8s-git-container.md
governed_by:
  - artifact: project-preferences
    dispositions:
      - "bash CLI, shellcheck --severity=warning, shell tests stub docker and kubectl on PATH → conforms"
      - "no private names in the repo (cluster, nodes, domains, other projects, the testament repo URL) → conforms: every added line is grepped before commit"
      - "supply-chain cooldown (REL-09) → conforms: testament's own release is the owner's ruled exception (latest release); its build backend resolves under the cooldown on the laptop (`uv build --exclude-newer <UTC now - 14 days>`, which governs the isolated build environment; checked live: a cutoff before the backend's release makes the build fail), and its runtime dependencies install under the image's 14-day uv setting"
partition: serial, one delegate on this branch (shares scripts/k8s/ and the dev image with every chunk); the main agent runs the Critic and integrates
---

# Build Plan — Kubernetes hardening and parity (W-K1)

**Work:** `k8s-hardening` (wave W-K1 of `plan-aidc-2.0.md`) · **Branch:**
`feature/k8s-git-container` (stacked, no PR until 2.0) · **Started:** 2026-11-24

## Goals

**Response taken:** proceed, citing it. W-K1 in `plan-aidc-2.0.md` §3 names each item, its
source (H9, D8, D9, D11, P6, P9, P12, P18, #60, GIT-03 leftover, K8S-19, K8S-25, owner's
restart/upgrade list) and its "done when". Owner rulings of 2026-11-24 bind: everything ships in
2.0, nothing filed; testament tracks its latest release, is fetched on the laptop with the user's
SSH key (never gh), built into a wheel, and is optional until public (only when the config names
its repo; missing config or a failed fetch never blocks a build or upgrade, one line says so).

**Product:** cluster sessions behave and report like Docker ones: failures read as "unknown",
never as a false "no"; their squid refuses private destinations itself; size is chosen at
create; restart, upgrade and refresh work and the conversation resumes; testament is in the
session when configured; status shows a lost malware feed on both backends; a session's
`gh pr status` says when a request expired.

**Architecture (must hold):** the backend seam (dispatcher → `scripts/k8s/session-<verb>.sh`;
no docker in shared libraries, test-backend-confinement.sh); sessions' only egress is their
squid; nothing private (keys, tokens) enters an image or a session; the private testament URL
lives only in the user's config.

**Constraints:** tests are contracts (never weakened); shellcheck warning-clean; every
`tests/unit/*.sh` exits 0; live checks on the reference cluster (scratch HOME) and on Docker
from a separate checkout with a test version tag, never touching the user's images, sessions or
aidc-mcp.

**Level:** High for 01, 02, 04, 07, 08; Medium for 05 (BuildKit-free build context on both
backends, checked live) and 06 (pod replacement must keep the conversation: checked live).

## Build Chunks

### Chunk 01: failed cluster reads say "unknown" (H9)
- `scripts/k8s/session-create.sh` disk check: a failed read of the disk claim is "cannot tell"
  (dies saying the cluster did not answer), never "no disk"; same for the default-deny check and
  the "already exists" check. `scripts/k8s/session-status.sh` policy read: a failed read prints
  `egress: unknown (the cluster did not answer)`, never NOT ENFORCED; pods list says unknown too.
- Done when: unit tests with a failing kubectl stub (tests/unit/test-k8s-session.sh).

### Chunk 02: k8s session proxy is public-only (D8) and the node-rules probe (D9)
- The session squid runs with `AIDC_PUBLIC_ONLY=1` (manifests.sh); the entrypoint's message is
  generic. Relays (`--egress-tcp`, W-K2-03) are reached by the dev pod directly, not through
  squid, so public-only does not touch them; recorded in design-12.
- Done when: rendered-manifest test; k8s smoke asserts a private address answers 403 at squid;
  live probe from session root (iptables/nft in the pod's namespace; NetworkPolicy still holds)
  recorded in design-12.

### Chunk 03: W-K0 residuals named for W-K1 (P6, P9, P12, P18)
- P6: gitctl push scans the lines each pushed commit adds (diff, `--cc` for merges) for AI
  attribution, as it scans messages.
- P9: a test that gitrun's `gc --auto` packs loose objects in a private copy.
- P12: other-umask files: interactive shells in k8s sessions get umask 002 too; tidy's
  cannot-delete line says how to clear it.
- P18: image-level smoke checks: gitwc refused off Docker (k8s smoke), the sudo switch to gitwc
  works on Docker (Docker git smoke).
- Done when: unit tests plus mutations; smoke steps.

### Chunk 04: `--cpu/--memory` and limits at create (K8S-19)
- `aidc create --backend kubernetes --cpu N --memory Q [--cpu-limit N --memory-limit Q]`,
  validated as Kubernetes quantities, request ≤ limit; status shows the size.
- Done when: rendered-manifest tests; live create with a size.

### Chunk 05: testament (K8S-25, amended)
- `testament.repo` in the user's config (SSH URL). On the laptop: newest `vX.Y.Z` tag
  (`git ls-remote`, version sort), shallow clone, `uv build --wheel --exclude-newer <14 days
  ago>` (REL-09 for the build backend), cached per tag (newest three kept). The wheel
  goes into dev-base's build context on both backends (aidc rebuild, create's first build,
  aidc k8s build) and into a running session on `aidc upgrade` (docker cp / kubectl cp, then
  install). Unconfigured or no access: one line, the build/upgrade goes on.
- Amend K8S-25 ("when configured, at its latest release").
- Done when: unit tests configured / unconfigured / no-access; `testament --version` in a live
  session on both backends.

### Chunk 06: `aidc restart`, `upgrade`, `refresh` on Kubernetes
- restart: replace the dev pod (same image), wait for ready; upgrade: point the StatefulSet at
  this version's images and roll it, then testament; refresh: the refresher's one-shot refresh.
  The home claim keeps the conversation; AIDC_CLAUDE_RESUME resumes it.
- Done when: unit tests; k8s smoke restarts and upgrades a session and the conversation is
  resumed (a planted conversation makes the wrapper pass --continue).

### Chunk 07: status parity (#60) and design-12 text (D11)
- The refresher writes a feed state file (counts, last refresh, interval); `aidc status` on both
  backends reports a feed at 0 and a refresh older than two intervals. Design-12 Status/Shape.
- Done when: unit tests plus docs.

### Chunk 08: `gh pr status` shows an expired request honestly (GIT-03 leftover)
- A request with no result and no request file is "expired (requests and results are kept 30
  days)" when the session sent it more than 30 days ago, and "taken, not answered yet" before
  that (see decision 08); never "sent, not taken yet".
- Done when: a unit test.

**Type:** final — one cumulative review at the wave's end (the main agent runs it); commit
0706859 (smoke cleanup) is in its scope.

## Decisions made mid-build
- (01) `aidc user add` keeps reading the disk phase as before: a failed read there only re-applies the (idempotent) disk claim, which fails on its own if the cluster is down; nothing is mistaken.
- (02) The squid message for public-only is generic now (it serves the git proxy and k8s sessions). Measured live on the reference cluster before the squid image was rebuilt: the old message, same rules.
- (03, P6) The diff scan reads only the lines each pushed commit adds (renames followed; a merge as a combined diff, so lines merged in from another branch or origin are not the merge's own). It refuses, as the message scan does. Inferred: test data that needs such text builds it from parts (this repo's new tests do); the older tests' literal lines are already on origin and are never re-scanned. Owner can veto (it binds aidc's own development through the git container too).
- (03, P6, narrowed after the cumulative review) The first diff scan applied the commit-message patterns to file contents and so refused this repo's own policy prose (CLAUDE.md's "No `Co-Authored-By:` trailers naming Claude" line, gitctl/CLAUDE.md's rule line, the guard's own comments), AUTHORS lines crediting a person named Cody or Devin, and plain claude.ai/code links. Technical call by the main agent, owner may overrule: file contents are checked by SHAPE (gitctl_file_attribution_stream): a trailer line (optional leading space and one comment/quote marker, then Co-Authored-By: or Signed-off-by: naming an AI tool: GITCTL_AI_ID's whole words without people's first names, or an email at an AI vendor's domain), or a "Generated with <AI tool>" footer that is the whole line (optionally after the robot emoji; the tool name may be a markdown link; a sentence that goes on is prose). Prose about attribution, a bare robot emoji and claude.ai/code links pass in files; commit messages, PR text and comments keep the broad check. The scan fails closed: a commit whose added lines git cannot produce is refused, saying why.
- (03, P12) Kept the git container's rights as they are (no gitwc-like path on Kubernetes, which would let the agent act as every session's uid). Instead shells opened from outside a k8s session (kubectl exec, sudo) get umask 002 like the session's own processes, and tidy's cannot-delete line says how to clear what is left (root-owned files from inner Docker builds).
- (03, P18) Image-level checks live in tests/smoke/git.sh (`sg_part_gitwc`), run by both smokes; the k8s half was checked live against the running git container.
- (04) A request above the configured limit, with no limit flag, raises the limit to the request (asking for more than the ceiling means wanting it), and says so; a request above a limit given on the same line is refused. The config's own size values are checked the same way. Live 2026-11-24: `--cpu 3 --memory 10Gi --memory-limit 20Gi` gave the pod exactly that, and status shows it.
- (05) Config key: `testament.repo` (an ssh URL; an https or local URL is refused, since only the user's SSH key may fetch it). Newest tag by numeric vX.Y.Z order (no pre-releases). Wheels cached in `~/.cache/aidc/testament/<tag>`, so an unchanged release is not rebuilt; after a new release is cached only the newest three tags stay, and build folders an interrupted build left (over an hour old) are removed.
- (05) Ruling Q-K7's checksum clause ("verified against the release's own checksums where it publishes them") has nothing to apply to: the later SSH ruling replaced downloading a release asset with building the tag from source, and there is no checksum asset. Integrity rests on the SSH-authenticated fetch of the tag's commit from the configured repo (tags can move, so it is as good as the repo's own tag discipline). The build backend resolves under REL-09's 14-day cooldown (`uv build --exclude-newer`).
- (05) A failure note stays one line but ends with the failing step's last stderr line (ls-remote, clone, uv build), e.g. ssh's "Permission denied (publickey)." (git's generic "Could not read from remote repository" advice is skipped).
- (05) No BuildKit dependency: dev-base builds from a staged copy of its context with `testament/` filled (one helper, `aidc_build_context`, for aidc rebuild, ensure_image and aidc k8s build); `.devcontainer/testament/.gitkeep` keeps the folder the Dockerfile copies when VS Code builds it directly. An install that fails in the image build is a line, not a failed build (the ruling's "never blocks", applied to the install as to the fetch).
- (05) The running-session install goes to the session user's home (`uv tool install`, ~/.local/bin), not the image's system folders: the home survives `aidc restart` and pod replacement on Kubernetes, and a login shell (tmux, Claude) finds it first. Accepted edge: an upgrade without access leaves an older home copy in front of a newer image copy until the next upgrade with access.
- (05) The ruling says kubectl cp; the Kubernetes copy streams the wheel through `kubectl exec -i ... cat` instead (same effect, no tar needed in the image).
- (06) restart replaces the dev pod (delete; the StatefulSet makes a new one): a pod has no in-place restart. upgrade sends one strategic-merge patch to the StatefulSet: every container and init container whose image is dev-base (read from the session's own StatefulSet, not a hand list) onto this version's image, plus a `restartedAt` stamp, so a forced rebuild under the same tag is pulled too and there is one template revision; it checks the new pod (by uid, not being deleted) runs the image it asked for. A failed read of the old pod's uid stops restart and upgrade before anything changes ("the cluster did not answer"); the wait skips a pod that is being deleted; a failed read of the new pod's image is said so, never "came back on an unknown image", and testament is installed only after that check. All the tri-state reads in scripts/k8s go through one reader, `k8s_get` in lib.sh (answer, "" for not found, or return 2 with kubectl's last line). Both wait for a pod with a NEW uid to log user-main's ready marker (AIDC_K8S_READY_WAIT, default 600 s). Neither touches the proxy pod. Upgrade always rolls (no digest compare: the registry is reachable from the node, not from the laptop).
- (06) Live 2026-11-24: with a planted conversation in the session home, `aidc restart` brought a new pod in 10 s and Claude started with `--continue`; `aidc refresh` re-pulled the feeds (urlhaus and hagezi both non-zero).
- (07) The state file lives on the blocklist volume beside the list (`/etc/squid/aidc-feeds.state`) and status reads it through the refresher sidecar (`docker exec` / `kubectl exec ... -c refresher`), so the compose template needed no new mount (the issue's proposed volume change). "Stale" is a list published more than twice the refresher's own interval ago (recorded in the file); a failed refresh keeps the time the serving list was published. No state yet (first refresh running, or an older refresher image) is "unknown", never fine.
- (08) A session cannot list the request folder, only test a file by its id. A request with neither its request file nor a result is either just taken (git-requests' take() moves the request out of requests/ before it writes any result) or swept after 30 days; the premise first recorded here, that the sweep is the only thing that removes both, was false. So the stand-in decides by the session's own record of when it sent the request: "expired" only when that is more than 30 days ago, "taken, not answered yet" within it, and "unknown" (saying both are possible) when the session has no record. `gh pr status` and `gh aidc request <id>` say the same.
- (03, P12, found live) `aidc create` on Kubernetes made the session's starting folder (and the folders on the way) with umask 022 in its repo-dir init container, so the git container could not tidy there; it now makes them group-writable too. Checked live: both folders drwxrwxr-x.
- (live, 2026-11-24) Reference cluster, all images rebuilt (`aidc k8s build --force`, testament configured in the scratch config): `tests/smoke/k8s.sh` passed with no failures (squid 403s, the node-rules probe, gitwc refused, restart/upgrade with Claude resuming, testament in the session, refresh, feeds in status). Docker, from a separate checkout at v1.9.10-wk1: `tests/smoke/run.sh` passed but for two failures (the MCP version line, P21, known; `aidc upgrade` "nothing to do", fixed in 452b5bc after this run); the image has testament 0.66.0; `aidc upgrade` installed it into a session's home when the image's copy was missing, it survived `aidc restart`, and unconfigured and no-access each gave one line with exit 0.
