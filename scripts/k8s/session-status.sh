#!/usr/bin/env bash
# aidc status <name> (a Kubernetes session): its pods, taint, repo, egress and audit.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=../lib/feeds.sh
. "$AIDC_SCRIPTS/lib/feeds.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=net.sh
. "$AIDC_SCRIPTS/k8s/net.sh"
# shellcheck source=tunnel.sh
. "$AIDC_SCRIPTS/k8s/tunnel.sh"
# shellcheck source=expose.sh
. "$AIDC_SCRIPTS/k8s/expose.sh"
case "${1:-}" in -h|--help) printf 'aidc status <name>\n'; exit 0 ;; esac
NAME="${1:-}"
validate_session_name "$NAME"
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
if k8s_is_git_session "$NAME"; then
    printf 'session:  %s (your git agent: the git container, kubernetes, namespace %s)\n' "$NAME" "$ns"
    AIDC_GIT_BACKEND=kubernetes exec bash "$AIDC_SCRIPTS/git/git-status.sh"
fi
k8s_require_session "$ns" "$NAME"
sts=$(k8s_kubectl -n "$ns" get statefulset "${NAME}-dev" -o json) \
    || die "cannot read session '${NAME}': the cluster did not answer"
printf 'session:  %s (kubernetes, namespace %s)\n' "$NAME" "$ns"
printf 'repo:     %s\n' "$(printf '%s' "$sts" | yq -p=json '.metadata.annotations["aidc/repo"] // "?"')"
printf 'profile:  %s\n' "$(printf '%s' "$sts" | yq -p=json '.metadata.annotations["aidc/profile"] // "?"')"
printf 'size:     %s\n' "$(printf '%s' "$sts" | yq -p=json '.spec.template.spec.containers[] | select(.name == "dev") | .resources |
    ((.requests.cpu // "?") + " CPU / " + (.requests.memory // "?") + " guaranteed, up to " + (.limits.cpu // "?") + " / " + (.limits.memory // "?"))' 2>/dev/null || echo '?')"
printf 'gpu:      %s\n' "$(printf '%s' "$sts" | yq -p=json '.spec.template.spec.containers[] | select(.name == "dev") | .resources.limits["nvidia.com/gpu"] // "none"' 2>/dev/null || echo '?')"
printf 'pods:\n'
k8s_kubectl -n "$ns" get pods -l "aidc/session=${NAME}" --request-timeout=10s \
    -o custom-columns='  NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,NODE:.spec.nodeName,STARTED:.status.startTime' 2>/dev/null \
    || printf '  unknown (the cluster did not answer)\n'
taint=$(k8s_session_taint "$ns" "$NAME")
case "$taint" in
    yes*) printf 'taint:    TAINTED %s\n' "${taint#yes }" ;;
    no) printf 'taint:    clean\n' ;;
    *) printf 'taint:    %s\n' "$taint" ;;
esac
# The malware feeds behind the blocklist (#60), from the refresher's state file; a refresher that
# cannot be asked is unknown, never fine.
if ! proxy=$(k8s_get "$ns" pod -l "aidc/session=${NAME},app=proxy" -o name); then
    printf 'feeds:    unknown: the cluster did not answer (%s)\n' "$proxy"
elif proxy=$(printf '%s\n' "$proxy" | head -n1) && [ -n "$proxy" ] && fstate=$(k8s_kubectl -n "$ns" exec "$proxy" -c refresher --request-timeout=10s -- \
        sh -c 'cat /etc/squid/aidc-feeds.state 2>/dev/null; true' </dev/null 2>/dev/null); then
    aidc_feeds_describe "$fstate" "$(date +%s)" | sed '1s/^/feeds:    /; 2,$s/^/          /' || true
else
    printf 'feeds:    unknown: the refresher sidecar did not answer\n'
fi
# The lockdown is the session's NetworkPolicies: say so only when they are there, and "unknown"
# when the cluster cannot be asked (never NOT ENFORCED for a read that failed).
if have=$(k8s_kubectl -n "$ns" get networkpolicy -o name --request-timeout=10s 2>/dev/null); then
    have=$(printf '%s\n' "$have" | sed 's|.*/||' | sort | paste -sd' ' -)
    want="default-deny ${NAME}-dev-only-to-its-proxy ${NAME}-proxy-public-only"
    missing=""
    for p in $want; do case " $have " in *" $p "*) ;; *) missing="${missing} ${p}" ;; esac; done
    if [ -z "$missing" ]; then
        printf 'egress:   enforced: NetworkPolicy, dev pod -> its proxy only (and the relays and networks below), proxy -> public addresses only; no cluster DNS in the dev pod\n'
    else
        printf 'egress:   NOT ENFORCED: NetworkPolicy missing:%s\n' "$missing"
    fi
else
    printf 'egress:   unknown (the cluster did not answer)\n'
fi
# DNS: the proxy's own resolvers (squid resolves through them when they are not Quad9).
dns=$(k8s_get "$ns" deployment "${NAME}-proxy" -o jsonpath='{.spec.template.spec.dnsConfig.nameservers}' 2>/dev/null) || dns=""
case "$dns" in *9.9.9.9*|"") ;; *) printf 'dns:      %s (squid resolves through these instead of Quad9)\n' "$(printf '%s' "$dns" | tr -d '[]"' | tr ',' ' ')" ;; esac
# Ports: declared at create (tunnels on any machine with aidc proxy up) and this machine's tunnels.
printf 'ports:\n'
declared=$(printf '%s' "$sts" | yq -p=json '.metadata.annotations["aidc/ports"] // ""' | tr ',' ' ')
printf '  declared: %s\n' "${declared:-(none)}"
tunnels=$(k8s_tunnels "$ns" "$NAME")
if [ -n "$tunnels" ]; then
    while read -r h c pid; do
        if [ "$pid" = - ]; then st="NOT RUNNING (aidc proxy ${NAME} add ${h}:${c})"; else st="tunnel up (pid ${pid})"; fi
        printf '  localhost:%s -> %s:%s  %s\n' "$h" "$NAME" "$c" "$st"
    done <<<"$tunnels"
else
    printf '  tunnels on this machine: (none)\n'
fi
# Pages on the network (K8S-15).
if pages=$(k8s_exposed "$ns" "$NAME"); then
    if [ -n "$pages" ]; then
        printf 'pages:\n'
        while read -r p h l; do
            if [ "$l" = yes ]; then l="login"; else l="no login"; fi
            printf '  https://%s/ -> %s:%s (%s)\n' "$h" "$NAME" "$p" "$l"
        done <<<"$pages"
    fi
else
    printf 'pages:    unknown (the cluster did not answer)\n'
fi
# TCP egress relays and namespaces: the session's ways out besides squid.
relays=$(k8s_relays_describe "$ns" "$NAME")
if [ -n "$relays" ]; then printf 'tcp egress:\n'; printf '%s\n' "$relays" | sed 's/^/  /'; else printf 'tcp egress: (none)\n'; fi
if nets=$(k8s_networks "$ns" "$NAME"); then
    [ -z "$nets" ] || printf 'networks: %s (any port, NOT through squid)\n' "$(printf '%s' "$nets" | paste -sd' ' -)"
else
    printf 'networks: unknown (the cluster did not answer)\n'
fi
audit=$(printf '%s' "$sts" | yq -p=json '.metadata.annotations["aidc/audit"] // ""')
printf 'audit:    volume claim %s in %s (kept by aidc kill)\n' "${audit:-?}" "$ns"
