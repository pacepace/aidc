# Project Preferences

How code is written in this repo. Read before writing any. Reconciled from the code
itself (2026-09-17), not from a survey: everything below is what the repo already does.

## Language & Runtime

- **Languages**: bash for the CLI and the container entrypoints (`scripts/`, `.devcontainer/`,
  `proxy/`); Python for the MCP control plane (`mcp/`).
- **Versions**: bash 4+ (GNU userland assumed: `sed -i`, `stat -c`); Python 3.14 (the MCP server
  requires it, and CI tests it).
- **Package manager**: `uv`, with a committed `uv.lock`. Every command runs `uv run --frozen`.

## Code Style

- **Naming**: snake_case throughout. Private module names carry a leading underscore; a name two
  modules share is public (see `transcript.slug`).
- **Formatting / linting**: `ruff` for Python (line length 100), `shellcheck` for shell.
- **Type annotations**: required in the MCP package; `mypy` runs clean on `src/`.
- **Imports**: absolute, grouped stdlib / third-party / local, sorted by ruff.
- **Comments**: they say WHY, and name the incident or measurement behind a rule where one
  exists. A comment that narrates history ("used to be X") is deleted once the history is in
  the design doc or the changelog.
- **No private names**: aidc is public. Code, docs, tests, fixtures and `.prawduct/` records
  name none of the owner's private infrastructure, projects or people (their cluster, nodes,
  addresses, domains, routers, private repos, other projects, colleagues). Use generic terms
  ("the reference cluster", "the coordinator", "a second user") and keep specifics in the
  owner's private repos. History is not rewritten for it (owner ruling 2026-11-24).
- **Errors**: catch specific exceptions; a genuinely necessary broad catch carries
  `# prawduct:allow prawduct/broad-except -- <reason>`. Shell libraries report their own
  failures (never assume a `die` helper the caller may not have sourced).

## Testing

- **Frameworks**: `pytest` (`mcp/tests/`), plain bash suites (`tests/unit/*.sh`), plus
  `tests/smoke/` for the Docker-dependent paths.
- **Style**: test names are sentences about behaviour ("a reply left in a damaged transcript is
  still delivered"), and every test says what breaks if it fails. Fixtures are real captures
  (transcript JSONL, tmux screens) wherever a real one exists.
- **Coverage expectations**: happy path plus the failure the change exists to prevent. A fix
  lands with a test that fails without it — checked by disabling the fix, not assumed.
- **Test location**: `mcp/tests/` for Python; `tests/unit/` for shell (no Docker, CI runs them
  all); `tests/smoke/` when a real daemon is needed.
- **Docker in tests**: stub `docker` on PATH; a test that needs a real daemon goes in smoke.

## Architecture Patterns

- **Data modeling**: frozen dataclasses for read models (`Turn`, `SessionState`, `ScreenState`);
  plain dicts only at the wire boundary.
- **Module split**: `transcript.py` is the pure core (parsing, delivery decisions, persistence
  helpers) with no I/O of its own; `screen.py` and `scope.py` own one concept each; the service
  package `service/` holds the send queue, the watchers, delivery, resume and the session
  operations, with no MCP or 3tears types (`test_service_boundary`), its state in
  `service/state.py`; `tearstools/` holds one 3tears `TearsTool` per tool over it (schemas and
  descriptions, no MCP types); `authz.py` the scope and taint refusals as the framework's
  authorizer; `server.py` the local MCP face (3tears-mcp's `McpServer` and the error codes);
  `auth.py` the bearer gate in front of it; `resources.py` the MCP resources.
- **State**: anything that must survive a restart is a row of the 3tears state store
  (`store.py`: one SQLite L3 file, `aidc-state.sqlite`, in the watcher-state dir), written
  through `transcript.py`'s persistence functions, never a new file beside it (the files there
  are 1.x's, read in once at upgrade). In-memory caches are derived, never the source of truth.
  (Amended 2026-11-26 by the 2026-11-25 ruling on design-13 Q4, TRS-25 option A.)
- **Contracts**: the MCP tool envelope and the callback payload are pinned in
  `docs/design-10-turn-state-and-sending.md` (D5/D6) and change only by agreement with the
  orchestrator, additively.

## Tooling

- **Tests**: `cd mcp && uv run --frozen pytest -q`, then `for t in tests/unit/*.sh; do bash "$t"; done`.
- **Lint/types**: `uv run --frozen --extra dev ruff check .` and `mypy src`; `shellcheck` for shell.
- **CI**: `.github/workflows/ci.yml` runs shellcheck (advisory), every `tests/unit/*.sh`
  (blocking), and the MCP suite on Python 3.14.
- **Commit attribution**: none, ever (see CLAUDE.md). Merge commits, PRs onto `develop`.
