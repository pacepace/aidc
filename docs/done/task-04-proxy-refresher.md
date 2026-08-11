# task-04: Proxy — Refresher Sidecar

## Objective

Build the sidecar that keeps Squid's malware blocklist fresh. Fetches URLhaus, ThreatFox, and HaGeZi-TIF feeds, normalizes them to one domain per line, atomically writes the result to a shared volume Squid reads, and signals Squid to reload via shared PID namespace. Runs once at startup, then every 6 hours.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| NET-04 | Squid consults a file-backed blocklist refreshed from URLhaus/ThreatFox/HaGeZi-TIF | P0 |
| NET-06 | Refresher fetches on startup and every 6h, atomically writes, signals Squid via `kill -HUP` in shared PID namespace | P0 |
| NET-11 | If feeds unreachable, last-good blocklist keeps serving; refresher failure MUST NOT block proxy | P0 |
| NET-12 | Feed URLs hard-coded into the refresher image, NOT runtime-configurable | P1 |
| NET-09 | Per-project blocklist additions in `/etc/squid/blocklist-additions.conf` are merged with feed-sourced lines | P0 |

---

## Design Context

From `docs/design-04-proxy-stack.md`:
> **Refresher sidecar.** Alpine + curl + ~30-line shell script. Sleep 6h → fetch → atomic-write → signal squid via `pid: service:squid` namespace share → `kill -HUP`. Also runs once at proxy startup.

> **Feeds fetched** (URLs baked into the image per NET-12):
> - URLhaus host list — `https://urlhaus.abuse.ch/downloads/hostfile/`
> - ThreatFox CSV (extract domains) — `https://threatfox.abuse.ch/export/csv/recent/`
> - HaGeZi Threat-Intelligence Feeds — `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.txt`

> **Failure semantics.** If a feed is unreachable, the refresher logs the failure and keeps the previous blocklist in place. It does NOT crash and does NOT empty the blocklist on partial failure. If all three feeds fail, the previous list keeps serving.

---

## Files to Create

### `proxy/refresher/Dockerfile`

Base on `alpine:3.20` (digest-pinned where practical). Install:

- `curl`, `bash`, `coreutils`, `gawk` (POSIX awk in busybox is too limited for some parses), `procps` (provides `kill`)

COPY `refresh.sh` and `loop.sh` to `/usr/local/bin/`, chmod +x. Set CMD to `/usr/local/bin/loop.sh`.

### `proxy/refresher/refresh.sh`

The one-shot refresh script. Idempotent; exits non-zero on hard failure.

Responsibilities:

1. Define hard-coded feed URLs (per NET-12):
   - `URLHAUS_URL=https://urlhaus.abuse.ch/downloads/hostfile/`
   - `THREATFOX_URL=https://threatfox.abuse.ch/export/csv/recent/`
   - `HAGEZI_TIF_URL=https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.txt`

2. Fetch each feed to a temp file. Use `curl -fsSL --max-time 60 -o $TMP $URL`. On any individual feed failure, log to stderr and continue with the others.

3. Normalize each feed to one domain per line:
   - URLhaus hostfile format: `0.0.0.0 domain` per line — strip the IP prefix, strip comments
   - ThreatFox CSV: skip header, extract column 3 (`ioc_value` field) when `ioc_type` is `domain`, strip quotes
   - HaGeZi TIF wildcard: domains in `*.domain` wildcard format — strip leading `*.`

4. Merge with per-project additions from `/etc/squid/blocklist-additions.conf` (mounted in at runtime by the compose template; may be empty or absent — handle gracefully).

5. Deduplicate, sort, strip empty lines and comments.

6. Validate result: must be non-empty. If empty (e.g., all feeds failed and no additions), DO NOT overwrite the existing blocklist. Log and exit 1.

7. Atomic write: write to `/etc/squid/blocklist.txt.new`, then `mv` rename to `/etc/squid/blocklist.txt`.

8. Signal Squid: `kill -HUP 1`. PID 1 in the refresher's namespace is the Squid process because compose sets `pid: service:squid`. If the kill fails (different PID semantics, Squid not yet up), log but exit 0 — refresh succeeded even if signal didn't land; Squid will pick up changes on next own reconfigure.

9. Print a one-line summary to stdout: `refreshed: N entries from urlhaus=$a threatfox=$b hagezi=$c additions=$d (took ${seconds}s)`.

### `proxy/refresher/loop.sh`

The container's main process. Runs `refresh.sh` once on startup, then loops every 6h.

