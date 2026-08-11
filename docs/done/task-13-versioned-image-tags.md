# task-13: Versioned Image Tags

## Objective

Replace the single shared `aidc/*:local` tag scheme with version-aware tags (e.g. `aidc/dev-base:v0.1.0`) so that a user upgrading the CLI via `brew upgrade aidc` actually picks up Dockerfile changes on their next `aidc create`. Without this, `build_if_missing` sees the cached `:local` tag and skips rebuild — the user runs the new CLI against the old image and wonders why their bug fix didn't land.

Source the version from a single `VERSION` file at repo root so there's one place to bump it. Pre-requisite for task-14 (release + brew tap).

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| REL-01 | Local `aidc/*` image tags MUST be versioned with the CLI version (e.g. `aidc/dev-base:v0.1.0`), NOT a single shared `:local` tag, so that `brew upgrade aidc` and a subsequent `aidc create` rebuilds against the new Dockerfile rather than reusing a stale image. | P0 |
| REL-02 | The CLI version MUST be sourced from a single `VERSION` file at the repo root; `scripts/aidc` MUST read it once at dispatcher init and expose it as `AIDC_VERSION`. | P0 |

---

## Design Context

### Why a VERSION file (not a git tag, not a constant in scripts/aidc)

Three sources of truth were considered:

1. **A constant in `scripts/aidc`.** Would work, but requires editing the script to bump version. Easy to miss.
2. **The most recent git tag.** Elegant, but breaks when the user installed via brew (no `.git/`), or runs from a non-tagged commit. Fragile.
3. **A `VERSION` file at repo root.** One file, plain text (`v0.1.0\n`), version-controlled, present in every install path (clone, tarball, brew). One place to bump.

Option 3 wins. The `VERSION` file is the canonical source.

### Tag format

`vMAJOR.MINOR.PATCH` (semver with a `v` prefix), optionally with a pre-release suffix (e.g. `-dev`, `-rc1`, `-alpha.2`) and/or build metadata (`+sha.abc1234`). Matches git tag convention. Matches semver convention. Examples: `v0.1.0`, `v0.1.0-dev`, `v0.1.0-rc1`, `v0.1.0+sha.abc1234`.

The canonical version regex (used for validation in `scripts/aidc`, in CI, in the release workflow):
```
^v[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9]([a-zA-Z0-9.]*[a-zA-Z0-9])?)?(\+[a-zA-Z0-9]([a-zA-Z0-9.]*[a-zA-Z0-9])?)?$
```
Each suffix segment requires a leading alphanumeric AND (if longer than one character) a trailing alphanumeric — no `+.something`, no `-.something`, no `v0.1.0-rc1.` (trailing dot), no `v0.1.0+sha.`. This intentionally permits build metadata (`+...` suffix). Compliance / SBOM workflows commonly want to surface a commit-sha or build-id in the version; allowing it now avoids a forced regex change in v0.2.

### VERSION → image-tag derivation (mangle for Docker charset)

**Docker image-tag charset is narrower than semver.** Docker tags allow `[a-zA-Z0-9_.-]{1,128}` — the `+` from semver build metadata IS NOT VALID. Naively using `${AIDC_VERSION}` as an image tag breaks `docker build` the first time a VERSION contains `+`.

The fix: image tags use a **mangled** form of the version. The mangling rule:
```
+   ->  _    (Docker forbids '+'; '_' is allowed)
```

Everything else passes through unchanged (`.` and `-` are valid in Docker tags).

This implies an intermediate var:
```bash
# In scripts/aidc (or scripts/lib/common.sh — caller's choice):
AIDC_VERSION_TAG="${AIDC_VERSION//+/_}"
export AIDC_VERSION_TAG
```

**Compose template, build calls, and ALL Docker tag references MUST use `${AIDC_VERSION_TAG}`, not `${AIDC_VERSION}`.** The unmangled `${AIDC_VERSION}` is for human-facing output, GitHub Release tags, brew formula version strings, and the like — wherever the `+` is valid and meaningful.

