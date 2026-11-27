#!/usr/bin/env bash
# aidc create <name> --backend kubernetes [--profile P]: a session in the cluster.
#
# The session lives in the user's namespace (scripts/k8s/manifests.sh, k8s_render_session):
# its proxy pod first, then, once the proxy's Service has an address, the dev pod. It sees the
# user's whole disk and starts in the current directory's place on it, at the same path as on
# the user's Linux machines: a path under this machine's home directory maps to
# /home/<user>/..., so a Mac's /Users/<name>/x and a Linux /home/<name>/x name the same folder
# and the same Claude history.
#
# No --repo: aidc does not hand a session a repo here. Repos are added with `aidc repo add`
# (the git container clones them onto the user's disk), and a session that works on one makes
# its own worktree and branch in it (owner ruling 2026-11-24).

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=net.sh
. "$AIDC_SCRIPTS/k8s/net.sh"
# shellcheck source=tunnel.sh
. "$AIDC_SCRIPTS/k8s/tunnel.sh"
# shellcheck source=expose.sh
. "$AIDC_SCRIPTS/k8s/expose.sh"
# shellcheck source=broker.sh
. "$AIDC_SCRIPTS/k8s/broker.sh"
# shellcheck source=../lib/claude-state.sh
. "$AIDC_SCRIPTS/lib/claude-state.sh"

usage() {
    cat <<'USAGE'
aidc create <name> --backend kubernetes [--profile P] [--cpu N] [--memory Q]
                                         [--cpu-limit N] [--memory-limit Q] [--gpu]
                                         [--port H:C ...] [--expose PORT ... [--login]]
                                         [--egress-tcp HOST:PORT ...] [--dns IP ...]
                                         [--network NAMESPACE ...]

Starts a session in the cluster of the `kubernetes:` config, on your disk there
(`aidc user add` makes it). The session sees your whole disk and starts in the current
directory's place on it (made when missing). It takes no --repo: add repos with
`aidc repo add`, and the session makes its own worktree and branch in one with
`git worktree add`. P is the toolchain profile (default: the config's, else multi).

Size: --cpu and --memory are what the session is guaranteed (default: the config's
kubernetes.cpu and .memory, else 2 and 8Gi); --cpu-limit and --memory-limit what it may
use when the node has room (kubernetes.cpu_limit and .memory_limit, else 16 and 32Gi).
CPU as 2, 1.5 or 500m; memory as 8Gi or 512Mi. A request above the configured limit
raises the limit to it, unless a limit is given too. --gpu gives the session one GPU.

Ports (merged with the config's ports:):
  --port H:C       a tunnel from localhost:H on this machine to the session's port C (N for
                   N:N), kept up by a local process (aidc proxy <name> ls|rm|up).
  --expose PORT    the port as a page on your network at <name>-<user>.<domain> (further
                   ports: <name>-<port>-<user>.<domain>); the domain, ingress class and
                   certificate come from kubernetes.ingress in your config.
  --login          put a generated username and password (printed once) in front of the
                   exposed pages. Without it they have no login.
Ways out besides squid:
  --egress-tcp HOST:PORT  a relay to one TCP destination (merged with egress_tcp:); the
                   session connects to HOST:PORT by its real name. Live: aidc egress.
  --dns IP         squid resolves through these servers instead of Quad9 (at most 3;
                   overrides dns_servers:).
  --network NS     the session may reach every pod of namespace NS on any port, and its
                   Services by name (<svc>.NS); merged with networks:. This widens the
                   sandbox: that traffic does not pass squid. Live: aidc network.
USAGE
}

NAME="" PROFILE_OVERRIDE="" CPU="" MEMORY="" CPU_LIMIT="" MEMORY_LIMIT="" GPU=0 LOGIN=0
PORT_FLAGS=() EXPOSE_FLAGS=() EGRESS_TCP_FLAGS=() DNS_FLAGS=() NETWORK_FLAGS=()
# need_value <flag> <value>: a flag's value, not missing and not the next flag.
need_value() { case "${2:-}" in ""|-*) die "$1 needs a value" ;; esac; }
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --cpu|--memory|--cpu-limit|--memory-limit)
            need_value "$1" "${2:-}"
            case "$1" in --cpu) CPU="$2" ;; --memory) MEMORY="$2" ;; --cpu-limit) CPU_LIMIT="$2" ;; --memory-limit) MEMORY_LIMIT="$2" ;; esac
            shift 2 ;;
        --cpu=*) CPU="${1#*=}"; shift ;;
        --memory=*) MEMORY="${1#*=}"; shift ;;
        --cpu-limit=*) CPU_LIMIT="${1#*=}"; shift ;;
        --memory-limit=*) MEMORY_LIMIT="${1#*=}"; shift ;;
        --repo|--repo=*)
            die "--repo is not used on the kubernetes backend: the session sees your whole disk. Add the repo with \`aidc repo add <owner/name>\`; the session makes its own worktree and branch in it (git worktree add)" ;;
        --port|--expose|--egress-tcp|--dns|--network)
            need_value "$1" "${2:-}"
            case "$1" in
                --port) PORT_FLAGS+=("$2") ;; --expose) EXPOSE_FLAGS+=("$2") ;;
                --egress-tcp) EGRESS_TCP_FLAGS+=("$2") ;; --dns) DNS_FLAGS+=("$2") ;;
                --network) NETWORK_FLAGS+=("$2") ;;
            esac
            shift 2 ;;
        --port=*) PORT_FLAGS+=("${1#*=}"); shift ;;
        --expose=*) EXPOSE_FLAGS+=("${1#*=}"); shift ;;
        --egress-tcp=*) EGRESS_TCP_FLAGS+=("${1#*=}"); shift ;;
        --dns=*) DNS_FLAGS+=("${1#*=}"); shift ;;
        --network=*) NETWORK_FLAGS+=("${1#*=}"); shift ;;
        --gpu) GPU=1; shift ;;
        --login) LOGIN=1; shift ;;
        --profile) PROFILE_OVERRIDE="${2:-}"; shift 2 ;;
        --profile=*) PROFILE_OVERRIDE="${1#--profile=}"; shift ;;
        -*) die "not supported on the kubernetes backend yet: $1" ;;
        *) [ -z "$NAME" ] || die "one session name only (got: $NAME and $1)"; NAME="$1"; shift ;;
    esac
