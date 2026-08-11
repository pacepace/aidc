#!/usr/bin/env bash
# aidc smoke test -- verifies isolation guarantees end-to-end.
# Spins up a real session, makes assertions, tears down.
#
# Scope: this exercises the sandbox (proxy, taint, audit, isolation). It does
# NOT install or invoke Claude Code -- that's out of scope for the smoke.
#
# Hygiene: everything (repo mount + audit dir) lives under tests/scratch/
# INSIDE the repo (gitignored). No /tmp, no mktemp, no ~/aidc-audit, so we
# never pollute the user's home or trigger macOS TCC prompts.
#
# Anti-leak: the cleanup trap runs on every exit path. The session name is
# timestamped so reruns can't collide with a user's real session.
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
CREATE_OUT="$SCRATCH/create.out"
AUDIT_DIR=""
PASS=0
FAIL=0
START_TS=$(date +%s)

mkdir -p "$TMP_REPO" "$AUDIT_DIR_OVERRIDE" "$TMP_REPO/.aidc"
# Tell aidc create where to put audit data -- overrides the global config's
# audit_dir. The smoke writes a per-project config so the override is picked
# up via normal config merge (per-project beats global beats defaults).
cat > "$TMP_REPO/.aidc/config.yaml" <<EOF
audit_dir: ${AUDIT_DIR_OVERRIDE}
EOF

cleanup() {
    local rc=$?
    if [ "${AIDC_SMOKE_PRESERVE:-0}" = "1" ] && [ "$rc" -ne 0 ]; then
        echo
        echo "AIDC_SMOKE_PRESERVE=1 set -- leaving session '$SESSION' up for inspection."
        echo "  Tear down manually: $AIDC kill $SESSION"
        echo "  Scratch dir:        $SCRATCH"
        echo "  Audit dir:          $AUDIT_DIR"
        return
    fi
    echo
    echo "[cleanup] tearing down session $SESSION"
    "$AIDC" kill "$SESSION" >/dev/null 2>&1 || true
    # git commit inside the dev container (uid 1000) leaves .git objects owned by
    # 1000; a host runner at a different uid (CI: 1001) can't rm them. Fall back to
    # a throwaway root container to clear the tree. `|| true` so a cleanup hiccup
    # never flips the script's real exit code.
    rm -rf "$SCRATCH" 2>/dev/null \
        || docker run --rm -v "$AIDC_ROOT/tests/scratch:/scratch" alpine \
             rm -rf "/scratch/$SESSION" 2>/dev/null \
        || true
}
trap cleanup EXIT INT TERM

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
    # -u vscode: container's entrypoint drops to vscode for user-facing work;
    # smoke assertions need to run as the same user.
    docker exec -u vscode "aidc-${SESSION}-dev" bash -c "$1"
}

echo "=== aidc smoke test ==="
echo "session: $SESSION"
echo "repo:    $TMP_REPO"
echo "audit:   $AUDIT_DIR_OVERRIDE"
echo

# --- prereqs --------------------------------------------------------------
for cmd in docker jq curl git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command '$cmd' not on PATH" >&2
        exit 2
    fi
done
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon unreachable" >&2; exit 2; }

# --- seed repo ------------------------------------------------------------
(
    cd "$TMP_REPO"
    git init -q
    touch README.md
    git add .
    git -c user.email=test@example.com -c user.name=Test commit -q -m "init"
)

# The dev container runs as vscode (uid 1000). The user seeding this repo may be
# a different uid (CI runners are 1001), so its .git is not writable by 1000 and
# the in-container `git commit` asymmetry assertion fails with EACCES. Make the
# repo world-writable so the assertions work regardless of the host uid. On
# uid-mapped hosts (Docker Desktop) this is a harmless no-op.
chmod -R a+rwX "$TMP_REPO"

# --- step 1: create session ----------------------------------------------
echo "[1/10] aidc create"
"$AIDC" create "$SESSION" --repo "$TMP_REPO" --profile multi 2>&1 | tee "$CREATE_OUT"
# Extract audit dir from the 'audit:   <path>' line in create output.
AUDIT_DIR=$(grep -E '^[[:space:]]*audit:' "$CREATE_OUT" | head -n1 | awk '{print $2}')
if [ -z "$AUDIT_DIR" ] || [ ! -d "$AUDIT_DIR" ]; then
    echo "ERROR: could not extract audit dir from create output" >&2
    exit 2
