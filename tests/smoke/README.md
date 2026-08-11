# aidc smoke tests

End-to-end harness that proves aidc's isolation guarantees actually hold. It
creates a real session, asserts behaviours against the live containers, and
tears everything down. This is what `make smoke` runs.

## Run

```bash
make smoke
# or:
bash tests/smoke/run.sh
```

Expected: all assertions pass, exit code 0.

## Prerequisites

- Docker (engine reachable; `docker info` succeeds)
- `docker compose` plugin (v2)
- `jq`, `curl`, `git` on PATH
- Network access to `example.com` and `example.org` (the only outside dependencies)

The smoke writes everything (repo mount, audit dir) to `tests/scratch/<session>/`
INSIDE the repo. That dir is gitignored. Nothing lands in `/tmp/`, `mktemp -d`,
or `~/aidc-audit/`; the per-project `.aidc/config.yaml` written into the scratch
repo overrides the global `audit_dir`. This is deliberate -- it keeps the
smoke self-contained and avoids macOS TCC prompts.

The smoke spins up 5 containers (dev, squid, refresher, policy, audit) for
roughly 60-120 seconds, then tears them down. Wall clock varies with image
build cache; first run on a clean machine will be slower because images get
built.

## What it covers

Verifies the P0 requirements that span multiple shards:

| Step | Requirement IDs | Asserts |
|------|----------------|---------|
| 2 | CTR-09, GIT-03 | no docker.sock leak, no `gh`, no SSH/token leak |
| 3 | GIT-02 | local git works, push fails, pre-push hook installed |
| 4 | DKR-01 | inner Docker daemon up, can't see host containers |
| 5 | NET-01/02/04/05 | example.com allowed, `.cn` TLD blocked, blocklist enforced |
| 6 | SEC-03 | malware hit writes `/var/state/tainted` (valid JSON) |
| 7 | SEC-03 | `aidc status` and `aidc list` surface the taint |
| 8 | -- | audit dir on host has `squid-access.log`, `policy-events.log` (with a `"outcome":"tainted"` line), `meta.json`, `config-snapshot.yaml`; lives under in-repo scratch (no host pollution) |
| 9 | SEC-06 | `aidc kill` removes all containers, preserves audit dir on host |

The TLD-only-does-not-taint (SEC-04) case is exercised implicitly: the `.cn`
block in step 5 fires before the malware injection, and if the policy sidecar
were tainting on TLD hits the tainted flag would appear before step 6's
malware injection. The default `tld_taints=false` is what we're checking.

## What it does NOT cover

- Claude Code itself is never installed or invoked. This is a sandbox test.
- The Phase 2 HTTP API is not exercised.
- Performance / load characteristics.
- Multi-session interference (only one session is created).
- Cross-platform path quirks (Linux + macOS host paths only).

## Debugging a failure

Set `AIDC_SMOKE_PRESERVE=1` to skip the cleanup trap when the run exits
non-zero:

```bash
AIDC_SMOKE_PRESERVE=1 make smoke
```

The script prints the session name and audit dir on failure so you can:

```bash
aidc status <session>
aidc attach <session>
docker logs aidc-<session>-policy
docker logs aidc-<session>-squid
ls -la <audit-dir>
```

Tear down manually when done:

```bash
aidc kill <session>
```

## Design notes

- The session name is `smoke-$(date +%s)` so reruns never collide and never
  shadow a user's real session.
- The cleanup trap runs on `EXIT`, `INT`, and `TERM` so Ctrl-C never leaks
  containers. Set `AIDC_SMOKE_PRESERVE=1` to opt out for debugging.
- The audit dir is parsed from `aidc create` output (the `audit:` line) which
  is the canonical place that path is surfaced. `aidc status` does not print
  it, so we capture it at create time.
- Assertions test file presence and content patterns -- never log line
  counts -- because Squid logging is non-deterministic.
- Squid blocklist hot-reload (`squid -k reconfigure`) is exercised as a
  side-effect of injecting the malware test domain; this is the same path the
  refresher sidecar uses.
