# task-05: Proxy — Policy Sidecar (Taint Detection)

## Objective

Build the sidecar that tails Squid's access log in real time, detects malware-blocklist hits, persists a taint flag to shared volume, and applies the configured taint response (`log` / `notify` / `freeze`). This is the runtime safety mechanism that turns "proxy blocked something bad" into "kill this container."

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| NET-07 | Policy sidecar tails Squid access.log, detects malware-list hits, writes taint flag readable by aidc status | P0 |
| SEC-02 | Tainted state persisted to shared volume | P0 |
| SEC-03 | Taint MUST trigger on any malware-list hit | P0 |
| SEC-04 | TLD hits are logged but DO NOT taint by default; configurable | P0 |
| SEC-05 | Response configurable: log / notify / freeze | P0 |
| SEC-08 | Default response when no config: `notify` | P1 |

---

## Design Context

From `docs/design-04-proxy-stack.md`:
> Tail `/var/log/squid/access.log` (shared volume with Squid). For each access line, parse the destination domain. If the line is a `TCP_DENIED` event and the deny reason involves the `malware_domains` ACL → trigger taint. If the deny involves only `bad_tld`, log but do not taint (unless `tld_taints: true`).

> Taint action: write `/var/state/tainted` with timestamp + offending line. Then execute the configured taint response.

From `docs/design-07-safety-model.md`:
> When taint triggers, the policy sidecar atomically writes `/var/state/tainted`. The file contents (JSON): `tainted_at`, `trigger`, `domain`, `squid_log_line`.

> Responses: `log` (flag only), `notify` (flag + FIFO/webhook/osascript alert), `freeze` (flag + `docker pause` on dev container).

---

## Files to Create

### `proxy/policy/Dockerfile`

Base on `alpine:3.20`. Install:

- `bash`, `coreutils`, `inotify-tools` (for log file rotation handling), `curl` (for webhook notify), `docker-cli` (for the freeze response — `docker pause`)

COPY `policy.sh` and `notify.sh` to `/usr/local/bin/`, chmod +x. Set CMD to `/usr/local/bin/policy.sh`.

Note: docker-cli inside the policy container is for issuing `docker pause` on the sibling dev container. The compose template mounts `/var/run/docker.sock` from the host into the policy container — see Implementation Notes.

### `proxy/policy/policy.sh`

The main tailer + dispatcher.

Responsibilities:

