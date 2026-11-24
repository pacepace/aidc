#!/usr/bin/env bash
# aidc kill <name> (a Kubernetes session): remove the session from the cluster.
#
# The audit sidecar finishes first, as on Docker: one last sweep, and killed_at stamped into
# meta.json. Then everything the session made goes (labelled aidc/session=<name>): its dev
# StatefulSet, proxy, Service, NetworkPolicies, home, state and audit seed. Its audit claim
# (labelled aidc/kept=audit, named for its creation time) stays, with its size, kill time and
# taint recorded on it as annotations (scripts/k8s/audit.sh), and so does the user's disk.
# `aidc audit trim` removes kept claims.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=../lib/audit.sh
. "$AIDC_SCRIPTS/lib/audit.sh"

case "${1:-}" in
    -h|--help) printf 'aidc kill <name>\n\nRemoves the session from the cluster; its audit claim and your disk stay.\n'; exit 0 ;;
esac
NAME="${1:-}"
validate_session_name "$NAME"
k8s_require || exit 1
# Before anything is asked or removed: the git agent holds the user's GitHub login and is
# managed with the git container, never killed as a session.
if k8s_is_git_session "$NAME"; then
    die "'${NAME}' is your git agent (the git container's Claude): aidc kill does not remove it. It is managed by aidc git setup; to stop it: kubectl -n $(k8s_user_ns "$AIDC_K8S_USER") scale deployment/git --replicas=0"
fi
ns=$(k8s_user_ns "$AIDC_K8S_USER")
sel="aidc/session=${NAME}"
k8s_require_session "$ns" "$NAME"
audit=$(k8s_kubectl -n "$ns" get pvc -l "${sel},aidc/kept=audit" -o name) \
    || die "the cluster did not answer while finding the audit claim; nothing was removed"
proxy=$(k8s_kubectl -n "$ns" get pod -l "${sel},app=proxy" -o name) \
    || die "the cluster did not answer while finding the proxy pod; nothing was removed"
audit=$(printf '%s\n' "$audit" | head -n1)
proxy=$(printf '%s\n' "$proxy" | head -n1)
measured=""
if [ -n "$proxy" ]; then
    if k8s_kubectl -n "$ns" exec "$proxy" -c audit -- /usr/local/bin/finalize.sh </dev/null >&2; then
        # The trail stops growing here, so its size is recorded now, for aidc audit list and the
        # size warning: then nothing has to mount the kept claim again to measure it.
        measured=$(k8s_kubectl -n "$ns" exec "$proxy" -c audit -- sh -c \
            'du -sk /var/aidc/audit | cut -f1; if [ -e /var/aidc/audit/tainted ] || grep -q tainted_at /var/aidc/audit/meta.json 2>/dev/null; then echo yes; else echo no; fi' \
            </dev/null 2>/dev/null) || measured=""
    else
        info "WARNING: the audit sidecar's final sweep did not run; the audit claim keeps its last sweep"
    fi
fi
if [ -n "$audit" ]; then
    size_k=$(printf '%s\n' "$measured" | sed -n 1p)
    tainted=$(printf '%s\n' "$measured" | sed -n 2p)
    notes=("aidc/killed-at=$(date -u +%FT%TZ)")
    case "$size_k" in ''|*[!0-9]*) ;; *) notes+=("aidc/size-bytes=$((size_k * 1024))") ;; esac
    case "$tainted" in yes|no) notes+=("aidc/tainted=${tainted}") ;; esac
    k8s_kubectl -n "$ns" annotate "$audit" --overwrite "${notes[@]}" >/dev/null \
        || info "WARNING: could not record the audit trail's size on ${audit#persistentvolumeclaim/}; aidc audit list shows it as unknown"
    aidc_audit_k8s_cache_clear
fi
info "removing session ${NAME} from ${ns}"
k8s_kubectl -n "$ns" delete statefulset,deployment,service,networkpolicy,configmap -l "$sel" --wait=true >&2
k8s_kubectl -n "$ns" delete pvc -l "${sel},aidc/kept!=audit" --wait=false >&2
info "session ${NAME} removed; its audit trail is kept in ${audit#persistentvolumeclaim/} (namespace ${ns}; aidc audit list)"
