> **Status (2026-08-11): shipped, then amended.** The lint/unit/MCP gates in
> `.github/workflows/ci.yml` are live and blocking. CI-01 (smoke on every PR) was
> deliberately **superseded in v0.6.1**: hosted 2-core runners spent ~15 minutes
> building the dev image to run ~53 seconds of assertions and failed on runner
> disk limits, not real defects. `make smoke` on a developer machine is now the
> authoritative pre-tag gate (see CONTRIBUTING.md "Releases");
> `.github/workflows/smoke.yml` is retained as `workflow_call`-only for a future
> self-hosted runner.

# task-12: CI — Smoke + Lint on every PR

## Objective

Add GitHub Actions workflows that run `make smoke` on every pull request and every push to `main`, plus a `shellcheck` lint pass on PR. Failure of the smoke job MUST block merge once branch protection is configured. This is the first quality gate for the project and the prerequisite for any release engineering (task-14).

The audience for aidc is sophisticated (advanced AI devs running Claude Max), but they will still reasonably expect that "main" passes a basic functional check. Today the check is "Pace ran smoke 10x on his laptop" — fine for a 1-day-old project, inadequate the moment a second person commits.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| CI-01 | A GitHub Actions workflow MUST run `make smoke` on every pull request targeting `main` and on every push to `main`. Failure MUST block merge (branch protection enforced separately by the repo admin). | P0 |
| CI-02 | The smoke job MUST run on `ubuntu-latest`. macOS runners do NOT support Docker and MUST NOT be used. | P0 |
| CI-03 | The CI workflow MUST cache Docker layers across runs (GitHub Actions cache via the `type=gha` builder cache) so that re-runs on unchanged Dockerfiles complete in <5 minutes. First runs on a fresh cache may take longer. | P0 |
| CI-04 | A `lint` job MUST run `shellcheck` against `scripts/` and the proxy sidecar `*.sh` files on every PR. Lint failures surface as PR-check warnings but do NOT block merge — shellcheck advice is advisory. Specific issues that shellcheck would catch can be addressed via per-line `# shellcheck disable=SCxxxx` comments when the warning is a false positive, or by fixing the underlying issue when it's real. | P1 |
| CI-05 | The CI workflow MUST NOT publish artifacts, push images, or modify any external repo. It is read-only against the world. | P0 |

---

## Design Context

### Why ubuntu-latest, not macOS

macOS runners on GitHub-hosted runners do **not** support Docker (no Docker daemon available; nested virtualization is forbidden). The smoke harness depends on Docker for everything. Ubuntu runners have Docker installed and accessible via `/var/run/docker.sock`. There is no path to "test on macOS in CI" with GitHub-hosted runners as of 2026-05; self-hosted runners are out of scope for v0.1.

The fact that smoke runs on linux/amd64 while Pace develops on darwin/arm64 is a feature, not a bug: it gives free cross-arch validation that the Dockerfile + scripts work on both architectures.

### Why GHA cache, not registry cache

Docker BuildKit supports two cache backends relevant here:
- `type=gha` — caches into GitHub Actions cache (10 GB per repo, evicts LRU). No external service. Fast inside CI runners.
- `type=registry` — caches into a docker registry. We've decided (REL-08) to never publish images; using a registry just for cache contradicts that.

GHA cache is the right choice.

### Why `make smoke` and not a custom CI script

The existing smoke harness (`tests/smoke/run.sh`, 36 assertions in ~30s) is the authoritative functional check. Reproducing logic in CI yaml duplicates work and creates drift. The CI yaml MUST be a thin wrapper that calls `make smoke` and reports its exit code.

If smoke needs CI-specific behavior, that belongs in `tests/smoke/run.sh` (gated on `${CI:-}` or `${GITHUB_ACTIONS:-}` env), not in the yaml.

---

## Research

