#!/usr/bin/env bash
# Unit tests for the user's Syncthing pod in the cluster (K8S-18, Q-K11: LAN/VPN only): `aidc sync
# start|stop|status|push-settings` (scripts/k8s/sync.sh) and its manifests (manifests.sh,
# k8s_render_sync, k8s_render_sync_config, k8s_sync_config_xml). This machine's side is
# tests/unit/test-claude-sync.sh.
#
# kubectl is a PATH stub; HOME holds the config. Needs yq and jq; skips without them.
#
# Hygiene: scratch lives under tests/scratch/ INSIDE the repo (gitignored).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$AIDC_ROOT/tests/scratch/k8s-sync-$$"
PASS=0
FAIL=0
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/.config/aidc" "$SCRATCH/home/.claude"

for t in yq jq; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not installed"; exit 0; }
done

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (want '$want', got '$got')"; FAIL=$((FAIL + 1))
    fi
}
assert_has() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc (no '$needle' in:"; printf '%s\n' "$hay" | tail -15 | sed 's/^/      /'
           echo "    )"; FAIL=$((FAIL + 1)) ;;
    esac
}

ID1=ABCDEFG-HIJKLMN-OPQRSTU-VWXYZ23-4567ABC-DEFGHIJ-KLMNOPQ-RSTUVWX
cat > "$SCRATCH/bin/kubectl" <<'STUB_K8S_SYNC_t2'
#!/bin/sh
printf '%s\n' "$*" >> "$K_LOG"
case "$*" in
    *"get runtimeclass"*) echo '{"scheduling":{"nodeSelector":{"kubernetes.io/hostname":"n1"}}}' ;;
    *"get deployment syncthing"*) [ "${K_RUNNING:-}" = 1 ] && printf 'syncthing|1' ;;
    *"get pvc syncthing"*) [ "${K_NO_CLAIM:-}" = 1 ] || echo "persistentvolumeclaim/syncthing" ;;
    *"apply -f -"*) { echo '---'; cat; } >> "$K_APPLIED" ;;
    *"device-id"*) echo "ZZZZZZZ-YYYYYYY-XXXXXXX-WWWWWWW-VVVVVVV-UUUUUUU-TTTTTTT-SSSSSSS" ;;
    *"exec -i deployment/syncthing"*) cat > "$K_PUSHED.$(printf '%s' "$*" | md5sum | cut -c1-6)" ;;
esac
exit 0
STUB_K8S_SYNC_t2
chmod +x "$SCRATCH/bin/kubectl"
cat > "$SCRATCH/bin/getent" <<'GETENT_K8S_SYNC_t2'
#!/bin/sh
case "$2" in
    mac.lan) echo "192.168.1.20    STREAM mac.lan" ;;
    public.example) echo "203.0.113.9   STREAM public.example" ;;
esac
GETENT_K8S_SYNC_t2
chmod +x "$SCRATCH/bin/getent"

export HOME="$SCRATCH/home" K_LOG="$SCRATCH/kubectl.log" K_APPLIED="$SCRATCH/applied.yaml" \
    K_PUSHED="$SCRATCH/pushed" PATH="$SCRATCH/bin:$PATH"
CFG="$HOME/.config/aidc/config.yaml"
write_config() {
    cat > "$CFG" <<CFG_K8S_SYNC_t2
backend: kubernetes
kubernetes:
  context: lab
  user: alice
  storage_class: shared-disk
  session_storage_class: scratch
sync:
  peers:
$1
CFG_K8S_SYNC_t2
}
write_config "    - {name: mac, device_id: ${ID1}, address: mac.lan}
    - {name: wsl, device_id: ${ID1}, address: 100.64.0.7, port: 22001}"
run() { : > "$K_APPLIED"; : > "$K_LOG"; ("$AIDC_ROOT/scripts/aidc" sync "$@" 2>&1 </dev/null); echo "exit=$?"; }
q() { yq -N ea "$1" -o=json -I=0 "$K_APPLIED"; }
dep() { q "[select(.kind == \"Deployment\")] | .[-1] | $1"; }

echo "=== aidc sync start ==="
out=$(K_NO_CLAIM=1 run start)
assert_has "exit 0" "exit=0" "$out"
assert_eq "it applies its identity's claim, its settings, its policy and its Deployment" \
    "PersistentVolumeClaim/syncthing ConfigMap/syncthing-config NetworkPolicy/syncthing Deployment/syncthing" \
    "$(yq -N e 'select(.kind != null) | [.kind, .metadata.name] | join("/")' "$K_APPLIED" | paste -sd' ' -)"
assert_eq "its identity is on the user's retained class" '"shared-disk"' \
    "$(q 'select(.kind == "PersistentVolumeClaim") | .spec.storageClassName')"
pol() { q "[select(.kind == \"NetworkPolicy\")] | .[-1] | $1"; }
assert_eq "nothing may connect to it" "[]" "$(pol '.spec.ingress')"
assert_eq "it may reach only the user's machines, each on its own port (a name resolved here)" \
    '[["192.168.1.20/32",22000],["100.64.0.7/32",22001]]' \
    "$(pol '[.spec.egress[] | [.to[0].ipBlock.cidr, .ports[0].port]]')"
