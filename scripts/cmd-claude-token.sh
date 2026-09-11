#!/usr/bin/env bash
# desc: Manage a long-lived Claude OAuth token that new sessions use instead of logging in (inference-only).
#
# Usage:
#   aidc claude-token setup     # walks you through generating + storing a 1-year token
#   aidc claude-token show      # show last-6 chars + mtime (do not print full token)
#   aidc claude-token clear     # remove the token file; next aidc create logs in inside the session
#
# Why this exists:
#   By default a session logs in on its own (`aidc attach <name>`, then /login):
#   a full claude.ai session that refreshes itself, supports Remote Control,
#   and can be a different account from the host's. This command is the
#   alternative for hosts that do not want a login step per session, such as
#   unattended or scripted creation: `claude setup-token` mints a 1-year token,
#   aidc stores it, and every new session gets it as CLAUDE_CODE_OAUTH_TOKEN.
#
# Trade-offs (documented in `aidc claude-token setup`):
#   - Inference-only: Remote Control does NOT work in a session that uses it,
#     and /login inside such a session is ignored while the token is set.
#   - One-time pain: running `claude setup-token` invalidates your host's
#     existing OAuth session. You'll need to /login on host once.
#   - Token expires after 1 year; rotate by running `claude-token setup`
#     again.
#   - Billing stays on your subscription either way.

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
           dev container and no /login is needed inside it. Inference-only:
           Remote Control does not work in sessions that use it.
  show     Show token presence (last-6 chars + mtime). Does not print the
           full token.
  clear    Remove the token file. Next `aidc create` asks you to /login
           inside the session instead (full session; Remote Control works).

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
  By default each session logs in on its own (aidc attach <name>, then
  /login) and gets a full claude.ai session: it refreshes itself, works
  with Remote Control, and can be a different account from the host's.

  This command is the no-login alternative. `claude setup-token` mints a
  1-year token; aidc stores it and injects it into every new session as
  CLAUDE_CODE_OAUTH_TOKEN. Useful for unattended or scripted session
  creation. The token is inference-only, so Remote Control is unavailable
  in sessions that use it.

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
     CLAUDE_CODE_OAUTH_TOKEN in the dev container's environment, and no
     /login is needed inside it.

Trade-offs:
  - HOST's existing OAuth session is invalidated (one-time /login on host)
  - Host continues to use /login subscription OAuth
  - Containers use the long-lived token
  - Inference-only token: Remote Control does NOT work in sessions that
    use it (a /login inside the session gives a full claude.ai session)
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

To stop using the long-lived token (sessions then /login inside instead):
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
    info "new aidc create runs will ask for a /login inside the session (full session; Remote Control works)"
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
