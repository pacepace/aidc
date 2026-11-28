#!/usr/bin/env bash
# Unit tests for `aidc audit list|trim` (scripts/cmd-audit.sh, scripts/lib/audit.sh,
# scripts/k8s/audit.sh) and the kept-audit size warning every command gives (K8S-26).
#
# Audit is evidence: a trim that removed a running session's trail, removed more than it
# listed, or removed anything without being asked would destroy it. docker and kubectl are PATH
# stubs; HOME holds the config. The Kubernetes half needs yq (the backend reads its settings
# with it) and skips without it.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/audit-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/aidc"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
assert_has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (no '$2' in: $(printf '%s' "$3" | tail -8))" ;; esac; }
assert_not_has() { case "$3" in *"$2"*) fail "$1 ('$2' in: $(printf '%s' "$3" | tail -8))" ;; *) pass "$1" ;; esac; }

# docker stub: one aidc container, which mounts the trail named in $D_MOUNT; D_DOWN=1 is a
# daemon that does not answer.
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$D_LOG"
[ "${D_DOWN:-}" = 1 ] && { echo 'Cannot connect to the Docker daemon' >&2; exit 1; }
case "$*" in
    "ps -aq --filter name=^aidc-") echo abc123 ;;
    "inspect --format"*) printf '/elsewhere/state\n%s/%s\n' "$AUDIT" "${D_MOUNT:-none}" ;;
    "run "*) exit 1 ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/docker"
# kubectl answers nothing until the Kubernetes half writes its own stub.
printf '#!/bin/sh\necho "kubectl stub: no cluster here" >&2\nexit 1\n' > "$SCRATCH/bin/kubectl"; chmod +x "$SCRATCH/bin/kubectl"

export HOME="$SCRATCH/home" AIDC_SCRIPTS="$AIDC_ROOT/scripts" PATH="$SCRATCH/bin:$PATH" \
    D_LOG="$SCRATCH/docker.log" K_LOG="$SCRATCH/kubectl.log" XDG_CACHE_HOME="$SCRATCH/cache"
export AUDIT="$SCRATCH/trails"
[ "$(command -v docker)" = "$SCRATCH/bin/docker" ] && [ "$(command -v kubectl)" = "$SCRATCH/bin/kubectl" ] \
    || { echo "FAIL: docker or kubectl is not the stub ($(command -v docker), $(command -v kubectl)); refusing to run"; exit 1; }
unset AIDC_MCP_MOUNTS AIDC_MCP_STATE_HOST AIDC_HOST_HOME AIDC_AUDIT_WARN_BYTES XDG_CACHE_HOME_UNUSED
printf 'audit_dir: %s   # the trails\n' "$AUDIT" > "$HOME/.config/aidc/config.yaml"

# trail <id> <session> <created> [<extra json>] [<bytes>]
trail() {
    mkdir -p "$AUDIT/$1"
    printf '{"session":"%s","created_at":"%s"%s}' "$2" "$3" "${4:-}" > "$AUDIT/$1/meta.json"
    head -c "${5:-100}" /dev/zero > "$AUDIT/$1/squid-access.log"
}
fresh_trails() {
    rm -rf "$AUDIT"
    trail old-20260101T000000Z old 2026-01-01T00:00:00Z ',"killed_at":"2026-01-02T00:00:00Z"' 300000
    trail old-20260201T000000Z old 2026-02-01T00:00:00Z ',"killed_at":"2026-02-02T00:00:00Z","tainted_at":"2026-02-01T05:00:00Z"'
    trail live-20260101T000000Z live 2026-01-01T00:00:00Z
    trail gone-20260301T000000Z gone 2026-03-01T00:00:00Z
    trail new-20991231T000000Z new 2099-12-31T00:00:00Z ',"killed_at":"2099-12-31T01:00:00Z"'
}
run() { : > "$D_LOG"; : > "$K_LOG"; "$AIDC_ROOT/scripts/aidc" "$@" 2>&1; echo "exit=$?"; }
export D_MOUNT=live-20260101T000000Z

