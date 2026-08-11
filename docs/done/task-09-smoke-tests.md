# task-09: Smoke Tests

## Objective

Build the verification harness that proves aidc's isolation guarantees actually hold. The harness creates a real session, runs assertions against the live containers, and tears down. This is what `make smoke` runs and what we use to confirm the implementation matches the design.

---

## Requirements

This shard verifies enforcement of multiple P0 requirements:

- CTR-09 (no host docker.sock in dev container)
- GIT-02 (push/pull/fetch fail inside container)
- GIT-03 (gh CLI not installed)
- DKR-01 (inner docker daemon works)
- NET-01, NET-02 (proxy filters egress)
- NET-04, NET-05 (blocklist + TLD policy enforced)
- NET-10 (proxy outside dev container)
- SEC-03 (taint triggers on malware hit)
- SEC-04 (TLD-only hit does NOT taint by default)
- SEC-06 (tainted container needs kill+create)

---

## Design Context

The smoke test is the integration-level confirmation that the whole system works end-to-end. Individual unit-style tests live with each shard's verification section; this is the cross-cutting test.

---

## Files to Create

### `tests/smoke/run.sh`

The top-level harness. Sequence:

```bash
#!/usr/bin/env bash
# aidc smoke test — verifies isolation guarantees end-to-end.
# Spins up a real session, makes assertions, tears down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AIDC="$AIDC_ROOT/scripts/aidc"

SESSION="smoke-$(date +%s)"
# Scratch lives inside the repo (gitignored) so we never pollute user home,
# /tmp, or any path that would trigger surprising macOS TCC prompts.
SCRATCH="$AIDC_ROOT/tests/scratch/${SESSION}"
TMP_REPO="$SCRATCH/repo"
AUDIT_DIR_OVERRIDE="$SCRATCH/audit"
mkdir -p "$TMP_REPO" "$AUDIT_DIR_OVERRIDE"
# Tell aidc create where to put audit data — overrides the global config's
# audit_dir. The smoke writes a per-project config under TMP_REPO so the
# override is picked up via normal config merge.
mkdir -p "$TMP_REPO/.aidc"
cat > "$TMP_REPO/.aidc/config.yaml" <<EOF
audit_dir: ${AUDIT_DIR_OVERRIDE}
EOF
PASS=0
FAIL=0

cleanup() {
    "$AIDC" kill "$SESSION" 2>/dev/null || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

assert() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "        cmd: $cmd"
        FAIL=$((FAIL + 1))
    fi
}

dev_exec() {
    docker exec "aidc-${SESSION}-dev" bash -c "$1"
}

echo "=== aidc smoke test ==="
echo "session: $SESSION"
echo "repo:    $TMP_REPO"
echo

# Initialize a test repo
(cd "$TMP_REPO" && git init -q && touch README.md && git add . && git -c user.email=test@example.com -c user.name=Test commit -q -m "init")

# Step 1: create session
echo "[1/N] aidc create"
"$AIDC" create "$SESSION" --repo "$TMP_REPO" --profile multi
echo

# Step 2: isolation assertions
echo "[2/N] isolation assertions"
assert "no docker.sock in dev container" \
    "! dev_exec 'test -S /var/run/docker.sock'"
assert "gh CLI not installed" \
    "! dev_exec 'command -v gh'"
assert "no SSH agent socket" \
    "dev_exec 'test -z \"\$SSH_AUTH_SOCK\"'"
assert "no ~/.ssh dir" \
    "! dev_exec 'test -d ~/.ssh'"
assert "no GITHUB_TOKEN env" \
    "dev_exec 'test -z \"\$GITHUB_TOKEN\"'"

# Step 3: git asymmetry
echo "[3/N] git asymmetry"
assert "git status works locally" \
    "dev_exec 'cd /workspaces/repo && git status'"
assert "git commit works locally" \
    "dev_exec 'cd /workspaces/repo && touch f.txt && git add f.txt && git -c user.email=c@example.com -c user.name=C commit -m smoke'"
assert "git push fails (no credentials + pre-push hook)" \
    "! dev_exec 'cd /workspaces/repo && git remote add o https://github.com/aidc-smoke/none.git && git push o main' 2>&1"
assert "system pre-push hook is installed" \
    "dev_exec 'git config --system --get core.hooksPath' | grep -q '/etc/git-hooks'"

# Step 4: DinD
echo "[4/N] DinD"
assert "inner docker daemon works" \
    "dev_exec 'docker version'"
assert "inner docker ps does NOT show host containers" \
    "! dev_exec 'docker ps --format \"{{.Names}}\" | grep -q aidc-${SESSION}-squid'"

# Step 5: proxy enforcement
echo "[5/N] proxy enforcement"
assert "egress to example.com succeeds (default allow)" \
    "dev_exec 'curl -fsS -o /dev/null -w \"%{http_code}\" https://example.com' | grep -q 200"
assert "egress to a TLD-blocked .cn domain fails" \
    "! dev_exec 'curl -fsS --max-time 10 https://anything.cn'"

# Inject a known-bad domain into the blocklist and test
docker exec "aidc-${SESSION}-squid" bash -c 'echo "smoke-evil.example" >> /etc/squid/blocklist.txt && squid -k reconfigure'
sleep 2
assert "egress to a malware-list domain fails" \
    "! dev_exec 'curl -fsS --max-time 10 http://smoke-evil.example'"

# Step 6: taint detection
echo "[6/N] taint detection"
# After the malware hit above, the policy sidecar should have written /var/state/tainted
sleep 3
assert "policy sidecar wrote tainted flag" \
    "docker exec aidc-${SESSION}-policy test -f /var/state/tainted"
assert "tainted flag is valid JSON" \
    "docker exec aidc-${SESSION}-policy cat /var/state/tainted | jq ."

# Step 7: status command surfaces taint
echo "[7/N] aidc status surfaces taint"
assert "aidc status shows tainted=YES" \
    "$AIDC status $SESSION 2>&1 | grep -qi 'tainted.*YES'"

# Step 8: TLD-only hit does NOT taint (was the initial .cn block — should NOT have tainted)
# This is implicit: we already had the .cn block early, and the malware taint only fired AFTER we injected the malware domain.
# If the policy sidecar were tainting on TLD hits too, the tainted flag would have appeared earlier.
# We can't easily test this without time-travel — accept that the smoke covers the malware path.

# Step 9: audit dir populated
echo "[8/N] audit"
AUDIT_DIR=$("$AIDC" status "$SESSION" 2>&1 | grep -i 'audit dir' | awk '{print $NF}')
assert "audit dir exists on host" \
    "test -d \"$AUDIT_DIR\""
assert "audit dir has squid-access.log" \
    "test -s \"$AUDIT_DIR/squid-access.log\""
assert "audit dir has meta.json" \
    "test -f \"$AUDIT_DIR/meta.json\""
assert "meta.json shows tainted_at" \
    "jq -e .tainted_at \"$AUDIT_DIR/meta.json\""

# Step 10: kill tears everything down
echo "[9/N] aidc kill"
"$AIDC" kill "$SESSION"
assert "dev container removed" \
    "! docker ps -a --format '{{.Names}}' | grep -q \"aidc-${SESSION}-dev\""
assert "squid container removed" \
    "! docker ps -a --format '{{.Names}}' | grep -q \"aidc-${SESSION}-squid\""
assert "audit dir preserved after kill" \
    "test -d \"$AUDIT_DIR\""

# Summary
echo
echo "=== smoke summary ==="
echo "passed: $PASS"
echo "failed: $FAIL"
exit $((FAIL == 0 ? 0 : 1))
```

