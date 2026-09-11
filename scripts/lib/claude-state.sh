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
# for THIS project so the workspace-trust dialog does not reappear. Everything
# that names the host's account, or belongs to some other project, stays out.

# aidc_claude_state_seed <host-claude.json> <repo-path> <workspace-path>
# Prints the filtered JSON on stdout; exits non-zero if jq cannot parse the input.
aidc_claude_state_seed() {
    local src="$1" repo="$2" ws="$3"
    jq --arg repo "$repo" --arg ws "$ws" '
        del(.oauthAccount)
        | .projects = ((.projects // {}) | with_entries(
            select(.key == $repo or .key == $ws or (.key | startswith($ws + "/")))))
    ' "$src"
}
