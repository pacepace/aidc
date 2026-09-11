# task-17: Host-Side Auth Bridge Daemon

> **Superseded.** Since the container owns its Claude config directory (requirement CTR-13; README "Claude auth"), no host credentials are bridged and this daemon, `aidc reauth`, and the Keychain extraction no longer exist. Kept as the record of the earlier design.

## Objective

Close the gap where a host `claude /login` (caused by Anthropic revoking refresh tokens, OAuth client rotation, or a token-format migration) leaves in-container Claude installs stuck on the rejected old token forever — recoverable today only by `aidc kill && aidc create`.

Ship `aidc-auth-bridge` as a single-global-instance-per-host daemon (mirrors the `aidc mcp` lifecycle pattern) that polls macOS Keychain and pushes any change into every active session's bridged credentials file. Lifecycle is implicit: `aidc create` / `aidc mcp start` ensure the daemon is running; `aidc kill` / `aidc mcp stop` shut it down when nothing aidc-managed remains. Explicit `aidc auth-bridge stop` is respected — the daemon stays stopped until something else triggers a start.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| CLI-21 | On macOS, `aidc` MUST run a host-side `aidc-auth-bridge` daemon that polls the macOS Keychain (`Claude Code-credentials` entry) and synchronizes any change into the per-session bridged `${AUDIT_DIR}/.claude-credentials.json` files. On Linux/WSL2 the daemon is a no-op. | P0 |
| CLI-22 | The auth bridge daemon MUST follow the same single-global-instance-per-host architectural pattern as `aidc mcp`, with `aidc auth-bridge start\|stop\|status\|logs\|restart` subcommands. Implementation is a host-side process (not a Docker container) because macOS Keychain is not reachable from inside a container. | P0 |
| CLI-23 | The auth bridge daemon's lifecycle MUST be managed implicitly by other `aidc` commands: `aidc create` and `aidc mcp start` MUST ensure the daemon is running (idempotent start). `aidc kill` and `aidc mcp stop` MUST stop the daemon when no aidc-managed containers remain on the host. An explicit `aidc auth-bridge stop` by the user MUST be respected. | P0 |

---

## Design Context

### Why this exists

`aidc create` on macOS extracts the Keychain entry once at session-create time and writes it to `${AUDIT_DIR}/.claude-credentials.json`, then bind-mounts that file into the container as `/home/vscode/.claude/.credentials.json`. The mount is RW, so Claude inside the container can refresh its access token in place — writing back to the per-session snapshot.

This works for the access-token-refresh case (each side refreshes independently against Anthropic). It fails for the **refresh-token-rotation** case:

1. Anthropic invalidates the user's existing refresh token (server-side event — security incident, OAuth client rotation, format migration).
2. Both host and container's existing refresh tokens get rejected on next use.
3. User runs `claude /login` on the host. Host's Keychain gets a fresh refresh+access token pair.
4. Container's snapshot still has the dead refresh token. Container's claude is stuck until `aidc kill && aidc create`.

Observed in practice 2026-05-23: both host and several aidc sessions died simultaneously; only host could re-auth (via interactive `/login`); container sessions had to be torn down and recreated.

### Why this is macOS-only

On Linux / WSL2, host credentials live at `~/.claude/.credentials.json` — a real file. `aidc create` bind-mounts that file directly into the container. When the host runs `/login`, it overwrites the file; the container's bind-mount sees the new bytes on its next read. No daemon needed.

On macOS, credentials live in the Keychain — a service, not a file. There's no path to bind-mount. The current approach (snapshot at create time) is a workaround for the lack of a host file. The daemon closes the resulting drift.

### Why a daemon (not a per-invocation refresh)

Alternatives considered:

- **Re-extract at every `aidc-claude` invocation inside the container** — container has no Keychain access; would need a host-side companion to push the data, which is structurally the same daemon.
- **Re-extract on `aidc attach` / `aidc restart`** — works as a side-effect but breaks down when the user stays attached for hours. The token failure happens to running sessions, not just newly-attached ones.
- **Re-extract on `claude` invocation via host-side `aidc` wrapper** — assumes the user runs claude through the wrapper. They don't; they're inside tmux, running claude directly.
- **`launchd` LaunchAgent** — survives reboots, more macOS-native. But adds plist install/uninstall machinery for one tiny process. Defer until we have a reliability issue with the simpler approach. Same call we made for the in-container dockerd watchdog.

