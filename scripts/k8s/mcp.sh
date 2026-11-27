#!/usr/bin/env bash
# aidc mcp start|stop|status|logs|token rotate|token show, on Kubernetes: the user's own MCP
# server in their namespace (K8S-07; MCP-02/03/05/06 as amended). scripts/k8s/manifests.sh,
# "The user's MCP server", says what runs; cmd-mcp.sh sends `aidc mcp` here when the backend
# is kubernetes (--backend, or the config's `backend:`).
#
# The token is a Secret in the user's namespace (MCP-05); start and rotate also write it to
# ~/.config/aidc/mcp-token (0600), so an orchestrator's config reads it where it does on Docker.
# It is never on a command line and never printed, except by `token rotate` (as on Docker) and
# `token show`.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=tunnel.sh
. "$AIDC_SCRIPTS/k8s/tunnel.sh"
# shellcheck source=expose.sh
. "$AIDC_SCRIPTS/k8s/expose.sh"
# shellcheck source=../lib/egress.sh
. "$AIDC_SCRIPTS/lib/egress.sh"

TOKEN_FILE="${HOME}/.config/aidc/mcp-token"

usage() {
    cat <<'USAGE'
aidc mcp <verb> --backend kubernetes

Your MCP server in the cluster, in your namespace: it keeps your sessions answering while
your machines are off.

Verbs:
  start              Start it (or apply what changed), with its token made when missing
  stop               Stop it (its state, token and transcripts are kept)
  status             Running state, token, last event
  logs [--follow]    Its log
  token rotate       A new token: the server restarts, and an MCP session opened with the old
                     one is refused on its next message; prints the new token
  token show         Print the current token

The token is a Secret in your namespace; start and rotate also write it to
~/.config/aidc/mcp-token (mode 0600), where an orchestrator's config reads it.

It is reached in the cluster at http://aidc-mcp.<your namespace>.svc:7878/mcp, and on your
network at https://mcp-<user>.<your pages' domain>/mcp when mcp.kubernetes.expose is ingress;
always with the token. It may post replies to orchestrator.callback_url only.
USAGE
}

# mcp_token_new: 32 random bytes, base64url without padding (the Docker server's form).
mcp_token_new() {
    LC_ALL=C dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr '+/' '-_' | tr -d '=\n'
}

# mcp_token_write_local <token>: the token to ~/.config/aidc/mcp-token, mode 0600 from the start.
mcp_token_write_local() {
    local dir tmp
    dir=$(dirname "$TOKEN_FILE")
    mkdir -p "$dir" || return 1
    tmp=$(umask 077 && mktemp "${dir}/.mcp-token.XXXXXX") || return 1
    if printf '%s\n' "$1" > "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$TOKEN_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# mcp_token_read: the token in the Secret, on stdout; "" when there is none; returns 2 when the
# cluster did not answer (k8s_get's rule: a failed read is never "no token").
mcp_token_read() {
    local b64
    b64=$(k8s_get "$ns" secret "$K8S_MCP_TOKEN_SECRET" -o 'jsonpath={.data.token}') || {
        printf '%s' "$b64" >&2; return 2; }
    [ -n "$b64" ] || return 0
    printf '%s' "$b64" | base64 -d
}

# mcp_api_endpoints: the API server's addresses the server may reach, "<ipv4>:<port>" a line,
# the one its kubectl tries first first: kubernetes.api_endpoints when the config names them,
# else the server of the kubeconfig in use, resolved here, and, when that is a control-plane
# node's own address, every control-plane node's at the same port (so the pod has another to
# turn to). A loopback or unresolvable one is refused: the pod could not reach it. Which of them
# the pod does reach is asked from inside it once it runs (mcp_reachable_endpoint).
mcp_api_endpoints() {
    local listed ep server hostport host port ip cps
    listed=$(_k8s_cfg_json '.kubernetes.api_endpoints' '[]' | yq -p=json '.[]' 2>/dev/null || true)
    if [ -n "$listed" ]; then
        while IFS= read -r ep; do
            [ -n "$ep" ] || continue
            host="${ep%:*}" port="${ep##*:}"
            if ! aidc_egress_is_ipv4 "$host" || ! k8s_port_ok "$port"; then
                err "kubernetes.api_endpoints: ${ep} is not <ipv4>:<port>"; return 1
            fi
            printf '%s:%s\n' "$host" "$port"
        done <<<"$listed"
        return 0
    fi
    server=$(k8s_kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null) || server=""
    hostport="${server#*://}"; hostport="${hostport%%/*}"
    [ -n "$hostport" ] || { err "cannot tell the API server's address from your kubeconfig: set kubernetes.api_endpoints"; return 1; }
    case "$hostport" in
        \[*) err "the API server is an IPv6 address (${hostport}): set kubernetes.api_endpoints to its IPv4 address"; return 1 ;;
        *:*) host="${hostport%:*}" port="${hostport##*:}" ;;
        *) host="$hostport" port=443 ;;
    esac
    ip=$(aidc_egress_resolve_explained "$host") || { err "set kubernetes.api_endpoints to the API server's <ipv4>:<port>"; return 1; }
    case "$ip" in
        127.*) err "your kubeconfig reaches the API server at ${ip}, which the server's pod cannot: set kubernetes.api_endpoints to the API server's <ipv4>:<port> as the cluster sees it"; return 1 ;;
    esac
    printf '%s:%s\n' "$ip" "$port"
    cps=$(mcp_control_plane_ips)
    if printf '%s\n' "$cps" | grep -qxF "$ip"; then
        printf '%s\n' "$cps" | grep -vxF "$ip" | sed "s/\$/:${port}/"
    fi
    return 0
}