- GitHub Actions docker/setup-buildx-action: https://github.com/docker/setup-buildx-action — sets up buildx so we get the modern builder with GHA cache support
- BuildKit GHA cache: https://docs.docker.com/build/cache/backends/gha/ — the cache backend we're using
- actions/checkout: https://github.com/actions/checkout — standard checkout action; we need `fetch-depth: 0` only if a future step references git history; for smoke, the default depth is fine
- shellcheck: https://www.shellcheck.net/ — already wired up in `make lint`. CI invokes the same Makefile target.
- The `make smoke` target invokes `tests/smoke/run.sh`. The script uses `set -euo pipefail` and exits 0 on all-pass, 1 on any failure.

---

## Patterns to Follow

- Existing `make lint` target: `Makefile:16-18`. CI lint job calls this directly.
- Existing `make smoke` target: `Makefile:20-21`. CI smoke job calls this directly.
- Existing smoke env handling: `tests/smoke/run.sh:1-40`. Smoke already handles the absence of a real interactive terminal and runs cleanly under non-tty conditions.

There is no prior `.github/workflows/` directory — this task creates the first workflows.

---

## Files to Create

### `.github/workflows/smoke.yml`

The smoke job. Triggers on `pull_request` to `main` and `push` to `main`. Single job, no matrix.

Required behavior:
- Checks out the PR/push commit via `actions/checkout` **pinned by 40-char commit SHA** (see Security below for the rule).
- Sets up Docker BuildKit via `docker/setup-buildx-action` **pinned by 40-char commit SHA**.
- Pre-warms the cache: builds `aidc/dev-base:${AIDC_VERSION_TAG}` where `AIDC_VERSION_TAG` is the Docker-tag-safe form of the VERSION file content (task-13 defines this). Task-13 lands before this task in implementation order — see `docs/requirements.md` CI-* / REL-* dependency chain — so `${AIDC_VERSION_TAG}` is already exported by the time CI runs. The pre-warm step reads it via `env: AIDC_VERSION_TAG: ${{ env.AIDC_VERSION_TAG }}` at job level after a setup step computes it from VERSION.
- Runs `make smoke`.
- The job MUST succeed only if every assertion in the smoke harness passes.

The other aidc images (squid, refresher, policy, audit, forwarder) are smaller and faster to build (~30s each); the smoke harness will build them itself via `aidc create`. We do not need to pre-build them in CI.

**Trigger:** use `pull_request:` (NOT `pull_request_target:`). The former runs in the PR fork's context with no access to repo secrets, which is correct for a smoke job. `pull_request_target` runs with the BASE branch's permissions and exposes secrets to forks — it is the canonical CI compromise vector and MUST NOT be used here.

**Concurrency:** add a top-level `concurrency:` block keyed on `smoke-${{ github.ref }}` (NOTE the `smoke-` prefix). When task-14 lands the release workflow, that workflow will run smoke under its own key (`release-smoke-${{ github.ref }}`) — distinct keys ensure a rapid push during a tagged release doesn't cancel the in-flight release-smoke. Use `cancel-in-progress: true` here (cancellation is desirable for PR / push iteration).

**Permissions:** explicit top-level `permissions: {}` (empty) and grant per-job `contents: read` ONLY. Nothing else. CI-05 requires the workflow to be unable to write anything.

**Reusable / `workflow_call`:** structure smoke.yml as a callable workflow from day one. Include `on.workflow_call:` alongside `on.pull_request:` / `on.push:`, with the following input contract documented from v0.1.0 so future callers (release workflow, self-hosted runners) know what they can override:

