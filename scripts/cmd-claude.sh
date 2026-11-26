#!/usr/bin/env bash
# desc: Your Claude accounts for cluster sessions, set up once (account add|remove|list|use; broker start|stop|status|logs).
#
# On Kubernetes, scripts/k8s/claude.sh: a broker pod in your namespace holds each account's
# login and gives every session the active account's credentials. On Docker each session logs
# in itself, or every new session gets one long-lived token (aidc claude-token setup).

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"

# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"
# shellcheck source=lib/git-common.sh
. "$AIDC_SCRIPTS/lib/git-common.sh"

_backend=$(aidc_default_backend) || exit 2
[ "$_backend" != kubernetes ] || exec bash "$AIDC_SCRIPTS/k8s/claude.sh" "$@"

case "${1:-}" in
    ""|help|-h|--help)
        cat <<'EOF'
aidc claude account|broker ... is for sessions in a cluster (--backend kubernetes, or
backend: kubernetes in your config): one login per account, used by every session.

On Docker each session logs in itself (aidc attach <name>, then /login), or every new
session gets one long-lived token: aidc claude-token setup.
EOF
        exit 0 ;;
esac
err "aidc claude ${1} is for sessions in a cluster (--backend kubernetes). On Docker a session logs in itself (aidc attach <name>, then /login), or every new session gets one long-lived token: aidc claude-token setup"
exit 2
