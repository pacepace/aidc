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

usage() {
    cat <<'USAGE'
aidc create <name> --backend kubernetes [--profile P]

Starts a session in the cluster of the `kubernetes:` config, on your disk there
(`aidc user add` makes it). The session sees your whole disk and starts in the current
directory's place on it (made when missing). It takes no --repo: add repos with
`aidc repo add`, and the session makes its own worktree and branch in one with
`git worktree add`. P is the toolchain profile (default: the config's, else multi).
USAGE
}

NAME="" PROFILE_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --repo|--repo=*)
            die "--repo is not used on the kubernetes backend: the session sees your whole disk. Add the repo with \`aidc repo add <owner/name>\`; the session makes its own worktree and branch in it (git worktree add)" ;;
        --profile) PROFILE_OVERRIDE="${2:-}"; shift 2 ;;
        --profile=*) PROFILE_OVERRIDE="${1#--profile=}"; shift ;;
        -*) die "not supported on the kubernetes backend yet: $1" ;;
        *) [ -z "$NAME" ] || die "one session name only (got: $NAME and $1)"; NAME="$1"; shift ;;
    esac
done
validate_session_name "$NAME"
! k8s_is_git_session "$NAME" || die "'git' is reserved for your git agent (aidc git setup); pick another session name"
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

REPO_PATH=$(k8s_cluster_repo_path "$PWD") \
    || die "run aidc create from under your home directory (${HOME}) or /home/${AIDC_K8S_USER}: the session starts at the same place on your disk (got ${PWD})"
case "$REPO_PATH" in *[\"\\]*|*$'\n'*) die "the repo path may not contain quotes, backslashes or newlines" ;; esac

ns=$(k8s_user_ns "$AIDC_K8S_USER")
[ "$(k8s_kubectl -n "$ns" get pvc disk -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Bound" ] \
    || die "no disk for ${AIDC_K8S_USER} in the cluster: run \`aidc user add ${AIDC_K8S_USER}\` first"
# The namespace's default-deny is half of every session's lockdown (its pods' own policies are
# the other half). A namespace made before aidc added it lacks it: say so rather than run there.
k8s_kubectl -n "$ns" get networkpolicy default-deny >/dev/null \
    || die "${ns} has no default-deny NetworkPolicy: run \`aidc user add ${AIDC_K8S_USER}\` again (it is safe to repeat)"
if k8s_kubectl -n "$ns" get deployment "${NAME}-proxy" >/dev/null 2>&1; then
    die "session '${NAME}' already exists (aidc kill ${NAME} --backend kubernetes)"
fi

sel=$(k8s_node_selector) || exit 1
# The session's own token (gh stand-in requests carry it; aidc git mode keys on it), made once
# here: the session is rendered twice below and both must carry the same one.
AIDC_K8S_GIT_TOKEN=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
[[ "$AIDC_K8S_GIT_TOKEN" =~ ^[0-9a-f]{64}$ ]] || die "cannot make the session's token"
AUDIT_CLAIM="${NAME}-audit-$(date -u +%Y%m%d%H%M%S)"
info "creating session ${NAME} in ${ns} (repo ${REPO_PATH}, profile ${PROFILE}, audit ${AUDIT_CLAIM})"
info "config: ${AIDC_CONFIG_SOURCES:-none found (defaults)}"
info "  profile=${PROFILE} taint_response=${AIDC_TAINT_RESPONSE} claude_mode=${AIDC_CLAUDE_MODE}"

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
k8s_kubectl -n "$ns" create configmap "${NAME}-audit-seed" --from-file="${seed}/meta.json" \
    --from-file="${seed}/config-snapshot.yaml" --dry-run=client -o yaml \
    | yq '.metadata.labels = {"app.kubernetes.io/managed-by": "aidc", "aidc/session": "'"${NAME}"'"}' \
    | k8s_kubectl apply -f - >&2
k8s_render_session "$NAME" "$REPO_PATH" "$PROFILE" "$sel" "$AUDIT_CLAIM" | k8s_kubectl apply -f - >&2
proxy_ip=""
for _ in $(seq 30); do
    proxy_ip=$(k8s_kubectl -n "$ns" get service "${NAME}-proxy" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    [ -n "$proxy_ip" ] && break
    sleep 1
done
[ -n "$proxy_ip" ] || die "the proxy Service has no address"
info "waiting for the proxy (squid, blocklist, policy, audit)"
k8s_kubectl -n "$ns" rollout status "deployment/${NAME}-proxy" --timeout=300s >&2 \
    || die "the proxy did not become ready; see: kubectl -n ${ns} describe pod -l aidc/session=${NAME},app=proxy"
k8s_render_session "$NAME" "$REPO_PATH" "$PROFILE" "$sel" "$AUDIT_CLAIM" "$proxy_ip" | k8s_kubectl apply -f - >&2
info "waiting for the dev pod to be ready"
pod="${NAME}-dev-0"
for _ in $(seq 150); do
    if k8s_kubectl -n "$ns" logs "$pod" -c dev 2>/dev/null | grep -q '\[aidc-user-main\] ready'; then
        info "session ${NAME} is ready"
        info "attach: aidc attach ${NAME} --backend kubernetes (or: kubectl -n ${ns} exec -it ${pod} -c dev -- sudo -u vscode tmux attach -t main)"
        exit 0
    fi
    sleep 4
done
die "the dev pod did not report ready in 10 minutes; see: kubectl -n ${ns} logs ${pod} -c dev"
