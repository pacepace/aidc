#!/usr/bin/env bash
# aidc upgrade <name> [--yes] (a Kubernetes session): its dev pod onto this aidc version's image.
#
# As on Docker, only the dev pod is replaced: its StatefulSet is pointed at this version's
# dev-base image (from the cluster's registry; `aidc k8s build` puts it there) and rolled, so
# the pod is new even when the tag is the same (a forced rebuild keeps the tag; the image is
# pulled every time). The proxy pod, the session home (Claude's conversation and login) and the
# user's disk are kept, and Claude resumes its conversation (--continue). Then testament's
# newest release goes into the session when the config names its repo (lib/testament.sh).

set -euo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=../lib/testament.sh
. "$AIDC_SCRIPTS/lib/testament.sh"

usage() {
    cat <<'USAGE'
aidc upgrade <name> [--yes]

Moves the session's dev pod onto this aidc version's dev-base image (run `aidc k8s build`
first for a new version; `--force` there for a new Claude Code or testament release under
the same version). The proxy pod, the session home and your disk are kept; an in-flight
Claude turn is interrupted, and Claude resumes the conversation (--continue). testament's
newest release goes into the session too, when your config names its repo.
USAGE
}
NAME="" YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --yes) YES=1; shift ;;
        -*) die "unknown flag: $1" ;;
        *) [ -z "$NAME" ] || die "unexpected positional argument: $1"; NAME="$1"; shift ;;
    esac
done
[ -n "$NAME" ] || { usage >&2; exit 2; }
validate_session_name "$NAME"
k8s_require || exit 1
k8s_is_git_session "$NAME" \
    && die "git is your git agent (the git container), not a session aidc upgrade manages: aidc git setup starts or updates it"
ns=$(k8s_user_ns "$AIDC_K8S_USER")
k8s_require_session "$ns" "$NAME"
pod="${NAME}-dev-0"
img="${AIDC_K8S_REGISTRY_PULL}/aidc/dev-base:${AIDC_VERSION_TAG}"
# The session's StatefulSet as manifests.sh rendered it: its dev container's image now, and
# every container and init container that runs dev-base (the dev container and those that copy
# from it), so all of them move together, whatever the manifest names them.
sts=$(k8s_get "$ns" statefulset "${NAME}-dev" -o json) \
    || die "cannot read session '${NAME}': the cluster did not answer (${sts})"
[ -n "$sts" ] || die "session '${NAME}' has no dev StatefulSet in ${ns}"
cur=$(printf '%s' "$sts" | jq -r '.spec.template.spec.containers[]? | select(.name == "dev") | .image' 2>/dev/null || true)
# The patch: those containers on the new image and a restartedAt stamp, in one change of the pod
# template (one revision, one new pod; the stamp makes it new under an unchanged tag).
patch=$(printf '%s' "$sts" | jq -c --arg img "$img" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def devbase: [.[]? | select((.image // "") | test("/aidc/dev-base:")) | {name: .name, image: $img}];
    {spec: {template: {metadata: {annotations: {"kubectl.kubernetes.io/restartedAt": $at}},
        spec: {containers: (.spec.template.spec.containers | devbase),
               initContainers: (.spec.template.spec.initContainers | devbase)}}}}
    | if (.spec.template.spec.initContainers | length) == 0 then del(.spec.template.spec.initContainers) else . end') \
    || die "cannot read session '${NAME}': its StatefulSet is not what aidc renders"
printf '%s' "$patch" | jq -e '[.spec.template.spec.containers[].name] | index("dev")' >/dev/null 2>&1 \
    || die "session '${NAME}' has no dev container on aidc's dev-base image: create it again (aidc kill ${NAME}; aidc create ${NAME})"

printf '\nThis replaces the dev pod of %s:\n' "$NAME" >&2
printf '  - an in-flight Claude turn is interrupted; Claude resumes the conversation (--continue)\n' >&2
printf '  - processes started in the pod and its inner Docker containers stop\n' >&2
printf '  - the proxy pod, the session home, your disk and the audit trail are kept\n' >&2
printf '  current image: %s\n  new image:     %s (pulled again)\n\n' "${cur:-unknown}" "$img" >&2
if [ "$YES" != 1 ]; then
    printf 'Proceed? [y/N] ' >&2
    REPLY=""
    read -r REPLY || true
    case "$REPLY" in y|Y) ;; *) info "aborted"; exit 0 ;; esac
fi

# The old pod's uid tells the new pod from it (the old one keeps its name and its ready line
# while it terminates): a read that fails stops here, before anything changes.
old=$(k8s_dev_pod_uid "$ns" "$NAME") \
    || die "cannot read ${NAME}'s dev pod in ${ns}: the cluster did not answer (${old}); nothing changed"
k8s_kubectl -n "$ns" patch statefulset "${NAME}-dev" --type=strategic -p "$patch" </dev/null >/dev/null \
    || die "the cluster did not take the new image; nothing changed"
info "rolling ${NAME}'s dev pod onto ${img}"
k8s_wait_dev_ready "$ns" "$NAME" "$old" "${AIDC_K8S_READY_WAIT:-600}" || exit 1
# The pod that said it was ready, read again with its uid: only a new pod's image is an answer.
now=$(k8s_get "$ns" pod "$pod" -o jsonpath='{.metadata.uid}|{.metadata.deletionTimestamp}|{.spec.containers[?(@.name=="dev")].image}') \
    || die "${NAME} came back, but its image cannot be read: the cluster did not answer (${now}); run aidc upgrade ${NAME} again"
IFS='|' read -r uid gone got <<<"$now" || true
{ [ -n "$uid" ] && [ "$uid" != "$old" ] && [ -z "$gone" ]; } \
    || die "${pod} was replaced again before its image could be read; run aidc upgrade ${NAME} again"
[ "$got" = "$img" ] || die "${pod} came back on ${got:-an unknown image}, not ${img}"
info "upgraded ${NAME} to ${img}"

# testament: a file into the dev pod, and a command in it as the session user.
testament_copy() { k8s_kubectl -n "$ns" exec -i "$pod" -c dev -- sh -c 'cat > "$1" && chown 1000:1000 "$1"' sh "$2" < "$1"; }
testament_exec() { k8s_kubectl -n "$ns" exec -i "$pod" -c dev -- sudo -u vscode -H env HOME=/home/vscode "$@"; }
aidc_testament_install testament_copy testament_exec
info "attach with: aidc attach ${NAME}"
