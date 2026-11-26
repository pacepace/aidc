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

usage() {
    cat <<'USAGE'
aidc sync <verb>

One Claude history per repo across the cluster and your machines (Mac, Linux, WSL), synced
by Syncthing over your LAN or VPN only, as two folders:
  aidc-claude-projects  ~/.claude/projects: conversations and memory, both ways (the lease
                        keeps two machines from writing one conversation at once)
  aidc-claude-shared    ~/.claude's CLAUDE.md, rules/, skills/, agents/, commands/,
                        keybindings.json: from your machines to the cluster only (Send Only
                        here); sessions read them and cannot change them
Never: credentials, .claude.json, live state. settings.json and the status line: push-settings.

On this machine:
  setup [--hooks]    Write the folders' ignore lists (~/.claude/.stignore, ~/.claude/projects/
                     .stignore); on a Mac, alias
                     the cluster's history folders (reconcile). With --hooks, also add aidc's
                     hooks to ~/.claude/settings.json: the conversation lease (two machines never
                     write one conversation at once) and, on a Mac, the alias reconciler
  reconcile          On a Mac: each history folder under its Linux name gets a /Users alias, and
                     one Claude made here under the /Users name moves to the Linux name

In the cluster (your Syncthing pod; see aidc sync help --backend kubernetes):
  start | stop | status | logs | push-settings

  lease-hook         The lease hook itself (what setup --hooks adds; Claude Code runs it)
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
    mkdir -p "${CLAUDE_DIR}/projects"
    aidc_sync_write_ignore "$CLAUDE_DIR" shared || exit 1
    aidc_sync_write_ignore "${CLAUDE_DIR}/projects" projects || exit 1
    info "wrote ${CLAUDE_DIR}/.stignore and ${CLAUDE_DIR}/projects/.stignore (what is synced)"
    do_reconcile
    if [ "$hooks" = 1 ]; then
        command -v aidc >/dev/null 2>&1 || info "WARNING: no aidc on your PATH: the hooks run \`aidc sync lease-hook\` and will fail until it is"
        aidc_sync_install_hooks "${CLAUDE_DIR}/settings.json" lease || exit 1
        info "added the conversation lease hooks to ${CLAUDE_DIR}/settings.json"
        if [ "$HOME" != "$(linux_home)" ]; then
            aidc_sync_install_hooks "${CLAUDE_DIR}/settings.json" reconcile || exit 1
            info "added the alias reconciler hook (this machine's home is ${HOME}, the cluster's $(linux_home))"
        fi
    else
        info "no hooks added: two machines could write one conversation at once (aidc sync setup --hooks adds them)"
    fi
    cat >&2 <<NEXT
[aidc] next, once:
[aidc]   1. aidc sync status --backend kubernetes   the cluster pod's device ID (aidc sync start first)
[aidc]   2. in this machine's Syncthing: add that device, and share two folders with it:
[aidc]      id ${AIDC_SYNC_PROJECTS_ID}, path ${CLAUDE_DIR}/projects, Send & Receive;
[aidc]      id ${AIDC_SYNC_SHARED_ID}, path ${CLAUDE_DIR}, Send Only
[aidc]      (turn off global discovery and relays if you can: the pod uses neither)
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
    lease-hook) exec bash "${AIDC_ROOT}/.devcontainer/claude-lease.sh" hook "$@" ;;
    start|stop|status|logs|push-settings) exec bash "$AIDC_SCRIPTS/k8s/sync.sh" "$VERB" "$@" ;;
    *) err "unknown 'aidc sync' verb: ${VERB} (try: aidc sync help)"; exit 2 ;;
esac
