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
aidc create <name> --backend kubernetes [--profile P] [--cpu N] [--memory Q]
                                         [--cpu-limit N] [--memory-limit Q]

Starts a session in the cluster of the `kubernetes:` config, on your disk there
(`aidc user add` makes it). The session sees your whole disk and starts in the current
directory's place on it (made when missing). It takes no --repo: add repos with
`aidc repo add`, and the session makes its own worktree and branch in one with
`git worktree add`. P is the toolchain profile (default: the config's, else multi).

Size: --cpu and --memory are what the session is guaranteed (default: the config's
kubernetes.cpu and .memory, else 2 and 8Gi); --cpu-limit and --memory-limit what it may
use when the node has room (kubernetes.cpu_limit and .memory_limit, else 16 and 32Gi).
CPU as 2, 1.5 or 500m; memory as 8Gi or 512Mi. A request above the configured limit
raises the limit to it, unless a limit is given too.
USAGE
}

NAME="" PROFILE_OVERRIDE="" CPU="" MEMORY="" CPU_LIMIT="" MEMORY_LIMIT=""
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
    info "git identity: NOT bridged (set this machine's git config --global user.name and user.email)"
fi
AUDIT_CLAIM="${NAME}-audit-$(date -u +%Y%m%d%H%M%S)"
info "creating session ${NAME} in ${ns} (repo ${REPO_PATH}, profile ${PROFILE}, audit ${AUDIT_CLAIM})"
info "config: ${AIDC_CONFIG_SOURCES:-none found (defaults)}"
info "  profile=${PROFILE} taint_response=${AIDC_TAINT_RESPONSE} claude_mode=${AIDC_CLAUDE_MODE}"
info "  size: ${AIDC_K8S_CPU_REQUEST} CPU / ${AIDC_K8S_MEMORY_REQUEST} guaranteed, up to ${AIDC_K8S_CPU_LIMIT} / ${AIDC_K8S_MEMORY_LIMIT}"

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
k8s_render_session "$NAME" "$REPO_PATH" "$PROFILE" "$sel" "$AUDIT_CLAIM" "$proxy_ip" | k8s_kubectl apply -f - >&2
info "waiting for the dev pod to be ready"
pod="${NAME}-dev-0"
# A new session has no old pod: any dev pod that is not being deleted and says it is ready
# (k8s_wait_dev_ready says where to look when it does not).
k8s_wait_dev_ready "$ns" "$NAME" "" "${AIDC_K8S_READY_WAIT:-600}" \
    || die "the dev pod did not report ready; its log: kubectl -n ${ns} logs ${pod} -c dev"
info "session ${NAME} is ready"
# The git container keys this session's git mode on its token (the user's mode until
# aidc git mode gives it its own; a session made again under an old name starts afresh).
if gpod=$(k8s_git_pod "$ns" 2>/dev/null) \
        && printf '%s\n' "$AIDC_K8S_GIT_TOKEN" | k8s_kubectl -n "$ns" exec -i "$gpod" -c git -- git-requests register "$NAME" >/dev/null 2>&1; then
    info "git container: session ${NAME} registered (your git mode applies to it)"
else
    info "git container: not running, so ${NAME} is not registered yet: its requests wait for your approval until aidc git setup"
fi
info "attach: aidc attach ${NAME} --backend kubernetes (or: kubectl -n ${ns} exec -it ${pod} -c dev -- sudo -u vscode tmux attach -t main)"
