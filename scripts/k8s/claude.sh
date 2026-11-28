#!/usr/bin/env bash
# aidc claude account|broker ..., on Kubernetes: the user's Claude accounts, set up once and used
# by every session (K8S-16), and switched between as their weekly usage runs out (K8S-17). The
# broker pod in the user's namespace holds them (broker/claude-broker.sh); this reaches it by
# kubectl exec. cmd-claude.sh sends `aidc claude` here when the backend is kubernetes.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/k8s/lib.sh"
# shellcheck source=manifests.sh
. "$AIDC_SCRIPTS/k8s/manifests.sh"
# shellcheck source=broker.sh
. "$AIDC_SCRIPTS/k8s/broker.sh"

usage() {
    cat <<'USAGE'
aidc claude <verb> --backend kubernetes

Your Claude accounts in the cluster, set up once and used by every session: a broker pod in
your namespace holds each account's login and gives every session the active account's
credentials (without the refresh token), so no session needs its own /login.

Accounts:
  account add <name>     Log an account in, with Claude's own login, inside the broker (it is
                         started when it is not running). Open the link it prints, sign in,
                         paste the code back. Again for an account whose login ended.
  account remove <name>  Log it out and forget it
  account list [--json]  Order, threshold, usage seen, expiry, last renewal; * is the active
                         account, > the one a waiting switch goes to
  account use <name>     Make it the active account now, in every session

The broker:
  broker start           Start it, or apply changed settings (claude_accounts and
                         claude_account_switch in your config)
  broker stop            Stop it (accounts and sessions' Claude dirs are kept; sessions keep
                         the last credentials until they expire)
  broker status          Running state and the accounts
  broker logs [--follow] Its log

Settings (~/.config/aidc/config.yaml):
  claude_accounts:              # the order accounts are used in; after the last, the first
    - {name: work, switch_at: 90}       # weekly usage (%) at which aidc moves away from it
    - {name: personal, switch_at: 70}
  claude_account_switch: auto   # or wait: the switch waits for `aidc claude account use`

Until you add an account, a session logs in itself (aidc attach <name>, then /login).
USAGE
}

# wants_help <args...>: 0 when any of them asks for help (the verbs take no flag of that name), so
# `account use --help` is never an account name.
wants_help() {
    local a
    for a in "$@"; do case "$a" in -h|--help) return 0 ;; esac; done
    return 1
}

claude_account() {
    local verb="${1:-}" state rc=0
    shift || true
    if wants_help "$@"; then usage; return 0; fi
    case "$verb" in
        add)
            [ -n "${1:-}" ] || die "usage: aidc claude account add <name>"
            state=$(k8s_broker_state "$ns") || die "cannot tell whether your Claude account broker runs: ${state}"
            if [ "$state" != RUNNING ]; then
                info "starting your Claude account broker in ${ns}"
                k8s_broker_start "$ns" || exit 1
            fi
            k8s_broker_exec_tty "$ns" login "$1" ;;
        remove|use)
            [ -n "${1:-}" ] || die "usage: aidc claude account ${verb} <name>"
            claude_require_running
            k8s_broker_exec "$ns" "$verb" "$1" ;;
        list)
            state=$(k8s_broker_state "$ns") || rc=$?
            [ "$rc" = 0 ] || die "cannot tell whether your Claude account broker runs: ${state}"
            if [ "$state" != RUNNING ]; then
                info "no Claude account broker runs in ${ns} (${state}): aidc claude account add <name> starts it"
                return 0
            fi
            k8s_broker_exec "$ns" list "$@" ;;
        ""|help|-h|--help) usage ;;
        *) die "unknown 'aidc claude account' verb: ${verb} (try: aidc claude help)" ;;
    esac
}

# claude_require_running: dies, saying how, unless the broker runs.
claude_require_running() {
    local state rc=0
    state=$(k8s_broker_state "$ns") || rc=$?
    [ "$rc" = 0 ] || die "cannot tell whether your Claude account broker runs: ${state}"
    [ "$state" = RUNNING ] || die "your Claude account broker is not running (${state}): aidc claude broker start"
}

claude_broker() {
    local verb="${1:-}" state rc=0
    shift || true
    if wants_help "$@"; then usage; return 0; fi
    case "$verb" in
        start) k8s_broker_start "$ns" || exit 1; claude_broker status ;;
        stop)
            info "stopping your Claude account broker in ${ns} (accounts and sessions' Claude dirs are kept)"
            k8s_deployment_stop "$ns" "$K8S_BROKER_NAME" || die "could not stop the Claude account broker" ;;
        status)
            state=$(k8s_broker_state "$ns") || rc=$?
            printf 'claude-broker (kubernetes, %s): %s\n' "$ns" "$state"
            [ "$rc" = 0 ] && [ "$state" = RUNNING ] || return 0
            k8s_broker_exec "$ns" list | sed 's/^/  /' ;;
        logs) k8s_deployment_logs "$ns" "$K8S_BROKER_NAME" broker "${1:-}" ;;
        ""|help|-h|--help) usage ;;
        *) die "unknown 'aidc claude broker' verb: ${verb} (try: aidc claude help)" ;;
    esac
}

VERB="${1:-}"
shift || true
case "$VERB" in ""|help|-h|--help) usage; exit 0 ;; esac
case "$VERB" in account|broker) if wants_help "$@"; then usage; exit 0; fi ;; esac
k8s_require || exit 1
ns=$(k8s_user_ns "$AIDC_K8S_USER")
case "$VERB" in
    account) claude_account "$@" ;;
    broker) claude_broker "$@" ;;
    *) err "unknown 'aidc claude' verb: ${VERB} (try: aidc claude help)"; exit 2 ;;
esac