done
validate_session_name "$NAME"
! k8s_is_git_session "$NAME" || die "'git' is reserved for your git agent (aidc git setup); pick another session name"
# The user's MCP server is served at mcp-<user>.<domain> (scripts/k8s/mcp.sh), a page name a
# session named mcp would take.
[ "$NAME" != mcp ] || die "'mcp' is reserved on the kubernetes backend: your MCP server's network name is mcp-${AIDC_K8S_USER:-<user>}.<domain>; pick another session name"
# Stricter than Docker's names: a Kubernetes Service name must start with a letter, and a label
# value must end with a letter or digit. Checked before anything is created, so a refused name
# leaves nothing behind.
printf '%s' "$NAME" | grep -Eq '^[a-z]([a-z0-9-]*[a-z0-9])?$' \
    || die "on the kubernetes backend a session name starts with a letter and ends with a letter or digit: ${NAME}"
k8s_require || exit 1
# The user's config, and the repo's own .aidc/config.yaml as cmd-create.sh reads it (load_config
# also reports the repo settings it refused: SEC-09). Read from the repo on this machine when it
# is here; the cluster copy is not readable from here.
load_config "$PWD" "$PWD"
aidc_report_repo_requests
PROFILE="${PROFILE_OVERRIDE:-${AIDC_PROFILE:-multi}}"
# The size: flags over the config (k8s_require loaded it). A request above the configured limit
# with no limit given raises the limit to it: asking for more than the default ceiling means
# wanting it.
size_flag() { # <flag> <value> <request var> <limit var> <limit flag value> <fn>
    local v="$2" q l
    [ -n "$v" ] || return 0
    printf -v "$3" '%s' "$v"
    if [ -z "$5" ] && q=$("$6" "$v") && l=$("$6" "${!4}") && awk -v a="$q" -v b="$l" 'BEGIN { exit !(a > b) }'; then
        info "$1 ${v} is above the configured limit ${!4}: the limit is ${v} too"
        printf -v "$4" '%s' "$v"
    fi
}
[ -z "$CPU_LIMIT" ] || AIDC_K8S_CPU_LIMIT="$CPU_LIMIT"
[ -z "$MEMORY_LIMIT" ] || AIDC_K8S_MEMORY_LIMIT="$MEMORY_LIMIT"
size_flag --cpu "$CPU" AIDC_K8S_CPU_REQUEST AIDC_K8S_CPU_LIMIT "$CPU_LIMIT" k8s_cpu_milli
size_flag --memory "$MEMORY" AIDC_K8S_MEMORY_REQUEST AIDC_K8S_MEMORY_LIMIT "$MEMORY_LIMIT" k8s_memory_bytes
k8s_check_size || exit 1