# mcp_control_plane_ips: the InternalIP of each control-plane node, one a line, as the cluster
# itself reports them (the addresses its API Service balances over); "" when it has none to
# show (a managed control plane) or does not answer.
mcp_control_plane_ips() {
    k8s_kubectl get nodes -l node-role.kubernetes.io/control-plane \
        -o 'jsonpath={range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null \
        | while IFS= read -r a; do aidc_egress_is_ipv4 "$a" && printf '%s\n' "$a"; done
    return 0
}

# mcp_reachable_endpoint <ipv4>:<port>...: the first of them the running server's pod reaches
# the API server at, asked from inside the pod with its own kubectl (the address the pod's
# kubeconfig will name, checked where it is used, not where it was resolved), on stdout. When
# it reaches none, prints the last attempt's error on stderr instead (a refused connection, or
# an exec that failed for its own reason: the two read differently) and returns 1. /readyz is
# readable by any client, so no grant is needed for the question.
mcp_reachable_endpoint() {
    local ep errf why=""
    errf=$(mktemp) || { printf 'cannot make a temporary file\n' >&2; return 1; }
    for ep in "$@"; do
        if k8s_kubectl -n "$ns" exec "deployment/${K8S_MCP_NAME}" -c mcp -- kubectl --server "https://${ep}" \
            --tls-server-name kubernetes.default.svc --request-timeout=5s get --raw /readyz </dev/null >/dev/null 2>"$errf"; then
            rm -f "$errf"
            printf '%s' "$ep"
            return 0
        fi
        why=$(grep -v '^[[:space:]]*$' "$errf" | tail -n1)
    done
    rm -f "$errf"
    printf '%s\n' "${why:-no answer}" >&2
    return 1
}

# mcp_config_endpoint: the API server address the running server's kubeconfig names now (its
# ConfigMap's), "" when it has none or the cluster does not answer.
mcp_config_endpoint() {
    local kc server
    kc=$(k8s_get "$ns" configmap "$K8S_MCP_CONFIG" -o 'jsonpath={.data.kubeconfig}' 2>/dev/null) || return 0
    server=$(printf '%s' "$kc" | yq '.clusters[0].cluster.server // ""' 2>/dev/null) || return 0
    case "$server" in https://*) printf '%s' "${server#https://}" ;; esac
    return 0
}

