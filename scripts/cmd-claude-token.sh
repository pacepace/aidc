#!/usr/bin/env bash
# desc: Manage the long-lived Claude OAuth token used to bypass the refresh-token race in containers.
#
# Usage:
#   aidc claude-token setup     # walks you through generating + storing a 1-year token
#   aidc claude-token show      # show last-6 chars + mtime (do not print full token)
#   aidc claude-token clear     # remove the token file; next aidc create reverts to Keychain bridging
#
# Why this exists:
#   Anthropic's OAuth refresh tokens are single-use. When you run multiple
#   concurrent claude processes (host + N dev containers), they race to
#   refresh the same token; the loser ends up with an invalid token and
#   prompts /login. See README "Claude auth -- the OAuth refresh-token race"
#   for the full bug discussion.
#
#   `claude setup-token` generates a 1-year OAuth token (CLAUDE_CODE_OAUTH_TOKEN)
#   that bypasses the refresh dance entirely. When this token is set in a
#   container's env, claude uses it directly -- no refresh, no race.
#
# Trade-offs (documented in `aidc claude-token setup`):
#   - One-time pain: running `claude setup-token` invalidates your host's
#     existing OAuth session. You'll need to /login on host once.
#   - After that, host stays on subscription OAuth, containers use the
#     long-lived token. Different auth mechanisms, no shared refresh.
#   - Token expires after 1 year; rotate by running `claude-token setup`
#     again.
#   - `/login` is not available inside containers using this token.
#   - aidc-auth-bridge becomes unnecessary (no Keychain file to keep fresh
#     in containers).

set -euo pipefail

trap '' PIPE

: "${AIDC_SCRIPTS:?AIDC_SCRIPTS not set}"
# shellcheck source=lib/common.sh
. "$AIDC_SCRIPTS/lib/common.sh"

CONFIG_DIR="${HOME}/.config/aidc"
TOKEN_FILE="${CONFIG_DIR}/claude-oauth-token"

usage() {
    cat <<'EOF'
aidc claude-token <verb>

Verbs:
  setup    Walk through generating + storing a 1-year Claude OAuth token.
           After setup, every new `aidc create` injects the token into the
           dev container, bypassing the OAuth refresh-token race.
  show     Show token presence (last-6 chars + mtime). Does not print the
           full token.
  clear    Remove the token file. Next `aidc create` reverts to Keychain
           bridging (the older approach with the refresh-token race).

See `aidc claude-token setup` for the full trade-off explanation.
EOF
}

# Validate token shape. Anthropic's long-lived OAuth tokens start with
# `sk-ant-oat01-`. Be permissive on length / charset because they may
# change the format; just confirm the prefix.
validate_token_shape() {
    local t="$1"
    case "$t" in
        sk-ant-oat01-*) return 0 ;;
        *) return 1 ;;
    esac
}

do_setup() {
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR" 2>/dev/null || true

    if [ -f "$TOKEN_FILE" ]; then
        local existing
        existing=$(cat "$TOKEN_FILE" 2>/dev/null || true)
        local tail6="${existing: -6}"
        printf 'A token is already stored (...%s, mtime %s).\n' "$tail6" \
            "$(stat -f '%Sm' "$TOKEN_FILE" 2>/dev/null || stat -c '%y' "$TOKEN_FILE" 2>/dev/null)" >&2
        printf 'Re-running setup will OVERWRITE it. Continue? [y/N] ' >&2
        REPLY=""
        read -r REPLY || true
        case "$REPLY" in y|Y) : ;; *) info "aborted"; exit 0 ;; esac
    fi

    cat >&2 <<'EOF'

aidc claude-token setup
-----------------------

Background:
  Anthropic's OAuth refresh tokens are single-use. When multiple claude
  processes refresh concurrently (e.g. host + N containers), they race
  and the losers are forced to /login. Anthropic ships partial fixes
  but the general fix is not yet in -- see https://github.com/anthropics/claude-code/issues/24317

  `claude setup-token` generates a 1-year OAuth token that bypasses
  the refresh dance entirely. Setting it as CLAUDE_CODE_OAUTH_TOKEN in
  each dev container removes containers from the race.

What this will do:
  1. You'll run `claude setup-token` in another terminal on the host.
     That command will:
       a) Open a browser to claude.ai for OAuth authorization.
       b) Print a token starting with `sk-ant-oat01-...` to that terminal.
       c) INVALIDATE your host's existing OAuth session. You will need
          to run `claude /login` on host once after to recover the host's
          interactive auth. This is a one-time pain.
  2. You'll paste the printed token here.
  3. aidc will store it at ~/.config/aidc/claude-oauth-token (mode 0600).
  4. From then on, every `aidc create` injects the token as
     CLAUDE_CODE_OAUTH_TOKEN in the dev container's environment.
     Containers no longer participate in the OAuth refresh race.

