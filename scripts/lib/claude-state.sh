#!/usr/bin/env bash
# Seed for the dev container's own ~/.claude.json. Sourced by cmd-create.sh on
# the host and by tests/unit/test-claude-state-seed.sh, so the test exercises the
# exact filter that ships.
#
# The container owns its Claude config directory (CLAUDE_CONFIG_DIR on the
# dev-home volume) and logs in on its own; nothing auth-related is shared with
# the host. What it still wants from the host's ~/.claude.json is the
# onboarding state (hasCompletedOnboarding, theme, output style, editor mode ...)
# so first launch goes straight to the login prompt, and the trust decision
# for THIS project so the workspace-trust dialog does not reappear.
#
# The container is the untrusted side, so the filter errs toward dropping:
#   - every top-level key that can carry a credential or a server definition
#     (the host account, an API key, the approved-API-key hashes, user-scope
#     MCP servers and their env), by name and by a name pattern that also
#     catches keys a later Claude Code adds;
#   - every other project's entry, and from THIS project's entry everything but
#     its trust / onboarding / allowed-tools state (never its prompt history or
#     project-scope MCP servers).

# Top-level keys dropped outright, plus a case-insensitive name pattern.
_AIDC_SEED_DROP_KEYS='["oauthAccount","primaryApiKey","customApiKeyResponses","mcpServers"]'
_AIDC_SEED_DROP_PATTERN='apikey|token|secret|credential|password|oauth|mcp'
# Per-project keys kept for the mounted project (allowlist).
_AIDC_SEED_PROJECT_KEEP='["hasTrustDialogAccepted","hasCompletedProjectOnboarding","projectOnboardingSeenCount","allowedTools","ignorePatterns","dontCrawlDirectory"]'

# aidc_claude_state_seed <host-claude.json> <repo-path> <workspace-path>
# Prints the filtered JSON on stdout; exits non-zero if jq cannot parse the input.
aidc_claude_state_seed() {
    local src="$1" repo="$2" ws="$3"
    jq --arg repo "$repo" --arg ws "$ws" \
       --argjson drop "$_AIDC_SEED_DROP_KEYS" --arg pattern "$_AIDC_SEED_DROP_PATTERN" \
       --argjson keep "$_AIDC_SEED_PROJECT_KEEP" '
        with_entries(select(
            (.key as $k | $drop | index($k) | not)
            and (.key | test($pattern; "i") | not)))
        | .projects = ((.projects // {}) | with_entries(
            select(.key == $repo or .key == $ws or (.key | startswith($ws + "/")))
            | .value |= (if type == "object"
                         then with_entries(select(.key as $k | $keep | index($k)))
                         else {} end)))
    ' "$src"
}

# aidc_statusline_scripts <settings.json> <host-home>
# The status line's script(s), for the settings bridge. settings.json is mounted
# into the session, so its statusLine command runs there too, but a script it
# names under ~/.claude exists only on the host and the line shows nothing.
# Prints, one per line, the path relative to ~/.claude of each regular file the
# command names as $HOME/.claude/..., ~/.claude/... or <host-home>/.claude/...;
# the caller mounts each read-only at the same place under the container's home.
# Prints nothing (and succeeds) without a settings file, a status line, or jq.
aidc_statusline_scripts() {
    local settings="$1" home="$2" cmd token rel
    [ -f "$settings" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    cmd=$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null) || return 0
    [ -n "$cmd" ] || return 0
    for token in $cmd; do
        token="${token#\"}"; token="${token%\"}"; token="${token#\'}"; token="${token%\'}"
        # The patterns are the literal text a settings.json carries, not expansions
        # (a bare ~ or $HOME in a pattern would expand to THIS machine's home).
        # shellcheck disable=SC2016,SC2088
        case "$token" in
            '$HOME/.claude/'*)     rel="${token#'$HOME/.claude/'}" ;;
            '${HOME}/.claude/'*)   rel="${token#'${HOME}/.claude/'}" ;;
            '~/.claude/'*)         rel="${token#'~/.claude/'}" ;;
            "${home}/.claude/"*)   rel="${token#"${home}"/.claude/}" ;;
            *) continue ;;
        esac
        case "$rel" in ''|*..*) continue ;; esac
        [ -f "${home}/.claude/${rel}" ] && printf '%s\n' "$rel"
    done
    return 0
}
