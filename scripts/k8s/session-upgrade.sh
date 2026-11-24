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
cur=$(k8s_kubectl -n "$ns" get statefulset "${NAME}-dev" --request-timeout=10s \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="dev")].image}' </dev/null) \
    || die "cannot read session '${NAME}': the cluster did not answer"

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

old=$(k8s_dev_pod_uid "$ns" "$NAME")
# The image of the dev container and of the init containers that copy from it (the home's first
# seed, the repo folder), then a rollout restart: a new pod even when the tag is unchanged.
k8s_kubectl -n "$ns" set image "statefulset/${NAME}-dev" "dev=${img}" "seed-home=${img}" "repo-dir=${img}" \
    </dev/null >/dev/null || die "the cluster did not take the new image; nothing changed"
k8s_kubectl -n "$ns" rollout restart "statefulset/${NAME}-dev" </dev/null >/dev/null \
    || die "the cluster did not roll the session; see: kubectl -n ${ns} describe statefulset ${NAME}-dev"
info "rolling ${NAME}'s dev pod onto ${img}"
k8s_wait_dev_ready "$ns" "$NAME" "$old" "${AIDC_K8S_READY_WAIT:-600}" || exit 1
got=$(k8s_kubectl -n "$ns" get pod "$pod" -o jsonpath='{.spec.containers[?(@.name=="dev")].image}' </dev/null 2>/dev/null || true)
[ "$got" = "$img" ] || die "${pod} came back on ${got:-an unknown image}, not ${img}"
info "upgraded ${NAME} to ${img}"

# testament: a file into the dev pod, and a command in it as the session user.
testament_copy() { k8s_kubectl -n "$ns" exec -i "$pod" -c dev -- sh -c 'cat > "$1" && chown 1000:1000 "$1"' sh "$2" < "$1"; }
testament_exec() { k8s_kubectl -n "$ns" exec -i "$pod" -c dev -- sudo -u vscode -H env HOME=/home/vscode "$@"; }
aidc_testament_install testament_copy testament_exec
info "attach with: aidc attach ${NAME}"
