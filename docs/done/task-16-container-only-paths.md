# task-16: Container-Only Paths (Per-Project Venv / Node / Build Overlays)

## Objective

Let each project declare a list of paths that MUST be container-only — overlaid by a Docker named volume so the host's same-named directory (a host venv with macOS-arm64 wheels, for example) is invisible to the container, and the container's writes (linux/amd64 wheels) don't leak back to host. Configurable per repo AND per workspace (workspace declaration covers multiple sibling repos at once). Glob patterns supported so monorepos can match `packages/*/node_modules`.

This is the explicit-opt-in version of the venv-overlay design that got shelved last week as too magic. Pace is now hitting the cross-arch venv-collision problem in practice, and the project-declares-what-it-needs framing avoids the "auto-detect every framework's cache dir" rabbit hole.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| CLI-18 | `aidc create` MUST honor a per-repo `container_only_paths:` list in `<repo>/.aidc/config.yaml` AND a workspace-level `container_only_paths:` list at `<workspace>/.aidc/config.yaml` when `--workspace` is in use. Each list entry is a path (supporting glob patterns like `packages/*/node_modules`) resolved relative to the workspace root. For each resolved path, `aidc create` MUST mount a session-scoped Docker named volume on top of that path inside the dev container so the container sees its own empty directory while the host's same-named directory remains untouched and invisible from inside the container. The host's directory MAY contain a different-platform venv / node_modules / target / etc.; the overlay isolates the container's filesystem at that path from the host's. | P0 |
| CLI-19 | Container-only-path volumes (CLI-18) MUST be session-scoped (named `aidc-sovl-<session>-<path-slug>`); `aidc kill` MUST remove them. `aidc create` against the same repo a second time gets a fresh empty overlay (and thus a fresh `uv sync` / `npm install` / `cargo build` cost). | P0 |
| CLI-20 | `aidc clean-env <session>` MUST remove all overlay volumes for the named session. `aidc clean-env --project <path>` MUST remove all overlay volumes whose name encodes the named project path, regardless of session. Both forms list volumes before deletion and prompt for y/N (override with `--yes`). | P1 |

---

## Design Context

### The collision we're closing

A Python project's `.venv/` directory holds an installed Python interpreter (typically a symlink to a specific binary) plus compiled wheels matching that interpreter's OS+arch. Mounting the host's repo into the dev container (which we always do, per CTR-* requirements) means the container sees host's `.venv/` — pointing at host's Python and host's wheels. When the container runs `uv sync` or activates the venv, things break in interesting ways:

