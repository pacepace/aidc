#!/usr/bin/env bash
# aidc git setup: the configured user's git container (its home claim, egress policy and
# Deployment) in their namespace. Idempotent: `kubectl apply` leaves what is already right
# alone, and the home claim, which holds the user's secrets, is never recreated.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"

case "${1:-}" in
    -h|--help) exec bash "$AIDC_SCRIPTS/cmd-git.sh" --help ;;
esac
[ $# -eq 0 ] || die "aidc git setup takes no arguments (got: $*); the user is kubernetes.user"
k8s_require || exit 1
# The git user's home is /home/git; a user named git would have their disk mounted over it.
[ "$AIDC_K8S_USER" != "git" ] || die "kubernetes.user 'git' clashes with the git container's own home (/home/git)"

ns=$(k8s_user_ns "$AIDC_K8S_USER")
# The disk comes from `aidc user add`; a cluster that does not answer is not "no disk". kubectl's
# messages go to a file, not into the phase: a warning on a call that worked must not read as "no disk".
err=$(mktemp); trap 'rm -f "$err"' EXIT
if ! phase=$(k8s_kubectl -n "$ns" get pvc disk --ignore-not-found -o jsonpath='{.status.phase}' \
        --request-timeout=10s 2>"$err"); then
    die "cannot read ${AIDC_K8S_USER}'s disk in ${ns}: the cluster did not answer: $(tail -n1 "$err")"
fi
[ "$phase" = "Bound" ] || die "${AIDC_K8S_USER} has no disk in ${ns}${phase:+ (it is ${phase})}: run \`aidc user add ${AIDC_K8S_USER}\` first"

sel=$(k8s_node_selector) || exit 1
info "applying ${AIDC_K8S_USER}'s git container in ${ns}"
applied=$(k8s_render_git "$sel" | k8s_kubectl apply -f -) || die "could not apply the git container"
printf '%s\n' "$applied" >&2
# The image tag is aidc's version, so `aidc k8s build --force` replaces the image under the same
# tag and an unchanged Deployment would keep running the old one. Setup restarts it then: the
# pod pulls the image again (imagePullPolicy Always). Always, not only when the registry's
# digest differs: the registry is reachable from the cluster, not from here, and setup is run
# rarely and on purpose. A request running then is reported to its session as interrupted.
if printf '%s\n' "$applied" | grep -q '^deployment.apps/git unchanged'; then
    info "restarting it, so it runs the image now in the registry"
    k8s_kubectl -n "$ns" rollout restart deployment/git >&2 || die "could not restart the git container"
fi
info "waiting for it to be ready"
if ! k8s_kubectl -n "$ns" rollout status deployment/git --timeout=300s >&2; then
    die "the git container did not become ready; see: kubectl -n ${ns} describe pod -l app=git (is aidc/gitctl built? aidc k8s build --only gitctl)"
fi
# The request folder sessions hand pull requests to, made (or checked) on the user's disk by a
# one-shot root pod, as the repo folders are, and given to the git container.
req=$(k8s_git_requests_path)
k8s_repo_dir_step "$ns" "$req" requests "$sel" >/dev/null \
    || die "the git container runs, but its request folder ${req} could not be made; run aidc git setup again"
info "the git container is ready (git mode: ${AIDC_K8S_GIT_MODE}). Next: \`aidc git login\` (a device code you approve in your browser)."
