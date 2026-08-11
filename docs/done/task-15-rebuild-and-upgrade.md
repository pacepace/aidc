# task-15: `aidc rebuild` + `aidc upgrade`

## Objective

Add two CLI subcommands so a user with multiple in-flight sessions can roll the dev image forward without coordinating a tear-down of every session. `aidc rebuild` (re)builds all aidc images locally without touching any session. `aidc upgrade <session>` swaps just the dev container of one named session onto the freshly-built image, preserving the proxy stack and all persistent state. The two together decouple image-rebuild cadence from session lifecycle.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| CLI-16 | `aidc rebuild` MUST rebuild all `aidc/*:${AIDC_VERSION_TAG}` images (squid, refresher, policy, audit, dev-base, forwarder, mcp) without touching any running session. | P0 |
| CLI-17 | `aidc upgrade <session>` MUST stop and recreate ONLY the dev container of the named session against the current `aidc/dev-base:${AIDC_VERSION_TAG}` image, preserving the proxy stack, the dev-home volume, the workspace bind mount, the per-project Claude memory mount, the audit dir, and the pyenv-versions volume. Adhoc port forwards (CLI-14) MUST be removed (re-add explicitly post-upgrade). Declared ports (CLI-13) MUST survive. Pre-flight MUST warn the operator that any in-flight claude conversation is interrupted, and MUST prompt for y/N (override with `--yes`). | P0 |

Related:

| ID | Requirement | Priority |
|----|-------------|----------|
| REL-01 | Local `aidc/*` image tags MUST be versioned with the CLI version (e.g. `aidc/dev-base:v0.1.0`) ... | P0 |
| CLI-14 | `aidc proxy <session> add\|rm\|ls\|clear` subverbs MUST manage adhoc host-to-container port forwards ... Forwards MUST NOT persist across `aidc restart` or `aidc kill`. | P0 |

`aidc upgrade` extends CLI-14's "forwards MUST NOT persist" rule to upgrade as well — anything that recreates the dev container nukes adhoc forwards.

---

## Design Context

### Why two commands, not one

The user has 3-5 sessions in flight at any given time. They want to:
- Pick up a new image when they want it (after a git pull + image rebuild).
- Roll each session forward at their own cadence, not all at once.
- Leave a session intentionally pinned to an older image if they have an in-flight thing they don't want to disturb.

Coupling rebuild to upgrade ("`aidc upgrade` rebuilds the image then swaps the container") would force a full rebuild on every session-swap. Decoupling them lets `aidc rebuild` happen once and `aidc upgrade` happen N times against the already-fresh image.

### Why the dev container is the only thing we replace

The proxy stack (squid, refresher, policy, audit) doesn't typically change between releases — and when it does, the existing taint state, blocklist, and audit-collection-in-progress are worth keeping. Replacing only the dev container:
- Keeps squid serving traffic uninterrupted (no DNS hiccup, no in-flight HTTP failures).
- Keeps the audit aggregator collecting (no gap in the per-session forensic log).
- Keeps the taint flag intact (if a session is tainted, it stays tainted).
- Touches the smallest possible surface — fewer ways for the upgrade to break.

If a future task changes a proxy sidecar's Dockerfile and we need to roll that out, the path is `aidc kill && aidc create` (same as today). The shard does NOT implement a full-stack upgrade — `aidc upgrade` is dev-container-only.

### What survives an upgrade