echo "=== lib/audit.sh: ages and sizes ==="
# shellcheck source=../../scripts/lib/audit.sh
. "$AIDC_ROOT/scripts/lib/audit.sh"
assert_eq "a bare number is days" 172800 "$(aidc_audit_parse_age 2)"
assert_eq "30d" 2592000 "$(aidc_audit_parse_age 30d)"
assert_eq "12h" 43200 "$(aidc_audit_parse_age 12h)"
assert_eq "2w" 1209600 "$(aidc_audit_parse_age 2w)"
for bad in "" d 3x -1d 1.5d 30dd; do
    aidc_audit_parse_age "$bad" >/dev/null && fail "'$bad' is not an age" || pass "'$bad' is not an age"
done
assert_eq "the audit dir comes from the global config, comment and all" "$AUDIT" "$(aidc_audit_host_dir)"
assert_eq "an epoch from ISO-8601" 86400 "$(aidc_audit_epoch 1970-01-02T00:00:00Z)"
assert_eq "sizes read in MB" "395 MB" "$(aidc_audit_human $((395 * 1048576)))"
assert_eq "unknown size" "?" "$(aidc_audit_human '?')"

echo "=== aidc audit list (Docker) ==="
fresh_trails
out=$(run audit list)
assert_has "exit 0" "exit=0" "$out"
assert_has "a killed trail is kept, with its creation and kill" \
    "old-20260101T000000Z               old              2026-01-01 00:00     2026-01-02 00:00     no" "$out"
assert_has "a trail a container mounts is running" "live-20260101T000000Z" "$out"
assert_eq "and says so" "running" "$(printf '%s\n' "$out" | awk '$1 == "live-20260101T000000Z" { print $(NF-1) }')"
assert_eq "a trail never closed whose session is gone has ended" "ended" \
    "$(printf '%s\n' "$out" | awk '$1 == "gone-20260301T000000Z" { print $(NF-1) }')"
assert_eq "a taint recorded in meta.json shows" "yes" \
    "$(printf '%s\n' "$out" | awk '$1 == "old-20260201T000000Z" { print $7 }')"
assert_has "each trail's size" "300 KB" "$out"
assert_has "a total per backend" "docker: 5 trails" "$out"
assert_not_has "no cluster is asked when none is configured" "get" "$(cat "$K_LOG")"
out=$(D_DOWN=1 run audit list)
assert_eq "Docker down: an unclosed trail is unknown, never ended" "unknown" \
    "$(printf '%s\n' "$out" | awk '$1 == "live-20260101T000000Z" { print $(NF-1) }')"
assert_eq "Docker down: a killed trail is still kept" "kept" \
    "$(printf '%s\n' "$out" | awk '$1 == "old-20260101T000000Z" { print $(NF-1) }')"
out=$(HOME="$SCRATCH/nohome" run audit list)
assert_has "no audit dir: nothing kept" "No kept audit trails." "$out"
out=$(run audit list extra)
assert_has "list takes no arguments" "takes no arguments" "$out"

echo "=== aidc audit trim (Docker) ==="
out=$(run audit trim --yes)
assert_has "trim with neither an age nor a name refuses" "say which trails" "$out"
assert_has "and fails" "exit=1" "$out"
assert_eq "and removes nothing" 5 "$(ls "$AUDIT" | wc -l | tr -d ' ')"
out=$(run audit trim --older-than 3x --yes)
assert_has "a bad age is refused" "an age is a number of days" "$out"
out=$(run audit trim old nosuch --yes)
assert_has "a name that matches nothing is refused" "no audit trail or session named 'nosuch'" "$out"
assert_eq "and nothing is removed, not even the names that matched" 5 "$(ls "$AUDIT" | wc -l | tr -d ' ')"

out=$(run audit trim --older-than 30d --dry-run)
assert_has "the dry run lists the old trails" "old-20260101T000000Z" "$out"
assert_has "all of them" "gone-20260301T000000Z" "$out"
assert_has "with what goes" "To remove: 3 trails" "$out"
assert_has "the running session's trail is kept, and said" "live-20260101T000000Z (docker, running)" "$out"
assert_not_has "a young trail is not listed" "new-20991231T000000Z" "$out"
assert_has "the dry run says it" "Dry run: nothing removed." "$out"
assert_eq "and removes nothing" 5 "$(ls "$AUDIT" | wc -l | tr -d ' ')"