# Everything below is checked before anything is made: a typo costs a message, not a half-made
# session.
# Ports: the flags, then the config's ports: (first wins on a host port), as on Docker.
AIDC_K8S_PORTS=""
_seen=" "
for _spec in ${PORT_FLAGS[@]+"${PORT_FLAGS[@]}"} ${AIDC_PORTS:-}; do
    _hc=$(k8s_port_spec "$_spec") || die "invalid --port/ports: entry: ${_spec}"
    case "$_seen" in *" ${_hc%% *} "*) continue ;; esac
    _seen="${_seen}${_hc%% *} "
    AIDC_K8S_PORTS="${AIDC_K8S_PORTS:+${AIDC_K8S_PORTS},}${_hc% *}:${_hc#* }"
done
# Pages (K8S-15): ports, deduped in order; the config must name the domain and the ingress.
EXPOSE_PORTS=""
for _p in ${EXPOSE_FLAGS[@]+"${EXPOSE_FLAGS[@]}"}; do
    k8s_port_ok "$_p" || die "invalid --expose port: ${_p} (1-65535)"
    case " ${EXPOSE_PORTS} " in *" ${_p} "*) ;; *) EXPOSE_PORTS="${EXPOSE_PORTS:+${EXPOSE_PORTS} }${_p}" ;; esac
done
if [ "$LOGIN" = 1 ] && [ -z "$EXPOSE_PORTS" ]; then die "--login puts a login in front of an exposed page: give --expose <port> too"; fi
if [ -n "$EXPOSE_PORTS" ]; then
    # shellcheck disable=SC2086  # one port per word
    k8s_expose_check "$NAME" "$LOGIN" $EXPOSE_PORTS || exit 2
fi
# DNS: the flags override the config's dns_servers:, as on Docker. A Kubernetes pod takes at most
# three nameservers, and each needs a /32 egress rule, so IPv4 addresses only.
AIDC_K8S_DNS_SERVERS=""
if [ "${#DNS_FLAGS[@]}" -gt 0 ]; then _dns="${DNS_FLAGS[*]}"; else _dns=$(printf '%s' "${AIDC_DNS_SERVERS:-}" | tr '\n' ' '); fi
for _d in $_dns; do
    aidc_egress_is_ipv4 "$_d" || die "invalid DNS server: ${_d} (an IPv4 address on the kubernetes backend)"
    case " ${AIDC_K8S_DNS_SERVERS} " in *" ${_d} "*) ;; *) AIDC_K8S_DNS_SERVERS="${AIDC_K8S_DNS_SERVERS:+${AIDC_K8S_DNS_SERVERS} }${_d}" ;; esac
done
[ "$(printf '%s' "$AIDC_K8S_DNS_SERVERS" | wc -w)" -le 3 ] || die "at most 3 DNS servers on the kubernetes backend (a pod takes three): ${AIDC_K8S_DNS_SERVERS}"
# Networks (NET-13's cluster form): namespaces, flags then networks:.
NETWORKS=""
for _n in ${NETWORK_FLAGS[@]+"${NETWORK_FLAGS[@]}"} ${AIDC_NETWORKS:-}; do
    if _why=$(k8s_network_refusal "$_n"); then die "refusing --network ${_n}: ${_why}"; fi
    if _why=$(k8s_network_ungranted "$_n"); then die "refusing --network ${_n}: ${_why}"; fi
    case " ${NETWORKS} " in *" ${_n} "*) ;; *) NETWORKS="${NETWORKS:+${NETWORKS} }${_n}" ;; esac
done
# TCP egress (NET-15): flags then egress_tcp:, resolved here on this machine, as on Docker.
EGRESS_LINES=""
for _spec in ${EGRESS_TCP_FLAGS[@]+"${EGRESS_TCP_FLAGS[@]}"} ${AIDC_EGRESS_TCP:-}; do
    aidc_egress_parse "$_spec" || die "invalid --egress-tcp/egress_tcp entry: ${_spec}"
    _ip=$(aidc_egress_resolve_explained "$AIDC_EGRESS_HOST") || die "egress: ${AIDC_EGRESS_HOST} has no address to relay to"
    if _why=$(aidc_egress_refusal "$_ip" "$AIDC_EGRESS_PORT" ""); then die "refusing ${_spec}: ${_why}"; fi
    EGRESS_LINES="${EGRESS_LINES}${AIDC_EGRESS_HOST} ${AIDC_EGRESS_PORT} ${_ip}