Examples:
| Source | VERSION | VERSION_TAG | Notes |
|---|---|---|---|
| Release | `v0.1.0` | `v0.1.0` | identical when no build metadata |
| Dev | `v0.1.0-dev` | `v0.1.0-dev` | identical, `-` is fine |
| RC | `v0.1.0-rc1` | `v0.1.0-rc1` | identical |
| Build metadata | `v0.1.0+sha.abc1234` | `v0.1.0_sha.abc1234` | `+` mangled to `_` |

Image tags use `${AIDC_VERSION_TAG}` verbatim, including the `v` prefix:
- `aidc/dev-base:${AIDC_VERSION_TAG}`
- `aidc/squid:${AIDC_VERSION_TAG}`
- `aidc/refresher:${AIDC_VERSION_TAG}`
- `aidc/policy:${AIDC_VERSION_TAG}`
- `aidc/audit:${AIDC_VERSION_TAG}`
- `aidc/forwarder:${AIDC_VERSION_TAG}`
- `aidc/mcp:${AIDC_VERSION_TAG}` (covered by the same pattern; see task-10 / MCP server)

### Future-proofing the tag namespace (RESERVED, not implemented in this task)

v0.1 emits a flat scheme: `aidc/<role>:<version>`. Future variants that we anticipate (and want to leave room for, not block on now):

| Future case | Tag shape |
|---|---|
| Per-profile dev-base (e.g. lean python-only vs heavy multi-toolchain) | `aidc/dev-base:vX.Y.Z-<profile>` (suffix BEFORE any build metadata) |
| Per-arch image variants (e.g. self-hosted arm64 macOS runners with a different base) | `aidc/dev-base:vX.Y.Z-<arch>` |
| Both | `aidc/dev-base:vX.Y.Z-<profile>-<arch>` |
| Third-party plugin sidecars | `aidc-plugin/<vendor>/<role>:vX.Y.Z` (separate org prefix) |

**This task implements only the flat scheme.** No code in this task references `-<profile>`, `-<arch>`, or `aidc-plugin/*`. But:

- DO NOT introduce a different convention later that conflicts with the above. Specifically, do NOT use underscores, dots, or capitals in the role/profile/arch segments — Docker tag charset allows them, but consistency with semver and DNS conventions is more important.
- Documenting this in `docs/done/design-04-proxy-stack.md` or a new `docs/decisions.md` is reasonable follow-up but NOT part of this task.

### What happens during dev work (no formal version)

Devs working in a clone between tagged releases have `VERSION` set to something like `v0.1.0-dev` (the next anticipated tag plus `-dev`). Each commit doesn't bump VERSION; only release-prep commits bump it.

Image tags during dev work would be e.g. `aidc/dev-base:v0.1.0-dev`. Multiple devs working on the same machine but different branches share that tag — same as today's `:local`. This is fine: dev-on-dev image collisions are not a problem we're trying to solve here. The collision we ARE solving is brew-upgrade reusing an image from a prior release.

### Backward compatibility

Existing sessions running with `aidc/*:local` images keep working until torn down with `aidc kill`. The `kill` flow doesn't care about image tags; it operates on container names. New `aidc create` produces version-tagged images. Mixed states (old session running, new session created) coexist without conflict.

No migration script needed. Users with `:local` images on disk will see them eventually become unreferenced when all `:local`-tagged sessions are killed; manual cleanup with `docker image rm aidc/dev-base:local` (etc.) is documented but not automated.

### LTS / multi-major releases (RESERVED, not implemented here)

Once v2.0 ships, some users will pin to v1.x for compliance / stability reasons and need backports. Multi-major release infrastructure is not part of this task's scope; the version scheme here MUST accommodate it without retrofit:

- The VERSION file is a single line; one repo state, one version. LTS branches live as `release/v1.x` branches with their own VERSION.
- `aidc/dev-base:v1.4.7` and `aidc/dev-base:v2.0.1` coexist on disk without conflict (different tags).
- Task-14's release workflow triggers on `v*` tags from any branch, so tag pushes from `release/v1.x` produce a v1.4.8 release without main-branch involvement.