# mcp_callback: K8S_MCP_CALLBACK_IP, _PORT and _HOST, where the server posts finished turns
# (orchestrator.callback_url), for its one egress rule and hosts entry. The name is resolved on
# this machine, as relays' are (NET-15), unless mcp.kubernetes.callback_address gives the
# address the cluster reaches it at. No callback_url: no callback egress, said once. Returns 1,
# saying why, for a URL or address the server could not use.
mcp_callback() {
    local url rest hostport host port ip over
    K8S_MCP_CALLBACK_IP="" K8S_MCP_CALLBACK_PORT="" K8S_MCP_CALLBACK_HOST=""
    url=$(_k8s_cfg '.orchestrator.callback_url')
    if [ -z "$url" ]; then
        info "no orchestrator.callback_url: the server delivers no replies until one is set (then aidc mcp start again)"
        return 0
    fi
    case "$url" in
        http://*) port=80 ;;
        https://*) port=443 ;;
        *) err "orchestrator.callback_url ${url} is not an http(s) URL"; return 1 ;;
    esac
    rest="${url#*://}"; hostport="${rest%%/*}"; hostport="${hostport##*@}"
    case "$hostport" in
        \[*) err "orchestrator.callback_url names an IPv6 address: set mcp.kubernetes.callback_address to its IPv4 address"; return 1 ;;
        *:*) host="${hostport%:*}" port="${hostport##*:}" ;;
        *) host="$hostport" ;;
    esac
    if ! printf '%s' "$host" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || ! k8s_port_ok "$port"; then
        err "orchestrator.callback_url ${url}: cannot read its host and port"; return 1
    fi
    over=$(_k8s_cfg '.mcp.kubernetes.callback_address')
    if [ -n "$over" ]; then
        aidc_egress_is_ipv4 "$over" || { err "mcp.kubernetes.callback_address ${over} is not an IPv4 address"; return 1; }
        ip="$over"
    elif ! ip=$(aidc_egress_resolve_explained "$host"); then
        err "set mcp.kubernetes.callback_address to the orchestrator's IPv4 address as the cluster reaches it"
        return 1
    fi
    case "$ip" in
        127.*) err "the callback host ${host} is ${ip} here, which the server's pod cannot reach: set mcp.kubernetes.callback_address"; return 1 ;;
    esac
    K8S_MCP_CALLBACK_IP="$ip" K8S_MCP_CALLBACK_PORT="$port"
    aidc_egress_is_ipv4 "$host" || K8S_MCP_CALLBACK_HOST="$host"
    export K8S_MCP_CALLBACK_IP K8S_MCP_CALLBACK_PORT K8S_MCP_CALLBACK_HOST
}

# mcp_expose_mode: "none" or "ingress" (mcp.kubernetes.expose); returns 1, saying why, otherwise.
mcp_expose_mode() {
    local m
    m=$(_k8s_cfg '.mcp.kubernetes.expose')
    case "$m" in
        ""|none|false) printf 'none' ;;
        ingress) printf 'ingress' ;;
        *) err "mcp.kubernetes.expose ${m}: expected ingress, or none (in the cluster only)"; return 1 ;;
    esac
}

# mcp_expose_check: whether the cluster can serve the server at k8s_mcp_host (MCP-11: an
# exposure the config asks for that cannot be served is refused, not skipped). Returns 1, saying
# why.
mcp_expose_check() {
    local host taken
    [ -n "$AIDC_K8S_INGRESS_DOMAIN" ] || { err "mcp.kubernetes.expose ingress needs kubernetes.ingress.domain: the domain your pages live under"; return 1; }
    k8s_valid_domain "$AIDC_K8S_INGRESS_DOMAIN" || { err "kubernetes.ingress.domain ${AIDC_K8S_INGRESS_DOMAIN} is not a domain name"; return 1; }
    [ -n "$AIDC_K8S_INGRESS_CLASS" ] || { err "mcp.kubernetes.expose ingress needs kubernetes.ingress.class"; return 1; }
    # The IngressClass must be there (an exposure the cluster cannot serve is refused).
    k8s_ingress_controller_settle || return 1
    host=$(k8s_mcp_host)
    if [ "${#host}" -gt 253 ] || [ "$(printf '%s' "${host%%.*}" | wc -c)" -gt 63 ]; then
        err "the server's name ${host} is too long for DNS"; return 1
    fi
    if taken=$(k8s_expose_taken "$ns" "$host") && [ "$taken" != "${ns}/${K8S_MCP_NAME}" ]; then
        err "${host} is already served by ingress ${taken}"; return 1
    fi
    # On the VPN/LAN only: a session's proxy may reach any public address (and no private one),
    # so a name that leads to a public address would let every session reach the server through
    # its Squid (MCP-12, K8S-13). Checked where this machine resolves it.
    local ip rc=0
    ip=$(aidc_egress_resolve "$host") || rc=$?
    if [ "$rc" != 0 ]; then
        err "cannot resolve ${host} here, so cannot tell it is on your network only: the server is exposed only at a private address, which aidc checks (does your network's DNS answer for the pages' domain?)"
        return 1
    fi
    if ! mcp_private_ipv4 "$ip"; then
        err "${host} resolves to ${ip}, a public address: every session could reach your MCP server through its proxy there; expose it only where the name resolves to your VPN/LAN (mcp.kubernetes.expose: none keeps it in the cluster)"
        return 1
    fi
}