"
done
[ -z "$EGRESS_LINES" ] || EGRESS_LINES=$(printf '%s' "$EGRESS_LINES" | aidc_egress_group)
AIDC_K8S_GPU="$GPU"
export AIDC_K8S_PORTS AIDC_K8S_DNS_SERVERS AIDC_K8S_GPU
unset _seen _spec _hc _p _dns _d _n _why _ip

REPO_PATH=$(k8s_cluster_repo_path "$PWD") \
    || die "run aidc create from under your home directory (${HOME}) or /home/${AIDC_K8S_USER}: the session starts at the same place on your disk (got ${PWD})"
case "$REPO_PATH" in *[\"\\]*|*$'\n'*) die "the repo path may not contain quotes, backslashes or newlines" ;; esac

ns=$(k8s_user_ns "$AIDC_K8S_USER")
# Each read below tells "not there" (an empty answer) from "the cluster did not answer" (kubectl
# failed): only the first is a fact about the user's namespace.
# k8s_read <what> <kubectl get args...>: the answer (lib.sh's k8s_get), or dies saying the
# cluster did not answer.
k8s_read() {
    local what="$1" out
    shift
    out=$(k8s_get "$ns" "$@") || die "cannot read ${what} in ${ns}: the cluster did not answer (${out})"
    printf '%s' "$out"
}
phase=$(k8s_read "your disk" pvc disk -o jsonpath='{.status.phase}')
case "$phase" in
    Bound) ;;
    "") die "no disk for ${AIDC_K8S_USER} in the cluster: run \`aidc user add ${AIDC_K8S_USER}\` first" ;;
    *) die "your disk in ${ns} is ${phase}, not Bound yet: see kubectl -n ${ns} describe pvc disk" ;;
esac
# The namespace's default-deny is half of every session's lockdown (its pods' own policies are
# the other half). A namespace made before aidc added it lacks it: say so rather than run there.
# Assigned, not tested inline: a die inside $(...) ends only the subshell; set -e ends the
# script on a failed assignment.
deny=$(k8s_read "the default-deny NetworkPolicy" networkpolicy default-deny -o name)
[ -n "$deny" ] \
    || die "${ns} has no default-deny NetworkPolicy: run \`aidc user add ${AIDC_K8S_USER}\` again (it is safe to repeat)"
existing=$(k8s_read "session '${NAME}'" deployment "${NAME}-proxy" -o name)
if [ -n "$existing" ]; then
    die "session '${NAME}' already exists (aidc kill ${NAME} --backend kubernetes)"
fi

# A session of this name killed moments ago may still have its claims, being deleted: applying
# the new session's claims then changes nothing, and its pods wait for claims that go away.
leftover=$(k8s_read "session '${NAME}''s claims" pvc "${NAME}-home" "${NAME}-state" -o name)
[ -z "$leftover" ] \
    || die "the claims of an earlier session '${NAME}' are still there (being removed after aidc kill, or left by one that stopped half way): wait a minute, or aidc clean-env ${NAME}"
# A page name another Ingress already serves would be shared with it.
first=1
for _p in $EXPOSE_PORTS; do
    _h=$(k8s_expose_host "$NAME" "$_p" "$first"); first=0
    if taken=$(k8s_expose_taken "$ns" "$_h"); then
        die "the page name ${_h} is already served by ingress ${taken}: pick another session name"
    fi
done

sel=$(k8s_node_selector) || exit 1
# The session's own token (gh stand-in requests carry it; aidc git mode keys on it), made once
# here: the session is rendered twice below and both must carry the same one.
AIDC_K8S_GIT_TOKEN=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
[[ "$AIDC_K8S_GIT_TOKEN" =~ ^[0-9a-f]{64}$ ]] || die "cannot make the session's token"
# The session's git identity, as on Docker (cmd-create.sh): the user's own name and email from
# this machine's git config, so the commits the git container pushes for it show as the user.
# A value with a control character is not taken (it would end up in the session's .gitconfig).
AIDC_K8S_GIT_USER_NAME=$(git config --get user.name 2>/dev/null || true)
AIDC_K8S_GIT_USER_EMAIL=$(git config --get user.email 2>/dev/null || true)
if [ "$(printf '%s%s' "$AIDC_K8S_GIT_USER_NAME" "$AIDC_K8S_GIT_USER_EMAIL" | LC_ALL=C tr -d -c '\000-\037\177' | wc -c)" != 0 ]; then
    AIDC_K8S_GIT_USER_NAME="" AIDC_K8S_GIT_USER_EMAIL=""
