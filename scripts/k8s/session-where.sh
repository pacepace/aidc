#!/usr/bin/env bash
# session-where.sh <name>: whether <name> is a session in the configured cluster.
#   exit 0  it is
#   exit 1  it is not, or no cluster is configured (kubectl or yq missing counts as none)
#   exit 2  the cluster could not be asked: an unreachable cluster is not an answer
# `session-where.sh --configured`: exit 0 when a cluster is configured. Quiet. The dispatcher
# uses it to send a verb that names a session to the backend the session lives on, without
# itself calling kubectl.

set -uo pipefail
: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh" 2>/dev/null || exit 1
command -v kubectl >/dev/null 2>&1 && _aidc_has_yq || exit 1
k8s_load_settings
[ "$AIDC_K8S_CONFIGURED" = "true" ] || exit 1
name="${1:-}"
[ "$name" = "--configured" ] && exit 0
[ -n "$name" ] || exit 1
found=$(k8s_kubectl -n "$(k8s_user_ns "$AIDC_K8S_USER")" get deployment,statefulset \
    -l "aidc/session=${name}" -o name --request-timeout=5s 2>/dev/null) || exit 2
[ -n "$found" ]
