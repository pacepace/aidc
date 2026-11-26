#!/usr/bin/env bash
# aidc sync start|stop|status|logs|push-settings, on Kubernetes: the user's Syncthing pod, which
# keeps their disk's .claude (every session's conversations and memory, and the shared Claude
# files) in sync with their own machines over the LAN or VPN (K8S-18, Q-K11). cmd-sync.sh sends
# these verbs here; `aidc sync setup` and `aidc sync reconcile` are the machine's own side.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=tunnel.sh
. "$AIDC_SCRIPTS/k8s/tunnel.sh"
# shellcheck source=../lib/egress.sh
. "$AIDC_SCRIPTS/lib/egress.sh"
# shellcheck source=../lib/claude-sync.sh
. "$AIDC_SCRIPTS/lib/claude-sync.sh"

usage() {
    cat <<'USAGE'
aidc sync <verb> --backend kubernetes

Your Claude history in the cluster (your disk's .claude: every session's conversations and
memory, CLAUDE.md, rules, skills, agents, commands, keybindings), kept in sync with your own
machines by a Syncthing pod in your namespace, over your LAN or VPN only.

  start            Start it, or apply changed peers (sync.peers in your config)
  stop             Stop it (its identity and your history are kept)
  status           Running state, its device ID (pair your machines with it), the peers
  logs [--follow]  Its log
  push-settings    Copy this machine's Claude settings.json (as the template new sessions
                   start from) and its status line script to the cluster: laptop to cluster
                   only, never synced back

Config:
  sync:
    peers:                       # your machines; the pod dials each one, nothing else
      - {name: mac, device_id: ABCDEFG-..., address: 192.168.1.20}   # port 22000 unless given

On each machine: Syncthing, with a folder of id aidc-claude at ~/.claude, shared with the
pod's device ID (aidc sync status); `aidc sync setup` writes the folder's ignore list there.
USAGE
}

# sync_peers: the configured peers, "<name> <device-id> <ipv4> <port>" a line; dies on one that
# cannot be used, saying why. A name is resolved here, as a relay's is (NET-15).
sync_peers() {
    local json n i name id addr port ip
    json=$(_k8s_cfg_json '.sync.peers' '[]')
    n=$(printf '%s' "$json" | jq 'length' 2>/dev/null) || die "sync.peers is not a list"
    for ((i = 0; i < n; i++)); do
        name=$(printf '%s' "$json" | jq -r ".[$i].name // \"peer$i\"")
        id=$(printf '%s' "$json" | jq -r ".[$i].device_id // \"\"")
        addr=$(printf '%s' "$json" | jq -r ".[$i].address // \"\"")
        port=$(printf '%s' "$json" | jq -r ".[$i].port // ${K8S_SYNC_PORT}")
        printf '%s' "$name" | grep -Eqx '[A-Za-z0-9._-]{1,63}' || die "sync.peers: the name ${name} is not a plain name"
        printf '%s' "$id" | grep -Eqx '[A-Z2-7]{7}(-[A-Z2-7]{7}){7}' \
            || die "sync.peers ${name}: device_id is not a Syncthing device ID (its Actions > Show ID)"
        k8s_port_ok "$port" || die "sync.peers ${name}: port ${port} is not a port"
        [ -n "$addr" ] || die "sync.peers ${name}: no address (the machine's LAN or VPN address)"
        if aidc_egress_is_ipv4 "$addr"; then
            ip="$addr"
        else
            ip=$(aidc_egress_resolve_explained "$addr") || die "sync.peers ${name}: cannot resolve ${addr} here"
        fi
        sync_private_ip "$ip" || die "sync.peers ${name}: ${ip} is a public address: Syncthing reaches only your own machines, on your LAN or VPN (Q-K11)"
        printf '%s %s %s %s\n' "$name" "$id" "$ip" "$port"
    done
}

# sync_private_ip <ipv4>: 0 for a private, shared (CGNAT, VPN) or link-local address.
sync_private_ip() {
    local a b
    IFS=. read -r a b _ <<<"$1"
    case "$a" in
        10) return 0 ;;
        172) [ "$b" -ge 16 ] && [ "$b" -le 31 ] ;;
        192) [ "$b" = 168 ] ;;
        100) [ "$b" -ge 64 ] && [ "$b" -le 127 ] ;;
        169) [ "$b" = 254 ] ;;
        *) return 1 ;;
    esac
}

# sync_state: RUNNING, STARTING or NOT RUNNING; returns 2 when the cluster did not answer.
sync_state() {
    local out
    out=$(k8s_get "$ns" deployment "$K8S_SYNC_NAME" -o 'jsonpath={.metadata.name}|{.status.readyReplicas}') \
        || { printf 'unknown (the cluster did not answer: %s)' "$out"; return 2; }
    case "$out" in
        "") printf 'NOT RUNNING' ;;
        *"|"|*"|0") printf 'STARTING' ;;
        *) printf 'RUNNING' ;;
    esac
}

# sync_device_id: the pod's device ID, "" when it cannot be read.
sync_device_id() {
    local out
    out=$(k8s_kubectl -n "$ns" exec "deployment/${K8S_SYNC_NAME}" -c syncthing -- \
        /bin/syncthing device-id --home=/var/syncthing/config </dev/null 2>/dev/null) || out=""
    [ -n "$out" ] || out=$(k8s_kubectl -n "$ns" logs "deployment/${K8S_SYNC_NAME}" -c syncthing 2>/dev/null || true)
    printf '%s\n' "$out" | grep -Eo '[A-Z2-7]{7}(-[A-Z2-7]{7}){7}' | head -n1
}

