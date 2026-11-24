#!/usr/bin/env bash
# session-where.sh <name>: exit 0 when <name> is a session in the configured cluster, 1 when it
# is not, or when no cluster is configured. `session-where.sh --configured`: exit 0 when a
# cluster is configured (and kubectl and yq are there). Quiet. The dispatcher uses it to send a verb that
# names a session to the backend the session lives on, without itself calling kubectl.

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
[ -n "$(k8s_kubectl -n "$(k8s_user_ns "$AIDC_K8S_USER")" get deployment,statefulset \
    -l "aidc/session=${name}" -o name --request-timeout=10s 2>/dev/null)" ]
