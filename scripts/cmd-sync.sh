#!/usr/bin/env bash
# desc: One Claude history per repo across the cluster and your machines, with Syncthing (setup, reconcile; start|stop|status|logs|push-settings).
#
# This machine's side (setup, reconcile) runs here; the cluster's Syncthing pod is
# scripts/k8s/sync.sh. docs/design-12-kubernetes.md, "One history per repo, on every machine".

set -euo pipefail

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
: "${AIDC_ROOT:?AIDC_ROOT not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"
# shellcheck source=lib/config.sh
. "$AIDC_SCRIPTS/lib/config.sh"
# shellcheck source=lib/claude-sync.sh
. "$AIDC_SCRIPTS/lib/claude-sync.sh"

CLAUDE_DIR="${HOME}/.claude"
LEASE_CMD="${AIDC_ROOT}/.devcontainer/claude-lease.sh hook"

usage() {
    cat <<'USAGE'
aidc sync <verb>

One Claude history per repo across the cluster and your machines (Mac, Linux, WSL): your
cluster disk's .claude and each machine's ~/.claude are one Syncthing folder (id aidc-claude),
synced over your LAN or VPN only. Synced: projects/ (conversations, memory), CLAUDE.md, rules/,
skills/, agents/, commands/, keybindings.json. Never: credentials, .claude.json, live state.

On this machine:
  setup [--hooks]    Write the folder's ignore list into ~/.claude/.stignore; on a Mac, alias
                     the cluster's history folders (reconcile). With --hooks, also add aidc's
                     hooks to ~/.claude/settings.json: the conversation lease (two machines never
                     write one conversation at once) and, on a Mac, the alias reconciler
  reconcile          On a Mac: each history folder under its Linux name gets a /Users alias, and
                     one Claude made here under the /Users name moves to the Linux name

In the cluster (your Syncthing pod; see aidc sync help --backend kubernetes):
  start | stop | status | logs | push-settings
USAGE
}

# linux_home: the cluster's home for this user, /home/<kubernetes.user (default: login name)>.
linux_home() {
    local u
    u=$(aidc_yq '.kubernetes.user' "$(_aidc_global_config_file)" 2>/dev/null || true)
    [ -n "$u" ] && [ "$u" != null ] || u=$(id -un)
    printf '/home/%s' "$u"
}

do_reconcile() {
    local quiet=0 out
    [ "${1:-}" = --hook ] && { quiet=1; cat >/dev/null 2>&1 || true; }
    out=$(aidc_sync_reconcile "${CLAUDE_DIR}/projects" "$HOME" "$(linux_home)" 2>&1; \
          aidc_sync_strip_links "${CLAUDE_DIR}/projects")
    [ "$quiet" = 1 ] || { [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/[aidc] /'; }
    return 0
}

do_setup() {
    local hooks=0
    case "${1:-}" in --hooks) hooks=1 ;; "") ;; *) die "unknown flag: $1 (aidc sync setup [--hooks])" ;; esac
    command -v jq >/dev/null 2>&1 || die "jq is needed (the hooks read Claude's JSON)"
    mkdir -p "$CLAUDE_DIR"
    aidc_sync_write_stignore "$CLAUDE_DIR" || exit 1
    info "wrote ${CLAUDE_DIR}/.stignore (what is synced)"
    do_reconcile
    if [ "$hooks" = 1 ]; then
        aidc_sync_install_hooks "${CLAUDE_DIR}/settings.json" "$LEASE_CMD" || exit 1
        info "added the conversation lease hooks to ${CLAUDE_DIR}/settings.json"
        if [ "$HOME" != "$(linux_home)" ]; then
            aidc_sync_install_hooks "${CLAUDE_DIR}/settings.json" "${AIDC_ROOT}/scripts/aidc sync reconcile --hook" || exit 1
            info "added the alias reconciler hook (this machine's home is ${HOME}, the cluster's $(linux_home))"
        fi
    else
        info "no hooks added: two machines could write one conversation at once (aidc sync setup --hooks adds them)"
    fi
    cat >&2 <<NEXT
[aidc] next, once:
[aidc]   1. aidc sync status --backend kubernetes   the cluster pod's device ID (aidc sync start first)
[aidc]   2. in this machine's Syncthing: add that device; add a folder, id ${AIDC_SYNC_FOLDER_ID},
[aidc]      path ${CLAUDE_DIR}, shared with it; turn off global discovery and relays for it if
[aidc]      you can (the pod uses neither)
[aidc]   3. this machine under sync.peers in your aidc config (its device ID and its LAN/VPN
[aidc]      address), then aidc sync start
NEXT
}

VERB="${1:-}"
shift || true
case "$VERB" in
    ""|help|-h|--help) usage ;;
    setup) do_setup "$@" ;;
    reconcile) do_reconcile "$@" ;;
    start|stop|status|logs|push-settings) exec bash "$AIDC_SCRIPTS/k8s/sync.sh" "$VERB" "$@" ;;
    *) err "unknown 'aidc sync' verb: ${VERB} (try: aidc sync help)"; exit 2 ;;
esac