fi
# Sanity: the audit dir must live under our scratch override, otherwise the
# per-project config override didn't take and we'd be polluting ~/aidc-audit.
case "$AUDIT_DIR" in
    "$AUDIT_DIR_OVERRIDE"/*) : ;;
    *)
        echo "ERROR: audit dir '$AUDIT_DIR' is not under override '$AUDIT_DIR_OVERRIDE'" >&2
        echo "       per-project config.yaml audit_dir override did not apply" >&2
        exit 2
        ;;
esac
echo "audit:   $AUDIT_DIR"
echo

# --- step 2: isolation ----------------------------------------------------
echo "[2/10] isolation assertions"
assert "no docker.sock from host in dev container" \
    "! dev_exec 'test -S /var/run/docker.sock.host'"
assert "gh CLI not installed" \
    "! dev_exec 'command -v gh'"
assert "no SSH agent socket" \
    "dev_exec 'test -z \"\$SSH_AUTH_SOCK\"'"
assert "no ~/.ssh dir" \
    "! dev_exec 'test -d ~/.ssh'"
assert "no GITHUB_TOKEN env" \
    "dev_exec 'test -z \"\$GITHUB_TOKEN\"'"
echo

# --- step 3: git asymmetry -----------------------------------------------
echo "[3/10] git asymmetry"
assert "git status works locally" \
    "dev_exec 'cd $TMP_REPO && git status'"
assert "git commit works locally" \
    "dev_exec 'cd $TMP_REPO && touch f.txt && git add f.txt && git -c user.email=c@example.com -c user.name=C commit -m smoke'"
assert "git push fails (no credentials + pre-push hook)" \
    "! dev_exec 'cd $TMP_REPO && git remote add o https://github.com/aidc-smoke/none.git && git push o main'"
assert "system pre-push hook is installed" \
    "dev_exec 'git config --system --get core.hooksPath' | grep -q '/etc/git-hooks'"
echo

# --- step 4: DinD ---------------------------------------------------------
echo "[4/10] DinD"
assert "inner docker daemon works" \
    "dev_exec 'docker version'"
assert "inner docker ps does NOT show host containers" \
    "! dev_exec 'docker ps --format \"{{.Names}}\" | grep -q aidc-${SESSION}-squid'"
echo

# --- step 5: port forwarding (CLI-13/14/15) ------------------------------
# Tests adhoc `aidc proxy add/rm/ls/clear` against a tiny http.server
# running inside the dev container. Pick an obscure host port so we don't
# collide with whatever the dev might be running. Declared-port behavior
# (`aidc create --port`) is exercised by the manual test plan in
# docs/tasks/task-11-port-forwarding.md -- adding a declared port to the
# smoke create would conflict with parallel runs.
echo "[5/10] port forwarding"
PF_PORT=$((28000 + RANDOM % 1000))
dev_exec "nohup python3 -m http.server ${PF_PORT} >/tmp/pfhttp.log 2>&1 &" >/dev/null 2>&1 || true
# Give the in-container server a beat to bind.
sleep 1
assert "aidc proxy add starts a forward" \
    "$AIDC proxy ${SESSION} add ${PF_PORT}"
# Curl from the HOST through the published port. Retry briefly because
# Docker's port-publish setup can take a moment after the docker run -p.
PF_CODE="?"
for _ in $(seq 1 10); do
    PF_CODE=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "http://localhost:${PF_PORT}/" 2>/dev/null || true)
    if [ "$PF_CODE" = "200" ]; then break; fi
    sleep 0.5
done
assert "host -> container HTTP through aidc proxy works" \
    "[ '${PF_CODE}' = '200' ]"
assert "aidc proxy ls shows the forward" \
    "$AIDC proxy ${SESSION} ls | grep -q ${PF_PORT}"
assert "aidc status shows the adhoc forward" \
    "$AIDC status ${SESSION} | grep -q 'localhost:${PF_PORT}'"
assert "aidc proxy rm removes the forward" \
    "$AIDC proxy ${SESSION} rm ${PF_PORT}"
assert "no forwarder containers remain after rm" \
    "! docker ps -a --format '{{.Names}}' | grep -q 'aidc-${SESSION}-fwd-${PF_PORT}\$'"
assert "aidc proxy clear with no forwards is idempotent" \
    "$AIDC proxy ${SESSION} clear"
# Tidy: stop the in-container http.server so we don't leak it into later tests.
dev_exec "pkill -f 'http.server ${PF_PORT}'" >/dev/null 2>&1 || true
echo

# --- step 6: proxy enforcement -------------------------------------------
echo "[6/10] proxy enforcement"
# Use explicit -x so curl ALWAYS routes through squid regardless of how it
# resolves *_PROXY env (curl as root ignores HTTP_PROXY; some libcurl builds
# only honor lowercase). Without this, assertions can pass for the wrong
# reason -- e.g. DNS failure -- and we never exercise squid at all.
PROXY="http://aidc-proxy:3128"
assert "egress to example.com via proxy returns 200" \
    "dev_exec 'curl -fsS --max-time 15 -x ${PROXY} -o /dev/null -w \"%{http_code}\" http://example.com' | grep -q 200"
assert "egress to a TLD-blocked .cn domain returns 403 from squid" \
    "dev_exec 'curl -sS --max-time 15 -x ${PROXY} -o /dev/null -w \"%{http_code}\" http://anything.cn' | grep -q 403"

# Inject a known-bad domain into the blocklist and hot-reload Squid.
# Use a resolvable hostname so squid actually logs a TCP_DENIED (the policy
# sidecar tails that log and won't see entries for DNS failures). example.org
# is RFC 2606 reserved and a stable, resolvable choice.
MALWARE_DOMAIN="example.org"
# The policy sidecar greps the on-disk blocklist file directly on each
# TCP_DENIED -- no in-memory cache, no reload to wait for. The reload below is
# the only thing that has to land before the curl below will be denied.
#
# Both commands are written against the squid 7.x Rock, which is chiselled and
# unprivileged. Do NOT "simplify" either back to the old form:
#   - `bash -c` does not exist in that image (no bash) -- use /bin/sh. Getting
#     this wrong exits 127, and because the failure lands between step 6's last
#     assert and step 7's banner it reads as a cleanup fault rather than a real
#     regression. That cost a full 18-minute CI cycle to diagnose once already.
#   - /etc/squid is root-owned while squid runs as UID 584792, so the append
#     needs --user root.
#   - the binary is `squid-gnutls`, not `squid`. Rather than depend on that name,
#     reload by signalling PID 1 from the host, which is exactly what the
#     refresher sidecar does in production (`kill -HUP 1`) and needs nothing
#     inside the container at all.
docker exec --user root "aidc-${SESSION}-squid" /bin/sh -c \
    "echo '${MALWARE_DOMAIN}' >> /etc/squid/blocklist.txt"
docker kill --signal=HUP "aidc-${SESSION}-squid" >/dev/null 2>&1
# Retry the curl up to 30s. squid -k reconfigure on a ~1.3M-entry ACL
# can briefly drop the listener while it ingests; we'd see "connection
# refused" until it's stable. Once squid is back, the assertion passes.
MALWARE_CODE="?"
for _ in $(seq 1 30); do
    MALWARE_CODE=$(dev_exec "curl -sS --max-time 5 -x ${PROXY} -o /dev/null -w '%{http_code}' http://${MALWARE_DOMAIN}" 2>/dev/null || true)
    if [ "$MALWARE_CODE" = "403" ]; then
        break
    fi
    sleep 1
done
assert "egress to malware-listed ${MALWARE_DOMAIN} returns 403 from squid" \
    "[ '$MALWARE_CODE' = '403' ]"
echo

# --- step 6: taint detection ---------------------------------------------
echo "[7/10] taint detection"
# Policy sidecar tails squid access.log; once the malware curl above is
# logged as TCP_DENIED, it writes /var/state/tainted. Poll for up to 15s.
TAINT_OK=0
for _ in $(seq 1 30); do
    if docker exec "aidc-${SESSION}-policy" test -f /var/state/tainted 2>/dev/null; then
        TAINT_OK=1; break
    fi
    sleep 0.5
done
[ "$TAINT_OK" = "1" ] || echo "  (taint flag did not appear within 15s -- assertions below will fail)"
assert "policy sidecar wrote tainted flag" \
    "docker exec aidc-${SESSION}-policy test -f /var/state/tainted"
# Note: jq is NOT installed in the policy container's Alpine image. Pipe the
# content out to the host jq to validate.
assert "tainted flag is valid JSON" \
    "docker exec aidc-${SESSION}-policy cat /var/state/tainted | jq -e ."

# In FREEZE response mode (the smoke default), policy.sh writes the tainted
# flag FIRST, then issues `docker pause aidc-<session>-dev`. The pause is
# in-flight at the moment the flag appears. If we proceed to step 8 (which
# does `docker ps`) while pause is still updating the daemon's container
# index, docker ps can transiently return empty rows -- causing aidc list
# to report "No active aidc sessions" even though sessions exist.
#
# Wait for the dev container to actually reach Paused state. Once docker
# reports it Paused, the daemon has settled and subsequent docker ps calls
# are consistent.
PAUSE_OK=0
for _ in $(seq 1 30); do
    dev_state=$(docker inspect "aidc-${SESSION}-dev" --format '{{.State.Status}}' 2>/dev/null || true)
    if [ "$dev_state" = "paused" ]; then
        PAUSE_OK=1; break
    fi
    sleep 0.2
done
[ "$PAUSE_OK" = "1" ] || echo "  (dev container did not reach paused state within 6s -- list assertion may race)"
echo

# --- step 7: status surfaces taint ---------------------------------------
echo "[8/10] aidc status surfaces taint"
# cmd-status.sh prints 'TAINTED.' on tainted sessions; cmd-list (used by
# `aidc list`) prints 'YES' in the tainted column. Check both surfaces.
# Capture output first so the assertion only depends on string content,
# never on the (sometimes flaky) exit code of `aidc status` under pipefail.
STATUS_OUT=$("$AIDC" status "$SESSION" 2>&1 || true)
LIST_OUT=$("$AIDC" list 2>&1 || true)
assert "aidc status <session> reports TAINTED" \
    "printf '%s' \"\$STATUS_OUT\" | grep -qi 'TAINTED'"
assert "aidc list shows YES in tainted column for $SESSION" \
    "printf '%s' \"\$LIST_OUT\" | grep -E \"^${SESSION}\" | grep -q 'YES'"
echo

# --- step 8: kill tears everything down ----------------------------------
# We kill BEFORE the audit-content assertions because the audit aggregator's
# default sweep interval is 60s -- we'd otherwise need to wait a full cycle
# for taint-time logs to land. SIGTERM triggers a final sweep + finalize,
# which is what produces the complete on-disk snapshot in practice.
echo "[9/10] aidc kill"
"$AIDC" kill "$SESSION" >/dev/null 2>&1
assert "dev container removed" \
    "! docker ps -a --format '{{.Names}}' | grep -q \"aidc-${SESSION}-dev\""
assert "squid container removed" \
    "! docker ps -a --format '{{.Names}}' | grep -q \"aidc-${SESSION}-squid\""
assert "policy container removed" \
    "! docker ps -a --format '{{.Names}}' | grep -q \"aidc-${SESSION}-policy\""
echo

# --- step 9: audit dir populated after kill ------------------------------
echo "[10/10] audit"
assert "audit dir exists on host" \
    "test -d \"$AUDIT_DIR\""
assert "audit dir is under in-repo scratch (no host pollution)" \
    "case \"$AUDIT_DIR\" in \"$AUDIT_DIR_OVERRIDE\"/*) true ;; *) false ;; esac"
assert "audit dir has squid-access.log" \
    "test -s \"$AUDIT_DIR/squid-access.log\""
assert "audit dir has meta.json" \
    "test -f \"$AUDIT_DIR/meta.json\""
assert "meta.json is valid JSON" \
    "jq -e . \"$AUDIT_DIR/meta.json\""
assert "audit dir has config-snapshot.yaml" \
    "test -s \"$AUDIT_DIR/config-snapshot.yaml\""
assert "audit dir has policy-events.log" \
    "test -s \"$AUDIT_DIR/policy-events.log\""
assert "policy-events.log records a taint event" \
    "grep -q '\"outcome\":\"tainted\"' \"$AUDIT_DIR/policy-events.log\""
echo

# --- summary --------------------------------------------------------------
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
echo "=== smoke summary ==="
echo "passed:   $PASS"
echo "failed:   $FAIL"
echo "elapsed:  ${ELAPSED}s"
exit $((FAIL == 0 ? 0 : 1))