```yaml
on:
  workflow_call:
    inputs:
      runs-on:
        description: Runner label (e.g. ubuntu-latest, or [self-hosted, macOS, arm64])
        type: string
        required: false
        default: ubuntu-latest
      ref:
        description: Git ref to run smoke against. When the smoke is called from
          the release workflow against a tag, the caller MUST pass the tag
          ref explicitly -- the default ${{ github.ref }} is the CALLEE's ref
          on `workflow_call`, not the caller's. For `pull_request` and `push`
          triggers, the default is correct.
        type: string
        required: false
        default: ${{ github.ref }}
      cache-backend:
        description: BuildKit cache backend. 'gha' for GitHub-hosted; 'local' for self-hosted.
        type: string
        required: false
        default: gha
      cache-path:
        description: Local filesystem path for the BuildKit cache when cache-backend=local.
          Ignored when cache-backend=gha. Default is suitable for single-job ephemeral runners.
          Callers using `local` backend on persistent or concurrent-job-sharing self-hosted runners
          MUST override to a per-job-unique path (e.g. include ${{ github.run_id }}) to avoid cache
          corruption from concurrent writers.
        type: string
        required: false
        default: /tmp/buildkit-cache
    secrets:
      # Explicitly NONE -- the smoke job MUST NOT have access to any secret.
      # Documented here as a comment, NOT inherited via `secrets: inherit`.
```

The job-level `runs-on:` references `${{ inputs.runs-on }}`; the checkout action uses `ref: ${{ inputs.ref }}`; the cache config is parameterized on `${{ inputs.cache-backend }}`.

**Prescriptive cache-config snippet** (use exactly this; the yaml conditional has subtle gotchas with quoting):

```yaml
- name: Build dev-base with cache (gha)
  if: inputs.cache-backend == 'gha'
  uses: docker/build-push-action@<sha>   # vX.Y.Z
  with:
    context: .devcontainer
    file: .devcontainer/Dockerfile
    push: false
    load: true
    tags: aidc/dev-base:${{ env.AIDC_VERSION_TAG }}
    cache-from: type=gha
    cache-to: type=gha,mode=max

- name: Build dev-base with cache (local)
  if: inputs.cache-backend == 'local'
  uses: docker/build-push-action@<sha>   # vX.Y.Z
  with:
    context: .devcontainer
    file: .devcontainer/Dockerfile
    push: false
    load: true
    tags: aidc/dev-base:${{ env.AIDC_VERSION_TAG }}
    cache-from: type=local,src=${{ inputs.cache-path }}
    cache-to: type=local,dest=${{ inputs.cache-path }},mode=max
```

Only one of the two steps runs per invocation (`if:` gates). Same SHA-pinned action both times; same tag both times.

`workflow_call:` does NOT inherit secrets by default. Do NOT add `secrets: inherit` or list secrets — smoke has no business with credentials. The release workflow (task-14) will call this with its own per-job permissions and explicitly pass nothing.

### `.github/workflows/lint.yml`

The shellcheck job. Triggers on `pull_request` to `main` only (linting on push to main is redundant — PRs already gated).

Required behavior:
- Checks out the PR commit via `actions/checkout` pinned by 40-char commit SHA.
- Installs shellcheck via `apt-get install -y shellcheck` (already on ubuntu-latest, but explicit is safer than implicit).
- Runs `make lint`.
- `continue-on-error: true` on the lint step itself per CI-04 — failures surface in the PR's check list but do not block merge.

**Trigger:** use `pull_request:` (NOT `pull_request_target:`). Same rationale as the smoke workflow above.

**Permissions:** top-level `permissions: {}`, per-job `contents: read` only.

---

## Files to Modify

### `Makefile`

The current `lint` target masks shellcheck's exit code with `|| true` (see `Makefile:18`). For CI we want shellcheck's exit to be visible — `continue-on-error` at the job level is how CI tolerates failures, not at the Makefile level. Remove the `|| true` and let `shellcheck` exit naturally.

Specifically, line 18 currently reads:
```makefile
	shellcheck scripts/aidc scripts/cmd-*.sh scripts/lib/*.sh proxy/refresher/*.sh proxy/policy/*.sh proxy/audit/*.sh 2>/dev/null || true
```

Change to:
```makefile
	shellcheck scripts/aidc scripts/cmd-*.sh scripts/lib/*.sh proxy/refresher/*.sh proxy/policy/*.sh proxy/audit/*.sh
```