| Surface | Survives | Mechanism |
|---|---|---|
| Proxy stack containers | Yes | `docker compose stop dev` + `docker compose up -d --force-recreate dev` only touches the `dev` service |
| `dev-home` named volume (vscode home, includes claude memory, npm-global, claude install) | Yes | named volume; recreated container re-mounts the same volume |
| Workspace bind mount (host repo) | Yes | bind mounts are container-level; recreate re-attaches |
| Claude memory (host `~/.claude/projects/<encoded>/`) | Yes | bind mount |
| Claude credentials / settings / state mounts | Yes | bind mounts |
| `pyenv-versions` named volume (cross-session) | Yes | external volume |
| Audit dir | Yes | host bind mount |
| Squid blocklist | Yes | proxy stack untouched |
| Taint flag | Yes | proxy `policy` sidecar untouched, state volume mounted |
| Declared port forwards (CLI-13) | Yes | published in compose; come back on recreate |
| Adhoc port forwards (CLI-14) | NO | explicitly removed per CLI-14 contract |
| In-flight claude conversation tool call | NO | the dev container is stopped mid-call; claude `--continue` re-attaches to the same conversation on restart |

### Image-rebuild safety

Docker image tags are mutable references to immutable content. A running container references the image by its content digest, NOT by tag. Concretely:
- User has `eng-ai-bot` running on `aidc/dev-base:v0.1.0-dev` (content digest `sha256:abc123...`).
- User runs `aidc rebuild`. Docker produces new content (`sha256:def456...`) and reassigns the `aidc/dev-base:v0.1.0-dev` tag to the new digest.
- `eng-ai-bot`'s container still references the OLD digest internally — it keeps running unaffected.
- Next `aidc create` or `aidc upgrade <session>` uses the tag, which now resolves to the new digest.

So `aidc rebuild` is non-disruptive by Docker's own semantics. We don't need any session-tracking; rebuild is fire-and-forget.

---

## Research

- Docker image vs. container reference model: https://docs.docker.com/engine/reference/commandline/image_inspect/ — image content digest vs. tag relationship
- `docker compose up --force-recreate <service>`: https://docs.docker.com/compose/reference/up/ — `--force-recreate` is what makes us pick up the new image even if the tag is unchanged from the container's perspective
- Existing aidc CLI dispatcher: scripts auto-discovered from `scripts/cmd-*.sh` per `scripts/cmd-help.sh`. New subcommands register automatically by adding new files.

---

## Patterns to Follow

- Existing `build_if_missing` helper at `scripts/cmd-create.sh:162-169` — `aidc rebuild` invokes the same image set with `docker build` (no `_if_missing` — always rebuild).
- Existing `aidc restart` script `scripts/cmd-restart.sh` — same shape as `aidc upgrade` (validate session, find compose project, do the dance, report). `aidc upgrade` is meaningfully more involved (compose up --force-recreate dev) but the script shape is the same.
- Existing adhoc-forward cleanup at `scripts/cmd-restart.sh:38-43` and `scripts/cmd-kill.sh:64-69` — `aidc upgrade` reuses the same `docker ps --filter "name=aidc-${SESSION}-fwd-" -q | xargs docker rm -f` pattern.
- The `# desc:` line convention at line 2 of every `cmd-*.sh` script — `aidc help` auto-discovers from this.

---

## Files to Create

### `scripts/cmd-rebuild.sh`

New subcommand. Iterates the canonical aidc image list (the same set built by `build_if_missing` in cmd-create) and runs `docker build -t <tag> -f <dockerfile> <context>` for each.

Required behavior:
- Reads `AIDC_VERSION_TAG` from env (exported by the dispatcher per task-13).
- Builds in this order: `aidc/squid`, `aidc/refresher`, `aidc/policy`, `aidc/audit`, `aidc/forwarder`, `aidc/mcp`, `aidc/dev-base`. Dev-base is last because it's the biggest and a fail-fast on a small one saves time.
- Each build runs to completion; a single failure stops the run with a clear error naming which image failed.
- Output is BuildKit's default per-step output; do NOT redirect or suppress.
- On success, prints a one-line summary: `rebuilt 7 images: aidc/{squid,refresher,policy,audit,forwarder,mcp,dev-base}:${AIDC_VERSION_TAG}`.
- Does NOT touch any running session. No `docker compose`, no `docker ps`, no session lookups.