fi
if [ -n "$AIDC_K8S_GIT_USER_NAME" ] && [ -n "$AIDC_K8S_GIT_USER_EMAIL" ]; then
    info "git identity: ${AIDC_K8S_GIT_USER_NAME} <${AIDC_K8S_GIT_USER_EMAIL}>"
else
    AIDC_K8S_GIT_USER_NAME="" AIDC_K8S_GIT_USER_EMAIL=""
    info "git identity: NOT bridged (set this machine's git config --global user.name and user.email; for a session your MCP server made, set them in the session)"
fi
AUDIT_CLAIM="${NAME}-audit-$(date -u +%Y%m%d%H%M%S)"
info "creating session ${NAME} in ${ns} (repo ${REPO_PATH}, profile ${PROFILE}, audit ${AUDIT_CLAIM})"
info "config: ${AIDC_CONFIG_SOURCES:-none found (defaults)}"
info "  profile=${PROFILE} taint_response=${AIDC_TAINT_RESPONSE} claude_mode=${AIDC_CLAUDE_MODE}"
info "  size: ${AIDC_K8S_CPU_REQUEST} CPU / ${AIDC_K8S_MEMORY_REQUEST} guaranteed, up to ${AIDC_K8S_CPU_LIMIT} / ${AIDC_K8S_MEMORY_LIMIT}"
[ "$GPU" = 1 ] && info "  gpu: one (nvidia.com/gpu)"
[ -z "$AIDC_K8S_DNS_SERVERS" ] || info "  dns: ${AIDC_K8S_DNS_SERVERS} (squid resolves through these instead of Quad9)"

# The audit record's first files, as cmd-create.sh writes them on Docker; the proxy pod copies
# them onto the audit claim before anything else runs.
seed=$(mktemp -d)
trap 'rm -rf "$seed"' EXIT
emit_loaded_config_yaml > "${seed}/config-snapshot.yaml"
jq -n --arg session "$NAME" --arg profile "$PROFILE" --arg repo "$REPO_PATH" \
    --arg created "$(date -u +%FT%TZ)" --arg taint "$AIDC_TAINT_RESPONSE" \
    --arg ns "$ns" --arg claim "$AUDIT_CLAIM" \
    '{session:$session, profile:$profile, repo:$repo, created_at:$created, taint_response:$taint,
      backend:"kubernetes", namespace:$ns, audit_claim:$claim}' > "${seed}/meta.json"
# The session's first ~/.claude.json, as on Docker (cmd-create.sh): this machine's, minus its
# account and every other project's state (lib/claude-state.sh), else empty; onboarding done
# and the session's start folder trusted (owner ruling 2026-11-27), so its first launch goes
# straight to the prompt. The dev pod's claude-seed step installs it while the session's
# Claude config dir has no .claude.json yet.
host_state="$(aidc_host_home)/.claude.json"
state_seed='{}'
if [ -f "$host_state" ]; then
    if state_seed=$(aidc_claude_state_seed "$host_state" "$REPO_PATH" "$REPO_PATH"); then
        info "state: seeded from this machine's ~/.claude.json (onboarding; no account)"
    else
        state_seed='{}'
        info "state: could not read this machine's ~/.claude.json (onboarding marked done only)"
    fi
fi
( umask 0077; printf '%s' "$state_seed" | aidc_claude_state_ready "$REPO_PATH" > "${seed}/${K8S_CLAUDE_STATE_SEED}" ) \
    || die "cannot write the session's Claude state seed"
k8s_kubectl -n "$ns" create configmap "${NAME}-audit-seed" --from-file="${seed}/meta.json" \
    --from-file="${seed}/config-snapshot.yaml" --from-file="${seed}/${K8S_CLAUDE_STATE_SEED}" \
    --dry-run=client -o yaml \
    | yq '.metadata.labels = {"app.kubernetes.io/managed-by": "aidc", "aidc/session": "'"${NAME}"'"}' \
    | k8s_kubectl apply -f - >&2