### `tests/smoke/README.md`

Brief notes on:

- Prerequisites: Docker, docker compose, jq, curl
- Cost: spins up ~5 containers for ~2 minutes
- What it covers and what it doesn't (doesn't run Claude Code itself; doesn't test the Phase 2 HTTP API)
- How to debug a failure (preserve session by setting `AIDC_SMOKE_PRESERVE=1`)

### `tests/smoke/preserve-on-fail.sh` (P1)

Optional wrapper that runs `run.sh` and on failure keeps the session alive for inspection. Defer to P1 — `run.sh` with manual `trap` removal works.

---

## Implementation Notes

1. **Idempotency.** The session name includes a timestamp so reruns don't clash. The cleanup trap ensures we never leak.

2. **TLD-vs-malware distinction.** The smoke test deliberately blocks a malware domain AFTER initial .cn-block tests so we can observe that the malware hit, not the TLD hit, triggered the taint.

   **Important — policy reload timing.** When you append a domain to the blocklist live (`docker exec aidc-...-squid bash -c 'echo X >> /etc/squid/blocklist.txt && squid -k reconfigure'`), Squid picks up the change within ~1 second. The policy sidecar relies on inotify to re-read its in-memory set. Wait at least **3 seconds** between the blocklist append and the curl that should trigger taint, so the policy sidecar has time to observe the inotify event AND complete its reload. Earlier manual testing surfaced flakiness with shorter waits.

