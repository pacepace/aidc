#!/usr/bin/env bash
# aidc clean-env <session> [--yes] (the kubernetes backend): remove what a session left behind.
#
# The cluster form of Docker's clean-env. Docker's removes a session's container-only-path
# volumes left by a create that died half way; a Kubernetes session has no such volumes (its
# worktree is its own, on the user's disk), but a create that dies half way, or a kill the cluster
# stopped answering in the middle of, leaves the same kind of litter: the session's labelled
# objects (audit seed, claims, Service, policies, relays, pages and their login) with no dev
# StatefulSet or proxy to own them, and this machine's tunnels to it. This removes them; the
# session's kept audit claim stays (aidc audit trim removes those), as does the user's disk.
# A running session is refused: aidc kill removes one of those.

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=tunnel.sh
. "$AIDC_SCRIPTS/k8s/tunnel.sh"
# shellcheck source=expose.sh
. "$AIDC_SCRIPTS/k8s/expose.sh"

usage() {
    cat <<'EOF'
aidc clean-env <session> [--yes]     (kubernetes backend)

Removes what a session that is no longer running left in the cluster (a create or a
kill that stopped half way): its objects there, except its kept audit claim, and
this machine's tunnels to it. --yes skips the confirmation.
EOF
}
NAME="" YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --yes) YES=1; shift ;;
        --project|--project=*) die "--project is the Docker backend's (container-only-path volumes; --backend docker); a kubernetes session has none" ;;
        -*) die "unknown flag: $1" ;;
        *) [ -z "$NAME" ] || die "unexpected positional argument: $1"; NAME="$1"; shift ;;
    esac
done
[ -n "$NAME" ] || { usage >&2; exit 2; }
validate_session_name "$NAME"
k8s_require || exit 1
k8s_is_git_session "$NAME" && die "git is your git agent (the git container); aidc git setup manages it"
ns=$(k8s_user_ns "$AIDC_K8S_USER")
sel="aidc/session=${NAME}"
rc=0
where=$(k8s_session_lookup "$ns" "$NAME") || rc=$?
case "$rc" in
    0) die "session '${NAME}' is running: aidc kill ${NAME} removes it" ;;
    1) ;;
    *) die "cannot tell whether session '${NAME}' runs: the cluster did not answer: ${where#unknown }" ;;
esac
# Secrets are not listed (a user may not read them): a page's login goes by name with its pages.
left=$(k8s_kubectl -n "$ns" get deployment,service,networkpolicy,configmap,ingress,pvc -l "$sel" \
    -o go-template='{{range .items}}{{if not (and .metadata.labels (index .metadata.labels "aidc/kept"))}}{{.kind}}/{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
    --request-timeout=10s </dev/null) || die "the cluster did not answer; nothing was removed"
tunnels=$(k8s_tunnels "$ns" "$NAME")
if [ -z "$left" ] && [ -z "$tunnels" ]; then
    # A login made by a create that stopped before its pages cannot be seen; removed unasked.
    k8s_expose_login_remove "$ns" "$NAME" 2>/dev/null || true
    info "nothing left behind by ${NAME}"
    exit 0
fi
printf 'Left behind by %s:\n' "$NAME" >&2
[ -z "$left" ] || printf '%s\n' "$left" | sed 's/^/  /' >&2
[ -z "$tunnels" ] || printf '%s\n' "$tunnels" | awk '{ print "  tunnel localhost:" $1 " (this machine)" }' >&2
if [ "$YES" != 1 ]; then
    printf 'Remove? [y/N] ' >&2
    REPLY=""
    read -r REPLY || true
    case "$REPLY" in y|Y) ;; *) info "aborted"; exit 0 ;; esac
fi
k8s_tunnels_stop_all "$ns" "$NAME" >/dev/null
k8s_expose_remove "$ns" "$NAME" || true
k8s_kubectl -n "$ns" delete deployment,service,networkpolicy,configmap -l "$sel" --ignore-not-found >&2 \
    || die "the cluster did not remove everything; run aidc clean-env ${NAME} again"
k8s_kubectl -n "$ns" delete pvc -l "${sel},aidc/kept!=audit" --ignore-not-found --wait=false >&2 \
    || die "the cluster did not remove the session's claims; run aidc clean-env ${NAME} again"
info "removed what ${NAME} left behind (its kept audit claim stays: aidc audit list)"
