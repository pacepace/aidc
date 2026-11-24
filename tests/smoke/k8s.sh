#!/usr/bin/env bash
# Kubernetes smoke: one real session on the cluster of the `kubernetes:` config, end to end.
#
# The Kubernetes backend's sandbox, checked against a live cluster the way tests/smoke/run.sh
# checks the Docker one: the session's only way out is its own Squid, Docker runs inside it
# without privileged mode, the malware feeds are loaded, a blocklisted request taints the
# session, and `aidc kill` removes it. Needs a configured cluster on which `aidc k8s setup`,
# `aidc k8s build` and `aidc user add <you>` have run (README, "Kubernetes backend").
#
# Usage: bash tests/smoke/k8s.sh            (uses ~/.config/aidc/config.yaml)
#        AIDC_SMOKE_HOME=<dir> bash tests/smoke/k8s.sh   (a HOME holding another config)
#
# Leaves behind only the session's audit claim, which aidc keeps by design; the end of the run
# names it. The repo folder it made on the user's disk is removed.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AIDC="$AIDC_ROOT/scripts/aidc"
[ -n "${AIDC_SMOKE_HOME:-}" ] && export HOME="$AIDC_SMOKE_HOME"
export AIDC_SCRIPTS="$AIDC_ROOT/scripts"
# shellcheck source=../../scripts/k8s/lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
k8s_require || exit 1

SESSION="smoke-$(date +%s | tail -c 7)"
REPO="$HOME/aidc-smoke-k8s/$SESSION"
NS=$(k8s_user_ns "$AIDC_K8S_USER")
POD="${SESSION}-dev-0"
PASS=0
FAIL=0
START=$(date +%s)

assert() {
    local desc="$1"; shift
    if eval "$*" >/dev/null 2>&1; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"; FAIL=$((FAIL + 1))
    fi
}
# in_dev <command>: run as the session user, with the session's proxy environment.
in_dev() { k8s_kubectl -n "$NS" exec "$POD" -c dev -- sudo -E -u vscode bash -c "$1" </dev/null; }
proxy_pod() { k8s_kubectl -n "$NS" get pod -l "aidc/session=${SESSION},app=proxy" -o name | head -n1; }