No CLI flags in v1: rebuild always builds all 7. (A future `aidc rebuild <image>` for selective rebuilds is reasonable, but YAGNI for this shard.)

### `scripts/cmd-upgrade.sh`

New subcommand. Recreates only the `dev` service of the named compose project against the latest local `aidc/dev-base:${AIDC_VERSION_TAG}` image.

Required behavior:
- Argument: `<session>` (required), `--yes` (optional, skips the y/N prompt).
- Validates the session exists via the existing `session_exists` helper.
- Locates the rendered compose file at `/tmp/aidc-${SESSION}.yaml` (the path cmd-create writes to). If missing, `die` with a clear message ("rendered compose file gone — `aidc kill` + `aidc create` instead").
- Reads the dev container's current image digest BEFORE the upgrade for the pre-flight check:
  ```bash
  OLD_DIGEST=$(docker inspect "$DEV_CT" --format '{{.Image}}' 2>/dev/null || true)
  ```
- Compares to the current tag's digest:
  ```bash
  NEW_DIGEST=$(docker image inspect "aidc/dev-base:${AIDC_VERSION_TAG}" --format '{{.Id}}' 2>/dev/null || true)
  ```
- If both digests are present AND equal, prints `aidc-<session>-dev is already on the current dev-base image (${NEW_DIGEST}); nothing to do.` and exits 0. (Use `aidc restart` for an in-place restart.)
- If `NEW_DIGEST` is absent, prints `no local aidc/dev-base:${AIDC_VERSION_TAG} image found; run 'aidc rebuild' first.` and exits 1.
- Pre-flight prompt (skipped if `--yes` was passed):
  ```
  This will interrupt aidc-<session>-dev:
    - any in-flight claude conversation tool call is aborted (claude --continue
      re-attaches to the same conversation when the container comes back)
    - adhoc port forwards (aidc proxy) are removed; re-add after upgrade
    - declared ports (--port at create time) survive
    - the proxy stack, dev-home volume, repo mount, memory, and audit dir all survive

  Proceed? [y/N]
  ```
  Read from stdin via `read -r`; accept only `y` / `Y` to proceed. Anything else aborts.
- Removes adhoc forwards (reuse the cmd-restart pattern):
  ```bash
  fwd_ids=$(docker ps -a --filter "name=aidc-${SESSION}-fwd-" -q 2>/dev/null || true)
  if [ -n "$fwd_ids" ]; then
      printf '%s\n' "$fwd_ids" | xargs docker rm -f >/dev/null 2>&1 || true
  fi
  ```
- Performs the swap:
  ```bash
  docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d --force-recreate dev
  ```
  Note: NOT `down dev` + `up dev`; that would tear down the network. `up -d --force-recreate dev` is the atomic-swap primitive.
- Waits for the dev container's `[aidc-user-main] ready` marker (reuse the wait-loop logic from `cmd-create.sh:380-402`, possibly extracted to `lib/common.sh` if not already).
- On success, prints:
  ```
  Upgraded aidc-<session>-dev to aidc/dev-base:${AIDC_VERSION_TAG}.
    Attach with: aidc attach <session>
  ```

---

## Files to Modify

### `scripts/cmd-help.sh`

No changes required — help is auto-discovered from the `# desc:` line at line 2 of each `cmd-*.sh`. As long as `cmd-rebuild.sh` and `cmd-upgrade.sh` have proper `# desc:` lines, they show up in `aidc help`.

### `README.md`

Add `aidc rebuild` and `aidc upgrade <session>` to the commands table under "Reference → Commands" (currently `README.md:179` region). Also add a short subsection under "Use" explaining the rebuild + upgrade workflow:

