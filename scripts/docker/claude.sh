#!/usr/bin/env bash
# aidc claude account|broker ..., on Docker: the user's Claude accounts, set up once and used by
# every session made while the broker runs, and switched between as their weekly usage runs out
# (K8S-27, K8S-28; owner ruling 2026-11-28, "Account switching on Docker too"). The broker
# container aidc-claude-broker holds them (broker/claude-broker.sh, the cluster's program); this
# reaches it by docker exec. cmd-claude.sh sends `aidc claude` here when the backend is docker.
# The help, the verbs and the messages are the shared front end's (lib/claude-front.sh); this
# file supplies only how to reach the Docker broker.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"
# shellcheck source=../lib/claude-front.sh
. "$AIDC_SCRIPTS/lib/claude-front.sh"

# shellcheck disable=SC2034  # read by lib/claude-front.sh
CF_WHERE="on this machine"
cf_require() { require_docker; }
cf_state() { dk_broker_state; }
cf_status_label() { printf 'docker, %s' "$DK_BROKER_CT"; }
cf_exec() { dk_broker_exec "$@"; }
cf_exec_tty() { dk_broker_exec_tty "$@"; }
cf_start() { dk_broker_start; }
cf_stop() { dk_broker_stop; }
cf_logs() {
    case "${1:-}" in
        -f|--follow) docker logs -f "$DK_BROKER_CT" ;;
        *) docker logs "$DK_BROKER_CT" ;;
    esac
}

claude_front_main "$@"