The chosen design is the lightest thing that works without user awareness: a backgrounded shell process with a PID file, started automatically by `aidc create` / `aidc mcp start`, stopped automatically by `aidc kill` / `aidc mcp stop` when nothing aidc remains, manageable explicitly via `aidc auth-bridge {start,stop,status,logs,restart}`.

### Why mirror the `aidc mcp` pattern

Per the conversation: the user's reference was "this should be like the mcp that just has a single pod for all of these." The MCP server is a single global instance on the host that manages all sessions. The auth bridge has the same scope (host-global, multi-session). Using the same lifecycle shape (`aidc <component> {start,stop,status,logs,restart}`) keeps the CLI surface predictable.

The implementation differs: MCP runs in a docker container; auth-bridge runs as a host process. That's forced by the Keychain constraint, not a design choice.

### State

- PID file: `~/.config/aidc/auth-bridge.pid` (matches MCP's `~/.config/aidc/mcp.pid` style)
- Log file: `~/.config/aidc/auth-bridge.log` (rotated by size; see below)
- Last-pushed hash file: `~/.config/aidc/auth-bridge.last-hash` (so a restart of the daemon doesn't immediately re-push the same value to all sessions)
- "User stopped me explicitly" flag: `~/.config/aidc/auth-bridge.disabled` (sentinel file; presence means user ran `aidc auth-bridge stop` and the daemon should NOT auto-restart from create/mcp start until they run `aidc auth-bridge start` or remove the sentinel)

### Polling cadence

30-second poll is the proposed default. Cheap (`security find-generic-password` is fast — milliseconds), responsive enough that a `/login` reaches running sessions within half a minute, and quiet enough that `top` doesn't notice the daemon.

Configurable via `~/.config/aidc/config.yaml` `auth_bridge.poll_seconds` if anyone needs to tune it. Default 30. Minimum 5 (anything tighter spams the Keychain unnecessarily).

---

## Research

- macOS `security find-generic-password`: man 1 security — supports `-s <service>` and `-w` (print only the password) for non-interactive use. Returns 44 if the entry doesn't exist; 0 with payload on stdout if it does.
- `shasum -a 256` for hashing the Keychain value (portable on macOS without installing anything). Used to detect "did this actually change" without re-writing files on every poll.
- Existing pattern for the dispatcher's daemon-management subcommand: `scripts/cmd-mcp.sh` (start/stop/status/logs/token verbs). The auth-bridge subcommand follows the same shape; pull patterns from there.
- Existing pattern for backgrounded watchdog with PID file: `.devcontainer/dockerd-start.sh` (spawn-watchdog block at lines 22-56). Same pattern applied here.

---

## Patterns to Follow

- `scripts/cmd-mcp.sh` — verb dispatch (`start`, `stop`, `status`, `logs`, `restart`), PID file management, idempotent start
- `.devcontainer/dockerd-start.sh:22-56` — watchdog spawn with PID file + idempotency check
- `scripts/cmd-create.sh:218-230` — the current `security find-generic-password` call that does the initial snapshot
- `scripts/cmd-kill.sh:48-69` — the existing tear-down sequence, where the "stop the auth bridge if nothing's left" check fits

---

## Files to Create

### `scripts/cmd-auth-bridge.sh`

The user-facing subcommand. Verb dispatch:

- `aidc auth-bridge start` — idempotent. On Linux/WSL2: print "not needed on this platform" and exit 0. On macOS: check PID file; if alive, no-op + report. If not, also check the `.disabled` sentinel (if present, abort with a clear message asking the user to remove it or run start anyway via `--force`). Otherwise fork the watcher script via `nohup` to detach, write PID file, return.
- `aidc auth-bridge stop` — if running, kill the PID, remove PID file. Touch the `.disabled` sentinel so auto-restart from create/mcp start respects the user's intent.
- `aidc auth-bridge status` — running? PID? last successful Keychain extraction time? last hash-change push time? count of audit dirs the daemon is updating? `.disabled` sentinel present?
- `aidc auth-bridge logs` — `tail -f ~/.config/aidc/auth-bridge.log` (or `-n 100` for non-follow).
- `aidc auth-bridge restart` — stop + start. Removes the `.disabled` sentinel (user is explicitly restarting, that's an opt-in).

`--force` flag on `start` removes the `.disabled` sentinel if present.

Platform detection: `uname -s` = `Darwin` is the auth bridge platform. Anything else, the daemon is a no-op (Linux/WSL2 bind-mounts the file directly; nothing to bridge). Subcommand prints "auth bridge is not needed on this platform (host credentials are bind-mounted directly)" and exits 0.

### `scripts/aidc-auth-bridge-watcher.sh`

The actual watcher process. Lives at `scripts/` so the dispatcher can find it. Not user-invocable directly (no `# desc:` line, OR has one prefixed with `(internal)` so aidc help skips it).

Watcher loop:
1. Read `~/.config/aidc/config.yaml` once at start for `auth_bridge.poll_seconds` (default 30, min 5).
2. Read existing `~/.config/aidc/auth-bridge.last-hash` if present, into memory.
3. Loop forever:
   - Extract Keychain via `security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null`. If exit code != 0 (Keychain locked, user logged out, etc.), log a warning, sleep, retry.
   - Compute `sha256` of the extracted value.
   - If hash matches in-memory `last_hash`, sleep + continue.
   - If hash differs:
     - Find all `~/aidc-audit/*/.claude-credentials.json` files (glob).
     - For each one that exists, atomic-write the new value: write to `<file>.new` with mode 0600, then `mv -f`. The container's bind-mount sees the new bytes.
     - Write the new hash to `~/.config/aidc/auth-bridge.last-hash`.
     - Update in-memory `last_hash`.
     - Log: `pushed keychain change to N session(s)` with timestamp.
   - Sleep `poll_seconds`.

Log rotation: rotate `~/.config/aidc/auth-bridge.log` when it exceeds 1MB. Keep one backup at `auth-bridge.log.1`. Simple `mv` + truncate — no fancy rotation library.

Exit handling: trap SIGTERM/SIGINT, remove PID file on exit. (The PID file is the source of truth for "is the daemon running" — leaving a stale one would confuse the next `start`.)

---

## Files to Modify

### `scripts/cmd-create.sh`

After the compose-up succeeds and the dev container is confirmed ready (current location: end of the "wait for dev container" block), call `aidc auth-bridge start` silently. Capture stderr; if it fails, info-log the failure but DO NOT fail the create. The session works fine without the bridge — it just won't auto-refresh.

The call:
```bash
# Auto-start the host-side auth bridge (macOS only; no-op on Linux/WSL2).
# Silent on success. Logs but does NOT fail create on failure -- the
# session still works; the bridge is an enhancement.
if [ "$(uname -s)" = "Darwin" ]; then
    if ! "$AIDC_SCRIPTS/aidc" auth-bridge start >/dev/null 2>&1; then
        info "auth-bridge: failed to start (auto-refresh of in-container claude credentials will not work; run 'aidc auth-bridge start' manually to retry)"
    fi
fi
```

### `scripts/cmd-mcp.sh`

Add the same auto-start call inside the `start` verb's path, after the MCP container is up. MCP itself benefits from fresh credentials for its own Claude calls.

### `scripts/cmd-kill.sh`

After the existing tear-down sequence, count what's still running on the host. If nothing aidc remains AND the MCP server isn't running, stop the auth bridge.

```bash
# Stop the host-side auth bridge if nothing aidc-managed remains on the
# host. Respects the user's explicit-stop sentinel automatically (stop
# is idempotent and no-op on already-stopped).
if [ "$(uname -s)" = "Darwin" ]; then
    if ! aidc_anything_running; then
        "$AIDC_SCRIPTS/aidc" auth-bridge stop >/dev/null 2>&1 || true
    fi
fi
```

Where `aidc_anything_running` is a new helper in `lib/common.sh`:
```bash
# Returns 0 if any aidc-managed container is alive on this host.
# Used to decide whether to tear down host-side daemons (auth-bridge).
aidc_anything_running() {
    if docker ps --filter 'name=^aidc-' -q 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}
```

Note: this catches both per-session containers (`aidc-<session>-*`) and the global MCP container (`aidc-mcp`). Both name patterns match `^aidc-`.

### `scripts/cmd-mcp.sh` (stop verb)

Same tear-down check in the `stop` verb. After stopping the MCP container, call `aidc_anything_running`; if false, stop the auth bridge.

### `scripts/lib/common.sh`

Add the `aidc_anything_running()` helper described above.

### `scripts/cmd-help.sh`

No changes — help is auto-discovered from `# desc:` line.

### `scripts/lib/config.sh`

Add the `auth_bridge.poll_seconds` config knob. Default 30. Read by the watcher script at startup.

In `aidc_config_defaults`:
```bash
    AIDC_AUTH_BRIDGE_POLL_SECONDS="30"
```

In the load loop:
```bash
        val=$(_aidc_yaml_nested "$f" "auth_bridge" "poll_seconds")
        [ -n "$val" ] && AIDC_AUTH_BRIDGE_POLL_SECONDS="$val"
```

Reuse the `_aidc_yaml_nested` helper from `cmd-mcp.sh:77` (lift it into `config.sh` if not already there). Lifting matches the inventory-helper-lift we did for image tags.

In `emit_loaded_config_yaml`:
```bash
    printf 'auth_bridge:\n  poll_seconds: %s\n' "$AIDC_AUTH_BRIDGE_POLL_SECONDS"
```

### `README.md`

Add a brief subsection under "Use" explaining auth-bridge:

```markdown
### Claude auth synchronization (macOS only)

When you run `claude /login` on your host (because Anthropic invalidated
your refresh token, or you switched accounts), your existing aidc sessions
would be stuck on the old credentials. Recovery used to mean `aidc kill`
+ `aidc create`.

A small host-side daemon (`aidc-auth-bridge`) polls your macOS Keychain
every 30 seconds and pushes any credentials change into every active
aidc session's bridged credentials file. Within ~30 seconds of your
host `/login`, every running session has the new tokens. No restart
needed.

The daemon starts automatically the first time you `aidc create` (or
`aidc mcp start`) on macOS, and stops automatically when the last aidc
session and the MCP server are both down. You can manage it explicitly:

    aidc auth-bridge start | stop | status | logs | restart

On Linux and WSL2 the daemon is a no-op -- your host's credentials file
is bind-mounted directly into the container, so updates propagate for
free.

If you explicitly `aidc auth-bridge stop` it, it stays stopped (a
sentinel file at `~/.config/aidc/auth-bridge.disabled` records your
choice). To re-enable, run `aidc auth-bridge start`.
```

Also add `auth-bridge` to the commands table.

### `docs/requirements.md`

Already updated in advance of this shard. CLI-21, CLI-22, CLI-23 are in place.

---

## Implementation Notes

1. **Mirror `cmd-mcp.sh` shape exactly.** Same verb names (`start`, `stop`, `status`, `logs`, `restart`), same PID-file-based lifecycle, same `--force` semantics. Predictability beats variation.

2. **PID file MUST be on the host, not in a docker volume.** The daemon is host-side; its lifecycle has nothing to do with any docker container. Path: `~/.config/aidc/auth-bridge.pid`.

3. **Atomic write to bridged files is required.** Claude inside the container may be reading the credentials file at any moment. Write to `<file>.new`, then `mv -f <file>.new <file>`. The mv is atomic on the same filesystem; claude either sees the old bytes or the new bytes, never a partial write.

4. **Hash before write.** Comparing the hash to last-pushed-hash prevents needlessly rewriting unchanged files. Cheap insurance against accidental mass file-mtime updates that could confuse downstream tools.

5. **0600 mode on credentials files.** Match the existing umask 0177 + write pattern in cmd-create.sh:222-224. The watcher's write MUST preserve those permissions; don't accidentally widen.

6. **Watcher's exit conditions.**
   - SIGTERM (from `aidc auth-bridge stop`): graceful exit, remove PID file.
   - SIGINT: same as SIGTERM.
   - Keychain entry deleted entirely: log a warning, keep polling (user may re-login eventually).
   - `~/.config/aidc/` removed: unlikely, log + exit.
   - Auth-bridge log file ENOSPC: log to stderr; continue; the watcher's primary job is syncing, not logging.

7. **`.disabled` sentinel semantics.**
   - `aidc auth-bridge stop` -> touch `.disabled`, kill PID.
   - `aidc auth-bridge start` (manual) -> remove `.disabled`, spawn.
   - `aidc auth-bridge start --force` -> same.
   - `aidc create` / `aidc mcp start`'s auto-start call -> check `.disabled`; if present, skip silently. Log to auth-bridge.log that the auto-start was suppressed by the sentinel so `aidc auth-bridge logs` shows it.
   - `aidc auth-bridge restart` -> remove `.disabled`, stop + start.

8. **Auto-stop respects ordering of teardown.** `aidc kill` and `aidc mcp stop` both call `aidc_anything_running` AFTER their main work. If `aidc kill foo` runs while `aidc-bar` is still up, `aidc_anything_running` returns true → auth bridge keeps running. If `foo` is the last one, returns false → bridge stops. Correct in both cases.

9. **Race condition: two `aidc create`s start simultaneously, both call auth-bridge start.** Handled by the PID-file check inside `start` — the second `start` sees a live PID and no-ops. No locking needed.

10. **Race condition: `aidc create` calls auth-bridge start RIGHT after kill stopped it.** The two operations interleave: kill notices no sessions, stops bridge. Create starts new session, ensures bridge is up. The fact that bridge was briefly down isn't a correctness issue (sessions don't drop dead in 30s without auth-bridge).

11. **Log format.** Match the existing pattern from `dockerd-start.sh`: `[%s] [aidc-auth-bridge] %s\n` with ISO 8601 timestamp. Makes `aidc auth-bridge logs` greppable.

---

## Anti-patterns

- **DO NOT** put the watcher inside a docker container. The whole point of this task is that the Keychain isn't reachable from inside containers; running the watcher in one defeats it.
- **DO NOT** make this configurable to "off" via the global config (other than via the `.disabled` sentinel). Auth refresh is correctness, not a feature you'd want to disable. The `.disabled` sentinel exists specifically for the "I want to debug this" case, not the "I don't want auth refresh" case.
- **DO NOT** add a `aidc auth-bridge refresh` subcommand (push now without waiting for the next poll). That's the "command you run to refresh" pattern Pace explicitly ruled out. The polling does it; if 30s is too slow, lower `poll_seconds`.
- **DO NOT** persist the daemon state across reboot via launchd. If the user reboots, the next `aidc create` re-starts the daemon. Defer launchd until we have a real reason to use it.
- **DO NOT** wake the daemon on FS events (kqueue / fswatch). Polling 30s is plenty responsive; FS-event plumbing is overhead for a use case where the latency budget is "within a minute or two of host /login."
- **DO NOT** also push the Keychain content to the host's `~/.claude/.credentials.json`. macOS Claude reads from Keychain, not from that file. Pushing to it would create a divergence between two host-side sources of truth.
- **DO NOT** call `aidc auth-bridge start` from `aidc restart` or `aidc upgrade`. Those don't establish new sessions; if the daemon was already up it stays up; if it was deliberately stopped, restart/upgrade shouldn't re-enable it.

---

## Success Criteria

- [ ] `scripts/cmd-auth-bridge.sh` exists with verb dispatch and a `# desc:` line. `aidc help` shows `auth-bridge`.
- [ ] `scripts/aidc-auth-bridge-watcher.sh` exists; not user-invocable via `aidc <watcher-name>` (skipped from help discovery).
- [ ] On macOS, `aidc create <name>` auto-starts the daemon. PID file appears at `~/.config/aidc/auth-bridge.pid`; log file at `~/.config/aidc/auth-bridge.log` starts populating.
- [ ] On macOS, `aidc create <name>` when the daemon is already running is a no-op (idempotent; existing daemon keeps running).
- [ ] Manual `claude /login` on host produces a fresh Keychain entry. Within ~30s, `~/aidc-audit/<active-session>/.claude-credentials.json` is updated with the new content (verified by diffing hashes).
- [ ] Container's `/home/vscode/.claude/.credentials.json` (the bind-mount target) reflects the update — `docker exec aidc-<session>-dev cat ...` returns the new content.
- [ ] `aidc auth-bridge stop` kills the daemon, removes PID file, touches `.disabled` sentinel.
- [ ] After explicit `aidc auth-bridge stop`, a subsequent `aidc create` does NOT auto-start the daemon. `aidc auth-bridge logs` shows the suppression message.
- [ ] `aidc auth-bridge start` (or `restart`) clears `.disabled` and resumes.
- [ ] `aidc auth-bridge start --force` overrides `.disabled`.
- [ ] `aidc kill <last-session>` (with no MCP running) stops the daemon. PID file removed.
- [ ] `aidc kill <not-last-session>` (other sessions still up) does NOT stop the daemon.
- [ ] `aidc mcp stop` (with no sessions running) stops the daemon.
- [ ] `aidc mcp stop` (with sessions still running) does NOT stop the daemon.
- [ ] `aidc auth-bridge status` shows: daemon PID, last extraction time, last push time, count of session credentials files being kept fresh, `.disabled` sentinel state.
- [ ] `aidc auth-bridge logs` tails the log.
- [ ] On Linux / WSL2, `aidc auth-bridge start` prints "not needed on this platform" and exits 0.
- [ ] On Linux / WSL2, `aidc create` and `aidc mcp start` do NOT spawn the daemon (the auto-start helper short-circuits on non-Darwin uname).
- [ ] Atomic-write verified: a `dd if=/dev/urandom` thrash of the credentials file by the watcher during simultaneous container reads produces no partial-read errors (the test can be conceptual — the property is enforced by the `<file>.new + mv -f` pattern).
- [ ] Daemon's PID file is cleaned up on SIGTERM / SIGINT.
- [ ] `make smoke` passes 10/10 runs. (Smoke runs on Linux in CI, where the daemon is a no-op; the auto-start helper short-circuits and smoke is unaffected. On macOS the auto-start happens; smoke shouldn't notice.)

---

## Verification

```bash
# macOS-side end-to-end
scripts/aidc create authtest --profile python --repo "$(pwd)"
scripts/aidc auth-bridge status        # daemon running, PID shown
ls ~/.config/aidc/auth-bridge.{pid,log}

# Capture current bridged content hash
BEFORE=$(shasum -a 256 ~/aidc-audit/authtest-*/.claude-credentials.json | awk '{print $1}')
echo "before: $BEFORE"

# Force a "keychain change" by interacting with `claude /login` (manual step
# the operator does), OR for testing simulate via:
#   1. Read current Keychain value
#   2. Modify a single byte and write back via `security add-generic-password -U`
#   3. Wait <= 30s
#   4. Re-hash the bridged file -- should be different
# (Manual test plan documented in release-process.md.)

# Verify status after a push
scripts/aidc auth-bridge status        # shows last-push timestamp updated

# Explicit stop + verify sentinel + verify auto-restart suppression
scripts/aidc auth-bridge stop
test -f ~/.config/aidc/auth-bridge.disabled && echo "sentinel present"
scripts/aidc create authtest2 --profile python --repo /tmp           # auth-bridge NOT auto-started
ls ~/.config/aidc/auth-bridge.pid 2>&1                               # should be missing

# Explicit start clears sentinel
scripts/aidc auth-bridge start
test -f ~/.config/aidc/auth-bridge.disabled || echo "sentinel cleared"
ls ~/.config/aidc/auth-bridge.pid                                    # present

# Kill all + verify auto-stop
scripts/aidc kill authtest
scripts/aidc kill authtest2
scripts/aidc auth-bridge status                                      # not running

# Linux / WSL2: auto-no-op
# (Only relevant if testing on those platforms.)
# uname -s on Darwin = "Darwin", on Linux/WSL2 = "Linux"
scripts/aidc auth-bridge start
# expected output: "auth bridge is not needed on this platform (host credentials are bind-mounted directly)"

# Smoke
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "=== smoke $i ==="
    make smoke 2>&1 | grep -E '^(passed|failed)'
done
```

---

## Enforcement Test Suggestions

- [ ] The watcher process MUST never expose the credentials value in its log output. Suggested test: a grep in `make lint` against the watcher script that flags any direct interpolation of the Keychain content variable into a log line (`printf ... "$creds"`-style patterns).
- [ ] The bridged file MUST always be written with 0600 mode. Suggested test: a smoke step that asserts `stat -f %A` (or equivalent) on the bridged file returns `600` after a watcher push.
