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
# It also runs the git container's part (tests/smoke/git.sh): `aidc git setup`, a public repo
# added and removed again (AIDC_SMOKE_PUBLIC_REPO, default octocat/Hello-World: only fetched),
# the session's requests. With the git container logged in to GitHub and
# AIDC_SMOKE_GIT_REPO=<owner/name> naming a scratch repo you own, a real push, PR, merge and
# tidy there; with AIDC_SMOKE_GIT_CLAUDE=1, the git agent's question (git.sh says what each needs).
#
# aidc kill keeps the session's audit claim by design; the smoke then lists it and removes it
# with `aidc audit trim` (AIDC_SMOKE_KEEP_AUDIT=1 keeps it, and the end of the run names it).
# The repo folders it made on the user's disk are removed. The git container stays.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AIDC="$AIDC_ROOT/scripts/aidc"
[ -n "${AIDC_SMOKE_HOME:-}" ] && export HOME="$AIDC_SMOKE_HOME"
export AIDC_SCRIPTS="$AIDC_ROOT/scripts"
# shellcheck source=../../scripts/k8s/lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=../../scripts/k8s/manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
AIDC_VERSION_TAG=$(head -n1 "$AIDC_ROOT/VERSION" | tr -d '\r' | tr '+' '_')
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
# status_has <text>: aidc status for the session contains <text>. The output is captured first:
# under pipefail, `status | grep -q` fails when grep stops reading before status finishes.
status_has() { local out; out=$("$AIDC" status "$SESSION" </dev/null 2>&1); case "$out" in *"$1"*) return 0 ;; esac; return 1; }
proxy_pod() { k8s_kubectl -n "$NS" get pod -l "aidc/session=${SESSION},app=proxy" -o name | head -n1; }

# The git container's part (tests/smoke/git.sh).
# shellcheck disable=SC2034  # read by git.sh
SG_BACKEND=kubernetes
# shellcheck disable=SC2034  # read by git.sh
SG_SESSION="$SESSION"
PUBLIC_REPO="${AIDC_SMOKE_PUBLIC_REPO:-octocat/Hello-World}"
SG_WC="/home/${AIDC_K8S_USER}/aidc-smoke-k8s/${SESSION}-wc"
SG_GH_WC_PATH="/home/${AIDC_K8S_USER}/aidc-smoke-k8s/${SESSION}-gh"
# shellcheck disable=SC2329  # called by git.sh
sg_in() { k8s_kubectl -n "$NS" exec "$POD" -c dev -- sudo -E -H -u vscode bash -c "umask 002; $1" </dev/null; }
# shellcheck disable=SC2329  # called by git.sh
sg_git() { k8s_kubectl -n "$NS" exec deploy/git -c git -- "$@" </dev/null; }
# shellcheck disable=SC2329  # called by git.sh
sg_make_gh_wc() {
    "$AIDC" repo add "$AIDC_SMOKE_GIT_REPO" --path "$SG_GH_WC_PATH" --backend kubernetes </dev/null >&2 || return 1
    printf '%s' "$SG_GH_WC_PATH"
}
# shellcheck source=git.sh
. "$SCRIPT_DIR/git.sh"