Trade-offs:
  - HOST's existing OAuth session is invalidated (one-time /login on host)
  - Host continues to use /login subscription OAuth
  - Containers use the long-lived token
  - The auth-bridge daemon is no longer needed when this is in use
  - Token expires after 1 year; rotate by re-running this setup
  - `claude /login` inside containers does NOT work with this auth mode
    (the env var token takes precedence over interactive OAuth)

Proceed? [y/N]
EOF
    REPLY=""
    read -r REPLY || true
    case "$REPLY" in y|Y) : ;; *) info "aborted"; exit 0 ;; esac

    cat >&2 <<'EOF'

Now in another terminal on this host, run:

    claude setup-token

When the browser flow completes and the token prints to the OTHER terminal,
paste it here (it starts with sk-ant-oat01-...):

EOF
    printf '> ' >&2
    TOKEN=""
    read -r TOKEN || true
    # Trim whitespace.
    TOKEN=$(printf '%s' "$TOKEN" | tr -d '[:space:]')

    if [ -z "$TOKEN" ]; then
        die "no token entered; aborted (run setup again when ready)"
    fi
    if ! validate_token_shape "$TOKEN"; then
        die "token does not match expected shape (should start with 'sk-ant-oat01-'); aborted without writing"
    fi

    # Atomic write with 0600.
    umask 0177
    printf '%s' "$TOKEN" > "${TOKEN_FILE}.new"
    mv -f "${TOKEN_FILE}.new" "$TOKEN_FILE"
    chmod 0600 "$TOKEN_FILE"

    info "stored token at ${TOKEN_FILE} (mode 0600)"
    info "every new 'aidc create' will inject this token as CLAUDE_CODE_OAUTH_TOKEN"
    info "existing running sessions are UNAFFECTED until you 'aidc kill' + 'aidc create' them"
    cat >&2 <<'EOF'

Next steps:
  1. On host: run `claude /login` to recover the host's interactive OAuth
     (only needed once -- setup-token invalidated the prior session).
  2. For each existing aidc session you want to switch to the long-lived
     token: aidc kill <name> && aidc create <name> ...
  3. New sessions automatically use the token.

To stop using the long-lived token and revert to Keychain bridging:
  aidc claude-token clear
EOF
}

do_show() {
    if [ ! -f "$TOKEN_FILE" ]; then
        printf 'no token stored\n'
        printf 'run `aidc claude-token setup` to enable the long-lived-token auth path\n'
        exit 0
    fi
    local content
    content=$(cat "$TOKEN_FILE" 2>/dev/null || true)
    if [ -z "$content" ]; then
        printf 'token file exists but is empty: %s\n' "$TOKEN_FILE"
        exit 1
    fi
    printf 'stored: ...%s\n' "${content: -6}"
    printf 'path:   %s\n' "$TOKEN_FILE"
    printf 'mtime:  %s\n' "$(stat -f '%Sm' "$TOKEN_FILE" 2>/dev/null || stat -c '%y' "$TOKEN_FILE" 2>/dev/null)"
    printf 'mode:   %s\n' "$(stat -f '%A' "$TOKEN_FILE" 2>/dev/null || stat -c '%a' "$TOKEN_FILE" 2>/dev/null)"
    printf '\n'
    printf 'new aidc create runs will inject this as CLAUDE_CODE_OAUTH_TOKEN.\n'
    printf 'existing running sessions are unaffected until kill + create.\n'
}

do_clear() {
    if [ ! -f "$TOKEN_FILE" ]; then
        info "no token stored; nothing to do"
        exit 0
    fi
    printf 'Remove %s? [y/N] ' "$TOKEN_FILE" >&2
    REPLY=""
    read -r REPLY || true
    case "$REPLY" in y|Y) : ;; *) info "aborted"; exit 0 ;; esac
    rm -f "$TOKEN_FILE"
    info "removed token file"
    info "new aidc create runs will fall back to Keychain bridging (the race-prone path)"
    info "existing sessions are unaffected"
}

VERB="${1:-}"
[ -z "$VERB" ] && { usage >&2; exit 2; }
shift

case "$VERB" in
    setup)          do_setup "$@" ;;
    show)           do_show "$@" ;;
    clear)          do_clear "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *)              err "unknown verb: ${VERB}"; usage >&2; exit 2 ;;
esac