# mcp_private_ipv4 <ipv4>: 0 when the address is in the ranges the session proxy's NetworkPolicy
# keeps it from (private, shared CGNAT, loopback, link-local: manifests.sh, its egress except
# list). Squid refuses more than these, so a name here is out of every session's reach.
mcp_private_ipv4() {
    local a b
    IFS=. read -r a b _ <<<"$1"
    case "$a" in
        10|127) return 0 ;;
        172) [ "$b" -ge 16 ] && [ "$b" -le 31 ] ;;
        192) [ "$b" = 168 ] ;;
        169) [ "$b" = 254 ] ;;
        100) [ "$b" -ge 64 ] && [ "$b" -le 127 ] ;;
        *) return 1 ;;
    esac
}

# mcp_state: RUNNING, STARTING or NOT RUNNING, from the Deployment; returns 2 when the cluster
# did not answer.
mcp_state() { k8s_deployment_state "$ns" "$K8S_MCP_NAME"; }

# mcp_incluster_api: the API server's in-cluster Service address as the running server's pod
# sees it (KUBERNETES_SERVICE_HOST and _PORT), "<ipv4>:<port>"; returns 1 when it cannot be read.
mcp_incluster_api() {
    local svc host port
    svc=$(k8s_kubectl -n "$ns" exec "deployment/${K8S_MCP_NAME}" -c mcp -- printenv KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT </dev/null 2>/dev/null) || return 1
    host=$(printf '%s\n' "$svc" | sed -n 1p) port=$(printf '%s\n' "$svc" | sed -n 2p)
    aidc_egress_is_ipv4 "$host" && k8s_port_ok "$port" || return 1
    printf '%s:%s\n' "$host" "$port"
}

# mcp_policy_endpoints: the API server addresses the server's NetworkPolicy allows now (the
# aidc-mcp policy's egress, which holds nothing else: the callback has a policy of its own),
# "<ipv4>:<port>" a line ("" when there is none); returns 1 when it cannot be read.
mcp_policy_endpoints() {
    local doc
    doc=$(k8s_get "$ns" networkpolicy "$K8S_MCP_NAME" -o json) || return 1
    [ -n "$doc" ] || return 0
    printf '%s' "$doc" | yq -p=json '.spec.egress[] | (.to[0].ipBlock.cidr | sub("/32$"; "")) + ":" + (.ports[0].port | tostring)' 2>/dev/null
}

# mcp_add_endpoints <list> <more>: <list> with each line of <more> not in it yet added.
mcp_add_endpoints() {
    local out="$1" ep
    while IFS= read -r ep; do
        [ -n "$ep" ] || continue
        printf '%s\n' "$out" | grep -qxF "$ep" || out=$(printf '%s\n%s' "$out" "$ep")
    done <<<"$2"
    printf '%s\n' "$out"
}

