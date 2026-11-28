#!/usr/bin/env bash
# desc: Your Claude accounts, set up once for every session (account add|remove|list|use; broker start|stop|status|logs).
#
# One broker per user holds each account's login and gives every session it manages the active
# account's credentials, switching between accounts as their weekly usage runs out: on Kubernetes
# a pod in your namespace (scripts/k8s/claude.sh), on Docker the container aidc-claude-broker
# (scripts/docker/claude.sh). The backend is aidc's one rule (aidc_default_backend): --backend,
# else the config's backend: line, else Docker.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"

# shellcheck source=lib/git-common.sh
. "$AIDC_SCRIPTS/lib/git-common.sh"

_backend=$(aidc_default_backend) || exit 2
if [ "$_backend" = kubernetes ]; then
    exec bash "$AIDC_SCRIPTS/k8s/claude.sh" "$@"
fi
exec bash "$AIDC_SCRIPTS/docker/claude.sh" "$@"