```markdown
### Rolling an image update across running sessions

You have 3 sessions running. A new aidc dev image lands. To pick it up
without coordinating a teardown of all 3:

    aidc rebuild                       # builds all aidc/* images at the current version; no session is touched
    aidc upgrade eng-ai-bot            # ~10s; swaps just the dev container; squid/audit/policy stay running
    aidc upgrade metallm               # roll the next one when you're ready
    # leave session 3 on the old image; aidc upgrade it later (or aidc kill it)

In-flight claude conversation is interrupted (claude --continue re-attaches
to the same conversation when the dev container comes back). Adhoc port
forwards (`aidc proxy ... add`) are removed by upgrade; re-add explicitly.
Declared ports (`--port` at create time) survive. The proxy stack is
NOT replaced — for proxy-stack changes, use `aidc kill && aidc create`.
```

Keep the addition under ~15 lines; the README already has the full reference further down.

### `docs/requirements.md`

Already updated in advance of this shard. CLI-16 and CLI-17 are in place.

---

## Implementation Notes

1. **`aidc rebuild` doesn't need session-aware code at all.** It iterates 7 image-tag-context-Dockerfile triples and shells out to `docker build`. Mirrors the `build_if_missing` block in `cmd-create.sh:171-175` plus the proxy/forwarder (`cmd-proxy.sh:84-87`) and mcp (`cmd-mcp.sh:134-136`) builds. Lift the canonical list into a shared array.

2. **Canonical image list — put it in a single place.** Extract a function `aidc_image_inventory()` into `scripts/lib/common.sh` that prints lines of `<tag>|<context>|<dockerfile>` for all 7 images. `cmd-rebuild.sh`, `cmd-create.sh`'s build_if_missing block, `cmd-proxy.sh`'s forwarder build, and `cmd-mcp.sh`'s mcp build all consume this list. Drift-prevention.

   ```bash
   # In scripts/lib/common.sh:
   aidc_image_inventory() {
       cat <<EOF
   aidc/squid:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/squid|${AIDC_ROOT}/proxy/squid/Dockerfile
   aidc/refresher:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/refresher|${AIDC_ROOT}/proxy/refresher/Dockerfile
   aidc/policy:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/policy|${AIDC_ROOT}/proxy/policy/Dockerfile
   aidc/audit:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/audit|${AIDC_ROOT}/proxy/audit/Dockerfile
   aidc/forwarder:${AIDC_VERSION_TAG}|${AIDC_ROOT}/proxy/forwarder|${AIDC_ROOT}/proxy/forwarder/Dockerfile
   aidc/mcp:${AIDC_VERSION_TAG}|${AIDC_ROOT}/mcp|${AIDC_ROOT}/mcp/Dockerfile
   aidc/dev-base:${AIDC_VERSION_TAG}|${AIDC_ROOT}/.devcontainer|${AIDC_ROOT}/.devcontainer/Dockerfile
   EOF
   }
   ```
   Refactoring the existing call sites to consume this is in scope — drift between cmd-rebuild and cmd-create on which images exist would be a real bug.

3. **Pre-flight digest check matters.** Without it, `aidc upgrade` against an already-current session does ~5s of `docker compose` work for no benefit AND interrupts an in-flight conversation. Comparing image digests is the right idempotency check.

4. **`up -d --force-recreate dev` is the right primitive.** `down dev` first would tear down dependent networks (the dev container depends on `default`, which other services depend on too — compose would refuse to take it down without `--remove-orphans=false`, or would take down the whole project). `up --force-recreate <service>` does the atomic swap without touching peers.

5. **The wait-for-ready loop should be DRY.** Today it lives inline in `cmd-create.sh:380-402`. Extract to `lib/common.sh` as `wait_for_dev_ready <session> [max-seconds]` and call from BOTH cmd-create AND cmd-upgrade. Same marker, same logic, same surface to log progress.

6. **In-flight conversation handling.** `claude --continue` (which aidc-claude passes by default per task-09) re-attaches to the conversation by reading the memory dir, which is bind-mounted from host and survives the container replace. Pace's explicit statement: "having to pause the conversation to do this is absolutely fine." No need to be cleverer.

