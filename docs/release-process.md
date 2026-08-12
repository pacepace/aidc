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
git tag -a vX.Y.Z -m "aidc vX.Y.Z" && git push origin vX.Y.Z
gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file <notes> install.sh
```

Pushing the tag triggers nothing by itself. **Publishing the GitHub Release**
(with hand-written notes, and `install.sh` attached as an asset — it serves the
documented `releases/latest/download/install.sh` bootstrap URL) triggers
`release.yml`, which validates the release — tag format, `VERSION` sync,
tag-commit-on-main, asset-matches-tree — audits the tarball, and (if the tap
token is configured) updates the Homebrew tap.

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

## 3. Merge, tag, publish

Releases flow `feature/* → develop → main` (see CONTRIBUTING.md). Tag the `main`
merge commit — the workflow refuses any tag whose commit is not on `main` — then
publish the GitHub Release for it. Write the release notes by hand (summarize
the CHANGELOG section; notes are for users, not a commit dump).

```bash
git tag -a vX.Y.Z -m "aidc vX.Y.Z" && git push origin vX.Y.Z
gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file <notes> install.sh
```

The title is the bare tag, e.g. `v1.0.0`. `--verify-tag` refuses to publish if
the tag doesn't already exist — publishing is deliberate, never tag-creating.
Attach `install.sh` (run the command from the tag's checkout so the asset is the
tagged tree's copy) — it serves the README's
`releases/latest/download/install.sh` bootstrap URL, and the workflow fails the
release if the asset is missing or differs from the tagged tree.

## 4. What the workflow does when the release is published

1. Validates the tag format and that it matches `VERSION` and the checked-out
   commit (TOCTOU-checked before and after download).
2. Verifies the tagged commit is on `main` (compare status `identical`/`behind`);
   a tag on unreleased work fails the run.
3. Downloads the tag archive from codeload — the same byte stream users and
   `brew` fetch via `archive/refs/tags/vX.Y.Z.tar.gz` — and computes its sha256.
4. Runs both tarball audits (`release/tarball-audit.sh` against the git tree,
   `release/tarball-audit-extracted.sh` against the extracted tarball).
5. Verifies the Release's `install.sh` asset is byte-identical to the tagged
   tree's `install.sh` (real releases only; dry-runs skip this).
6. If the tap PAT secret is set: renders `Formula/aidc.rb` and
   `Formula/aidc@MAJOR.MINOR.rb` from `release/Formula/*.tmpl` and pushes them to
   `pacepace/homebrew-aidc`. If the secret is absent the tap step is skipped with
   a notice.

If validation fails, the published Release is already public — fix the problem,
delete the Release **and** the tag, and redo the tag + publish. Don't leave a
Release whose validation run is red.

`workflow_dispatch` on an existing tag is a **dry-run only** — it exercises
everything except the asset check and the tap push. Use it to verify token
rotation.

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
