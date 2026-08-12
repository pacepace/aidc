# Contributing to aidc

Thanks for helping improve aidc. This is a small, security-sensitive project — a sandbox for
running an autonomous coding agent — so changes are reviewed with the isolation guarantees in
mind. Keep contributions focused and verifiable.

## Development setup

You need the same runtime prerequisites as a user (see the README's *Requirements*): Docker,
`bash`, `jq`, `docker compose`, and `yq`. For the MCP control plane and its tests you also
need [`uv`](https://docs.astral.sh/uv/).

```bash
git clone git@github.com:pacepace/aidc.git
cd aidc
make install        # symlink scripts/aidc into ~/.local/bin
```

## Branching workflow (gitflow)

The repo follows gitflow:

- **`main`** — released, tagged code only. Protected; merges require admin.
- **`develop`** — integration branch; everything lands here first.
- **`feature/<name>`** (or `fix/<name>`) — branch off `develop`, do the work, open a PR back
  into `develop`.

Releases flow `feature/* → develop → main`. Never commit directly to `main` or `develop`;
open a pull request. Every PR gets an independent review before merge.

## Build, lint, and test

Run these before opening a PR — they are the project's enforcement gates:

```bash
# Shell scripts (the aidc CLI + proxy sidecars)
make lint            # shellcheck over scripts/ and proxy/

# MCP control-plane unit tests (Python)
cd mcp && uv run pytest      # pytest + pytest-asyncio; add --extra dev if pytest is missing

# End-to-end isolation smoke test (spins a real multi-container session)
make smoke           # bash tests/smoke/run.sh — 36 assertions, ~1-2 minutes
```

`make smoke` is the primary enforcement harness: it brings up a real session and asserts the
isolation, git-asymmetry, DinD, proxy allow/deny, taint, and audit guarantees end-to-end. It
writes only under `tests/scratch/` (gitignored) and tears the session down on every exit path,
so it never touches your host home. CI does not run it (see *Releases* below), so run it
locally for any change that touches the CLI, proxy, or container wiring.

If you change behavior, add or update a test (a shell assertion in `tests/smoke/run.sh` or a
unit test under `mcp/tests/`) that pins it. Design docs and finished task shards live under
`docs/`; move a design doc into `docs/done/` once it ships.

## Commit conventions

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): imperative summary
```

- **types** seen in history: `feat`, `fix`, `chore`, `docs`.
- **scope** is the area touched, e.g. `mcp`, `dev`, `proxy`, `release`.
- append `!` for a breaking change: `feat(mcp)!: make session_send non-blocking`.

Keep the summary short and imperative. Explain the *why* in the body when it isn't obvious.

### Releases

A release is a `chore(release):` commit that bumps every version reference together (the
`VERSION` file, `mcp/pyproject.toml`, and the image tags) so no built image is left at an
uncommitted version, followed by a tag on `main` and a GitHub release. Pushing the tag
triggers nothing on its own; **publishing the GitHub Release** (with hand-written notes) is
what fires the release workflow, which validates the tag — including that its commit is on
`main` — and updates the Homebrew tap. Update `CHANGELOG.md` in the same change. Full
operator checklist: `docs/release-process.md`.

**Run `make smoke` locally before tagging.** CI does not run it. The smoke harness builds
the full dev-base image and stands up a real session, which on a 2-core GitHub-hosted runner
meant ~15 minutes of image build to execute ~53 seconds of assertions — and failed twice on
runner disk limits rather than on real defects. The same run takes a couple of minutes on a
developer machine where the image is already cached, so it belongs there. `.github/workflows/
smoke.yml` is retained for `workflow_call` only, in case a self-hosted runner is ever added.

CI still gates every push and PR on the cheap checks: shellcheck, the Homebrew formula-template
lint, the shell unit tests, and the MCP suite (pytest + ruff + mypy on Python 3.12 and 3.14).

## Governance

This repository is governed by **[Prawduct](https://github.com/pacepace/prawduct)** — its
build cycle, planning method, and independent Critic/PR review shape how work is scoped and
merged. Governance artifacts are written locally under `.prawduct/` and are gitignored (not
committed). If you have the Prawduct plugin installed, its skills (`prawduct:building`,
`prawduct:planning`, `prawduct:pr`, …) drive the workflow; if not, the practical rules above
are what matter: branch off `develop`, keep changes verifiable, run the gates, and open a PR.