mcp_start() {
    local sel tok rc=0 eps api_eps first reach target held="" state incluster="" known expose
    # A token first: the pod mounts it, and a cluster that does not say whether there is one
    # must not get a second.
    tok=$(mcp_token_read) || rc=$?
    [ "$rc" = 0 ] || die "cannot read your MCP token in ${ns}: the cluster did not answer"
    eps=$(mcp_api_endpoints) || exit 1
    api_eps="$eps" first=$(printf '%s\n' "$eps" | head -n1)
    mcp_callback || exit 1
    expose=$(mcp_expose_mode) || exit 1
    [ "$expose" != ingress ] || mcp_expose_check || exit 1
    # The API server's in-cluster address too, as the pod sees it: a network policy may judge a
    # connection before or after the Service's address is translated, so both are allowed. A
    # server that runs already says it, so its policy is applied once, never narrowed for a
    # moment under the server; one that does not answer keeps what its policy allows now. A
    # new server's is read once it runs (below).
    state=$(mcp_state) || die "cannot tell whether your MCP server runs: ${state}"
    if [ "$state" != "NOT RUNNING" ]; then
        if ! incluster=$(mcp_incluster_api); then
            known=$(mcp_policy_endpoints) \
                || die "cannot read your MCP server's API address, nor its network policy: the cluster did not answer (nothing was changed)"
            incluster=$(printf '%s\n' "$known" | grep -vxF -f <(printf '%s\n' "$eps") || true)
        fi
        eps=$(mcp_add_endpoints "$eps" "$incluster")
    fi
    # The pod's kubectl goes to one API server address (docs/design-12-kubernetes.md, the MCP
    # server's "API server reach"). A server that runs already is asked which it reaches before
    # its kubeconfig is written (it is projected into the running pod, so a write is live): it
    # keeps the one it reaches, and is restarted only when that is not the one it held. A new
    # server starts on the first, until it says it reaches another only (below).
    target="$first"
    if [ "$state" != "NOT RUNNING" ]; then
        held=$(mcp_config_endpoint)
        # shellcheck disable=SC2086  # one endpoint per word
        # (Its error is not one here: the check below asks again and shows that one.)
        if reach=$(mcp_reachable_endpoint $api_eps 2>/dev/null); then target="$reach"; fi
    fi
    if [ -z "$tok" ]; then
        tok=$(mcp_token_new)
        [ "${#tok}" -ge 40 ] || die "cannot make a token"
        k8s_render_mcp_token "$tok" | k8s_kubectl create -f - >/dev/null \
            || die "the cluster did not take your MCP token"
        info "made a new MCP bearer token (Secret ${K8S_MCP_TOKEN_SECRET} in ${ns})"
    fi
    sel=$(k8s_node_selector) || exit 1
    k8s_ensure_transcripts "$ns" || exit 1
    k8s_ensure_claim "$ns" "$K8S_MCP_STATE_CLAIM" "MCP server's state" k8s_render_mcp_state || exit 1
    k8s_render_mcp_config "$target" | k8s_kubectl apply -f - >/dev/null \
        || die "could not write the MCP server's config"
    mcp_load_settings
    if [ "${AIDC_MCP_SESSION_CREATE:-}" = true ]; then
        info "session_create: offered (mcp.session_create; sessions are made in ${ns}, without a repo)"
    else
        info "session_create: not offered (set mcp.session_create: true to enable)"
    fi
    info "starting your MCP server in ${ns} (it reaches the API server at $(printf '%s' "$eps" | paste -sd' ' -) only)"
    # shellcheck disable=SC2086  # one endpoint per word
    k8s_render_mcp "$sel" $eps | k8s_kubectl apply -f - >&2 || die "could not apply the MCP server"
    k8s_kubectl -n "$ns" rollout status "deployment/${K8S_MCP_NAME}" --timeout=300s >&2 \
        || die "the MCP server did not become ready; see: kubectl -n ${ns} describe pod -l app=${K8S_MCP_NAME}"
    if [ "$state" = "NOT RUNNING" ]; then
        held="$target"
        incluster=$(mcp_incluster_api) \
            || die "your MCP server started, but its in-cluster API address could not be read, so it may not reach the API server: run aidc mcp start again (aidc mcp logs says more)"
        if ! printf '%s\n' "$eps" | grep -qxF "$incluster"; then
            eps=$(mcp_add_endpoints "$eps" "$incluster")
            # shellcheck disable=SC2086  # one endpoint per word
            k8s_render_mcp "$sel" $eps | k8s_kubectl apply -f - >/dev/null \
                || die "could not let the MCP server reach the API server at ${incluster}"
        fi
    fi
    reach_err=$(mktemp) || die "cannot make a temporary file"
    # shellcheck disable=SC2086  # one endpoint per word
    reach=$(mcp_reachable_endpoint $api_eps 2>"$reach_err") \
        || die "your MCP server's pod reaches the API server at none of $(printf '%s' "$api_eps" | paste -sd' ' -) ($(cat "$reach_err"; rm -f "$reach_err")): set kubernetes.api_endpoints to the API server's <ipv4>:<port> as pods in the cluster reach it, then aidc mcp start again"
    rm -f "$reach_err"
    [ "$reach" = "$first" ] || info "your MCP server's pod does not reach the API server at ${first}: it uses ${reach}"
    if [ "$reach" != "$target" ]; then
        k8s_render_mcp_config "$reach" | k8s_kubectl apply -f - >/dev/null \
            || die "could not write the MCP server's config"
    fi
    if [ "$reach" != "$held" ]; then
        k8s_kubectl -n "$ns" rollout restart "deployment/${K8S_MCP_NAME}" >/dev/null \
            || die "could not restart the MCP server onto ${reach}"
        k8s_kubectl -n "$ns" rollout status "deployment/${K8S_MCP_NAME}" --timeout=300s >&2 \
            || die "the MCP server did not become ready; see: kubectl -n ${ns} describe pod -l app=${K8S_MCP_NAME}"
    fi
    # A callback no longer configured keeps no way out.
    if [ -z "${K8S_MCP_CALLBACK_IP:-}" ]; then
        k8s_kubectl -n "$ns" delete networkpolicy "${K8S_MCP_NAME}-callback" --ignore-not-found >/dev/null \
            || err "could not remove the server's old callback egress: the cluster did not answer"
    fi
    # On the user's network when the config asks (an Ingress on the pages' class and
    # certificate); its removal when it no longer does.
    if [ "$expose" = ingress ]; then
        k8s_render_mcp_expose | k8s_kubectl apply -f - >/dev/null \
            || die "the cluster did not take the server's Ingress at $(k8s_mcp_host)"
    else
        k8s_kubectl -n "$ns" delete ingress "$K8S_MCP_NAME" --ignore-not-found >/dev/null \
            || err "could not remove the server's Ingress (mcp.kubernetes.expose is off): the cluster did not answer"
    fi
    mcp_token_write_local "$tok" || die "could not write ${TOKEN_FILE}"
    info "token: ${TOKEN_FILE} (mode 0600)"
    mcp_status
}

