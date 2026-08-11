# task-06: Proxy — Audit Aggregator Sidecar

## Objective

Build the sidecar that collects forensic artefacts from the running session into a host-visible audit directory: Squid access log, policy events, refresher log, dev container shell history, optional Claude Code transcript, plus a meta.json. The audit dir persists after `aidc kill` so post-incident review is possible.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| NET-08 | Audit aggregator collects Squid access log, dev container shell history, and Claude Code session transcripts into a host-visible audit directory | P0 |
| SEC-07 | Audit captures enough data for post-hoc forensic review of taint events | P0 |

---

## Design Context

From `docs/design-04-proxy-stack.md`:
> **What it collects** (into `${audit_dir}/${session}-${timestamp}/`):
> - `squid-access.log` — copied from Squid's volume
> - `dev-shell-history` — pulled from the dev container's `~/.bash_history` and `~/.zsh_history` periodically
> - `claude-transcript/` — Claude Code's session transcript directory, if the user has configured Claude Code to write one
> - `policy-events.log` — every taint event the policy sidecar wrote
> - `refresher.log` — feed fetch successes/failures
> - `meta.json` — session start/end timestamps, profile, config snapshot, container image digests

From `docs/design-04-proxy-stack.md`:
> The compose stack mounts `${audit_dir}` from host into the audit container. The dev container also has a read-only mount of `/var/aidc/audit` so Claude can see what's been logged (transparency).

---

## Files to Create

### `proxy/audit/Dockerfile`

Base on `alpine:3.20`. Install:

- `bash`, `coreutils`, `jq` (for meta.json updates)

COPY `aggregate.sh` and (optionally) `init-meta.sh` to `/usr/local/bin/`, chmod +x. Set CMD to `/usr/local/bin/aggregate.sh`.

### `proxy/audit/aggregate.sh`

The main loop. Runs every N seconds (default 60); copies and updates artefacts.

Responsibilities:

1. Read environment:
   - `AIDC_SESSION` — session name
   - `AIDC_AUDIT_INTERVAL` — seconds between sweeps; default `60`

2. The audit container's filesystem layout (mounted by compose):
   - `/var/aidc/audit/` — host-mounted; the persistent output dir for THIS session (already includes session subdirectory)
   - `/var/log/squid/` — read-only, shared with Squid
   - `/var/log/aidc/` — read-only, shared with policy + refresher
   - `/var/aidc/dev-home/` — read-only mount of the dev container's `/home/vscode/`
   - `/var/aidc/claude-transcript/` — read-only mount of Claude's transcript dir (if configured)
   - `/var/aidc/state/` — read-only mount of taint state

3. On startup: initialize `meta.json` if absent. Includes:
   ```json
   {
     "session": "<name>",
     "started_at": "<ISO8601 UTC>",
     "profile": "<from env>",
     "image_digests": {
       "dev": "<from env, populated by aidc create>",
       "squid": "...",
       "refresher": "...",
       "policy": "...",
       "audit": "..."
     },
     "config_snapshot": "<inlined from a mounted file>"
   }
   ```