out=$(run audit trim --older-than 30d </dev/null)
assert_has "without --yes and no answer, nothing is removed" "Nothing removed (no answer: use --yes" "$out"
assert_has "and it fails" "exit=1" "$out"
assert_eq "and the trails stay" 5 "$(ls "$AUDIT" | wc -l | tr -d ' ')"
out=$(echo n | run audit trim --older-than 30d)
assert_has "an answer of n removes nothing" "Nothing removed." "$out"
assert_eq "the trails stay" 5 "$(ls "$AUDIT" | wc -l | tr -d ' ')"

out=$(echo y | run audit trim old)
assert_has "a session name takes all its trails" "To remove: 2 trails" "$out"
assert_has "it asks first" "Remove them? This cannot be undone. [y/N]" "$out"
assert_eq "an answer of y removes them" "gone-20260301T000000Z live-20260101T000000Z new-20991231T000000Z" \
    "$(ls "$AUDIT" | paste -sd' ' -)"
assert_has "and says where each went" "removed ${AUDIT}/old-20260101T000000Z" "$out"

fresh_trails
out=$(run audit trim old-20260201T000000Z --yes)
assert_eq "a trail's own name takes only that trail" "no" "$([ -d "$AUDIT/old-20260201T000000Z" ] && echo yes || echo no)"
assert_eq "not the session's other trail" "yes" "$([ -d "$AUDIT/old-20260101T000000Z" ] && echo yes || echo no)"
out=$(run audit trim --older-than 30d old --yes)
assert_has "an age and a name: a trail must match both" "To remove: 1 trail " "$out"

fresh_trails
out=$(run audit trim live --yes)
assert_has "a running session's trail is refused by name" "live-20260101T000000Z (docker, running)" "$out"
assert_has "and the request fails" "exit=1" "$out"
assert_eq "and the trail stays" "yes" "$([ -d "$AUDIT/live-20260101T000000Z" ] && echo yes || echo no)"
out=$(D_DOWN=1 run audit trim gone live old-20260101T000000Z --yes)
assert_eq "Docker down: an unclosed trail is not removed" "yes yes" \
    "$([ -d "$AUDIT/gone-20260301T000000Z" ] && echo yes) $([ -d "$AUDIT/live-20260101T000000Z" ] && echo yes)"
assert_eq "Docker down: a killed trail can go" "no" "$([ -d "$AUDIT/old-20260101T000000Z" ] && echo yes || echo no)"

# A session made between the list and the removal: the trail is checked again just before.
fresh_trails
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$D_LOG"
case "$*" in
    "ps -aq --filter name=^aidc-") echo abc123 ;;
    "inspect --format"*) n=$(grep -c '^inspect' "$D_LOG")
        [ "$n" -ge 2 ] && printf '%s/gone-20260301T000000Z\n' "$AUDIT" ;;
esac
exit 0
STUB
out=$(run audit trim gone --yes)
assert_has "a trail mounted since the list is not removed" "now mounted by a session; not removed" "$out"
assert_eq "and stays" "yes" "$([ -d "$AUDIT/gone-20260301T000000Z" ] && echo yes || echo no)"

# Files the audit sidecar wrote as root: rm fails, the throwaway container is the fallback.
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$D_LOG"
case "$*" in "run "*) exit 1 ;; esac
exit 0
STUB
cat > "$SCRATCH/bin/rm" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$SCRATCH/bin/rm"
out=$(run audit trim gone --yes)
rm -f "$SCRATCH/bin/rm"
assert_has "an rm that fails falls back to a container of aidc's audit image" \
    "run --rm --network none --entrypoint rm -v ${AUDIT}:/trails aidc/audit:" "$(cat "$D_LOG")"
assert_has "a trail that will not go is said, with what to do" "could not remove" "$out"
assert_has "and fails" "exit=1" "$out"

echo "=== the size warning (Docker) ==="
out=$(AIDC_AUDIT_WARN_BYTES=1000000 run audit-nosuch 2>&1)
assert_not_has "under the threshold: no warning" "kept audit trails take" "$out"
out=$(AIDC_AUDIT_WARN_BYTES=1000 run nosuchverb)
assert_has "over the threshold: every command warns, naming the size and the trim command" \
    "kept audit trails take" "$out"
