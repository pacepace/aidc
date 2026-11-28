#!/usr/bin/env bash
# aidc claude account|broker ...: the one front end of the user's Claude account broker, the same
# on Docker and on Kubernetes (owner ruling 2026-11-28, "Account switching on Docker too": it works
# the same way on both). Sourced by scripts/docker/claude.sh and scripts/k8s/claude.sh, which
# supply only how to reach their broker, then call claude_front_main "$@":
#
#   CF_WHERE        where the broker runs, in words ("on this machine", "in <namespace>")
#   cf_require      dies unless the backend can be used (docker answers; the cluster's config)
#   cf_state        RUNNING, STARTING or NOT RUNNING; returns 2, saying why, when it cannot tell
#   cf_status_label what broker status names it by ("docker, aidc-claude-broker")
#   cf_exec ...     claude-broker <args> in the broker, no stdin
#   cf_exec_tty ... the same with this terminal (Claude's own login)
#   cf_start        the broker started, or its settings applied; returns 1, saying why
#   cf_stop         the broker stopped (accounts and sessions' Claude dirs kept); 1 when refused
#   cf_logs [-f]    its log
#
# It reports with common.sh's die, err and info, and loads common.sh itself when the caller has
# not (tests/unit/test-lib-self-contained.sh: a library never calls a helper it has not loaded).
#
# Everything a user reads (the help, the verbs, the messages) is here, once.

# shellcheck source=common.sh
declare -F die >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/common.sh"

claude_front_usage() {
    cat <<'USAGE'
aidc claude <verb> [--backend docker|kubernetes]

Your Claude accounts, set up once and used by every session made while the broker runs: a
broker (on Docker the container aidc-claude-broker, on Kubernetes a pod in your namespace)
holds each account's login and gives every such session, and the git agent, the active
account's credentials (without the refresh token), so no session needs its own /login, and a
switch reaches running sessions on their next message, conversation kept.

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

# claude_front_wants_help <args...>: 0 when any of them asks for help (the verbs take no flag of
# that name), so `account use --help` is never an account name.
claude_front_wants_help() {
    local a
    for a in "$@"; do case "$a" in -h|--help) return 0 ;; esac; done
    return 1
}

# claude_front_require_running: dies, saying how, unless the broker runs.
claude_front_require_running() {
    local state rc=0
    state=$(cf_state) || rc=$?
    [ "$rc" = 0 ] || die "cannot tell whether your Claude account broker runs: ${state}"
    [ "$state" = RUNNING ] || die "your Claude account broker is not running (${state}): aidc claude broker start"
}

claude_front_account() {
    local verb="${1:-}" state rc=0
    shift || true
    case "$verb" in
        add)
            [ -n "${1:-}" ] || die "usage: aidc claude account add <name>"
            state=$(cf_state) || die "cannot tell whether your Claude account broker runs: ${state}"
            if [ "$state" != RUNNING ]; then
                info "starting your Claude account broker ${CF_WHERE}"
                cf_start || exit 1
            fi
            cf_exec_tty login "$1" ;;
        remove|use)
            [ -n "${1:-}" ] || die "usage: aidc claude account ${verb} <name>"
            claude_front_require_running
            cf_exec "$verb" "$1" ;;
        list)
            state=$(cf_state) || rc=$?
            [ "$rc" = 0 ] || die "cannot tell whether your Claude account broker runs: ${state}"
            if [ "$state" != RUNNING ]; then
                info "no Claude account broker runs ${CF_WHERE} (${state}): aidc claude account add <name> starts it"
                return 0
            fi
            cf_exec list "$@" ;;
        *) die "unknown 'aidc claude account' verb: ${verb} (try: aidc claude help)" ;;
    esac
}

claude_front_broker() {
    local verb="${1:-}" state rc=0
    shift || true
    case "$verb" in
        start)
            cf_start || exit 1
            info "sessions made from now on use it; the git agent moves to it at its next start (aidc git setup)"
            claude_front_broker status ;;
        stop)
            info "stopping your Claude account broker ${CF_WHERE} (accounts and sessions' Claude dirs are kept)"
            cf_stop || die "could not stop the Claude account broker" ;;
        status)
            state=$(cf_state) || rc=$?
            printf 'claude-broker (%s): %s\n' "$(cf_status_label)" "$state"
            [ "$rc" = 0 ] && [ "$state" = RUNNING ] || return 0
            cf_exec list | sed 's/^/  /' ;;
        logs)
            case "${1:-}" in
                ""|-f|--follow) cf_logs "${1:-}" ;;
                *) die "usage: aidc claude broker logs [--follow]" ;;
            esac ;;
        *) die "unknown 'aidc claude broker' verb: ${verb} (try: aidc claude help)" ;;
    esac
}

# claude_front_main <verb> [args...]: help never reaches the backend (no docker, no cluster
# asked); every other verb runs once the backend can be used.
claude_front_main() {
    local verb="${1:-}"
    shift || true
    case "$verb" in ""|help|-h|--help) claude_front_usage; return 0 ;; esac
    case "$verb" in
        account|broker)
            case "${1:-}" in ""|help|-h|--help) claude_front_usage; return 0 ;; esac
            if claude_front_wants_help "$@"; then claude_front_usage; return 0; fi ;;
        *) err "unknown 'aidc claude' verb: ${verb} (try: aidc claude help)"; exit 2 ;;
    esac
    cf_require
    case "$verb" in
        account) claude_front_account "$@" ;;
        broker) claude_front_broker "$@" ;;
    esac
}