cleanup() {
    echo "[cleanup] killing ${SESSION}"
    "$AIDC" kill "$SESSION" </dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "[1/7] the cluster"
assert "aidc k8s check passes" "'$AIDC' k8s check </dev/null"

echo "[2/7] create"
mkdir -p "$REPO"
assert "aidc create --backend kubernetes makes a ready session" \
    "(cd '$REPO' && '$AIDC' create '$SESSION' --backend kubernetes </dev/null)"
assert "aidc list shows it, on the kubernetes backend" \
    "'$AIDC' list </dev/null | grep -E '^${SESSION} .*kubernetes'"
assert "aidc status reports it clean" "'$AIDC' status '$SESSION' </dev/null | grep -q 'taint:    clean'"

echo "[3/7] egress: the session's only way out is its own Squid"
assert "https://example.com through squid" "in_dev 'curl -sf -m 20 -o /dev/null https://example.com'"
assert "a state-actor TLD is refused" "! in_dev 'curl -sf -m 20 -o /dev/null https://www.baidu.cn'"
assert "a direct connection, no proxy, is blocked" "! in_dev \"curl -sf -m 8 --noproxy '*' -o /dev/null https://1.1.1.1\""
assert "a DNS lookup is blocked" "! in_dev 'getent hosts github.com'"
assert "the Kubernetes API is blocked" "! in_dev \"curl -sk -m 8 --noproxy '*' -o /dev/null https://kubernetes.default.svc\""

echo "[4/7] Docker inside, unprivileged"
assert "the dev pod is not privileged and runs in a user namespace" \
    "k8s_kubectl -n '$NS' get pod '$POD' -o json | yq -p=json -e '.spec.hostUsers == false and ([.spec.containers[] | select(.securityContext.privileged == true)] | length == 0)'"
assert "docker run hello-world" "in_dev 'timeout 180 docker run --rm hello-world'"
mtu=$(in_dev "perl -e 'socket(my \$s,2,2,0); my \$r=pack(\"a16 x16\",\"eth0\"); ioctl(\$s,0x8921,\$r) and print unpack(\"x16 i\",\$r)'" 2>/dev/null)
if [ -n "$mtu" ] && [ "$mtu" -lt 1500 ] 2>/dev/null; then
    assert "the inner dockerd uses the pod network's MTU (${mtu})" "in_dev \"ps -o args= -C dockerd | grep -q -- '--mtu=${mtu}'\""
else
    echo "  note: pod MTU ${mtu:-unknown}; no --mtu expected"
fi
assert "an inner container downloads through the proxy" \
    "in_dev 'timeout 240 docker run --rm -e https_proxy=\$HTTPS_PROXY curlimages/curl:8.17.0 -sfL -m 200 -o /dev/null https://github.com/pyenv/pyenv/archive/refs/heads/master.tar.gz'"
assert "an inner container cannot get out directly" \
    "! in_dev 'timeout 60 docker run --rm curlimages/curl:8.17.0 -sf -m 15 -o /dev/null https://1.1.1.1'"

echo "[5/7] the blocklist feeds"
for _ in $(seq 60); do
    k8s_kubectl -n "$NS" logs "$(proxy_pod)" -c refresher 2>/dev/null | grep -q '^refreshed:' && break
    sleep 5
done
line=$(k8s_kubectl -n "$NS" logs "$(proxy_pod)" -c refresher 2>/dev/null | grep '^refreshed:' | tail -n1)
assert "every malware feed contributed entries (urlhaus > 0, hagezi > 0): ${line:-no refresh yet}" \
    "printf '%s' '$line' | grep -Eq 'urlhaus=[1-9][0-9]* hagezi=[1-9][0-9]*'"

echo "[6/7] taint"
# The refresher image has a shell but no perl; replace the file in one rename, as it does, and
# keep it sorted in byte order: squid's helper finds a domain by binary search, so an entry
# appended to the end of a sorted list is never found.
# shellcheck disable=SC2016  # expanded by the container's shell
k8s_kubectl -n "$NS" exec "$(proxy_pod)" -c refresher -- sh -c \
    'f=/etc/squid/blocklist.txt; { cat "$f"; echo example.org; } | LC_ALL=C sort -u > "$f.new" && mv "$f.new" "$f"' </dev/null
code=$(in_dev 'curl -s -m 20 -o /dev/null -w "%{http_code}" http://example.org/' 2>/dev/null)
assert "a blocklisted domain is refused by squid (403, got ${code:-none})" "[ '$code' = 403 ]"
sleep 8
assert "the policy sidecar writes the taint flag" \
    "k8s_kubectl -n '$NS' exec '$(proxy_pod)' -c policy -- cat /var/state/tainted </dev/null | grep -q malware_domains"
assert "aidc status shows the taint" "'$AIDC' status '$SESSION' </dev/null | grep -q 'taint:    TAINTED'"
# The audit sidecar copies the logs to its volume every 60 s (AIDC_AUDIT_INTERVAL).
for _ in $(seq 15); do
    k8s_kubectl -n "$NS" exec "$(proxy_pod)" -c audit -- grep -q tainted /var/aidc/audit/policy-events.log </dev/null 2>/dev/null && break
    sleep 5
done
assert "the audit volume holds the policy events" \
    "k8s_kubectl -n '$NS' exec '$(proxy_pod)' -c audit -- grep -q tainted /var/aidc/audit/policy-events.log </dev/null"

echo "[7/7] kill"
in_dev "rm -rf '/home/${AIDC_K8S_USER}${REPO#"$HOME"}'" >/dev/null 2>&1 || true
assert "aidc kill removes the session" "'$AIDC' kill '$SESSION' </dev/null"
trap - EXIT INT TERM
assert "nothing of it is left but its audit claim" \
    "[ -z \"\$(k8s_kubectl -n '$NS' get statefulset,deployment,service,networkpolicy -l aidc/session=$SESSION -o name)\" ]"
assert "its audit claim is kept" "k8s_kubectl -n '$NS' get pvc '${SESSION}-audit'"
rmdir "$REPO" "$(dirname "$REPO")" 2>/dev/null || true

echo
echo "=== kubernetes smoke summary ==="
echo "passed:   $PASS"
echo "failed:   $FAIL"
echo "elapsed:  $(( $(date +%s) - START ))s"
echo "kept:     audit claim ${SESSION}-audit in ${NS}"
[ "$FAIL" -eq 0 ]
