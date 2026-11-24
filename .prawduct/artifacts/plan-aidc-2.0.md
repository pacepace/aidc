# aidc 2.0: coverage map, wave plan and decisions

Written 2026-11-24 against `feature/k8s-git-container` @ 9af86ba (clean tree; a Critic round is
running on it). Sources: `docs/requirements.md`, `docs/design-12-kubernetes.md`,
`docs/design-13-3tears-tools.md`, `.prawduct/owner-rulings.md` (through "Everything ships in
2.0"), `.prawduct/.handoff-notes.md`, the three build plans, `.prawduct/changes/*`,
`docs/security-model.md`, `.prawduct/backlog.md` (empty), `gh issue list -R pacepace/aidc`
(8 open), and the code. Status was checked against code, not only against plan text.

Scope (owner, 2026-11-24): 2.0 = the whole Kubernetes program + the 3tears adoption, released
together. Nothing may be deferred to a backlog item or a later release. Below, every leftover is
put in a wave. Where something stays a recorded residual, the wave says so and asks the owner to
accept it in writing. That is a decision, not a deferral.

Status key: **LIVE** = done and checked live · **DONE-UNLIVE** = done, not checked live ·
**PARTIAL** · **NOT STARTED**.

---

## 1. Requirements coverage

### K8S

| ID | Status | Evidence | What is missing |
|---|---|---|---|
| K8S-01 second backend, same commands + MCP | **PARTIAL** | dispatcher `scripts/aidc` L77-148; `scripts/k8s/session-{create,attach,kill,list,logs,status,where}.sh`; `mcp/src/aidc_mcp/backend.py` is Docker-only (`is_kubernetes` is only used to refuse `--repo`, tools.py L3268) | The MCP server cannot reach cluster sessions at all (no kubectl backend, no kubectl in the image). CLI verbs with no k8s version: `restart`, `upgrade`, `egress`, `proxy` (ad-hoc ports), `refresh`, `network`, `clean-env`, `claude-token` (the dispatcher says "not available on the kubernetes backend yet"). Create refuses `--port --dns --network --egress-tcp --gpu` and any unknown flag (`session-create.sh` L44). |
| K8S-02 per-user disk | **LIVE** | `scripts/k8s/user-add.sh`; smoke `tests/smoke/k8s.sh` L214 (the disk outlives the session); wave 2 chunk 03 live | The registry PVC on the owner's cluster is still on the scratch class "while testing" (handoff). That is an ops item, see W-K7. |
| K8S-03 own worktree (amended: the session makes it) | **LIVE** (amended form) | create refuses `--repo` (`session-create.sh` L40); `aidc repo add` live; smoke L98 | Nothing in code. Session instructions on where repos live and how to name worktrees are not checked by a live session agent. |
| K8S-04 only the git container pushes; one gh login | **DONE-UNLIVE** for GitHub; refusals and token isolation LIVE | `gitctl/`, `scripts/{k8s,docker}/git-*.sh`; plan (02)-(07); k8s smoke 61/61, Docker smoke 151/152 | A real push, PR or merge with a login was never run (gated `AIDC_SMOKE_GIT_REPO`). The identity file has not been seen live. |
| K8S-05 git mode ask..rules, per-session | **LIVE** (without a login) | `git-requests.sh`; `aidc git mode`; plan (04), (05), (07) live notes | With a login: an approve that really pushes. |
| K8S-06 orchestrator approves via the user's MCP | **PARTIAL** | Docker: the transcript mirror reaches the MCP (plan (07); a planted transcript was parsed) | Docker: a real question from a logged-in agent was never answered by `session_send`. The MCP's notes doubt that the AskUserQuestion widget takes paste+Enter. Kubernetes: nothing. Needs K8S-07. The ruling makes this a 2.0 ship blocker. |
| K8S-07 per-user MCP server in the cluster | **NOT STARTED** | none (no manifest, no k8s backend.py) | Everything. See W-M1..M5. |
| K8S-08 git container deletes merged, flags the rest | **DONE-UNLIVE** (GitHub side) | `gitctl tidy`, `delete-branch`; local tidy LIVE (plan (04), (07)) | `delete-branch` on GitHub, and tidy after a real merge. |
| K8S-09 VS Code attached to a pod with the disk | **NOT STARTED** | none | Design is not settled (§3, Q-K4). |
| K8S-10 Docker in sessions, no privileged mode | **LIVE** | smoke L118-132; Sysbox pod, MTU | none |
| K8S-11 GPU only with `--gpu` | **NOT STARTED** | `--gpu` refused | A `nvidia.com/gpu` limit when asked for, and a live `nvidia-smi` in a session. Needs the GPU node to be free. |
| K8S-12 egress only via own Squid; no DNS, no SA token | **LIVE** | `manifests.sh`; smoke L111-115 | none |
| K8S-13 no reach to MCP, git, API, nodes, LAN, VPN, except the taint webhook | **PARTIAL** | NetworkPolicy LIVE (design-12 table); git pod measured | (a) The one allowed path, policy sidecar to the per-user MCP taint webhook, does not exist (no MCP). (b) Design-12 "still to check": the session Squid's own deny of private destinations. `AIDC_PUBLIC_ONLY=1` exists now but only the Docker git proxy uses it. The k8s session proxy does not (manifests.sh L372). (c) "A root process in a Sysbox session cannot change node-side rules" has not been measured. |
| K8S-14 port tunnel with the user's credentials | **NOT STARTED** | `--port` refused; no `aidc proxy` on k8s | `kubectl port-forward` with reconnect, from create and from `aidc proxy`. Issue #74 is related: status does not list forwarded ports. |
| K8S-15 LAN Ingress at `<session>-<user>.<domain>`, optional login | **NOT STARTED** | none | Ingress, wildcard certificate, ingress NetworkPolicy, removal at kill, optional login. The login mechanism is not settled (Q-K5). |
| K8S-16 Claude login once per user | **NOT STARTED** (only the fallback, by hand) | k8s sessions get no credential (`manifests.sh` sets only `CLAUDE_CONFIG_DIR`). `aidc claude-token`'s long-lived token is not wired to k8s. | The broker (design-12) and how accounts are added. Today each k8s session needs its own `/login`. |
| K8S-17 account switch with no loss; cycle; per-account threshold | **NOT STARTED** | design only (measured rename swap) | The broker, statusline usage wrapper, `StopFailure` hook, `claude_accounts` config, auto/wait setting. Open item: behaviour at real token expiry. |
| K8S-18 one history per repo, Syncthing | **NOT STARTED** | design only | A Syncthing pod, the laptop side, Mac alias reconciler, lease. As built, each session has its OWN home claim, so its `projects/` is per session, not per repo. That conflicts with the design (Q-K2). |
| K8S-19 2/8Gi guaranteed, burst 16/32Gi, settable at create | **PARTIAL** | defaults from config (`scripts/k8s/lib.sh` L112-115, `manifests.sh` L474) | Not settable at create (`--cpu/--memory` refused as unknown flags). |
| K8S-20 `aidc user add` | **LIVE** (admin half) | `user-add.sh`; plan wave 2 chunk 03 | The user's own Claude accounts depend on K8S-16. Per-user cluster credentials (RBAC) are not built: the CLI uses the admin kubeconfig (wave 2 tradeoff). K8S-14 says "the user's own cluster credentials" (Q-K6). No second user has been added live. |
| K8S-21 drive from any machine | **DONE-UNLIVE** | `session-where.sh` (lookup by label) | Live: create on one machine, attach from a second one. |
| K8S-22 come back after a node reboot | **DONE-UNLIVE** (by construction) | StatefulSet + claims; `AIDC_CLAUDE_RESUME=true` | No reboot test. The registry must be up before pulls (imagePullPolicy Always plus a registry on the same node: ordering after a reboot is unproven). The taint claim survives. |
| K8S-23 check protections, offer them | **DONE-UNLIVE** | `gitctl protection/protect`; first-push marker (plan (04)) | Live with a login (`AIDC_SMOKE_GIT_PROTECT=1`). |
| K8S-24 hard rules in code | **LIVE** for refusals | gitctl fixed verbs; plan (02) live in pod | Residuals listed in §2 (R-G*) need the owner's acceptance. |
| K8S-25 testament in sessions, pinned | **NOT STARTED** | `git grep testament` is docs only | Install (release binary, pinned, checksum, 14-day cooldown) in the dev image, plus a smoke check. Needs its release source/URL (Q-K7). |
| K8S-26 audit list/trim + 100 MB warning | **NOT STARTED** | no `cmd-audit.sh`; issue #77 | All of it, on both backends. |

### GIT (touched by the git container)

| ID | Status | Evidence | Missing |
|---|---|---|---|
| GIT-01 | LIVE | sessions commit in worktrees (smoke/git.sh) | none |
| GIT-02 push/pull/fetch fail in sessions | LIVE | `git-remote-aidc.sh` pushInsteadOf; pre-push hook | Fetch over https still works in sessions by design (public repos through Squid). That is not a change: GIT-02 has always said "fail", so the owner should confirm fetch stays allowed (it was so before k8s too). |
| GIT-03 (amended) gh stand-in | LIVE | `.devcontainer/gh-standin.sh` | `gh pr status` shows a request whose files the 30-day sweep removed as "sent, not taken yet" (handoff chunk-04 leftover, still in code L313). `/prawduct:pr` run end to end in a session (it pushes before `gh pr create`) has not been checked live. |
| GIT-04/05 | LIVE | | none |
| GIT-06 host keeps full git | LIVE | | none |

### MCP (touched by K8S-07 and by the 3tears rebuild)

| ID | Status for 2.0 | What 2.0 must do |
|---|---|---|
| MCP-01/04 server, Streamable HTTP | done on Docker | Keep it through 3tears-mcp (local face). |
| MCP-02 one global instance per host | **conflicts** with K8S-07 (one per user in the cluster) | Amend: one per host on Docker, one per user on Kubernetes. |
| MCP-03 Docker container + `aidc mcp start/stop/...` | Docker only | Amend for a k8s Deployment. `aidc mcp` gains a k8s form (or `aidc mcp setup` per user). |
| MCP-05/06 token at `~/.config/aidc/mcp-token` | Docker only | In the cluster: a Secret in the user's namespace. Rotation restarts the Deployment. The user's machines fetch it with their kubeconfig. |
| MCP-07 progress | done (as `ctx.info`) | Upstream 3tears-mcp items 1-2. Mesh behaviour is open (design-13 Q1). |
| MCP-08 tool surface | done | Re-published as namespaced `aidc.*` names (breaking), regenerated `published-tools.json`. |
| MCP-09 resources | done | design-13 is self-contradictory: the mapping table says "drop at the major version", while the owner ruling and "Work" step 3 say keep them via upstream resources (item 4). Fix design-13 to "keep". |
| MCP-10/11 bind address | Docker only | Cluster: how the orchestrator reaches the per-user MCP is NOT designed (Q-M1). |
| MCP-12 sessions can't reach the MCP | done on Docker | On k8s, NetworkPolicy plus the taint-webhook exception (K8S-13). |
| MCP-13 tools shell out to the `aidc` CLI | done | The in-cluster MCP needs the CLI, kubectl, yq and in-cluster RBAC (Q-M2). |
| MCP-14 access log file | done | Kept as a file sink under 3tears-observe. In-cluster: on a claim. |
| MCP-15..19, 23-26, 28-30, 33-37, 40-45 delivery, queues, turns | done (Docker) | Carried through the service split (design-13 step 2), with behaviour preserved. In-cluster: transcripts must reach the MCP pod (Q-M3). State must be on a claim. |
| MCP-20 no "claude" in names | done | Namespacing keeps it. |
| MCP-21 dynamic descriptions + `tools/list_changed` | done | Same contradiction as MCP-09: keep, via upstream stateful mode (item 5). |
| MCP-22 descriptions for small models | done | Carried over verbatim. |
| MCP-27, MCP-39 the old orchestrator config name keys | done | Renamed to `orchestrator.*` on `chore/coordinator-naming` (unmerged). Fold into 2.0. |
| MCP-31 scope env var | done | Kept. On a mesh: grants plus the env var (design-13 table). |
| MCP-32 error codes | done (envelope) | Become real protocol codes (upstream item 3). |
| MCP-38 session_create opt-in + path check | done (Docker). On k8s it refuses repo/workspace (plan (03, Critic)) | In-cluster create via the CLI, under RBAC (Q-M2). |
| MCP-43 invoke cancellation | done | Kept local via the call context (upstream item 1). Mesh: async only (design-13). |
| new: 3tears adoption | **no requirement IDs exist** | Requirements Precede Code: write MCP-46.. (or `TRS-NN`) for local mode, mesh mode, observe, namespaced names, error model, packaging before building (W-T0). |

---

## 2. Every leftover, mapped to a wave

Wave codes are defined in §3.

### From `.prawduct/.handoff-notes.md`

| # | Item | Wave |
|---|---|---|
| H1 | Chunk 06 cumulative Critic round (forced, owner-approved), running now | W-K0 |
| H2 | Owner logs in (`aidc git login`, git agent's Claude) for the gated smoke parts | W-K0 (owner) |
| H3 | Live: a logged-in git agent's question reaches an orchestrator, and `session_send` answers an AskUserQuestion (Docker) | W-K0 |
| H4 | Smokes' GitHub part on a scratch repo (push, PR, merge, tidy, protect) | W-K0 |
| H5 | macOS: Docker git container volume ownership and the mount check | W-K0 (owner's Mac) |
| H6 | the old orchestrator config name still in 41 files; rename belongs with `chore/coordinator-naming` | W-N |
| H7 | Owner OK to delete test audit claims: seam1/2/3-audit, smoke-*, locktest-audit-20261124083532, bundletest-audit-20261124085514, c3fix-audit-20261124091751, ch04-audit-20261124101744, c5mode-audit-20261124115121, smoke-528025-audit-20261124134734 (claim, PV, dataset; Retain class) | W-K7 (owner), and done by hand with `aidc audit trim` once W-K6 exists (uses the new command for real) |
| H8 | The owner's `~/.config/aidc/config.yaml` must rename the old orchestrator config name` → `orchestrator:` before an aidc-mcp built with the rename restarts | W-N (owner) |
| H9 | Wave 2 leftover: `session-create.sh` L68 reads a failed cluster read as "no disk"; `session-status.sh` L33 reads it as "NOT ENFORCED" (verified in code) | W-K1 |
| H10 | Wave 2 leftover: the first-session plan repeats its two chunk-05 paragraphs and has a stale "same scripts" line | W-R (archive plans) |
| H11 | Wave 2 leftover: the audit sidecar fix is proven only on k8s; Docker needs `aidc rebuild` + `make smoke` | W-R (release smoke) |
| H12 | `build-plan.md` (wave 1) is still `lifecycle: active`; archive it | W-R |
| H13 | Norm ratification (prawduct `norm-registry-unratified`), parked "after the Kubernetes work"; learnings corpus over its limit | W-R (governance close-out) |
| H14 | Live objects on the cluster: registry PVC on the scratch class; `aidc-probe` namespace | W-K7 (owner) |
| H15 | Merge-into-develop question unanswered (stack waves on `feature/k8s-git-container`) | W-R (asked only at release; §3) |

### From the plans' "Decisions made mid-build" and Critic observations

| # | Item | Wave |
|---|---|---|
| P1 | (03) MCP `session_create` on kubernetes refuses repo; `mcp_server` at create and every other session tool on k8s are "aidc 2.0's" | W-M2 |
| P2 | (05) No `aidc send` CLI; MCP session tools on k8s → the git agent's question reaching an orchestrator | W-M3 |
| P3 | (07) `session_send` may not answer the AskUserQuestion widget by paste+Enter | W-K0 (check). If it fails: W-M3 adds a way to answer (Q-M5) |
| P4 | (02) Residual: the agent's own git can move refs and write objects | W-K0: owner accepts as residual (R-G1) |
| P5 | (02) gh holds the token in memory; nothing may run code as gitcred | R-G2, accept (W-K0) |
| P6 | (02) A commit's diff is not scanned for attribution; the attribution list is a list of names | R-G3: owner decides whether 2.0 adds a diff scan (cheap: `git diff` text through `gitctl_attribution` at push) or accepts. Recommend: add it in W-K1 |
| P7 | (02)/(04) A fine-grained token without admin scope + branch protection as backstop | Documented. W-K0 live protect |
| P8 | (03) Residual: session-written working-copy config can steer the agent's own git (uid 2000; gitwc on Docker) | R-G4, accept (W-K0) |
| P9 | (03) `gc --auto` in private copies is not proven to pack in a test | W-K1 (a test with enough loose objects, or a live check) |
| P10 | (03, Critic) Residual: busybox `find -delete` could be redirected by a mid-walk symlink swap (reach: the user's disk) | R-G5, accept (W-K0) |
| P11 | (04) Filters: a driver added between the read and the call | R-G6, accept (W-K0) |
| P12 | (04) `cannot-delete` for files made with another umask (kubectl exec shells, Docker-in-session builds) | W-K1: decide whether the git agent may fix group-write through a gitwc-like path on k8s. Otherwise accept |
| P13 | (04, Critic) tidy: a path component swapped between the check and `worktree remove` | R-G7, accept |
| P14 | (04, Critic) Residual: the agent can sudo to gitcred's PR verbs on any repo | Closed (06, cumulative Critic): gitcred asks gitrun `has-copy` itself before any gh call that names a repo |
| P15 | (05) Per-session mode can only loosen; `mode <s> ask` under rules is refused (the plan says "owner may want it otherwise") | Closed (06, cumulative Critic): per the 2026-11-23 ruling both ways; every mode decision is keyed on the session's registered token |
| P16 | (05) Residuals: a line pasted while the user types joins their text; a request answered outside the question waits for the next look | R-G9, accept, or W-M3 if the orchestrator answer path changes |
| P17 | (05, Critic) `Bash(git *)` allow list is a courtesy; only the instructions stop self-approval; prawduct skills kept out only by CLAUDE.md | R-G10/11/12. Owner accepts, or 2.0 adds an approval binding (e.g. `git-requests approve` requires a nonce shown only in the user's terminal or MCP answer). Recommend asking (Q-K8) |
| P18 | (07, Critic) Off-Docker gitwc refusal and the sudo switch reached only in the installed image (no unit test) | Live-checked in chunk 06. W-K1 adds an image-level test in the smoke |
| P19 | (07) A host user whose uid is not 1000 has the same mismatch Docker sessions already have | Accept (pre-existing Docker behaviour), stated in README. W-K0 owner OK |
| P20 | (07) No device+inode recorded at `repo add` | Accepted by Critic reasoning; owner OK in W-K0 |
| P21 | (06) Docker smoke 151/152: the version-tag artifact (MCP reports pyproject's version) | W-R: fix the smoke so a test tag also sets the MCP version, or compare to pyproject. No weakening of the test |
| P22 | (06) Older runs' empty transcript folders on the owner's machine | W-K7 (owner: delete by hand) |
| P23 | (06) Claude part of the smoke automated only up to the question; the answer is by hand | W-M3 makes it automatic once the answer path is known |
| P24 | Wave 2 tradeoff: taint response is record-and-report only on k8s ("before any untrusted workload") | W-K4 (taint freeze) |
| P25 | Wave 2 tradeoff: the CLI uses the user's own (admin) kubeconfig; per-user RBAC "with `aidc user add`'s second half" | W-K5 (Q-K6) |
| P26 | Wave 1: `file_put` overwrite fails in Ubuntu 26.04 sessions (issue #76) | W-T3 (it is an MCP tool being rebuilt). Fix it before then if it bites |

### From design-12 "Open items" and "Still to check"

| # | Item | Wave |
|---|---|---|
| D1 | Session behaviour at real access-token expiry with no refresh token (hours) | W-K3 (broker) |
| D2 | Syncthing in a pod, paired with a laptop | W-K3b |
| D3 | Mac alias symlinks: purge, retention, `/resume` picker, long hashed names | W-K3b (owner's Mac) |
| D4 | Git agent's question answered by `session_send` (Docker) | W-K0 |
| D5 | Git agent's question reaching an orchestrator on k8s ("owner ruling; 2.0's per-user MCP"): settled by the 2026-11-24 ruling (must route before 2.0 ships) | W-M3 |
| D6 | Real push/PR/merge/tidy/protect | W-K0 |
| D7 | Docker git container on macOS | W-K0 |
| D8 | Squid's own deny of private destinations on k8s sessions (defence in depth) | W-K1: set `AIDC_PUBLIC_ONLY=1` on the k8s session proxy (done). `--egress-tcp` relays (W-K2-03) are planned to be reached by the dev pod directly, by their own egress rule, not through squid, so they need no squid allow; W-K2-03 checks it |
| D9 | A root process in a Sysbox session cannot change node-side NetworkPolicy rules | W-K1 (live probe: iptables/nft from session root) |
| D10 | Design-12 header "Status" is stale (says the git container is not built) | Closed (06, cumulative Critic) |
| D11 | Design-12 "Shape" tree still marks git container/aidc-mcp/syncthing "(later)" | W-K1 docs (and finished as each is built) |

### Open GitHub issues

| Issue | Belongs to | Wave |
|---|---|---|
| #77 audit list/trim + warning | K8S-26 | W-K6 |
| #76 `file_put` overwrite fails | MCP tool (rebuilt in 2.0) | W-T3 |
| #74 status 'declared: (none)' for dfwd-published ports | ports (Docker side of K8S-14 parity) | W-K2: fix with the port work, so `aidc status` lists ports right on both backends |
| #60 status does not show a lost malware feed | both backends' status (k8s smoke already asserts the feeds) | W-K1 (status parity) |
| #35 symlink in bridged memory dir can leak host files | Syncthing syncs `projects/`, so the same symlink risk is cross-machine | W-K3b: must be settled there (a synced memory dir is the bridge's case, multiplied). Its stage is `design` |
| #72 share_plugins EROFS, #73 container_only_paths slug, #55 /tmp root-owned after reboot | Docker host bridge, not Kubernetes or 3tears | Not 2.0 scope under the ruling's words. Owner decides: ship in 2.0's release PR (all S) or leave on the tracker. Listed so nothing is silent |

---

## 3. Wave plan to finish 2.0

Order rationale: close the git container first (W-K0), while the logins are fresh. Do the
cluster pieces with no MCP dependency next (K1, K2, K4, K6). Write the 2.0 requirements and
settle design-13 (T0) in parallel. Then the transport-free service split (T2) can start while
the upstream 3tears-mcp work (T1) runs. The per-user MCP (M*) needs both the k8s MCP backend
and, by the ruling, the 3tears server, so it comes after T3. The account broker and Syncthing
(K3/K3b) need decisions about where Claude state lives, which also affects how the MCP reads
transcripts (Q-K2/Q-M3), so those questions are asked early and the build follows M1.

```
W-K0 ─┬─ W-K1 ─ W-K2 ─ W-K4* ─────────────┐
      │                 (W-K4 needs M4 webhook for the k8s freeze trigger)
      ├─ W-K6                             │
      ├─ W-T0 ─ W-T1 (upstream) ──┐       │
      │         W-T2 (split) ─────┴─ W-T3 ─ W-T4 ─ W-M1 ─ W-M2 ─ W-M3 ─ W-M4 ─ W-T5 (mesh)
      ├─ W-N (rename, early: removes conflicts)       │
      └─ W-K5 (RBAC/kubeconfig) ─────────────────────┘ (M1/M2 need its RBAC model)
W-K3 (broker) and W-K3b (Syncthing) after M1 (shared Claude-state layout), before W-R
W-K7 ops (any time, owner) ; W-R release last
```

### W-K0: close the git container wave (branch `feature/k8s-git-container`)
- Status: the git container build plan's chunks are all built and reviewed, and that plan is archived (`archive/build-plan-k8s-git-container.md`, completed). Its only open items, the owner-login live GitHub and Claude tests, continue here as 02 and 03.
- 01 Critic round finishes. Fix its findings. Goal: the wave is reviewed. Done when: verify clean.
- 02 Owner logs in (`aidc git login`, git agent's Claude). Run the smokes' GitHub and Claude parts on a scratch repo (`AIDC_SMOKE_GIT_REPO`, `_CLAUDE`, `_PROTECT`). Done when: PR merged with two parents, branch deleted on GitHub, worktree tidied, identity seen, protections read and applied.
- 03 Docker: a real AskUserQuestion from the git agent reaches an MCP watcher, and `session_send` answers it. Done when: the answer is seen in the transcript, or the failure is recorded (which triggers Q-M5).
- 04 `/prawduct:pr` end to end inside a session (push before `gh pr create`). Done when: the PR exists through the request path.
- 05 macOS run of the Docker git container (volumes, mount check). Done when: the Docker git smoke passes on a Mac.
- 06 Residual acceptance: the owner reads R-G1..R-G12 (P4-P20) and accepts each, or names it for W-K1. Done when: each is recorded in owner-rulings.
- Owner's hands: GitHub login, Claude login, scratch repo, a Mac.

### W-K1: Kubernetes hardening and parity fixes
- 01 Failed cluster reads say unknown (H9): `session-create` disk check and `session-status` policy read. Done when: unit tests with a failing kubectl stub.
- 02 k8s session proxy `AIDC_PUBLIC_ONLY=1` (D8) and the Sysbox root vs node-rules probe (D9). Done when: smoke asserts that a private address is 403 at squid, and the probe is recorded.
- 03 Accepted-for-fix residuals from W-K0 (likely P6 diff scan, P14 gitcred repo check, P9 gc test, P18 image test, P12). Done when: tests plus mutations.
- 04 `--cpu/--memory` (and limits) at create (K8S-19). Done when: rendered manifest test plus live.
- 05 testament in the dev image (K8S-25), pinned, checksummed, cooldown. Done when: `testament --version` in the smoke on both backends.
- 06 `restart`, `upgrade` and `refresh` on k8s (owner list: restart/upgrade). Done when: k8s smoke restarts and upgrades a session and its conversation resumes.
- 07 status parity: lost malware feed (#60) on both backends; design-12 Status and Shape text (D10/D11). Done when: unit tests plus docs.
- 08 `gh pr status` for expired requests (GIT-03 leftover). Done when: a unit test.
- Depends: W-K0. Owner: none. Q-K7 (testament source) before 05.

### W-K2: ports, `--egress-tcp`, GPU
- 01 Tunnel (K8S-14): `aidc create --port` and `aidc proxy <s> add|rm|ls` on k8s via `kubectl port-forward`, kept alive with reconnect by a local supervisor. Status lists them (and fixes #74 on Docker). Done when: from a second machine the port answers, and it survives a pod restart.
- 02 LAN Ingress (K8S-15): `--expose <port>` gives an Ingress at `<session>-<user>.<domain>`, an ingress NetworkPolicy from the ingress controller only, the wildcard certificate (config names its Secret/issuer), removed at kill. Optional login per Q-K5. Done when: a phone on the VPN loads a page. kill removes it.
- 03 `--egress-tcp` and `aidc egress` on k8s (NET-15): a socat relay pod per host, a ClusterIP Service, hostAliases, an egress rule for the /32:port. It must coexist with K1-02's public-only squid (relays are reached directly, not through squid: check). Runtime add/rm changes hostAliases, which restarts the dev pod (Q-K9). Done when: a session reaches a LAN database and nothing else on the LAN.
- 04 `--gpu` (K8S-11): `nvidia.com/gpu: 1`, node selector unchanged. Done when: `nvidia-smi -L` in a `--gpu` session, and absent without it.
- 05 `--dns` and `--network` on k8s: owner ruling needed (Q-K10): implement (`--dns` = the session proxy's resolvers) or rule them Docker-only (K8S-01 amended).
- Depends: K1. Owner's hands: the wildcard certificate for the domain (DNS already answers, per ruling); the GPU free for a test; a LAN database to relay to; phone.

### W-K4: taint freeze on Kubernetes
- 01 Design (Q-K3), then build: on taint, the response the config names (`freeze` default) acts on k8s. Done when: a blocklisted fetch freezes the session within N s (smoke), and `aidc status` says so.
- Depends: the mechanism. If it uses the MCP webhook (K8S-13's exception), it needs W-M4. A policy-sidecar-only design can go earlier.

### W-K5: per-user cluster credentials
- 01 Per Q-K6: `aidc user add` second half: a namespace-scoped Role/RoleBinding for the user and for their MCP ServiceAccount, and a kubeconfig handed to the user (or documented use of their own). Done when: a user's kubeconfig can do everything aidc needs in their namespace and nothing in another user's (probe).
- Depends: K0. Needed by M1/M2.

### W-K6: audit trim (K8S-26, #77)
- 01 `aidc audit list|trim [--older-than D] [names]` on both backends, never a running session's trail. Done when: unit tests on both backends, and a live trim of the test claims (H7, with the owner's OK).
- 02 The 100 MB warning on every command (Docker: cheap `du`; k8s: only during cluster commands, cached about a day). Done when: tests for the cache and the threshold. Commands are not slowed (timed).
- Depends: K0. Owner: OK to delete the listed claims.

### W-N: naming 
- 01 Merge `chore/coordinator-naming` into develop (PR, owner), then merge develop into the k8s stack (merge commit, no rebase). Resolve the 11 overlapping files. Done when: `git grep -niw the old orchestrator config name lists only history files (or none).
- 02 Clean the rest in current files (the list is kept outside the repo, in the main agent's forward notes). Done when: the grep is clean of current docs/code/tests, and the owner has decided what to do with history-type files.
- Owner: PR approval; rename their own config section (H8) before restarting aidc-mcp.

### W-T0: 2.0 requirements and design-13 settled (no code)
- 01 Requirements for the adoption (local face, mesh face, observe, namespaced names, error model, packaging, per-user MCP mode). Amend MCP-02/03/05/10 for the cluster. Done when: IDs exist in `docs/requirements.md`.
- 02 Owner answers design-13 Q1-Q5 plus Q-M1..M4. Fix the "drop resources/list_changed" rows to the ruling ("keep, upstream"). Done when: design-13 has no **open** marks.
- 03 Build plan for the 3tears waves (prawduct format).

### W-T1: upstream 3tears-mcp (in the 3tears repo, released there)
- 01 Call context (progress token, report_progress, log, cancel). 02 progress and logging over Streamable HTTP. 03 richer error model. 04 resources. 05 stateful mode (`list_changed`, subscriptions, cancellation, identity re-checked per message). 06 TearsTool→McpTool bridge. 07 `face_api` without the hub. 08 (if Q4 = yes) L1 on a file. 09 durable/fail-reporting agent-audit sink.
- Done when: each is released in one pinned 3tears minor.
- Owner's hands: 3tears releases (PyPI), the decision on dropping SDK 1.x (Q5).

### W-T2: service split in aidc (can run alongside T1)
- 01 Watchers, queues, delivery and resume move out of `tools.py` into a service module with no MCP types. Done when: the MCP suite is unchanged and green, and `make smoke` passes.

### W-T3: tools as TearsTools, local face
- 01 23 tools as TearsTools over the service. Taint gate as an Authorizer. Schemas via tool-schema. 02 local face on 3tears-mcp through the bridge: progress, resources, list_changed, cancel kept; aidc codes as protocol codes. 03 #76 `file_put` overwrite fixed in the rebuilt tool. 04 wire tests rewritten, published-tools regenerated. Done when: an orchestrator round trip (send, watch, callback, cancel) passes against the new server on Docker.
- Depends: T1 (01-06), T2.

### W-T4: observability on 3tears-observe
- 01 Structured logs and traces. The access log stays a file sink (MCP-14). Done when: the access-log tests are unchanged.

### W-M1: MCP Kubernetes backend
- 01 `backend.py` gains a kubectl implementation (`target` → namespace/pod/container; exec, inspect, list, instance id, missing). The confinement test is extended. Done when: unit tests mirror the Docker ones.
- 02 Transcripts from cluster sessions and the git pod reach the service (Q-M3). Done when: a cluster session's turn is delivered once across an MCP restart.
- Depends: T3, K5.

### W-M2: per-user MCP in the cluster (K8S-07)
- 01 `aidc mcp setup|status|logs|token rotate` on k8s: a Deployment in the user's namespace, state and access log on a claim, the token as a Secret, an image with the aidc CLI, kubectl and yq, ServiceAccount with K5's Role. 02 Reachability for the orchestrator per Q-M1. 03 Callback egress to the orchestrator (NetworkPolicy to exactly the callback host:port). 04 `session_create` on k8s (no repo) and `session_mcp_set`. Done when: sessions keep running and a reply arrives at the orchestrator while the laptop is off.
- Owner's hands: the orchestrator running for the live test; the DNS/ingress name if Q-M1 picks Ingress.

### W-M3: git approvals through the orchestrator on Kubernetes (K8S-06, ruling)
- 00 Q-K8 (§5): bind each approval in code to the answer: the question carries a one-time code only the user's or orchestrator's answer returns, and `git-requests approve` refuses without it (both backends). Done when: the agent cannot approve its own request (unit test + mutation), and an orchestrator answer approves.
- 01 The git agent (`git` session) reached by the in-cluster MCP: watch, status, send. 02 The answer path from W-K0-03's result (paste works, or a dedicated answer, Q-M5). 03 The smoke's Claude part made automatic. Done when: an orchestrator approves a k8s session's PR request end to end.

### W-M4: the taint webhook path (K8S-13)
- 01 Policy sidecar → per-user MCP webhook allowed by one NetworkPolicy rule (to the MCP Service port only). The MCP records it and, if K4 chose it, freezes. Done when: a taint shows in `session_status` within seconds, and the session still cannot reach any other MCP port.

### W-K3: account broker (K8S-16, K8S-17)
- 01 Per-user broker pod: accounts added by the user (`aidc claude account add` runs the OAuth login in the broker), refresh tokens on a claim only it mounts. It writes access-only `.credentials.json` into each session's Claude dir by rename. 02 Switching: the statusline wrapper reads `rate_limits.seven_day` against `switch_at`, the `StopFailure rate_limit` hook, cycle order, auto/wait setting. 03 The live token-expiry test (D1, hours). Done when: a session crosses an account switch mid-conversation without a restart, and survives a real token expiry.
- Needs: Q-K1, Q-K2 (where the Claude dir lives: today it is the session's own home claim; the broker must be able to write it, so the broker mounts each session home or the Claude dir moves to the user disk). Owner's hands: two or more Claude accounts.

### W-K3b: one history per repo, Syncthing (K8S-18)
- 01 Per Q-K2: one `projects/` per user on the cluster shared by the user's sessions. A Syncthing pod in the user's namespace (its egress: Syncthing relays/discovery or the LAN only, Q-K11). The sync set per ruling (laptop-to-cluster-only items one way). The lease so one machine resumes a conversation. 02 Mac alias reconciler plus D3 tests. Windows junctions (bonus). 03 #35's symlink risk settled for synced memory. Done when: a conversation started on the cluster is continued on the Mac with memory intact, and never two writers at once.
- Owner's hands: Syncthing on each laptop, pairing, a Mac.

### W-T5: mesh mode
- 01 ToolServer entry point, pod identity, registration, grants, mesh audit. 02 The mesh delivery channel if Q2 says so. 03 The per-user server in mesh or local mode (config). Done when: an orchestrator on a real mesh calls `aidc.session_send` and gets the turn.
- Owner's hands: a running 3tears mesh (NATS with callout auth, registry, hub) to test against. The hub's MCP/API face is not in the 3tears repo.

### W-K7: owner operations (any time)
- Registry PVC off the scratch class. Delete `aidc-probe` if unneeded. Delete test audit claims (H7) and empty transcript folders (P22). Before W-R: a node reboot test for K8S-22 (owner schedules the session-node reboot). K8S-21 from a second machine. K8S-20 with a second (test) user.

### W-R: release 2.0
- 01 Docker `aidc rebuild` + `make smoke` (H11; P21 fixed); `make smoke-k8s`; full unit and MCP suites. 02 CHANGELOG with upgrade notes (namespaced tools, `orchestrator:`, the k8s backend), README, published-tools. 03 Archive the plans (H10, H12), change records into CHANGELOG. 04 Merge the stack into develop (H15: ask the owner once, here: one PR for 2.0 per the release flow). Tag, release, update, rebuild, MCP stop/start. 05 Norm ratification (H13).

### Requirements not designed enough to build (Requirements Precede Code)

| Q | Requirement | Question that settles it |
|---|---|---|
| Q-K1 | K8S-16/17 | Where does the broker run, and how does a user add an account (OAuth in a broker pod via `aidc claude account add`, or log in on the laptop and upload the refresh token)? Is `aidc claude-token` (1-year inference token) an acceptable K8S-16 fallback in the meantime? |
| Q-K2 | K8S-18 (+K8S-16, MCP transcripts) | As built, each session's Claude state is on its own home claim, so history is per session. Should `~/.claude` (or only `projects/`) move to the user's disk, shared by all the user's sessions, so one repo has one history and Syncthing, the broker and the MCP have one place to look? |
| Q-K3 | taint freeze on k8s | What does "freeze" mean in a cluster: cut the session's egress (a deny-all policy on its proxy), scale the dev pod to 0, or cgroup-freeze its processes? And who acts: the per-user MCP on the sidecar's webhook, or something with no API token? |
| Q-K4 | K8S-09 | Which pod does VS Code attach to (a dedicated per-user editor pod mounting the disk, the git pod, or a session pod)? How does the VS Code server get in, given that sessions have no direct egress? |
| Q-K5 | K8S-15 | Which login is put in front of a page when asked (basic auth via an ingress middleware, oauth2-proxy with GitHub, other)? And which ingress controller/certificate source does the config name? |
| Q-K6 | K8S-14/20 | Does aidc mint per-user namespace-scoped credentials at `aidc user add`, or does each user bring their own kubeconfig? (K8S-14 says "the user's own cluster credentials".) |
| Q-K7 | K8S-25 | testament's release source (URL, checksums) and the pinned version. |
| Q-K8 | R-G11 | Should a git-agent approval be bound in code to the user's answer (a nonce the user or orchestrator returns), or is "only its instructions" accepted? |
| Q-K9 | NET-15 on k8s | Can `aidc egress add` restart the session's dev pod (hostAliases), or must it stay live (a DNS shim in the pod instead)? |
| Q-K10 | K8S-01 | Are `--dns`, `--network`, `clean-env` Docker-only (amend K8S-01), or must they have cluster forms? |
| Q-K11 | K8S-18 | Syncthing pod egress: public relays/discovery (through what policy) or LAN-only direct to the user's machines? |
| Q-M1 | K8S-07, MCP-10 | How does the orchestrator reach a user's in-cluster MCP: Ingress name, LoadBalancer/NodePort on the LAN, or the user's port-forward? And where does the orchestrator run (inside the cluster, on the LAN)? |
| Q-M2 | MCP-13/38 in cluster | What may the MCP's ServiceAccount do (create session StatefulSets and policies in its namespace only), and is Pod Security admission on user namespaces enough to stop it creating privileged pods? |
| Q-M3 | MCP-15 in cluster | How do transcripts reach the per-user MCP: it mounts each session's home claim (local-path, same node), a mirror to the user disk (as Docker mirrors to the MCP state), or exec+tail? |
| Q-M4 | MCP-02/03/05 | Is the Docker `aidc-mcp` kept beside the per-user cluster MCP (both in 2.0), and which does `aidc mcp` drive by default? |
| Q-M5 | K8S-06 | If paste+Enter cannot answer AskUserQuestion: a key sequence the MCP sends, or an explicit `git_approve` tool (and is that still "no separate approval system")? |
| design-13 Q1-Q5 | 3tears | Progress on the mesh; mesh delivery channel; one image or a mesh variant; L1-on-file vs aidc's files; drop SDK 1.x. |

---

## 5. Decisions taken by the main agent (2026-11-24; technical calls, the owner may overrule)

- Q-K2: yes. Each user's Claude `projects/` (history and memory) moves to the user's disk, shared by all their sessions, so one repo has one history and the broker, Syncthing and the MCP read one place.
- Q-K3: "freeze" on Kubernetes cuts the session's egress (a deny-all policy on its proxy pod) and marks it frozen, like Docker's freeze keeps the container but stops it acting; the per-user MCP acts on the sidecar's webhook.
- Q-K4: VS Code attaches to a per-user editor pod that mounts the user's disk (no API token, egress only through its own proxy).
- Q-K6: `aidc user add` mints namespace-scoped credentials (Role/RoleBinding + a kubeconfig); a user may still bring their own.
- Q-K8: yes, bind approvals in code: the question carries a one-time code that only the user's answer returns, and `git-requests approve` refuses without it.
- Q-K9: `aidc egress add` stays live (no pod restart); resolve names through the session's own proxy/relay instead of hostAliases.
- Q-K10: `--dns`, `--network` and `clean-env` get cluster forms (owner ruling: nothing left behind); where a form truly cannot exist, K8S-01 is amended with the owner's yes.
- Q-K11: Syncthing reaches only the user's own machines (LAN/VPN), no public relays or discovery.
- Q-M2: the MCP's ServiceAccount may create session StatefulSets, Services and NetworkPolicies in its own namespace only; user namespaces enforce Pod Security "baseline" with the runtime class allowed.
- Q-M3: transcripts are mirrored to the user's disk (as Docker mirrors to the MCP state), and the MCP reads them there.
- Q-M4: both: the Docker `aidc-mcp` stays for the Docker backend; `aidc mcp` drives the backend the config selects.
- Q-M5: decided by the W-K0-03 test; if paste+Enter cannot answer, the MCP sends the key sequence the question widget needs, not a separate approval tool.

Q-M1 answered by the owner (owner-rulings 2026-11-24): both, the in-cluster Service always and VPN/LAN exposure on request, behind the bearer token.

Q-K7 answered (owner-rulings 2026-11-24): GitHub releases, latest not pinned, kept current like Claude Code; amend K8S-25 in W-K1-05. Source: a private GitHub repo (its SSH URL in the user's config, not hard-coded). The laptop fetches it with the user's own SSH key, never gh (owner 2026-11-24: gh is not used for regular git work): `git ls-remote --tags` finds the newest vX.Y.Z tag (version sort), a shallow clone of that tag is built into a wheel locally (uv build), and the wheel goes into the image build context (both backends) and into a running session on upgrade (docker cp / kubectl cp, then install). No key or token enters a session or the image. Integrity comes from the SSH-authenticated clone of the tag's commit; the release SHA256SUMS asset is not reachable over SSH. OPTIONAL while testament is private (owner 2026-11-24): only when the user's config names its repo; if the config omits it, or the SSH fetch fails (no access), builds and upgrades carry on without testament and say so in one line, never fail. Tests cover configured, unconfigured and no-access.

Q-K5 answered (owner-rulings 2026-11-24): the developer chooses per expose, login or none; the domain comes from the user's config.

Asked of the owner one at a time, each only when its wave is about to be built: Q-K1 (account add flow), design-13 Q1-Q5.