4. Each loop iteration:
   - Copy `/var/log/squid/access.log` → `/var/aidc/audit/squid-access.log` (atomic via `.tmp` + mv)
   - Copy `/var/log/aidc/policy-events.log` → `/var/aidc/audit/policy-events.log`
   - Copy `/var/log/aidc/refresher.log` → `/var/aidc/audit/refresher.log` (if present)
   - Copy `/var/aidc/dev-home/.bash_history` → `/var/aidc/audit/dev-bash-history` (if present)
   - Copy `/var/aidc/dev-home/.zsh_history` → `/var/aidc/audit/dev-zsh-history` (if present)
   - rsync-like copy of `/var/aidc/claude-transcript/` → `/var/aidc/audit/claude-transcript/` if present (use `cp -a` if rsync not available — alpine doesn't ship rsync by default; install it or use cp)
   - If `/var/aidc/state/tainted` exists, copy it AND update `meta.json` to set `tainted_at` to its content

5. Loop forever; on signal, do a final sweep then exit. Compose's `docker compose down` sends SIGTERM; trap it.

6. On SIGTERM:
   - Do final copy
   - Update `meta.json` with `killed_at: <ISO8601>`
   - Exit 0

### `proxy/audit/finalize.sh`

A standalone script `aidc kill` invokes to do a final sweep + close meta.json BEFORE bringing down the stack. (See task-08-cli's kill subcommand.) Same logic as the loop's final-sweep block, callable standalone.

```bash
#!/usr/bin/env bash
# Final audit sweep; called by aidc kill before tear-down.
set -euo pipefail

# Same copies as one loop iteration
/usr/local/bin/aggregate.sh --once

# Close meta.json
META=/var/aidc/audit/meta.json
if [ -f "$META" ]; then
    TMP=$(mktemp)
    jq --arg ts "$(date -u +%FT%TZ)" '.killed_at = $ts' "$META" > "$TMP"
    mv "$TMP" "$META"
fi
```

Implement `aggregate.sh --once` as a one-shot mode (single sweep, no loop) so finalize can reuse it.

---

## Implementation Notes

1. **Read-only mounts.** The audit container should only have READ access to the source data. The compose template enforces this with `:ro` suffixes. The audit container's write access is limited to `/var/aidc/audit/`.

2. **Per-session output directory.** The compose template mounts `${AUDIT_DIR}/${SESSION}-${TIMESTAMP}/` as the audit container's `/var/aidc/audit/`. The audit container does NOT need to compute the timestamp or create the dir — that's `aidc create`'s job.

3. **Claude transcript location.** Claude Code writes session transcripts to `~/.claude/projects/<encoded-path>/` (the same place this memory lives, for context). For aidc, we configure Claude inside the dev container with `CLAUDE_CODE_TRANSCRIPT_DIR` env (or equivalent) pointing at a known location like `/var/claude-transcripts/<session>/`. The dev container's compose mount maps that into `/var/aidc/claude-transcript/` in the audit container.

   In v1, this is best-effort: if Claude is not configured, no transcript appears, audit just skips it.

4. **Robustness.** Source files may be locked, missing, or rotating. Every copy must be wrapped in a non-fatal block. The audit container should keep running even if individual copies fail.

5. **Disk usage.** Squid access logs can grow quickly. v1 simply mirrors them; rotation/pruning is deferred to a future `aidc audit-prune` command (P2). Document this in `aggregate.sh` comments.

6. **Atomic copies.** Use `cp <src> <dst>.tmp && mv <dst>.tmp <dst>` so concurrent readers of audit dir never see a partial file.

---

## Anti-patterns

- DO NOT modify source files. Read-only.
- DO NOT delete audit data ever, automatically. Cleanup is user action via future audit-prune.
- DO NOT swallow signals. SIGTERM must trigger final sweep.
- AVOID synchronous webhook-style processing in the audit loop — keep the loop simple file copies.

---

## Success Criteria

- [ ] `proxy/audit/Dockerfile` builds
- [ ] `aggregate.sh` runs as the container's main process and loops every 60s by default
- [ ] `aggregate.sh --once` does a single sweep and exits
- [ ] Empty mounted source dirs do not cause crashes
- [ ] `meta.json` is created on startup and updated on taint / shutdown
- [ ] Final sweep on SIGTERM produces a clean snapshot
- [ ] Output files appear in `/var/aidc/audit/` after first loop iteration

---

## Verification

```bash
# Build
docker build -t aidc-audit-test proxy/audit/

# Set up source dirs
mkdir -p /tmp/aidc-audit/{out,squid,aidc,dev-home,claude-transcript,state}
echo "fake squid access log" > /tmp/aidc-audit/squid/access.log
echo '{"taint":"test"}' > /tmp/aidc-audit/aidc/policy-events.log
echo "ls -la" > /tmp/aidc-audit/dev-home/.bash_history

# Run audit container, short interval for testing
docker run -d --name aud-test \
    -e AIDC_SESSION=test \
    -e AIDC_AUDIT_INTERVAL=2 \
    -v /tmp/aidc-audit/out:/var/aidc/audit \
    -v /tmp/aidc-audit/squid:/var/log/squid:ro \
    -v /tmp/aidc-audit/aidc:/var/log/aidc:ro \
    -v /tmp/aidc-audit/dev-home:/var/aidc/dev-home:ro \
    -v /tmp/aidc-audit/claude-transcript:/var/aidc/claude-transcript:ro \
    -v /tmp/aidc-audit/state:/var/aidc/state:ro \
    aidc-audit-test

sleep 4

# Check outputs
ls -la /tmp/aidc-audit/out/
# Expected to see: meta.json, squid-access.log, policy-events.log, dev-bash-history
cat /tmp/aidc-audit/out/meta.json
# Expected: JSON with session=test, started_at=...

# Run finalize via exec
docker exec aud-test /usr/local/bin/finalize.sh

# meta.json should now have killed_at
jq '.killed_at' /tmp/aidc-audit/out/meta.json

# Cleanup
docker rm -f aud-test
rm -rf /tmp/aidc-audit
```

---

## Enforcement Test Suggestions

- [ ] Audit container has no write access outside /var/aidc/audit — suggested test: compose template review for :ro on source mounts
- [ ] meta.json is JSON-valid at all times (atomic updates) — suggested test: spam-update while reading, assert always parses