7. **`--yes` flag for scripted use.** A maintainer running `aidc rebuild && aidc upgrade eng-ai-bot --yes && aidc upgrade metallm --yes` should be able to script it. `--yes` skips the interactive prompt but still emits the pre-flight summary to stderr so the operator sees what happened in the log.

8. **Order of operations matters.** Remove adhoc forwards FIRST, then do the compose recreate. If recreate happens first and fails, you've removed the user's forwards for nothing.

---

## Anti-patterns

- **DO NOT** make `aidc rebuild` selective by default. The shard is for the "rebuild everything" case; selective rebuilds (`aidc rebuild dev-base`) are a future enhancement, not part of this shard. Selective without `aidc rebuild all` as the explicit primary would be a footgun ("did I rebuild everything I need?").
- **DO NOT** combine rebuild and upgrade into one command. The whole point of the two-step model is that `aidc upgrade` is non-disruptive after `aidc rebuild` runs once. A combined command forces a build on every session-swap, defeating the design.
- **DO NOT** silently `aidc rebuild` from inside `aidc upgrade`. If `aidc/dev-base:${AIDC_VERSION_TAG}` is missing, `aidc upgrade` MUST error out telling the user to run `aidc rebuild` first. Silent-rebuild would (a) surprise the user with a 10-15 min wait they didn't ask for, (b) hide image-version drift behind upgrade calls.
- **DO NOT** add a `--full` flag to `aidc upgrade` that triggers `aidc kill && aidc create`. Explicit kill+create is the documented path for full-stack replacement; adding a flag duplicates that without simplifying.
- **DO NOT** touch the proxy stack containers in `aidc upgrade`. Even if the proxy images have been rebuilt, leave them alone — proxy-stack changes go through kill+create per the design rationale.
- **DO NOT** preserve adhoc port forwards across upgrade. CLI-14 is explicit: forwards do NOT persist across restart or kill, and upgrade is in the same category. Re-adding adhoc forwards is the user's explicit re-opt-in.
- **DO NOT** use `docker compose restart dev` instead of `docker compose up -d --force-recreate dev`. Restart re-runs the SAME container against the SAME image; upgrade needs a NEW container against the (potentially new) image content under the same tag.
- **DO NOT** require `aidc upgrade` to be run from the repo dir. The session captures everything at create time (workspace, repo, ports, etc.); upgrade just acts on what's already running. CWD irrelevant.
- **DO NOT** add interactive confirmation to `aidc rebuild`. It's a non-disruptive operation; making the user confirm every time would be annoying-friction without security benefit.

---

## Success Criteria

- [ ] `scripts/cmd-rebuild.sh` exists, has a `# desc:` line, is executable.
- [ ] `scripts/cmd-upgrade.sh` exists, has a `# desc:` line, is executable.
- [ ] `aidc help` lists both `rebuild` and `upgrade` (auto-discovery).
- [ ] `aidc rebuild` builds all 7 aidc images at `${AIDC_VERSION_TAG}` and prints the summary line. Running it again with no Dockerfile changes is fast (BuildKit cache hits everywhere).
- [ ] `aidc rebuild` while a session is running does NOT disturb the running session. Verified by: `docker exec aidc-<session>-dev whoami` continues to succeed throughout the rebuild.
- [ ] `aidc upgrade <session>` against an already-current session (digests match) prints "already on the current image" and exits 0 without prompting or touching the container.
- [ ] `aidc upgrade <session>` against a stale session (after a rebuild produced a new digest) prompts for y/N, then on confirmation swaps the dev container in ~10s and reports the new image tag.
- [ ] `aidc upgrade <session> --yes` skips the prompt but still emits the pre-flight summary to stderr.
- [ ] Post-upgrade, `aidc attach <session>` works and claude `--continue` re-attaches to the previous conversation.
- [ ] Post-upgrade, declared ports (CLI-13) are still published (`docker port aidc-<session>-dev` shows them).
- [ ] Post-upgrade, adhoc port forwards (CLI-14) are gone (`aidc proxy <session> ls` shows none).
- [ ] Post-upgrade, the proxy stack containers (`aidc-<session>-{squid,refresher,policy,audit}`) have the SAME container IDs as before — they were NOT touched.
- [ ] Post-upgrade, the taint flag is preserved (test: taint a session via the smoke pattern, then upgrade, then `aidc status` still reports TAINTED).
- [ ] `aidc upgrade <session>` when `aidc/dev-base:${AIDC_VERSION_TAG}` is absent prints a clear error pointing at `aidc rebuild`.
- [ ] `aidc upgrade nonexistent-session` exits cleanly with "no such session".
- [ ] `aidc rebuild` after refactoring uses the SAME image inventory list as `aidc create`. Verified by: deleting one of the 7 image tags from local docker, running `aidc create newsess`, observing only that one image rebuilds. (Tests the inventory function is shared.)
- [ ] `make smoke` passes 10/10 after this change. The smoke harness does not exercise rebuild/upgrade directly (out of scope for v1), but smoke MUST NOT regress.