The implementing subagent in this task does NOT need to write LTS-branch tooling. Just verify nothing about the implementation closes the door (e.g., do NOT validate the VERSION file against main's most recent tag — that would break LTS).

### Validating the VERSION file is critical

`VERSION` is attacker-controllable input on a brew install (the tarball ships it, the user runs scripts that consume it). `scripts/aidc` MUST validate the read value against the canonical regex BEFORE exporting it. A malformed VERSION must `die` cleanly, not silently propagate garbage into Docker image tags or envsubst-rendered yaml. See "Files to Modify → `scripts/aidc`" below for the prescriptive check.

---

## Research

- Semver: https://semver.org/ — for version format choice
- Docker image naming/tagging rules: https://docs.docker.com/engine/reference/commandline/tag/ — tags must match `[a-zA-Z0-9_.-]{1,128}`, the leading `v` and dots/dashes in semver are all valid
- The brew formula written in task-14 will read `VERSION` to derive the tarball URL; the URL pattern is `https://github.com/pacepace/aidc/archive/refs/tags/${VERSION}.tar.gz`

---

## Patterns to Follow

- The `build_if_missing` helper is defined at `scripts/cmd-create.sh:162-169` and called for the five aidc proxy/dev images at `scripts/cmd-create.sh:171-175`. It takes `(tag, context, dockerfile)`. The signature stays the same; the caller is responsible for passing a versioned tag.
- The MCP image tag is defined as `IMAGE="aidc/mcp:local"` at `scripts/cmd-mcp.sh:23` and consumed at `cmd-mcp.sh:134-136` (build) and `cmd-mcp.sh:150` (run). Change the definition; the consumers pick up the new tag automatically.
- The forwarder image tag is defined as `FORWARDER_IMAGE="aidc/forwarder:local"` at `scripts/cmd-proxy.sh:28` and consumed throughout that script. Same pattern: change the definition.
- Common-lib pattern for exported globals: `scripts/lib/config.sh` defines `AIDC_*` env vars in `aidc_config_defaults()` and exports them. `AIDC_VERSION` doesn't fit there (it's not config; it's identity) — read it once in `scripts/aidc` and export directly.

**Authoritative `:local` inventory (run on 2026-05-22):**
```
scripts/cmd-create.sh:171       aidc/squid:local
scripts/cmd-create.sh:172       aidc/refresher:local
scripts/cmd-create.sh:173       aidc/policy:local
scripts/cmd-create.sh:174       aidc/audit:local
scripts/cmd-create.sh:175       aidc/dev-base:local
scripts/cmd-mcp.sh:23           aidc/mcp:local
scripts/cmd-proxy.sh:28         aidc/forwarder:local
proxy/compose.yaml.template:30  aidc/squid:local
proxy/compose.yaml.template:48  aidc/refresher:local
proxy/compose.yaml.template:60  aidc/policy:local
proxy/compose.yaml.template:80  aidc/audit:local
proxy/compose.yaml.template:97  aidc/dev-base:local
README.md:92                    aidc/forwarder:local (prose)
README.md:160                   aidc/dev-base:local (prose)
proxy/forwarder/Dockerfile:13   aidc/forwarder:local (comment)
scripts/cmd-proxy.sh:10,77      aidc/forwarder:local (comments)
```

Re-run `grep -rn 'aidc/[a-z_-]*:local' scripts/ proxy/ README.md tests/` before editing — if the inventory has changed since this shard was written, fix all hits. The list above is exhaustive at the time of writing.

---

## Files to Create

### `VERSION`

A single-line plain-text file at repo root. Initial content for the unreleased state:

```
v0.1.0-dev
```

The trailing `-dev` distinguishes "in-development" from "released." The release workflow in task-14 will update this file in a release-prep commit before tagging.

---

## Files to Modify

### `scripts/aidc`

Read `VERSION` once at dispatcher init. Validate. Export `AIDC_VERSION` so every subcommand sees it without re-reading.

The VERSION file lives at `${AIDC_ROOT}/VERSION` (the same `AIDC_ROOT` the dispatcher already resolves from its own location). If the file is missing or contains a malformed value, the dispatcher MUST `die` with a clear message rather than silently defaulting or propagating bad input. A bad VERSION is a project-state error, not a runtime decision to paper over.

VERSION is attacker-controllable input on a brew install — the tarball ships it. Without validation, a malicious or accidentally-mangled VERSION could inject shell metacharacters via envsubst into the rendered compose yaml, or characters outside Docker's tag charset that break image references silently downstream. The validation closes that door.

Read + validate + derive image-tag form. Read only the FIRST line of VERSION; reject if the line itself contains whitespace (defends against `v0.1.0\tevil` getting silently concatenated into `v0.1.0evil` which then passes the regex). Then mangle `+` → `_` to produce the Docker-tag-safe form.

```bash
# Read first line only. Strip trailing CR (Windows line endings) but NOT internal whitespace.
AIDC_VERSION=$(head -n1 "${AIDC_ROOT}/VERSION" 2>/dev/null | tr -d '\r' || true)
if [ -z "$AIDC_VERSION" ]; then
    err "VERSION file is missing or empty at ${AIDC_ROOT}/VERSION"
    exit 2
fi
# Reject any whitespace inside the line itself.
case "$AIDC_VERSION" in
    *[[:space:]]*)
        err "VERSION first line contains whitespace: '${AIDC_VERSION}'"
        exit 2
        ;;
esac
# Canonical version format. Permits semver pre-release (-dev, -rc1, -alpha.2)
# and build metadata (+sha.abc1234). Each suffix segment requires a leading
# alphanumeric (no leading dots). Matches the regex in CI / release workflow.
if ! printf '%s' "$AIDC_VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9]([a-zA-Z0-9.]*[a-zA-Z0-9])?)?(\+[a-zA-Z0-9]([a-zA-Z0-9.]*[a-zA-Z0-9])?)?$'; then
    err "VERSION file content '${AIDC_VERSION}' does not match v[MAJOR].[MINOR].[PATCH][(-|.)pre][+build]"
    exit 2
fi
# Docker tag charset is narrower than semver -- `+` is not allowed in image tags.
# Mangle for the image-tag form; everything else passes through.
AIDC_VERSION_TAG="${AIDC_VERSION//+/_}"
export AIDC_VERSION AIDC_VERSION_TAG
```

Note: `grep -E` (ERE) on macOS bash 3.2 handles this regex without surprises. Do not use `[[ =~ ]]` — different regex engines, different escaping rules. `${var//+/_}` is bash parameter expansion (works on bash 3.2 fine).

### `scripts/cmd-create.sh`

Replace every `aidc/*:local` literal with `aidc/*:${AIDC_VERSION_TAG}` (NOTE: use the tag-mangled form, not raw `AIDC_VERSION`). Specifically:
- `build_if_missing "aidc/squid:local"` → `build_if_missing "aidc/squid:${AIDC_VERSION_TAG}"`
- Same for `refresher`, `policy`, `audit`, `dev-base`.
- The forwarder image is lazy-built in `cmd-proxy.sh`, not here — handle that separately.

The compose template references `aidc/*:local` in the service definitions:

```yaml
squid:
    image: aidc/squid:local
    ...
```

These references need to be parameterized. Use envsubst:
- Change the template to `image: aidc/squid:${AIDC_VERSION_TAG}` (treat as a placeholder).
- Add `AIDC_VERSION_TAG` to the envsubst variable list in `proxy/compose-render.sh`.
- Export `AIDC_VERSION_TAG` from the dispatcher (already done in `scripts/aidc` per the read+validate block above).

### `proxy/compose.yaml.template`

Change every `image: aidc/<role>:local` to `image: aidc/<role>:${AIDC_VERSION_TAG}` (the tag-mangled form). **Five occurrences**: lines 30 (squid), 48 (refresher), 60 (policy), 80 (audit), 97 (dev-base). The template's `${VAR}` syntax is already understood by `envsubst`. If the line numbers have shifted by the time the implementing subagent reaches this file, the grep results in "Patterns to Follow" are authoritative.

### `proxy/compose-render.sh`

Add `AIDC_VERSION_TAG` to the envsubst variable list at the bottom of the file (the `exec envsubst '...'` line). Without this, envsubst leaves the `${AIDC_VERSION_TAG}` placeholder un-expanded and the rendered yaml is broken.

Also add a require-or-die at the top of the script:
```bash
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG must be set; aidc dispatcher should have exported it}"
```
Fail loudly rather than render a broken compose file.

### `scripts/cmd-mcp.sh`

The MCP image tag is **defined** at `scripts/cmd-mcp.sh:23` as `IMAGE="aidc/mcp:local"` and **consumed** at `:134-136` (build) and `:150` (run). Change the definition at `:23` to `IMAGE="aidc/mcp:${AIDC_VERSION_TAG}"`. The consumers don't need changes — they reference `$IMAGE`.

### `scripts/cmd-proxy.sh`

The forwarder image tag is **defined** at `scripts/cmd-proxy.sh:28` as `FORWARDER_IMAGE="aidc/forwarder:local"`. Change to `FORWARDER_IMAGE="aidc/forwarder:${AIDC_VERSION_TAG}"`. Both the `build_if_missing` call and the `docker run` invocation use this constant.

### `scripts/cmd-kill.sh`

Audit for any hardcoded `aidc/*:local` references; the kill flow operates on container NAMES, not image tags, so no changes expected. If grep finds any references, parameterize them; otherwise this script is unaffected.

### `tests/smoke/run.sh`

The smoke harness does NOT hardcode image tags (verified — grep for `aidc/.*:local` in the file). Smoke runs `aidc create` which produces version-tagged images via the dispatcher; smoke runs `aidc kill` which operates on names. No changes needed.

If grep DOES find image-tag references in smoke, parameterize them: `aidc/dev-base:$(tr -d '[:space:]' < VERSION)` or by reading `AIDC_VERSION` after sourcing common.sh.

### `README.md`

Two prose occurrences to update:

- `README.md:92` — the port-forwarding section mentions `aidc/forwarder:local`. Change to reference the versioned tag, or rephrase to "the aidc forwarder image" if the version is incidental to the explanation.
- `README.md:160` — the restart-vs-kill-create section mentions `aidc/dev-base:local`. Change to `aidc/dev-base:<version>` or rephrase.

Also update prose comments in `proxy/forwarder/Dockerfile:13` and `scripts/cmd-proxy.sh:10,77` (comments only, no code change there). Same treatment: reference the versioned tag or rephrase as the abstract image.

### `docs/done/design-01-architecture.md`, other design docs

The "design docs are frozen once moved to `done/`" rule applies (per `feedback-cut-complexity-when-told` and project conventions). DO NOT modify them in this task. If the design docs say `aidc/*:local` somewhere, that's a historical artifact; the requirements (REL-01) override.

---

## Implementation Notes

1. **AIDC_VERSION must be readable EVERY time the dispatcher runs.** This includes subcommands invoked over `docker exec` from another container, in shells started by the MCP server, and from CI. The `${AIDC_ROOT}/VERSION` read assumes `AIDC_ROOT` is set — confirm `scripts/aidc` sets it before the read.

2. **VERSION file content normalization.** Read the FIRST LINE only (`head -n1`), strip trailing CR (handles Windows line endings), then reject any internal whitespace in that line as malformed. Do NOT use `tr -d '[:space:]'` to swallow whitespace — that would silently concatenate `v0.1.0\tevil` into `v0.1.0evil` which passes the regex. The prescribed code in "Files to Modify → `scripts/aidc`" is authoritative.

3. **The `-dev` suffix is intentional.** Between releases, `VERSION` reads `v0.1.0-dev`. The release workflow (task-14) bumps to `v0.1.0` immediately before tagging, then bumps to `v0.1.1-dev` (or `v0.2.0-dev`) after tagging. Dev-tagged images are explicitly distinguishable from release-tagged images.

4. **Existing developer images become stale.** Anyone who pulled before this task will have `aidc/dev-base:local` (no version) sitting on disk. It's harmless but unused after this task lands. Document one-line cleanup in the PR description: `docker image ls aidc/ ; docker image rm aidc/dev-base:local aidc/squid:local aidc/refresher:local aidc/policy:local aidc/audit:local aidc/forwarder:local aidc/mcp:local 2>/dev/null || true`. Do NOT add an automatic cleanup to the codebase; that's surprising behavior.

5. **Compose template envsubst order matters.** `${AIDC_VERSION_TAG}` must be in the envsubst allowed-vars list, NOT relying on default expansion. envsubst with no args expands ALL `${...}` references, which would mangle any unrelated shell-style references in service commands. The explicit allow-list is already the established pattern in `compose-render.sh`. (`${AIDC_VERSION}` itself doesn't appear in the compose template — only the tag-safe form does — so it doesn't need to be in the allow-list for the template render. But the dispatcher exports both, so other scripts can use either form.)

6. **Smoke MUST pass after this change.** Run `make smoke` locally. If any image-tag mismatch surfaces, it's a bug introduced by this task. Fix in this PR.

7. **No CI bypass for this task.** If task-12 (CI) has landed first, this task's PR triggers smoke in CI. CI exercises the same code path as local smoke. Both must pass.

---

## Anti-patterns

- **DO NOT** hardcode the version in `scripts/aidc` as a fallback. There is ONE source of truth (`VERSION`), and a missing file is a hard error.
- **DO NOT** parse the version from `git describe --tags` even as a backup. Brew installs don't have `.git/`.
- **DO NOT** use a `latest` tag in any aidc image. Latest is a footgun: tag immutability matters for the upgrade story we're building.
- **DO NOT** retain a fallback `:local` tag for "compatibility." Old `:local` images on a user's disk are harmless but the codebase should reference only versioned tags going forward.
- **DO NOT** sed-replace `:local` in the rendered compose file post-envsubst. Option B in the design context; brittle, hides intent.
- **DO NOT** update design docs in `docs/done/` to reflect the new tag scheme. They're frozen historical records; requirements are authoritative.
- **DO NOT** put `AIDC_VERSION` in `aidc_config_defaults()` or `~/.config/aidc/config.yaml`. Version is identity (immutable per install), not configuration (mutable per user).

---

## Success Criteria

- [ ] `VERSION` file exists at repo root with content `v0.1.0-dev` (or whatever the project is at when this task ships).
- [ ] `scripts/aidc` reads `${AIDC_ROOT}/VERSION` at init, validates against the canonical regex, and exports BOTH `AIDC_VERSION` and `AIDC_VERSION_TAG` (the latter is `AIDC_VERSION` with any `+` mangled to `_`).
- [ ] A malformed VERSION (e.g. `BAD`, `v0.1`, `v0.1.0-`, or any line with whitespace inside) causes `scripts/aidc` to exit 2 with a clear message — verified by deliberately munging VERSION and running `scripts/aidc help`.
- [ ] A VERSION with build metadata like `v0.1.0+sha.abc1234` produces image tags `aidc/dev-base:v0.1.0_sha.abc1234` (note the underscore replacing the `+`). Verified by setting VERSION to that value and running `aidc create`.
- [ ] `aidc create foo` produces `aidc/dev-base:v0.1.0-dev`, `aidc/squid:v0.1.0-dev`, etc. — verify with `docker image ls aidc/`.
- [ ] Rendered compose yaml under `/tmp/aidc-foo.yaml` shows `image: aidc/squid:v0.1.0-dev` (etc.), not `:local`.
- [ ] `aidc proxy foo add 28080` builds `aidc/forwarder:v0.1.0-dev` on first invocation.
- [ ] `aidc mcp start` (if exercised in this PR) builds `aidc/mcp:v0.1.0-dev`.
- [ ] `make smoke` passes 10/10 runs after the change. (Same stability bar as task-11.)
- [ ] `grep -rn 'aidc/[a-z_-]*:local' scripts/ proxy/compose.yaml.template proxy/compose-render.sh README.md tests/smoke/` returns nothing in **active code paths**. Definition of "active code path":
  - In `.sh` / `.bash` / `Makefile` / `.py` / `.rb` files: any line not beginning with `#` (whitespace-trimmed).
  - In `.yaml` / `.yml` files: any line not beginning with `#` (whitespace-trimmed). Note that YAML inline comments after a value (`key: val # comment`) are not stripped — the `val` portion is still part of the active path.
  - In `.md` files: code fences (between ``` and ```) and inline code (between backticks) count as active code paths. Prose mentions of `aidc/foo:local` for explanatory purposes in plain prose are NOT active code paths.
  Comments in `cmd-proxy.sh` and `proxy/forwarder/Dockerfile` may retain historical references rephrased to remove `:local`, but no executable code path emits `:local`.

---

## Verification

```bash
# Confirm VERSION is read and exported
scripts/aidc help 2>&1 | head -1
env | grep AIDC_VERSION       # only set inside `scripts/aidc` subprocess; check inside

# Manual session, observe image tags
scripts/aidc create vtest --profile multi --repo "$(pwd)"
docker image ls aidc/        # all tags should be vX.Y.Z-dev or vX.Y.Z, none :local

# Render check
cat /tmp/aidc-vtest.yaml | grep '^    image:'
# should print:
#   image: aidc/squid:v0.1.0-dev
#   image: aidc/refresher:v0.1.0-dev
#   image: aidc/policy:v0.1.0-dev
#   image: aidc/audit:v0.1.0-dev
#   image: aidc/dev-base:v0.1.0-dev

# Adhoc forward, confirm forwarder version
scripts/aidc proxy vtest add 28080
docker image ls aidc/forwarder         # tag is v0.1.0-dev

# Smoke
scripts/aidc kill vtest
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "=== smoke $i ==="
    make smoke 2>&1 | grep -E '^(passed|failed)'
done

# Static checks
grep -r 'aidc/[a-z_-]*:local' scripts/ proxy/ README.md tests/smoke/
# expected: empty output
```

---

## Enforcement Test Suggestions

- [ ] No new code references `aidc/*:local`. Suggested test: a grep in `make lint` (or a separate `make grep-policy` target) that fails on any `aidc/[a-z_-]+:local` occurrence outside of comments/docs.
- [ ] **VERSION file format enforced in CI** (REQUIRED): a one-liner in CI that asserts `head -n1 VERSION | tr -d '\r' | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9]([a-zA-Z0-9.]*[a-zA-Z0-9])?)?(\+[a-zA-Z0-9]([a-zA-Z0-9.]*[a-zA-Z0-9])?)?$'`. Same regex `scripts/aidc` enforces at runtime. Catches accidental edits before they break the release workflow. Promoted from "suggested" to "required" in round 3.
- [ ] **No code path emits an image tag without the version** (REQUIRED): a grep in `make lint` that fails if any `aidc/[a-z_-]+:` reference appears in **non-comment** code in `scripts/`, `proxy/compose.yaml.template`, `proxy/compose-render.sh`, `.devcontainer/`, `mcp/` and is followed by anything other than `${AIDC_VERSION_TAG}` or the literal `v[0-9]`. The lint MUST strip `#`-prefixed comment lines from consideration so that prose comments like `# previously aidc/forwarder:local` don't trigger false positives. Catches accidental reversion to `:local`. Promoted from "suggested" to "required" in round 3.
- [ ] **Tag-namespace lint** (REQUIRED): an allowlist-based grep in `make lint`. The canonical role names are exactly: `dev-base`, `squid`, `refresher`, `policy`, `audit`, `forwarder`, `mcp`.
  - Rule 1: any image-tag reference matching `aidc/<X>:` where `<X>` is NOT in the role allowlist fails lint.
  - Rule 2: any image-tag reference matching `aidc-plugin/<vendor>/<X>:` is ACCEPTED (reserved future namespace per the Future-proofing section) but the `<vendor>` and `<X>` segments MUST each be `[a-z0-9-]+` — anything else fails lint.
  - Rule 3: any image-tag reference outside the two patterns above (e.g. typos like `aidcs/dev-base:...`, missing slashes, etc.) fails lint.
  - When a new role is added (rare; requires design doc work), update the allowlist in the same PR. The plugin pattern is reserved-but-unused in v0.1; lint allows the structure so future plugin work doesn't have to fight the lint rule.
