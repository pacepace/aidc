# task-08: aidc CLI

## Objective

Implement the `aidc` bash CLI: a top-level dispatcher plus subcommand scripts (`create`, `attach`, `kill`, `list`, `status`, `logs`, `refresh`, `config`). Bash-only; depends on `docker`, `docker compose`, `jq`, `envsubst`. Cross-platform across macOS, Linux, WSL2.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| CLI-01 through CLI-12 | Full CLI surface | mixed P0/P1 |
| CTR-11 | Cross-platform (macOS / Linux / WSL2) | P0 |

---

## Design Context

From `docs/design-05-cli.md`:
> Bash dispatcher uses convention-over-config: any executable script in `scripts/cmd-*.sh` is a subcommand.

> Two config files; per-project overrides global... For list fields (TLDs, blocklist additions), concatenate and dedupe.

> Session names are constrained to `[a-z0-9][a-z0-9-]{0,30}`.

> The CLI auto-detects WSL2 via `/proc/sys/kernel/osrelease` (contains `microsoft` or `WSL`).

---

## Files to Create

### `scripts/aidc`

The top-level dispatcher. Replace the stub from task-01.

```bash
#!/usr/bin/env bash
# aidc - AI Dev Container CLI
set -euo pipefail

# Resolve the repo root from the script's own location
AIDC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AIDC_ROOT
export AIDC_SCRIPTS="$AIDC_ROOT/scripts"

# Source common library
. "$AIDC_SCRIPTS/lib/common.sh"

# Show help if no args
if [ $# -eq 0 ]; then
    exec "$AIDC_SCRIPTS/cmd-help.sh"
fi

SUBCOMMAND="$1"
shift

SUBCOMMAND_SCRIPT="$AIDC_SCRIPTS/cmd-${SUBCOMMAND}.sh"
if [ ! -x "$SUBCOMMAND_SCRIPT" ]; then
    err "Unknown subcommand: $SUBCOMMAND"
    exec "$AIDC_SCRIPTS/cmd-help.sh"
fi

exec "$SUBCOMMAND_SCRIPT" "$@"
```

### `scripts/lib/common.sh`

Shared utilities sourced by every subcommand.

Required functions:

- `err <msg>` — print to stderr with a prefix
- `die <msg>` — `err` then exit 1
- `info <msg>` — to stderr, prefixed
- `validate_session_name <name>` — fail if name doesn't match `^[a-z0-9][a-z0-9-]{0,30}$`
- `is_wsl2` — return 0 if running in WSL2, 1 otherwise
- `translate_wsl_path <path>` — if WSL2 and path looks like `C:\...`, convert to `/mnt/c/...`; else return as-is
- `compose_project_name <session>` — return `aidc-<session>`
- `container_name <session> <role>` — return `aidc-<session>-<role>`
- `session_exists <name>` — `docker ps --filter "label=aidc.session=<name>" -q | grep -q .`
- `realpath_portable <path>` — works on macOS without GNU coreutils

### `scripts/lib/config.sh`

Config-loading library. Provides:

- `load_config <session?>` — reads global `~/.config/aidc/config.yaml` and (if cwd has `.aidc/config.yaml`) per-project. Merges into env vars: `AIDC_PROFILE`, `AIDC_TAINT_RESPONSE`, `AIDC_TLD_TAINTS`, `AIDC_AUDIT_DIR`, `AIDC_STATE_ACTOR_TLDS` (newline-separated), `AIDC_BLOCKLIST_ADDITIONS` (newline-separated), `AIDC_NOTIFY_WEBHOOK`.
- `default_config_yaml` — emit a default config template to stdout

Use `yq` if available; otherwise a minimal `awk`-based YAML parser for our flat key/list schema. If neither works, install yq via Homebrew/apt suggestion — `die` with a message.

Defaults if no config files exist:

```
AIDC_PROFILE=multi
AIDC_TAINT_RESPONSE=notify
AIDC_TLD_TAINTS=false
AIDC_AUDIT_DIR=$HOME/aidc-audit
AIDC_STATE_ACTOR_TLDS=".ru\n.cn\n.by\n.ir\n.kp"
AIDC_BLOCKLIST_ADDITIONS=""
AIDC_NOTIFY_WEBHOOK=""
```

### `scripts/cmd-help.sh`

Prints usage. Globs `scripts/cmd-*.sh` and lists discovered subcommands with a short description (read from the second line of each script, a `# desc: ...` comment).