# The session's transcripts and hook events reach the user's MCP server through the mirror claim.
k8s_ensure_transcripts "$ns" || exit 1
# Its Claude config dir is its folder of the user's claude-config claim (the proxy pod's first
# step makes it; the account broker writes its credentials there).
k8s_ensure_claude_config "$ns" || exit 1
# Its policy sidecar pokes the user's MCP server when it is tainted (W-M4): at the server's
# Service address, made now when missing so it is stable whether or not the server runs yet.
AIDC_K8S_TAINT_WEBHOOK_IP=$(k8s_mcp_service_ip "$ns") || exit 1
export AIDC_K8S_TAINT_WEBHOOK_IP
k8s_render_session "$NAME" "$REPO_PATH" "$PROFILE" "$sel" "$AUDIT_CLAIM" | k8s_kubectl apply -f - >&2
# Not there yet is asked again; a read that fails is "the cluster did not answer" (k8s_read).
proxy_ip=""
for _ in $(seq 30); do
    proxy_ip=$(k8s_read "the proxy Service's address" service "${NAME}-proxy" -o jsonpath='{.spec.clusterIP}')
    [ -n "$proxy_ip" ] && break
    sleep 1
done
[ -n "$proxy_ip" ] || die "the proxy Service has no address"
info "waiting for the proxy (squid, blocklist, policy, audit)"
k8s_kubectl -n "$ns" rollout status "deployment/${NAME}-proxy" --timeout=300s >&2 \
    || die "the proxy did not become ready; see: kubectl -n ${ns} describe pod -l aidc/session=${NAME},app=proxy"
# The ways out besides squid, before the dev pod starts: relays (NET-15), namespaces
# (--network), and their names in the session's names responder.
if [ -n "$EGRESS_LINES" ]; then
    while read -r _host _ip _ports; do
        [ -n "$_host" ] || continue
        # shellcheck disable=SC2086  # one port per word
        k8s_render_relay "$NAME" "$_host" "$_ip" declared "$AUDIT_CLAIM" "$sel" $_ports | k8s_kubectl apply -f - >&2
        info "egress_tcp: $(k8s_relay_reach_as "$NAME" "$_host") port(s) ${_ports} -> ${_ip} (each connection logged to the audit trail)"
    done <<<"$EGRESS_LINES"
fi
for _n in $NETWORKS; do
    k8s_render_network "$NAME" "$_n" | k8s_kubectl apply -f - >&2
    info "network: ${_n}: every pod there, any port, and its Services by name (<svc>.${_n})"
    info "  NOT proxied by squid and NOT visible to taint detection: a deliberate widening"
done
if [ -n "$EGRESS_LINES" ] || [ -n "$NETWORKS" ]; then
    k8s_names_sync "$ns" "$NAME" || die "the session's names could not be written; aidc kill ${NAME} and create it again"
fi
# The active account's credentials before the session's Claude starts, so it starts logged in;
# with no broker, the long-lived token when this machine has one (the stopgap until a broker).
# The token is a file on the user's own machine: the user's MCP server never hands one on.
K8S_CLAUDE_QUIET_NONE=1
{ [ -f "${HOME}/.config/aidc/claude-oauth-token" ] && [ -z "${AIDC_MCP_BACKEND:-}" ]; } || K8S_CLAUDE_QUIET_NONE=0
k8s_claude_session_ready "$ns" "$NAME" || exit 1
if [ "$K8S_CLAUDE_VIA" = none ] && [ "$K8S_CLAUDE_QUIET_NONE" = 1 ]; then
    k8s_claude_token_secret "$ns" "$NAME" || exit 1
fi
k8s_render_session "$NAME" "$REPO_PATH" "$PROFILE" "$sel" "$AUDIT_CLAIM" "$proxy_ip" | k8s_kubectl apply -f - >&2
info "waiting for the dev pod to be ready"
pod="${NAME}-dev-0"
# A new session has no old pod: any dev pod that is not being deleted and says it is ready
# (k8s_wait_dev_ready says where to look when it does not).
k8s_wait_dev_ready "$ns" "$NAME" "" "${AIDC_K8S_READY_WAIT:-600}" \
    || die "the dev pod did not report ready; its log: kubectl -n ${ns} logs ${pod} -c dev"