cleanup() {
    sg_cleanup_github
    echo "[cleanup] killing ${SESSION}"
    "$AIDC" kill "$SESSION" </dev/null >/dev/null 2>&1 || true
    remove_repos
}
# The working copies the smoke added (and gitrun's copies of them), whatever they hold.
remove_repos() {
    local wc
    for wc in "$SG_WC" "$SG_GH_WC_PATH"; do
        "$AIDC" repo remove "$wc" --delete-working-copy --even-unpushed --backend kubernetes </dev/null >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT INT TERM

echo "[1/7] the cluster"
assert "aidc k8s check passes" "'$AIDC' k8s check </dev/null"

echo "[1b/7] the git container, and a public repo on the user's disk"
sg_part_setup
assert "aidc repo add ${PUBLIC_REPO} clones it onto the user's disk" \
    "'$AIDC' repo add '${PUBLIC_REPO}' --path '${SG_WC}' --backend kubernetes </dev/null"

echo "[2/7] create"
mkdir -p "$REPO"
assert "aidc create --backend kubernetes makes a ready session" \
    "(cd '$REPO' && '$AIDC' create '$SESSION' --backend kubernetes </dev/null)"
assert "aidc list shows it, on the kubernetes backend" \
    "'$AIDC' list </dev/null | grep -E '^${SESSION} .*kubernetes'"
assert "aidc status reports it clean" "status_has 'taint:    clean'"
assert "aidc status confirms the lockdown's policies are in place" "status_has 'egress:   enforced'"

echo "[3/7] egress: the session's only way out is its own Squid"
assert "https://example.com through squid" "in_dev 'curl -sf -m 20 -o /dev/null https://example.com'"
assert "a state-actor TLD is refused" "! in_dev 'curl -sf -m 20 -o /dev/null https://www.baidu.cn'"
assert "a direct connection, no proxy, is blocked" "! in_dev \"curl -sf -m 8 --noproxy '*' -o /dev/null https://1.1.1.1\""
assert "a DNS lookup is blocked" "! in_dev 'getent hosts github.com'"
assert "the Kubernetes API is blocked" "! in_dev \"curl -sk -m 8 --noproxy '*' -o /dev/null https://kubernetes.default.svc\""
# Squid refuses private destinations itself (AIDC_PUBLIC_ONLY): 403 from squid, before its
# NetworkPolicy would refuse the connection (503). A public name that resolves to loopback is
# refused the same way: squid checks the address it resolved.
for target in http://192.168.1.1/ http://10.0.0.1/ http://localtest.me/; do
    code=$(in_dev "curl -s -m 20 -o /dev/null -w '%{http_code}' ${target}" 2>/dev/null)
    assert "squid itself refuses ${target} (403, got ${code:-none})" "[ '$code' = 403 ]"
done
# Root in the Sysbox session owns its own network namespace only: rules it adds there change
# nothing, because NetworkPolicy lives in the node's namespace (docs/design-12, "Egress").
in_root() { k8s_kubectl -n "$NS" exec "$POD" -c dev -- sh -c "$1" </dev/null; }
assert "root in the session can change its own namespace's rules (it is root there)" \
    "in_root 'iptables -I OUTPUT 1 -j ACCEPT && iptables -P OUTPUT ACCEPT'"
assert "it sees none of the node's NetworkPolicy rules" "! in_root 'iptables-save; nft list ruleset 2>/dev/null' | grep -qiE 'kube-router|KUBE-NWPLCY|KUBE-POD-FW'"
assert "and a direct connection is still blocked after it opened its own rules" \
    "! in_root \"curl -sf -m 8 --noproxy '*' -o /dev/null https://1.1.1.1\""
in_root 'iptables -D OUTPUT -j ACCEPT' >/dev/null 2>&1 || true

echo "[4/7] Docker inside, unprivileged"
assert "the dev pod is not privileged and runs in a user namespace" \
    "k8s_kubectl -n '$NS' get pod '$POD' -o json | yq -p=json -e '.spec.hostUsers == false and ([.spec.containers[] | select(.securityContext.privileged == true)] | length == 0)'"
assert "Claude Code is installed in the session (it lives in the session home)" \
    "k8s_kubectl -n '$NS' exec '$POD' -c dev -- sudo -u vscode -i claude --version </dev/null"
assert "the session user owns its home" "in_dev 'test -O /home/vscode && touch /home/vscode/.aidc-smoke-write'"
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

echo "[4b/7] the git container: requests from the session"
sg_part_gitwc
sg_part_requests
sg_part_github sg_make_gh_wc
sg_part_claude

echo "[4c/7] restart, upgrade and refresh; the conversation resumes"
# A conversation in the session home, where Claude keeps the repo's (one message is enough for
# the aidc-claude wrapper to pass --continue), and a fact about the pods before.
DISK_DIR="/home/${AIDC_K8S_USER}${REPO#"$HOME"}"
PROJ=$(printf '%s' "$DISK_DIR" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g')
in_dev "mkdir -p /home/vscode/.claude/projects/${PROJ} && printf '%s\n' '{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"aidc smoke\"}}' > /home/vscode/.claude/projects/${PROJ}/aidc-smoke.jsonl" >/dev/null 2>&1 || true
PROXY_BEFORE=$(proxy_pod)
UID_BEFORE=$(k8s_kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null)
# resumed: Claude runs in the new pod with --continue (it is started a moment after "ready").
resumed() { for _ in $(seq 20); do in_dev "ps -eo args | grep -q -- '[c]laude.*--continue'" && return 0; sleep 3; done; return 1; }
assert "aidc restart gives the session a new dev pod" \
    "'$AIDC' restart '$SESSION' </dev/null && [ \"\$(k8s_kubectl -n '$NS' get pod '$POD' -o jsonpath='{.metadata.uid}')\" != '$UID_BEFORE' ]"
assert "its home is kept (a file written before is there)" "in_dev 'test -f /home/vscode/.aidc-smoke-write'"
assert "Claude resumes the conversation (--continue)" "resumed"
assert "the proxy pod was not touched" "[ \"\$(proxy_pod)\" = '$PROXY_BEFORE' ]"
UID_BEFORE=$(k8s_kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null)
assert "aidc upgrade --yes rolls it onto this version's image" \
    "'$AIDC' upgrade '$SESSION' --yes </dev/null && [ \"\$(k8s_kubectl -n '$NS' get pod '$POD' -o jsonpath='{.metadata.uid}')\" != '$UID_BEFORE' ]"
assert "the upgraded pod runs ${AIDC_VERSION_TAG}" \
    "k8s_kubectl -n '$NS' get pod '$POD' -o jsonpath='{.spec.containers[0].image}' | grep -q ':${AIDC_VERSION_TAG}\$'"
assert "Claude resumes the conversation after the upgrade too" "resumed"
if [ -n "$(bash -c ". '$AIDC_SCRIPTS/lib/config.sh'; . '$AIDC_SCRIPTS/lib/testament.sh'; aidc_testament_repo" 2>/dev/null)" ]; then
    assert "testament is in the session (testament.repo is configured)" "in_dev 'bash -lc \"testament --version\"'"
else
    echo "  note: testament.repo is not configured; the session has no testament (optional)"
fi
assert "aidc refresh re-pulls the malware feeds" "'$AIDC' refresh '$SESSION' </dev/null | grep -q '^refreshed:'"

echo "[5/7] the blocklist feeds"
for _ in $(seq 60); do
    k8s_kubectl -n "$NS" logs "$(proxy_pod)" -c refresher 2>/dev/null | grep -q '^refreshed:' && break
    sleep 5
done
line=$(k8s_kubectl -n "$NS" logs "$(proxy_pod)" -c refresher 2>/dev/null | grep '^refreshed:' | tail -n1)
assert "every malware feed contributed entries (urlhaus > 0, hagezi > 0): ${line:-no refresh yet}" \
    "printf '%s' '$line' | grep -Eq 'urlhaus=[1-9][0-9]* hagezi=[1-9][0-9]*'"
assert "aidc status shows the malware feeds, none lost (#60)" \
    "status_has 'feeds:    urlhaus ' && ! status_has 'LOST:'"

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
assert "aidc status shows the taint" "status_has 'taint:    TAINTED'"
# The audit sidecar copies the logs to its volume every 60 s (AIDC_AUDIT_INTERVAL).
for _ in $(seq 15); do
    k8s_kubectl -n "$NS" exec "$(proxy_pod)" -c audit -- grep -q tainted /var/aidc/audit/policy-events.log </dev/null 2>/dev/null && break
    sleep 5
done
assert "the audit volume holds the policy events" \
    "k8s_kubectl -n '$NS' exec '$(proxy_pod)' -c audit -- grep -q tainted /var/aidc/audit/policy-events.log </dev/null"

echo "[7/7] kill"
REL="${REPO#"$HOME"}"
DISK_REPO="/home/${AIDC_K8S_USER}${REL}"
in_dev "echo kept > '${DISK_REPO}/marker'" >/dev/null 2>&1 || true
# A shell-history line and a transcript file in the session home, where Claude Code keeps them,
# for the audit sidecar's final sweep to collect (SEC-07).
in_dev "echo aidc-smoke-history >> /home/vscode/.bash_history; mkdir -p /home/vscode/.claude/projects/aidc-smoke && echo '{\"smoke\":true}' > /home/vscode/.claude/projects/aidc-smoke/t.jsonl" >/dev/null 2>&1 || true
AUDIT=$(k8s_kubectl -n "$NS" get statefulset "${SESSION}-dev" -o jsonpath='{.metadata.annotations.aidc/audit}' 2>/dev/null)
assert "aidc kill removes the session" "'$AIDC' kill '$SESSION' </dev/null"
trap - EXIT INT TERM
sg_cleanup_github
remove_repos
assert "the smoke's working copies are removed from the user's disk" "! '$AIDC' repo list --backend kubernetes </dev/null | grep -q 'aidc-smoke-k8s/${SESSION}'"
assert "nothing of it is left but its audit claim" \
    "[ -z \"\$(k8s_kubectl -n '$NS' get statefulset,deployment,service,networkpolicy -l aidc/session=$SESSION -o name)\" ]"
assert "its audit claim is kept (${AUDIT:-none named})" "[ -n '$AUDIT' ] && k8s_kubectl -n '$NS' get pvc '$AUDIT'"
# A reader pod on the kept audit claim and the user's disk: what outlives the session.
READER="${SESSION}-reader"
k8s_kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: ${READER}, namespace: ${NS}, labels: {app.kubernetes.io/managed-by: aidc}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  nodeSelector: $(k8s_node_selector)
  tolerations: ${AIDC_K8S_TOLERATIONS}
  containers:
    - {name: r, image: "${AIDC_K8S_REGISTRY_PULL}/aidc/audit:${AIDC_VERSION_TAG}", command: [sleep, "300"],
       volumeMounts: [{name: audit, mountPath: /audit}, {name: disk, mountPath: /disk}]}
  volumes:
    - {name: audit, persistentVolumeClaim: {claimName: "${AUDIT}"}}
    - {name: disk, persistentVolumeClaim: {claimName: disk}}
YAML
k8s_kubectl -n "$NS" wait --for=condition=Ready "pod/${READER}" --timeout=180s >/dev/null 2>&1
rd() { k8s_kubectl -n "$NS" exec "$READER" -- sh -c "$1" </dev/null; }
assert "the audit trail has meta.json, stamped killed_at by the final sweep" "rd 'jq -e .killed_at /audit/meta.json'"
meta_names_it() { [ "$(rd "jq -r '.session + \" \" + .backend' /audit/meta.json")" = "${SESSION} kubernetes" ]; }
assert "meta.json names the session and its backend" "meta_names_it"
assert "the audit trail has the config snapshot" "rd 'test -s /audit/config-snapshot.yaml'"
assert "meta.json records when the session was tainted" "rd 'jq -e .tainted_at /audit/meta.json'"
assert "the audit trail has the session's shell history" "rd 'grep -q aidc-smoke-history /audit/dev-bash-history'"
assert "the audit trail has the session's Claude transcripts" "rd 'test -s /audit/claude-transcript/aidc-smoke/t.jsonl'"
assert "the audit trail has squid's access log" "rd 'test -s /audit/squid-access.log'"
assert "the user's disk outlives the session (a file written in it is still there)" \
    "rd 'grep -q kept /disk${REL}/marker'"
rd "rm -rf '/disk${REL}'" >/dev/null 2>&1 || true
k8s_kubectl -n "$NS" delete pod "$READER" --wait=true --timeout=120s >/dev/null 2>&1 || true
rmdir "$REPO" "$(dirname "$REPO")" 2>/dev/null || true

# aidc audit: the kept claim is listed with the size aidc kill recorded, and trim removes it with
# its volume, so smoke runs do not pile up claims (AIDC_SMOKE_KEEP_AUDIT=1 keeps it).
k8s_kubectl -n "$NS" wait --for=delete pod -l "aidc/session=${SESSION}" --timeout=180s >/dev/null 2>&1 || true
audit_row() { "$AIDC" audit list --backend kubernetes </dev/null | awk -v c="$AUDIT" '$1 == c'; }
assert "aidc audit list shows the kept claim, kept, with the size aidc kill recorded" \
    "audit_row | grep -Eq ' [0-9]+ (B|KB|MB) +kept +kubernetes\$'"
if [ "${AIDC_SMOKE_KEEP_AUDIT:-}" != 1 ] && [ -n "$AUDIT" ]; then
    AUDIT_PV=$(k8s_kubectl -n "$NS" get pvc "$AUDIT" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    assert "aidc audit trim removes the claim" "'$AIDC' audit trim '$AUDIT' --yes --backend kubernetes </dev/null"
    assert "and its volume, whatever the class's reclaim policy" \
        "[ -n '$AUDIT_PV' ] && ! k8s_kubectl get pv '$AUDIT_PV' >/dev/null 2>&1"
    AUDIT="(trimmed)"
fi

echo
echo "=== kubernetes smoke summary ==="
echo "passed:   $PASS"
echo "failed:   $FAIL"
echo "elapsed:  $(( $(date +%s) - START ))s"
echo "kept:     audit claim ${AUDIT:-?} in ${NS}"
[ "$FAIL" -eq 0 ]