---

## Verification

```bash
# Build all images at current VERSION
scripts/aidc rebuild
docker image ls 'aidc/*' --format '{{.Repository}}:{{.Tag}}\t{{.ID}}'
# Should list 7 aidc/* images all at ${AIDC_VERSION_TAG}.

# Confirm rebuild is non-disruptive
scripts/aidc create rolltest --profile multi --repo "$(pwd)" --port 28080
OLD_PROXY_ID=$(docker inspect aidc-rolltest-squid --format '{{.Id}}')
scripts/aidc rebuild
NEW_PROXY_ID=$(docker inspect aidc-rolltest-squid --format '{{.Id}}')
[ "$OLD_PROXY_ID" = "$NEW_PROXY_ID" ] && echo "PASS: proxy stack untouched"
docker exec aidc-rolltest-dev whoami     # should still work; outputs "vscode"

# Add an adhoc forward to verify it gets cleaned up
scripts/aidc proxy rolltest add 28081
scripts/aidc proxy rolltest ls           # shows 28081

# Touch the Dockerfile to force a digest change on next rebuild
echo '# touch' >> .devcontainer/Dockerfile
scripts/aidc rebuild                      # new dev-base digest

# Now upgrade
scripts/aidc upgrade rolltest             # prompts y/N
# (answer y)

# Verify post-upgrade state
scripts/aidc proxy rolltest ls            # should be empty (adhoc removed)
docker port aidc-rolltest-dev             # should still show 28080:28080 (declared)
NEW_PROXY_ID2=$(docker inspect aidc-rolltest-squid --format '{{.Id}}')
[ "$OLD_PROXY_ID" = "$NEW_PROXY_ID2" ] && echo "PASS: proxy stack STILL untouched"
scripts/aidc attach rolltest              # claude --continue re-attaches

# Idempotency: upgrade again with no change
scripts/aidc upgrade rolltest             # should say "already on the current image"

# Cleanup
scripts/aidc kill rolltest
git checkout .devcontainer/Dockerfile     # undo the test touch

# Smoke stability check
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "=== smoke $i ==="
    make smoke 2>&1 | grep -E '^(passed|failed)'
done
```

---

## Enforcement Test Suggestions

Subagent fills this in at completion if drift potential exists.

- [ ] Image inventory is the single source of truth. Suggested test: a grep in `make lint` that fails if any `docker build -t aidc/` invocation appears in `scripts/cmd-*.sh` outside of a call to the `aidc_image_inventory` helper. Catches drift where a new image-build site is added without updating the inventory.
- [ ] `aidc upgrade` never touches the proxy stack. Suggested test: a smoke-style integration test that asserts the proxy container IDs are unchanged across an upgrade. (Already in Success Criteria above.)