sync_start() {
    local peers sel have
    peers=$(sync_peers)
    [ -n "$peers" ] || info "no sync.peers in your config: the pod starts, reaching no machine until you add one (then aidc sync start again)"
    have=$(k8s_get "$ns" pvc "$K8S_SYNC_CLAIM" -o name) || die "cannot read the Syncthing claim in ${ns}: the cluster did not answer (${have})"
    if [ -z "$have" ]; then
        k8s_render_sync_claim | k8s_kubectl apply -f - >/dev/null || die "could not make the Syncthing claim"
    fi
    k8s_render_sync_config "$peers" | k8s_kubectl apply -f - >/dev/null || die "could not write Syncthing's settings"
    sel=$(k8s_node_selector) || exit 1
    k8s_render_sync "$sel" "$peers" | k8s_kubectl apply -f - >&2 || die "could not apply the Syncthing pod"
    # Settings are read at start: a running pod is restarted to take changed ones.
    k8s_kubectl -n "$ns" rollout restart "deployment/${K8S_SYNC_NAME}" >/dev/null 2>&1 || true
    k8s_kubectl -n "$ns" rollout status "deployment/${K8S_SYNC_NAME}" --timeout=300s >&2 \
        || die "Syncthing did not become ready; see: kubectl -n ${ns} describe pod -l app=${K8S_SYNC_NAME}"
    sync_status
}

sync_status() {
    local state rc=0 id
    state=$(sync_state) || rc=$?
    printf 'syncthing (kubernetes, %s): %s\n' "$ns" "$state"
    [ "$rc" = 0 ] && [ "$state" = RUNNING ] || return 0
    id=$(sync_device_id)
    printf '  device ID:  %s\n' "${id:-unknown (aidc sync logs)}"
    printf '  folder:     %s (your disk'"'"'s .claude), LAN/VPN only: no discovery, no relays\n' "$AIDC_SYNC_FOLDER_ID"
    _k8s_cfg_json '.sync.peers' '[]' | jq -r '.[] | "  peer:       \(.name // "?") \(.address // "?") \(.device_id // "?")"'
}

sync_push_settings() {
    local src="${HOME}/.claude" cmd script tmpl
    [ "$(sync_state 2>/dev/null || true)" = RUNNING ] || die "Syncthing is not running in ${ns}: aidc sync start"
    if [ -f "${src}/settings.json" ]; then
        # Without the hooks `aidc sync setup --hooks` added here: they name this machine's
        # paths, and a cluster session runs its own from its managed settings.
        tmpl=$(jq 'if (.hooks | type) == "object" then
                       .hooks |= (with_entries(.value |= map(select(any(.hooks[]?; (.command // "") | test("claude-lease[.]sh|aidc sync reconcile")) | not)))
                                  | with_entries(select(.value | length > 0)))
                       | if .hooks == {} then del(.hooks) else . end
                   else . end' "${src}/settings.json") || die "${src}/settings.json is not JSON"
        printf '%s\n' "$tmpl" | k8s_kubectl -n "$ns" exec -i "deployment/${K8S_SYNC_NAME}" -c syncthing -- \
            sh -c 'umask 022 && t=$(mktemp /var/syncthing/claude/.settings.template.XXXXXX) && cat > "$t" && mv -f "$t" /var/syncthing/claude/settings.template.json' \
            || die "could not copy settings.json"
        info "settings.json: the template new cluster sessions start from"
    fi
    cmd=$(jq -r '.statusLine.command // empty' "${src}/settings.json" 2>/dev/null || true)
    script=""
    # shellcheck disable=SC2088  # the literal ~ a settings file holds
    case "$cmd" in
        "~/.claude/"*) script="${src}/${cmd#\~/.claude/}" ;;
        "${src}/"*) script="$cmd" ;;
    esac
    script="${script%% *}"
    if [ -n "$script" ] && [ -f "$script" ]; then
        k8s_kubectl -n "$ns" exec -i "deployment/${K8S_SYNC_NAME}" -c syncthing -- \
            sh -c 'umask 022 && n="$1" && t=$(mktemp "/var/syncthing/claude/.$n.XXXXXX") && cat > "$t" && chmod 0755 "$t" && mv -f "$t" "/var/syncthing/claude/$n"' \
            sh "$(basename -- "$script")" < "$script" || die "could not copy the status line script"
        info "status line: $(basename -- "$script") (cluster sessions run it through aidc, which reads its usage)"
    fi
}

VERB="${1:-}"
shift || true
case "$VERB" in ""|help|-h|--help) usage; exit 0 ;; esac
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
case "$VERB" in
    start) sync_start ;;
    stop)
        info "stopping Syncthing in ${ns} (its identity and your history are kept)"
        k8s_kubectl -n "$ns" delete deployment,networkpolicy -l "app=${K8S_SYNC_NAME}" --wait=true >&2 \
            || die "could not stop Syncthing" ;;
    status) sync_status ;;
    logs)
        case "${1:-}" in --follow|-f) k8s_kubectl -n "$ns" logs -f "deployment/${K8S_SYNC_NAME}" -c syncthing ;;
                         "") k8s_kubectl -n "$ns" logs "deployment/${K8S_SYNC_NAME}" -c syncthing ;;
                         *) die "unknown flag: $1" ;; esac ;;
    push-settings) sync_push_settings ;;
    *) err "unknown 'aidc sync' verb: ${VERB} (try: aidc sync help)"; exit 2 ;;
esac
