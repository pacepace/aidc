#!/usr/bin/env bash
# aidc claude account|broker ..., on Kubernetes: the user's Claude accounts, set up once and used
# by every session (K8S-16), and switched between as their weekly usage runs out (K8S-17). The
# broker pod in the user's namespace holds them (broker/claude-broker.sh); this reaches it by
# kubectl exec. cmd-claude.sh sends `aidc claude` here when the backend is kubernetes.
# The help, the verbs and the messages are the shared front end's (lib/claude-front.sh); this
# file supplies only how to reach the cluster's broker.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=broker.sh
. "$AIDC_SCRIPTS/k8s/broker.sh"
# shellcheck source=../lib/claude-front.sh
. "$AIDC_SCRIPTS/lib/claude-front.sh"

ns="" CF_WHERE=""
cf_require() {
    k8s_require || exit 1
    ns=$(k8s_user_ns "$AIDC_K8S_USER")
    # shellcheck disable=SC2034  # read by lib/claude-front.sh
    CF_WHERE="in ${ns}"
}
cf_state() { k8s_broker_state "$ns"; }
cf_status_label() { printf 'kubernetes, %s' "$ns"; }
cf_exec() { k8s_broker_exec "$ns" "$@"; }
cf_exec_tty() { k8s_broker_exec_tty "$ns" "$@"; }
cf_start() { k8s_broker_start "$ns"; }
cf_stop() { k8s_deployment_stop "$ns" "$K8S_BROKER_NAME"; }
cf_logs() { k8s_deployment_logs "$ns" "$K8S_BROKER_NAME" broker "${1:-}"; }

claude_front_main "$@"