mcp_stop() {
    local state rc=0
    state=$(mcp_state) || rc=$?
    [ "$rc" = 0 ] || die "cannot tell whether your MCP server runs: ${state}"
    if [ "$state" = "NOT RUNNING" ]; then
        info "your MCP server is not running"
        return 0
    fi
    # The Service stays: sessions' policy sidecars hold its address for the taint webhook.
    info "stopping your MCP server in ${ns} (its state, token, Service and transcripts are kept)"
    k8s_deployment_stop "$ns" "$K8S_MCP_NAME" ingress || die "could not stop the MCP server"
}

mcp_status() {
    local state rc=0 last why used host
    state=$(mcp_state) || rc=$?
    printf 'aidc-mcp (kubernetes, %s): %s\n' "$ns" "$state"
    [ "$rc" = 0 ] || return 0
    printf '  token file:  %s (from Secret %s)\n' "$TOKEN_FILE" "$K8S_MCP_TOKEN_SECRET"
    printf '  state:       claim %s\n' "$K8S_MCP_STATE_CLAIM"
    [ "$state" = "NOT RUNNING" ] && return 0
    printf '  in cluster:  http://%s.%s.svc:%s/mcp (from any namespace but %s)\n' \
        "$K8S_MCP_NAME" "$ns" "$K8S_MCP_PORT" "$ns"
    if host=$(k8s_get "$ns" ingress "$K8S_MCP_NAME" -o 'jsonpath={.spec.rules[0].host}'); then
        [ -z "$host" ] || printf '  network:     https://%s/mcp\n' "$(printf '%s' "$host" | aidc_printable)"
    fi
    if [ "$state" = STARTING ]; then
        # Not ready: a pod still starting, or one that cannot (an image not built yet, a crash).
        why=$(k8s_get "$ns" pod -l "app=${K8S_MCP_NAME}" \
            -o 'jsonpath={range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{" "}{end}' 2>/dev/null || true)
        why=$(printf '%s' "$why" | tr -s ' ' | sed 's/^ //; s/ $//' | aidc_printable)
        [ -z "$why" ] || printf '  waiting:     %s (see: aidc mcp logs)\n' "$why"
        return 0
    fi
    [ "$state" = RUNNING ] || return 0
    # The store and the access log share the claim; a full claim stops delivery, not only logging.
    if used=$(k8s_kubectl -n "$ns" exec "deployment/${K8S_MCP_NAME}" -c mcp -- df -P "$K8S_MCP_STATE_DIR" </dev/null 2>/dev/null); then
        used=$(printf '%s\n' "$used" | awk 'NR == 2 { sub("%", "", $5); print $5 }')
        case "$used" in
            ''|*[!0-9]*) ;;
            *) if [ "$used" -ge 80 ]; then
                   printf '  state claim: %s%% used (WARNING: a full claim stops replies; raise kubernetes.mcp_state_size)\n' "$used"
               else
                   printf '  state claim: %s%% used\n' "$used"
               fi ;;
        esac
    fi
    if last=$(k8s_kubectl -n "$ns" exec "deployment/${K8S_MCP_NAME}" -c mcp -- tail -n1 "${K8S_MCP_STATE_DIR}/access.log" </dev/null 2>/dev/null); then
        [ -z "$last" ] || printf '  last event:  %s\n' "$(printf '%s' "$last" | head -c 200 | aidc_printable)"
    fi
}