info "session ${NAME} is ready"
# Pages on the network (K8S-15): the login, when asked for, is made here and printed once.
EXPOSE_FAILED=0
if [ -n "$EXPOSE_PORTS" ]; then
    htpasswd="" login_user="" login_pw=""
    if [ "$LOGIN" = 1 ]; then
        login_user="u$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
        login_pw=$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')
        htpasswd=$(k8s_htpasswd_line "$login_user" "$login_pw") || die "cannot hash the login's password"
    fi
    # The login first, so no page is ever served without it: made with create (a user may make
    # and delete Secrets, not read them), after removing any a half-made session left.
    if [ -n "$htpasswd" ]; then
        k8s_expose_login_remove "$ns" "$NAME" || die "cannot remove an earlier login of ${NAME}: the cluster did not answer"
        k8s_render_expose_login "$NAME" "$htpasswd" | k8s_kubectl create -f - >&2 \
            || die "the cluster did not take the login for ${NAME}'s pages: no page was made (the session runs; aidc kill ${NAME} removes it)"
    fi
    # shellcheck disable=SC2086  # one port per word
    k8s_render_expose "$NAME" "$htpasswd" $EXPOSE_PORTS | k8s_kubectl apply -f - >&2
    # A login asked for is checked, not assumed: each page is opened once without it and must
    # answer 401. One that does not is removed again, the session kept, and create fails.
    if [ "$LOGIN" = 1 ]; then
        info "checking each page asks for the login"
        # shellcheck disable=SC2086  # one port per word
        if ! unlocked=$(k8s_expose_login_probe "$ns" "$NAME" $EXPOSE_PORTS); then
            k8s_expose_remove "$ns" "$NAME" || true
            while read -r _h _code; do
                [ -n "$_h" ] || continue
                err "https://${_h}/ answered ${_code} without the login, not 401 (000: no answer reached this machine)"
            done <<<"$unlocked"
            err "the pages were REMOVED: the ingress controller did not put the login in front of them"
            err "  (kubernetes.ingress.controller is ${AIDC_K8S_INGRESS_CONTROLLER}; is IngressClass ${AIDC_K8S_INGRESS_CLASS} really that controller, and does this machine resolve and reach the domain?)"
            EXPOSE_FAILED=1
        fi
    fi
    if [ "$EXPOSE_FAILED" != 1 ]; then
        first=1
        for _p in $EXPOSE_PORTS; do
            info "page: https://$(k8s_expose_host "$NAME" "$_p" "$first")/ -> ${NAME}:${_p}"; first=0
        done
        if [ "$LOGIN" = 1 ]; then
            info "login for these pages (shown once, kept only as a hash): user ${login_user}  password ${login_pw}"
        else
            info "  no login: anyone on your network can open these pages"
        fi
    fi
fi
# Tunnels (K8S-14) to this machine.
if [ -n "$AIDC_K8S_PORTS" ]; then
    for _spec in $(printf '%s' "$AIDC_K8S_PORTS" | tr ',' ' '); do
        if k8s_tunnel_start "$ns" "$NAME" "${_spec%%:*}" "${_spec##*:}"; then
            info "tunnel: localhost:${_spec%%:*} -> ${NAME}:${_spec##*:} (aidc proxy ${NAME} ls)"
        else
            info "WARNING: the tunnel on localhost:${_spec%%:*} did not start; aidc proxy ${NAME} add ${_spec}"
        fi
    done
fi
# The git container keys this session's git mode on its token (the user's mode until
# aidc git mode gives it its own; a session made again under an old name starts afresh).
if gpod=$(k8s_git_pod "$ns" 2>/dev/null) \
        && printf '%s\n' "$AIDC_K8S_GIT_TOKEN" | k8s_kubectl -n "$ns" exec -i "$gpod" -c gitreq -- git-requests register "$NAME" >/dev/null 2>&1; then
    info "git container: session ${NAME} registered (your git mode applies to it)"
else
    info "git container: not running, so ${NAME} is not registered yet: its requests wait for your approval until aidc git setup"
fi
info "attach: aidc attach ${NAME} --backend kubernetes (or: kubectl -n ${ns} exec -it ${pod} -c dev -- sudo -u vscode tmux attach -t main)"
if [ "$EXPOSE_FAILED" = 1 ]; then
    err "session ${NAME} runs, but WITHOUT its pages: the login could not be confirmed (see above)"
    exit 1
fi