xml=$(q 'select(.kind == "ConfigMap") | .data."config.xml"' | jq -r .)
for o in globalAnnounceEnabled localAnnounceEnabled relaysEnabled natEnabled crashReportingEnabled; do
    assert_has "$o off (LAN/VPN only, Q-K11)" "<${o}>false</${o}>" "$xml"
done
assert_has "usage reporting refused" "<urAccepted>-1</urAccepted>" "$xml"
assert_has "its GUI only on its own loopback" "<address>127.0.0.1:8384</address>" "$xml"
assert_has "each machine dialled at its address" "<address>tcp://192.168.1.20:22000</address>" "$xml"
assert_has "one folder, aidc-claude, the disk's .claude" 'folder id="aidc-claude" label="Claude (aidc)" path="/var/syncthing/claude" type="sendreceive"' "$xml"
assert_has "...shared with the machines" "<device id=\"${ID1}\"></device>" "$xml"
assert_eq "the folder's ignore list is the sync set" "$(. "$AIDC_ROOT/scripts/lib/claude-sync.sh"; aidc_sync_stignore)" \
    "$(q 'select(.kind == "ConfigMap") | .data.".stignore"' | jq -r .)"
pod() { dep ".spec.template.spec | $1"; }
assert_eq "no API token, no service links, no DNS" '[false,false,"None"]' \
    "$(pod '[.automountServiceAccountToken, .enableServiceLinks, .dnsPolicy]')"
assert_eq "it runs as the session user (the history's owner), read-only, with nothing" \
    '{"runAsUser":1000,"runAsGroup":1000,"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}' \
    "$(pod '.containers[0].securityContext')"
assert_eq "it mounts its identity and the disk's .claude only" \
    '[{"name":"config","mountPath":"/var/syncthing/config"},{"name":"disk","mountPath":"/var/syncthing/claude","subPath":".claude"},{"name":"tmp","mountPath":"/tmp"}]' \
    "$(pod '.containers[0].volumeMounts')"
assert_eq "the disk's .claude is made first, as the session user, before any mount of it" \
    '["claude-dir",{"runAsUser":1000,"runAsGroup":1000}]' "$(pod '[.initContainers[0].name, .initContainers[0].securityContext]')"
assert_has "the pinned Syncthing image" '"docker.io/syncthing/syncthing:' "$(pod '.containers[0].image | tojson')"
assert_has "a changed setting takes effect: the pod is restarted" "rollout restart deployment/syncthing" "$(cat "$K_LOG")"

echo "=== peers it refuses ==="
write_config "    - {name: far, device_id: ${ID1}, address: public.example}"
out=$(run start)
assert_has "a machine at a public address (no relays, no internet: Q-K11)" "is a public address" "$out"
assert_eq "...nothing applied" "" "$(cat "$K_APPLIED")"
write_config "    - {name: mac, device_id: nope, address: 192.168.1.20}"
out=$(run start)
assert_has "a device ID that is not one" "is not a Syncthing device ID" "$out"
write_config "    - {name: mac, device_id: ${ID1}}"
out=$(run start)
assert_has "a machine with no address" "no address" "$out"
write_config "    - {name: mac, device_id: ${ID1}, address: 192.168.1.20}"

echo "=== status, stop, push-settings ==="
out=$(K_RUNNING=1 run status)
assert_has "status gives the pod's device ID, to pair the machines with" "device ID:  ZZZZZZZ-YYYYYYY" "$out"
assert_has "...and the peers" "peer:       mac 192.168.1.20" "$out"
out=$(K_RUNNING=1 run stop)
assert_has "stop removes its Deployment and policy (identity and history kept)" \
    "delete deployment,networkpolicy -l app=syncthing" "$(cat "$K_LOG")"
printf '{"statusLine":{"type":"command","command":"~/.claude/statusline.sh"},"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/opt/aidc/.devcontainer/claude-lease.sh hook"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"mine"}]}]}}' > "$HOME/.claude/settings.json"
printf '#!/bin/sh\necho mine\n' > "$HOME/.claude/statusline.sh"
rm -f "$K_PUSHED".*
out=$(K_RUNNING=1 run push-settings)
assert_has "push-settings copies settings.json as the template new sessions start from" "settings.template.json" "$(cat "$K_LOG")"
assert_has "...and the status line script" "statusline.sh" "$(cat "$K_LOG")"
assert_eq "what was sent is this machine's" "2" "$(cat "$K_PUSHED".* | grep -c -e '"model": "opus"' -e 'echo mine')"
tmpl=$(cat "$K_PUSHED".* | jq -c 'select(type == "object")' 2>/dev/null)
assert_eq "...the template without the hooks aidc sync setup added (this machine's paths), its own kept" \
    '{"SessionEnd":[{"hooks":[{"type":"command","command":"mine"}]}]}' "$(printf '%s' "$tmpl" | jq -c .hooks)"
out=$(run push-settings)
assert_has "with no pod running it says so" "aidc sync start" "$out"

echo "=== this machine's side, through the dispatcher ==="
out=$(run setup)
assert_has "setup writes the ignore list" "wrote ${HOME}/.claude/.stignore" "$out"
assert_eq "...the sync set" "*" "$(tail -1 "$HOME/.claude/.stignore")"
assert_has "...and says what is next" "aidc sync status" "$out"

echo
echo "k8s sync: passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
