#!/usr/bin/env bash
# aidc network <session> add|rm|ls|sync (a Kubernetes session): another namespace's services, live.
#
# The cluster form of Docker's `aidc network` (NET-13): where Docker attaches the dev container to
# another stack's bridge, here the session's dev pod is let out to every pod of a namespace, on
# any port, by its own NetworkPolicy, and that namespace's Services resolve by name
# (<svc>.<namespace>[.svc[.cluster.local]]) through the session's names responder. Live: the dev
# pod keeps running. This widens the sandbox exactly as on Docker: that traffic does not pass
# squid and taint detection never sees it. The other namespace's own policies may still refuse
# it. aidc's own namespaces and the cluster's system namespaces are refused (k8s_network_refusal).

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=net.sh
. "$AIDC_SCRIPTS/k8s/net.sh"

usage() {
    cat <<'EOF'
aidc network <session> <subcommand> [args]     (kubernetes backend)

  add <namespace>   let the session reach every pod of the namespace, on any port, and
                    its Services by name (<svc>.<namespace>)
  rm  <namespace>   take it away again
  ls                the namespaces the session may reach
  sync              read those namespaces' Services again (add of one already given does too)

The Service names are read when the session is created and on each add, rm, sync and egress
change: a Service made in that namespace later resolves after the next sync. Its pods are
reachable by address at once.

This WIDENS THE SANDBOX: that traffic does not pass through squid and is invisible to
taint detection. Give the narrowest namespace that does the job. Changes are live.
EOF
}

NAME="${1:-}"
case "$NAME" in ''|-h|--help) usage; exit 0 ;; esac
shift
SUBVERB="${1:-}"
[ -n "$SUBVERB" ] || { usage >&2; exit 2; }
shift
validate_session_name "$NAME"
k8s_require || exit 1
k8s_is_git_session "$NAME" && die "git is your git agent (the git container), not a session with networks"
ns=$(k8s_user_ns "$AIDC_K8S_USER")
k8s_require_session "$ns" "$NAME"

current() {
    local out
    out=$(k8s_networks "$ns" "$NAME") || die "cannot read ${NAME}'s networks: the cluster did not answer (${out})"
    printf '%s' "$out"
}

do_add() {
    local target="${1:-}" why
    [ -n "$target" ] || die "add requires a namespace"
    if why=$(k8s_network_refusal "$target"); then die "refusing ${target}: ${why}"; fi
    if why=$(k8s_network_ungranted "$target"); then die "refusing ${target}: ${why}"; fi
    if current | grep -qxF "$target"; then
        info "${NAME} already reaches ${target}; reading its Services again"
        do_sync
        return 0
    fi
    k8s_render_network "$NAME" "$target" | k8s_kubectl apply -f - >&2 || die "the cluster did not take the policy for ${target}"
    k8s_names_sync "$ns" "$NAME" \
        || info "WARNING: ${target}'s Service names could not be written into ${NAME}'s names responder; its pods are reachable by address"
    info "network: ${NAME} -> every pod of ${target}, any port; its Services as <svc>.${target}"
    info "  NOT proxied by squid and NOT visible to taint detection; ${target}'s own policies may still refuse"
}

do_rm() {
    local target="${1:-}"
    [ -n "$target" ] || die "rm requires a namespace"
    if ! current | grep -qxF "$target"; then info "${NAME} does not reach ${target} (already gone?)"; return 0; fi
    k8s_kubectl -n "$ns" delete networkpolicy "${NAME}-net-${target}" --ignore-not-found >&2 \
        || die "the cluster did not remove the policy for ${target}"
    k8s_names_sync "$ns" "$NAME" || info "WARNING: ${target}'s Service names are still in ${NAME}'s names responder (they no longer reach anything)"
    info "network: ${NAME} no longer reaches ${target}"
}

do_sync() {
    k8s_names_sync "$ns" "$NAME" || die "the Service names could not be written into ${NAME}'s names responder"
    info "names: ${NAME}'s names responder has every given namespace's Services as they are now"
}

do_ls() {
    local nets
    nets=$(current)
    [ -n "$nets" ] || { printf 'no networks for session %s (only its squid and its relays)\n' "$NAME"; return 0; }
    printf '%s\n' "$nets"
}

case "$SUBVERB" in
    add) do_add "$@" ;;
    rm) do_rm "$@" ;;
    ls) do_ls ;;
    sync) do_sync ;;
    -h|--help) usage ;;
    *) err "unknown subverb: ${SUBVERB}"; usage >&2; exit 2 ;;
esac