```bash
#!/usr/bin/env bash
set -euo pipefail

REFRESH_INTERVAL="${AIDC_REFRESH_INTERVAL:-21600}"   # seconds; 6h default

echo "aidc-refresher: starting (interval=${REFRESH_INTERVAL}s)"

# Startup refresh — log failures but never exit on first refresh failure
if /usr/local/bin/refresh.sh; then
    echo "aidc-refresher: startup refresh OK"
else
    echo "aidc-refresher: startup refresh FAILED (continuing with last-good list)"
fi

# Main loop
while true; do
    sleep "$REFRESH_INTERVAL"
    if /usr/local/bin/refresh.sh; then
        echo "aidc-refresher: periodic refresh OK at $(date -u +%FT%TZ)"
    else
        echo "aidc-refresher: periodic refresh FAILED at $(date -u +%FT%TZ) (keeping last-good list)"
    fi
done
```

The interval is overridable via env for testing (e.g., set to `60` for smoke tests).

---

## Implementation Notes

1. **Feed-specific parsing** — be exact:
   - URLhaus hostfile lines look like: `0.0.0.0 some-domain.example`. Some lines are comments (`# ...`) or blank. AWK: `awk '$1 == "0.0.0.0" { print $2 }'`.
   - ThreatFox CSV has a multi-line header and quoted CSV fields. Column 3 is `ioc_value` when `ioc_type` (column 4) is `domain`. Use a CSV-aware tool or accept some imprecision (we don't ship perfection here).
   - HaGeZi TIF wildcard format: lines like `*.evil.example`. Strip `*.` prefix; ignore non-wildcard lines.

2. **Atomic write** — `mv` is atomic on the same filesystem. Since both temp and target are on the shared named volume mounted at `/etc/squid/`, this works as expected. Do NOT write the target directly; never let Squid see a half-written file.

3. **Empty-result guard** — critical for NET-11. If all three feeds fail and there are no additions, the script must EXIT WITHOUT WRITING. The previous file stays. The loop logs and tries again later.

4. **Signal delivery** — `kill -HUP 1` only works when `pid: service:squid` is set in compose. Document this dependency in a comment near the kill line.

5. **Time-budgeting** — each curl gets `--max-time 60` so a single hung feed doesn't stall the refresh. Total refresh budget should be under 3 minutes even on slow networks.

6. **No network egress filter** — the refresher itself is not behind Squid (would cause a chicken-and-egg). Its network is direct via the host. The compose template (task-07) keeps it on the same network as Squid but does not route its traffic through Squid.

---

## Anti-patterns

- DO NOT overwrite the blocklist with an empty file on feed failure. NET-11 is non-negotiable.
- DO NOT make feed URLs runtime-configurable (NET-12). They're baked in.
- DO NOT panic-exit on individual feed failures. Log and continue.
- DO NOT write to `/etc/squid/blocklist.txt` directly. Always atomic via `.new` and `mv`.
- AVOID complex CSV parsing — if ThreatFox parsing gets gnarly, accept a less-perfect parse rather than pulling in heavy dependencies. URLhaus alone is enough for a baseline.

---

## Success Criteria

- [ ] `proxy/refresher/Dockerfile` builds successfully
- [ ] Container CMD is `loop.sh`
- [ ] `refresh.sh` runs end-to-end against real feeds and writes a non-empty `/etc/squid/blocklist.txt`
- [ ] If a feed returns 5xx or is unreachable, the script continues and writes results from the successful feeds
- [ ] If all feeds fail and no additions exist, the script exits non-zero WITHOUT modifying the existing file
- [ ] `loop.sh` does not exit on refresh failure — it keeps looping
- [ ] Atomic write: at no point during refresh does the target file contain a truncated or partial blocklist

---

## Verification

```bash
# Build
docker build -t aidc-refresher-test proxy/refresher/

# Test 1: a one-shot refresh against real feeds
docker run --rm -v /tmp/aidc-test-squid:/etc/squid aidc-refresher-test /usr/local/bin/refresh.sh
# Expected: writes /tmp/aidc-test-squid/blocklist.txt with thousands of lines
wc -l /tmp/aidc-test-squid/blocklist.txt
# Expected: at least 1000 lines (URLhaus alone usually has >2000)

# Test 2: simulate complete feed failure (block egress) — file must be preserved
echo "preserved.example" > /tmp/aidc-test-squid/blocklist.txt
docker run --rm --network=none -v /tmp/aidc-test-squid:/etc/squid aidc-refresher-test /usr/local/bin/refresh.sh ; echo "exit=$?"
# Expected: exit=1 (failure), and:
cat /tmp/aidc-test-squid/blocklist.txt
# Expected: still "preserved.example" — file untouched

# Test 3: loop.sh runs but does not crash on first failure
docker run --rm --network=none --name lt -d aidc-refresher-test
sleep 3
docker logs lt
# Expected: "startup refresh FAILED" message + container still running
docker rm -f lt

# Cleanup
rm -rf /tmp/aidc-test-squid
```

---

## Enforcement Test Suggestions

- [ ] Feed URLs hard-coded — suggested test: grep refresh.sh for env-driven URL variables (should find none beyond AIDC_REFRESH_INTERVAL)
- [ ] Empty-result guard — suggested test: unit test that mocks all feeds returning empty, asserts target file unchanged and exit 1
