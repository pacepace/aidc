# Design 05 — CLI (`aidc`)

**What this covers.** The `aidc` command — subcommands, argument shape, implementation strategy, config file format and merging rules, naming conventions, and cross-platform considerations. The CLI is the user's only interface to the system; everything else is implementation detail behind it.

**Requirements implemented:** CLI-01 through CLI-12.

---

## Implementation strategy

`aidc` is a bash dispatcher (CLI-02). The top-level command resolves a subcommand to a script under `scripts/cmd-<name>.sh` and execs it with the remaining arguments. No Python, no Go, no Node runtime needed on the host beyond:

- `bash` ≥ 4 (macOS ships 3.2 but `aidc` runs fine on it with care; we avoid bash-4-only syntax)
- `docker` and `docker compose`
- `jq` and `yq` (for config parsing; both are widely available and small)

Rationale: matches the original brief (`scripts/*.sh`), zero new dependencies, identical behavior across macOS, Linux, and WSL2.

The dispatcher is `~80 lines` and lives at the repo's top level. Subcommand scripts are 50–200 lines each.

---

## Naming convention (CLI-12)

Every Docker resource created for a session is named `aidc-<session>-<role>`:

| Resource | Name |
|----------|------|
| Dev container | `aidc-<session>-dev` |
| Squid container | `aidc-<session>-squid` |
| Refresher container | `aidc-<session>-refresher` |
| Policy container | `aidc-<session>-policy` |
| Audit container | `aidc-<session>-audit` |
| Compose project | `aidc-<session>` |
| Internal docker network | `aidc-<session>-net` |
| Audit volume | `aidc-<session>-audit-vol` |
| State volume | `aidc-<session>-state-vol` |

Session names are constrained to `[a-z0-9][a-z0-9-]{0,30}` so they're valid as Docker resource name components on all platforms.

---

## Subcommands

### `aidc create` (CLI-03)

```
aidc create <name> [--profile python|node|go|rust|multi] [--repo PATH]
```

Builds and starts a full session: proxy stack first, then dev container.

**Args:**

- `<name>` — required. The session name (validated against the regex above).
- `--profile P` — language profile. If omitted, reads per-project config, then global, then defaults to `multi`.
- `--repo PATH` — host path to the repo to mount. Defaults to current working directory. Must be an absolute path or resolvable to one. On WSL2, Windows paths (`C:\...`) are converted to `/mnt/c/...` automatically.

**Behavior:**

1. Validate session name uniqueness — fail loudly if a session with this name already exists.
2. Resolve effective config (see "Configuration" below).
3. Render the per-session `docker-compose.yaml` from a template, substituting session name, profile, repo path, and config-derived values.
4. `docker compose -p aidc-<name> up -d` for the proxy stack first.
5. Wait for Squid health (poll its `cache_object://localhost/mgr:info` or a simpler connect test) and for the refresher's startup fetch to complete.
6. Start the dev container (also via compose).
7. Run `postCreateCommand` to seed tmux, Claude Code, and the system pre-push hook.
8. Print the audit directory path and the `aidc attach <name>` invocation.

**Failure modes:**

- Squid won't start → tear down the stack, show last 50 lines of Squid log, exit non-zero.
- Refresher's first fetch fails → log warning, continue with empty blocklist + TLD policy. **Do not abort** the session for this — startup must remain robust.
- Dev container fails to start → tear down the whole stack (proxy stays alone is useless), surface logs.

### `aidc attach` (CLI-04)

```
aidc attach <name>
```