assert_has "names where" "in ${AUDIT}" "$out"
assert_has "names the trim command" "aidc audit trim --older-than 30d" "$out"
out=$(run nosuchverb)
assert_not_has "the default threshold is 100 MB" "kept audit trails take" "$out"
assert_eq "100 MB" $((100 * 1024 * 1024)) "$(aidc_audit_warn_bytes)"
out=$(AIDC_AUDIT_WARN_BYTES=1000 run audit list)
assert_not_has "aidc audit itself shows sizes instead" "warning: kept audit trails" "$out"
out=$(AIDC_AUDIT_WARN_BYTES=1000 HOME="$SCRATCH/nohome" run nosuchverb)
assert_not_has "no audit dir: no warning" "kept audit trails take" "$out"

if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: the Kubernetes half needs yq and jq"
    echo
    echo "passed: $PASS  failed: $FAIL"
    [ "$FAIL" -eq 0 ]
    exit
fi

# kubectl stub. The namespace aidc-u-alice holds four kept claims:
#   demo-audit-20260101000000   killed, measured (2 MB), volume pv-demo (Retain)
#   run-audit-20260101000000    named by a running session's StatefulSet
#   mnt-audit-20260101000000    mounted by a pod
#   old-audit-20260101000000    killed before sizes were recorded, volume pv-old
# and the cluster a released volume pv-orphan, whose claim orph-audit-20260101000000 is gone.
#   K_DOWN=1      the cluster does not answer
#   K_NO_PV=1     volumes cannot be read
#   K_STUCK=1     the provisioner never deletes a volume
cat > "$SCRATCH/bin/kubectl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
[ "${K_DOWN:-}" = 1 ] && { echo 'Unable to connect to the server' >&2; exit 1; }
claim() { # name created annotations volume
    printf '{"metadata":{"name":"%s","labels":{"aidc/session":"%s","aidc/kept":"audit"},"creationTimestamp":"%s","annotations":%s},"spec":{"volumeName":"%s"}}' \
        "$1" "${1%-audit-*}" "$2" "$3" "$4"
}
pv() { # name policy phase claim
    printf '{"metadata":{"name":"%s","creationTimestamp":"2026-01-01T00:00:00Z"},"spec":{"persistentVolumeReclaimPolicy":"%s","claimRef":{"namespace":"aidc-u-alice","name":"%s"},"csi":{"driver":"disk.example"}},"status":{"phase":"%s"}}' \
        "$1" "$2" "$4" "$3"
}
case "$*" in
    *"get pvc -l aidc/kept=audit -o json"*)
        printf '{"items":[%s,%s,%s,%s]}' \
            "$(claim demo-audit-20260101000000 2026-01-01T00:00:00Z '{"aidc/killed-at":"2026-01-02T00:00:00Z","aidc/size-bytes":"2097152","aidc/tainted":"no"}' pv-demo)" \
            "$(claim run-audit-20260101000000 2026-01-01T00:00:00Z '{}' pv-run)" \
            "$(claim mnt-audit-20260101000000 2026-01-01T00:00:00Z '{}' pv-mnt)" \
            "$(claim old-audit-20260101000000 2026-01-01T00:00:00Z '{"aidc/killed-at":"2026-01-03T00:00:00Z"}' pv-old)" ;;
    *"get statefulset"*"jsonpath"*) printf 'run-audit-20260101000000\n' ;;
    *"get pod"*"jsonpath"*) printf 'run-home\nmnt-audit-20260101000000\n' ;;
    *"get pv -o json"*) [ "${K_NO_PV:-}" = 1 ] && { echo 'forbidden' >&2; exit 1; }
        printf '{"items":[%s,%s,%s]}' "$(pv pv-demo Retain Bound demo-audit-20260101000000)" \
            "$(pv pv-orphan Retain Released orph-audit-20260101000000)" \
            "$(pv pv-other Retain Released someone-elses-claim)" ;;
    *"get pvc demo-audit-20260101000000 -o jsonpath"*) printf 'pv-demo' ;;
    *"get pvc old-audit-20260101000000 -o jsonpath"*) printf 'pv-old' ;;
    *"get pv "*"persistentVolumeReclaimPolicy"*) printf 'Retain' ;;
    *"get pv "*"status.phase"*) printf 'Released' ;;
    *"get pv "*"csi.driver"*) printf 'disk.example' ;;
    *"wait --for=delete"*) [ "${K_STUCK:-}" = 1 ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$SCRATCH/bin/kubectl"
cat > "$HOME/.config/aidc/config.yaml" <<EOF
audit_dir: $AUDIT
kubernetes:
  context: lab
  user: alice
  storage_class: shared-disk
EOF
rm -rf "$AUDIT"
cat > "$SCRATCH/bin/docker" <<'STUB'
#!/bin/sh
exit 0
STUB

echo "=== aidc audit list (Kubernetes) ==="
out=$(run audit list)
assert_has "exit 0" "exit=0" "$out"
assert_eq "a killed, measured claim is kept with its size" "kept 2 MB" \
    "$(printf '%s\n' "$out" | awk '$1 == "demo-audit-20260101000000" { print $(NF-1), $(NF-3), $(NF-2) }' | awk '{print $1, $2, $3}')"
assert_eq "a claim a session's StatefulSet names is running" "running" \
    "$(printf '%s\n' "$out" | awk '$1 == "run-audit-20260101000000" { print $(NF-1) }')"
assert_eq "a claim a pod mounts is running" "running" \
    "$(printf '%s\n' "$out" | awk '$1 == "mnt-audit-20260101000000" { print $(NF-1) }')"
assert_eq "a claim no session uses is kept, even with no kill time recorded" "kept" \
    "$(printf '%s\n' "$out" | awk '$1 == "old-audit-20260101000000" { print $(NF-1) }')"
assert_eq "a released audit volume whose claim is gone is listed" "released" \
    "$(printf '%s\n' "$out" | awk '$1 == "pv-orphan" { print $(NF-1) }')"
assert_not_has "a released volume that is not an audit trail is not" "pv-other" "$out"
assert_has "the total counts what aidc kill measured, and says what it could not" \
    "kubernetes: 5 trails, 2 MB in the cluster (4 of unknown size" "$out"
assert_eq "listing refreshes the cached total" "aidc-u-alice 2097152 3" \
    "$(cut -d' ' -f2- "$XDG_CACHE_HOME/aidc/audit-k8s-size")"
out=$(K_NO_PV=1 run audit list)
assert_has "volumes it may not read: said, and the claims still listed" "released audit volumes are not listed" "$out"
assert_has "the claims" "demo-audit-20260101000000" "$out"
out=$(K_DOWN=1 run audit list --backend kubernetes)
assert_has "a cluster that does not answer is an error, not an empty list" "the cluster did not answer" "$out"
assert_has "and fails" "exit=1" "$out"

echo "=== aidc audit trim (Kubernetes) ==="
out=$(run audit trim demo --dry-run)
assert_has "the dry run names the claim and its volume" "claim aidc-u-alice/demo-audit-20260101000000, volume pv-demo (Retain)" "$out"
assert_has "and says the volume and its data go too" "set to Delete first" "$out"
assert_not_has "and removes nothing" "delete" "$(cat "$K_LOG")"
assert_not_has "or changes nothing" "patch" "$(cat "$K_LOG")"

out=$(run audit trim demo --yes)
log=$(cat "$K_LOG")
assert_has "the claim's Retain volume is set to Delete" \
    'patch pv pv-demo --type=merge -p {"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' "$log"
assert_has "the claim is deleted" "delete pvc demo-audit-20260101000000" "$log"
patch_line=$(grep -n 'patch pv pv-demo' "$K_LOG" | head -n1 | cut -d: -f1)
delete_line=$(grep -n 'delete pvc demo-audit' "$K_LOG" | head -n1 | cut -d: -f1)
assert_eq "set to Delete before the claim goes, so the provisioner removes the data" "yes" \
    "$([ "${patch_line:-99}" -lt "${delete_line:-0}" ] && echo yes)"
assert_has "it waits for the volume to go" "wait --for=delete pv/pv-demo" "$log"
assert_has "and says the data is deleted" "removed claim demo-audit-20260101000000: volume pv-demo and its data are deleted" "$out"
assert_has "exit 0" "exit=0" "$out"
assert_eq "the cached total is dropped" "no" "$([ -f "$XDG_CACHE_HOME/aidc/audit-k8s-size" ] && echo yes || echo no)"

out=$(K_STUCK=1 run audit trim demo --yes)
assert_has "a volume the provisioner keeps: named, with where its data is" \
    "volume pv-demo is still there (Released)" "$out"
assert_has "the data is said to be on the storage backend" "its data is still on the storage backend" "$out"
assert_has "and it fails" "exit=1" "$out"

out=$(run audit trim run mnt --yes)
assert_has "a running session's claim is refused" "run-audit-20260101000000 (kubernetes, running)" "$out"
assert_has "so is a mounted one" "mnt-audit-20260101000000 (kubernetes, running)" "$out"
assert_not_has "nothing is deleted" "delete" "$(cat "$K_LOG")"
assert_has "and it fails" "exit=1" "$out"
out=$(bash "$AIDC_ROOT/scripts/k8s/audit.sh" trim run-audit-20260101000000 2>&1; echo "exit=$?")
assert_has "the backend refuses a running claim on its own too" "still in use by a session or pod; not removed" "$out"
assert_not_has "and deletes nothing" "delete" "$(cat "$K_LOG")"

out=$(run audit trim pv-orphan --yes)
log=$(cat "$K_LOG")
assert_has "a released volume is set to Delete" "patch pv pv-orphan" "$log"
assert_not_has "no claim is deleted for it" "delete pvc" "$log"
assert_has "and said" "removed released volume: volume pv-orphan and its data are deleted" "$out"

out=$(run audit trim --older-than 1d --dry-run)
assert_has "--older-than takes every old trail that is not running" "To remove: 3 trails" "$out"

echo "=== the size warning (Kubernetes) ==="
rm -rf "$XDG_CACHE_HOME"
out=$(AIDC_AUDIT_WARN_BYTES=1000 run list)
assert_has "a cluster command with no cached total asks the cluster once" "get pvc -l aidc/kept=audit -o json --request-timeout=5s" "$(cat "$K_LOG")"
assert_has "and warns when over the threshold" "kept audit trails take 2 MB (more than 1000 B) in the cluster (namespace aidc-u-alice" "$out"
out=$(AIDC_AUDIT_WARN_BYTES=1000 run list)
assert_not_has "within a day it uses the cached total, not the cluster" "aidc/kept=audit" "$(cat "$K_LOG")"
assert_has "and still warns" "kept audit trails take 2 MB" "$out"
out=$(run list)
assert_not_has "under 100 MB: no warning" "kept audit trails take" "$out"
now=$(date +%s)
printf '%s aidc-u-alice 999999999 0\n' $((now - 90000)) > "$XDG_CACHE_HOME/aidc/audit-k8s-size"
touch -d '@'$((now - 100000)) "$HOME/.config/aidc/config.yaml" 2>/dev/null || touch -t 197001010000 "$HOME/.config/aidc/config.yaml"
out=$(run list)
assert_has "a cached total older than a day is measured again" "aidc/kept=audit" "$(cat "$K_LOG")"
assert_not_has "and the new total decides" "kept audit trails take" "$out"
printf '%s aidc-u-alice 999999999 0\n' "$now" > "$XDG_CACHE_HOME/aidc/audit-k8s-size"
touch -d '@'$((now - 100)) "$XDG_CACHE_HOME/aidc/audit-k8s-size" 2>/dev/null || true
touch "$HOME/.config/aidc/config.yaml"
out=$(run list)
assert_has "a config changed since (another cluster or user) makes the cache stale" "aidc/kept=audit" "$(cat "$K_LOG")"
printf '%s aidc-u-alice 999999999 0\n' "$now" > "$XDG_CACHE_HOME/aidc/audit-k8s-size"
out=$(run list --backend docker)
assert_not_has "a Docker command never asks the cluster" "aidc/kept=audit" "$(cat "$K_LOG")"
assert_not_has "nor warns about the cluster's trails" "in the cluster" "$out"
out=$(K_DOWN=1 AIDC_AUDIT_CACHE_SECONDS=0 run list)
assert_not_has "a cluster that does not answer: no warning (the command says why)" "kept audit trails take" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
