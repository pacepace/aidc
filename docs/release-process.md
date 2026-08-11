# Release process

The operator checklist for cutting an aidc release. The automation half lives in
`.github/workflows/release.yml`; this file is the human half. Background/design:
`docs/done/task-14-release-and-brew-tap.md`.

## TL;DR

```bash
# on a branch off develop
vim VERSION CHANGELOG.md mcp/pyproject.toml mcp/src/aidc_mcp/__init__.py
(cd mcp && uv lock)                 # pick up the pyproject version bump
make lint && (cd mcp && uv run pytest)
make smoke                          # THE pre-tag gate. CI does not run this.
# PR -> develop -> main, then:
git checkout main && git pull
git tag vX.Y.Z && git push origin vX.Y.Z
```

The tag push triggers `release.yml`, which creates the GitHub Release and (if the
tap token is configured) updates the Homebrew tap.

## 1. Bump every version reference together

One `chore(release):` commit updates all of these — no built image may be left at
an uncommitted version:

- `VERSION` — canonical, `v`-prefixed (e.g. `v1.0.0`). Single source of truth for
  the CLI and image tags.
- `mcp/pyproject.toml` + `mcp/src/aidc_mcp/__init__.py` — no `v` prefix.
- `mcp/uv.lock` — regenerate with `cd mcp && uv lock`.
- `CHANGELOG.md` — move `[Unreleased]` content into a dated `[X.Y.Z]` section and
  add its link definition.

## 2. Gates (all local except CI's cheap checks)

- `make lint` — shellcheck over `scripts/` and `proxy/`.
- `cd mcp && uv run pytest && uv run ruff check . && uv run mypy src`.
- `bash release/lint-formula-template.sh` — formula-template allowlist (CI also
  blocks on this).
- **`make smoke` — mandatory before tagging.** Since 0.6.1 smoke does not run on
  hosted CI at all (`smoke.yml` is `workflow_call`-only); this local run is the
  only end-to-end validation a release gets.

## 3. Merge and tag

Releases flow `feature/* → develop → main` (see CONTRIBUTING.md). Tag the `main`
merge commit; `release.yml` verifies tag ↔ commit ↔ `VERSION` agreement and fails
the release on any mismatch.

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```

## 4. What the workflow does with the tag

1. Validates the tag format and that it matches `VERSION` and the checked-out
   commit (TOCTOU-checked before and after download).
2. Downloads the tag archive from codeload — the same byte stream users and
   `brew` fetch via `archive/refs/tags/vX.Y.Z.tar.gz` — and computes its sha256.
3. Runs both tarball audits (`release/tarball-audit.sh` against the git tree,
   `release/tarball-audit-extracted.sh` against the extracted tarball).
4. Creates the GitHub Release with auto-generated notes.
5. If the tap PAT secret is set: renders `Formula/aidc.rb` and
   `Formula/aidc@MAJOR.MINOR.rb` from `release/Formula/*.tmpl` and pushes them to
   `pacepace/homebrew-aidc`. If the secret is absent the tap step is skipped with
   a notice and the Release still ships.

`workflow_dispatch` on an existing tag is a **dry-run only** — it exercises every
step except the two with side effects. Use it to verify token rotation.

## 5. Homebrew tap

- The tap repo is `pacepace/homebrew-aidc` (public; `Formula/` dir). Users:
  `brew tap pacepace/aidc && brew install aidc`.
- The PAT lives in the secret named `TAP_REPO_TOKEN_EXPIRES_<date>` — a
  fine-scoped token with contents write on the tap repo only. Rotate before the
  date in the name; verify rotation with a dry-run dispatch.
- Manual first-time seeding (before automation): see `Formula/README.md`.
- After a release that touches the formula, validate on a Mac:
  `brew update && brew audit --strict aidc && brew install aidc && brew test aidc`.

## 6. After the release

- Check the Release page rendered notes sensibly.
- `brew install aidc` (or `brew upgrade aidc`) on a Docker-equipped machine and
  run `aidc help` + a real `aidc create` as a post-ship sanity check.
- Announce/close out anything the release resolves.