### `scripts/cmd-create.sh`

`aidc create <name> [--profile P] [--repo PATH]`

Steps:

1. Parse args; validate session name.
2. Fail if `session_exists $NAME`.
3. Resolve repo path (default cwd). Translate WSL paths if needed. `realpath_portable`.
4. Load config; apply `--profile` override if passed.
5. Compute audit dir: `${AIDC_AUDIT_DIR}/${NAME}-$(date -u +%Y%m%dT%H%M%SZ)`. Create it.
6. Write the resolved config snapshot to `${AUDIT_DIR}/config-snapshot.yaml` and an initial `meta.json`.
7. Build images if missing/stale. Read `.aidc-image-tag` (or compute git sha) and tag as `aidc/<role>:local`. For first-time use, build everything: `aidc/squid:local`, `aidc/refresher:local`, `aidc/policy:local`, `aidc/audit:local`, `aidc/dev-${PROFILE}:local`. The dev image is profile-specific: render `.devcontainer/devcontainer.json` with the chosen profile's features merged in, then use `devcontainer` CLI if available OR a direct `docker build` using the Dockerfile + a small wrapper that pre-installs the requested features.
8. Render compose: set env vars per the template's contract and run `compose-render.sh`.
9. `docker compose -p aidc-${NAME} -f /tmp/aidc-${NAME}.yaml up -d`.
10. Wait for Squid healthy (poll `docker inspect ... --format '{{.State.Health.Status}}'`).
11. Print:
    ```
    Session 'my-feature' created.
      profile:    python
      repo:       /Users/pace/code/proj
      audit:      /Users/pace/aidc-audit/my-feature-20260521T143000
    Attach with: aidc attach my-feature
    ```

**Building the dev image**: this is the trickiest part. Strategies:

- **Simplest (v1):** maintain one Dockerfile per profile by extending the base. `aidc create` runs `docker build` against `.devcontainer/Dockerfile.${PROFILE}` if present, else `.devcontainer/Dockerfile`. Task-02 produces a base Dockerfile; for v1, treat profile selection as ENV inside the same base image, installing extra packages via post-create rather than re-baking. This keeps the build matrix to 1.

- **devcontainer CLI:** if the `devcontainer` CLI is installed, use it (`devcontainer build`). It handles features. But we can't require it. Make it optional: use devcontainer CLI if present, else fall back to plain `docker build`.

For v1, document both paths but ship the plain-docker-build path. Profile features become post-create install steps in the rendered configuration.

### `scripts/cmd-attach.sh`

`aidc attach <name>`

- Validate name.
- `session_exists $NAME` or die.
- `exec docker exec -it aidc-${NAME}-dev tmux attach -t main`

### `scripts/cmd-kill.sh`

`aidc kill <name>`