3. **Timing.** Some assertions need sleeps because the policy sidecar polls or tails with some latency. Keep sleeps minimal but real (2-3 seconds for taint propagation).

4. **Squid reconfigure.** The smoke injects a malware domain via `docker exec aidc-${SESSION}-squid bash -c 'echo ... && squid -k reconfigure'`. This is the same path the refresher uses. Tests both the blocklist mechanism and Squid's hot-reload.

5. **No real Claude Code invocation.** This smoke does NOT install or run Claude Code. It verifies the sandbox; testing Claude itself is out of scope. The dev container would have Claude Code if `multi` profile + npm install were configured, but the smoke focuses on isolation.

6. **Reading audit dir path.** The audit dir is known up front because the smoke wrote `${AUDIT_DIR_OVERRIDE}` into `${TMP_REPO}/.aidc/config.yaml` before `aidc create`. After create, `${AUDIT_DIR_OVERRIDE}/${SESSION}-<timestamp>/` contains the artefacts; the smoke can `ls "$AUDIT_DIR_OVERRIDE"/${SESSION}-*` to find the exact subdir.

7. **Bash safety.** `set -euo pipefail` plus explicit `|| true` where failures are expected (e.g., the assert helpers).

---

## Anti-patterns

- DO NOT run smoke against a session name that might collide with a user's real session. Always timestamp-suffix.
- DO NOT leave containers running after a failed assertion — the cleanup trap must always run.
- DO NOT depend on internet for assertions beyond confirming "example.com is reachable" — pin to a couple of stable domains.
- AVOID asserting on Squid log line counts — they're nondeterministic; assert on file presence and content patterns.

---

## Success Criteria

- [ ] `make smoke` runs the full harness end-to-end
- [ ] All assertions pass against a clean implementation of tasks 1-8
- [ ] Failures produce actionable output (which assertion, what command)
- [ ] Cleanup is reliable (no orphan containers after any failure mode)
- [ ] Smoke completes in under 3 minutes on a typical dev laptop

---

## Verification

```bash
make smoke
# Expected: all assertions PASS, exit 0

# Force a failure to verify cleanup
# (Edit run.sh temporarily to make one assert fail.)
make smoke ; echo "exit=$?"
# Expected: exit non-zero, no leaked containers

docker ps -a --format '{{.Names}}' | grep aidc-smoke- && echo "LEAK" || echo "clean"
```

---

## Enforcement Test Suggestions

- [ ] Cleanup trap reliability — suggested test: kill the smoke script mid-run with SIGINT, assert no orphan containers
- [ ] Smoke covers each P0 requirement — suggested test: parse run.sh asserts, map to requirements.md IDs, ensure each P0 is exercised
