#!/usr/bin/env bash
# aidc claude account|broker ..., on Docker: the user's Claude accounts, set up once and used by
# every session made while the broker runs, and switched between as their weekly usage runs out
# (K8S-27, K8S-28; owner ruling 2026-11-28, "Account switching on Docker too"). The broker
# container aidc-claude-broker holds them (broker/claude-broker.sh, the cluster's program); this
# reaches it by docker exec. cmd-claude.sh sends `aidc claude` here when the backend is docker.

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_VERSION_TAG:?AIDC_VERSION_TAG not set}"
# shellcheck source=lib.sh
. "$AIDC_SCRIPTS/docker/lib.sh"

usage() {
    cat <<'USAGE'
aidc claude <verb>   (Docker; --backend kubernetes for a cluster's)

Your Claude accounts on this machine, set up once and used by every session made while the
broker runs: a broker container (aidc-claude-broker) holds each account's login and gives
every such session, and the git agent, the active account's credentials (without the refresh
token), so no session needs its own /login, and a switch reaches running sessions on their
next message, conversation kept.

Accounts:
  account add <name>     Log an account in, with Claude's own login, inside the broker (it is
                         started when it is not running). Open the link it prints, sign in,
                         paste the code back. Again for an account whose login ended.
  account remove <name>  Log it out and forget it
  account list [--json]  Order, threshold, usage seen (with its source and age), expiry, last
                         renewal; * is the active account, > the one a waiting switch goes to
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

Sessions made while no broker runs keep their own way: a /login inside the session (aidc
attach <name>), or the long-lived token (aidc claude-token setup). Sessions made while it runs
use it, and keep using it across restart and upgrade. The git agent moves to it at its next
start (aidc git setup).
USAGE
}

# wants_help <args...>: 0 when any of them asks for help (the verbs take no flag of that name).
wants_help() {
    local a
    for a in "$@"; do case "$a" in -h|--help) return 0 ;; esac; done
    return 1
}

# require_running: dies, saying how, unless the broker runs.
require_running() {
    local state rc=0
    state=$(dk_broker_state) || rc=$?
    [ "$rc" = 0 ] || die "cannot tell whether your Claude account broker runs: ${state}"
    [ "$state" = RUNNING ] || die "your Claude account broker is not running (${state}): aidc claude broker start"
}

claude_account() {
    local verb="${1:-}" state rc=0
    shift || true
    case "$verb" in ""|help|-h|--help) usage; return 0 ;; esac
    if wants_help "$@"; then usage; return 0; fi
    case "$verb" in
        add)
            [ -n "${1:-}" ] || die "usage: aidc claude account add <name>"
            state=$(dk_broker_state) || die "cannot tell whether your Claude account broker runs: ${state}"
            if [ "$state" != RUNNING ]; then
                info "starting your Claude account broker (${DK_BROKER_CT})"
                dk_broker_start || exit 1
            fi
            dk_broker_exec_tty login "$1" ;;
        remove|use)
            [ -n "${1:-}" ] || die "usage: aidc claude account ${verb} <name>"
            require_running
            dk_broker_exec "$verb" "$1" ;;
        list)
            state=$(dk_broker_state) || rc=$?
            [ "$rc" = 0 ] || die "cannot tell whether your Claude account broker runs: ${state}"
            if [ "$state" != RUNNING ]; then
                info "no Claude account broker runs here (${state}): aidc claude account add <name> starts it"
                return 0
            fi
            dk_broker_exec list "$@" ;;
        *) die "unknown 'aidc claude account' verb: ${verb} (try: aidc claude help)" ;;
    esac
}

claude_broker() {
    local verb="${1:-}" state rc=0
    shift || true
    case "$verb" in ""|help|-h|--help) usage; return 0 ;; esac
    if wants_help "$@"; then usage; return 0; fi
    case "$verb" in
        start)
            dk_broker_start || exit 1
            info "sessions made from now on use it; the git agent moves to it at its next start (aidc git setup)"
            claude_broker status ;;
        stop)
            info "stopping your Claude account broker (accounts and sessions' Claude dirs are kept)"
            dk_broker_stop || die "could not stop the Claude account broker" ;;
        status)
            state=$(dk_broker_state) || rc=$?
            printf 'claude-broker (docker, %s): %s\n' "$DK_BROKER_CT" "$state"
            [ "$rc" = 0 ] && [ "$state" = RUNNING ] || return 0
            dk_broker_exec list | sed 's/^/  /' ;;
        logs)
            case "${1:-}" in
                "") docker logs "$DK_BROKER_CT" ;;
                -f|--follow) docker logs -f "$DK_BROKER_CT" ;;
                *) die "usage: aidc claude broker logs [--follow]" ;;
            esac ;;
        *) die "unknown 'aidc claude broker' verb: ${verb} (try: aidc claude help)" ;;
    esac
}

VERB="${1:-}"
shift || true
case "$VERB" in ""|help|-h|--help) usage; exit 0 ;; esac
require_docker
case "$VERB" in
    account) claude_account "$@" ;;
    broker) claude_broker "$@" ;;
    *) err "unknown 'aidc claude' verb: ${VERB} (try: aidc claude help)"; exit 2 ;;
esac