1. Read configuration from environment variables (compose passes these from the session's resolved config):
   - `AIDC_SESSION` — the session name (used to compute the dev container's docker name)
   - `AIDC_TAINT_RESPONSE` — `log` | `notify` | `freeze`. Default: `notify`.
   - `AIDC_TLD_TAINTS` — `true` | `false`. Default: `false`.
   - `AIDC_NOTIFY_WEBHOOK` — optional URL. If set, POST taint events to it.

2. Tail `/var/log/squid/access.log` with rotation awareness. Use `tail -F` (capital F handles rotation) or an inotify-driven loop.

3. For each new line, parse it. Squid `squid` log format columns (space-separated):
   ```
   <timestamp> <elapsed> <client_ip> <result/code> <bytes> <method> <url> <user> <hierarchy/from> <content_type>
   ```
   The `result/code` field looks like `TCP_DENIED/403` on a block.

4. **Critical: distinguishing malware vs TLD block.** Squid's default `access.log` does NOT tell you *which* ACL denied a request — both malware_domains and bad_tld show up as the same `TCP_DENIED/403`. To distinguish, we need a secondary check:
   - Read `/etc/squid/blocklist.txt` (mounted in read-only from the shared volume) into a hash set on startup, and re-read it on inotify-change.
   - Read `/etc/squid/state-actor-tlds.txt` (mounted in read-only) into a TLD list on startup.
   - For each denied request, extract the domain from the URL. Check membership: if it matches `blocklist.txt` exactly (or as a parent of), it's a **malware** hit. Otherwise if it matches any TLD in `state-actor-tlds.txt`, it's a **TLD** hit.

5. On malware hit: ALWAYS taint.

6. On TLD hit: if `AIDC_TLD_TAINTS=true`, taint; else just log to `/var/log/aidc/policy-events.log`.

7. Taint action (atomic):
   - Build the JSON payload:
     ```json
     {
       "tainted_at": "<ISO8601>",
       "trigger": "malware_domains",
       "domain": "<offending domain>",
       "squid_log_line": "<full line>"
     }
     ```
   - Write to `/var/state/tainted.new`, then `mv` to `/var/state/tainted`.
   - Call `notify.sh` with the JSON as stdin.
   - If `AIDC_TAINT_RESPONSE=freeze`: call `docker pause aidc-${AIDC_SESSION}-dev`. Log result.
   - Once tainted, the policy script continues running but skips re-tainting (the file already exists; one event is the signal).

8. Also write each event to `/var/log/aidc/policy-events.log` (append-only) regardless of taint outcome.

### `proxy/policy/notify.sh`

Receives a JSON taint event on stdin and emits notifications based on env vars:

```bash
#!/usr/bin/env bash
set -euo pipefail

JSON=$(cat)
EVENT_TIME=$(printf '%s' "$JSON" | sed -n 's/.*"tainted_at":"\([^"]*\)".*/\1/p')
DOMAIN=$(printf '%s' "$JSON" | sed -n 's/.*"domain":"\([^"]*\)".*/\1/p')
TRIGGER=$(printf '%s' "$JSON" | sed -n 's/.*"trigger":"\([^"]*\)".*/\1/p')

# Always: log to events file
mkdir -p /var/log/aidc
printf '%s\n' "$JSON" >> /var/log/aidc/policy-events.log

# Always: append to host-visible FIFO (compose mounts a directory under audit_dir)
FIFO=/var/aidc/audit/taint-events
if [ -p "$FIFO" ]; then
    printf '%s\n' "$JSON" > "$FIFO" || true
else
    # If no FIFO, append to a plain file
    mkdir -p "$(dirname "$FIFO")"
    printf '%s\n' "$JSON" >> "${FIFO}.log"
fi

# Conditional: webhook
if [ -n "${AIDC_NOTIFY_WEBHOOK:-}" ]; then
    curl -fsS -X POST -H 'Content-Type: application/json' \
        --max-time 10 \
        -d "$JSON" \
        "$AIDC_NOTIFY_WEBHOOK" >/dev/null || true
fi

# Response mode is enforced by the caller (policy.sh) — notify.sh handles only the alerting fan-out.
```

### `proxy/policy/parse-domain.sh`

Helper used inline by `policy.sh` to extract the domain from a Squid URL. For HTTPS, the URL is `host:port`. For HTTP, it's a full URL. Use a small shell function or a bundled awk script:

```bash
extract_domain() {
    local url="$1"
    # Strip scheme
    url="${url#http://}"
    url="${url#https://}"
    # Strip path
    url="${url%%/*}"
    # Strip port (for CONNECT host:port style)
    url="${url%%:*}"
    # Strip userinfo
    url="${url##*@}"
    printf '%s\n' "$url"
}
```

Inline this into `policy.sh` rather than a separate file — keeps the parse logic colocated.

---

## Implementation Notes

1. **Distinguishing ACL hits.** Squid does not log *which* deny ACL fired (its log format predates that need). Our approach: post-classify by membership check against the two files. This is the most robust approach without modifying Squid's log format. An alternative (more invasive) is to write to two different access logs from Squid using `access_log` directives with `acl` filters — but that complicates Squid config. Stick with post-classification.

2. **File-watching.** `/etc/squid/blocklist.txt` changes when the refresher writes. Re-read on inotify events. If `inotify-tools` proves flaky, fall back to a 60-second poll of mtime.

3. **Idempotent taint.** Once `/var/state/tainted` exists, additional events go to the events log but do NOT trigger a new freeze/notify. One taint = one alert. The session needs to die and be recreated to clear taint.

4. **Docker socket access.** The compose template mounts `/var/run/docker.sock` from the host into the policy container ONLY when `taint_response: freeze`. For `log` and `notify`, the socket is not mounted — minimizing exposure. The policy script checks for socket presence before attempting `docker pause`.

5. **TLD matching.** Squid matches `.cn` as a suffix (`dstdomain` semantics). The policy sidecar's TLD check should do the same: a domain matches a TLD if it ends with the TLD pattern. E.g., `evil.cn` matches `.cn`.

6. **Logging style.** Use `printf '%s\n'` not `echo -e`; portability across shells. Timestamp lines with `date -u +%FT%TZ`.

7. **Startup behavior.** On startup, the tail-F begins from the current end of the log (`tail -F -n 0`). Pre-existing events in the log are NOT re-evaluated — taint is forward-only from this session's start. Document this in a comment.

---

## Anti-patterns

- DO NOT modify `/var/log/squid/access.log` — read only.
- DO NOT taint on every line after the first — idempotent guard via the flag file's presence.
- DO NOT mount Docker socket for `log` or `notify` responses — only for `freeze`.
- AVOID parsing Squid logs with regex on the whole URL — extract the domain field first, then membership-check.
- AVOID using `tail -f` (lowercase) — use `tail -F` to survive rotation.

---

## Success Criteria

- [ ] `proxy/policy/Dockerfile` builds
- [ ] `policy.sh` starts, finds `/var/log/squid/access.log` (or waits for it), and begins tailing
- [ ] Injecting a `TCP_DENIED` line for a domain in blocklist.txt causes `/var/state/tainted` to be written exactly once
- [ ] Injecting a `TCP_DENIED` line for a TLD-only hit does NOT taint when `AIDC_TLD_TAINTS=false`
- [ ] Injecting a TLD hit DOES taint when `AIDC_TLD_TAINTS=true`
- [ ] `policy-events.log` records both classes of events
- [ ] With `AIDC_TAINT_RESPONSE=notify` and `AIDC_NOTIFY_WEBHOOK` set, a taint event POSTs to the webhook
- [ ] With `AIDC_TAINT_RESPONSE=freeze` and docker.sock mounted, the dev container is paused after taint
- [ ] After taint, second occurrences write events but do NOT re-notify or re-pause

---

## Verification

```bash
# Build
docker build -t aidc-policy-test proxy/policy/

# Set up test volumes
mkdir -p /tmp/aidc-policy/squid /tmp/aidc-policy/state /tmp/aidc-policy/log /tmp/aidc-policy/audit
echo "blocked.example" > /tmp/aidc-policy/squid/blocklist.txt
echo ".cn" > /tmp/aidc-policy/squid/state-actor-tlds.txt
touch /tmp/aidc-policy/log/access.log

# Run policy with notify mode
docker run -d --name pol-test \
    -e AIDC_SESSION=test \
    -e AIDC_TAINT_RESPONSE=notify \
    -e AIDC_TLD_TAINTS=false \
    -v /tmp/aidc-policy/squid:/etc/squid:ro \
    -v /tmp/aidc-policy/state:/var/state \
    -v /tmp/aidc-policy/log:/var/log/squid \
    -v /tmp/aidc-policy/audit:/var/aidc/audit \
    aidc-policy-test

sleep 2

# Inject a malware-list hit
printf '1716300000.000 1 127.0.0.1 TCP_DENIED/403 0 GET http://blocked.example/ - HIER_NONE/- -\n' \
    >> /tmp/aidc-policy/log/access.log
sleep 1
test -f /tmp/aidc-policy/state/tainted && echo "TAINTED OK"
cat /tmp/aidc-policy/state/tainted

# Inject a TLD-only hit (should NOT taint, because flag was already set, but events log should grow)
LINES_BEFORE=$(wc -l < /tmp/aidc-policy/log/access.log)
printf '1716300100.000 1 127.0.0.1 TCP_DENIED/403 0 GET http://something.cn/ - HIER_NONE/- -\n' \
    >> /tmp/aidc-policy/log/access.log
sleep 1

# Cleanup
docker rm -f pol-test
rm -rf /tmp/aidc-policy
```

---

## Enforcement Test Suggestions

- [ ] Idempotent taint (one event = one notify) — suggested test: inject two malware hits, assert webhook called exactly once
- [ ] No Docker socket for log/notify modes — suggested test: parse compose template, assert socket mount only present in freeze mode
- [ ] TLD-vs-malware classification is correct — suggested test: domains that are both in blocklist and under a blocked TLD should classify as malware (the higher-signal class)