mcp_logs() { k8s_deployment_logs "$ns" "$K8S_MCP_NAME" mcp "${1:-}"; }

mcp_token() {
    local tok rc=0
    case "${1:-}" in
        rotate)
            tok=$(mcp_token_new)
            [ "${#tok}" -ge 40 ] || die "cannot make a token"
            k8s_kubectl -n "$ns" delete secret "$K8S_MCP_TOKEN_SECRET" --ignore-not-found >/dev/null \
                || die "could not remove the old token: the cluster did not answer (nothing changed)"
            k8s_render_mcp_token "$tok" | k8s_kubectl create -f - >/dev/null \
                || die "the old token is gone but the cluster did not take the new one: run aidc mcp token rotate again"
            mcp_token_write_local "$tok" || die "could not write ${TOKEN_FILE}"
            info "wrote the new token to ${TOKEN_FILE}"
            if [ "$(mcp_state 2>/dev/null || true)" != "NOT RUNNING" ]; then
                info "restarting your MCP server to take the new token"
                k8s_kubectl -n "$ns" rollout restart "deployment/${K8S_MCP_NAME}" >/dev/null \
                    || die "could not restart the MCP server: it takes the new token within a minute, from its Secret"
                k8s_kubectl -n "$ns" rollout status "deployment/${K8S_MCP_NAME}" --timeout=300s >&2 \
                    || err "the MCP server did not come back ready; see: aidc mcp logs"
            fi
            printf '%s\n' "$tok"
            ;;
        show)
            tok=$(mcp_token_read) || rc=$?
            [ "$rc" = 0 ] || die "cannot read your MCP token in ${ns}: the cluster did not answer"
            [ -n "$tok" ] || die "no MCP token in ${ns}: run 'aidc mcp start' first"
            printf '%s\n' "$tok"
            ;;
        ""|help|-h|--help)
            printf 'aidc mcp token rotate   - a new token, the server restarted, the token printed\n'
            printf 'aidc mcp token show     - print the current token\n' ;;
        *) die "unknown 'aidc mcp token' verb: ${1}" ;;
    esac
}

VERB="${1:-}"
shift || true
case "$VERB" in ""|help|-h|--help) usage; exit 0 ;; esac
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
case "$VERB" in
    start)  mcp_start "$@" ;;
    stop)   mcp_stop "$@" ;;
    status) mcp_status "$@" ;;
    logs)   mcp_logs "$@" ;;
    token)  mcp_token "$@" ;;
    *) err "unknown 'aidc mcp' verb: ${VERB} (try: aidc mcp help)"; exit 2 ;;
esac