- On macOS-arm64 host + linux-arm64 container: same arch, but glibc vs Apple's libSystem, plus the Python interpreter path differs.
- On macOS-arm64 host + linux/amd64 container (Docker Desktop's emulated case): different arch entirely, native wheels are wrong.
- WSL2 amd64 → linux/amd64 container: same arch and libc, may actually work — but the Python interpreter binary path still differs.

Same logic applies to Node (`node_modules/` with native addons: `better-sqlite3`, `sharp`, `esbuild`, `node-gyp` builds), Rust (`target/` is per-toolchain), Go build artifacts, tox envs, nox envs, and most language-cache directories. Once the dev container starts emitting binaries into the repo, the host either sees broken binaries or (worse) silently uses them and gets confusing import errors.

The fix is to isolate these directories at the filesystem layer: host gets its own, container gets its own, they don't see each other.

### Why explicit opt-in per project

The previous design attempt baked a default list (`.venv`, `node_modules`, `target`, etc.) into the codebase and made it opt-out. Pace ruled that out: each project knows what it needs better than the framework knows. A pure-Python project doesn't need `node_modules/`. A monorepo with shared workspaces wants different paths than a single-package repo. The framework's job is to enforce the mechanism; the project's job is to declare what gets mechanized.

### Why workspace-level too

A typical setup runs with `--workspace ~/code/myorg` mounting several sibling repos. Many of them have the same overlay needs. Without workspace-level config, every sibling repo has to copy-paste the same `container_only_paths` list. With workspace-level config, the workspace declares the common defaults and individual repos can extend them.

Resolution order (later overrides earlier for scalar fields; for the `container_only_paths` LIST, later entries are appended-and-deduped):

1. Workspace config: `<workspace>/.aidc/config.yaml`
2. Repo config: `<repo>/.aidc/config.yaml`

Both lists are aggregated. No mechanism to subtract — the workspace can't forbid a repo from adding overlays.

### Why glob patterns

Some real cases:
- Single-package: `.venv` (literal, single-level).
- Monorepo: `packages/*/node_modules` (glob matching N siblings).
- Mixed: `[.venv, packages/*/node_modules, services/*/target]`.

Glob expansion happens at `aidc create` time, against the workspace root, with the workspace itself as cwd. `*` matches anything (excluding `/`); `**` is NOT supported in v1 (recursive matching is a footgun — a misplaced `**` matches `.git/` and explodes); `?` matches a single char; brace expansion is NOT supported. The implementation uses bash's built-in glob (set the right shopt flags); shell out only if bash's globbing is unavailable.

### Why session-scoped (not project-scoped)

Two same-repo `aidc create` calls would share a project-scoped volume. If the user runs `pytest` in both simultaneously, the venv's lock files collide. Session-scoped guarantees isolation: each `aidc create` gets its own empty overlay. Cost: each new session pays the re-sync cost (`uv sync` ~30s, `npm install` ~1-3min). Acceptable; sessions are not so frequent that this dominates.

Volume name: `aidc-sovl-<session>-<path-slug>` where `<path-slug>` is the overlay's container path with `/` replaced by `-` and leading dot replaced (`.venv` → `dotvenv`; `packages/web/node_modules` → `packages-web-node_modules`). Slug rules below in Implementation Notes.

`aidc kill` already iterates session-scoped resources via `docker compose down -v`. Overlay volumes get declared in the rendered compose file so compose down nukes them.

### Committed venv is the user's problem

If a project commits `.venv/` to git (bad practice), the overlay shadows those files from the container. Container can't see them, host still can. Documented as a known sharp edge; we don't validate, warn, or auto-detect. Pace's framing: "if you are committing platform virtual environments then you have caused a nightmare already and we're not here to train jr devs on not being fools."

---

## Research

- Docker named volumes overlaying bind-mount subpaths: https://docs.docker.com/storage/volumes/ — a named volume mounted at a subpath of a bind mount shadows the bind mount at that subpath, which is exactly the semantics we want
- Bash globbing options: `shopt -s nullglob` (so no-match returns empty rather than the literal pattern) and `shopt -s dotglob` (NOT enabled here — overlay paths starting with `.` should match `.venv` literally, not by globbing)
- yq for parsing nested YAML list fields with potential globs: the existing `_aidc_yaml_list` helper at `scripts/lib/config.sh:138` already handles top-level YAML lists; we extend usage, no new parser

---

## Patterns to Follow

- Config list-loading: `_aidc_yaml_list` at `scripts/lib/config.sh:138` (already handles both flow `[a, b]` and block `- a\n- b` styles)
- Config list aggregation across global + project: `scripts/lib/config.sh:244-253` (existing `tlds`, `adds`, `ports` aggregation pattern)
- Per-session named volume declaration in compose template: `proxy/compose.yaml.template:8-16` (existing pattern for `blocklist`, `state`, `squid-log`, etc.)
- Per-service volume mount in compose template: `proxy/compose.yaml.template:128-138` (existing pattern under the `dev:` service)
- Session resource cleanup on kill: `scripts/cmd-kill.sh:48-53` (`docker compose down -v --remove-orphans` already nukes named volumes; if we declare overlays in the compose file, they ride this cleanup for free)
- Confirmation-prompt pattern with `--yes` override: NEW; the cleanest similar pattern is `aidc-claude` wrapper's mode dispatch but that's not interactive. Implement fresh.

---

## Files to Create

### `scripts/cmd-clean-env.sh`

New subcommand. Two flavors:

- `aidc clean-env <session>` — list and remove all `aidc-sovl-<session>-*` volumes for the named session. Requires the session NOT be running (refuse with a clear error if `session_exists`). Since `aidc kill` already removes session-scoped overlay volumes, this command is for the edge case where someone has stray volumes from a botched session that didn't clean up.
- `aidc clean-env --project <path>` — list and remove all `aidc-sovl-*-<path-slug>` volumes whose encoded project path matches. Useful when you want to clear out a repo's volumes across many killed sessions.
- Both forms list the volumes they're about to delete, prompt for y/N (skip with `--yes`), and remove with `docker volume rm`.

Required behavior:
- Reuses `validate_session_name` from `lib/common.sh` for the session form.
- Reuses `realpath_portable` + the path-encoding logic for the project form.
- On success, prints the count of removed volumes.
- Idempotent: no volumes matching the filter → "nothing to remove" + exit 0.

---

## Files to Modify

### `scripts/lib/config.sh`

Add `AIDC_CONTAINER_ONLY_PATHS` to `aidc_config_defaults()` (empty string default). Extend `load_config` to read the `container_only_paths` list from BOTH the workspace config (if present) AND the repo config, aggregating and deduping in the same pattern as the existing `tlds` / `adds` / `ports` lists.

Important: today's `load_config` takes a single project_dir arg. Extend to optionally take a workspace_dir as a second arg; when set, also read `<workspace_dir>/.aidc/config.yaml`. Callers pass `--workspace`'s resolved path as the second arg when relevant.

Update `emit_loaded_config_yaml` to include the resolved (post-glob-expansion) `container_only_paths` list in the audit dir's `config-snapshot.yaml`.

### `scripts/cmd-create.sh`

After config-load, expand glob patterns. Bash builtin globbing in workspace cwd:

```bash
# Run inside a subshell so we don't perturb the caller's pwd/shopt.
_aidc_expand_overlay_paths() {
    local ws="$1"
    local raw_list="$2"
    (
        cd "$ws" || return 1
        shopt -s nullglob
        while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue
            # Reject patterns containing ** (recursive globbing -- footgun).
            case "$pattern" in
                *'**'*) printf 'ERROR: ** is not supported in container_only_paths: %s\n' "$pattern" >&2; return 1 ;;
            esac
            # Reject absolute paths and parent traversals.
            case "$pattern" in
                /*|*..*) printf 'ERROR: container_only_paths entries must be relative within the workspace: %s\n' "$pattern" >&2; return 1 ;;
            esac
            # Expand. If no matches, nullglob makes this loop iterate zero times.
            local match
            for match in $pattern; do
                # Output absolute container path (since workspace is mirrored at the same path inside).
                printf '%s/%s\n' "$ws" "$match"
            done
            # Emit the pattern even if no match -- creates the dir at container start and overlays it.
            # This handles the "I declared .venv but haven't run uv sync yet" case.
            if ! eval "ls -d $pattern 2>/dev/null" >/dev/null; then
                printf '%s/%s\n' "$ws" "$pattern"
            fi
        done <<<"$raw_list"
    )
}
```

NOTE the "emit even if no match" branch: needed because the user can legitimately declare `.venv` before the host has one. The overlay creates the dir at container start.

After expansion, render the overlay volumes into the compose template (see template change below) and pass through `envsubst`.

### `scripts/cmd-kill.sh`

No changes IF overlays are declared as compose-managed named volumes (which they will be — see template change below). `docker compose down -v` already handles them.

Add an extra defensive sweep AFTER compose down (mirroring the existing pattern at `cmd-kill.sh:55-59`):
```bash
# Sweep any container-only-path overlay volumes that escaped compose-managed
# cleanup (e.g. a session that died mid-create before compose tracked them).
sovl_vols=$(docker volume ls --filter "name=aidc-sovl-${NAME}-" -q 2>/dev/null || true)
if [ -n "$sovl_vols" ]; then
    info "removing container-only-path overlay volumes"
    printf '%s\n' "$sovl_vols" | xargs docker volume rm >/dev/null 2>&1 || true
fi
```

### `scripts/cmd-help.sh`

No changes — auto-discovery from `# desc:` line of cmd-clean-env.sh handles it.

### `proxy/compose.yaml.template`

Add a `${OVERLAY_VOLUMES_DECLARATIONS}` placeholder under the top-level `volumes:` block, and a `${OVERLAY_VOLUMES_MOUNTS}` placeholder under the `dev:` service's `volumes:` block.

```yaml
volumes:
  blocklist:
    name: aidc-${SESSION}-blocklist
  # ... existing volumes ...
  pyenv-versions:
    name: aidc-pyenv-versions
    external: true
${OVERLAY_VOLUMES_DECLARATIONS}

# ... dev service ...
    volumes:
      - ${WORKSPACE_PATH}:${WORKSPACE_PATH}:rw
      - dev-home:/home/vscode:rw
      - pyenv-versions:/usr/local/pyenv/versions:rw
      - ${AUDIT_DIR}:/var/aidc/audit:ro
      ${CLAUDE_MEMORY_MOUNT}
      ${CLAUDE_CREDS_MOUNT}
      ${CLAUDE_SETTINGS_MOUNT}
      ${CLAUDE_STATE_MOUNT}
${OVERLAY_VOLUMES_MOUNTS}
```

`cmd-create.sh` builds the strings for those two placeholders. Empty strings collapse to blank lines (envsubst handles this fine; the rendered yaml just has extra whitespace).

Example: for paths `["/workspace/foo/.venv", "/workspace/foo/packages/web/node_modules"]`, render:

```yaml
# OVERLAY_VOLUMES_DECLARATIONS:
  aidc-sovl-foo-dotvenv:
    name: aidc-sovl-foo-dotvenv
  aidc-sovl-foo-packages-web-node_modules:
    name: aidc-sovl-foo-packages-web-node_modules

# OVERLAY_VOLUMES_MOUNTS (under dev: -> volumes:):
      - aidc-sovl-foo-dotvenv:/workspace/foo/.venv:rw
      - aidc-sovl-foo-packages-web-node_modules:/workspace/foo/packages/web/node_modules:rw
```

### `proxy/compose-render.sh`

Add `${OVERLAY_VOLUMES_DECLARATIONS}` and `${OVERLAY_VOLUMES_MOUNTS}` to the envsubst allow-list at the bottom of the file. Add the `: "${VAR:=}"` defaults at the top so missing values render as empty strings.

### `README.md`

Add a subsection under "Use" explaining the feature. Sample:

```markdown
### Container-only directories (venv / node_modules / target)

Cross-platform problem: your host is macOS arm64 and your dev container is
Linux. If the container writes its venv into the repo's `.venv/`, the host
sees Linux wheels for a Linux Python interpreter -- and vice versa. You
end up with one of them broken any time you run tooling on the other side.

Fix: declare paths that should live inside the container only. The host's
same-named directory is left alone; the container gets its own empty
directory to populate.

In `<repo>/.aidc/config.yaml`:

    container_only_paths:
      - .venv
      - node_modules

For workspaces with many sibling repos sharing the same needs, declare
once at `<workspace>/.aidc/config.yaml` instead of in every repo. Glob
patterns supported for monorepos:

    container_only_paths:
      - .venv
      - packages/*/node_modules

Each overlay is session-scoped: a fresh `aidc create` gets a fresh empty
overlay, so the first `uv sync` / `npm install` repopulates it.
`aidc kill` removes the overlay volumes.

If overlay volumes ever pile up from botched sessions, clean them with
`aidc clean-env <session>` or `aidc clean-env --project <repo-path>`.

`**` (recursive glob) is NOT supported -- the footgun risk is too high.
Use explicit `packages/*` / `services/*` paths instead.
```

### `docs/requirements.md`

Already updated in advance of this shard. CLI-18 / CLI-19 / CLI-20 are in place.

### `tests/smoke/run.sh`

Add a new step exercising container-only-paths:

```
[N/M] container-only-paths
  - create a session with container_only_paths: [.venv] in .aidc/config.yaml
  - verify the overlay volume aidc-sovl-<session>-dotvenv exists
  - verify dev_exec touching /workspace/repo/.venv/sentinel succeeds
  - verify the host's repo path does NOT have a .venv/sentinel
  - aidc kill removes the volume
```

Add to the smoke test BEFORE the kill step (currently step [9/10]).

---

## Implementation Notes

1. **Path-slug rules.** Container paths get encoded into volume names. Rules:
   - Lowercase only (Docker requires).
   - Replace `/` with `-`.
   - Replace leading `.` with `dot` (so `.venv` → `dotvenv`, `.tox` → `dottox`).
   - Underscores and digits pass through unchanged.
   - Final string MUST match `^[a-z0-9][a-z0-9_-]*$` per Docker's volume-name rules.
   - Reject any other character with a clear error at `aidc create` time.

2. **Glob expansion happens at `aidc create` time, NOT at compose render time.** Expansion writes the resolved list of paths into the rendered compose file. If the user adds a new monorepo package after `aidc create`, they need to `aidc kill && aidc create` for the new path to be overlaid. Acceptable — adding a new package is rare and already requires a fresh dependency install.

3. **Both workspace and repo configs are read; lists aggregate.** Workspace declarations apply to ALL sibling repos visible in the workspace mount. Repo declarations apply only within that repo's tree. Glob expansion produces paths under the workspace root; the volume name encodes the relative-to-workspace path.

4. **Subshell discipline for the glob expansion.** `shopt -s nullglob` is process-global within the subshell; using `(...)` (subshell, not `{...}`) means we don't leak the shopt change back to the caller. The implementation example above wraps in `(...)` for exactly this reason.

5. **`**` is forbidden.** Bash 4+ supports `globstar` (recursive matching). It's not enabled by default and we don't enable it. Reject any pattern containing `**` with a clear error. Rationale: a stray `**` is the difference between matching `packages/web/node_modules` and matching every `node_modules` anywhere in the tree — including ones the user didn't intend, like `.git/objects/pack/something`. Explicit `packages/*` is safer.

6. **Absolute paths and `..` traversal forbidden.** Volume mounts at `/etc/` or `../sibling-repo/.venv` are denied. Pattern must be a relative path inside the workspace.

7. **Empty list = no change in behavior.** If no project declares `container_only_paths`, no overlays are mounted, no new volumes are created, behavior is identical to today.

8. **`emit_loaded_config_yaml` snapshot.** The audit dir's `config-snapshot.yaml` should show the POST-EXPANSION list of paths (the actual paths the volumes are mounted at), not the raw glob patterns. This is the forensic record of what the session actually saw.

9. **The "I declared `.venv` but haven't run anything yet" case.** A bare `.venv` pattern in a fresh repo matches nothing in glob expansion. The implementation MUST still emit a volume mount for it (the path is created in the container at mount time). The example expansion function above handles this via the "no match -> emit the literal pattern" branch.

10. **clean-env's two modes share most of their code.** Both build a list of volumes to delete by name pattern, both prompt, both delete. Factor the shared logic into a helper.

---

## Anti-patterns

- **DO NOT** ship a `default` shorthand or a baked-in default list. Pace's explicit decision: explicit lists only, so we're not fighting defaults. No `[.venv, node_modules, target, ...]` autodefault.
- **DO NOT** enable bash `globstar` (`**`). Footgun; rejected per design.
- **DO NOT** make overlays project-scoped (survive across `aidc kill`). They're session-scoped per CLI-19; concurrent sessions get isolated environments.
- **DO NOT** warn on committed `.venv/` (i.e., `.venv/` appearing in `git ls-tree`). Pace's framing: not our job.
- **DO NOT** auto-detect framework cache dirs (`.next/`, `.parcel-cache/`, etc.) and add them to overlays. Project declares what it wants.
- **DO NOT** validate that the host's repo has a `.gitignore` covering the overlay paths. Same rationale.
- **DO NOT** apply workspace config when `--workspace` was NOT passed to `aidc create`. The workspace config file may exist, but if the user didn't opt into workspace mounting, we don't read it.
- **DO NOT** allow workspace config to be sourced from outside the workspace root via symlinks or includes. `<workspace>/.aidc/config.yaml` is the literal path; we don't follow indirection.
- **DO NOT** support brace expansion (`{a,b}.tmpl`) in glob patterns. Globs only — `*`, `?`. Predictability trumps expressiveness.

---

## Success Criteria

- [ ] A project with `container_only_paths: [.venv]` in `<repo>/.aidc/config.yaml` produces a rendered compose file with the overlay volume declared AND mounted at the dev service's `<repo>/.venv` path.
- [ ] After `aidc create`, `docker volume ls --filter name=aidc-sovl-` shows the new volume(s).
- [ ] Inside the dev container, touching `<repo>/.venv/sentinel` succeeds; the host's `<repo>/.venv/sentinel` does NOT appear.
- [ ] Conversely, the host's `<repo>/.venv/sentinel-host` (if any) is NOT visible from inside the dev container at `<repo>/.venv/`.
- [ ] Workspace config: a `<workspace>/.aidc/config.yaml` with `container_only_paths: [.venv]` applies to every sibling repo's `.venv/` when `--workspace` is used. The repo's own `.aidc/config.yaml` may extend (aggregate); cannot subtract.
- [ ] Glob: `packages/*/node_modules` expands to all matching paths at `aidc create` time. Adding a new `packages/<new>/node_modules` after create requires `aidc kill && aidc create` to pick up.
- [ ] `**` in a pattern fails create with a clear error.
- [ ] Absolute paths or `..`-containing patterns fail create with a clear error.
- [ ] Two concurrent `aidc create` calls against the same repo each get their OWN overlay volumes (different session names → different volume names per CLI-19).
- [ ] `aidc kill` removes the overlay volumes (`docker volume ls --filter name=aidc-sovl-<killed-session>-` returns empty).
- [ ] `aidc clean-env <session>` against a NON-running session removes the session's overlay volumes; prompts for y/N; respects `--yes`.
- [ ] `aidc clean-env <session>` against a RUNNING session refuses with a clear error.
- [ ] `aidc clean-env --project <repo-path>` removes overlay volumes whose name encodes that repo path, across any session; prompts for y/N; respects `--yes`.
- [ ] `aidc clean-env` with no matches prints "nothing to remove" and exits 0.
- [ ] Audit dir's `config-snapshot.yaml` shows the POST-EXPANSION list of overlay paths (not the raw glob patterns).
- [ ] No `container_only_paths` declared anywhere → behavior identical to today; no new volumes, no compose changes.
- [ ] `make smoke` passes 10/10 after this change, including the new container-only-paths step.

---

## Verification

```bash
# Setup: a repo with one Python project
mkdir -p /tmp/aidc-ov-test
cd /tmp/aidc-ov-test
git init -q
mkdir -p .aidc
cat > .aidc/config.yaml <<'EOF'
container_only_paths:
  - .venv
EOF

# Create a session and verify the overlay is in place
scripts/aidc create ovtest --profile python --repo /tmp/aidc-ov-test
docker volume ls --filter name=aidc-sovl-ovtest-
# expect: aidc-sovl-ovtest-dotvenv

# Inside the container, populate .venv; verify host doesn't see it
docker exec aidc-ovtest-dev bash -c 'mkdir -p /tmp/aidc-ov-test/.venv && touch /tmp/aidc-ov-test/.venv/sentinel-container'
ls /tmp/aidc-ov-test/.venv 2>/dev/null
# expect: empty or "No such file or directory" -- the container's .venv is on the volume, not the host bind mount

# Conversely, host writes are not visible inside
mkdir -p /tmp/aidc-ov-test/.venv 2>/dev/null
touch /tmp/aidc-ov-test/.venv/sentinel-host 2>/dev/null   # may fail because the mount masks; that's fine
docker exec aidc-ovtest-dev ls /tmp/aidc-ov-test/.venv/
# expect: sentinel-container only

# Kill and verify volume is gone
scripts/aidc kill ovtest
docker volume ls --filter name=aidc-sovl-ovtest-
# expect: empty

# Recreate -- fresh empty overlay
scripts/aidc create ovtest --profile python --repo /tmp/aidc-ov-test
docker exec aidc-ovtest-dev ls /tmp/aidc-ov-test/.venv/
# expect: empty -- previous session's sentinel is gone (session-scoped per CLI-19)
scripts/aidc kill ovtest

# Glob test
mkdir -p /tmp/aidc-ov-mono/{packages/{a,b,c},.aidc}
cd /tmp/aidc-ov-mono
git init -q
cat > .aidc/config.yaml <<'EOF'
container_only_paths:
  - packages/*/node_modules
EOF
scripts/aidc create monotest --profile node --repo /tmp/aidc-ov-mono
docker volume ls --filter name=aidc-sovl-monotest-
# expect: three volumes (packages-a-node_modules, packages-b-node_modules, packages-c-node_modules)
scripts/aidc kill monotest

# ** is rejected
cd /tmp/aidc-ov-mono
cat > .aidc/config.yaml <<'EOF'
container_only_paths:
  - "**/node_modules"
EOF
scripts/aidc create monotest 2>&1 | grep '\*\* is not supported'
# expect: error mentioning ** is not supported; exit non-zero

# Cleanup
rm -rf /tmp/aidc-ov-test /tmp/aidc-ov-mono

# Smoke stability
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "=== smoke $i ==="
    make smoke 2>&1 | grep -E '^(passed|failed)'
done
```

---

## Enforcement Test Suggestions

- [ ] Glob expansion never escapes the workspace root. Suggested test: a smoke-style integration test that declares `container_only_paths: [../sibling/.venv]` and asserts `aidc create` fails.
- [ ] Overlay volume names match the canonical regex `^aidc-sovl-[a-z0-9][a-z0-9-]*-[a-z0-9_][a-z0-9_-]*$`. Suggested test: a Make lint step that asserts no script emits a candidate volume name failing the regex.