(Note: keeping `2>/dev/null` was hiding shellcheck's own diagnostic output. Remove that too — we want the developer to see what shellcheck is complaining about.)

After this change, `make lint` exits non-zero if any shellcheck issue is found. The CI yaml handles informational-only via `continue-on-error`.

### `tests/smoke/run.sh`

Audit the harness for any host-only assumptions that would break under CI:
- `AIDC_SMOKE_PRESERVE` defaults to `0` — fine.
- `tests/scratch/` is the scratch dir — fine (CI workspace is writable).
- Any `git config --global user.{name,email}` reads in `cmd-create.sh` — if the CI runner has no global git config, the create flow emits a warning and continues without bridging. Acceptable; smoke does not depend on git identity being set.
- No assumption about `~/.claude/projects/` existing — fine. The Claude memory bridge falls back gracefully when the host dir is absent.
- DNS resolution of `example.com` / `example.org` / `anything.cn` — required, ubuntu-latest runners have working DNS. Confirmed.

If any host-only check is found that breaks under CI, gate it on `[ -n "${CI:-}" ] && ...` patterns rather than removing it (host devs still want strict checking).

The audit dir defaults to `~/aidc-audit` — but the smoke harness overrides this to `tests/scratch/<session>/audit` for self-containment. Confirm via `grep AUDIT_DIR tests/smoke/run.sh` — already correct, no action needed.

### `README.md`

The README's smoke description is stale and will diverge further as CI surfaces real-world runtimes. Update both occurrences:

- `README.md:319` — currently "29 assertions. ~15 seconds." → change to "36 assertions. ~30 seconds." (Reflects the current harness after task-11.)
- `README.md:357` — currently "29 assertions per run" → change to "36 assertions per run".

Confirm the current numbers via `grep -c '^assert ' tests/smoke/run.sh` (expect 36) before editing.

### `docs/requirements.md`

Already updated in advance of this shard. CI-01..CI-05 are in place.

---

## Implementation Notes

1. **Workflow naming convention.** Use `smoke.yml` and `lint.yml` — the job name is what shows up in the PR's check list. Avoid generic names like `ci.yml`.

2. **Concurrency cancellation matters.** Without `concurrency:`, a rapid sequence of pushes (`git push` then immediately `git commit --amend && git push -f`) launches multiple smoke runs in parallel. They all consume cache slots and CI minutes. The keyed concurrency block cancels the older run when a new one lands.

3. **Pre-warming the dev-base image** is the single biggest speedup. The proxy sidecars are small (Alpine + a few packages); they don't benefit much from caching. The dev-base image includes pyenv compiling three Python versions (~5 minutes uncached), plus Rust toolchain, Go, Node, and a chunky native-deps `apt` step. Cold build: 10-15 min. Warm cache: ~2 min. Worth the extra 20 lines of yaml.

4. **Reading the cache during smoke.** When `aidc create` runs inside `make smoke`, it calls `docker build -t aidc/dev-base:local ...`. The plain `docker build` command does benefit from BuildKit cache if BuildKit is the default builder. With `docker/setup-buildx-action@v3` and `driver-opts: image=moby/buildkit:latest` (the action's default), `docker build` uses BuildKit and reads from `type=gha` automatically. Verify: a smoke run after the pre-warm step should see "CACHED" output for every dev-base layer.

5. **No magic env in the workflow.** Do not set `AIDC_*` env vars in the workflow itself. Let smoke run with defaults. Smoke's config-defaults path is what real users hit; CI should exercise the same code path.

6. **Job logs.** Surface `make smoke`'s output verbatim. Do not pipe to a file or `tee`; the GitHub Actions log is the artifact. If a flake recurs, the log is the only evidence.

7. **PR-only concurrency vs push concurrency.** The `concurrency` key for PR runs is `smoke-${{ github.ref }}`; for push to main, the ref is `refs/heads/main` and concurrency cancellation is also desirable (e.g. rapid merges). The same key handles both. The `smoke-` prefix is significant — it namespaces this workflow's concurrency away from `release-smoke-...` (task-14) so a rapid push during a release doesn't cancel the release.

8. **All third-party actions MUST be SHA-pinned.** Pin every `uses: org/action@<ref>` line by a full 40-character commit SHA, not a tag (`@v3`, `@main`, `@latest`). Rationale: GitHub action tags are mutable; a maintainer-takeover or compromised tag at `docker/setup-buildx-action@v3` executes arbitrary code on the runner — which has access to whatever secrets the workflow declares. SHA pinning makes that supply-chain attack require the attacker to push a new commit, which has a far longer window to be noticed. Place a comment with the human-readable version next to the SHA so future readers know what version it is:

   ```yaml
   - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11   # v4.1.1
   - uses: docker/setup-buildx-action@f95db51fddba0c2d1ec667646a06c2ce06100226   # v3.0.0
   ```

   The implementing subagent MUST look up the current SHA for each action's intended version from the action's GitHub Releases page and verify it before writing. Do NOT trust example SHAs in this shard or in any other source — they age out.

9. **Never enable `set -x` in CI scripts.** Bash trace mode echoes every command, including command lines that may contain expanded secret variables. Even when no secret is currently referenced, future workflow edits could introduce one. The smoke harness runs unmodified; do not add `bash -x tests/smoke/run.sh` or `set -x` to any workflow step. Same applies to `env` dumps, `set | grep`, or `cat`ing rendered configs in unredacted form.

10. **Use `pull_request`, never `pull_request_target`.** The latter runs the workflow with BASE-branch permissions and grants secret access to forks — it is the well-documented canonical CI compromise pattern. There is no scenario in v0.1's CI where `pull_request_target` is correct.

---

## Anti-patterns

- **DO NOT** run smoke on macOS runners or in a matrix. macOS GitHub-hosted runners do not provide Docker and never will (Apple's licensing model + GitHub's lack of nested virtualization). The "test on every platform" instinct is right but unreachable on GitHub-hosted infra. Cross-arch validation comes for free from the linux/amd64 runner exercising the same Dockerfile that Pace's darwin/arm64 host also exercises.
- **DO NOT** publish images, tarballs, or any other artifact from the smoke or lint workflows. Per CI-05, these are read-only. Release engineering lives in a separate workflow gated on `tags`.
- **DO NOT** add an inline shellcheck override. If a script has an inevitable shellcheck warning, document it with a comment + `# shellcheck disable=SCxxxx` at the offending line. Do not blanket-disable rules at the workflow level.
- **DO NOT** use `actions/cache@v3` for Docker layers. That cache action is for filesystem paths, not BuildKit layer cache. The correct path is `type=gha` in the BuildKit `cache-from`/`cache-to`.
- **DO NOT** swallow non-zero exit codes anywhere in the smoke job. If `make smoke` fails, the job MUST fail. The whole point of CI is to surface that loudly.
- **DO NOT** use `actions/setup-buildx-action@v1` or older versions; the GHA cache backend has changed twice in BuildKit history and old action versions are misaligned. Pin `@v3` or later.
- **DO NOT** trigger on every branch's pushes. The workflow runs on `push: branches: [main]` only. PRs from feature branches get coverage via `pull_request:`. Triggering on every branch push doubles CI minutes for no benefit.
- **DO NOT** use `pull_request_target:` as a trigger. It runs with base-branch permissions including secret access — the canonical CI compromise vector.
- **DO NOT** pin actions by tag (`@v3`, `@main`, `@latest`). Pin by full 40-char commit SHA. Tags are mutable; SHAs are not.
- **DO NOT** enable `set -x`, `set -o xtrace`, or any other bash trace mode in CI workflow steps or in `make` targets invoked by them. Echoes commands that may contain expanded secrets to public logs.
- **DO NOT** `env` / `printenv` / `set` from CI steps. Same leak risk as `set -x`.
- **DO NOT** add `pull_request_target` or `workflow_run` even "just for now" to bypass fork-permission limits. If a future feature needs them, treat it as its own security review.
- **DO NOT** assume the `type=gha` cache backend is available on self-hosted runners. It binds to GitHub's hosted cache service; self-hosted runners get nothing. If self-hosted runners are added later, switch their workflow path to a local-disk or registry cache backend rather than silently running uncached.

---

## Success Criteria

- [ ] `.github/workflows/smoke.yml` exists with the structure described above. Triggers correctly on PR and push to main.
- [ ] `.github/workflows/lint.yml` exists, runs `make lint`, reports failures without blocking merge.
- [ ] `Makefile` `lint` target no longer masks shellcheck's exit code with `|| true`.
- [ ] A PR opened against `main` produces both a "smoke" and a "lint" check in the PR check list.
- [ ] A push to `main` produces a "smoke" check (no lint duplication on push).
- [ ] First CI run on a cold cache completes; subsequent CI runs without Dockerfile changes complete in <5 min.
- [ ] Deliberately introducing a smoke-breaking change (e.g. comment out a `set -e` in an entrypoint script) produces a failing CI check.
- [ ] Deliberately introducing a shellcheck warning (e.g. `var=$(unquoted)`) produces a lint warning in CI but the PR is still mergeable.
- [ ] Workflow `permissions:` blocks are `contents: read` only (no `contents: write`, no `packages: write`, no `id-token: write`). Top-level `permissions: {}` declared.
- [ ] Every `uses: org/action@<ref>` line in `.github/workflows/*.yml` references a 40-character commit SHA, with a `# vMAJOR.MINOR.PATCH` comment alongside.
- [ ] Neither workflow uses `pull_request_target` as a trigger.
- [ ] `smoke.yml` includes `workflow_call:` so future workflows (release smoke, self-hosted-runner smoke) can invoke it.
- [ ] The `concurrency:` key in `smoke.yml` is `smoke-${{ github.ref }}` (the `smoke-` prefix matters — leaves `release-smoke-*` available for task-14).
- [ ] No workflow step enables `set -x`, prints env, or surfaces rendered configs in logs.
- [ ] `README.md` smoke description updated to "36 assertions, ~30 seconds" in both locations.
- [ ] **`make lint` extended to enforce the security rules** (REQUIRED, not suggested):
  - Any `uses: org/action@<ref>` line in `.github/workflows/` where the ref is not a 40-character hex SHA fails lint. ALL third-party actions SHA-pinned — no allowlist for `actions/*` or `github/*`; first-party action compromise is still possible (CVE history bears this out). Two exemptions, both narrow:
    - Local repo-relative references — `uses: ./.github/workflows/<file>.yml` — are NOT SHA-pinned (the ref IS the local file; no remote SHA exists). The local-path pattern (`./...`) is the allowlist token.
    - GitHub-Expression interpolations — `uses: ${{ matrix.action }}` — fail lint (interpolation hides the SHA). If a future workflow needs dynamic action selection, it MUST be a hardcoded conditional with each branch SHA-pinned, NOT an expression.
  - Any `pull_request_target` trigger in any workflow yaml fails lint.
  - Any workflow step containing `set -x`, `set -o xtrace`, `bash -x`, `sh -x`, `BASH_XTRACEFD=`, `env >`, `env >>`, `printenv`, `set | grep` fails lint. (Bash bare `set` and `printenv` always leak secrets in scope. Adding a workflow step that explicitly invokes a shell with `-x` is the same anti-pattern via different syntax.)
  - Any workflow step that `cat`s a known-secret-adjacent path fails lint. Pattern list: `~/.config/aidc/`, `~/.config/gh/`, `~/.ssh/`, `~/.netrc`, `*.token`, `*.token-*`, `*.pat`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `*credentials*`, `*gh-token*`, `/proc/self/environ`, `/var/run/secrets/`. (Scoping is important — bare `cat` is legitimate for surfacing files and is NOT flagged. Only path patterns matching the secret-adjacent list trigger. Audit-log files at `~/aidc-audit/` are NOT on the list — they're surfacing-friendly outputs by design.)
  - Any workflow yaml granting `*: write` permissions in a job that doesn't include a `# justify:` comment fails lint. Three accepted placements (whichever the implementing subagent picks consistently):
    1. On the line immediately before the `permissions:` key:
       ```yaml
       release:
         # justify: contents: write needed to create the GitHub Release for this tag
         permissions:
           contents: write
       ```
    2. On the same line as the `*: write` declaration as a trailing comment:
       ```yaml
       permissions:
         contents: write  # justify: needed to create the GitHub Release for this tag
       ```
    3. As the first child of the job, immediately under the job key (before `permissions:`):
       ```yaml
       release:
         # justify: contents: write needed to create the GitHub Release for this tag
         runs-on: ubuntu-latest
         permissions:
           contents: write
       ```
    The lint script accepts any of the three placements. Implementation: for each `*: write` line, search the preceding 10 lines AND the same line for `# justify:` — if neither contains it, fail with the file:line of the violation.
- [ ] **Coordination with task-14:** task-14's release.yml grants `contents: write` to the release job. That job MUST include a `# justify:` line. The task-14 implementing subagent should be made aware via the PR description that this lint rule exists. (Alternatively, task-14 lands AFTER task-12, sees the lint failure on its first PR, and adds the comment as part of the fix.)
- [ ] Deliberately re-introducing each anti-pattern (one at a time, in a throwaway PR) causes `make lint` to fail with a specific error message naming the violation.

---

## Verification

```bash
# Local syntax check of the workflow yaml (after writing it):
docker run --rm -v "$PWD":/repo -w /repo ghcr.io/rhysd/actionlint:latest \
    -color .github/workflows/smoke.yml .github/workflows/lint.yml

# Confirm Makefile change is correct:
grep -n 'shellcheck' Makefile
# Should show the shellcheck line WITHOUT trailing `|| true` or `2>/dev/null`.

# Open a PR with a trivial change and confirm:
# - "smoke" check appears and passes
# - "lint" check appears
# - Repeated re-runs of the PR (push --force-with-lease a new commit) cancel the prior smoke run
```

The full verification of CI-01 (failure blocks merge) requires repo admin to enable branch protection on `main` with "Require status checks to pass before merging" → check the "smoke" job. That action is out of scope for the subagent implementing this task — call it out in the PR description so the admin enables it after merge.

---

## Enforcement Test Suggestions

The subagent fills this in at task completion if drift potential exists. Candidates worth considering:

- [ ] Workflow `permissions:` block stays at `contents: read` (or `{}` at top level). Suggested test: a grep-based check in `make lint` that fails if any workflow yaml grants `*: write` permissions in jobs that don't explicitly need them. Catches accidental escalation (the kind of mistake that lets a compromised PR push to main).
- [ ] No workflow ever uses `secrets.GITHUB_TOKEN` with write scopes in the smoke/lint workflows. Same grep-based safety net.
- [ ] `make smoke` invocation in CI matches the local invocation (no special flags or env). Suggested test: assert that the workflow yaml contains the literal string `make smoke` on its own line.
- [ ] No third-party action is referenced by a tag (`@v[0-9]+`, `@main`, `@latest`). Suggested test: a `make lint`-time regex that flags any `uses:` line where the ref is not a 40-char hex SHA, with an allowlist for first-party `actions/*` if Pace wants to relax that subset. Critical defense against tag-mutation supply-chain attacks.
- [ ] No workflow uses `pull_request_target:` as a trigger. Suggested test: grep for `pull_request_target` across `.github/workflows/`; fail if found.
- [ ] No workflow step contains `set -x`, `set -o xtrace`, `env >`, `printenv`, or unredacted `cat` of files that might contain secrets. Suggested test: same regex-based grep in `make lint`.