`docker exec -it aidc-<name>-dev tmux attach -t main` (or a similar invocation specific to how the dev container's tmux is set up).

If multiple humans attach simultaneously, tmux's multi-client semantics apply — they share a view. This is intentional for "Pace and a colleague both observing Claude" use cases.

### `aidc kill` (CLI-05)

```
aidc kill <name> [--keep-audit]
```

1. `docker pause aidc-<name>-dev` (immediately freeze Claude).
2. Trigger final audit aggregation flush.
3. `docker compose -p aidc-<name> down -v --remove-orphans`.
4. Unless `--keep-audit` is passed, leave audit directory intact (kill never deletes audit by default; the flag is the *opposite* — pass it to explicitly say "I know you're going to keep it"). Actually, simpler: audit dir is *always* preserved by `aidc kill`. Removing audit data is a separate `aidc audit-prune` command (P2).

**Cleanup ordering:** pause first, then kill. This prevents Claude from doing anything during the few seconds the audit flush takes.

### `aidc list` (CLI-06)

```
aidc list
```

Lists all running aidc sessions. Output format:

```
SESSION        STATUS     PROFILE   STARTED            TAINTED
my-feature     running    python    2 hours ago        no
test-refactor  paused     multi     30 minutes ago     YES
```

Implementation: `docker ps --filter "label=aidc.role=dev" --format ...` plus a check of each session's `tainted` flag file.

### `aidc status` (CLI-07)

```
aidc status [<name>]
```

Without `<name>`: equivalent to `aidc list` plus aggregate health.

With `<name>`: detailed view of one session:

```
session:        my-feature
profile:        python
repo:           /Users/pace/code/my-project
started:        2026-05-21T14:30:00Z
status:         running

dev container:    aidc-my-feature-dev          healthy
squid:            aidc-my-feature-squid        healthy   (last fetch: 4h ago, 145382 blocked domains)
refresher:        aidc-my-feature-refresher    healthy
policy:           aidc-my-feature-policy       healthy
audit:            aidc-my-feature-audit        healthy

tainted:        NO

audit dir:      ~/aidc-audit/my-feature-20260521T143000/
```

If `tainted` is YES, the line is loud (red in a TTY) and includes a one-line summary of the offending event.

### `aidc logs` (CLI-08)

```
aidc logs <name> [--component dev|squid|refresher|policy|audit] [--follow]
```

Tail logs for one component. `--component dev` shows the dev container's stdout (which is mostly tmux session output if Claude is running). `--follow` is `docker logs -f`.

### `aidc refresh` (CLI-09)

```
aidc refresh <name>
```

Trigger an immediate blocklist refresh for the named session. Implementation: `docker exec aidc-<name>-refresher /refresh.sh`. The refresher's normal loop will pick up where the manual one left off.

### `aidc config` (CLI-10)

```
aidc config global                # show effective global config
aidc config <name>                # show effective config for a session
aidc config edit global           # open global config in $EDITOR
aidc config edit                  # open per-project config in $EDITOR (current dir)
```

Read-only views go to stdout as YAML. `edit` invokes `$EDITOR` (or `vim`) on the file, creating it from a template if missing.

---

## Configuration (CLI-11)

Two config files; per-project overrides global.

### Global: `~/.config/aidc/config.yaml`

```yaml
# All keys optional; aidc fills defaults at runtime.

profile: multi                    # default profile if none specified
taint_response: notify            # log | notify | freeze
tld_taints: false                 # do TLD policy hits trigger taint?
audit_dir: ~/aidc-audit           # where audit data lands
state_actor_tlds:                 # default block-by-TLD list
  - .ru
  - .cn
  - .by
  - .ir
  - .kp
blocklist_additions: []           # global custom block additions
```

### Per-project: `<repo>/.aidc/config.yaml`

Same schema. Any field overrides the global value. **Exception:** `state_actor_tlds` and `blocklist_additions` are **merged**, not replaced — projects can add but never remove.

### Effective-config resolution

At `aidc create` time:

1. Start from baked-in defaults.
2. Overlay `~/.config/aidc/config.yaml`.
3. Overlay `<repo>/.aidc/config.yaml` if present.
4. Apply command-line flags (`--profile` etc.).
5. For list fields (TLDs, blocklist additions), concatenate and dedupe at each step rather than overwrite.

The resolved config is captured in the session's audit `meta.json` so a post-hoc reviewer can see exactly what was in effect.

---

## Cross-platform considerations

### macOS

- bash 3.2 ships by default. The dispatcher must not use bash-4 features (no `mapfile`, no `declare -A`).
- `realpath` is not standard; use `python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))'` or guarded fallback.
- File watching: not used in the CLI itself; doesn't matter.

### Linux

- Standard environment. No special handling.

### WSL2

- The CLI runs inside WSL2; from the CLI's perspective this is Linux.
- `--repo PATH` may receive a Windows path (`C:\Users\...`) from a user copy-pasting. Detect that pattern and translate to `/mnt/c/Users/...` before passing to Docker.
- Docker Desktop's WSL2 integration handles the daemon connection; nothing for aidc to configure.

The CLI auto-detects WSL2 via `/proc/sys/kernel/osrelease` (contains `microsoft` or `WSL`) and enables the path translation only there.

---

## Subcommand discovery

Bash dispatcher uses convention-over-config: any executable script in `scripts/cmd-*.sh` is a subcommand. The name after `cmd-` is the subcommand. New subcommands can be added without touching the dispatcher.

`aidc` (no args) prints `aidc help`, which is itself just `cmd-help.sh` listing the available subcommands by globbing the scripts directory.

---

## Error handling philosophy

- Every subcommand exits non-zero on failure.
- Errors include enough context to debug (which Docker command failed, what session, what state).
- Log levels in the CLI are simple: print to stderr by default, prefix with the subcommand name. No structured logging.
- The CLI doesn't try to recover from arbitrary failures — if compose fails, surface it and stop. The user re-runs the command with more flags or with `--verbose`.

---

## Things deliberately not in v1

- Tab completion. Easy to add later; not blocking.
- A `--json` output mode for `aidc list` / `aidc status`. Useful for Saoirse-driven orchestration in Phase 2; tagged P2.
- Configurable proxy port. Hard-coded to `3128` for v1 simplicity.
- Multi-host orchestration (running aidc sessions across machines). Out of scope.

---

## References

- Dispatcher pattern (similar): `git` itself uses `git-<subcommand>` executable resolution.
- `yq` for YAML: https://github.com/mikefarah/yq
- `jq`: https://stedolan.github.io/jq/