1. Validate name; verify session exists.
2. `docker pause aidc-${NAME}-dev` (immediate freeze).
3. `docker exec aidc-${NAME}-audit /usr/local/bin/finalize.sh` (best-effort).
4. `docker compose -p aidc-${NAME} down -v --remove-orphans`.
5. `docker rm -f aidc-${NAME}-dev` (in case compose didn't catch it).
6. Print: `Session 'my-feature' killed. Audit preserved at <audit dir>.`

### `scripts/cmd-list.sh`

`aidc list`

Use `docker ps --filter "label=aidc.role=dev" --format '{{json .}}'` and format. Show columns: SESSION, STATUS, PROFILE, STARTED, TAINTED. Get taint status by checking each session's state volume for `tainted` file.

### `scripts/cmd-status.sh`

`aidc status [<name>]`

Without arg: `aidc list` + summary line.

With arg: detailed status — query each container's health, show last log lines, show taint status with detail.

### `scripts/cmd-logs.sh`

`aidc logs <name> [--component dev|squid|refresher|policy|audit] [--follow]`

Maps to `docker logs [-f] aidc-${NAME}-${COMPONENT}`. Default component is `dev`.

### `scripts/cmd-refresh.sh`

`aidc refresh <name>`

`docker exec aidc-${NAME}-refresher /usr/local/bin/refresh.sh`

### `scripts/cmd-config.sh`

`aidc config [global|<session>] [edit]`

- Without args: show resolved config (output of `load_config` as YAML).
- `global`: show global config file contents.
- `<session>`: show resolved config for a named session (read its audit dir's `config-snapshot.yaml`).
- `edit`: open `${EDITOR:-vim}` on the appropriate file; create from template if missing.

---

## Implementation Notes

1. **POSIX-portable bash.** macOS ships bash 3.2 by default. Avoid bash-4-only features (no `mapfile`, no `declare -A`). For map-like needs, use parallel arrays or temp files.

2. **`realpath_portable`** — `realpath` is not standard on macOS. Use:
   ```bash
   realpath_portable() {
       python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null \
           || cd "$(dirname "$1")" && pwd -P
   }
   ```

3. **YAML parsing.** Prefer `yq`. If not installed:
   - Detect at script start; if missing and the user is on macOS, print install hint: `brew install yq`. On Linux: `apt install yq` or `wget` instructions. On WSL2: same as Linux.
   - Don't ship a bash-based YAML parser unless absolutely necessary. The schema is flat enough that even `grep`/`awk` can handle it for the known keys, but it's brittle. yq is small and easy to install.

4. **WSL2 detection.**
   ```bash
   is_wsl2() {
       [ -f /proc/sys/kernel/osrelease ] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease
   }
   ```

5. **Session name validation.** Use `[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]`. Reject everything else with a clear message.

6. **Idempotency.** `aidc create my-feature` when `my-feature` exists must fail loudly, not silently re-up.

7. **Image building strategy for v1.** Sidecar images (`aidc/squid:local`, etc.) are built on first `aidc create` if not present. The dev image is built per-profile but for v1 we ship one Dockerfile that installs all profiles based on a build-arg (`--build-arg PROFILE=python`). This keeps profile selection simple.

8. **Error surfacing.** Every subcommand's failures should bubble up with `set -e` semantics. Use `trap 'err "command failed at line $LINENO"' ERR` in long-running scripts.

9. **Help comments.** Each `cmd-*.sh` should have a second-line comment `# desc: short description` that `cmd-help.sh` reads to build its listing.

---

## Anti-patterns

- DO NOT use bash-4 features — macOS will reject.
- DO NOT shell-out to `gh` or expect host SSH agent to be available — those are denied by design.
- DO NOT `cd` to the repo root inside subcommands; use absolute paths derived from `$AIDC_ROOT`.
- DO NOT swallow `docker compose` errors silently — surface them.
- DO NOT skip the `validate_session_name` check — names go into Docker resource names; bad chars break things.

---

## Success Criteria

- [ ] `aidc` (no args) prints help, lists all subcommands
- [ ] `aidc help` is equivalent
- [ ] `aidc unknown-cmd` prints "Unknown subcommand: unknown-cmd" then help; exits non-zero
- [ ] `aidc create $(printf 'BAD/NAME')` fails with name validation error
- [ ] `aidc create test-smoke --profile multi --repo .` succeeds: starts proxy stack + dev container, prints session info
- [ ] `aidc list` shows `test-smoke` running
- [ ] `aidc status test-smoke` shows component health
- [ ] `aidc attach test-smoke` enters tmux session (manual verification — script returns 0 after tmux exit)
- [ ] `aidc kill test-smoke` tears down all containers and preserves audit
- [ ] Config merging: global config sets `taint_response: log`, per-project sets `taint_response: freeze`, `aidc config` shows freeze
- [ ] WSL2 path translation: `aidc create x --repo 'C:\Users\Pace\code\proj'` translates to `/mnt/c/Users/Pace/...` on WSL2; passes through unchanged on macOS

---

## Verification

```bash
# Lint
make lint   # should pass shellcheck

# Help
scripts/aidc | grep -q 'subcommand' && echo "OK: help printed"

# Validation
scripts/aidc create '' 2>&1 | grep -q 'validation' && echo "OK: empty name rejected"
scripts/aidc create 'BadName' 2>&1 | grep -q 'validation' && echo "OK: bad name rejected"

# Smoke create (requires Docker + built images)
# This is exercised by tests/smoke/run.sh; see task-09.
```

---

## Enforcement Test Suggestions

- [ ] Bash compatibility: scripts use no bash-4 syntax — suggested test: shellcheck with --shell=bash --severity=warning; manual review for `declare -A` / `mapfile`
- [ ] Every subcommand validates session name — suggested test: parse each cmd-*.sh, ensure `validate_session_name` appears before any container interaction
- [ ] Config merge is additive for lists, override for scalars — suggested test: unit test of `load_config` with various inputs
